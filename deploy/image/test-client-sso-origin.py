#!/usr/bin/env python3
"""Exercise real SSO views and token persistence in an isolated SQLite DB."""
import argparse
import os
from pathlib import Path
import runpy
import sys
import tempfile
import unittest

parser = argparse.ArgumentParser()
parser.add_argument('--source', required=True)
source = Path(parser.parse_args().source).resolve()
sys.path[:0] = [str(source), str(source / 'thirdpart'),
                str(source.parent / 'seafile/lib/python3/site-packages')]
with tempfile.TemporaryDirectory(prefix='client-sso-origin-') as temporary:
    (Path(temporary) / 'seahub_settings.py').write_text(
        'SECRET_KEY="client-sso-isolated-test"\n'
        'DATABASES={"default":{"ENGINE":"django.db.backends.sqlite3","NAME":":memory:"}}\n'
        'CACHES={"default":{"BACKEND":"django.core.cache.backends.locmem.LocMemCache"}}\n'
        'SERVICE_URL="https://canonical.example.test"\n'
        'CLIENT_SSO_VIA_LOCAL_BROWSER=True\n')
    os.environ.update(
        SEAFILE_CENTRAL_CONF_DIR=temporary, CCNET_CONF_DIR=temporary,
        SEAFILE_CONF_DIR=temporary, SEAFILE_RPC_PIPE_PATH=temporary,
        CACHE_PROVIDER='memcached', DJANGO_SETTINGS_MODULE='seahub.settings')
    import django
    django.setup()
    from django.db import connection
    from seahub.base.models import ClientSSOToken
    with connection.schema_editor() as editor:
        editor.create_model(ClientSSOToken)
    module = runpy.run_path(str(source / 'tests/seahub/views/test_client_sso_origin.py'))
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(module['ClientSSOOriginTest'])
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if not result.wasSuccessful():
        sys.exit(1)
    print('CLIENT_SSO_ORIGIN_TESTS_OK', result.testsRun)
