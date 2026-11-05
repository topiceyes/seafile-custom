#!/usr/bin/env python3
"""Run backup with temporary data and a simulated database dump."""
import importlib.util
import os
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import time

base = Path(__file__).resolve().parent
backup_script = base / 'backup.sh'
if not backup_script.exists():
    backup_script = Path('/usr/local/bin/seafile-backup.sh')
spec = importlib.util.spec_from_file_location('bootstrap', base / 'custom_bootstrap.py')
bootstrap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bootstrap)
status_script = base / 'backup-status.py'
if not status_script.exists():
    status_script = Path('/usr/local/libexec/backup-status.py')
status_spec = importlib.util.spec_from_file_location('backup_status', status_script)
backup_status = importlib.util.module_from_spec(status_spec)
status_spec.loader.exec_module(backup_status)

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

    def state(self):
        return json.loads((self.root / 'backups/.backup-status.json').read_text())

    def old_backups(self, count=8):
        root = self.root / 'backups'
        root.mkdir(exist_ok=True)
        result = []
        for day in range(1, count + 1):
            folder = root / ('202001%02d-000000' % day)
            folder.mkdir()
            for name in ('COMPLETE', 'all-dbs.sql.gz', 'data.tar.gz'):
                (folder / name).write_text('fixture')
            result.append(folder)
        return result

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
        self.assertEqual(self.state()['state'], 'success')
        self.assertTrue(backup_status.health(self.root / 'backups')['healthy'])
        self.assertEqual((self.root / 'backups/.backup-status.json').stat().st_mode & 0o777, 0o600)

    def test_failed_dump_leaves_no_completed_or_partial_backup(self):
        self.env['FAIL_DUMP'] = '1'
        result = self.run_backup()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual([p.name for p in (self.root / 'backups').iterdir()], ['.backup-status.json'])
        self.assertEqual(self.state()['state'], 'failed')
        self.assertEqual(self.state()['failed_phase'], 'database')

    def test_missing_credentials_fails_closed(self):
        (self.data / 'conf/.backup-mysql.cnf').unlink()
        self.assertNotEqual(self.run_backup().returncode, 0)
        self.assertEqual(self.state()['failed_phase'], 'preflight')

    def test_overlapping_backup_is_rejected(self):
        (self.root / 'backups/.backup-lock').mkdir(parents=True)
        self.assertNotEqual(self.run_backup().returncode, 0)
        self.assertFalse((self.root / 'backups/.backup-status.json').exists())

    def test_retention_keeps_newest_seven_and_ignores_unmanaged_directories(self):
        old = self.old_backups()
        unmanaged = self.root / 'backups/20190101-000000'
        unmanaged.mkdir()
        unrelated = self.root / 'backups/2020010100-000000'
        unrelated.mkdir()
        (unrelated / 'COMPLETE').write_text('fixture')
        link = self.root / 'backups/20200109-000000'
        link.symlink_to(old[-1], target_is_directory=True)
        result = self.run_backup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(old[0].exists())
        self.assertFalse(old[1].exists())
        self.assertTrue(all(p.exists() for p in old[2:]))
        self.assertTrue(unmanaged.exists())
        self.assertTrue(unrelated.exists())
        self.assertTrue(link.is_symlink())

    def test_failed_backup_does_not_prune_existing_backups(self):
        old = self.old_backups()
        self.env['FAIL_DUMP'] = '1'
        self.assertNotEqual(self.run_backup().returncode, 0)
        self.assertTrue(all(p.exists() for p in old))

    def test_later_failure_preserves_last_success_timestamp(self):
        self.assertEqual(self.run_backup().returncode, 0)
        previous = self.state()
        backup_status.record(self.root / 'backups', 'failed', time.time(), phase='database', exit_code=1)
        self.assertEqual(self.state()['last_success_at'], previous['last_success_at'])
        self.assertEqual(backup_status.health(self.root / 'backups')['reason'], 'last_attempt_failed')

    def test_health_rejects_overdue_missing_and_corrupt_backup_records(self):
        self.assertEqual(self.run_backup().returncode, 0)
        root = self.root / 'backups'
        state = self.state()
        self.assertEqual(backup_status.health(root, now=state['last_success_at'] + 31 * 3600)['reason'],
                         'last_success_overdue')
        (root / state['last_success_backup'] / 'data.tar.gz').unlink()
        self.assertEqual(backup_status.health(root)['reason'], 'success_record_invalid_or_files_missing')
        (root / '.backup-status.json').write_text('{broken')
        self.assertEqual(backup_status.health(root)['reason'], 'status_unreadable')

    def test_legacy_complete_backup_can_be_checked_before_first_status_record(self):
        folder = self.old_backups(count=1)[0]
        now = backup_status.datetime.strptime(folder.name, '%Y%m%d-%H%M%S').timestamp() + 3600
        self.assertTrue(backup_status.health(folder.parent, now=now)['healthy'])

    def test_no_success_and_long_running_backup_are_unhealthy(self):
        root = self.root / 'backups'
        root.mkdir()
        self.assertEqual(backup_status.health(root)['reason'], 'no_successful_backup')
        now = time.time()
        backup_status.record(root, 'running', now, pid=os.getpid())
        self.assertEqual(backup_status.health(root, now=now)['reason'], 'backup_in_progress')
        self.assertEqual(backup_status.health(root, now=now + 7 * 3600)['reason'], 'backup_running_too_long')

    def test_check_command_has_monitoring_exit_status(self):
        command = ['python3', str(status_script), 'check', '--root', str(self.root / 'backups')]
        empty = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(empty.returncode, 1)
        self.assertEqual(json.loads(empty.stdout)['reason'], 'no_successful_backup')
        self.assertEqual(self.run_backup().returncode, 0)
        success = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(success.returncode, 0)
        self.assertTrue(json.loads(success.stdout)['healthy'])

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
