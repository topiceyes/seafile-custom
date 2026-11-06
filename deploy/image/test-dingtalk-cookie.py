#!/usr/bin/env python3
"""Exercise both actual DingTalk callback bodies with isolated service doubles."""
import argparse
import ast
import base64
import hashlib
import hmac
import json
import logging
from pathlib import Path
import time
from types import SimpleNamespace
import unittest
from unittest.mock import Mock
import urllib.parse

parser = argparse.ArgumentParser()
parser.add_argument('--source', required=True)
args = parser.parse_args()
source = Path(args.source) / 'seahub/dingtalk/views.py'
tree = ast.parse(source.read_text(encoding='utf-8'))
functions = [node for node in tree.body if isinstance(node, ast.FunctionDef)
             and node.name in ('dingtalk_login_redirect', 'dingtalk_callback', 'dingtalk_callback_new')]
assert len(functions) == 3
module = ast.Module(body=functions, type_ignores=[])

class Response:
    def __init__(self, location):
        self.location = location
        self.cookies = {}
    def delete_cookie(self, name):
        self.cookies[name] = {'value': '', 'max_age': 0}

class DingTalkCookieTest(unittest.TestCase):
    def test_callbacks_authenticate_without_issuing_token(self):
        for modern in (False, True):
            for destination in ('/', '/client-sso/example/complete/?shib_platform=mac'):
                with self.subTest(modern=modern, destination=destination):
                    user = SimpleNamespace(username='user@example.test', is_active=True)
                    profile = SimpleNamespace(nickname='name', contact_email='', save=Mock())
                    login = Mock()
                    ns = dict(
                        time=time, base64=base64, hmac=hmac, sha256=hashlib.sha256,
                        urllib=urllib, json=json, logger=logging.getLogger('test'), _=lambda s: s,
                        is_dingtalk_enabled=lambda: True,
                        get_dingtalk_app_key=lambda: 'key' if modern else '',
                        get_dingtalk_app_secret=lambda: 'secret' if modern else '',
                        DINGTALK_QR_CONNECT_APP_SECRET='secret', DINGTALK_QR_CONNECT_APP_ID='id',
                        DINGTALK_QR_CONNECT_USER_INFO_URL='https://example.test/legacy',
                        DINGTALK_QR_CONNECT_LOGIN_REMEMBER_ME=True,
                        DINGTALK_OAUTH_GRANT_TYPE='authorization_code',
                        DINGTALK_OAUTH_USER_ACCESS_TOKEN_URL='https://example.test/token',
                        DINGTALK_GET_USER_INFO_URL='https://example.test/users/',
                        requests=SimpleNamespace(
                            RequestException=type('RequestException', (Exception,), {}),
                            post=Mock(return_value=SimpleNamespace(raise_for_status=lambda: None, json=lambda: {'accessToken': 'oauth', 'user_info': {'unionid': 'uid'}})),
                            get=Mock(return_value=SimpleNamespace(raise_for_status=lambda: None, json=lambda: {'unionId': 'uid', 'nick': 'name'}))),
                        SocialAuthUser=SimpleNamespace(objects=SimpleNamespace(get_by_provider_and_uid=lambda *a: SimpleNamespace(username=user.username))),
                        auth=SimpleNamespace(authenticate=lambda **kw: user, login=login),
                        User=SimpleNamespace(DoesNotExist=type('DoesNotExist', (Exception,), {})),
                        Profile=SimpleNamespace(objects=SimpleNamespace(get_profile_by_user=lambda email: profile)),
                        dingtalk_get_detailed_user_info=lambda uid: {},
                        dingtalk_get_userid_by_unionid_new=lambda uid: 'userid',
                        dingtalk_get_detailed_user_info_new=lambda uid: {},
                        _dingtalk_detailed_name=lambda info: '',
                        _pick_display_name=lambda detail, nick, previous: previous,
                        HttpResponseRedirect=Response,
                        url_has_allowed_host_and_scheme=Mock(return_value=True),
                    )
                    exec(compile(module, str(source), 'exec'), ns)
                    request = SimpleNamespace(GET={'state': 'state', 'authCode': 'code', 'code': 'code'},
                                              get_host=lambda: 'service.example.test', is_secure=lambda: True,
                                              session={'dingtalk_login_state': 'state', 'dingtalk_login_redirect': destination})
                    response = ns['dingtalk_callback'](request)
                    login.assert_called_once_with(request, user)
                    self.assertEqual(response.location, destination)
                    ns['url_has_allowed_host_and_scheme'].assert_called_once_with(
                        destination, allowed_hosts={'service.example.test'}, require_https=True)
                    self.assertEqual(response.cookies, {'seahub_auth': {'value': '', 'max_age': 0}})
                    self.assertIs(request.user, user)

    def test_redirect_rejects_a_disallowed_destination(self):
        check = Mock(return_value=False)
        ns = {'url_has_allowed_host_and_scheme': check}
        exec(compile(module, str(source), 'exec'), ns)
        request = SimpleNamespace(session={'dingtalk_login_redirect': 'https://evil.example/'},
                                  get_host=lambda: 'service.example.test', is_secure=lambda: True)
        self.assertEqual(ns['dingtalk_login_redirect'](request), '/')

unittest.main(argv=[__file__], verbosity=2)
