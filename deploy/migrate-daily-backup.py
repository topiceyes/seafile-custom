#!/usr/bin/env python3
"""Move production daily backups to /home, retaining the original copy.

Run without arguments to inspect the plan; --apply copies, checks, and switches.
Requires root, Python 3, rsync, Docker and the existing production Compose files.
"""
import argparse
import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time


DEPLOY = Path('/opt/seafile-custom/deploy')
TARGET = Path('/home/seafile-daily-backups')
COMPOSE = DEPLOY / 'seafile-prod.yml'
LOCK = Path('/var/lib/seafile-project-ops/lock')
MOUNT = '      - /home/seafile-daily-backups:/shared/backup'


def run(args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


def output(args):
    return run(args, capture_output=True).stdout.strip()


def atomic_write(path, data, mode):
    fd, temporary = tempfile.mkstemp(prefix='.backup-migration-', dir=str(path.parent))
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, 'w') as fp:
            fp.write(data)
        os.replace(temporary, str(path))
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    if os.geteuid() != 0:
        raise RuntimeError('Run in the 198 server root terminal.')
    for command in ('docker', 'rsync', 'du', 'findmnt'):
        if not shutil.which(command):
            raise RuntimeError('Missing command: ' + command)
    docker = ['docker']
    inspect = json.loads(output(docker + ['inspect', 'seafile']))[0]
    if not inspect['State']['Running']:
        raise RuntimeError('Seafile is not running.')
    environment = dict(item.split('=', 1) for item in inspect['Config'].get('Env', []) if '=' in item)
    if environment.get('SEAFILE_BACKUP_ROOT', '/shared/backup') != '/shared/backup':
        raise RuntimeError('A custom backup output path is already configured; manual review required.')
    if any(m['Destination'] == '/shared/backup' for m in inspect['Mounts']):
        raise RuntimeError('A dedicated backup mount already exists; inspect it before migrating again.')
    shared = [m for m in inspect['Mounts'] if m['Destination'] == '/shared' and m['Type'] == 'bind']
    if len(shared) != 1:
        raise RuntimeError('Expected one bind mount at /shared.')
    source = Path(shared[0]['Source']) / 'backup'
    if source.is_symlink() or TARGET.is_symlink():
        raise RuntimeError('Backup source or target is a symlink; manual review required.')
    if source.exists() and not source.is_dir():
        raise RuntimeError('Backup source is not a directory.')
    if TARGET.exists() and (not TARGET.is_dir() or any(TARGET.iterdir())):
        raise RuntimeError('Target contains files; no merge or overwrite will be performed.')
    if (source / '.backup-lock').exists():
        raise RuntimeError('Backup is running or has a stale lock; inspect before migrating.')
    text = COMPOSE.read_text()
    anchor = '      - ${SEAFILE_VOLUME}:/shared'
    if text.count(anchor) != 1 or '/shared/backup' in text:
        raise RuntimeError('Unexpected Compose layout; no files changed.')
    changed = text.replace(anchor, anchor + '\n' + MOUNT, 1)
    compose_binary = ['docker', 'compose']
    if subprocess.run(compose_binary + ['version'], stdout=subprocess.DEVNULL,
                      stderr=subprocess.DEVNULL).returncode:
        if not shutil.which('docker-compose'):
            raise RuntimeError('Compose is unavailable.')
        compose_binary = ['docker-compose']
    compose = compose_binary + ['--env-file', str(DEPLOY / '.env'), '-f', str(COMPOSE)]
    image_id = inspect['Image']
    env = dict(os.environ, SEAFILE_PRO_IMAGE=image_id)
    run(compose + ['config', '-q'], env=env, cwd=str(DEPLOY))
    print('Source:', source, flush=True)
    print('Target:', TARGET, flush=True)
    print('Pinned existing image:', image_id, flush=True)
    print('Target filesystem:', output(['findmnt', '-n', '-o', 'SOURCE,TARGET', '-T', '/home']), flush=True)
    needed = int(output(['du', '-sk', str(source)]).split()[0]) * 1024 if source.exists() else 0
    if shutil.disk_usage('/home').free < needed + 2 * 1024 ** 3:
        raise RuntimeError('Insufficient target free space for copy plus 2 GiB reserve.')
    if not args.apply:
        print('PLAN_OK: --apply copies and checks backups, then recreates only Seafile. Original backups remain.')
        return
    with LOCK.open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        source.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(str(source), 0o700)
        TARGET.mkdir(mode=0o700, exist_ok=True)
        os.chmod(str(TARGET), 0o700)
        held = []
        switched = False
        original_saved = None
        try:
            # Both paths stay locked until the container has the new mount.
            for root in (source, TARGET):
                guard = root / '.backup-lock'
                guard.mkdir(mode=0o700)
                held.append(guard)
            run(['rsync', '-a', '--exclude=/.backup-lock', str(source) + '/', str(TARGET) + '/'])
            print('COPY_DONE; checking every file by checksum...', flush=True)
            differences = output(['rsync', '-acn', '--itemize-changes', '--exclude=/.backup-lock',
                                  str(source) + '/', str(TARGET) + '/'])
            if differences:
                raise RuntimeError('Backup copy differs; original Compose and container retained.')
            original_saved = COMPOSE.with_name('seafile-prod.yml.before-daily-backup-' + time.strftime('%Y%m%d-%H%M%S'))
            with original_saved.open('x') as fp:
                os.chmod(str(original_saved), 0o600)
                fp.write(text)
            mode = COMPOSE.stat().st_mode & 0o777
            switched = True
            atomic_write(COMPOSE, changed, mode)
            run(compose + ['config', '-q'], env=env, cwd=str(DEPLOY))
            run(compose + ['up', '-d', '--no-deps', 'seafile'], env=env, cwd=str(DEPLOY))
            updated = json.loads(output(docker + ['inspect', 'seafile']))[0]
            mounts = [m for m in updated['Mounts'] if m['Destination'] == '/shared/backup']
            if updated['Image'] != image_id or len(mounts) != 1 or Path(mounts[0]['Source']) != TARGET:
                raise RuntimeError('New mount or pinned image verification failed.')
            probe = 'import urllib.request; assert urllib.request.urlopen("http://127.0.0.1/accounts/login/",timeout=5).status == 200'
            for attempt in range(60):
                if subprocess.run(docker + ['exec', 'seafile', 'python3', '-c', probe],
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
                    break
                time.sleep(3)
            else:
                raise RuntimeError('Web readiness timed out.')
            run(docker + ['exec', 'seafile', 'sh', '-ec',
                         'test -r /shared/seafile/conf/.backup-mysql.cnf; '
                         'test -f /etc/cron.d/seafile-backup; '
                         'test -x /usr/local/bin/seafile-backup.sh; '
                         'test -w /shared/backup'])
            print('MIGRATION_OK: dedicated mount, same image, cron present, credentials readable, WEB_LOGIN_200.', flush=True)
            print('Original backup directory retained:', source, flush=True)
            print('Original Compose saved:', original_saved, flush=True)
        except Exception:
            if switched:
                print('Restoring original Compose and current application image...', flush=True)
                atomic_write(COMPOSE, text, mode)
                run(compose + ['up', '-d', '--no-deps', 'seafile'], env=env, cwd=str(DEPLOY))
            raise
        finally:
            for guard in reversed(held):
                guard.rmdir()


if __name__ == '__main__':
    main()
