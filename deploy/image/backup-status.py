#!/usr/bin/env python3
"""Persist backup outcomes atomically and report health without database secrets."""
import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import re
import tempfile
import time

NAME = re.compile(r'^[0-9]{8}-[0-9]{6}$')
STATE_FILE = '.backup-status.json'


def read_state(root):
    path = root / STATE_FILE
    if not path.exists():
        return {}
    value = json.loads(path.read_text())
    if not isinstance(value, dict):
        raise ValueError('Invalid backup status object')
    return value


def save(root, state):
    fd, name = tempfile.mkstemp(prefix='.backup-status-', dir=str(root))
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, 'w') as fp:
            json.dump(state, fp, sort_keys=True)
            fp.write('\n')
            fp.flush()
            os.fsync(fp.fileno())
        os.replace(name, str(root / STATE_FILE))
    finally:
        if os.path.exists(name):
            os.unlink(name)


def record(root, event, now, **details):
    state = read_state(root)
    state.update(state=event, updated_at=now)
    if event == 'running':
        state.update(started_at=now, pid=details['pid'])
        state.pop('failed_phase', None)
        state.pop('exit_code', None)
    elif event == 'success':
        if not NAME.fullmatch(details['backup']):
            raise ValueError('Invalid backup directory name')
        state.update(last_success_at=now, last_success_backup=details['backup'])
    elif event == 'failed':
        state.update(failed_phase=details['phase'], exit_code=details['exit_code'])
    save(root, state)


def completed(root, name):
    directory = root / name
    return (NAME.fullmatch(name) is not None and not directory.is_symlink()
            and all((directory / file).is_file() and (directory / file).stat().st_size > 0
                    for file in ('COMPLETE', 'all-dbs.sql.gz', 'data.tar.gz')))


def health(root, now=None, max_age_hours=30, max_run_hours=6):
    now = time.time() if now is None else now
    result = {'healthy': False}
    try:
        state = read_state(root)
        result['state'] = state.get('state', 'unknown')
        last = state.get('last_success_at')
        backup = state.get('last_success_backup')
        # Existing 1.3.4 backups predate the status file; accept only complete sets.
        if last is None and root.is_dir():
            names = sorted(p.name for p in root.iterdir() if completed(root, p.name))
            if names:
                backup = names[-1]
                last = datetime.strptime(backup, '%Y%m%d-%H%M%S').timestamp()
        result.update(last_success_at=last, last_success_backup=backup)
        if state.get('state') == 'failed':
            result.update(reason='last_attempt_failed', failed_phase=state.get('failed_phase'),
                          exit_code=state.get('exit_code'))
        elif state.get('state') == 'running' and (
                now - state['started_at'] > max_run_hours * 3600):
            result['reason'] = 'backup_running_too_long'
        elif last is not None and (last > now + 300 or not completed(root, backup)):
            result['reason'] = 'success_record_invalid_or_files_missing'
        elif last is not None and now - last > max_age_hours * 3600:
            result['reason'] = 'last_success_overdue'
        elif last is None and state.get('state') != 'running':
            result['reason'] = 'no_successful_backup'
        else:
            result.update(healthy=True, reason='backup_in_progress' if state.get('state') == 'running' else 'ok')
    except (OSError, ValueError, TypeError, KeyError) as error:
        result.update(reason='status_unreadable', error=type(error).__name__)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    check = sub.add_parser('check')
    check.add_argument('--max-age-hours', type=float, default=30)
    check.add_argument('--max-run-hours', type=float, default=6)
    rec = sub.add_parser('record')
    rec.add_argument('event', choices=['running', 'success', 'failed'])
    rec.add_argument('--pid', type=int)
    rec.add_argument('--backup')
    rec.add_argument('--phase')
    rec.add_argument('--exit-code', type=int)
    for command in (check, rec):
        command.add_argument('--root', type=Path, default=Path(os.environ.get('SEAFILE_BACKUP_ROOT', '/shared/backup')))
    args = parser.parse_args()
    if args.command == 'record':
        record(args.root, args.event, time.time(), pid=args.pid, backup=args.backup,
               phase=args.phase, exit_code=args.exit_code)
        return 0
    result = health(args.root, max_age_hours=args.max_age_hours, max_run_hours=args.max_run_hours)
    print(json.dumps(result, sort_keys=True))
    return 0 if result['healthy'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
