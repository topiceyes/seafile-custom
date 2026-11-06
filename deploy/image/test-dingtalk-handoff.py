#!/usr/bin/env python3
"""Check the additive migration and real SSO views without any business DB/RPC."""
import argparse
from copy import deepcopy
from io import StringIO
import os
from pathlib import Path
import runpy
import sys
import tempfile
import unittest

parser = argparse.ArgumentParser()
parser.add_argument('--source', required=True)
parser.add_argument('--tests-dir')
parser.add_argument('--artifacts-dir')
parser.add_argument('--locale-dir')
args = parser.parse_args()
source = Path(args.source).resolve()
tests_dir = Path(args.tests_dir) if args.tests_dir else source / 'tests/seahub/views'
sys.path[:0] = [str(source), str(source / 'thirdpart'),
                str(source.parent / 'seafile/lib/python3/site-packages')]
with tempfile.TemporaryDirectory(prefix='dingtalk-handoff-') as temporary:
    conf = Path(temporary)
    (conf / 'seafile.conf').write_text('[fileserver]\nport=8082\n')
    (conf / 'seahub_settings.py').write_text(
        'SECRET_KEY="handoff-isolated-test"\n'
        'DATABASES={"default":{"ENGINE":"django.db.backends.sqlite3","NAME":":memory:"}}\n'
        'CACHES={"default":{"BACKEND":"django.core.cache.backends.locmem.LocMemCache"}}\n'
        'SERVICE_URL="https://canonical.example.test"\n'
        'CLIENT_SSO_VIA_LOCAL_BROWSER=True\n')
    os.environ.update(SEAFILE_CENTRAL_CONF_DIR=temporary, CCNET_CONF_DIR=temporary,
                      SEAFILE_CONF_DIR=temporary, SEAFILE_RPC_PIPE_PATH=temporary,
                      CACHE_PROVIDER='memcached', EVENTS_CONFIG_FILE=str(conf / 'no-events.conf'),
                      DJANGO_SETTINGS_MODULE='seahub.settings')
    import django
    django.setup()
    from django.conf import settings
    from django.core.management import call_command
    from django.db import connection
    from django.db.migrations.executor import MigrationExecutor
    from django.db.migrations.recorder import MigrationRecorder
    from django.test import override_settings
    from seahub.base.models import ClientSSOToken

    # Simulate the SQL-initialized legacy base history. Do not fake or execute it
    # on a deployed database; only the independent DingTalk migration may run.
    recorder = MigrationRecorder(connection)
    for name in ['0001_initial', '0002_reposecretkey',
                 '0003_auto_20181016_1242', '0004_auto_20191125_1555']:
        recorder.record_applied('base', name)
    recorder.record_applied('tags', '0001_initial')
    with connection.schema_editor() as editor:
        editor.create_model(ClientSSOToken)
    legacy = recorder.applied_migrations()
    target = [('dingtalk', '0001_client_sso_handoff')]
    executor = MigrationExecutor(connection)
    plan = executor.migration_plan(target)
    assert [(migration.app_label, migration.name) for migration, backwards in plan] == target
    executor.migrate(target)
    assert not MigrationExecutor(connection).migration_plan(target)
    assert set(recorder.applied_migrations()) - set(legacy) == set(target)
    call_command('makemigrations', 'dingtalk', check=True, dry_run=True, verbosity=0)
    sql = StringIO()
    call_command('sqlmigrate', 'dingtalk', '0001_client_sso_handoff', stdout=sql)
    assert 'CREATE TABLE "dingtalk_clientssohandoff"' in sql.getvalue()
    assert 'base_' not in sql.getvalue()
    print('DINGTALK_HANDOFF_MIGRATION_OK')

    # Keep template rendering real, excluding RPC-backed global site context.
    templates = deepcopy(settings.TEMPLATES)
    for template in templates:
        template.setdefault('OPTIONS', {})['context_processors'] = [
            'django.template.context_processors.i18n',
            'django.template.context_processors.request',
        ]
    locale_paths = ([args.locale_dir] if args.locale_dir else []) + list(settings.LOCALE_PATHS)
    with override_settings(TEMPLATES=templates, LOCALE_PATHS=locale_paths):
        suite = unittest.TestSuite()
        for file, case in [('test_dingtalk_handoff.py', 'DingTalkHandoffTest'),
                           ('test_client_sso_origin.py', 'ClientSSOOriginTest')]:
            module = runpy.run_path(str(tests_dir / file))
            suite.addTests(unittest.defaultTestLoader.loadTestsFromTestCase(module[case]))
        result = unittest.TextTestRunner(verbosity=2).run(suite)
        if not result.wasSuccessful():
            sys.exit(1)
        if args.artifacts_dir:
            from django.template import engines
            output = Path(args.artifacts_dir)
            output.mkdir(parents=True, exist_ok=True)
            from django.utils.translation import activate
            activate('zh-cn')
            for name in ['client_dingtalk_launch', 'client_dingtalk_landing', 'client_dingtalk_error']:
                html = engines['django'].get_template(name + '.html').render({
                    'LANGUAGE_CODE': 'zh-cn', 'site_title': 'Seafile',
                    'MEDIA_URL': '/media/', 'logo_path': 'img/seafile-logo.png',
                    'logo_width': 149, 'logo_height': 32, 'branding_css': '',
                    'dingtalk_link': 'dingtalk://dingtalkclient/page/link?url=https%3A%2F%2Fexample.test%2F',
                })
                (output / (name + '.html')).write_text(html)
    print('DINGTALK_HANDOFF_TESTS_OK', result.testsRun)
