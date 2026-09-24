#!/usr/bin/env bash
# 从 seahub 二开分支重导 patch 系列，并刷新 patches/MANIFEST.md。
#
#   ./export-patches.sh          # 重导 + 刷新清单 + 树校验
#
# 什么时候要跑：在 seahub/dev-dingtalk 上新增或修改了提交之后。
# 忘了跑也不会静默出错——build-image.sh 与 CI 都会做「补丁树 == 分支树」的硬校验，
# 不一致直接构建失败。本脚本只是让修这件事变成一条命令。
set -euo pipefail

cd "$(dirname "$0")"
REPO_ROOT=$(cd .. && pwd)
SEAHUB_DIR="${SEAHUB_DIR:-$REPO_ROOT/seahub}"
PATCHES_DIR="$REPO_ROOT/patches"
MANIFEST="$PATCHES_DIR/MANIFEST.md"
DEFAULT_BASE=0877ad70251d50fcb43e2b15026f086bcfc4f815

[[ -d "$SEAHUB_DIR/.git" ]] || { echo "错误：找不到 seahub 仓库（${SEAHUB_DIR}）" >&2; exit 1; }

# 基线：环境变量 BASE_FULL 显式指定时优先（升级上游大版本换基线用，是有意的、
# 一次性的动作，不该藏在默认值里——见 docs/007 §6 升级流程）；
# 否则沿用现有 MANIFEST 里的值（保证日常重导不会悄悄改变基线）。
if [[ -z "${BASE_FULL:-}" && -f "$MANIFEST" ]]; then
  BASE_FULL=$(awk '$1=="base_commit"{print $3; exit}' "$MANIFEST")
fi
BASE_FULL="${BASE_FULL:-$DEFAULT_BASE}"
git -C "$SEAHUB_DIR" cat-file -e "${BASE_FULL}^{commit}" \
  || { echo "错误：基线 $BASE_FULL 不在本地仓库中（浅克隆可能不含它）" >&2; exit 1; }

# base_branch 同理：环境变量优先，否则沿用 MANIFEST，最后兜底 12.0
if [[ -z "${BASE_BRANCH:-}" && -f "$MANIFEST" ]]; then
  BASE_BRANCH=$(awk '$1=="base_branch"{print $3; exit}' "$MANIFEST" 2>/dev/null || true)
fi
BASE_BRANCH="${BASE_BRANCH:-12.0}"

# 工作区必须干净：导出的补丁要与分支内容一致
git -C "$SEAHUB_DIR" diff --quiet && git -C "$SEAHUB_DIR" diff --cached --quiet \
  || { echo "错误：seahub 工作区有未提交改动，先提交再导出补丁" >&2; exit 1; }

N=$(git -C "$SEAHUB_DIR" rev-list --count "$BASE_FULL..HEAD")
[[ "$N" -gt 0 ]] || { echo "错误：分支相对基线没有任何提交，无可导出" >&2; exit 1; }

# 先导到临时目录再整体替换：中途失败不会留下半个补丁系列
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/seafile-patches.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT

# --no-signature：不追加 "-- \n<git 版本>" 尾巴（与既有补丁系列一致，也让 diff 更干净）
git -C "$SEAHUB_DIR" format-patch --no-signature -o "$STAGE" "$BASE_FULL..HEAD" >/dev/null

STAGED_COUNT=$(ls "$STAGE"/*.patch 2>/dev/null | wc -l | tr -d ' ')
[[ "$STAGED_COUNT" == "$N" ]] \
  || { echo "错误：导出 $STAGED_COUNT 个补丁，但分支领先基线 $N 个提交" >&2; exit 1; }

rm -f "$PATCHES_DIR"/[0-9]*.patch
mv "$STAGE"/*.patch "$PATCHES_DIR"/

BRANCH_TREE=$(git -C "$SEAHUB_DIR" rev-parse 'HEAD^{tree}')
HEAD_SHA=$(git -C "$SEAHUB_DIR" rev-parse HEAD)

# 树校验：实现复用 build-image.sh 的 --check-tree（构建时跑的是同一段逻辑，
# 避免「导出时自检通过、构建时却失败」这种两套实现分叉）。校验不过就直接失败。
"$REPO_ROOT/deploy/build-image.sh" --check-tree

cat > "$MANIFEST" <<EOF
# 补丁清单（基线 + 目标树）

本文件由 \`deploy/export-patches.sh\` 自动生成与刷新，**勿手工编辑**。
\`deploy/build-image.sh\`（本地构建）与 \`.github/workflows/build-image.yml\`（CI 构建）
都从这里读取基线，避免基线在脚本与 YAML 里各写一份而漂移。

下面的 key = value 块是机器可读的（脚本用 \`awk '\$1=="base_commit"{print \$3}'\` 取值）。

\`\`\`ini
base_commit     = $BASE_FULL
base_branch     = $BASE_BRANCH
patch_count     = $N
tree_sha        = $BRANCH_TREE
seahub_head_sha = $HEAD_SHA
exported_at     = $(date +%Y-%m-%d)
\`\`\`

## 各字段含义

| 字段 | 含义 |
|---|---|
| \`base_commit\` | 二开的起点，上游 \`haiwen/seahub\` 的**完整** commit sha（不用短 sha，避免歧义）。CI 按这个 SHA 浅取上游 |
| \`base_branch\` | 基线所在的上游分支，仅供人看。**注意**：仅在冻结基线的当下它与 \`base_commit\` 的 tip 重合，上游一旦发布新版本就不再重合，所以 CI 一律按 SHA 取、不按分支名取 |
| \`patch_count\` | \`patches/*.patch\` 的数量。必须等于 \`git rev-list --count base_commit..HEAD\`，也等于镜像 tag 里的 \`N\` |
| \`tree_sha\` | 全部补丁应用后的 \`git write-tree\` 结果。**这是整套发布流水线的核心不变量**：CI 在 \`git am\` 之后断言它，等于每次构建都重新验证「补丁能逐字节复现二开分支」 |
| \`seahub_head_sha\` | 导出时 seahub 分支的 HEAD，仅供追溯（CI 复现不出这个 sha，因为 CI 是 \`git am\` 出来的，不是同一批 commit 对象） |
| \`exported_at\` | 导出日期 |

## 为什么用 tree 哈希而不是 \`git archive\` 的 sha256

\`git archive\` 的输出含 tar/pax 头信息，会随 git 版本、umask、时间戳变化，跨机器比对不可靠。
tree 哈希只由「路径 + 模式 + blob 内容」决定，是与机器无关的稳定指纹。

## 刷新方式

\`\`\`bash
cd deploy && ./export-patches.sh
\`\`\`

脚本会重导补丁、重算本文件、并跑一次树校验；校验不过则拒绝结束。
EOF

echo "✅ 已导出 $N 个补丁 → patches/"
echo "   基线        : $BASE_FULL"
echo "   分支 HEAD   : $HEAD_SHA"
echo "   目标树      : $BRANCH_TREE"
echo "   tag 将变为  : $(./build-image.sh --print-tag)"
