#!/usr/bin/env python3
"""Run a management command with an explicit success marker.

The upstream seahub.sh prints Done and returns 0 even when Python failed.
Cron must observe the Python outcome, not that wrapper's exit status alone.
"""
import subprocess
import sys

def run_task(arguments, runner=None):
    base = '/opt/seafile/seafile-server-latest'
    marker = 'SEAFILE_MANAGEMENT_TASK_OK'
    if not arguments:
        return 2
    program = (
        'import os; os.environ.setdefault("DJANGO_SETTINGS_MODULE", "seahub.settings"); '
        'from django.core.management import execute_from_command_line; '
        'execute_from_command_line(%r); print(%r)' % (['manage.py'] + arguments, marker)
    )
    result = (runner or subprocess.run)(
        [base + '/seahub.sh', 'python-env', 'python3', '-c', program],
        cwd=base + '/seahub', text=True, capture_output=True, timeout=3300)
    sys.stdout.write(result.stdout)
    sys.stderr.write(result.stderr)
    return int(bool(result.returncode or marker not in result.stdout.splitlines()))


if __name__ == '__main__':
    sys.exit(run_task(sys.argv[1:]))
