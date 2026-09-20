#!/usr/bin/env bash
# 配置管理：dev 预渲染 / prod 首启后定制追加。
#
#   ./init-conf.sh           dev 模式：把 conf-templates/ 渲染进数据卷（仅渲染尚不存在的文件）
#   ./init-conf.sh --force   dev 模式：覆盖已存在的文件（会丢手工改动）
#   ./init-conf.sh --prod    prod 模式：在【已完成首次启动】的数据卷上追加二开定制项
#
# ⚠️ 为什么 prod 不能预渲染：全新数据卷首启时，镜像内 setup-seafile-mysql.py 会用
#    open(seahub_settings.py, 'w') 无条件重写全套配置（SECRET_KEY 随机生成、DB 密码取
#    DB_PASSWORD 环境变量、SERVICE_URL 取 SEAFILE_SERVER_* 环境变量）。预渲染的文件
#    会被整体覆盖。所以生产流程是：先用 compose 环境变量完成首启，再跑本脚本追加定制项。
#
# 数据卷位置读 .env 的 SEAFILE_VOLUME（缺省 ./seafile-data）。
# env 文件默认 .env；本地彩排用 ENV_FILE=.env.rehearsal 覆盖（dev 的 .env 不受影响）。
set -euo pipefail

cd "$(dirname "$0")"

ENV_FILE="${ENV_FILE:-.env}"

FORCE=0
PROD=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    --prod)  PROD=1 ;;
    *) echo "未知参数：$arg（支持 --force / --prod）" >&2; exit 1 ;;
  esac
done

if [[ ! -f "$ENV_FILE" ]]; then
    echo "错误：找不到 deploy/$ENV_FILE，请先 cp 对应模板并填入配置。" >&2
    exit 1
fi

python3 - "$FORCE" "$PROD" "$ENV_FILE" <<'PY'
import re, sys
from pathlib import Path

force, prod = sys.argv[1] == '1', sys.argv[2] == '1'
env_file = sys.argv[3]
root = Path('.')

env = {}
for line in (root / env_file).read_text().splitlines():
    line = line.strip()
    if not line or line.startswith('#') or '=' not in line:
        continue
    k, v = line.split('=', 1)
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
        v = v[1:-1]
    env[k.strip()] = v

shared = env.get('SEAFILE_VOLUME') or 'seafile-data'

if prod:
    # ---- prod：首启后定制追加（幂等）----
    conf = root / shared / 'seafile' / 'conf'

    if not (conf / 'seahub_settings.py').exists():
        sys.exit('错误：seahub_settings.py 不存在。prod 模式要在首次启动完成之后运行'
                 '（首启由镜像 setup 生成基础配置）。\n'
                 '       流程：docker compose up -d → 等待 seahub 启动完成 → ./init-conf.sh --prod')

    # 1) WebDAV：镜像默认 enabled = false
    seafdav = conf / 'seafdav.conf'
    if seafdav.exists() and 'enabled = true' not in seafdav.read_text():
        seafdav.write_text(re.sub(r'^enabled = .*$', 'enabled = true',
                                  seafdav.read_text(), flags=re.M))
        print('  修改           seafdav.conf enabled=true')

    # 2) seahub 自定义配置块（幂等：标记存在则跳过）
    MARKER = '# ---- 二开定制（init-conf.sh --prod 追加，勿手改本块）----'
    sspath = conf / 'seahub_settings.py'
    current = sspath.read_text()
    if MARKER in current:
        print('  跳过（已追加过） seahub_settings.py 定制块')
    else:
        block = f"""

{MARKER}
# 客户端（桌面/移动端）单点登录：通过本地浏览器完成（URL 在导入期注册，须写文件）
CLIENT_SSO_VIA_LOCAL_BROWSER = True

# 钉钉扫码登录（企业内部应用）。这三项已 constance 化，此处为默认值，后台可改（docs/002）
ENABLE_DINGTALK = True
DINGTALK_APP_KEY = '{env.get('SEAHUB_DINGTALK_APP_KEY', '')}'
DINGTALK_APP_SECRET = '{env.get('SEAHUB_DINGTALK_APP_SECRET', '')}'

# 账号管控
ENABLE_DELETE_ACCOUNT = False           # 禁止用户自助注销（docs/003）
# PASSWORD_LOGIN_ADMIN_ONLY = True     # 补丁 0008 默认即 True；紧急放开时取消注释改 False
"""
        sspath.write_text(current.rstrip() + '\n' + block)
        print('  追加           seahub_settings.py 定制块（钉钉/SSO/账号管控）')

    print('\n完成。生效命令（容器内）：')
    print('  docker exec seafile /opt/seafile/seafile-server-latest/seafile.sh restart   # seafdav')
    print('  docker exec seafile /opt/seafile/seafile-server-latest/seahub.sh restart   # seahub')
else:
    # ---- dev：预渲染（数据卷已初始化，setup 不会再跑）----
    def render(text):
        def sub(m):
            key = m.group(1)
            if key not in env or env[key] == '':
                sys.exit(f"错误：.env 中缺少 {key}（模板占位符 __{key}__ 无法替换）")
            return env[key]
        return re.sub(r'__([A-Z0-9_]+)__', sub, text)

    targets = [
        ('conf-templates/seahub_settings.py',       f'{shared}/seafile/conf/seahub_settings.py'),
        ('conf-templates/seafevents.conf',          f'{shared}/seafile/conf/seafevents.conf'),
        ('conf-templates/seafile.conf',             f'{shared}/seafile/conf/seafile.conf'),
        ('conf-templates/seafdav.conf',             f'{shared}/seafile/conf/seafdav.conf'),
        ('conf-templates/gunicorn.conf.py',         f'{shared}/seafile/conf/gunicorn.conf.py'),
        ('conf-templates/nginx/seafile.nginx.conf', f'{shared}/nginx/conf/seafile.nginx.conf'),
    ]
    for src, dst in targets:
        dstp = root / dst
        if dstp.exists() and not force:
            print(f'  跳过（已存在）  {dst}')
            continue
        dstp.parent.mkdir(parents=True, exist_ok=True)
        dstp.write_text(render((root / src).read_text()))
        print(f'  生成           {dst}')

    print('\n完成。若配置有变动，执行以下命令生效：')
    print('  docker exec seafile /opt/seafile/seafile-server-latest/seahub.sh restart   # seahub 配置')
    print('  docker exec seafile /opt/seafile/seafile-server-latest/seafile.sh restart  # seafile/webdav 配置')
PY
