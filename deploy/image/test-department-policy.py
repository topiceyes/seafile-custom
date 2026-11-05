#!/usr/bin/env python3
"""Exercise the actual mutation guards with isolated RPC and model doubles."""
import argparse
import ast
from pathlib import Path
import sys
from types import ModuleType, SimpleNamespace
import unittest
from unittest.mock import Mock, patch

parser = argparse.ArgumentParser()
parser.add_argument('--source', required=True)
source = Path(parser.parse_args().source) / 'seahub'

class Denied(Exception):
    pass

def guard(repo_id):
    if repo_id == 'managed':
        raise Denied(repo_id)

def load_function(path, name, ns, class_name=None):
    tree = ast.parse(path.read_text(encoding='utf-8'))
    nodes = tree.body
    if class_name:
        nodes = next(n for n in nodes if isinstance(n, ast.ClassDef) and n.name == class_name).body
    node = next(n for n in nodes if isinstance(n, ast.FunctionDef) and n.name == name)
    node.decorator_list = []
    exec(compile(ast.Module(body=[node], type_ignores=[]), str(path), 'exec'), ns)
    return ns[name]

class PolicyTests(unittest.TestCase):
    def setUp(self):
        self.signals = ModuleType('seahub.department_spaces.signals')
        self.signals.deny_unmanaged_sharing = guard
        self.modules = patch.dict(sys.modules, {'seahub.department_spaces.signals': self.signals})
        self.modules.start()
        self.addCleanup(self.modules.stop)

    def test_share_and_permission_mutations_are_guarded_before_rpc(self):
        ns = {'PERMISSION_ADMIN': 'admin', 'PERMISSION_READ_WRITE': 'rw',
              'is_valid_org_id': lambda value: False, 'seafile_api': Mock(),
              'ExtraSharePermission': Mock(), 'ExtraGroupsSharePermission': Mock()}
        path = source / 'share/utils.py'
        repo = SimpleNamespace(repo_id='managed')
        cases = [('share_dir_to_user', (repo, '/', 'owner', 'owner', 'target', 'rw')),
                 ('share_dir_to_group', (repo, '/', 'owner', 'owner', 1, 'rw')),
                 ('update_user_dir_permission', ('managed', '/', 'owner', 'target', 'rw')),
                 ('update_group_dir_permission', ('managed', '/', 'owner', 1, 'rw'))]
        for name, args in cases:
            with self.subTest(name=name):
                func = load_function(path, name, ns)
                with self.assertRaises(Denied):
                    func(*args)
        self.assertEqual(ns['seafile_api'].method_calls, [])
        repo.repo_id = 'personal'
        ns['share_dir_to_user'](repo, '/', 'owner', 'owner', 'target', 'rw')
        ns['seafile_api'].share_repo.assert_called_once_with('personal', 'owner', 'target', 'rw')

    def test_legacy_share_and_transfer_stop_before_rpc(self):
        ns = {'seafile_api': Mock()}
        share = load_function(source / 'share/views.py', 'ajax_private_share_dir', ns)
        request = SimpleNamespace(POST={'repo_id': 'managed', 'path': '/'})
        with self.assertRaises(Denied):
            share(request)
        transfer = load_function(source / 'utils/__init__.py', 'transfer_repo', ns)
        with self.assertRaises(Denied):
            transfer('managed', 'someone', False)
        self.assertEqual(ns['seafile_api'].method_calls, [])

    def test_batch_share_filters_managed_libraries_before_lookup(self):
        model = ModuleType('seahub.department_spaces.models')
        model.Space = SimpleNamespace(objects=SimpleNamespace(filter=lambda **kw:
            SimpleNamespace(values_list=lambda *a, **kw: ['managed'])))
        data = SimpleNamespace(get=lambda key, default=None: {'operation': 'share'}.get(key, default),
                               getlist=lambda key: ['managed'])
        api = Mock()
        ns = {'Response': lambda obj: obj, 'seafile_api': api}
        post = load_function(source / 'api2/endpoints/repos_batch.py', 'post', ns, 'ReposBatchView')
        with patch.dict(sys.modules, {'seahub.department_spaces.models': model}):
            result = post(None, SimpleNamespace(data=data, user=SimpleNamespace(username='user')))
        self.assertEqual(result['success'], [])
        self.assertEqual(result['failed'][0]['repo_id'], 'managed')
        api.get_repo.assert_not_called()
        api.share_repo.assert_not_called()

    def test_batch_share_keeps_personal_library_in_mixed_request(self):
        model = ModuleType('seahub.department_spaces.models')
        model.Space = SimpleNamespace(objects=SimpleNamespace(filter=lambda **kw:
            SimpleNamespace(values_list=lambda *a, **kw: ['managed'])))
        fields = {'operation': 'share', 'share_type': 'user', 'username': 'target', 'permission': 'rw'}
        data = SimpleNamespace(get=lambda key, default=None: fields.get(key, default),
                               getlist=lambda key: ['managed', 'personal'])
        api = Mock()
        api.get_repo.return_value = SimpleNamespace(id='personal')
        ns = {'Response': lambda obj: obj, 'seafile_api': api,
              'get_repo_owner': lambda request, repo_id: 'owner',
              'get_available_repo_perms': lambda: ['rw'],
              'User': SimpleNamespace(objects=SimpleNamespace(get=Mock()), DoesNotExist=Exception),
              'ccnet_api': SimpleNamespace(get_orgs_by_user=lambda user: []),
              'is_org_context': lambda request: False,
              'share_repo_to_user_successful': SimpleNamespace(send=Mock()),
              'send_perm_audit_msg': Mock(), 'logger': Mock()}
        post = load_function(source / 'api2/endpoints/repos_batch.py', 'post', ns, 'ReposBatchView')
        view = SimpleNamespace(has_shared_to_user=lambda *args: False)
        with patch.dict(sys.modules, {'seahub.department_spaces.models': model}):
            result = post(view, SimpleNamespace(data=data, user=SimpleNamespace(username='owner')))
        self.assertEqual([x['repo_id'] for x in result['failed']], ['managed'])
        self.assertEqual([x['repo_id'] for x in result['success']], ['personal'])
        api.share_repo.assert_called_once_with('personal', 'owner', 'target', 'rw')

    def test_batch_unshare_can_remove_existing_managed_grant(self):
        model = ModuleType('seahub.department_spaces.models')
        model.Space = SimpleNamespace(objects=SimpleNamespace(filter=Mock()))
        fields = {'operation': 'unshare', 'share_type': 'user', 'username': 'target'}
        data = SimpleNamespace(get=lambda key, default=None: fields.get(key, default),
                               getlist=lambda key: ['managed'])
        api = Mock()
        ns = {'Response': lambda obj: obj, 'seafile_api': api,
              'get_repo_owner': lambda request, repo_id: 'owner',
              'is_org_context': lambda request: False,
              'check_user_share_out_permission': lambda *args: 'rw',
              'ExtraSharePermission': SimpleNamespace(objects=SimpleNamespace(delete_share_permission=Mock())),
              'send_perm_audit_msg': Mock(), 'logger': Mock()}
        post = load_function(source / 'api2/endpoints/repos_batch.py', 'post', ns, 'ReposBatchView')
        view = SimpleNamespace(has_shared_to_user=lambda *args: True)
        with patch.dict(sys.modules, {'seahub.department_spaces.models': model}):
            result = post(view, SimpleNamespace(data=data, user=SimpleNamespace(username='owner')))
        self.assertEqual([x['repo_id'] for x in result['success']], ['managed'])
        api.remove_share.assert_called_once_with('managed', 'owner', 'target')
        model.Space.objects.filter.assert_not_called()

if __name__ == '__main__':
    unittest.main(argv=[__file__], verbosity=2)
