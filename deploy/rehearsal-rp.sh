#!/usr/bin/env bash
# 反代模式彩排（docs/007 §7.2）—— 上线前必跑的那一遍。
#
#   ./rehearsal-rp.sh                 # 从 Release 固定 URL 取安装文件，跑完清理现场
#   ./rehearsal-rp.sh --keep          # 保留现场（调试用，下次运行会先清掉重来）
#   ./rehearsal-rp.sh --from-tree     # 安装文件取工作树而不是 Release（改模板时的快速内环）
#   ./rehearsal-rp.sh --tag <镜像tag> # 指定通道之外的具体 tag（回滚演练用）
#
# 它验的是**生产那份 compose 文件本身**，不是它的复制品：seafile-prod.yml 从 Release
# 资产 URL 取回来（与真服务器同一条路），再用 rehearsal-rp-override.yml 只改「撞 dev 栈」
# 的三处（容器名 / 端口 / 加一个代理服务）。改了生产 compose 就等于改了彩排。
#
# 与 dev 栈（占用宿主机 80/443/8180）**完全隔离**：不发布 80、三个容器全部改名、
# 数据卷指向本目录下全新目录。跑这个脚本不会碰 dev 的任何东西。
#
# ⚠️ 本脚本是这套断言的【唯一事实来源】，文档里只摘要、不复制全文。
#    理由见 docs/007 §10：同一套断言存两份，CI 首跑时两边都错。
#
# 覆盖不到什么，见 docs/007 §7.2 的表格 —— 尤其是「你的云代理配置对不对」，
# 那只能上线时用真域名复验。
set -euo pipefail
cd "$(dirname "$0")"
REPO_DEPLOY=$(pwd)
cd ..

DOMAIN=seafile.localhost          # 本机解析（配合 curl --resolve，不改 /etc/hosts）
HOST_PORT="${SEAFILE_RP_HTTP_PORT:-18080}"   # 容器 80 直连口（P1-P4 对照探针用）。
PROXY_PORT="${SEAFILE_RP_TLS_PORT:-18443}"   # 代理 443。两个都可用环境变量覆盖：
                                             # 宿主端口被别的东西占着时（比如本机临时起
                                             # 的服务），不用杀它——换口即可：
                                             #   SEAFILE_RP_HTTP_PORT=18081 ./rehearsal-rp.sh
export SEAFILE_RP_HTTP_PORT SEAFILE_RP_TLS_PORT   # 让 override 里的端口插值拿到同一组值
PROJECT=seafile-rp
WD="$REPO_DEPLOY/rehearsal-rp"
ADMIN_EMAIL="admin@$DOMAIN"
ADMIN_PW='Rehearsal-Alpha-1'
KEEP=0
FROM_TREE=0
TAG_OVERRIDE=''

while [ $# -gt 0 ]; do
  case "$1" in
    --keep)      KEEP=1; shift ;;
    --from-tree) FROM_TREE=1; shift ;;
    --tag)       TAG_OVERRIDE="${2:?}"; shift 2 ;;
    -h|--help)   sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数：$1（--help 看用法）" >&2; exit 1 ;;
  esac
done

