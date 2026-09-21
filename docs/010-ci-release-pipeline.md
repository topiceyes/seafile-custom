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
> **守卫的报错方式已于 2026-09-21 修正**：它原先一律 `exit 1`，于是每次这种空转
> 都往管理员邮箱发一封「构建失败」，而实际什么都没坏。现在按触发方式区分——
> **自动触发（push）**下 tag 已存在 = 构建输入未变 = 无需构建，记 `::notice::` +
> step summary 后 **exit 0**（构建/冒烟/记录步骤整体跳过）；**手动
> `workflow_dispatch`** 下保持 `exit 1`（是人明确要求构建的，什么都不做必须让人看见）。
> 实测同一条提交由「失败」变为「成功 + 跳过」（run 35566843877）。
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

## 8. 基础设施镜像镜像 + ACR 备选

### 8.1 MariaDB / memcached 镜像到 ghcr（2026-09-21）

生产 compose 有三个镜像。早先只有 seafile 走 ghcr，另两个直接引 Docker Hub——
而国内网络常常**只有 Docker Hub 不通**：

```
ghcr.io                            401（可达；/v2/ 未认证的正常响应）
registry-1.docker.io               000（12s 超时）
registry.cn-hangzhou.aliyuncs.com  401（可达）
```

已于 2026-09-21 由 `.github/workflows/mirror-infra-images.yml` 镜像到 ghcr，
三个镜像同源，服务器侧只剩一个要连通的目标。

**这个坑最阴的地方是报错指向的仓库不对**：`docker compose pull` 会依次拉三个镜像，
最先失败的是 Docker Hub 那两个，于是屏幕上是
`Get "https://registry-1.docker.io/v2/": context deadline exceeded` ——
看起来像我们的镜像出了问题，实际 ghcr 一直是好的（匿名 `tags/list` 200，
匿名 pull 拿到的 digest 与 CI 记录一致）。**排查时先分清报错里的域名属于谁。**

| 项 | 值 |
|---|---|
| 源 | `docker.io/library/mariadb:10.11` / `docker.io/library/memcached:1.6.29` |
| 目标 | `ghcr.io/topiceyes/mariadb:10.11` / `ghcr.io/topiceyes/memcached:1.6.29` |
| 方式 | `docker buildx imagetools create`（registry→registry 复制，不落本地）|
| 产物 | **manifest list（索引）**，含源仓库的全部平台 |
| 刷新 | 手动 `gh workflow run mirror-infra-images.yml`（改该文件里的清单后 push 也会触发）|

#### ⚠️ 为什么必须是 manifest list，不能是单平台 manifest

第一版用 `docker pull --platform linux/amd64` + `tag` + `push` 镜像，推上去的是
**单平台 manifest**。表面上服务器 `docker compose pull` 完全正常，但离线包路径炸了：

```
$ docker save --platform linux/amd64 ghcr.io/topiceyes/mariadb:10.11
Error response from daemon: no suitable export target found: image with reference
ghcr.io/topiceyes/mariadb:10.11 was found but does not provide the specified
platform (linux/amd64)
```

而本地 `docker inspect` 明明显示 `amd64/linux` —— 所以这**不是「拉错了架构」**，
是 mediaType 的差别：

| 镜像 | mediaType | `save --platform` |
|---|---|---|
| `ghcr.io/topiceyes/seafile-mc`（CI 用 buildx 构建） | OCI manifest | ✅ 572M |
| `ghcr.io/topiceyes/mariadb`（第一版镜像） | **Docker v2 manifest** | ❌ 报上面那个错 |
| 同上，**不带** `--platform` | 同上 | ⚠️ **产出 8KB 空包且退出码为 0** |
| `ghcr.io/topiceyes/mariadb`（imagetools 版） | **OCI index** | ✅ 122M |

最后一行才是最危险的：静默产出一个 8KB 的「成功」包。（`make-offline-bundle.sh`
末尾的 manifest 校验会拦下它——但那已经是最后一道防线了。）

