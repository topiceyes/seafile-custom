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

INSTALLPATH=/opt/seafile/seafile-server-12.0.14
S="$INSTALLPATH/seahub"

fail() { echo "✗ $*" >&2; exit 1; }
ok()   { echo "✓ $*"; }

# ---- 1) 版本号：补丁 0002 在源码里写的是 12.0.14-dev，Dockerfile 构建期 sed 成发布号 ----
grep -q '^SEAFILE_VERSION = "12.0.14"' "$S/seahub/settings.py" \
  || fail "SEAFILE_VERSION 不是 12.0.14（Dockerfile 的 sed 没生效？）"
ok "SEAFILE_VERSION = 12.0.14"

# ---- 2) 二开补丁的落地痕迹 ----
grep -q PASSWORD_LOGIN_ADMIN_ONLY "$S/seahub/settings.py" \
  || fail "settings.py 缺 PASSWORD_LOGIN_ADMIN_ONLY（补丁 0008 未生效）"
grep -q 'X-Forwarded-Proto' /templates/seafile.nginx.conf.template \
  || fail "nginx 模板缺 X-Forwarded-Proto（Dockerfile 的模板 COPY 没生效）"
test "$(grep -c X-Forwarded-Proto /templates/seafile.nginx.conf.template)" -ge 2 \
  || fail "nginx 模板的 X-Forwarded-Proto 少于 2 处（location / 与 /seafdav/ 各需一处）"
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

# ---- 5) nginx 模板：两种部署模式都要能渲染且语法合法 ----
#
# 模板坏了 = 站点直接起不来，而这类错误在构建期完全看不出来（COPY 一个文本文件而已）。
# 这里用镜像自己的 render_template 渲染，再交给 nginx -t 解析：
#   https=true  → 容器内终止 TLS（Let's Encrypt 模式，需 443 与证书文件）
#   https=false → 上游反向代理终止 TLS，容器只监听 80（本项目的生产形态，见 docs/007 §9）
# 反代模式那支还需要 $seafile_fwd_proto 变量，语法错会被 nginx -t 抓到。
D=smoke.test
mkdir -p /shared/ssl /etc/nginx/sites-enabled
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -keyout /shared/ssl/$D.key -out /shared/ssl/$D.crt -subj "/CN=$D" 2>/dev/null

for mode in False True; do
  python3 -c "
import sys; sys.path.insert(0, '/scripts')
from utils import render_template
render_template('/templates/seafile.nginx.conf.template',
                '/etc/nginx/sites-enabled/seafile.nginx.conf',
                {'https': $mode, 'domain': '$D', 'is_tmp': False})
" || fail "nginx 模板渲染失败（https=${mode}）"
  nginx -t >/dev/null 2>&1 \
    || { nginx -t; fail "nginx 配置语法非法（https=${mode}）"; }
  ok "nginx 模板渲染且语法合法（https=${mode}）"

  # 反代模式下必须不能直接透传 $scheme（那恒为 http，Django 会以为请求是明文）。
  # 这条断言有牙齿：模板一旦回退成 proxy_set_header X-Forwarded-Proto $scheme 就会红。
  if [ "$mode" = "False" ]; then
    grep -q 'X-Forwarded-Proto *\$scheme' /etc/nginx/sites-enabled/seafile.nginx.conf \
      && fail "反代模式下 X-Forwarded-Proto 直接用了 \$scheme（应交给 \$seafile_fwd_proto 处理）"
    grep -q 'X-Forwarded-Proto *\$seafile_fwd_proto' /etc/nginx/sites-enabled/seafile.nginx.conf \
      || fail "反代模式下 X-Forwarded-Proto 未走 \$seafile_fwd_proto"
    ok "反代模式 X-Forwarded-Proto 取值正确"
  fi
done
rm -f /etc/nginx/sites-enabled/seafile.nginx.conf

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
