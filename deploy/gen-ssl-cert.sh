#!/usr/bin/env bash
# 生成本地开发/彩排用的自签 TLS 证书（证书与私钥不入库）。
#
#   ./gen-ssl-cert.sh [127.0.0.1]     # dev：IP 证书（默认）
#   ./gen-ssl-cert.sh example.com     # 彩排：域名证书（有效期 >30 天，
#                                     #   init_letsencrypt 见到即跳过签发，见 docs/007 彩排章节）
#   SEAFILE_VOLUME=./rehearsal-data ./gen-ssl-cert.sh example.com   # 输出到指定数据卷
set -euo pipefail

cd "$(dirname "$0")"

if [[ ! -f .env ]]; then
    echo "错误：找不到 deploy/.env。" >&2; exit 1
fi

CN="${1:-127.0.0.1}"
# 数据卷目录：优先环境变量，其次 .env 里的 SEAFILE_VOLUME，最后 ./seafile-data
SHARED="${SEAFILE_VOLUME:-$(grep -oP "^SEAFILE_VOLUME='\K[^']+" .env 2>/dev/null || echo seafile-data)}"
SSL_DIR="$SHARED/ssl"

mkdir -p "$SSL_DIR"

if [[ -f "$SSL_DIR/$CN.crt" ]]; then
    echo "$SSL_DIR/$CN.crt 已存在，跳过。要重新生成请先删除该文件。"
    exit 0
fi

# SAN 按类型自适应：IP 证书 vs 域名证书
if [[ "$CN" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    SAN="IP:$CN,DNS:localhost"
else
    SAN="DNS:$CN,DNS:localhost"
fi

openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout "$SSL_DIR/$CN.key" \
    -out    "$SSL_DIR/$CN.crt" \
    -subj "/CN=$CN" \
    -addext "subjectAltName=$SAN"

echo
echo "已生成 $SSL_DIR/$CN.crt|key（3650 天，SAN: ${SAN}）。"
echo "浏览器/客户端信任：把 $CN.crt 导入系统钥匙串并设为「始终信任」。"
