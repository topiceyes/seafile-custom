#!/bin/sh
# 镜像冒烟验证 —— CI 与人工验证共用【同一份】断言。
#
# 用法（在宿主机上，对已构建的镜像跑）：
#   docker run --rm --entrypoint sh -v "$PWD/deploy/smoke-test.sh:/smoke.sh:ro" <镜像> /smoke.sh
#
# 为什么是文件而不是内联在 workflow 里：这套断言曾在 workflow 与 docs/007 里各存一份，
# 结果 docs 那份写错了路径（断言 frontend/build/static/js，而 CRA 的 appBuild 实际是
# build/frontend，且真正被服务的是 collectstatic 产物），CI 首次运行才暴露。
# 现在只有这一份，改断言只改这里。
set -eu

INSTALLPATH=/opt/seafile/seafile-server-13.0.28
S="$INSTALLPATH/seahub"

fail() { echo "✗ $*" >&2; exit 1; }
ok()   { echo "✓ $*"; }

# ---- 1) 版本号：补丁在源码里写的是 -dev，Dockerfile 构建期 sed 成发布号 ----
grep -q '^SEAFILE_VERSION = "13.0.28"' "$S/seahub/settings.py" \
  || fail "SEAFILE_VERSION 不是 13.0.28（Dockerfile 的 sed 没生效？）"
ok "SEAFILE_VERSION = 13.0.28"

# ---- 2) 二开补丁的落地痕迹 ----
grep -q PASSWORD_LOGIN_ADMIN_ONLY "$S/seahub/settings.py" \
  || fail "settings.py 缺 PASSWORD_LOGIN_ADMIN_ONLY（补丁未生效）"
# 13.0 起 conf 是构建期静态烘入，不再是 /templates/ 模板
grep -q 'X-Forwarded-Proto' /etc/nginx/sites-enabled/seafile.nginx.conf \
  || fail "静态 nginx conf 缺 X-Forwarded-Proto（Dockerfile 的 COPY 没生效）"
test "$(grep -c X-Forwarded-Proto /etc/nginx/sites-enabled/seafile.nginx.conf)" -ge 2 \
  || fail "静态 conf 的 X-Forwarded-Proto 少于 2 处（location / 与 /seafdav/ 各需一处）"
grep -q '__SEAFILE_SERVER_NAME__' /etc/nginx/sites-enabled/seafile.nginx.conf \
  || fail "静态 conf 缺 server_name 占位符（custom_bootstrap 首启替换的锚点没了）"
ok "二开补丁痕迹齐全"

# ---- 3) 备份依赖与运维脚本（已烘进镜像，不再由 compose 挂载）----
#
# 这三个文件以前是 bind-mount 进容器的，副作用是「必须先 checkout 仓库 + 必须待在
# 固定目录」——换目录时挂载落空，容器照样起得来，但备份和离职同步会静默失效。
# 烘进镜像后部署只需 compose + .env，这里断言它们确实在。
command -v mysqldump >/dev/null || fail "缺 mysqldump（容器内 backup.sh 依赖）"
test -x /usr/local/bin/seafile-backup.sh || fail "缺 /usr/local/bin/seafile-backup.sh 或不可执行"
test -f /etc/cron.d/seafile-backup       || fail "缺 /etc/cron.d/seafile-backup"
test -f /etc/cron.d/dingtalk-sync        || fail "缺 /etc/cron.d/dingtalk-sync"
# cron 会静默拒绝加载属主非 root、或 group/other 可写的文件——那种失败没有任何提示，
# 只表现为「定时任务不跑」，所以在这里拦下。
for f in /etc/cron.d/seafile-backup /etc/cron.d/dingtalk-sync; do
  perms=$(stat -c '%a %U' "$f")
  [ "$perms" = "644 root" ] || fail "$f 属性是 [$perms]，cron 要求 [644 root]（否则不加载且无提示）"
done
ok "运维脚本与 cron 就位（backup.sh + 两个 cron，属性符合 cron 要求）"

# ---- 4) 前端：验证【真正被浏览器请求的那份】，而不是构建的中间产物 ----
#
# 链条：frontend/build/frontend/static/js/*  →collectstatic→  media/assets/frontend/static/js/*
#       →模板按 WEBPACK_LOADER.BUNDLE_DIR_NAME('frontend/') + chunk 路径拼出
#         /media/assets/frontend/static/js/*
# 所以只断言 frontend/build 存在是不够的：collectstatic 没跑到、或 STATICFILES_DIRS
# 没收录 build 目录时，页面照样白屏。这里拿 webpack-stats 里的 chunk 清单逐个核对落点。
test -f "$S/frontend/webpack-stats.pro.json" || fail "缺 frontend/webpack-stats.pro.json"
test -d "$S/frontend/build"                  || fail "缺 frontend/build（前端构建产物未拷入镜像）"

