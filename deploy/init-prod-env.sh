#!/usr/bin/env bash
# 生产 .env 生成器：零提问。密钥全自动生成，域名先用占位值。
#
#   ./init-prod-env.sh                                   # 什么都不用给，直接跑
#   ./init-prod-env.sh --domain seafile.acme.cn          # 域名已经定了就带上
#   ./init-prod-env.sh --admin-email me@acme.cn --admin-password 'xxx'
#
# 设计原则：**部署时不必知道任何"以后能改"的东西。**
#   · 域名     → 先用占位值当初始默认，装完在「系统管理 → 设置 → Site URL」填真的，免重启
#                （补丁 0009 把 SERVICE_URL 挪进了 constance，见 docs/011）
#   · 钉钉凭据 → 留空，装完在同一页填，免重启生效（docs/002）
#   · 管理员密码 → 自动生成并打印，登录后自己改
# 所以这个脚本问都不用问，跑完直接起服务。
#
# 它顺手防掉手抄 .env 的三类坑：密钥生成命令记错、改错行（比如动了不该动的
# SEAFILE_SERVER_LETSENCRYPT）、把单引号写进 '值' 里导致解析错乱。
set -euo pipefail

cd "$(dirname "$0")"

TEMPLATE=.env.prod.example
TARGET=.env
COMPOSE=seafile-prod.yml

# 占位域名：故意用 .local（不可能是真实域名），提醒你还没配真域名
PLACEHOLDER_DOMAIN=seafile.local

DOMAIN="$PLACEHOLDER_DOMAIN"
ADMIN_EMAIL=''; ADMIN_PASSWORD=''
DT_KEY=''; DT_SECRET=''
while [ $# -gt 0 ]; do
  case "$1" in
    --domain)          DOMAIN="${2:?}";         shift 2 ;;
    --admin-email)     ADMIN_EMAIL="${2:?}";    shift 2 ;;
    --admin-password)  ADMIN_PASSWORD="${2:?}"; shift 2 ;;
    --dingtalk-key)    DT_KEY="${2:?}";         shift 2 ;;
    --dingtalk-secret) DT_SECRET="${2:?}";      shift 2 ;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数：$1（--help 看用法）" >&2; exit 1 ;;
  esac
done

die() { echo "错误：$*" >&2; exit 1; }
# .env 用 '值' 形式，值里出现单引号会把它截断
no_quote() { case "$2" in *"'"*) die "$1 不能含单引号（会破坏 .env 解析）";; esac; }

[ -f "$TEMPLATE" ] || die "找不到 ${TEMPLATE}（应在 deploy/ 下）"
command -v openssl >/dev/null || die "缺 openssl（用来生成密钥）；Debian/Ubuntu: apt install openssl"

# ---- 迁移提醒：.env 里不该再有镜像版本 ----
#
# 镜像版本已挪进【入库的】compose 文件（见 docs/007 §6）。.env 里若还留着这一行，
# 它会【覆盖】compose 的默认值 —— 那正是要消灭的「改了没生效」：仓库里换了版本，
# 服务器却按 .env 里的旧值跑，而且不报错。
#
# 这里是警告、不是拒绝：.env 含真实密钥，本脚本对已存在的文件一向不动手。
# 放在覆盖保护【之前】——否则永远走不到（下一段对已存在的 .env 直接 die）。
if [ -f "$TARGET" ] && grep -q "^SEAFILE_PRO_IMAGE=" "$TARGET"; then
  echo "⚠️  ${TARGET} 里还有 SEAFILE_PRO_IMAGE —— 它会盖掉 ${COMPOSE} 里钉的版本。"
  echo "    镜像版本已挪进 ${COMPOSE}。迁移：注释掉 ${TARGET} 里那一行，"
  echo "    之后升级只要重取 deploy/ + docker compose pull && docker compose up -d。"
  echo
fi

# ---- 覆盖保护：.env 里有真实密钥，绝不静默重建 ----
if [ -f "$TARGET" ]; then
  echo "⚠️  ${TARGET} 已存在。"
  echo "    它含真实密钥（数据库密码、JWT 密钥）。重建会换掉这些值，"
  echo "    而已初始化的数据卷里的数据库密码是【旧值】——换掉后服务连不上数据库。"
  echo
  echo "    · 想改域名：首启前直接 vi ${TARGET}；首启后在「系统管理 → 设置 → Site URL」改"
  echo "    · 想改别的：直接 vi $TARGET"
  echo "    · 全新部署但要重来：先删掉数据卷，再删 $TARGET"
  echo
  if [ ! -t 0 ]; then
    die "$TARGET 已存在，非交互模式下拒绝覆盖"
  fi
  printf '    确实要覆盖吗？输入 yes 继续：'
  read -r ans
  [ "$ans" = "yes" ] || { echo "已取消，$TARGET 未改动。"; exit 1; }
fi

# 有限输入的 openssl 管道，不会踩 pipefail+SIGPIPE（/dev/urandom|head 会）
gen_password() { LC_ALL=C openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-20; }

# ---- 校验命令行给的域名 ----
no_quote "域名" "$DOMAIN"
case "$DOMAIN" in
  *"/"*|*:*) die "域名只填纯域名，不要带 http:// 或端口：$DOMAIN" ;;
esac

