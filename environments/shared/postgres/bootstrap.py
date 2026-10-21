#!/usr/bin/python3
"""Idempotent first-boot setup; passwords and database files never enter Terraform."""
import ipaddress
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import time

DATA = Path('/srv/postgres')
CONFIG = Path('/etc/shared-postgres.json')
APPS = ('personal_os', 'sg_wedding')


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


def write(path, text, mode=0o600, owner=None):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + '.new')
    temporary.write_text(text)
    temporary.chmod(mode)
    if owner:
        shutil.chown(temporary, owner, owner)
    temporary.replace(path)


def mount_data():
    device = Path('/dev/oracleoci/oraclevdb')
    for _ in range(120):
        if device.is_block_device():
            break
        time.sleep(5)
    else:
        raise RuntimeError('Data attachment missing; refusing to put PostgreSQL on the boot disk')
    actual = str(device.resolve())
    root_device = run('findmnt', '-nro', 'SOURCE', '/', capture_output=True).stdout.strip()
    root_tree = run('lsblk', '-sno', 'PATH', root_device, capture_output=True).stdout.split()
    if actual in root_tree:
        raise RuntimeError('Data device resolves to the boot disk')
    signatures = json.loads(run('wipefs', '--json', actual, capture_output=True).stdout).get('signatures', [])
    if not signatures:
        children = json.loads(run('lsblk', '--json', actual, capture_output=True).stdout)['blockdevices'][0].get('children')
        if children or int(run('blockdev', '--getsize64', actual, capture_output=True).stdout) < 49 * 1024**3:
            raise RuntimeError('Unexpected data disk layout or size; refusing to format')
        run('mkfs.ext4', '-L', 'shared-postgres', actual)
    elif len(signatures) != 1 or signatures[0]['type'] != 'ext4':
        raise RuntimeError('Unexpected disk signatures; refusing to format or mount')
    label = run('blkid', '-s', 'LABEL', '-o', 'value', actual, capture_output=True).stdout.strip()
    if label != 'shared-postgres':
        raise RuntimeError('Existing volume has unexpected label; recover it manually')
    uuid = run('blkid', '-s', 'UUID', '-o', 'value', actual, capture_output=True).stdout.strip()
    DATA.mkdir(parents=True, exist_ok=True)
    fstab = Path('/etc/fstab')
    marker = f'UUID={uuid} /srv/postgres ext4 defaults,_netdev,nofail 0 2'
    if marker not in fstab.read_text():
        if any('/srv/postgres' in line and not line.lstrip().startswith('#') for line in fstab.read_text().splitlines()):
            raise RuntimeError('An unexpected /srv/postgres mount already exists')
        with fstab.open('a') as stream:
            stream.write('\n' + marker + '\n')
    if not DATA.is_mount():
        run('mount', '/srv/postgres')
    mounted_uuid = run('findmnt', '-nro', 'UUID', '/srv/postgres', capture_output=True).stdout.strip()
    if mounted_uuid != uuid:
        raise RuntimeError('Wrong disk mounted at /srv/postgres')
    DATA.chmod(0o755)


def sql(statement, database='postgres'):
    # Capture output so CREATE ROLE/password statements cannot appear in cloud-init logs.
    return run('runuser', '-u', 'postgres', '--', 'psql', '-X', '-v', 'ON_ERROR_STOP=1',
               '-At', '-d', database, input=statement, capture_output=True).stdout.strip()


