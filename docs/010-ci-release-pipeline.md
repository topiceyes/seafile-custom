# 010 - CI 发布流水线（GitHub Actions → ghcr.io）

> 完成日期：2026-09-20 ｜ 状态：随生产部署上线

## 1. 概览

开发机不再需要手工构建和推镜像。推代码到 GitHub，Actions 自动构建，生产机只 `docker compose pull`。

```
开发机                               GitHub                                    生产服务器（国内）
─────                                ──────                                    ────────────────
seahub/dev-dingtalk 提交
  └ deploy/export-patches.sh
       └ patches/*.patch + MANIFEST.md
            └ git push ──────────→  seafile-custom（public, main）
                                      └ .github/workflows/build-image.yml
                                         ├ 按固定 SHA 浅取上游 haiwen/seahub
                                         ├ git am patches/*.patch
                                         ├ 断言源码树 == MANIFEST.tree_sha
                                         ├ deploy/build-image.sh（与开发机同一脚本）
                                         └ push → ghcr.io/topiceyes/seafile-mc:12.0.14-dingtalk.<N>.<hash>
                                                                                  │
                                      codeload.github.com tarball ───────────────┤ 免代理免凭据取 deploy/
                                                                                  ↓
                                                        docker compose pull && up -d
```

**一条设计原则**：workflow 里**不写构建逻辑**。CI 只负责准备源码树，然后调用
`deploy/build-image.sh` —— 与开发机同一个脚本。所以「CI 产物 ≡ 本地产物」是结构上
成立的，而不是靠两边各自维护一套命令保持同步。CI 里唯一的构建相关代码就是环境变量：

```yaml
PLATFORMS=linux/amd64
CACHE_ARGS="--cache-from type=gha,scope=seafile-mc --cache-to type=gha,mode=max,scope=seafile-mc"
EXTRA_ARGS="--provenance=false --sbom=false"
```

## 2. 为什么二开源码不做成 GitHub fork

`seahub/` 是上游 `haiwen/seahub` 的克隆，8 个二开提交此前只存在于开发机上。
把它放到 GitHub 有三条路：

| 路线 | 结论 |
|---|---|
| fork 上游后推分支 | ⚠️ **这条当初是被否决的，但理由已经失效** —— 见下 |
| 新建 mirror 仓后推分支 | 否决：等价于先 `git fetch --unshallow`，上游仓库 1.4 GB 要经代理拖完整历史。二开 delta 只有 21 文件 / 约 185 KiB 对象 |
| **补丁路线**（选用） | CI 在 GitHub 网络内（无墙、无代理成本）按固定 SHA 浅取上游，再应用 `patches/` |

> **2026-09-20 更新：仓库已转为 public，fork 的禁令不再适用。**
> 当初否决 fork 的唯一理由是「上游是公开仓库，而公开仓库的 fork 无法设为私有
> （GitHub 强制继承父仓库可见性）」，走 fork 等于公开二开代码，与「仓库保持私有」冲突。
> 现在仓库本身就是公开的，这个冲突不存在了。
>
> **但仍然保留补丁路线**，理由换成它自身的技术优点（下面这条），而不是策略约束：
>
> - fork 路线下 CI 直接构建分支，**没有任何东西验证「镜像内容 == 补丁所描述的源码」**
> - 补丁路线下，每次构建都重新验证「补丁能逐字节复现二开分支」，上游漂移或补丁被改坏
>   会变成**构建失败**，而不是悄悄发出一个内容不对的镜像
> - 另外切到 fork 要把上游历史推上去（1.4 GB），一次性成本不低，收益却是负的
>
> 换句话说：**禁令解除了，但我们本来也不是因为禁令才选它的。**

代价是 GitHub 上没有可浏览的逐提交历史。补丁文件由 `git format-patch` 生成，保留了
完整的作者/日期/提交消息，需要时 `git log` 也仍可在开发机上查看。

## 3. 触发方式

