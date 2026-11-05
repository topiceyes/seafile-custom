"""Local development only: real temporary account/library and byte round trip.

Run through manage.py shell in the local development container. File HTTP
requests connect only to loopback; Host simulates the two public entries.
"""
import hashlib
import http.client
import json
import os
import secrets
import ssl
import uuid
from unittest.mock import patch
from urllib.parse import urlsplit

from django.test import override_settings
from rest_framework.test import APIRequestFactory, force_authenticate
from seaserv import seafile_api
from seahub.api2.views import UploadLinkView, get_repo_file
from seahub.base.accounts import User

if os.environ.get('SEAFILE_SERVER_HOSTNAME') != '127.0.0.1':
    raise RuntimeError('This probe is restricted to the local development stack')


def file_request(url, method='GET', body=None, headers=None):
    parsed = urlsplit(url)
    connection = http.client.HTTPSConnection(
        '127.0.0.1', 443, context=ssl._create_unverified_context(), timeout=60)
    try:
        # Only the development self-signed loopback connection skips TLS checks.
        request_headers = dict(headers or {}, Host=parsed.netloc)
        connection.request(method, parsed.path + ('?' + parsed.query if parsed.query else ''),
                           body=body, headers=request_headers)
        response = connection.getresponse()
        return response.status, response.read()
    finally:
        connection.close()


identifier = uuid.uuid4().hex
username = 'origin-probe-%s@local.invalid' % identifier
repo_id = None
owner = None
try:
    owner = User.objects.create_user(username, secrets.token_urlsafe(32), is_active=True)
    repo_id = seafile_api.create_repo('Origin probe ' + identifier, 'Temporary local URL probe', owner.username, None)
    factory = APIRequestFactory()
    payload = secrets.token_bytes(8 * 1024 * 1024)
    expected_hash = hashlib.sha256(payload).hexdigest()
    with override_settings(ALLOWED_HOSTS=['m-disc.example.test', 'i-disc.example.test']), \
            patch('seahub.utils.get_service_url', return_value='https://canonical.example.test'):
        for host in ['m-disc.example.test', 'i-disc.example.test:7443']:
            request = factory.get('/api2/repos/%s/upload-link/' % repo_id,
                                  HTTP_HOST=host, secure=True)
            force_authenticate(request, user=owner)
            response = UploadLinkView.as_view(throttle_classes=[])(request, repo_id=repo_id)
            assert response.status_code == 200, response.status_code
            upload_url = response.data
            assert upload_url.startswith('https://%s/seafhttp/upload-api/' % host)
            boundary = 'origin-probe-' + uuid.uuid4().hex
            filename = 'entry-%s.bin' % host.replace(':', '-')
            body = (
                ('--%s\r\nContent-Disposition: form-data; name="parent_dir"\r\n\r\n/\r\n' % boundary).encode()
                + ('--%s\r\nContent-Disposition: form-data; name="file"; filename="%s"\r\n'
                   'Content-Type: application/octet-stream\r\n\r\n' % (boundary, filename)).encode()
                + payload + ('\r\n--%s--\r\n' % boundary).encode())
            code, content = file_request(upload_url, 'POST', body, {
                'Content-Type': 'multipart/form-data; boundary=' + boundary})
            assert code == 200, ('upload', host, code)
            file_id = seafile_api.get_file_id_by_path(repo_id, '/' + filename)
            assert file_id, 'Upload did not commit a file'
            request.user = owner
            response = get_repo_file(request, repo_id, file_id, filename, 'download')
            download_url = json.loads(response.content)
            assert download_url.startswith('https://%s/seafhttp/files/' % host)
            code, downloaded = file_request(download_url)
            assert code == 200, ('download', host, code)
            assert hashlib.sha256(downloaded).hexdigest() == expected_hash
            print('FILESERVER_ORIGIN_ROUNDTRIP_OK', host, len(downloaded), expected_hash)
finally:
    if repo_id:
        seafile_api.remove_repo(repo_id)
    if owner:
        owner.delete()
    print('FILESERVER_ORIGIN_PROBE_CLEANED')
