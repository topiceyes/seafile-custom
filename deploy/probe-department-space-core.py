"""Run through manage.py shell in a disposable/local development stack only.

Creates two temporary users and a library, checks the real CE adapter, and
removes all test resources in finally. Does not read existing user files.
"""
import uuid
from types import SimpleNamespace

from seaserv import seafile_api
from seahub.base.accounts import User
from seahub.department_spaces.backend import SeafileBackend

backend = SeafileBackend()
provision_id = uuid.uuid4()
owner = None
member = None
repo_id = None
try:
    owner = backend.ensure_owner(provision_id)
    assert backend.ensure_owner(provision_id) == owner
    member = backend.ensure_owner(uuid.uuid4())
    space = SimpleNamespace(provision_id=provision_id, owner=owner, repo_id=None,
                            department=SimpleNamespace(name='部门空间接口验证'))
    repo_id = backend.ensure_repo(space)
    space.repo_id = repo_id
    assert backend.ensure_repo(space) == repo_id
    assert backend.ensure_repo(SimpleNamespace(
        provision_id=provision_id, owner=owner, repo_id=None,
        department=space.department)) == repo_id
    assert not seafile_api.check_permission(repo_id, member)
    backend.grant(space, member)
    assert seafile_api.check_permission(repo_id, member) == 'rw'
    backend.grant(space, member)
    assert seafile_api.check_permission(repo_id, member) == 'rw'
    backend.revoke(space, member)
    assert not seafile_api.check_permission(repo_id, member)
    backend.revoke(space, member)
    print('CE_CORE_PROBE_OK: owner, provisioning recovery, idempotent grant/revoke, native rw access')
finally:
    if owner:
        for repo in seafile_api.get_owned_repo_list(owner):
            seafile_api.remove_repo(repo.id)
    for username in (member, owner):
        if username:
            User.objects.get(email=username).delete()
    print('CE_CORE_PROBE_CLEANED')
