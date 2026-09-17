#!/usr/bin/env bash
# 生成本地开发用的自签 TLS 证书（证书与私钥不入库，见 .gitignore）。
# 详见 docs/006。
set -euo pipefail

cd "$(dirname "$0")"

SSL_DIR="seafile-data/ssl"
CN="${1:-127.0.0.1}"

mkdir -p "$SSL_DIR"

if [[ -f "$SSL_DIR/$CN.crt" ]]; then
    echo "$SSL_DIR/$CN.crt 已存在，跳过。要重新生成请先删除该文件。"
    exit 0
fi

openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout "$SSL_DIR/$CN.key" \
    -out    "$SSL_DIR/$CN.crt" \
    -subj "/CN=$CN" \
    -addext "subjectAltName=IP:$CN,DNS:localhost,DNS:seafile-dev.test"

echo
echo "已生成 $SSL_DIR/$CN.crt|key（有效期 3650 天）。"
echo "客户端信任：把 $SSL_DIR/$CN.crt 导入系统钥匙串并设为「始终信任」。"