python3 - "$S" <<'PY' || exit 1
import json, os, sys

S = sys.argv[1]
stats = json.load(open(os.path.join(S, "frontend/webpack-stats.pro.json")))
chunks = stats.get("chunks") or {}

total, missing = 0, []
for files in chunks.values():
    for f in files:
        total += 1
        if not os.path.isfile(os.path.join(S, "media/assets/frontend", f)):
            missing.append(f)

if total == 0:
    sys.exit("✗ webpack-stats.pro.json 里没有任何 chunk")
if missing:
    sys.exit("✗ collectstatic 后缺失 %d/%d 个 chunk，前几个：%s"
             % (len(missing), total, missing[:5]))
print("✓ webpack chunk 全部落地：%d 个（collectstatic 产物齐全）" % total)
PY

# ---- 5) 静态 nginx conf：语法合法 + 反代协议判定正确 ----
#
# 13.0 起 conf 构建期静态烘入（无 /templates/ 模板渲染）。这里直接对烘入的静态 conf
# 做 nginx -t 语法解析，再断言反代协议判定逻辑：
#   $seafile_fwd_proto 按访问入口分流（域名→https、其它→转发头/$scheme），
#   不能退化成直接透传 $scheme（那恒为 http，Django 会以为请求是明文 → 登录 403）。
# 冒烟容器不挂数据卷：conf 的 access_log 指向 /shared/seafile/logs/，nginx -t 会真的
# 去打开日志文件，目录不在就 emerg。运行期这个目录由 create_data_links 建好，
# 这里补上只是为了让语法检查能跑（与运行期行为无涉）。
mkdir -p /shared/seafile/logs
nginx -t >/dev/null 2>&1 \
  || { nginx -t; fail "静态 nginx 配置语法非法"; }
ok "静态 nginx conf 语法合法"

CONF=/etc/nginx/sites-enabled/seafile.nginx.conf
grep -q 'X-Forwarded-Proto *\$scheme' "$CONF" \
  && fail "X-Forwarded-Proto 直接用了 \$scheme（应交给 \$seafile_fwd_proto 分流）"
grep -q 'X-Forwarded-Proto *\$seafile_fwd_proto' "$CONF" \
  || fail "X-Forwarded-Proto 未走 \$seafile_fwd_proto"
grep -q 'if (\$http_host = \$server_name)' "$CONF" \
  || fail "缺域名入口判定（if \$http_host = \$server_name → https）"
ok "反代协议判定逻辑正确（按入口分流，非直接透传 \$scheme）"

# ---- 6) 二开定制钩子：接进 start.py + 真跑一遍 ----
#
# 这一步以前是人手工 `init-conf.sh --prod`：等首启 → 追加 → 重启。手工的问题不是
# 麻烦，是忘了不报错——SSO / 账号管控 / WebDAV 静默失效，页面照常打开。现在它在
# 镜像里，所以【必须】断言它真的接进去了：Dockerfile 的 sed 一旦失效，构建应当失败。
#
# 光检查文件存在不够——所以下面在一个假配置目录上真跑一遍，验实际行为。
test -f /scripts/custom_bootstrap.py || fail "缺 /scripts/custom_bootstrap.py"
test -x /scripts/custom_bootstrap.py || fail "/scripts/custom_bootstrap.py 不可执行"
grep -q '^from custom_bootstrap import init_custom_settings, start_service_retry$' /scripts/start.py \
  || fail "start.py 缺 custom_bootstrap 的 import（patch-upstream.py 没生效？）"
# 调用点必须在 init_seafile_server() 之后、seafile.sh 启动之前——顺序错了就白搭：
# 早了会被 setup 的 open('w') 覆盖，晚了 seahub 已经起来、settings.py 改不生效。
awk '/^    init_seafile_server\(\)$/ {s=NR} /^    init_custom_settings\(\)$/ {c=NR} END {exit !(s && c && c == s+1)}' \
  /scripts/start.py \
  || fail "start.py 里 init_custom_settings() 没有紧跟 init_seafile_server()（顺序不对）"

# 起 seahub 必须走带重试的那条路。上游 seahub.sh 是「硬编码 sleep 5 再 pgrep 一次」
# 判定成败，而 gunicorn 带 --preload 要先导入整个 Django 应用，机器一忙就误判失败
# （2026-09-21 彩排实测撞到过）。改回裸 call( 就等于把这个坑放回去。
grep -q "start_service_retry('{} start'.format(get_script('seahub.sh')))" /scripts/start.py \
  || fail "start.py 起 seahub 没走 start_service_retry（重试补丁没生效？）"
