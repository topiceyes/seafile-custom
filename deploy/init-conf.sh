#!/usr/bin/env bash
# 把 conf-templates/ 渲染进运行时数据卷（seafile-data/）。
#
# 仓库里只存模板（无密钥），真实配置由本脚本从 .env 取值生成，
# 生成物位于 seafile-data/ 下 —— 该目录不入库。
#
#   ./init-conf.sh           仅渲染尚不存在的文件
#   ./init-conf.sh --force   覆盖已存在的文件（会丢手工改动）
set -euo pipefail

cd "$(dirname "$0")"

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

if [[ ! -f .env ]]; then
    echo "错误：找不到 deploy/.env，请先 cp .env.example .env 并填入配置。" >&2
    exit 1
fi

SHARED="seafile-data"
CONF_DIR="$SHARED/seafile/conf"
NGINX_DIR="$SHARED/nginx/conf"

# 渲染：用 .env 中的值替换模板里的 __PLACEHOLDER__
python3 - "$FORCE" <<'PY'
import os, re, shutil, sys
from pathlib import Path

force = sys.argv[1] == '1'
root = Path('.')

# 读 .env（形如 KEY='value' 或 KEY=value，忽略注释）
env = {}
for line in (root / '.env').read_text().splitlines():
    line = line.strip()
    if not line or line.startswith('#') or '=' not in line:
        continue
    k, v = line.split('=', 1)
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
        v = v[1:-1]
    env[k.strip()] = v

def render(text):
    def sub(m):
        key = m.group(1)
        if key not in env or env[key] == '':
            sys.exit(f"错误：.env 中缺少 {key}（模板占位符 __{key}__ 无法替换）")
        return env[key]
    return re.sub(r'__([A-Z0-9_]+)__', sub, text)

targets = [
    ('conf-templates/seahub_settings.py',      'seafile-data/seafile/conf/seahub_settings.py'),
    ('conf-templates/seafevents.conf',         'seafile-data/seafile/conf/seafevents.conf'),
    ('conf-templates/seafile.conf',            'seafile-data/seafile/conf/seafile.conf'),
    ('conf-templates/seafdav.conf',            'seafile-data/seafile/conf/seafdav.conf'),
    ('conf-templates/gunicorn.conf.py',        'seafile-data/seafile/conf/gunicorn.conf.py'),
    ('conf-templates/nginx/seafile.nginx.conf','seafile-data/nginx/conf/seafile.nginx.conf'),
]

for src, dst in targets:
    dstp = root / dst
    if dstp.exists() and not force:
        print(f'  跳过（已存在）  {dst}')
        continue
    dstp.parent.mkdir(parents=True, exist_ok=True)
    dstp.write_text(render((root / src).read_text()))
    print(f'  生成           {dst}')
PY

echo
echo "完成。若配置有变动，执行以下命令生效："
echo "  docker exec seafile /opt/seafile/seafile-server-latest/seahub.sh restart   # seahub 配置"
echo "  docker exec seafile /opt/seafile/seafile-server-latest/seafile.sh restart  # seafile/webdav 配置"