```bash
# 手动触发（主入口）
gh workflow run build-image.yml
gh workflow run build-image.yml -f force=true    # 覆盖已存在的 tag

# 自动触发：push 到 main 且改动以下路径
#   patches/**                    → 补丁变了，镜像内容变
#   deploy/image/**               → Dockerfile / nginx 模板变了
#   deploy/build-image.sh         → 构建入口变了
#   .github/workflows/build-image.yml 自身
```

`paths:` 过滤是必需的：漏了它，一次文档提交也会烧掉十几分钟额度，还会产出一个
内容与上个版本完全相同的 tag。

> ⚠️ **强推（重写历史）后的 `push` 触发不可靠——注意是「不可靠」，不是「一定不触发」。**
> 2026-09-20 把提交作者改成 noreply 邮箱时重写了全部历史，两次强推表现相反：
> 第一次（改动确实落在 `patches/**`）**远端一个 run 都没生成**；第二次（新旧 tip 的
> tree 完全相同、按 `paths` 本不该触发）**反而生成了 run**，并因算出的 tag 已存在
> 被守卫拦下（run 35501316392，17 秒，属预期行为，不是故障）。
> 根因是 `paths` 过滤在「before 不是 after 的祖先」时判定不可靠。
> **结论：重写历史后别指望自动触发，手动跑 `gh workflow run build-image.yml`。**
> 顺带一提，重写补丁相关历史会让 tag 变（补丁内容进了哈希），所以本来就得走一次构建。

同一 ref 上的构建**不并发、也不互相取消**（`cancel-in-progress: false`）——
两次构建抢同一个 tag 是最糟的失败模式。

## 4. tag 规则与血缘断言

tag 形如 `12.0.14-dingtalk.<N>.<8位哈希>`：

| 段 | 含义 |
|---|---|
| `12.0.14` | Seafile 版本（与 Dockerfile 的 `BASE_IMAGE` 耦合） |
| `N` | 补丁个数（= `git rev-list --count <base_commit>..HEAD`）。**给人看的**，便于沟通 |
| `<8位哈希>` | **构建输入的内容哈希**：补丁内容 + `deploy/image/**` + `build-image.sh` |

tag 由 `./deploy/build-image.sh --print-tag` 算出，**不在 YAML 里重算** ——
那是 CI 与本地最可能发生漂移的地方。

CI 在构建前跑三条断言：

1. tag 里的数字 == `patches/*.patch` 的文件数
2. tag 的版本前缀 == `deploy/image/Dockerfile` 里 `BASE_IMAGE` 的版本
   （升级 Seafile 时要同步改 BASE_IMAGE / INSTALLPATH / 版本前缀 / tag 四处，
   这条能在「只改了一半」时提前拦住，避免发出 12.0.14 与 12.1.x 混搭的镜像）
3. 补丁文件名 `0001..000N` 连续无缺口

### 为什么 tag 里要带内容哈希

早期版本只有 `12.0.14-dingtalk.<N>`。问题在于 **镜像内容不只取决于补丁个数**：
改一次 nginx 模板、改一行 Dockerfile，补丁数不变，于是产出**同 tag 不同内容** ——
钉了该 tag 的机器下次 `pull` 会静默漂移。这不是理论风险：本项目第一次改 nginx
模板就撞上了，只能靠 `force=true` 覆盖，而「同一个 tag 指过三个不同镜像」本身就
是不健康的状态。

现在把构建输入的内容哈希并进 tag 后，**「同 tag ⇒ 同内容」重新成立**：

- 改任何构建输入 → 自动得到新 tag，**不需要 force**
- tag 已存在 → 说明输入一字未改，重建是多余的，守卫拦下是对的

`force=true` 因此只剩下一个正当用途：**重建以拉取上游更新过的基础镜像**
（`seafileltd/seafile-mc:12.0.14` 是按 tag 引用的，上游若重推同一 tag，
本仓库的输入没变而镜像内容可能变 —— 那是 tag 哈希覆盖不到的部分）。