def configure_tls(config):
    tls = DATA / 'tls'
    ca = DATA / 'ca'
    tls.mkdir(exist_ok=True, mode=0o755)
    ca.mkdir(exist_ok=True, mode=0o700)
    if not (ca / 'root.key').exists():
        if (tls / 'root.crt').exists():
            raise RuntimeError('CA key missing; restore CA from backup')
        run('openssl', 'req', '-x509', '-newkey', 'rsa:3072', '-nodes', '-days', '3650',
            '-subj', '/CN=Shared PostgreSQL CA', '-keyout', str(ca / 'root.key'),
            '-out', str(tls / 'root.crt'), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        (ca / 'root.key').chmod(0o600)
    cert = tls / 'server.crt'
    if not cert.exists() or subprocess.run(['openssl', 'x509', '-checkend', '2592000', '-noout',
                                          '-in', str(cert)], stdout=subprocess.DEVNULL).returncode:
        run('openssl', 'req', '-new', '-newkey', 'rsa:3072', '-nodes', '-subj', '/CN=postgres',
            '-keyout', str(tls / 'server.key'), '-out', str(tls / 'server.csr'),
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        write(tls / 'extensions.cnf',
              'subjectAltName=IP:' + config['private_ip'] + ',DNS:postgres,DNS:localhost,IP:127.0.0.1\n'
              'extendedKeyUsage=serverAuth\n', 0o644)
        run('openssl', 'x509', '-req', '-days', '365', '-in', str(tls / 'server.csr'),
            '-CA', str(tls / 'root.crt'), '-CAkey', str(ca / 'root.key'), '-CAcreateserial',
            '-extfile', str(tls / 'extensions.cnf'), '-out', str(cert),
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        shutil.chown(tls / 'server.key', 'postgres', 'postgres')
        (tls / 'server.key').chmod(0o600)
        cert.chmod(0o644)
        (tls / 'root.crt').chmod(0o644)


def configure_server(config):
    cluster = DATA / '16/main'
    if not (cluster / 'PG_VERSION').exists():
        if cluster.exists() and any(cluster.iterdir()):
            raise RuntimeError('Nonempty unrecognized PostgreSQL directory; recover manually')
        if Path('/etc/postgresql/16/main').exists():
            raise RuntimeError('Existing cluster configuration without data; recover manually')
        run('pg_createcluster', '16', 'main', '--datadir', str(cluster), '--start-conf=auto',
            '--', '--data-checksums', '--auth-local=peer', '--auth-host=scram-sha-256')
    elif (cluster / 'PG_VERSION').read_text().strip() != '16':
        raise RuntimeError('Unexpected PostgreSQL major version')
    elif not Path('/etc/postgresql/16/main/postgresql.conf').exists():
        raise RuntimeError('Restore cluster configuration from backup before starting this recovered volume')
    configure_tls(config)
    write('/etc/postgresql/16/main/conf.d/shared.conf', f"""listen_addresses = '{config['private_ip']},127.0.0.1'
ssl = on
ssl_min_protocol_version = 'TLSv1.2'
ssl_cert_file = '/srv/postgres/tls/server.crt'
ssl_key_file = '/srv/postgres/tls/server.key'
password_encryption = 'scram-sha-256'
shared_buffers = '1536MB'
effective_cache_size = '4GB'
work_mem = '4MB'
maintenance_work_mem = '128MB'
max_connections = 60
max_wal_size = '1GB'
log_min_duration_statement = 1000
log_connections = on
log_disconnections = on
""", 0o644, 'postgres')
    # pg_createcluster can leave include_dir commented when initdb options are
    # supplied. Explicitly include our managed fragment after package settings.
    main_config = Path('/etc/postgresql/16/main/postgresql.conf')
    include = "include = '/etc/postgresql/16/main/conf.d/shared.conf'"
    if include not in main_config.read_text():
        with main_config.open('a') as stream:
            stream.write('\n' + include + '\n')
    rules = ['local all postgres peer', 'local all all peer']
    for app in APPS:
        for cidr in ['127.0.0.1/32', *config['worker_cidrs'], *config['bastion_cidrs']]:
            ipaddress.ip_network(cidr)
            rules.append(f'hostssl {app} {app} {cidr} scram-sha-256')
        rules.append(f'hostssl backup_verify_{app} {app} 127.0.0.1/32 scram-sha-256')
    rules += ['host all all 0.0.0.0/0 reject', 'host all all ::/0 reject']
    write('/etc/postgresql/16/main/pg_hba.conf', '\n'.join(rules) + '\n', 0o640, 'postgres')
    write('/etc/systemd/system/postgresql@16-main.service.d/data.conf',
          '[Unit]\nRequiresMountsFor=/srv/postgres\nConditionPathIsMountPoint=/srv/postgres\n', 0o644)
    run('systemctl', 'daemon-reload')
    run('systemctl', 'restart', 'postgresql@16-main')
    credentials = DATA / 'credentials'
    credentials.mkdir(exist_ok=True, mode=0o700)
    for app in APPS:
        password_file = credentials / (app + '.password')
        if not password_file.exists():
            if sql(f"SELECT 1 FROM pg_roles WHERE rolname='{app}';"):
                raise RuntimeError('Existing role without saved password; rotate it manually')
            write(password_file, secrets.token_hex(32) + '\n')
        password = password_file.read_text().strip()
        if len(password) != 64 or any(c not in '0123456789abcdef' for c in password):
            raise RuntimeError('Invalid saved credential format')
        if not sql(f"SELECT 1 FROM pg_roles WHERE rolname='{app}';"):
            sql(f"CREATE ROLE {app} LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION PASSWORD '{password}';")
        if not sql(f"SELECT 1 FROM pg_database WHERE datname='{app}';"):
            sql(f'CREATE DATABASE {app} OWNER {app};')
        sql(f'REVOKE CONNECT, TEMPORARY ON DATABASE {app} FROM PUBLIC; GRANT CONNECT, TEMPORARY ON DATABASE {app} TO {app};')
        sql('REVOKE CREATE ON SCHEMA public FROM PUBLIC;', app)
        sql('CREATE TABLE IF NOT EXISTS public.infrastructure_restore_probe (id integer PRIMARY KEY); '
            'INSERT INTO public.infrastructure_restore_probe VALUES (1) ON CONFLICT DO NOTHING;', app)
        write(credentials / (app + '.env'),
              f"JDBC_URL=jdbc:postgresql://{config['private_ip']}:5432/{app}?sslmode=verify-full&sslrootcert=/etc/database/root.crt\n"
              f'DB_USERNAME={app}\nDB_PASSWORD={password}\n')
    sql('REVOKE CONNECT, TEMPORARY ON DATABASE postgres FROM PUBLIC;')


def configure_firewall(config):
    # OCI images may ship a terminal REJECT, so insert specific allows.
    for cidr in [*config['worker_cidrs'], *config['bastion_cidrs']]:
        ports = '22,5432' if cidr in config['bastion_cidrs'] else '5432'
        args = ['INPUT', '-s', cidr, '-p', 'tcp', '-m', 'multiport', '--dports', ports, '-j', 'ACCEPT']
        if subprocess.run(['iptables', '-C', *args], stderr=subprocess.DEVNULL).returncode:
            run('iptables', '-I', args[0], '1', *args[1:])
    run('netfilter-persistent', 'save')


def install_timers():
    write('/etc/systemd/system/postgres-backup.service', '''[Unit]
Description=Dump both application databases, verify restores, and upload private backup
RequiresMountsFor=/srv/postgres
After=postgresql@16-main.service network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/postgres-backup
TimeoutStartSec=7200
UMask=0077
''', 0o644)
    write('/etc/systemd/system/postgres-backup.timer', '''[Unit]
Description=Daily PostgreSQL backup
[Timer]
OnCalendar=*-*-* 03:00:00 UTC
OnBootSec=15min
Persistent=true
RandomizedDelaySec=300
[Install]
WantedBy=timers.target
''', 0o644)
    write('/etc/systemd/system/postgres-health.service', '''[Unit]
Description=Check PostgreSQL disk space, backup freshness, and renew TLS
RequiresMountsFor=/srv/postgres
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/postgres-bootstrap --health
''', 0o644)
    write('/etc/systemd/system/postgres-health.timer', '''[Timer]
OnBootSec=30min
OnUnitActiveSec=1h
[Install]
WantedBy=timers.target
''', 0o644)
    run('systemctl', 'daemon-reload')
    run('systemctl', 'enable', '--now', 'postgresql@16-main', 'postgres-backup.timer', 'postgres-health.timer')


def health(config):
    run('pg_isready', '-q')
    used = shutil.disk_usage(DATA)
    if used.used / used.total > 0.80:
        raise RuntimeError('PostgreSQL data volume is more than 80% full')
    last = DATA / 'last-successful-backup'
    if not last.exists() or time.time() - last.stat().st_mtime > 30 * 3600:
        raise RuntimeError('No successful off-VM backup within 30 hours')
    configure_tls(config)
    run('systemctl', 'reload', 'postgresql@16-main')


def install_dependencies():
    write('/etc/postgresql-common/createcluster.conf', 'create_main_cluster = false\n', 0o644)
    env = dict(os.environ, DEBIAN_FRONTEND='noninteractive')
    run('apt-get', 'update', env=env)
    run('apt-get', 'install', '-y', 'postgresql-16', 'postgresql-client-16', 'openssl',
        'python3-venv', 'iptables-persistent', 'unattended-upgrades', env=env)
    # Ubuntu's ARM package repositories do not provide python3-oci. Use the
    # official Oracle SDK from PyPI, isolated from system Python packages.
    python = Path('/opt/shared-postgres-venv/bin/python3')
    if not python.exists():
        run('python3', '-m', 'venv', '/opt/shared-postgres-venv')
    sdk_version = '2.189.0'
    installed = subprocess.run([str(python), '-c', 'import oci; print(oci.__version__)'],
                               capture_output=True, text=True)
    if installed.returncode or installed.stdout.strip() != sdk_version:
        run(str(python), '-m', 'pip', 'install', '--disable-pip-version-check',
            '--index-url', 'https://pypi.org/simple', 'oci==' + sdk_version)
    run(str(python), '-c', "import oci; assert oci.__version__ == '2.189.0'")
    write('/etc/apt/apt.conf.d/20auto-upgrades',
          'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n', 0o644)


def main():
    if os.geteuid() != 0:
        raise SystemExit('Run as root')
    config = json.loads(CONFIG.read_text())
    if '--health' in __import__('sys').argv:
        health(config)
        return
    mount_data()
    install_dependencies()
    configure_server(config)
    configure_firewall(config)
    write(DATA / 'bootstrap-complete', 'PostgreSQL 16 ready; credentials are root-only.\n')
    install_timers()


if __name__ == '__main__':
    main()