# ---- 输出设施 ----
step() { printf '\n\033[1m── %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✅\033[0m %s\n' "$*"; }
info() { printf '  ·  %s\n' "$*"; }
die()  { printf '\n\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# 断言失败也走 die —— 彩排的意义就是「红要红得响亮」，不能吞。
assert_eq() { [ "$1" = "$2" ] || die "$3（期望 [$2]，实际 [$1]）"; ok "$3"; }
assert_has() { grep -q -- "$2" "$1" || die "$3（在 $1 里找不到 [$2]）"; ok "$3"; }
assert_not() { ! grep -q -- "$2" "$1" || die "$3（$1 里不该出现 [$2]）"; ok "$3"; }

cleanup() {
  if [ "$KEEP" = "1" ]; then
    printf '\n（--keep）现场保留在 %s\n' "$WD"
    return
  fi
  step "清理现场"
  ( cd "$WD" 2>/dev/null && DOMAIN="$DOMAIN" COMPOSE_PROJECT_NAME="$PROJECT" \
      docker compose -p "$PROJECT" --env-file .env \
        -f seafile-prod.yml -f rehearsal-rp-override.yml down -v >/dev/null 2>&1 ) || true
  rm -rf "$WD"
  ok "容器、卷、现场目录都已清掉（dev 栈全程未受影响）"
}
trap cleanup EXIT

# ---------------------------------------------------------------- 0. 前置检查
step "0. 前置检查"
command -v docker >/dev/null || die "缺 docker"
command -v openssl >/dev/null || die "缺 openssl"
for p in "$HOST_PORT" "$PROXY_PORT"; do
  if lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1; then
    die "宿主端口 $p 已被占用——本脚本靠这两个端口与 dev 栈隔离。
  占用者多半是本机临时起的服务，不用杀它，换口重跑即可：
    SEAFILE_RP_HTTP_PORT=18081 ./rehearsal-rp.sh        （http 探针口）
    SEAFILE_RP_TLS_PORT=18444  ...                       （本地代理 TLS 口）"
  fi
done
ok "端口 $HOST_PORT / $PROXY_PORT 空闲（dev 栈的 80/443/8180 不参与）"

# ---------------------------------------------------------------- 1. 取安装文件
step "1. 取安装文件（与真服务器同一条路）"
if [ -f "$REPO_DEPLOY/.env" ]; then :; else
  info "注意：deploy/.env 不存在，gen-ssl-cert.sh 会拒绝——但那不影响本脚本后面自己生成 .env"
fi
rm -rf "$WD"; mkdir -p "$WD"
if [ "$FROM_TREE" = "1" ]; then
  cp "$REPO_DEPLOY/seafile-prod.yml" "$REPO_DEPLOY/env.prod.example" \
     "$REPO_DEPLOY/init-prod-env.sh" "$WD/"
  info "取自工作树（--from-tree）：验的是你手上这份，不是发布出去那份"
else
  B=https://github.com/topiceyes/seafile-custom/releases/latest/download
  # 开发机上 github.com 往往直连不通（2026-09-21 实测：直连超时，走代理才通）。
  # 这不是脚本该「自动修好」的事——代理是这台机器的环境，脚本只负责把话说明白，
  # 免得卡满 120s×3 才吐出一个没头没尾的 curl 错误。
  fetch() {
    local f=$1 out=$2
    curl -fsSL --max-time 120 -o "$out" "$B/$f" && return 0
    local rc=$?
    printf '\n' >&2
    die "取 ${f} 失败（curl 退出码 ${rc}）
      地址：$B/$f
      这台机器到 github.com 通不通？先单独试一次：
        curl -fsS  -o /dev/null -w '%{http_code}\n' --max-time 20 $B/seafile-prod.yml
      开发机上实测直连会超时，需要走代理（例如已在本机跑的 privoxy）：
        HTTPS_PROXY=http://127.0.0.1:8118 $0 $( [ "$KEEP" = 1 ] && echo --keep )
      注意：**服务器上不需要代理**，这条只是开发机的事。
      另有一条不依赖 github.com 的入口（已在服务器实测可达）：
        ./rehearsal-rp.sh --from-tree     # 从工作树取，用于改模板时的快速内环"
  }
  fetch seafile-prod.yml "$WD/seafile-prod.yml"
  fetch env.prod.example "$WD/env.prod.example"
  fetch init-prod-env.sh "$WD/init-prod-env.sh"
  ok "三个资产取自 Release 固定 URL（就是新服务器执行的那条命令）"
fi
chmod +x "$WD/init-prod-env.sh"
cp "$REPO_DEPLOY/rehearsal-rp-override.yml" "$WD/"
ok "覆盖文件就位（它不是 Release 资产，从仓库取）"

# ---------------------------------------------------------------- 2. 生成 .env
step "2. 生成 .env（走 init-prod-env.sh 本身，零提问）"
# 先把模板里的两个数据卷指到本目录下。这样做而不是事后 sed .env，是为了让
# init-prod-env.sh 那段「代建数据目录」的新逻辑**真的跑到**（指到 /data 会因权限失败，
# 只能看到警告分支）。
sed -i.bak \
  -e "s|^SEAFILE_VOLUME=.*|SEAFILE_VOLUME='$WD/data'|" \
  -e "s|^SEAFILE_MYSQL_VOLUME=.*|SEAFILE_MYSQL_VOLUME='$WD/mysql'|" \
  -e "s|^SEAHUB_DINGTALK_APP_KEY=.*|SEAHUB_DINGTALK_APP_KEY='rehearsal-dummy-key'|" \
  -e "s|^SEAHUB_DINGTALK_APP_SECRET=.*|SEAHUB_DINGTALK_APP_SECRET='rehearsal-dummy-secret'|" \
  "$WD/env.prod.example"
rm -f "$WD/env.prod.example.bak"
( cd "$WD" && ./init-prod-env.sh --domain "$DOMAIN" --admin-email "$ADMIN_EMAIL" \
    --admin-password "$ADMIN_PW" ) > "$WD/init.log" 2>&1 \
  || { cat "$WD/init.log"; die "init-prod-env.sh 失败（完整输出见上）"; }
assert_has "$WD/init.log" "数据目录就绪" "脚本自己把数据目录建好了（没人手抄 mkdir）"
assert_has "$WD/.env" "SEAFILE_SERVER_LETSENCRYPT='false'" "反代模式开关是 false（不是 §7.1 那个 true）"
assert_has "$WD/.env" "SEAFILE_SERVER_PROTOCOL='https'"    "生成的链接用 https"
if grep -q '^SEAFILE_PRO_IMAGE=' "$WD/.env"; then
  die ".env 里出现了生效的 SEAFILE_PRO_IMAGE —— 这台机器会被钉死，不再跟随通道 tag"
fi
ok ".env 里没有生效的 SEAFILE_PRO_IMAGE（跟的是通道 tag）"

if [ -n "$TAG_OVERRIDE" ]; then
  export SEAFILE_PRO_IMAGE="$TAG_OVERRIDE"
  info "已按 --tag 指定镜像：$SEAFILE_PRO_IMAGE"
fi

# ---------------------------------------------------------------- 3. 代理证书
step "3. 代理侧自签证书（TLS 在代理终止，证书就该在代理手里）"
# SEAFILE_VOLUME 必须显式传：gen-ssl-cert.sh 的兜底分支用了 grep -oP，
# 而 macOS 的 BSD grep 不支持 -P，兜底会拿到错值。
SEAFILE_VOLUME="$WD/data" "$REPO_DEPLOY/gen-ssl-cert.sh" "$DOMAIN" >/dev/null
[ -f "$WD/data/ssl/$DOMAIN.crt" ] || die "证书没生成到 $WD/data/ssl/"
ok "证书就位：$WD/data/ssl/$DOMAIN.crt"

# ---------------------------------------------------------------- 4. 拉镜像
step "4. 拉镜像（通道 tag，也就是生产在跑的那份字节）"
cd "$WD"
DC=(docker compose -p "$PROJECT" --env-file .env
    -f seafile-prod.yml -f rehearsal-rp-override.yml)
"${DC[@]}" pull 2>&1 | tail -5

if [ -z "$TAG_OVERRIDE" ]; then
  IMG=ghcr.io/topiceyes/seafile-mc:latest
else
  IMG="$TAG_OVERRIDE"
fi
ARCH=$(docker image inspect "$IMG" --format '{{.Architecture}}')
DIGEST=$(docker image inspect "$IMG" --format '{{index .RepoDigests 0}}' 2>/dev/null || echo '(本地无 digest)')
CREATED=$(docker image inspect "$IMG" --format '{{.Created}}')
step "溯源（下次出问题先看这一段：这次到底测的是哪几个字节）"
info "镜像      $IMG"
info "架构      $ARCH"
info "digest    $DIGEST"
info "构建于    $CREATED"
for f in seafile-prod.yml env.prod.example init-prod-env.sh; do
  info "$(printf '%-20s' "$f") $(shasum -a 256 "$f" | cut -c1-16)…"
done
# 发布出去的只有 amd64。哪天 CI 改成同时构建 arm64，Apple Silicon 上 `pull` 会
# 静默改拉 arm64，彩排从此测的不是生产字节而且没有任何报错 —— 所以这里断言而不是钉死
# （钉 platform 会把漂移藏起来，断言会把它喊出来）。
assert_eq "$ARCH" "amd64" "拉到的镜像是生产用的 amd64"

# ---------------------------------------------------------------- 5. 起栈
step "5. 起服务（一条命令；db 的 healthcheck 会自己排好序）"
"${DC[@]}" up -d
info "等待首启完成（amd64 模拟下会比较慢，最多等 20 分钟）…"
# ⚠️ 探针必须带 --noproxy '*'。开发机取 Release 资产要 HTTPS_PROXY（步骤 1 的提示就是
#    这么教的），但同一个环境变量会把 --resolve 到 127.0.0.1 的本机流量也送进代理：
#    代理那头解析不出 seafile.localhost，于是永远 000，彩排「等满 20 分钟然后超时」，
#    而服务其实早就绪了（2026-09-21 实测：带代理 000、不带 200）。本脚本后面所有
#    对本机的 curl 同理，一律 --noproxy '*'。
CODE=000
for i in $(seq 1 120); do
  CODE=$(curl -sk --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 10 \
           --resolve "$DOMAIN:$PROXY_PORT:127.0.0.1" "https://$DOMAIN:$PROXY_PORT/accounts/login/" || true)
  [ "$CODE" = "200" ] && break
  [ $((i % 6)) -eq 0 ] && info "  已等 $((i*10))s，登录页仍是 $CODE …"
  sleep 10
done
[ "$CODE" = "200" ] || { "${DC[@]}" logs seafile 2>&1 | tail -40; die "登录页始终不是 200（最后是 ${CODE}）"; }
ok "代理 → 容器 → seahub 链路通了，登录页 200"

# ---------------------------------------------------------------- 6. 配置层断言
step "6. 配置层断言（不依赖网络，失败时先看这里）"
assert_not "$WD/data/nginx/conf/seafile.nginx.conf" "listen 443" \
  "容器只监听 80、不监听 443（反代模式下 443 在代理侧）"
assert_has "$WD/data/nginx/conf/seafile.nginx.conf" "seafile_fwd_proto" \
  "模板走了 https=false 分支（恒判 https，而不是 \$scheme）"
assert_not "$WD/data/nginx/conf/seafile.nginx.conf" 'X-Forwarded-Proto $scheme' \
  "容器侧没有直接透传 \$scheme（那恒为 http，Django 会以为请求是明文）"
assert_has "$WD/data/seafile/conf/seahub_settings.py" "SECURE_PROXY_SSL_HEADER" \
  "SECURE_PROXY_SSL_HEADER 已写进 seahub_settings.py"
# setup-seafile-mysql.py 写 SERVICE_URL 用【双引号】、bootstrap.py 写 FILE_SERVER_ROOT 用
# 【单引号】（上游两处代码风格不同）—— 断言里的 . 是通配符，两种引号都认。
assert_has "$WD/data/seafile/conf/seahub_settings.py" "^SERVICE_URL = .https://$DOMAIN" \
  "SERVICE_URL 用的是 https（constance 的初始默认值）"
assert_has "$WD/data/seafile/conf/seahub_settings.py" "^FILE_SERVER_ROOT = .https://$DOMAIN/seafhttp" \
  "FILE_SERVER_ROOT 同样是 https"
assert_has "$WD/data/seafile/conf/seafdav.conf" "enabled = true" \
  "二开定制自动落地（WebDAV 已开）"

# ---------------------------------------------------------------- 7. 端到端
step "7. 真表单登录（CSRF → POST → 302，不是 403）"
J=$(mktemp -d)
R=(--resolve "$DOMAIN:$PROXY_PORT:127.0.0.1")
P="https://$DOMAIN:$PROXY_PORT"
O="https://$DOMAIN"        # ⚠️ 不带端口：必须与代理发给容器的 Host 头一致

curl -sk --noproxy '*' "${R[@]}" -c "$J/cj" -o "$J/login.html" "$P/accounts/login/"
CSRF=$(sed -n 's/.*name="csrfmiddlewaretoken" value="\([^"]*\)".*/\1/p' "$J/login.html" | head -1)
[ -n "$CSRF" ] || die "登录页里没找到 csrfmiddlewaretoken"
ok "拿到 CSRF token"

curl -sk --noproxy '*' "${R[@]}" -b "$J/cj" -c "$J/cj2" -D "$J/h.txt" -o /dev/null \
  -H "Referer: $O/accounts/login/" -H "Origin: $O" \
  --data-urlencode "csrfmiddlewaretoken=$CSRF" \
  --data-urlencode "login=$ADMIN_EMAIL" \
  --data-urlencode "password=$ADMIN_PW" \
  --data-urlencode "next=/" "$P/accounts/login/"
grep -qE '^HTTP/[0-9.]+ 302' "$J/h.txt" \
  || { sed -n '1,20p' "$J/h.txt"; die "表单登录不是 302 而是 $(head -1 "$J/h.txt") —— 403 就是 CSRF 那条老路"; }
ok "表单登录返回 302（**不是 403** —— 这就是 2026-09-21 那次事故的复现点）"
# 「302 回登录页」和「302 进首页」只差 Location / Set-Cookie 这两个头。失败路径把
# 它们全打出来，别让人猜是密码错、0008 拦截、还是别的。
# 注意 ${LOC} 必须带花括号：后面跟的是全角括号，bash 3.2 会把它并进变量名。
LOC=$(grep -i '^location:' "$J/h.txt" | tail -1 | tr -d '\r' | awk '{print $2}')
case "$LOC" in
  *accounts/login*|*login*)
    sed -n '1,15p' "$J/h.txt"
    die "302 但跳回了登录页（Location: ${LOC}）—— 密码不对，或 0008 把这个账号拦了。
        查容器日志：docker logs seafile-rp 2>&1 | grep -iE 'login|auth' | tail -10" ;;
