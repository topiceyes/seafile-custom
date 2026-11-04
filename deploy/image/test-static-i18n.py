#!/usr/bin/env python3
"""Check the browser-served catalogs and hashed template URLs, without a database."""
import gettext
import json
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
sys.path.insert(0, str(root / 'thirdpart'))
assets = root / 'media/assets'
manifest = json.loads((assets / 'staticfiles.json').read_text())['paths']

for language, locale in [('zh-cn', 'zh_CN'), ('en', 'en')]:
    relative = 'scripts/i18n/%s/djangojs.js' % language
    hashed = manifest[relative]
    assert hashed != relative, 'Catalog URL must change when translations change'
    original = (assets / relative).read_text()
    assert (assets / hashed).read_text() == original
    match = re.search(r'(?:const|var) newcatalog = (\{.*?\});', original, re.S)
    assert match, 'Missing browser catalog: ' + language
    actual = json.loads(match.group(1))
    with (root / 'locale' / locale / 'LC_MESSAGES/djangojs.mo').open('rb') as source:
        expected = gettext.GNUTranslations(source)._catalog
    # Check every translated singular entry, not only existence of a generated file.
    for key, value in expected.items():
        if isinstance(key, str) and key and isinstance(value, str) and value:
            assert actual.get(key) == value, (language, key, actual.get(key), value)
    assert actual['Department sharing'] == ('部门共享' if language == 'zh-cn' else 'Department sharing')
    print('STATIC_I18N_CATALOG_OK', language, len(actual), hashed)

from django.conf import settings
settings.configure(
    DEBUG=False, STATIC_URL='/media/assets/', STATIC_ROOT=str(assets),
    INSTALLED_APPS=['django.contrib.staticfiles'], STORAGES={'staticfiles': {
        'BACKEND': 'django.contrib.staticfiles.storage.ManifestStaticFilesStorage'}},
)
import django
django.setup()
from django.template import Context, Engine
engine = Engine(libraries={'static': 'django.templatetags.static'})
for name in ['base_for_react.html', 'markdown_file_view_react.html',
             'plain_markdown_file_view_react.html', 'wiki/wiki_publish_ssr.html']:
    template = (root / 'seahub/templates' / name).read_text()
    match = re.search(r'{% with catalog_path=.*?{% endwith %}', template, re.S)
    assert match, 'Template does not use hashed catalogs: ' + name
    for language in ['zh-cn', 'en']:
        rendered = engine.from_string('{% load static %}' + match.group()).render(
            Context({'LANGUAGE_CODE': language}))
        assert '/media/assets/' + manifest['scripts/i18n/%s/djangojs.js' % language] in rendered
print('STATIC_I18N_TEMPLATE_URLS_OK')
