#!/usr/bin/env python3
"""Run real file-transfer views with mocked RPC and no business DB or network."""
import argparse
import os
from pathlib import Path
import runpy
import sys
import tempfile
import unittest

parser = argparse.ArgumentParser()
parser.add_argument('--source', required=True)
args = parser.parse_args()
source = Path(args.source).resolve()
sys.path[:0] = [str(source), str(source / 'thirdpart'),
                str(source.parent / 'seafile/lib/python3/site-packages')]

with tempfile.TemporaryDirectory(prefix='fileserver-origin-') as temporary:
    conf = Path(temporary)
    (conf / 'seahub_settings.py').write_text(
        'SECRET_KEY="fileserver-origin-isolated-test"\n'
        'DATABASES={"default":{"ENGINE":"django.db.backends.sqlite3","NAME":":memory:"}}\n'
        'CACHES={"default":{"BACKEND":"django.core.cache.backends.locmem.LocMemCache"}}\n'
        'SERVICE_URL="https://canonical.example.test"\n')
    os.environ.update(
        SEAFILE_CENTRAL_CONF_DIR=temporary, CCNET_CONF_DIR=temporary,
        SEAFILE_CONF_DIR=temporary, SEAFILE_RPC_PIPE_PATH=temporary,
        CACHE_PROVIDER='memcached', DJANGO_SETTINGS_MODULE='seahub.settings')
    import django
    django.setup()
    module = runpy.run_path(str(source / 'tests/seahub/utils/test_fileserver_origin.py'))
    suite = unittest.TestSuite(unittest.defaultTestLoader.loadTestsFromTestCase(module[name])
                               for name in ['FileserverOriginTest', 'TransferEndpointOriginTest'])
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if not result.wasSuccessful():
        sys.exit(1)
    print('FILESERVER_ORIGIN_TESTS_OK', result.testsRun)
