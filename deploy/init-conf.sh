#!/usr/bin/env bash
# 配置管理：**仅 dev**。生产不再需要这个脚本（见下面 --prod 的说明）。
#
#   ./init-conf.sh           dev 模式：把 conf-templates/ 渲染进数据卷（仅渲染尚不存在的文件）
#   ./init-conf.sh --force   dev 模式：覆盖已存在的文件（会丢手工改动）
#   ./init-conf.sh --prod    已废弃，只会报错退出
#
# ## 为什么 dev 要预渲染、prod 不能
#
# 全新数据卷首启时，镜像内 setup-seafile-mysql.py 会用 open(seahub_settings.py, 'w')
# **无条件重写**全套配置（SECRET_KEY 随机生成、DB 密码取 DB_PASSWORD 环境变量、
# SERVICE_URL 取 SEAFILE_SERVER_* 环境变量）——生产上预渲染会被整体覆盖，所以这条路
# 走不通。而 dev 的数据卷早就初始化过了，setup 不会再跑，预渲染是安全的。
#
# 生产的那份「追加定制」原先也在这里（--prod）：先等首启完成，再追加，再重启两个服务。
# **2026-09-21 起整个搬进镜像**，由 deploy/image/custom_bootstrap.py 在容器启动时
# 自动完成 —— 时机是 setup 写完配置之后、seafile/seahub 起来之前，所以**不需要重启**，
# 而且每次启动都校验一遍（幂等）。手工步骤的真正问题不是麻烦，是忘了不会报错：
# SSO / 账号管控 / WebDAV 会静默失效，而页面照常打开。
#
# 数据卷位置读 .env 的 SEAFILE_VOLUME（缺省 ./seafile-data）。
# env 文件默认 .env；本地彩排用 ENV_FILE=.env.rehearsal 覆盖（dev 的 .env 不受影响）。
set -euo pipefail

cd "$(dirname "$0")"

ENV_FILE="${ENV_FILE:-.env}"

FORCE=0
PROD=0
NORESTART=0
for arg in "$@"; do
  case "$arg" in
    --force)      FORCE=1 ;;
    --prod)       PROD=1 ;;
    --no-restart) NORESTART=1 ;;
    # 注意 ${arg} 的花括号：写成 $arg 再跟中文括号，bash 会把括号并进变量名
    *) echo "未知参数：${arg}（支持 --force；--prod 已废弃）" >&2; exit 1 ;;
  esac
done

if [[ ! -f "$ENV_FILE" ]]; then
    echo "错误：找不到 deploy/${ENV_FILE}，请先 cp 对应模板并填入配置。" >&2
    exit 1
fi

python3 - "$FORCE" "$PROD" "$NORESTART" "$ENV_FILE" <<'PY'
import re, sys
from pathlib import Path

force, prod = sys.argv[1] == '1', sys.argv[2] == '1'
env_file = sys.argv[4]
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
    # --prod 已废弃（2026-09-21）。不是「改名」，是这件事整个搬进镜像了：
    # 追加配置的时机现在是 start.py 在 setup 写完配置之后、seafile/seahub 起来之前
    # 调用 custom_bootstrap.py —— 见 deploy/image/custom_bootstrap.py。
    # 所以 `docker compose up -d` 之后不需要再跑任何东西。
    #
    # 保留这个分支只为了给旧流程一个明确的说法：静默变成 no-op 的话，用旧镜像的人
    # 会以为配置已经追加好了，而实际上没有（SSO/账号管控/WebDAV 静默失效）。
    sys.exit(
        '错误：--prod 已废弃，不再需要。\n'
        '\n'
        '  二开定制的追加已搬进镜像：容器启动时由 custom_bootstrap.py 自动完成\n'
        '  （在 setup 写完配置之后、seafile/seahub 起来之前），所以\n'
        '\n'
        '      docker compose up -d\n'
        '\n'
        '  之后不需要再跑任何东西。幂等，每次启动都会校验一遍。\n'
        '\n'
        '  看到这条说明你用的还是旧镜像。换成含此改动的镜像即可（tag 见 docs/010 §9）。\n'
        '  若确实要手工追加（例如临时绕过），用旧版脚本：git show <旧提交>:deploy/init-conf.sh'
    )
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