esac
assert_eq "$LOC" "/" "302 的目标是首页（next=/），不是登录页"
grep -qi '^set-cookie: sessionid=' "$J/h.txt" \
  || { sed -n '1,15p' "$J/h.txt"; die "302 了但没有 sessionid cookie —— 会话没立起来"; }
ok "拿到 sessionid 会话 cookie（Seafile 12 用 Django 标准会话，不是老版的 seahub_auth）"

# 会话有效性的硬证据：带 cookie 调 API，未登录这里是 401/403。
INFO=$(curl -sk --noproxy '*' "${R[@]}" -b "$J/cj2" "$P/api2/account/info/")
echo "$INFO" | grep -q "\"email\": *\"$ADMIN_EMAIL\"" \
  || die "会话 API 返回的不是管理员：$INFO"
ok "带会话调 /api2/account/info/ → 200 且是 ${ADMIN_EMAIL}（真登录，不是假 302）"
echo "$INFO" | grep -q "\"is_staff\": *true" || die "管理员不是 is_staff —— 账号建错了"
ok "账号是 is_staff（INIT_SEAFILE_ADMIN_* 生效，不是 me@example.com）"

# ⚠️ 彩排专属的「运输改写」：API 生成的上传/下载链接是【无端口】的
#    https://<域名>/seafhttp/…（生产形态本来就该无端口）。但这台开发机的 443 被
#    dev 栈占着 —— 不改写的话请求会打到【dev 的 fileserver】上，拿着彩排的 token
#    得到 {"error": "Access token not found."} 403（2026-09-21 实测排查了两小时，
#    症状极具迷惑性：像代理坏了，其实请求压根没进彩排）。改写只动运输层（端口），
#    上面对链接形状的断言验的是语义（协议与域名），两者分开。
# ⚠️ 别用 ${u/#https:\/\/…/…} 的模式替换写法：bash 3.2（macOS 自带）会在【替换串】里
#    把转义斜杠原样吐出来（实测得到 https:\/\/…）。用前缀剥除 + 拼接，行为处处一致。
rp_url() {
  local u=$1 p="https://$DOMAIN/"
  case "$u" in
    "$p"*) printf '%s%s\n' "https://$DOMAIN:$PROXY_PORT/" "${u#"$p"}" ;;
    *)     printf '%s\n' "$u" ;;
  esac
}

