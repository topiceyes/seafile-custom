# 补丁清单（基线 + 目标树）

本文件由 `deploy/export-patches.sh` 自动生成与刷新，**勿手工编辑**。
`deploy/build-image.sh`（本地构建）与 `.github/workflows/build-image.yml`（CI 构建）
都从这里读取基线，避免基线在脚本与 YAML 里各写一份而漂移。

下面的 key = value 块是机器可读的（脚本用 `awk '$1=="base_commit"{print $3}'` 取值）。

```ini
base_commit     = 0877ad70251d50fcb43e2b15026f086bcfc4f815
base_branch     = 12.0
patch_count     = 8
tree_sha        = a0fe634985f007dfa055502188972a65f5d25489
seahub_head_sha = e1eb10ce0ff67d01c475c4670e25841714eeb941
exported_at     = 2026-09-20
```

## 各字段含义

| 字段 | 含义 |
|---|---|
| `base_commit` | 二开的起点，上游 `haiwen/seahub` 的**完整** commit sha（不用短 sha，避免歧义）。CI 按这个 SHA 浅取上游 |
| `base_branch` | 基线所在的上游分支，仅供人看。**注意**：仅在冻结基线的当下它与 `base_commit` 的 tip 重合，上游一旦发布新版本就不再重合，所以 CI 一律按 SHA 取、不按分支名取 |
| `patch_count` | `patches/*.patch` 的数量。必须等于 `git rev-list --count base_commit..HEAD`，也等于镜像 tag 里的 `N` |
| `tree_sha` | 全部补丁应用后的 `git write-tree` 结果。**这是整套发布流水线的核心不变量**：CI 在 `git am` 之后断言它，等于每次构建都重新验证「补丁能逐字节复现二开分支」 |
| `seahub_head_sha` | 导出时 seahub 分支的 HEAD，仅供追溯（CI 复现不出这个 sha，因为 CI 是 `git am` 出来的，不是同一批 commit 对象） |
| `exported_at` | 导出日期 |

## 为什么用 tree 哈希而不是 `git archive` 的 sha256

`git archive` 的输出含 tar/pax 头信息，会随 git 版本、umask、时间戳变化，跨机器比对不可靠。
tree 哈希只由「路径 + 模式 + blob 内容」决定，是与机器无关的稳定指纹。

## 刷新方式

```bash
cd deploy && ./export-patches.sh
```

脚本会重导补丁、重算本文件、并跑一次树校验；校验不过则拒绝结束。
