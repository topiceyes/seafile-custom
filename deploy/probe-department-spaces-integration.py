"""Disposable local-stack integration probe. Requires an empty department-space app.

Uses real CE libraries, shares and Django APIs, then removes all fixture data.
Existing user files and manual groups are never changed.
"""
import uuid

from seaserv import seafile_api, ccnet_api
from rest_framework.test import APIRequestFactory, force_authenticate
from seahub.auth.models import SocialAuthUser
from seahub.base.accounts import User
from seahub.department_spaces.backend import SeafileBackend
from seahub.department_spaces.models import AccessGrant, AuditEvent, Department, Space, SyncRun
from seahub.department_spaces.services import sync_directory, compensate_login
from seahub.department_spaces.views import SpacesView, SpaceDetailView

assert not Department.objects.exists(), 'Use an empty disposable department-space database.'
backend = SeafileBackend()
tag = str(uuid.uuid4())
accounts = {}
fixture_users = []
try:
    for label in ('alice', 'director', 'finance-director'):
        accounts[label] = backend.ensure_owner(uuid.uuid4())
        fixture_users.append(accounts[label])
    def dept(name, parent, members=(), managers=()):
        ident = lambda label: (tag + '-' + label, {'name': label, 'userid': tag + label})
        return {'name': name, 'parent_id': parent,
                'members': dict(ident(x) for x in members),
                'managers': dict(ident(x) for x in managers)}
    parent, child, unrelated = tag + '-parent', tag + '-child', tag + '-finance'
    snapshot = {'1': dept('测试根', ''),
                parent: dept('测试研发', '1', (), ('director',)),
                child: dept('测试平台', parent, ('alice',)),
                unrelated: dept('测试财务', '1', (), ('finance-director',))}
    group_count = len(ccnet_api.get_all_groups(-1, -1))
    mapped = {tag + '-' + label: username for label, username in accounts.items() if label != 'alice'}
    assert sync_directory(snapshot, backend, mapped, actor='integration-probe')['errors'] == 0
    platform = Space.objects.get(department__external_id=child)
    repo_id = platform.repo_id
    assert seafile_api.check_permission(repo_id, accounts['director']) == 'rw'
    assert not seafile_api.check_permission(repo_id, accounts['finance-director'])
    assert not seafile_api.check_permission(repo_id, accounts['alice'])

    SocialAuthUser.objects.add(accounts['alice'], 'dingtalk', tag + '-alice')
    compensate_login(accounts['alice'])
    assert seafile_api.check_permission(repo_id, accounts['alice']) == 'rw'
    factory = APIRequestFactory()
    def request(view, user, space=None, method='get', data=None):
        req = getattr(factory, method)('/api/v2.1/department-spaces/', data, format='json')
        force_authenticate(req, user=User.objects.get(email=user))
        return view.as_view()(req, **({'space_id': space.pk} if space else {}))
    result = request(SpacesView, accounts['alice'])
    assert len(result.data['spaces']) == 1 and result.data['spaces'][0]['id'] == platform.pk
    detail = request(SpaceDetailView, accounts['alice'], platform)
    assert detail.status_code == 200 and not detail.data['can_manage']
    denied = request(SpaceDetailView, accounts['alice'], platform, 'patch', {'description': 'bad'})
    assert denied.status_code == 403
    allowed = request(SpaceDetailView, accounts['director'], platform, 'patch', {'description': 'validated'})
    assert allowed.status_code == 200
    mapped[tag + '-alice'] = accounts['alice']
    snapshot[child]['parent_id'] = unrelated
    assert sync_directory(snapshot, backend, mapped, allow_large_changes=True)['errors'] == 0
    platform.refresh_from_db()
    assert platform.repo_id == repo_id
    assert not seafile_api.check_permission(repo_id, accounts['director'])
    assert seafile_api.check_permission(repo_id, accounts['finance-director']) == 'rw'
    assert seafile_api.check_permission(repo_id, accounts['alice']) == 'rw'
    assert len(ccnet_api.get_all_groups(-1, -1)) == group_count
    print('DEPARTMENT_SPACE_INTEGRATION_OK: real core, first-login grant, API isolation, inherited management, reparent revocation, no groups created')
finally:
    custodians = list(Space.objects.exclude(owner='').values_list('owner', flat=True))
    for username in custodians:
        for repo in seafile_api.get_owned_repo_list(username):
            seafile_api.remove_repo(repo.id)
    SocialAuthUser.objects.filter(username__in=fixture_users, provider='dingtalk').delete()
    AccessGrant.objects.all().delete()
    AuditEvent.objects.all().delete()
    Space.objects.all().delete()
    Department.objects.all().delete()
    SyncRun.objects.all().delete()
    for username in fixture_users + custodians:
        User.objects.get(email=username).delete()
    print('DEPARTMENT_SPACE_INTEGRATION_CLEANED')