step "8. 文件上传 + 下载（SERVICE_URL / FILE_SERVER_ROOT 写错时唯一会露馅的地方）"
TOKEN=$(curl -sk --noproxy '*' "${R[@]}" -X POST "$P/api2/auth-token/" \
          -d "username=$ADMIN_EMAIL" -d "password=$ADMIN_PW" \
        | sed -n 's/.*"token": *"\([^"]*\)".*/\1/p')
[ -n "$TOKEN" ] || die "拿不到 API token"
ok "API token 到手"

# 全新实例的管理员名下【没有】「我的资料库」——它是 SPA 首登时调
# POST /api2/default-repo/ 惰性创建的（seahub/api2/views.py:DefaultRepoView.post）。
# 直接 GET /api2/repos/ 会拿到空列表，那不是故障，是还没触发过。
DR=$(curl -sk --noproxy '*' "${R[@]}" -X POST -H "Authorization: Token $TOKEN" \
      "$P/api2/default-repo/")
REPO_ID=$(echo "$DR" | sed -n 's/.*"repo_id": *"\([^"]*\)".*/\1/p')
[ -n "$REPO_ID" ] || die "POST /api2/default-repo/ 没建出资料库：$DR"
info "「我的资料库」已建，id：$REPO_ID"

UPLOAD_LINK=$(curl -sk --noproxy '*' "${R[@]}" -H "Authorization: Token $TOKEN" \
                "$P/api2/repos/$REPO_ID/upload-link/" | tr -d '"')
