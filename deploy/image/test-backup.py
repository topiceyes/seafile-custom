#!/usr/bin/env python3
"""Run backup with temporary data and a simulated database dump."""
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

base = Path(__file__).resolve().parent
backup_script = base / 'backup.sh'
if not backup_script.exists():
    backup_script = Path('/usr/local/bin/seafile-backup.sh')
spec = importlib.util.spec_from_file_location('bootstrap', base / 'custom_bootstrap.py')
bootstrap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bootstrap)

class BackupTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='seafile-backup-test-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.data = self.root / 'data'
        for name in ('conf', 'seafile-data', 'seahub-data'):
            (self.data / name).mkdir(parents=True)
            (self.data / name / 'sample').write_text(name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        dump = self.bin / 'mysqldump'
        dump.write_text('#!/bin/sh\n[ "$FAIL_DUMP" != 1 ] || exit 1\nprintf "CREATE DATABASE test;\\n"\n')
        dump.chmod(0o755)
        with patch.dict(os.environ, {'INIT_SEAFILE_MYSQL_ROOT_PASSWORD': 'p"ass\\word',
                                     'SEAFILE_MYSQL_DB_HOST': 'db'}, clear=True):
            bootstrap.ensure_backup_credentials(str(self.data / 'conf'))
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                        SEAFILE_BACKUP_ROOT=str(self.root / 'backups'),
                        SEAFILE_BACKUP_DATA_ROOT=str(self.data), FAIL_DUMP='0')

    def run_backup(self):
        return subprocess.run(['bash', str(backup_script)], env=self.env,
                              capture_output=True, text=True)

    def test_success_creates_private_complete_backup(self):
        cred = self.data / 'conf/.backup-mysql.cnf'
        self.assertEqual(cred.stat().st_mode & 0o777, 0o600)
        self.assertIn('password="p\\"ass\\\\word"', cred.read_text())
        result = self.run_backup()
        self.assertEqual(result.returncode, 0, result.stderr)
        backups = list((self.root / 'backups').glob('20*'))
        self.assertEqual(len(backups), 1)
        self.assertEqual({p.name for p in backups[0].iterdir()},
                         {'COMPLETE', 'all-dbs.sql.gz', 'data.tar.gz'})
        subprocess.run(['tar', '-tzf', str(backups[0] / 'data.tar.gz')], check=True,
                       stdout=subprocess.DEVNULL)

    def test_failed_dump_leaves_no_completed_or_partial_backup(self):
        self.env['FAIL_DUMP'] = '1'
        result = self.run_backup()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list((self.root / 'backups').iterdir()), [])

    def test_missing_credentials_fails_closed(self):
        (self.data / 'conf/.backup-mysql.cnf').unlink()
        self.assertNotEqual(self.run_backup().returncode, 0)

    def test_overlapping_backup_is_rejected(self):
        (self.root / 'backups/.backup-lock').mkdir(parents=True)
        self.assertNotEqual(self.run_backup().returncode, 0)

    def test_cron_env_is_private_on_creation_and_existing_file(self):
        conf = self.data / 'conf'
        env_file = conf / '.env'
        with patch.dict(os.environ, {'JWT_PRIVATE_KEY': 'jwt-value'}, clear=True):
            bootstrap.ensure_cron_env(str(conf))
            self.assertEqual(env_file.stat().st_mode & 0o777, 0o600)
            env_file.chmod(0o644)
            bootstrap.ensure_cron_env(str(conf))
        self.assertEqual(env_file.stat().st_mode & 0o777, 0o600)
        self.assertIn('JWT_PRIVATE_KEY=jwt-value', env_file.read_text())

if __name__ == '__main__':
    unittest.main(verbosity=2)