即便如此，生产 `.env` 里**钉 digest 仍是默认做法**（模板已是 digest 形式）：
它是唯一不依赖任何命名约定的保障。每次构建的 digest 会写进 GitHub Actions 的
run summary，也在下节的台账里记一份。

## 5. 漂移控制（三层）

### ① `patches/MANIFEST.md`
基线全 SHA、上游分支、补丁数、目标 tree sha。`build-image.sh` 与 CI **都从这里读基线**，
所以不存在「脚本里写一个、YAML 里写另一个」的可能。由脚本生成，勿手工编辑。

> 文件名注意：**不能**匹配 `*.patch`，否则会被 `git am patches/*.patch` 的 glob 误吞。

### ② 构建时的硬不变量
`build-image.sh` 在每次构建前把补丁逐个 `git apply --cached` 到临时 index，比对
`git write-tree` 与分支 HEAD 的 tree 哈希，不一致直接失败。用 **tree 哈希**而不是
`git archive` 的 sha256 —— 后者含 tar/pax 头信息，随 git 版本/umask/时间戳变化，
跨机器不可比。

从「软警告」改成「硬失败」是有意的：这条性质是整套流水线的地基，静默漂移的代价
（发出一个内容不对的镜像且无人察觉）远高于构建失败的代价。

### ③ `deploy/export-patches.sh`
在 seahub 分支上改完代码后跑一次：重导补丁 → 刷新 MANIFEST → 调 `build-image.sh --check-tree`
自检（复用同一份实现，避免两套逻辑分叉），校验不过拒绝结束。

```bash
cd deploy && ./export-patches.sh
```

## 6. 服务器侧

```bash
# 0a) 取部署文件。服务器上 git 协议到 github.com 不通，
#     但 codeload.github.com 可直连（已实测）。仓库是 public，裸 curl 即可
mkdir -p /opt/seafile-custom
curl -fL --max-time 120 \
  https://codeload.github.com/topiceyes/seafile-custom/tar.gz/refs/heads/main \
  | tar -xz --strip-components=1 -C /opt/seafile-custom
cd /opt/seafile-custom/deploy        # 习惯而已：生产 compose 已无宿主机相对路径，放哪都行
cp .env.prod.example .env            # .env 不在 tarball 内，重取代码不会覆盖它

# 0b) 更新
vi .env      # SEAFILE_PRO_IMAGE 改成新 tag（或钉 digest）
docker compose pull && docker compose up -d     # 镜像包是 public，不需要 docker login
```

几个容易踩的点：

- tarball 根目录是 `<owner>-<repo>-<sha>/`，所以要 `--strip-components=1`
- 要可复现而非跟随 `main`，就把 URL 里的 `main` 换成具体 commit SHA，并记入台账
- 这套命令**不需要任何凭据**。曾经需要一个 classic PAT（`repo` + `read:packages`）覆盖
  「取 tarball + 拉镜像」，2026-09-20 仓库与镜像包转 public 后取消——详见 §2 的说明

## 7. 排障

| 症状 | 原因与处置 |
|---|---|
| CI 失败于「校验源码树 == tree_sha」 | 补丁与 `MANIFEST.tree_sha` 不同步。跑 `deploy/export-patches.sh` 重导补丁并提交 |
| CI 失败于「按 SHA 取上游」 | 基线 SHA 在上游不可达（极少见）。确认 `MANIFEST.base_commit` 拼写，或改用 `--filter=blob:none` 全量 clone |
| CI 失败于「tag 已存在」 | 构建输入一字未改，重建是多余的。多半是你的改动没触及 `patches/`、`deploy/image/`、`build-image.sh`（例如只改了文档）。确认后无需重建；只有要刷新上游基础镜像才用 `force=true` |
| 冒烟验证失败「缺 frontend/build 或 chunk 未落地」 | 前端产物没进镜像，或 `collectstatic` 没把它收进 `media/assets`。断言在 `deploy/smoke-test.sh`；改完断言要 `-f force=true` 重跑才验得到（改该文件不会自动触发构建） |
| 冒烟验证报 `toomanyrequests` | Docker Hub 对共享 runner IP 的匿名限流。在仓库 secrets 里配 `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN`，workflow 会自动登录 |
| 服务器 `docker pull` 报 `denied` | 镜像包是 public 时不该出现。若出现，多半是包的可见性被改回了 private（Package settings → Change visibility），或本地有失效的 `~/.docker/config.json` 缓存旧凭据 → `docker logout ghcr.io` 再试 |
| 生产机连不上 ghcr.io | 见 §8 的 ACR 备选 |

