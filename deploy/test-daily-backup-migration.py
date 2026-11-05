#!/usr/bin/env python3
"""Exercise migration with real temporary files/rsync and simulated Docker."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('migration', Path(__file__).with_name('migrate-daily-backup.py'))
migration = importlib.util.module_from_spec(spec)
spec.loader.exec_module(migration)
real_run = subprocess.run


class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.shared = self.root / 'shared'
        self.source = self.shared / 'backup'
        self.source.mkdir(parents=True)
        (self.source / 'fixture').write_bytes(b'backup-fixture\x00')
        self.target = self.root / 'daily'
        self.compose = self.root / 'seafile-prod.yml'
        self.original = 'services:\n  seafile:\n    volumes:\n      - ${SEAFILE_VOLUME}:/shared\n'
        self.compose.write_text(self.original)
        self.mounted = False
        self.fail_verify = False
        self.copy_diff = False
        self.up_count = 0
        for key, value in {'DEPLOY': self.root, 'TARGET': self.target, 'COMPOSE': self.compose,
                           'LOCK': self.root / 'lock',
                           'MOUNT': '      - %s:/shared/backup' % self.target}.items():
            mock = patch.object(migration, key, value)
            mock.start()
            self.addCleanup(mock.stop)

    def execute(self, apply=False):
        def command(args, **kwargs):
            if args[0] in ('docker', 'docker-compose'):
                stdout = ''
                if args[1] == 'inspect':
                    mounts = [{'Destination': '/shared', 'Type': 'bind', 'Source': str(self.shared)}]
                    if self.mounted:
                        mounts.append({'Destination': '/shared/backup', 'Type': 'bind', 'Source': str(self.target)})
                    stdout = json.dumps([{'State': {'Running': True}, 'Image': 'sha256:fixture',
                                          'Config': {'Env': []}, 'Mounts': mounts}])
                elif 'up' in args:
                    self.up_count += 1
                    self.mounted = '/shared/backup' in self.compose.read_text()
                elif args[1:4] == ['exec', 'seafile', 'sh'] and self.fail_verify:
                    raise subprocess.CalledProcessError(1, args)
                return subprocess.CompletedProcess(args, 0, stdout=stdout)
            if args[0] == 'findmnt':
                return subprocess.CompletedProcess(args, 0, stdout='/dev/test /home')
            if args[0] == 'rsync' and '-acn' in args and self.copy_diff:
                return subprocess.CompletedProcess(args, 0, stdout='>f fixture')
            return real_run(args, **kwargs)
        with patch.object(migration.os, 'geteuid', return_value=0), \
                patch.object(migration.shutil, 'which', return_value='/test-command'), \
                patch.object(migration.shutil, 'disk_usage', return_value=SimpleNamespace(free=10**12)), \
                patch.object(migration.subprocess, 'run', side_effect=command), \
                patch('sys.argv', ['migration'] + (['--apply'] if apply else [])), \
                contextlib.redirect_stdout(io.StringIO()):
            migration.main()

    def test_plan_does_not_copy_or_change_compose(self):
        self.execute()
        self.assertFalse(self.target.exists())
        self.assertEqual(self.compose.read_text(), self.original)

    def test_success_preserves_backups_and_current_image(self):
        self.execute(True)
        self.assertTrue(self.mounted)
        self.assertEqual((self.source / 'fixture').read_bytes(), (self.target / 'fixture').read_bytes())
        self.assertEqual(self.target.stat().st_mode & 0o777, 0o700)
        self.assertFalse((self.source / '.backup-lock').exists())
        self.assertFalse((self.target / '.backup-lock').exists())
        self.assertEqual(self.up_count, 1)

    def test_failed_runtime_verification_rolls_back_compose_and_mount(self):
        self.fail_verify = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.execute(True)
        self.assertFalse(self.mounted)
        self.assertEqual(self.compose.read_text(), self.original)
        self.assertEqual(self.up_count, 2)
        self.assertTrue((self.source / 'fixture').exists())

    def test_copy_mismatch_never_recreates_container(self):
        self.copy_diff = True
        with self.assertRaisesRegex(RuntimeError, 'differs'):
            self.execute(True)
        self.assertEqual(self.up_count, 0)
        self.assertEqual(self.compose.read_text(), self.original)

    def test_active_backup_lock_blocks_copy(self):
        (self.source / '.backup-lock').mkdir()
        with self.assertRaisesRegex(RuntimeError, 'lock'):
            self.execute(True)
        self.assertFalse(self.target.exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)
