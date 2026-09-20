#!/usr/bin/env bash
# 构建二开生产镜像 —— 开发机与 CI 共用的【唯一】构建入口。
#
#   ./build-image.sh --local                  # 本地彩排：仅 arm64、--load、不推
#   ./build-image.sh <registry>/<namespace>   # 构建并推送（如 ghcr.io/topiceyes）
#   ./build-image.sh --print-tag              # 只打印本次会用的 tag（供 CI 取用）
#   ./build-image.sh --check-tree             # 只校验「补丁能复现分支树」（供 export-patches.sh 复用）
#
# tag 规则：12.0.14-dingtalk.<N>.<构建输入哈希>
#   N        = seahub 分支相对基线的提交数（= 补丁个数，对人可读）
#   <哈希>   = 补丁内容 + deploy/image/** + 本脚本 的 sha256 前 8 位
# 把构建输入并进 tag 是为了让「同 tag ⇒ 同内容」成立——只按 N 编号的话，
# 改一次 nginx 模板或 Dockerfile 就会产出同 tag 不同内容（静默漂移）。
# 基线从 patches/MANIFEST.md 读取 —— 勿在此硬编码，否则会与 CI 各写一份而漂移。
#
# 环境变量旋钮（CI 用）：
#   SEAHUB_DIR    seahub 检出位置（默认 $REPO_ROOT/seahub）
#   PATCHES_DIR   补丁目录（默认 $REPO_ROOT/patches）
#   PLATFORMS     推送模式的目标平台（默认 linux/amd64,linux/arm64）
#   CACHE_ARGS    buildx 缓存参数，例："--cache-from type=gha,scope=x --cache-to type=gha,mode=max,scope=x"
#   EXTRA_ARGS    其他 buildx 参数，例："--provenance=false --sbom=false"
set -euo pipefail

cd "$(dirname "$0")"
REPO_ROOT=$(cd .. && pwd)

MODE=push
PRINT_TAG=0
CHECK_TREE=0
while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    --local)      MODE=local; shift ;;
    --print-tag)  PRINT_TAG=1; shift ;;
    --check-tree) CHECK_TREE=1; shift ;;
    -h|--help)
      sed -n '2,21p' "$0" | sed 's/^#\{1,\} \{0,1\}//'
      exit 0 ;;
    --*)  echo "未知参数：$1（支持 --local / --print-tag / --check-tree）" >&2; exit 1 ;;
    *)    break ;;
  esac
done
REGISTRY_NS="${1:-}"

SEAHUB_DIR="${SEAHUB_DIR:-$REPO_ROOT/seahub}"
PATCHES_DIR="${PATCHES_DIR:-$REPO_ROOT/patches}"
MANIFEST="$PATCHES_DIR/MANIFEST.md"
DEFAULT_BASE=0877ad70251d50fcb43e2b15026f086bcfc4f815
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}"
CACHE_ARGS="${CACHE_ARGS:-}"
EXTRA_ARGS="${EXTRA_ARGS:-}"

[[ -d "$SEAHUB_DIR/.git" ]] || { echo "错误：找不到 seahub 仓库（${SEAHUB_DIR}）" >&2; exit 1; }

# ---- 基线：以 patches/MANIFEST.md 为唯一事实来源（与 CI 共用同一份）----
BASE_FULL=""
if [[ -f "$MANIFEST" ]]; then
  BASE_FULL=$(awk '$1=="base_commit"{print $3; exit}' "$MANIFEST" || true)
fi
if [[ -z "$BASE_FULL" ]]; then
  BASE_FULL="$DEFAULT_BASE"
  echo "警告：未能从 ${MANIFEST} 读到 base_commit，回退到 ${DEFAULT_BASE}（建议跑 deploy/export-patches.sh）" >&2
fi
git -C "$SEAHUB_DIR" cat-file -e "${BASE_FULL}^{commit}" 2>/dev/null \
  || { echo "错误：基线 $BASE_FULL 不在 seahub 仓库中（浅克隆可能不含它）" >&2; exit 1; }