case "$UPLOAD_LINK" in
  "https://$DOMAIN/seafhttp/"*) ok "上传地址是 https 且指向代理域名（FILE_SERVER_ROOT 正确）" ;;
  *) die "上传地址是 [$UPLOAD_LINK] —— 期望以 https://$DOMAIN/seafhttp/ 开头。
       出现 http:// 或容器名，说明 SEAFILE_SERVER_PROTOCOL / SERVICE_URL 没生效，
       生产上的症状正是「页面能开、上传下载坏」" ;;
esac

echo "rehearsal-$(date +%s)" > "$J/payload.txt"
# ⚠️ 对 fileserver 的 POST 也要带 Authorization 头 —— 官方 web API 文档的示例就带着。
# 不带的话 fileserver 回 {"error": "Access token not found."}（2026-09-21 实测；
# 这个错误串不在 seahub 源码里，是 C 写的 fileserver 吐的，别去 Django 里找）。
# || true：curl 传输层失败（非 HTTP 错误）时不许 set -e 直接杀掉脚本 ——
# 那样只会看到「清理现场」，一句诊断都没有（2026-09-21 就这么白跑过一轮）。
# 失败会让 UP 为空/含 error，下面的判断会把话说明白。
UP=$(curl -sk --noproxy '*' "${R[@]}" -H "Authorization: Token $TOKEN" \
       -F "file=@$J/payload.txt" -F "parent_dir=/" -F "replace=1" \
       "$(rp_url "$UPLOAD_LINK")" 2>"$J/up.err") || true
