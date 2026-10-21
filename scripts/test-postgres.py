#!/usr/bin/env python3
"""Failure-path tests for disk protection and backup restore verification; no OCI access."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'environments/shared/postgres' / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


bootstrap = load('bootstrap')
backup = load('backup')


class DiskGuards(unittest.TestCase):
    def test_missing_attachment_never_formats(self):
        with patch.object(Path, 'is_block_device', return_value=False), patch.object(bootstrap.time, 'sleep'), \
                patch.object(bootstrap, 'run') as run:
            with self.assertRaisesRegex(RuntimeError, 'Data attachment missing'):
                bootstrap.mount_data()
            run.assert_not_called()

    def test_boot_disk_never_formats(self):
        with patch.object(Path, 'is_block_device', return_value=True), \
                patch.object(Path, 'resolve', return_value=Path('/dev/sda')), \
                patch.object(bootstrap, 'run', side_effect=[
                    subprocess.CompletedProcess([], 0, '/dev/sda1\n'),
                    subprocess.CompletedProcess([], 0, '/dev/sda1\n/dev/sda\n')]) as run:
            with self.assertRaisesRegex(RuntimeError, 'boot disk'):
                bootstrap.mount_data()
            self.assertEqual(run.call_count, 2)

    def test_existing_unknown_filesystem_never_formats(self):
        with patch.object(Path, 'is_block_device', return_value=True), \
                patch.object(Path, 'resolve', return_value=Path('/dev/sdb')), \
                patch.object(bootstrap, 'run', side_effect=[
                    subprocess.CompletedProcess([], 0, '/dev/sda1\n'),
                    subprocess.CompletedProcess([], 0, '/dev/sda1\n/dev/sda\n'),
                    subprocess.CompletedProcess([], 0, '{"signatures":[{"type":"xfs"}]}')]) as run:
            with self.assertRaisesRegex(RuntimeError, 'Unexpected disk signatures'):
                bootstrap.mount_data()
            self.assertEqual(run.call_count, 3)


class RestoreGuards(unittest.TestCase):
    def test_restore_failure_still_drops_temporary_database(self):
        calls = []

        def pg(*args, **kwargs):
            calls.append(args)
            if args[0] == 'pg_restore':
                raise subprocess.CalledProcessError(1, ['pg_restore'])
            return subprocess.CompletedProcess([], 0, '1\n')

        with patch.object(backup, 'pg', side_effect=pg), patch.object(Path, 'read_text', return_value='test-password'):
            with self.assertRaises(subprocess.CalledProcessError):
                backup.verify_restore('personal_os', Path('/private/personal_os.dump'))
        self.assertEqual(calls[-1], ('dropdb', '--if-exists', 'backup_verify_personal_os'))

    def test_backup_refuses_unmounted_data_volume(self):
        with patch.object(Path, 'is_mount', return_value=False):
            with self.assertRaisesRegex(RuntimeError, 'persistent data mount'):
                backup.backup(None, 'unused', 'unused')

    def test_wrong_restore_probe_is_failure(self):
        with patch.object(backup, 'pg', return_value=subprocess.CompletedProcess([], 0, '')), \
                patch.object(Path, 'read_text', return_value='test-password'):
            with self.assertRaisesRegex(RuntimeError, 'SQL probe'):
                backup.verify_restore('sg_wedding', Path('/private/sg_wedding.dump'))

    def test_write_defaults_to_private_permissions(self):
        with tempfile.TemporaryDirectory() as temporary:
            target = Path(temporary) / 'credential'
            bootstrap.write(target, 'private')
            self.assertEqual(target.stat().st_mode & 0o777, 0o600)


if __name__ == '__main__':
    unittest.main()