# ---- 核心不变量：补丁逐字节复现分支树 ----
# 临时 index 上逐个 apply --cached（不碰工作区），再比 tree 哈希。
# 用 tree 哈希而非 git archive 的 sha256：tar/pax 头随 git 版本变化，跨机器不可比。
check_patch_tree() {
  local patch_tree branch_tree
  patch_tree=$(PATCHES_ABS="$PATCHES_DIR" BASE="$BASE_FULL" SEAHUB="$SEAHUB_DIR" bash -c '
    set -euo pipefail
    TMPIDX=$(mktemp -u)
    trap "rm -f \"$TMPIDX\"" EXIT
    GIT_INDEX_FILE=$TMPIDX git -C "$SEAHUB" read-tree "$BASE"
    for p in "$PATCHES_ABS"/*.patch; do
      GIT_INDEX_FILE=$TMPIDX git -C "$SEAHUB" apply --cached "$p"
    done
    GIT_INDEX_FILE=$TMPIDX git -C "$SEAHUB" write-tree
  ')
  branch_tree=$(git -C "$SEAHUB_DIR" rev-parse 'HEAD^{tree}')
  if [[ "$patch_tree" != "$branch_tree" ]]; then
    echo "错误：patch 系列打出的树与 seahub 分支树不一致" >&2
    echo "      补丁树: $patch_tree" >&2
    echo "      分支树: $branch_tree" >&2
    echo "      → 补丁没覆盖分支的最新改动。跑 deploy/export-patches.sh 重导补丁。" >&2
    return 1
  fi
  echo "补丁树校验通过：$patch_tree" >&2
}

if [[ "$CHECK_TREE" == "1" ]]; then
  check_patch_tree
  exit 0
fi

# 镜像内容 = 提交内容：工作区必须干净
git -C "$SEAHUB_DIR" diff --quiet && git -C "$SEAHUB_DIR" diff --cached --quiet \
  || { echo "错误：seahub 工作区有未提交改动，先提交再构建" >&2; exit 1; }

N=$(git -C "$SEAHUB_DIR" rev-list --count "$BASE_FULL..HEAD")
PATCH_COUNT=$(ls "$PATCHES_DIR"/*.patch 2>/dev/null | wc -l | tr -d ' ')

# ---- tag = 版本.补丁数.构建输入哈希 ----
#
# 只用「补丁数」当 tag 是不够的：镜像内容还取决于补丁【内容】、deploy/image/**
# （Dockerfile、nginx 模板）和本脚本。改这些而不加 seahub 提交，就会产出
# 【同 tag 不同内容】——钉了该 tag 的机器下次 pull 会静默漂移。
# 这在实践中真的会发生：改一次 nginx 模板就中招。
#
# 所以把全部构建输入的内容哈希并进 tag，让「同 tag ⇒ 同内容」重新成立。
# 补丁数仍然留在 tag 里，是因为它对人不言自明（第几个二开版本），便于沟通。
build_inputs_hash() {
  {
    # 补丁内容（不只是个数）
    cat "$PATCHES_DIR"/*.patch
    # 除补丁外的构建输入：Dockerfile、nginx 模板、本脚本
    ( cd "$REPO_ROOT" && find deploy/image deploy/build-image.sh -type f \
        -exec sha256sum {} + | LC_ALL=C sort -k2 )
  } | sha256sum | cut -c1-8
}
BUILD_HASH=$(build_inputs_hash)

# 版本前缀 12.0.14 与 Dockerfile 的 BASE_IMAGE/INSTALLPATH 耦合，
# 升级 Seafile 时三处要同步（docs/007 §6）；CI 有断言兜住半途而废的升级。
TAG="12.0.14-dingtalk.${N}.${BUILD_HASH}"

# 说明：tag 覆盖的是【本仓库的构建输入】。基础镜像 seafileltd/seafile-mc:12.0.14
# 是按 tag 引用的，上游若重新推同一个 tag，溯源内容仍可能变——那属于上游行为，
# 靠生产侧钉 digest + 发布台账（docs/010 §9）覆盖。

if [[ "$PRINT_TAG" == "1" ]]; then
  # 只输出 tag，诊断信息一律走 stderr，便于 CI 用 $(...) 捕获
  [[ "$PATCH_COUNT" == "$N" ]] \
    || echo "警告：patches/ 有 $PATCH_COUNT 个补丁，但分支领先基线 $N 个提交" >&2
  echo "$TAG"
  exit 0
fi

check_patch_tree

# ---- 构建上下文：git archive 干净源码树（绕开 seahub/ 被顶层 gitignore 与 node_modules）----
CTX=$(mktemp -d "${TMPDIR:-/tmp}/seafile-build.XXXXXX")
trap 'rm -rf "$CTX"' EXIT
mkdir -p "$CTX/seahub" "$CTX/image"

git -C "$SEAHUB_DIR" archive --format=tar HEAD | tar -x -C "$CTX/seahub"

# package-lock.json 是 npm ci 可复现的前提。它在 seahub 里是 tracked 的（尽管
# seahub/.gitignore:63 有同名规则，tracked 优先），所以 archive 会带上它。
# 这里断言住：万一哪天有人 git rm --cached 掉它，构建会退化成 npm install
# （依赖版本漂移）——那种降级在 CI 里必须是响亮的失败，而不是静默继续。
[[ -f "$CTX/seahub/frontend/package-lock.json" ]] \
  || { echo "错误：构建上下文缺少 frontend/package-lock.json，npm ci 无法复现依赖" >&2; exit 1; }

cp -R "$REPO_ROOT/deploy/image/." "$CTX/image/"

echo "==> 构建上下文：$(du -sh "$CTX" | cut -f1)（$(git -C "$SEAHUB_DIR" rev-parse --short HEAD)，$N 个二开提交）"

# 数组展开用 ${A[@]+"${A[@]}"} 形式：macOS 自带 bash 3.2 在 set -u 下对空数组直接展开会报 unbound variable
read -r -a CACHE_ARR <<<"$CACHE_ARGS"
read -r -a EXTRA_ARR <<<"$EXTRA_ARGS"

if [[ "$MODE" == local ]]; then
  echo "==> 本地构建（arm64，不推送）：seafile-mc-devbuild:$TAG"
  docker buildx build -f "$CTX/image/Dockerfile" --platform linux/arm64 \
    -t "seafile-mc-devbuild:$TAG" --load "$CTX"
else
  [[ -n "$REGISTRY_NS" ]] || { echo "用法: $0 [--local|--print-tag|--check-tree] <registry>/<namespace>" >&2; exit 1; }
  IMAGE="$REGISTRY_NS/seafile-mc:$TAG"
  echo "==> 构建并推送（${PLATFORMS}）：${IMAGE}"
  docker buildx build -f "$CTX/image/Dockerfile" --platform "$PLATFORMS" \
    ${CACHE_ARR[@]+"${CACHE_ARR[@]}"} ${EXTRA_ARR[@]+"${EXTRA_ARR[@]}"} \
    -t "$IMAGE" --push "$CTX"
fi