索引用 `--platform` 选平台是标准路径，与 Docker Hub 自己的 tag 行为一致。所以
改用 `imagetools create`，并在 workflow 里**把这条假设写成断言**（检查 mediaType
是索引、且索引含 `linux/amd64`）——写死在代码里而不验证的假设，就是下一次静默漂移。

代价：索引含 arm64，比只留 amd64 多占约一倍存储。GitHub 官方口径是容器镜像的
存储与带宽免费，可接受；换来的是与 Docker Hub 原 tag 行为完全一致。

> **另一个值得记的坑**：那条断言第一次跑时误报「索引里没有 linux/amd64」，
> 而索引里明明有。根因是 `imagetools inspect "$DST" | grep -q 'linux/amd64'` ——
> `grep -q` 命中即退出 → 关闭管道 → 左侧收到 **SIGPIPE** 而非零退出 →
> `set -o pipefail` 让整条管道判为失败，**即使匹配成功**。
> 改为先收进变量再 `grep -q <<<"$INSPECT"`。（`echo` 那种短输出不受影响，
> 数据远小于管道缓冲区，写完才轮到 grep 退出。）

> **仓库 public ≠ 镜像包 public**，新包默认可能是私有。该 workflow 里带一个
> 尽力而为的 visibility PATCH（`continue-on-error`——对用户所有的包不保证被
> `GITHUB_TOKEN` 接受），失败时 step summary 会给出人工改可见性的链接。
> 实测这次两个包匿名 `tags/list` 都是 200，无需人工干预。

> **不能从开发机直接推**：本地 ghcr 凭据只有读权限，`docker push` 报
> `permission_denied: The token provided does not match expected scopes`。
> CI 的 `GITHUB_TOKEN` 带 `packages: write`，所以这一步只能走 CI。

### 8.2 ACR 备选（ghcr 不可达时）

`build-image.sh` 对 registry 无假设，本地推 ACR 的能力一直保留：

```bash
# 开发机上（arm64 native；要 amd64 需换机器或开仿真）
docker login registry.cn-hangzhou.aliyuncs.com
./deploy/build-image.sh registry.cn-hangzhou.aliyuncs.com/<命名空间>
```

生产 `.env` 的 `SEAFILE_PRO_IMAGE` 换成对应 ACR 地址即可，compose 文件不用动。

> ⚠️ 走 ACR 时**别忘了基础设施镜像**：`seafile-prod.yml` 里的 `mariadb`/`memcached`
> 现在写死指向 `ghcr.io/topiceyes/…`（§8.1）。若 ghcr 整个不可达，这两行也要换成
> ACR 地址，否则 pull 会卡在它们上面——症状与本文档反复强调的那个坑一模一样：
> **报错指的是基础设施镜像，看起来却像主镜像有问题。**

**关于 ghcr 的额度**：GitHub Packages 免费额度是 500 MB 存储 / 1 GB 月流量，但官方
文档明确「容器镜像的存储与带宽目前免费」——这是两套口径，容器镜像大概率不受 500 MB 限制。
不过该政策保留变更权（变更会提前一个月通知），所以保留 ACR 这条后路是有价值的。
本镜像实测未压缩 0.48–0.8 GB。

## 9. 发布台账

每次发布后追加一行，便于回滚与审计。

