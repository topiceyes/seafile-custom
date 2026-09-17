#!/bin/bash
# 重新构建 seahub 前端并部署进容器
# 用法：./rebuild-frontend.sh
# 说明：容器内静态文件在镜像层（/shared 卷之外），容器重建后会丢失，需重跑本脚本。
set -euo pipefail

SEAHUB_DIR="$(cd "$(dirname "$0")/../seahub" && pwd)"
CONTAINER=seafile
INSTALL_PATH=/opt/seafile/seafile-server-12.0.14/seahub

echo "==> [1/4] npm build（宿主机）"
cd "$SEAHUB_DIR/frontend"
npm run build

echo "==> [2/4] 复制构建产物进容器（build/ + webpack-stats.pro.json）"
docker exec "$CONTAINER" mkdir -p "$INSTALL_PATH/frontend"
# 注意：docker cp 目标已存在时会把源目录嵌套进目标（build/build/），必须先删旧的
docker exec "$CONTAINER" rm -rf "$INSTALL_PATH/frontend/build"
docker cp "$SEAHUB_DIR/frontend/build" "$CONTAINER:$INSTALL_PATH/frontend/build"
docker cp "$SEAHUB_DIR/frontend/webpack-stats.pro.json" "$CONTAINER:$INSTALL_PATH/frontend/webpack-stats.pro.json"

echo "==> [3/4] collectstatic（容器内）"
docker exec -w "$INSTALL_PATH" "$CONTAINER" \
  "$INSTALL_PATH/../../seafile-server-latest/seahub.sh" python-env \
  python3 manage.py collectstatic --noinput

echo "==> [4/4] 完成。浏览器强刷（Cmd+Shift+R）查看效果。"
