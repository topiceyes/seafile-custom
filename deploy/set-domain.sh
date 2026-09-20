#!/usr/bin/env bash
# 装完之后改站点域名（首启用的是占位域名，等真域名定了再跑这个）。
#
#   ./set-domain.sh seafile.acme.cn
#
# 为什么需要它：域名只在【首启】被写进三处，之后改 .env 里的 SEAFILE_DOMAIN 不再生效
# （container 只在 /shared/nginx/conf/seafile.nginx.conf 不存在时才渲染）。三处是：
#
#   1. seahub_settings.py 的 SERVICE_URL     ← 唯一真正要紧的一处
#   2. seahub_settings.py 的 FILE_SERVER_ROOT ← 文件上传下载走它
#   3. nginx conf 的 server_name              ← 反代模式下只有一个 server 块，装饰性
#
# 而钉钉回调地址是用 get_site_scheme_and_netloc() 现算的（源头就是 SERVICE_URL），
# 所以改完 1 之后回调 URL 会跟着变，不用改代码——但【钉钉后台里的回调域名要手工改】。
set -euo pipefail

cd "$(dirname "$0")"

die() { echo "错误：$*" >&2; exit 1; }
no_quote() { case "$1" in *"'"*) die "域名不能含单引号";; esac; }

NEW_DOMAIN="${1:-}"
if [ -z "$NEW_DOMAIN" ]; then
  echo "用法：./set-domain.sh <新域名>"
  echo "例：  ./set-domain.sh seafile.acme.cn"
  exit 1
fi
no_quote "$NEW_DOMAIN"
case "$NEW_DOMAIN" in
  *"/"*|*:*) die "只填纯域名，不要带 http:// 或端口：$NEW_DOMAIN" ;;
esac

[ -f .env ] || die "找不到 .env（生产配置，由 init-prod-env.sh 生成）"

# 从 .env 读数据卷位置与协议
VOLUME=$(sed -n "s/^SEAFILE_VOLUME='\(.*\)'$/\1/p" .env | head -1)
[ -n "$VOLUME" ] || die ".env 里读不到 SEAFILE_VOLUME"
PROTO=$(sed -n "s/^SEAFILE_SERVER_PROTOCOL='\(.*\)'$/\1/p" .env | head -1)
PROTO="${PROTO:-https}"

SS="$VOLUME/seafile/conf/seahub_settings.py"
NGX="$VOLUME/nginx/conf/seafile.nginx.conf"

if [ ! -f "$SS" ]; then
  die "找不到 $SS —— 说明还没首启过。
     首启前不需要用它：直接改 .env 里的 SEAFILE_DOMAIN，然后按正常流程启动即可。"
fi

# 取 SERVICE_URL 里的域名。两个讲究：
#   · 用 -E 而非 \?（BSD sed 不支持 \?）——这个脚本要能在 macOS 上测、Linux 上跑
#   · 字符类必须同时排除单双引号：SERVICE_URL 的引号两种都可能出现（首启写的是 "，
#     手工改过 / 老版本可能是 '），漏掉一个就会把引号带进域名，后续 grep 全落空
OLD_DOMAIN=$(grep -m1 '^SERVICE_URL' "$SS" | sed -E "s|.*//([^/\"']*).*|\1|")
case "$OLD_DOMAIN" in
  *SERVICE_URL*) OLD_DOMAIN='' ;;   # 没匹配上（格式意外），别拿整行去当域名
esac
NOW=$(date +%Y%m%d-%H%M%S)

if [ "$OLD_DOMAIN" = "$NEW_DOMAIN" ]; then
  echo "域名已经是 ${NEW_DOMAIN}，无需改动。"
  exit 0
fi

echo "域名变更：${OLD_DOMAIN:-（读不到）} → ${NEW_DOMAIN}"
echo "  协议      : ${PROTO}"
echo "  数据卷    : ${VOLUME}"
echo

# 先备份：这两个文件手工改坏过就很难查
cp "$SS"  "$SS.bak-$NOW"
echo "  备份  $SS.bak-$NOW"

# 重写 KEY = '...' / KEY = "..." 行；值经 ENVIRON 传入（awk -v 会解释反斜杠转义）
set_py() {  # set_py <文件> <KEY> <值>
  local f="$1" k="$2" v="$3"
  grep -q "^${k} *=" "$f" || { echo "    ⚠️  $f 里没有 ${k}，跳过（首启没写全？）"; return 0; }
  NEWVAL="$v" awk -v k="$k" '
    $0 ~ "^"k" *=" { print k" = \""ENVIRON["NEWVAL"]"\""; next } { print }
  ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  echo "  改    ${k} = \"${v}\""
}

set_py "$SS" SERVICE_URL      "${PROTO}://${NEW_DOMAIN}"
set_py "$SS" FILE_SERVER_ROOT "${PROTO}://${NEW_DOMAIN}/seafhttp"

if [ ! -f "$NGX" ]; then
  echo "  ⚠️  找不到 ${NGX}（反代模式下它是装饰性的，不影响使用）"
elif [ -z "$OLD_DOMAIN" ]; then
  echo "  ⚠️  读不到旧域名，跳过 nginx 改动。请手工把 ${NGX} 里 server_name 那行改掉"
  echo "      （可能有多个 server 块，别动 'server_name _ default_server;' 那行）"
elif ! grep -q "server_name[[:space:]]*${OLD_DOMAIN}" "$NGX"; then
  echo "  ⚠️  ${NGX} 里没有 'server_name ${OLD_DOMAIN}'，跳过（可能已改过，或用了别的写法）"
else
  cp "$NGX" "$NGX.bak-$NOW"
  echo "  备份  $NGX.bak-$NOW"
  # 只替换【含旧域名】的那一行。无差别替换所有 server_name 会误伤
  # 'server_name _ default_server;'（80 端口的 catch-all），把默认虚拟主机搞坏。
  OLDVAL="$OLD_DOMAIN" NEWVAL="$NEW_DOMAIN" awk '
    /^[[:space:]]*server_name[[:space:]]/ && index($0, ENVIRON["OLDVAL"]) {
      print "server_name " ENVIRON["NEWVAL"] ";"; next
    }
    { print }
  ' "$NGX" > "$NGX.tmp" && mv "$NGX.tmp" "$NGX"
  echo "  改    nginx server_name：${OLD_DOMAIN} → ${NEW_DOMAIN}"
fi

# .env 也同步，免得下次有人看 .env 以为是旧域名
NEWVAL="$NEW_DOMAIN" awk '
  /^SEAFILE_DOMAIN=/ { print "SEAFILE_DOMAIN=\x27"ENVIRON["NEWVAL"]"\x27"; next } { print }
' .env > .env.tmp && mv .env.tmp .env
echo "  改    .env 的 SEAFILE_DOMAIN"

echo
echo "✅ 完成。生效需要重启（数据卷不动）："
echo "    docker compose restart seafile"
echo
echo "还要手工做的一件事："
echo "    钉钉开发者后台 → 应用 → 回调域名改成  ${PROTO}://${NEW_DOMAIN}/dingtalk/callback/"
echo
echo "验证：浏览器打开 ${PROTO}://${NEW_DOMAIN}/，然后试一次【文件上传 + 下载】"
echo "      （这条过了就说明 SERVICE_URL / FILE_SERVER_ROOT 都对）"