if grep -q "call('{} start'.format(get_script('seahub.sh')))" /scripts/start.py; then
  fail "start.py 里还剩裸 call() 起 seahub（重试补丁只打了一半）"
fi

# enterpoint.sh 必须跟着 start.py 一起死。
# 不这么做的话，start.py 因任何原因退出都会留下「docker ps 显示 Up、网站是死的」
# 容器，restart 策略也救不了（容器没退出）—— 这是本项目一直在消灭的静默失败。
grep -q '^SERVER_PID=\$!$' /scripts/enterpoint.sh \
  || fail "enterpoint.sh 没记下 start.py 的 PID（补丁没生效？）"
grep -q 'kill -0 "\$SERVER_PID"' /scripts/enterpoint.sh \
  || fail "enterpoint.sh 没在保活循环里检查 start.py 是否还活着"
grep -q 'exit 1' /scripts/enterpoint.sh \
  || fail "enterpoint.sh 检测到 start.py 死了却没有退出容器"

# 在真路径上放一份假的 setup 产物，跑钩子，验它写对了、且第二遍幂等
mkdir -p /opt/seafile/conf
printf 'SECRET_KEY = "smoke"\n' > /opt/seafile/conf/seahub_settings.py
printf '\n[WEBDAV]\nenabled = false\nport = 8080\n' > /opt/seafile/conf/seafdav.conf

python3 /scripts/custom_bootstrap.py >/dev/null || fail "custom_bootstrap.py 跑失败"

python3 - <<'PY' || fail "钩子写入的配置不正确"
import ast, sys
src = open('/opt/seafile/conf/seahub_settings.py').read()
ns = {}
exec(compile(src, 'seahub_settings.py', 'exec'), ns)
assert ns['CLIENT_SSO_VIA_LOCAL_BROWSER'] is True, 'CLIENT_SSO_VIA_LOCAL_BROWSER 不是 True'
assert ns['ENABLE_DINGTALK'] is True, 'ENABLE_DINGTALK 不是 True'
assert ns['ENABLE_DELETE_ACCOUNT'] is False, 'ENABLE_DELETE_ACCOUNT 不是 False'
# 反代模式下不设它，Django 不认 X-Forwarded-Proto → request.is_secure() 恒为假 →
# CSRF 的 good_origin 算成 http://域名 → 登录 403（2026-09-21 生产实测）。
assert ns['SECURE_PROXY_SSL_HEADER'] == ('HTTP_X_FORWARDED_PROTO', 'https'), \
    'SECURE_PROXY_SSL_HEADER 缺失或取值不对（反代模式下会导致登录 403）'
assert 'enabled = true' in open('/opt/seafile/conf/seafdav.conf').read(), 'WebDAV 没开'
PY

# 幂等：第二遍不能再追加一个块（否则每次重启配置都会变长）
python3 /scripts/custom_bootstrap.py >/dev/null || fail "custom_bootstrap.py 第二遍跑失败"
n=$(grep -c 'CLIENT_SSO_VIA_LOCAL_BROWSER = True' /opt/seafile/conf/seahub_settings.py)
[ "$n" = "1" ] || fail "钩子不幂等：CLIENT_SSO_VIA_LOCAL_BROWSER 出现 $n 次（应为 1）"

# ---- 升级路径：已部署机器上新增一项设置 ----
#
# 这一条是 2026-09-21 生产登录 403 的成因：老镜像写过的 seahub_settings.py 里
# 标记块**早就在了**，而当时的幂等判断是整块级的（「看见标记就跳过」），于是新加的
# SECURE_PROXY_SSL_HEADER **永远写不进去**。机制能自愈「块被删掉」，自愈不了
# 「块里少一行」。现在改成逐项核对，这条断言把那个盲区钉死。
cat > /opt/seafile/conf/seahub_settings.py <<'EOF'
SECRET_KEY = "smoke"
# ---- 二开定制（镜像烘焙，勿手改本块）----
CLIENT_SSO_VIA_LOCAL_BROWSER = True
ENABLE_DINGTALK = True
ENABLE_DELETE_ACCOUNT = False
EOF
python3 /scripts/custom_bootstrap.py >/dev/null || fail "升级路径下 custom_bootstrap.py 跑失败"
python3 - <<'PY' || fail "升级路径没补上新增设置（整块级幂等的盲区又回来了？）"
src = open('/opt/seafile/conf/seahub_settings.py').read()
ns = {}
exec(compile(src, 'seahub_settings.py', 'exec'), ns)
assert ns['SECURE_PROXY_SSL_HEADER'] == ('HTTP_X_FORWARDED_PROTO', 'https'), \
    'SECURE_PROXY_SSL_HEADER 没被补上——反代模式下这台机器会登录 403'