[ -s "$J/up.err" ] && { cat "$J/up.err" >&2; info "（上传请求的 stderr 见上）"; }
# 成功的返回就是【裸的】40 位文件 id（无引号无 JSON 包装）——别按 JSON 去 grep。
echo "$UP" | grep -qE '^[0-9a-f]{40}$' || die "上传返回不含文件 id：$UP"
ok "上传成功"

DL=$(curl -sk --noproxy '*' "${R[@]}" -H "Authorization: Token $TOKEN" \
       "$P/api2/repos/$REPO_ID/file/?p=/payload.txt&reuse=1" 2>/dev/null | tr -d '"') || true
case "$DL" in
  "https://$DOMAIN/seafhttp/"*) ok "下载地址同样是 https 代理域名" ;;
  *) die "下载地址是 [$DL] —— 与上传地址同源问题" ;;
esac
curl -sk --noproxy '*' "${R[@]}" -o "$J/back.txt" "$(rp_url "$DL")"
cmp -s "$J/payload.txt" "$J/back.txt" || die "下载回来的内容与上传的不一致"
ok "下载内容与上传逐字节一致"

# ---------------------------------------------------------------- 9. 对照探针
step "9. 对照探针：域名入口怎么转发都通；IP 直连是原版行为"
# P1-P3 的 Host / Referer / Origin 完全相同（都是浏览器经云代理访问时真实会发的值），
# 唯一变量是 X-Forwarded-Proto 有无、及其值。直连容器 80，绕过代理。
# P4 另走一条：Host/Origin 全是 IP——局域网直连用户的真实形态。
C="http://127.0.0.1:$HOST_PORT"
probe() {  # $1 = X-Forwarded-Proto 的值；空串 = 不发这个头
  local j; j=$(mktemp -d)
  local -a H=(); [ -n "$1" ] && H=(-H "X-Forwarded-Proto: $1")
  curl -s --noproxy '*' -c "$j/cj" -o "$j/l.html" -H "Host: $DOMAIN" "$C/accounts/login/"
  local t; t=$(sed -n 's/.*name="csrfmiddlewaretoken" value="\([^"]*\)".*/\1/p' "$j/l.html" | head -1)
  # ⚠️ 必须是 ${H[@]+"${H[@]}"} 这种写法，不能直接写 "${H[@]}"：
  # macOS 自带的是 bash 3.2，空数组在 set -u 下展开会直接报 "H[@]: unbound variable"。
  # 踩中的正好是 P3（不发头那条），也就是最有意思的那一条。
  curl -s --noproxy '*' -b "$j/cj" -o /dev/null -w '%{http_code}' ${H[@]+"${H[@]}"} \
    -H "Host: $DOMAIN" -H "Referer: $O/accounts/login/" -H "Origin: $O" \
    --data-urlencode "csrfmiddlewaretoken=$t" \
    --data-urlencode "login=$ADMIN_EMAIL" \
    --data-urlencode "password=$ADMIN_PW" \
    --data-urlencode "next=/" "$C/accounts/login/"
  rm -rf "$j"
}
# 2026-09-22 定稿的规则按【访问入口】分流：Host=域名 → 恒 https（P1/P2/P3 验这条，
# 转发头对错都不影响）；Host=其它（IP 直连）→ 原版行为，按明文 http 如实处理（P4）。
# P4 是生产实测撞出来的需求：上游原版镜像 IP 直连能登录，「恒判 https」那版把它
# 掐死了（403），用户原话「不配域名就不让访问了吗」——对，不能。这条断言钉住它。
P1=$(probe https); P2=$(probe http); P3=$(probe '')
assert_eq "$P1" "302" "P1 带头 https → 302（域名入口链路健康）"
assert_eq "$P2" "302" "P2 带头 http  → 302（**域名入口免疫乱发转发头**：Host=域名时恒判 https，不看 X-Forwarded-Proto 的值）"
assert_eq "$P3" "302" "P3 不发该头   → 302（域名入口同样免疫缺头：代理不配转发头也不 403）"

