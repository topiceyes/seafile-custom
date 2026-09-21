#!/usr/bin/env bash
# 配置管理：dev 预渲染 / prod 首启后定制追加。
#
#   ./init-conf.sh           dev 模式：把 conf-templates/ 渲染进数据卷（仅渲染尚不存在的文件）
#   ./init-conf.sh --force   dev 模式：覆盖已存在的文件（会丢手工改动）
#   ./init-conf.sh --prod    prod 模式：【一条命令做完】等首启 → 追加定制 → 重启 → 自检
#
# prod 模式可以直接跟在 `docker compose up -d` 后面跑，不需要先确认首启完成——
# 脚本自己会等（默认 300s，PROD_WAIT=<秒> 可改）。
#
#   SEAFILE_CONTAINER=<名>  容器名（默认 seafile）
#   --no-restart           只改文件不重启（用于手工控制生效时机）
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
NORESTART=0
for arg in "$@"; do
  case "$arg" in
    --force)      FORCE=1 ;;
    --prod)       PROD=1 ;;
    --no-restart) NORESTART=1 ;;
    # 注意 ${arg} 的花括号：写成 $arg 再跟中文括号，bash 会把括号并进变量名
    *) echo "未知参数：${arg}（支持 --force / --prod / --no-restart）" >&2; exit 1 ;;
  esac
done

if [[ ! -f "$ENV_FILE" ]]; then
    echo "错误：找不到 deploy/${ENV_FILE}，请先 cp 对应模板并填入配置。" >&2
    exit 1
fi

python3 - "$FORCE" "$PROD" "$NORESTART" "$ENV_FILE" <<'PY'
import os, re, shutil, subprocess, sys, time
from pathlib import Path

