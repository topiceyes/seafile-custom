#!/usr/bin/env bash
# 构建二开生产镜像。
#
#   ./build-image.sh --local                              # 本地彩排：仅 arm64、--load、不推
#   ./build-image.sh <registry>/<namespace>               # 双架构构建并推送（ACR 等）
#
# tag 规则：12.0.14-dingtalk.<N>，N = seahub 分支相对基线 0877ad7 的提交数（必然递增）
set -euo pipefail

cd "$(dirname "$0")"
REPO_ROOT=$(cd .. && pwd)

MODE=push
if [[ "${1:-}" == "--local" ]]; then MODE=local; shift; fi
REGISTRY_NS="${1:-}"

SEAHUB_DIR="$REPO_ROOT/seahub"
PATCHES_DIR="$REPO_ROOT/patches"
BASE_COMMIT=0877ad7

# 镜像内容 = 提交内容：工作区必须干净
git -C "$SEAHUB_DIR" diff --quiet && git -C "$SEAHUB_DIR" diff --cached --quiet \
  || { echo "错误：seahub 工作区有未提交改动，先提交再构建" >&2; exit 1; }

N=$(git -C "$SEAHUB_DIR" rev-list --count "$BASE_COMMIT..HEAD")
TAG="12.0.14-dingtalk.${N}"

# patches/ 数量与提交数一致性提醒（不阻断：patch 可能尚未导出）
PATCH_COUNT=$(ls "$PATCHES_DIR"/*.patch 2>/dev/null | wc -l | tr -d ' ')
[[ "$PATCH_COUNT" == "$N" ]] \
  || echo "警告：patches/ 有 $PATCH_COUNT 个补丁，seahub 领先基线 $N 个提交（记得导出补丁）" >&2

# 构建上下文：git archive 干净源码树（绕开 seahub/ 被顶层 gitignore 与 node_modules）
CTX=$(mktemp -d "${TMPDIR:-/tmp}/seafile-build.XXXXXX")
trap 'rm -rf "$CTX"' EXIT
mkdir -p "$CTX/seahub" "$CTX/image"

git -C "$SEAHUB_DIR" archive --format=tar HEAD | tar -x -C "$CTX/seahub"
# package-lock.json 被 seahub/.gitignore 排除，单独叠加（npm ci 可复现的前提）
if [[ -f "$SEAHUB_DIR/frontend/package-lock.json" ]]; then
  cp "$SEAHUB_DIR/frontend/package-lock.json" "$CTX/seahub/frontend/"
else
  echo "警告：无 package-lock.json，将退化为 npm install（依赖版本可能漂移）" >&2
fi
cp -R "$REPO_ROOT/deploy/image/." "$CTX/image/"

echo "==> 构建上下文：$(du -sh "$CTX" | cut -f1)（$(git -C "$SEAHUB_DIR" rev-parse --short HEAD)，$N 个二开提交）"

if [[ "$MODE" == local ]]; then
  echo "==> 本地构建（arm64，不推送）：seafile-mc-devbuild:$TAG"
  docker buildx build -f "$CTX/image/Dockerfile" --platform linux/arm64 \
    -t "seafile-mc-devbuild:$TAG" --load "$CTX"
else
  [[ -n "$REGISTRY_NS" ]] || { echo "用法: $0 [--local] <registry>/<namespace>" >&2; exit 1; }
  echo "==> 双架构构建并推送：$REGISTRY_NS/seafile-mc:$TAG"
  docker buildx build -f "$CTX/image/Dockerfile" --platform linux/amd64,linux/arm64 \
    -t "$REGISTRY_NS/seafile-mc:$TAG" --push "$CTX"
fi