for k in ('CLIENT_SSO_VIA_LOCAL_BROWSER', 'ENABLE_DINGTALK', 'ENABLE_DELETE_ACCOUNT'):
    assert src.count(k + ' = ') == 1, '%s 出现多次：逐项核对退化成了整块追加' % k
PY
ok "二开定制钩子已接入 start.py；行为、幂等性、升级路径均验证通过"

# ---- 升级路径二：静态 nginx conf 的域名占位符替换（13.0 起）----
#
# 13.0 废除了 /templates/ 模板渲染（generate_local_nginx_conf 删除），conf 构建期
# 静态烘入。这治好了 12.0 的「conf 滞留数据卷」病根（403 第三形态结构性消失，
# sync_nginx_conf 整套退役），但带来新动作：conf 里的 server_name 是占位符
# __SEAFILE_SERVER_NAME__，首启时由 custom_bootstrap 替换为真实 SEAFILE_DOMAIN。
# 这里断言替换真的发生、且幂等（重启场景容器层已替换过，不能再动）。
python3 - <<'PY' || fail "apply_nginx_server_name 行为不正确"
import os, sys, shutil, importlib.util
sys.path.insert(0, '/scripts')
spec = importlib.util.spec_from_file_location('cb', '/scripts/custom_bootstrap.py')
cb = importlib.util.module_from_spec(spec); spec.loader.exec_module(cb)

base = '/tmp/nginxtest'; shutil.rmtree(base, ignore_errors=True); os.makedirs(base)
conf = base + '/seafile.nginx.conf'

# 首启：占位符 → 替换为域名
open(conf, 'w').write('server {\n    server_name __SEAFILE_SERVER_NAME__;\n}\n')
os.environ['SEAFILE_DOMAIN'] = 'disc.example.cn'
cb.NGINX_STATIC_CONF = conf
cb.apply_nginx_server_name()
out = open(conf).read()
assert 'server_name disc.example.cn;' in out, '占位符没被替换'
assert '__SEAFILE_SERVER_NAME__' not in out, '占位符残留'

# 重启：已是目标域名 → 幂等不动
cb.apply_nginx_server_name()
assert open(conf).read() == out, '幂等失败：重启场景改了 conf'

# 未设域名：占位符保留（仅 IP 直连可用），不崩
open(conf, 'w').write('server {\n    server_name __SEAFILE_SERVER_NAME__;\n}\n')
del os.environ['SEAFILE_DOMAIN']
os.environ.pop('SEAFILE_SERVER_HOSTNAME', None)
cb.apply_nginx_server_name()
assert '__SEAFILE_SERVER_NAME__' in open(conf).read(), '未设域名时占位符被误改'

shutil.rmtree(base)
print('nginx server_name 替换 OK（首启替换 + 重启幂等 + 未设域名不崩）')
PY
ok "静态 conf 域名替换：首启替换、重启幂等、未设域名不崩"

# 清掉假配置目录：/opt/seafile/conf 若残留在镜像层，首启 setup 会有意外行为
rm -rf /opt/seafile/conf

# ---- 7) 指纹：供跨架构（CI 的 amd64 vs 开发机 arm64）比对 ----
echo "--- 指纹 ---"
printf 'overlay_seahub_pkg  n=%-6s %s\n' \
  "$(find "$S/seahub" -type f -not -path '*/__pycache__/*' | wc -l | tr -d ' ')" \
  "$(find "$S/seahub" -type f -not -path '*/__pycache__/*' -exec sha256sum {} + | LC_ALL=C sort -k2 | sha256sum | cut -d' ' -f1)"
printf 'served_frontend    n=%-6s %s\n' \
  "$(find "$S/media/assets/frontend" -type f | wc -l | tr -d ' ')" \
  "$(find "$S/media/assets/frontend" -type f | LC_ALL=C sort | sha256sum | cut -d' ' -f1)"
printf 'media_assets       n=%-6s %s\n' \
  "$(find "$S/media/assets" -type f | wc -l | tr -d ' ')" \
  "$(find "$S/media/assets" -type f | LC_ALL=C sort | sha256sum | cut -d' ' -f1)"

echo "SMOKE_OK"