probe_ip() {  # 原版直连行为：无转发头、Host/Referer/Origin 全是 IP（http）
  local j; j=$(mktemp -d)
  local B="http://127.0.0.1:$HOST_PORT"
  curl -s --noproxy '*' -c "$j/cj" -o "$j/l.html" "$B/accounts/login/"
  local t; t=$(sed -n 's/.*name="csrfmiddlewaretoken" value="\([^"]*\)".*/\1/p' "$j/l.html" | head -1)
  curl -s --noproxy '*' -b "$j/cj" -o /dev/null -w '%{http_code}' \
    -H "Referer: $B/accounts/login/" -H "Origin: $B" \
    --data-urlencode "csrfmiddlewaretoken=$t" \
    --data-urlencode "login=$ADMIN_EMAIL" \
    --data-urlencode "password=$ADMIN_PW" \
    --data-urlencode "next=/" "$B/accounts/login/"
  rm -rf "$j"
}
P4=$(probe_ip)
assert_eq "$P4" "302" "P4 IP 直连（无转发头）→ 302（**原版行为**：按明文 http 如实处理，不配域名也能登录）"

# ---- 9b. 钉钉回调跟随发起域名（多入口部署，2026-09-24 生产形态）----
# 生产形态：内网用户走主域名（Host=server_name），外网用户走云反代的第二域名
# （Host≠server_name + XFP: https）。钉钉 redirect_uri 必须回到【发起的那个域名】，
# 否则 state 所在的会话 cookie（按 host 隔离）读不到 → invalid state（第 0010 补丁）。
# 探针直连容器 80，各带自己的 Host/XFP 组合，断言 302 Location 里的 redirect_uri
# （urlencode 形式）跟着 Host 走。凭据是彩排专用假值——视图在构造 URL 时并不校验它们。
dingtalk_redirect_uri_host() {  # $1=Host, $2=XFP 值（空=不发）
  local -a H=(); [ -n "$2" ] && H=(-H "X-Forwarded-Proto: $2")
  local loc; loc=$(curl -s --noproxy '*' -o /dev/null -w '%{redirect_url}' ${H[@]+"${H[@]}"} \
    -H "Host: $1" "http://127.0.0.1:$HOST_PORT/dingtalk/login/")
  # Location 形如 https://login.dingtalk.com/...?redirect_uri=https%3A%2F%2F<host>%2Fdingtalk%2Fcallback%2F...
  printf '%s' "$loc" | sed -n 's/.*redirect_uri=https%3A%2F%2F\([^%]*\)%2Fdingtalk.*/\1/p'
}
D1=$(dingtalk_redirect_uri_host "$DOMAIN" '')
assert_eq "$D1" "$DOMAIN" "D1 主域名发起（Host=server_name，无转发头）→ redirect_uri 回主域名"
ALT_DOMAIN='i-disc.example.test'
D2=$(dingtalk_redirect_uri_host "$ALT_DOMAIN" 'https')
assert_eq "$D2" "$ALT_DOMAIN" "D2 第二域名发起（Host≠server_name + XFP https，云反代形态）→ redirect_uri 回第二域名"