# ---- 生成 ----
[ -n "$ADMIN_EMAIL" ]    || ADMIN_EMAIL="admin@${DOMAIN}"
GENERATED_ADMIN_PW=0
[ -n "$ADMIN_PASSWORD" ] || { ADMIN_PASSWORD=$(gen_password); GENERATED_ADMIN_PW=1; }
no_quote "管理员邮箱" "$ADMIN_EMAIL"
no_quote "管理员密码" "$ADMIN_PASSWORD"
no_quote "钉钉 AppSecret" "$DT_SECRET"

MYSQL_ROOT_PW=$(openssl rand -hex 16)
MYSQL_DB_PW=$(openssl rand -hex 16)
JWT_KEY=$(openssl rand -base64 48 | tr -d '\n')

cp "$TEMPLATE" "$TARGET"
chmod 600 "$TARGET"          # 含明文密钥，先收紧权限再写

# ---- 只替换这几行，模板其余内容（含反代模式两个开关）原样保留 ----
# 值经 ENVIRON 传入：awk 的 -v 会解释值里的反斜杠转义，ENVIRON 不会。
set_env() {
  local key="$1" val="$2"
  if grep -q "^${key}=" "$TARGET"; then
    NEWVAL="$val" awk -v k="$key" '
      $0 ~ "^"k"=" { print k"=\047"ENVIRON["NEWVAL"]"\047"; next } { print }
    ' "$TARGET" > "$TARGET.tmp" && chmod 600 "$TARGET.tmp" && mv "$TARGET.tmp" "$TARGET"
  else
    printf "%s='%s'\n" "$key" "$val" >> "$TARGET"
  fi
}

set_env SEAFILE_DOMAIN              "$DOMAIN"
set_env SEAFILE_MYSQL_ROOT_PASSWORD "$MYSQL_ROOT_PW"
set_env SEAFILE_MYSQL_DB_PASSWORD   "$MYSQL_DB_PW"
set_env JWT_PRIVATE_KEY             "$JWT_KEY"
set_env SEAFILE_ADMIN_EMAIL         "$ADMIN_EMAIL"
set_env SEAFILE_ADMIN_PASSWORD      "$ADMIN_PASSWORD"
set_env SEAHUB_DINGTALK_APP_KEY     "$DT_KEY"
set_env SEAHUB_DINGTALK_APP_SECRET  "$DT_SECRET"

# ---- 自检：反代模式的两个开关必须没被动过；值不能被写坏 ----
grep -q "^SEAFILE_SERVER_LETSENCRYPT='false'" "$TARGET" \
  || die "SEAFILE_SERVER_LETSENCRYPT 不是 false —— 反代模式下容器必须只监听 80"
grep -q "^SEAFILE_SERVER_PROTOCOL='https'" "$TARGET" \
  || die "SEAFILE_SERVER_PROTOCOL 不是 https —— 会导致 SERVICE_URL 生成 http 链接"
grep -qE '^[[:space:]]+image: \$\{SEAFILE_PRO_IMAGE:-ghcr\.io/topiceyes/seafile-mc@sha256:[0-9a-f]{64}\}' "$COMPOSE" \
  || die "${COMPOSE} 的 seafile 镜像没有钉死 digest 的默认值（\${SEAFILE_PRO_IMAGE:-ghcr.io/…@sha256:…}）——取部署文件后这一行丢了？"
if grep -qE "^[A-Z_]+='(change-me|seafile\.example\.com|admin@example\.com)'" "$TARGET"; then
  die "还有占位符未替换：$(grep -oE "^[A-Z_]+='(change-me|seafile\.example\.com|admin@example\.com)'" "$TARGET" | tr '\n' ' ')"
fi

# ---- 把生成的密码留在终端上 ----
echo
echo "✅ 已生成 ${TARGET}（权限 600，含明文密钥，勿入库）"
echo
echo "  ┌─ 现在抄进密码管理器 ─────────────────────────────────"
echo "  │ 管理员账号：${ADMIN_EMAIL}"
if [ "$GENERATED_ADMIN_PW" = "1" ]; then
  echo "  │ 管理员密码：${ADMIN_PASSWORD}   ← 自动生成，只显示这一次"
else
  echo "  │ 管理员密码：（用你 --admin-password 给的那个）"
fi
echo "  │ 数据库 root：${MYSQL_ROOT_PW}"
echo "  └──────────────────────────────────────────────────────"
echo "    （数据库密码等已写进 .env，这里列出只是为了让你留底）"
echo
if [ "$DOMAIN" = "$PLACEHOLDER_DOMAIN" ]; then
  echo "ℹ️  域名用的是占位值 ${DOMAIN} —— 它只是个初始默认值，不影响首启。"
  echo "     装完在「系统管理 → 设置 → Site URL」填真域名，免重启（docs/011）"
else
  echo "ℹ️  域名：${DOMAIN}（装完也能在「系统管理 → 设置 → Site URL」随时改）"
fi
echo "ℹ️  钉钉凭据留空 —— 装完在「系统管理 → 设置」页填即可，免重启（docs/002）"
echo
echo "下一步（照抄）："
echo "  mkdir -p /data/seafile /data/seafile-mysql"
echo "  docker compose pull"
echo "  docker compose up -d           # 一条命令起全部；db 的 healthcheck 会自动排好顺序"
echo "                                 # 二开定制的追加由镜像内自动完成，没有下一步了"
