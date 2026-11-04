#!/usr/bin/env python3
"""Run the new app against an isolated SQLite DB, never the development/production DB.

docker exec -i seafile python3 - --source /opt/seafile/seafile-server-latest/seahub \
  < deploy/test-department-spaces.py
"""
import argparse
import os
import sys
import types

parser = argparse.ArgumentParser()
parser.add_argument('--source', required=True)
parser.add_argument('--makemigrations', action='store_true')
args = parser.parse_args()
sys.path.insert(0, args.source)
sys.path.insert(0, os.path.join(args.source, 'thirdpart'))
# Seafile's package __init__ imports all server handlers. This test environment
# deliberately loads only the app under test, without RPC or the real DB config.
package = types.ModuleType('seahub')
package.__path__ = [os.path.join(args.source, 'seahub')]
sys.modules['seahub'] = package
from django.conf import settings
settings.configure(
    SECRET_KEY='department-space-isolated-tests',
    INSTALLED_APPS=['django.contrib.contenttypes', 'django.contrib.auth', 'seahub.department_spaces'],
    DATABASES={'default': {'ENGINE': 'django.db.backends.sqlite3', 'NAME': ':memory:'}},
    DEFAULT_AUTO_FIELD='django.db.models.AutoField', USE_TZ=True,
    ROOT_URLCONF='seahub.department_spaces.test_urls',
    REST_FRAMEWORK={'UNAUTHENTICATED_USER': None},
    MIDDLEWARE=[], ALLOWED_HOSTS=['testserver'],
)
import django
django.setup()
from django.core.management import call_command
if args.makemigrations:
    call_command('makemigrations', 'department_spaces')
else:
    call_command('makemigrations', 'department_spaces', check=True, dry_run=True)
    call_command('test', 'seahub.department_spaces.tests', verbosity=2)
