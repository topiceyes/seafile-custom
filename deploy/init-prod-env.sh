#!/usr/bin/env bash
# 生产 .env 生成器：把「要人填的」压到 4 项，密钥全部自动生成。
#
#   ./init-prod-env.sh                          # 交互式
#   ./init-prod-env.sh --domain seafile.x.com \
#                      --admin-email admin@x.com \
#                      --admin-password 'xxx' \
#                      --dingtalk-key 'xxx' --dingtalk-secret 'xxx'    # 脚本化/无人值守
#
# 为什么要有这个脚本：手抄 .env 有三类坑——密钥生成命令记错、改错行（比如动了
# 不该动的 SEAFILE_SERVER_LETSENCRYPT）、把 ' 写进单引号值里导致 .env 解析错乱。
# 这里三件事一起解决：密钥自动生成、只改该改的行、值统一做引号检查。
#
# 钉钉凭据可以留空：它们写进 seahub_settings.py 的是 constance 默认值，
# 装完在「系统管理 → 设置」里填也能生效，不必重启（见 docs/002）。
set -euo pipefail

cd "$(dirname "$0")"

TEMPLATE=.env.prod.example
TARGET=.env

DOMAIN=''; ADMIN_EMAIL=''; ADMIN_PASSWORD=''; DT_KEY=''; DT_SECRET=''
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

# ---- 覆盖保护：.env 里有真实密钥，绝不静默重建 ----
if [ -f "$TARGET" ]; then
  echo "⚠️  $TARGET 已存在。"
  echo "    它含真实密钥（数据库密码、JWT 密钥）。重建会换掉这些值，"
  echo "    而已初始化的数据卷里的数据库密码是【旧值】——换掉后服务连不上数据库。"
  echo
  echo "    · 想改配置：直接 vi $TARGET"
  echo "    · 全新部署但要重来：先删掉数据卷，再删 $TARGET"
  echo
  if [ ! -t 0 ]; then
    die "$TARGET 已存在，非交互模式下拒绝覆盖"
  fi
  printf '    确实要覆盖吗？输入 yes 继续：'
  read -r ans
  [ "$ans" = "yes" ] || { echo "已取消，$TARGET 未改动。"; exit 1; }
fi

# ---- 收集 4 个必填项 ----
# 回显结果到 stdout（不用 nameref，macOS 自带的 bash 3.2 不支持 local -n）
ask() {  # ask <当前值> <提示语> <参数名> <默认值>
  local cur="$1" hint="$2" flag="$3" def="${4:-}" ans=''
  if [ -n "$cur" ]; then printf '%s' "$cur"; return 0; fi
  if [ ! -t 0 ]; then die "非交互模式必须给 --$flag"; fi
  if [ -n "$def" ]; then read -r -p "  $hint [$def]: " ans; ans="${ans:-$def}"
  else                   read -r -p "  $hint: " ans; fi
  printf '%s' "$ans"
}

# 有限输入的 openssl 管道，不会踩 pipefail+SIGPIPE（/dev/urandom|head 会）
gen_password() { LC_ALL=C openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-20; }

echo "=== 生产 .env 生成 ==="
echo
echo "只有 4 项要填（密钥自动生成）。钉钉凭据可以留空，装完在管理后台填也行。"
echo

DOMAIN=$(ask "$DOMAIN" "站点域名（用户在浏览器里输入的那个，不带 https://）" domain "")
no_quote "域名" "$DOMAIN"
[ -n "$DOMAIN" ] || die "域名不能为空"
case "$DOMAIN" in
  *"/"*|*:*) die "域名只填纯域名，不要带 http:// 或端口：$DOMAIN" ;;
esac

ADMIN_EMAIL=$(ask "$ADMIN_EMAIL" "管理员邮箱" admin-email "")
no_quote "管理员邮箱" "$ADMIN_EMAIL"
case "$ADMIN_EMAIL" in *'@'*) ;; *) die "管理员邮箱看起来不像邮箱：$ADMIN_EMAIL" ;; esac

GENERATED_ADMIN_PW=0
if [ -z "$ADMIN_PASSWORD" ]; then
  if [ -t 0 ]; then
    printf '  管理员密码（直接回车 = 自动生成强密码）: '
    read -r ADMIN_PASSWORD
  fi
  if [ -z "$ADMIN_PASSWORD" ]; then
    ADMIN_PASSWORD=$(gen_password)
    GENERATED_ADMIN_PW=1
  fi
fi
no_quote "管理员密码" "$ADMIN_PASSWORD"

if [ -z "$DT_KEY" ] && [ -t 0 ]; then
  printf '  钉钉 AppKey（可留空，装完在管理后台填）: '
  read -r DT_KEY
fi
if [ -z "$DT_KEY" ] && [ ! -t 0 ]; then :; fi
if [ -n "$DT_KEY" ] && [ -z "$DT_SECRET" ] && [ -t 0 ]; then
  printf '  钉钉 AppSecret: '
  read -r DT_SECRET
fi
no_quote "钉钉 AppSecret" "$DT_SECRET"

# ---- 生成密钥 ----
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
grep -q "^SEAFILE_PRO_IMAGE='ghcr.io/" "$TARGET" \
  || die "SEAFILE_PRO_IMAGE 不是 ghcr.io 镜像"
# 占位符没被替换完 = 有必填项漏了
if grep -qE "^[A-Z_]+='(change-me|seafile\.example\.com|admin@example\.com)'" "$TARGET"; then
  die "还有占位符未替换：$(grep -oE "^[A-Z_]+='(change-me|seafile\.example\.com|admin@example\.com)'" "$TARGET" | tr '\n' ' ')"
fi

echo
echo "✅ 已生成 ${TARGET}（权限 600，含明文密钥，勿入库）"
echo "   域名      : $DOMAIN"
echo "   管理员    : $ADMIN_EMAIL"
if [ "$GENERATED_ADMIN_PW" = "1" ]; then
  echo "   管理员密码: $ADMIN_PASSWORD    ← 自动生成，现在就存进密码管理器"
fi
if [ -n "$DT_KEY" ]; then echo "   钉钉凭据  : 已填"
else                        echo "   钉钉凭据  : 留空（装完在管理后台「设置」页填）"; fi
echo
echo "接下来："
echo "  mkdir -p /data/seafile /data/seafile-mysql"
echo "  docker compose pull"
echo "  docker compose up -d db memcached"
echo "  docker exec seafile-mysql mariadb -uroot -p'$MYSQL_ROOT_PW' -e 'select 1'   # 返回 1 再继续"
echo "  docker compose up -d seafile"
echo "  ./init-conf.sh --prod          # 首启完成后跑，只做一次"
