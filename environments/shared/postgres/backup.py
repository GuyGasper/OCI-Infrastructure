#!/opt/shared-postgres-venv/bin/python3
"""Daily logical backup with actual SQL restore verification and remote readback."""
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

APPS = ('personal_os', 'sg_wedding')
DATA = Path('/srv/postgres')


def pg(*args, **kwargs):
    return subprocess.run(['runuser', '-u', 'postgres', '--', *args],
                          check=True, text=True, **kwargs)


def verify_restore(app, dump):
    database = 'backup_verify_' + app
    pg('dropdb', '--if-exists', database, stdout=subprocess.DEVNULL)
    try:
        pg('createdb', '--template=template0', '--owner=' + app, database)
        # Restore application-owned SQL as that restricted SQL user. Running
        # untrusted schema functions as a superuser can escalate privileges.
        environment = dict(os.environ, PGPASSWORD=(DATA / 'credentials' / (app + '.password')).read_text().strip(),
                           PGSSLMODE='verify-full', PGSSLROOTCERT=str(DATA / 'tls/root.crt'))
        pg('pg_restore', '--exit-on-error', '--no-owner', '--no-privileges', '--host=127.0.0.1',
           '--username=' + app, '-d', database, str(dump), env=environment)
        result = pg('psql', '-XAt', '-v', 'ON_ERROR_STOP=1', '-d', database, '-c',
                    'SELECT id FROM public.infrastructure_restore_probe WHERE id=1;', capture_output=True)
        if result.stdout.strip() != '1':
            raise RuntimeError('Restored database failed the SQL probe: ' + app)
    finally:
        pg('dropdb', '--if-exists', database, stdout=subprocess.DEVNULL)


def backup(client, namespace, bucket):
    if not DATA.is_mount() or not (DATA / 'bootstrap-complete').exists():
        raise RuntimeError('Refusing backup before bootstrap and persistent data mount')
    sizes = [int(pg('psql', '-XAt', '-d', 'postgres', '-c',
                    "SELECT pg_database_size('" + app + "');", capture_output=True).stdout.strip()) for app in APPS]
    required = max(5 * 1024**3, 2 * sum(sizes) + 2 * 1024**3)
    if shutil.disk_usage(DATA).free < required:
        raise RuntimeError('Insufficient free space for dumps, archive, and restored database; expand the data volume')
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y/%m/%d/%H%M%S')
    with tempfile.TemporaryDirectory(prefix='backup-', dir=DATA) as temporary:
        work = Path(temporary)
        work.chmod(0o711)
        dumps = work / 'dumps'
        dumps.mkdir(mode=0o700)
        shutil.chown(dumps, 'postgres', 'postgres')
        for app in APPS:
            dump = dumps / (app + '.dump')
            pg('pg_dump', '--format=custom', '--file=' + str(dump), app)
            verify_restore(app, dump)
        globals_file = dumps / 'globals.sql'
        pg('pg_dumpall', '--globals-only', '--file=' + str(globals_file))
        archive = work / 'backup.tar.gz'
        archive.touch(mode=0o600)
        with tarfile.open(archive, 'w:gz') as stream:
            for app in APPS:
                stream.add(dumps / (app + '.dump'), arcname=app + '.dump')
            stream.add(globals_file, arcname='globals.sql')
            for source, target in [(DATA / 'credentials', 'credentials'), (DATA / 'ca', 'ca'),
                                   (DATA / 'tls', 'tls'), (Path('/etc/postgresql/16/main'), 'postgresql-config')]:
                stream.add(source, arcname=target)
        with archive.open('rb') as stream:
            digest = hashlib.file_digest(stream, 'sha256').hexdigest()
        key = stamp + '/backup.tar.gz'
        # Single PUT avoids multipart IAM privileges (50 GiB maximum).
        with archive.open('rb') as stream:
            client.put_object(namespace, bucket, key, stream, if_none_match='*',
                              opc_meta={'sha256': digest, 'restore-tested': 'true'})
        response = client.get_object(namespace, bucket, key)
        downloaded = hashlib.sha256()
        for chunk in response.data.raw.stream(1024 * 1024, decode_content=False):
            downloaded.update(chunk)
        if downloaded.hexdigest() != digest:
            raise RuntimeError('Uploaded backup failed SHA256 readback verification')
        marker = DATA / 'last-successful-backup.new'
        marker.touch(mode=0o600)
        marker.write_text(json.dumps({'object': key, 'sha256': digest, 'restore_tested': True}) + '\n')
        marker.chmod(0o600)
        marker.replace(DATA / 'last-successful-backup')
    print('Both database restores verified; uploaded backup SHA256 verified.')


def main():
    if os.geteuid() != 0:
        raise SystemExit('Run as root')
    import oci
    config = json.loads(Path('/etc/shared-postgres.json').read_text())
    signer = oci.auth.signers.InstancePrincipalsSecurityTokenSigner()
    client = oci.object_storage.ObjectStorageClient({'region': config['region']}, signer=signer,
                                                   retry_strategy=oci.retry.DEFAULT_RETRY_STRATEGY)
    with Path('/run/postgres-backup.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        backup(client, config['namespace'], config['backup_bucket'])


if __name__ == '__main__':
    main()
