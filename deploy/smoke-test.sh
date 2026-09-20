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
" || fail "nginx 模板渲染失败（https=$mode）"
  nginx -t >/dev/null 2>&1 \
    || { nginx -t; fail "nginx 配置语法非法（https=$mode）"; }
  ok "nginx 模板渲染且语法合法（https=$mode）"

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

# ---- 6) 指纹：供跨架构（CI 的 amd64 vs 开发机 arm64）比对 ----
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