force, prod = sys.argv[1] == '1', sys.argv[2] == '1'
no_restart = sys.argv[3] == '1'
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
    # ---- prod：等首启完成 → 追加定制 → 重启 → 自检 ----
    conf = root / shared / 'seafile' / 'conf'
    sspath = conf / 'seahub_settings.py'
    container = os.environ.get('SEAFILE_CONTAINER', 'seafile')
    wait = int(os.environ.get('PROD_WAIT', '300'))

    if shutil.which('docker') is None:
        sys.exit('错误：找不到 docker 命令。prod 模式要用它确认首启状态、重启服务。')

    def docker(*args):
        return subprocess.run(('docker',) + args, capture_output=True, text=True)

    # 容器健全性：先给一个明确的错误，别让用户对着「等待 xxx 未就绪」猜。
    r = docker('inspect', '--format', '{{.State.Running}}', container)
    if r.returncode != 0:
        sys.exit(f'错误：找不到容器 {container}。先启动它：\n'
                 f'       docker compose up -d\n'
                 f'       （容器名不是 {container} 时用 SEAFILE_CONTAINER=<名> 指定）')
    if r.stdout.strip() != 'true':
        sys.exit(f'错误：容器 {container} 存在但没在运行。看日志：docker logs --tail 100 {container}')

    def wait_for(pred, what, timeout):
        print(f'    等待{what}（最多 {timeout}s）', flush=True)
        t0, last = time.time(), 0.0
        while True:
            if pred():
                print(f'    ✅ {what}已就绪（用时 {int(time.time() - t0)}s）')
                return
            el = time.time() - t0
            if el > timeout:
                sys.exit(f'    ❌ 等待 {timeout}s 后{what}仍未就绪。排查：\n'
                         f'         docker logs --tail 100 {container}\n'
                         f'       机器慢就加大超时重跑：PROD_WAIT=900 ./init-conf.sh --prod')
            if el - last >= 15:
                print(f'         ... 已等待 {int(el)}s')
                last = el
            time.sleep(3)

    def seahub_up():
        # gunicorn 默认绑 127.0.0.1:8000（gunicorn.conf.py）。任何 HTTP 状态码都算「在服务」，
        # 只有 000 是「连不上」——所以 302/404 也算通过。
        r = docker('exec', container, 'curl', '-sS', '-o', '/dev/null', '-w', '%{http_code}',
                   '--max-time', '5', 'http://127.0.0.1:8000/')
        code = r.stdout.strip()
        return code.isdigit() and code != '000'

    print('==> 等待首次启动完成')
    wait_for(lambda: sspath.exists(), '首启配置生成', wait)
    # 等到 seahub 真正应答再改配置。否则可能撞上 start.py 正在起 seahub，
    # 两边同时操作 seahub 进程（重启用的是 stop+start）。
    wait_for(seahub_up, 'seahub 服务起来', wait)

    # ---- 1) WebDAV：镜像默认 enabled = false ----
    print('\n==> 应用二开定制')
    changed = False
    seafdav = conf / 'seafdav.conf'
    if seafdav.exists() and not re.search(r'^enabled\s*=\s*true', seafdav.read_text(), re.M):
        seafdav.write_text(re.sub(r'^enabled = .*$', 'enabled = true',
                                  seafdav.read_text(), flags=re.M))
        print('    修改           seafdav.conf  enabled = true')
        changed = True

    # ---- 2) seahub 自定义配置块（幂等：标记存在则跳过）----
    MARKER = '# ---- 二开定制（init-conf.sh --prod 追加，勿手改本块）----'
    current = sspath.read_text()
    if MARKER in current:
        print('    跳过（已追加过）seahub_settings.py 定制块')
    else:
        # 只有 .env 里预置了才写钉钉凭据。默认不写：钉钉凭据已 constance 化
        # （docs/002），后台「系统管理 → 设置」填即可，写空串只会让人以为要在这儿配。
        dt_key = env.get('SEAHUB_DINGTALK_APP_KEY', '').strip()
        dt_secret = env.get('SEAHUB_DINGTALK_APP_SECRET', '').strip()
        dt_lines = ''
        if dt_key or dt_secret:
            dt_lines = ("DINGTALK_APP_KEY = '%s'\nDINGTALK_APP_SECRET = '%s'\n"
                        % (dt_key, dt_secret))
        block = f"""

{MARKER}
# 下面三项必须在【模块导入期】就确定，所以只能写文件 —— 改这里要重启 seahub。
# 判断依据是各调用点的绑定方式，不是「重不重要」：
#   CLIENT_SSO_VIA_LOCAL_BROWSER → urls.py / api2/urls.py / views/sso.py 导入期读它来注册路由
#   ENABLE_DINGTALK              → 它决定 constance 里该键的默认值（settings.py:1236）
#   ENABLE_DELETE_ACCOUNT        → profile/views.py 模块级 from seahub.settings import
# 其余站点相关配置（SERVICE_URL、钉钉凭据与开关）都已是 constance：管理员在
# 后台「系统管理 → 设置」页填，存库、免重启生效。所以本块只写这一次，之后不用再动。
CLIENT_SSO_VIA_LOCAL_BROWSER = True
ENABLE_DINGTALK = True
ENABLE_DELETE_ACCOUNT = False           # 禁止用户自助注销（docs/003）
# PASSWORD_LOGIN_ADMIN_ONLY = True     # 补丁 0008 默认即 True；紧急放开时取消注释改 False
{dt_lines}"""
        sspath.write_text(current.rstrip() + '\n' + block)
        print('    追加           seahub_settings.py 定制块（SSO / 钉钉默认开关 / 账号管控）')
        changed = True

    # ---- 3) 生效 ----
    if not changed:
        print('\n==> 没有改动，无需重启。')
        sys.exit(0)

    if no_restart:
        print('\n==> 已指定 --no-restart，未重启。手动生效：')
        print(f'    docker exec {container} /opt/seafile/seafile-server-latest/seafile.sh restart  # seafdav')
        print(f'    docker exec {container} /opt/seafile/seafile-server-latest/seahub.sh restart   # seahub')
        sys.exit(0)

    print('\n==> 重启服务使其生效')
    for script in ('seafile.sh', 'seahub.sh'):
        r = docker('exec', container, f'/opt/seafile/seafile-server-latest/{script}', 'restart')
        if r.returncode != 0:
            sys.exit(f'    ❌ {script} restart 失败（exit {r.returncode}）：\n'
                     f'{(r.stderr or r.stdout).strip()[-800:]}')
        print(f'    ✅ {script} restart')

    wait_for(seahub_up, 'seahub 重新起来', wait)

    print('\n完成。接下来在浏览器里做首次站点配置（域名、钉钉凭据），见 docs/011。')
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
