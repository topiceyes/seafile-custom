import importlib.util
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

path = Path(__file__).resolve().parent / 'custom_bootstrap.py'
spec = importlib.util.spec_from_file_location('handoff_bootstrap', path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
with patch('subprocess.run', return_value=SimpleNamespace(returncode=0, stdout='DINGTALK_SSO_SCHEMA_OK\n', stderr='')) as run:
    module.migrate_dingtalk_sso()
    command = run.call_args.args[0][-1]
    assert '["manage.py", "migrate", "dingtalk", "--noinput"]' in command
    assert 'migrate", "base' not in command
for result in [SimpleNamespace(returncode=0, stdout='Done.\n', stderr=''), SimpleNamespace(returncode=1, stdout='DINGTALK_SSO_SCHEMA_OK\n', stderr='')]:
    with patch('subprocess.run', return_value=result):
        try:
            module.migrate_dingtalk_sso()
        except RuntimeError:
            pass
        else:
            raise AssertionError('Migration failure was swallowed')
print('HANDOFF_BOOTSTRAP_SUCCESS_AND_FAILURE_OK')