# ---------------------------------------------------------------- 10. 升级 / 回滚
step "10. 升级路径（通道没动 → 应当是无操作）"
BEFORE=$("${DC[@]}" ps --format '{{.Image}}' seafile 2>/dev/null || echo '')
"${DC[@]}" pull >/dev/null 2>&1
"${DC[@]}" up -d >/dev/null 2>&1
AFTER=$("${DC[@]}" ps --format '{{.Image}}' seafile 2>/dev/null || echo '')
assert_eq "$AFTER" "$BEFORE" "pull && up -d 之后镜像没变（通道未动 = 无操作）"

# ---- 10b. 已有数据卷 + 模板更新：滞留的旧 conf 必须被自动重渲染 ----
# 数据卷里的 nginx conf 是首启渲染的一次性产物，上游只在文件缺失时渲染——镜像
# 模板更新后旧 conf 无限滞留。2026-09-22 生产 403 第三形态正撞在这里：用户拉了
# 三版新镜像，容器里跑的仍是首启那版规则（远程探针实证 XFP=http→302 / 无头→403）。
# 彩排每次都是全新卷，结构上测不到这条路径——所以这里手工制造「滞留」再重启钉死它。
step "10b. 已有卷 + 模板更新：旧 conf 自动重渲染（2026-09-22 生产 403 第三形态）"
printf '# 旧模板渲染的滞留件（模拟 2026-09-22 那台生产机）\nset $seafile_fwd_proto https;\n' \
  > "$WD/data/nginx/conf/seafile.nginx.conf"
rm -f "$WD/data/nginx/conf/.render-inputs.sha"
"${DC[@]}" restart seafile >/dev/null 2>&1
CODE=000
for i in $(seq 1 60); do
  CODE=$(curl -sk --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 10 \
           --resolve "$DOMAIN:$PROXY_PORT:127.0.0.1" "https://$DOMAIN:$PROXY_PORT/accounts/login/" || true)
  [ "$CODE" = "200" ] && break
  sleep 10
done
assert_eq "$CODE" "200" "restart 后容器回来了（登录页 200）"
assert_has "$WD/data/nginx/conf/seafile.nginx.conf" 'if ($http_host = $server_name)' \
  "滞留的旧 conf 被 sync_nginx_conf 自动重渲染（新规则已生效）"
ls "$WD/data/nginx/conf/" | grep -q '^seafile\.nginx\.conf\.bak-' \
  || die "旧 conf 没有被挪走为 .bak（sync_nginx_conf 没跑？）"
ok "旧 conf 已备份为 .bak-*，重渲染完成"

step "11. 回滚机制（内联一个不可变 tag，不改任何文件）"
# 确定性断言：内联变量确实能盖住 compose 里的通道默认值。
# 这条是回滚能工作的全部机制 —— 它成立，回滚就成立。
ROLLBACK_TAG='ghcr.io/topiceyes/seafile-mc:12.0.14-dingtalk.9.ed2042da'
RESOLVED=$(SEAFILE_PRO_IMAGE="$ROLLBACK_TAG" "${DC[@]}" config \
           | awk '/^  seafile:/{f=1} f && /image:/{print $2; exit}')
assert_eq "$RESOLVED" "$ROLLBACK_TAG" "内联 SEAFILE_PRO_IMAGE 能覆盖 compose 里的通道 tag"
info "真机上回滚 = 把这条内联变量换成 Releases 里想回到的那个 tag，跑 pull && up -d"
info "想在本机真跑一次回滚演练：./rehearsal-rp.sh --keep --tag $ROLLBACK_TAG"

printf '\n\033[1;32m════ 反代模式彩排全部通过 ════\033[0m\n'
printf '它证明了：容器 + Django 在「TLS 在代理终止」这个输入下是对的，\n'
printf '且是在【真实拉回来的 amd64 字节】上对的。\n'
printf '它【没有】证明：你的云代理配置是对的 —— 上线后仍要用真域名复验一次表单登录。\n'
printf '（详见 docs/007 §7.2 的覆盖边界表）\n'