| 日期 | tag | 补丁数 | 源码树 | 镜像 digest | 备注 |
|---|---|---|---|---|---|
| 2026-09-21 | `12.0.14-dingtalk.9.e3c4174f` | 9 | `446fe9ea…c38e393f` | `sha256:5cf3abfd…0f2fb9d7` | **当前生产用**（`.env.prod.example` 钉的就是它）。启动链路加固：seahub 启动失败重试 + 保活循环跟着死（[docs/007 §4.2.3](007-production-deployment.md)）。run 35574442997，6m27s |
| 2026-09-21 | `12.0.14-dingtalk.9.b7a741d8` | 9 | `446fe9ea…c38e393f` | `sha256:aa906c16…467b6e0a4` | 二开定制搬进镜像：`init-conf.sh --prod` 整个删除，部署不再有「再跑一个脚本」这一步。run 35573252750，5m38s |
| 2026-09-20 | `12.0.14-dingtalk.9.4edcb25d` | 9 | `446fe9ea…c38e393f` | `sha256:624c439c…4469e0cb9` | 补丁 0009：站点地址 `SERVICE_URL` 挪到管理后台、免重启生效（[docs/011](011-service-url-admin-config.md)）。首次自动触发成功（run 35503681853，5m53s） |
| 2026-09-20 | `12.0.14-dingtalk.8.325dfdcd` | 8 | `a0fe6349…a65f5d25489` | `sha256:f604d0ba…c55c013ba` | 提交身份改为 GitHub noreply 后重导补丁（run 35500160361，手动触发）。镜像内容与上一版**未变**——三层指纹逐字节相同 |
| 2026-09-20 | `12.0.14-dingtalk.8.e9313643` | 8 | `a0fe6349…a65f5d25489` | `sha256:a9d840d6…42e584a4` | 运维脚本烘进镜像（不再 bind-mount），生产 compose 已无宿主机相对路径（run 35497571764） |
| 2026-09-20 | `12.0.14-dingtalk.8.4261dd78` | 8 | `a0fe6349…a65f5d25489` | `sha256:c3b12c34…d01952d2` | 含反代模式 nginx 修复；tag 规则改内容寻址后的首次发布（run 35496784127） |
| 2026-09-20 | `12.0.14-dingtalk.8` | 8 | `a0fe6349…a65f5d25489` | `sha256:add45ed6…23665527` | 首次 CI 发布（run 35495223406），构建 8m27s。**已被覆盖且格式过时，勿用** |

**基础设施镜像**（`mirror-infra-images.yml`，run 35566304802，2026-09-21）——
digest 是**索引**的 digest（含全部平台）：

| 目标 | digest（索引） | amd64 子清单 |
|---|---|---|
| `ghcr.io/topiceyes/mariadb:10.11` | `sha256:7f22313f…f9bc66ab` | `sha256:5ae7fc7b…9834d9e` |
| `ghcr.io/topiceyes/memcached:1.6.29` | `sha256:56a39bd5…a16d3953b` | `sha256:486b2361…ef824c52` |

> ⚠️ **这两行早期记的 digest 已作废**：第一版推的是单平台 manifest
> （`sha256:6f08d1d7…` / `sha256:c8eed037…`），因离线包路径不可用而改成了索引。
> 单平台那版**从未被任何服务器消费过**。

> 这两个用 **tag**（不是 digest）引用，与 `SEAFILE_PRO_IMAGE` 的口径不同。理由：它们是
> 我们自己命名空间下的快照，tag 只会在**手动重跑镜像 workflow 时**移动，不存在上游悄悄
> 重推导致漂移的问题；而 tag 形式让「刷新基础镜像」就是重跑一次 workflow 这么简单。
> digest 记在这里，需要钉死时可直接换成 `ghcr.io/topiceyes/mariadb@sha256:7f22313f…`。

> **换过一次源，旧离线包因此作废。** compose 从 `mariadb:10.11` 改成
> `ghcr.io/topiceyes/mariadb:10.11` 之后，**改源前打的那个 693MB 离线包不再可用**：
> `docker load` 进去的 tag 是 `mariadb:10.11`，而 compose 找不到这个名字，会转去联网拉、
> 又失败。已用新源重打（三个 RepoTag 与新 compose 逐字一致）。若你手上有更早的包，
> 丢掉重取。

> **tag 规则的由来**：首次发布当天，`12.0.14-dingtalk.8` 这个 tag 前后指过三个不同镜像 ——
> 第一次冒烟断言写错（run 35494641254，`sha256:dcf18a2e…`），修好后 `force` 覆盖；
> 之后支持反代模式改了 nginx 模板，又是一次同 tag 覆盖。每次都靠 `force=true` 硬来，
> 因为**补丁数没变而镜像内容变了**。
>
> 这正是 §4 把构建输入哈希并进 tag 的直接动因。改完之后，上面这两次修改都会各自
> 得到新 tag，不需要任何 force。**当时的旧 digest 无任何服务器消费过，所以没有实际影响** ——
> 但若已有生产机钉了该 tag，每次覆盖都是一次静默漂移。
