#!/usr/bin/env python3
"""Transfer root-only VM credentials into each namespace over an existing SSH tunnel."""
import argparse
import base64
import json
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ssh-port', type=int, default=2222, help='Local Bastion tunnel to VM port 22')
    parser.add_argument('--identity', required=True, help='Path to the WSL SSH private key; never uploaded')
    args = parser.parse_args()
    ssh = ['ssh', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes',
           '-p', str(args.ssh_port), '-i', args.identity, 'ubuntu@127.0.0.1']

    def remote(path):
        # Only fixed, repository-defined file paths are sent to the remote shell.
        return subprocess.run([*ssh, 'sudo', '-n', 'cat', path], check=True, capture_output=True).stdout

    ca = remote('/srv/postgres/tls/root.crt')
    for namespace, database in [('personal-os', 'personal_os'), ('sg-wedding', 'sg_wedding')]:
        content = remote('/srv/postgres/credentials/' + database + '.env').decode()
        credentials = dict(line.split('=', 1) for line in content.splitlines() if line)
        if set(credentials) != {'JDBC_URL', 'DB_USERNAME', 'DB_PASSWORD'}:
            raise RuntimeError('Unexpected remote credential file keys')
        if credentials['DB_USERNAME'] != database or 'sslmode=verify-full' not in credentials['JDBC_URL']:
            raise RuntimeError('Unexpected database user or missing TLS verification')
        data = {key: base64.b64encode(value.encode()).decode() for key, value in credentials.items()}
        data['DB_SSL_ROOT_CERT'] = base64.b64encode(ca).decode()
        manifest = {'apiVersion': 'v1', 'kind': 'Secret', 'type': 'Opaque',
                    'metadata': {'name': 'database-credentials', 'namespace': namespace}, 'data': data}
        # Server-side apply avoids storing another credential copy in the last-applied annotation.
        subprocess.run(['kubectl', 'apply', '--server-side', '--field-manager=postgres-credentials', '-f', '-'],
                       input=json.dumps(manifest).encode(), check=True, stdout=subprocess.DEVNULL)
        print('Installed database-credentials in ' + namespace + '; restart its API when ready.')


if __name__ == '__main__':
    main()
