#!/usr/bin/env python3
"""Real PostgreSQL bootstrap, TLS, role isolation, and backup tests in a disposable container."""
import io
import json
import os
import subprocess
import sys
import tarfile
from pathlib import Path
if os.environ.get('POSTGRES_INTEGRATION_CONTAINER') != '1' or not Path('/.dockerenv').exists():
    raise SystemExit('Only run this test in the dedicated disposable Docker container')
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'environments/shared/postgres'))
import bootstrap
import backup
config = {'private_ip': '127.0.0.2', 'worker_cidrs': ['10.20.30.0/24'], 'bastion_cidrs': ['10.20.90.2/32']}
Path('/srv/postgres').mkdir(parents=True, exist_ok=True)
original = bootstrap.run

def run(*args, **kwargs):
    if args[0] == 'systemctl':
        if args[1] in ('restart', 'reload'):
            return original('pg_ctlcluster', '16', 'main', args[1], **kwargs)
        return subprocess.CompletedProcess(args, 0, '')
    return original(*args, **kwargs)
bootstrap.run = run
bootstrap.configure_server(config)
passwords = {app: (Path('/srv/postgres/credentials') / (app + '.password')).read_text().strip() for app in bootstrap.APPS}
bootstrap.configure_server(config)
assert all(((Path('/srv/postgres/credentials') / (app + '.password')).read_text().strip() == value for app, value in passwords.items()))
print('Bootstrap rerun preserves credentials and data', flush=True)

def connect(app, db=None, mode='verify-full', root='/srv/postgres/tls/root.crt', sql='SELECT current_user;'):
    env = dict(os.environ, PGPASSWORD=passwords[app], PGSSLMODE=mode, PGSSLROOTCERT=root)
    return subprocess.run(['psql', '-XAt', '-v', 'ON_ERROR_STOP=1', '-h', '127.0.0.2', '-U', app, '-d', db or app, '-c', sql], env=env, capture_output=True, text=True)
for app in bootstrap.APPS:
    r = connect(app)
    assert r.returncode == 0, (app, r.stderr)
    assert r.stdout.strip() == app
    assert connect(app, mode='disable').returncode != 0
    assert connect(app, root='/tmp/missing-ca.crt').returncode != 0
    other = 'sg_wedding' if app == 'personal_os' else 'personal_os'
    assert connect(app, db=other).returncode != 0
    r = connect(app, sql="DROP TABLE IF EXISTS application_sample; CREATE TABLE application_sample (value text); INSERT INTO application_sample VALUES ('restore me');")
    assert r.returncode == 0, r.stderr
    assert bootstrap.sql(f"SELECT has_database_privilege('{app}','{other}','CONNECT');") == 'f'
    assert bootstrap.sql(f"SELECT rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication FROM pg_roles WHERE rolname='{app}';") == 'f'
print('Verified TLS, plaintext rejection, CA checking, isolated databases, and restricted application roles', flush=True)
Path('/srv/postgres/bootstrap-complete').touch()

class Raw:

    def __init__(self, data):
        self.data = data

    def stream(self, *args, **kwargs):
        yield self.data

class Client:

    def put_object(self, namespace, bucket, key, stream, **kwargs):
        self.payload = stream.read()
        self.key = key

    def get_object(self, *args):
        from types import SimpleNamespace
        return SimpleNamespace(data=SimpleNamespace(raw=Raw(self.payload)))
client = Client()
original_is_mount = Path.is_mount
Path.is_mount = lambda p: str(p) == '/srv/postgres' or original_is_mount(p)
backup.backup(client, 'test', 'private-backups')
assert json.loads(Path('/srv/postgres/last-successful-backup').read_text())['restore_tested']
assert bootstrap.sql("SELECT count(*) FROM pg_database WHERE datname LIKE 'backup_verify_%';") == '0'
with tarfile.open(fileobj=io.BytesIO(client.payload), mode='r:gz') as tar:
    for app in bootstrap.APPS:
        assert app + '.dump' in tar.getnames()
    assert 'globals.sql' in tar.getnames() and 'ca/root.key' in tar.getnames()
    assert 'credentials/personal_os.env' in tar.getnames()
print('Verified actual pg_dump -> pg_restore -> SQL probes, archive contents, SHA256 readback, and temporary database cleanup', flush=True)
previous = Path('/srv/postgres/last-successful-backup').read_bytes()

class CorruptClient(Client):

    def get_object(self, *args):
        from types import SimpleNamespace
        return SimpleNamespace(data=SimpleNamespace(raw=Raw(b'corrupted remote archive')))
try:
    backup.backup(CorruptClient(), 'test', 'private-backups')
    raise AssertionError('Corrupt remote backup was accepted')
except RuntimeError as error:
    assert 'SHA256' in str(error)
assert Path('/srv/postgres/last-successful-backup').read_bytes() == previous
print('Failed remote readback leaves the previous successful-backup marker unchanged', flush=True)