## 8. ACR 备选（ghcr 不可达时）

`build-image.sh` 对 registry 无假设，本地推 ACR 的能力一直保留：

```bash
# 开发机上（arm64 native；要 amd64 需换机器或开仿真）
docker login registry.cn-hangzhou.aliyuncs.com
./deploy/build-image.sh registry.cn-hangzhou.aliyuncs.com/<命名空间>
```

生产 `.env` 的 `SEAFILE_PRO_IMAGE` 换成对应 ACR 地址即可，compose 文件不用动。

**关于 ghcr 的额度**：GitHub Packages 免费额度是 500 MB 存储 / 1 GB 月流量，但官方
文档明确「容器镜像的存储与带宽目前免费」——这是两套口径，容器镜像大概率不受 500 MB 限制。
不过该政策保留变更权（变更会提前一个月通知），所以保留 ACR 这条后路是有价值的。
本镜像实测未压缩 0.48–0.8 GB。

## 9. 发布台账

每次发布后追加一行，便于回滚与审计。

| 日期 | tag | 补丁数 | 源码树 | 镜像 digest | 备注 |
|---|---|---|---|---|---|
| 2026-09-20 | `12.0.14-dingtalk.9.4edcb25d` | 9 | `446fe9ea…c38e393f` | `sha256:624c439c…4469e0cb9` | **当前生产用**（`.env.prod.example` 钉的就是它）。补丁 0009：站点地址 `SERVICE_URL` 挪到管理后台、免重启生效（[docs/011](011-service-url-admin-config.md)）。首次自动触发成功（run 35503681853，5m53s） |
| 2026-09-20 | `12.0.14-dingtalk.8.325dfdcd` | 8 | `a0fe6349…a65f5d25489` | `sha256:f604d0ba…c55c013ba` | 提交身份改为 GitHub noreply 后重导补丁（run 35500160361，手动触发）。镜像内容与上一版**未变**——三层指纹逐字节相同 |
| 2026-09-20 | `12.0.14-dingtalk.8.e9313643` | 8 | `a0fe6349…a65f5d25489` | `sha256:a9d840d6…42e584a4` | 运维脚本烘进镜像（不再 bind-mount），生产 compose 已无宿主机相对路径（run 35497571764） |
| 2026-09-20 | `12.0.14-dingtalk.8.4261dd78` | 8 | `a0fe6349…a65f5d25489` | `sha256:c3b12c34…d01952d2` | 含反代模式 nginx 修复；tag 规则改内容寻址后的首次发布（run 35496784127） |
| 2026-09-20 | `12.0.14-dingtalk.8` | 8 | `a0fe6349…a65f5d25489` | `sha256:add45ed6…23665527` | 首次 CI 发布（run 35495223406），构建 8m27s。**已被覆盖且格式过时，勿用** |

> **tag 规则的由来**：首次发布当天，`12.0.14-dingtalk.8` 这个 tag 前后指过三个不同镜像 ——
> 第一次冒烟断言写错（run 35494641254，`sha256:dcf18a2e…`），修好后 `force` 覆盖；
> 之后支持反代模式改了 nginx 模板，又是一次同 tag 覆盖。每次都靠 `force=true` 硬来，
> 因为**补丁数没变而镜像内容变了**。
>
> 这正是 §4 把构建输入哈希并进 tag 的直接动因。改完之后，上面这两次修改都会各自
> 得到新 tag，不需要任何 force。**当时的旧 digest 无任何服务器消费过，所以没有实际影响** ——
> 但若已有生产机钉了该 tag，每次覆盖都是一次静默漂移。
