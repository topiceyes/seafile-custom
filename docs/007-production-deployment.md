# 007 - 生产部署（正式服务器）

> 完成日期：2026-09-20 ｜ 状态：镜像构建/彩排流程已建立，首次上线按本文执行

## 1. 架构

```
开发机（Mac）                        GitHub                              生产服务器（本地 docker + 云反代）
─────────────────                    ──────                              ──────────────────────────────────
seahub 二开分支 ──┐
export-patches.sh │                  Actions:                            docker compose pull
                  ├→ patches/ ──push→  ├ 取上游 seahub @固定SHA             （ghcr.io public 镜像）─→ docker compose up -d
deploy/image/*   ─┘                    ├ git am patches/                                                  ├ 云代理终止 TLS
                                       ├ 断言 tree sha                                                    └ 明文转发到本机 :80
                                       └ 构建 amd64 → ghcr.io
```

镜像由 **GitHub Actions 构建并推送到 ghcr.io**（见 [010](010-ci-release-pipeline.md)），
生产机只 `docker compose pull`，不需要 node、不需要 seahub 源码、不需要构建工具链。
TLS 由云上反向代理终止（本项目的实际形态，见 §9）；容器自签 LE 也已支持，两种模式配置见 §9。

与 dev 环境的本质差异：**二开代码不再 bind-mount，全部烘进镜像**（seahub Python 包 + 前端构建产物 + collectstatic 静态资源），容器重建不丢任何东西。

> 想让机器自己构建（而非拉现成镜像）也可以：`deploy/build-image.sh` 保留完整能力，
> 但它依赖本地有 `seahub/` 检出，所以只适用于开发机。

## 2. 前置条件（上线检查清单）

- [ ] **docker（≥20.10）+ 任一 compose 实现**：v2 插件（`docker compose`）或
  v1（`docker-compose`，**≥1.27** —— 本项目的 compose 文件是无 `version:` 键的
  compose-spec 格式、且依赖 `depends_on` 的 `service_healthy` 条件，v1 从 1.27 起
  两者都支持；1.29.2 实测解析 exit 0、条件保留，生产服务器就是这么跑的）。
  **机器上有什么用什么**：`init-prod-env.sh` 自动探测入口（v2 优先），末尾自检与
  打印的「下一步」命令都按同一形态；两种都没有才报错，报错里两种装法都给。
  老版 docker 没装 v2 插件时，`docker compose` 会报
  `unknown shorthand flag: 'f' in -f` 外加一整页 docker help——**极具误导性，
  看着像部署文件坏了**（2026-09-21 在生产服务器上撞过），探测就是为了
  让这类报错根本轮不到出现。
- [ ] **（上线时才需要，不是部署前提）** 域名 DNS 已指向**云反向代理**（不是本机）：
  `dig +short <域名>` 确认解析到代理的 IP
  - 反代模式下本机不需要公网 DNS；`SEAFILE_DOMAIN` 填的就是这个域名
  - **域名还没定也能先装**：`init-prod-env.sh` 默认用占位值 `seafile.local`，
    装完在「系统管理 → 设置 → Site URL」填真的——见 §4.2.1
- [ ] **本机 80 端口可被云代理访问到**（反代模式下只需要这一个）
  - 验证：从云代理那台机器 `curl -I http://<本机IP>/` 有响应即可
  - 反代模式下**不需要**本机 443 公网可达，也不需要 DNS 指向本机——证书和 DNS 都在云代理侧
  - （只有在用 `SEAFILE_SERVER_LETSENCRYPT=true` 时才需要 80 公网可达 + DNS 指向本机，
    因为那是容器自己跑 acme.sh webroot 验证）
  - **宿主机自己跑 nginx/面板（如宝塔）做反代时**：80/443 归宿主 nginx，容器端口用
    `.env` 的 `SEAFILE_HTTP_LISTEN` 挪开（如 `127.0.0.1:8080`）——见 §9.1
- [x] **不需要任何凭据**：仓库与镜像包都是 public，取部署文件和拉镜像都免登录
  （曾是 classic PAT，2026-09-20 转 public 后取消）。CI 推镜像用内置 `GITHUB_TOKEN`
- [x] **服务器网络可达两个域名**（免凭据，但都必须是通的）——**2026-09-21 已在生产服务器上
  实测通过**：`ghcr.io/v2/` → `401  0.673s`（401 即通），`codeload.github.com` 匿名取
  tarball → 200。这条曾是全案唯一未验证的假设（开发机可达 ≠ 服务器可达），现已消除：

  | 域名 | 用途 | 验证 |
  |---|---|---|
  | `codeload.github.com` | 取部署 tarball | `curl -so /dev/null -w '%{http_code}\n' --max-time 20 https://codeload.github.com/` → 200 |
  | `ghcr.io` | 拉**全部三个**镜像 | `curl -so /dev/null -w '%{http_code}\n' --max-time 20 https://ghcr.io/v2/` → **401 即通**（未认证是预期） |

  一条命令验完这两个：
  ```bash
  for h in codeload.github.com ghcr.io; do
    printf '%-24s ' "$h"
    curl -so /dev/null -w '%{http_code}\n' --max-time 20 "https://$h/"
  done
  ```

  > **需要几个域名取决于是「新装」还是「升级」——别混为一谈：**
  >
  > | 场景 | 要通的域名 |
  > |---|---|
  > | 日常**升级/回滚** | 只有 `ghcr.io` 一个（一个文件都不取，§6） |
  > | **新装**（固定 URL 那条） | `github.com` + `release-assets.githubusercontent.com` + `ghcr.io` |
  > | **新装**（codeload 兜底那条） | `codeload.github.com` + `ghcr.io`（✅ 两条都已在服务器实测） |
  >
  > 所以「只需要两个域名」这句话只对升级成立。**新装**要按上表选一条走。

  > ⚠️ **新装入口还要多一条，走的是另一个域名。** §4.1 的安装命令取的是
  > `https://github.com/<owner>/<repo>/releases/latest/download/<文件>`——它先是
  > **`github.com`**（要能解析并 302），再重定向到 **`release-assets.githubusercontent.com`**
  > 取真正的内容。这两个**都不在上面那两行里**，`codeload.github.com` 通不代表它们通
  > （2026-09-21 开发机上就是：`codeload` 通、`github.com` 直连超时，只能走代理）。
  > **服务器上装之前先验一遍**，一条命令：
  > ```bash
  > B=https://github.com/topiceyes/seafile-custom/releases/latest/download
  > curl -fLso /dev/null -w '%{http_code} %{size_download}B  %{url_effective}\n' \
  >   --max-time 60 "$B/seafile-prod.yml"     # 期望 200，且 url_effective 落在 githubusercontent 上
  > ```
  > 不通的兜底（不依赖 `github.com`，走 §2 验过的 `codeload`）：
  > ```bash
  > curl -fL --max-time 120 \
  >   https://codeload.github.com/topiceyes/seafile-custom/tar.gz/refs/tags/<最新 tag> \
  >   | tar -xz --strip-components=1 -C /opt/seafile-custom
  > ```
  > 那条路取到的是**整棵源码树**（含 `deploy/` 三个文件），是一棵钉死的树。
  > **升级路径完全不受影响**——升级一个文件都不取（§6）。

  > **`registry-1.docker.io` 曾经是必需的第三个域名，2026-09-21 起不再需要。**
  > 早先 compose 里 `mariadb` 与 `memcached` 直接引 Docker Hub，而国内网络常只有
  > 这一条不通（`Get "https://registry-1.docker.io/v2/": context deadline exceeded`
  > 或 `connection reset by peer`）。**这个报错会指向 Docker Hub 而不是我们自己的镜像，
  > 极易误判成「ghcr 挂了」**——当时就是在这个误判上绕了几轮。
  > 现在这两个镜像由 `.github/workflows/mirror-infra-images.yml` 镜像到 ghcr，
  > 三个镜像同源。Docker Hub 只影响 **CI 构建**（runner 侧拉基础镜像），
  > 已由 `DOCKERHUB_USERNAME`/`DOCKERHUB_TOKEN` secrets 缓解，见 docs/010 §7。

  > **离线导入**（服务器确实连不上 ghcr 时的保底，一定能成）：在开发机上
  > ```bash
  > cd deploy && ./make-offline-bundle.sh 12.0.14-dingtalk.9.1464e1b4   # 不给 tag 就取当前构建输入算出来的那个；可用值见 GitHub Releases
  > # → /tmp/seafile-offline-<tag>.tar.gz（三个镜像，约 690MB）
  > ```
  > ```bash
  > # 服务器上：
  > gunzip -c seafile-offline-<tag>.tar.gz | docker load
  > docker compose up -d        # ⚠️ 用 up，不要用 pull——pull 会强制联网，本地有也照拉
  > ```
  > 脚本会自己校验「每个镜像都有 tag 且都是 amd64」。
  >
  > 三个不写下来一定踩的坑（脚本里已处理，手工做时要当心）：
  > - **`--platform linux/amd64` 不能省**：开发机是 Apple Silicon，本地镜像是 arm64，
  >   不指定平台导出的包在 amd64 服务器上会报 `exec format error`。
  > - **必须按 tag 拉、不能按 digest 拉**：按 digest 拉的镜像没有 RepoTag，
  >   `docker save` 写出 `"RepoTags": null`，`docker load` 之后是个**无标签的悬空镜像**。
  >   症状很隐蔽——load 不报错、`docker images` 里也看得到（repo 显示 `<none>`），
  >   但 compose 按 tag 找不到它，于是又去联网拉、又失败。
  >   → 脚本会把 seafile 镜像**同时打上不可变 tag 和通道 tag**（compose 里那个
  >   `:latest`），所以服务器 load 之后**不需要动 `.env` 任何一行**。
  >   （2026-09-21 之前 compose 钉的是 digest，那时必须去 `.env` 里覆盖成 tag 形式；
  >   这个坑随通道 tag 一起消失了。）
  > - **基础镜像必须是 manifest list，不能是单平台 manifest**（2026-09-21 踩到）：
  >   单平台 manifest 在 arm64 上 `docker save --platform linux/amd64` 直接失败；
  >   **不带 `--platform` 更糟**——产出 8KB 空包且退出码为 0，一路静默到服务器。
  >   但**按 tag 拉时这一点不用你操心**——§6 的回滚是 `SEAFILE_PRO_IMAGE=<不可变 tag>`，
  >   走的就是 tag 形式。只有想按 digest 钉死时才要留意别钉到单平台那份。
  >
  > ⚠️ **包里三个镜像的 tag 必须与当前 compose 一致。** compose 换过源
  > （2026-09-21：`mariadb:10.11` → `ghcr.io/topiceyes/mariadb:10.11`），
  > **那次之前打的包作废**——load 进去的 tag 名字对不上，compose 会转去联网拉又失败。
  > 打完之后可以自查：
  > ```bash
  > tar -xOf seafile-offline-<tag>.tar.gz manifest.json | python3 -m json.tool | grep RepoTags -A2
  > # 应列出 ghcr.io/topiceyes/{seafile-mc,mariadb,memcached} 三个
  > ```
  >
  > ⚠️ **离线导入是应急路径，不是常态**——每次更新都要手工搬一次。服务器长期够不着
  > 仓库的话，应该把镜像推到国内仓库（ACR/TCR），见 [010 §8](010-ci-release-pipeline.md)。

- [x] 若 `ghcr.io` 也不通：走 [010 §8](010-ci-release-pipeline.md) 的 ACR 备选，
  或把 seafile 镜像也 `docker save` 搬过去（同一套办法）——**此路本次未启用**
  （服务器直连 ghcr 已实测可用，见上）
- [ ] 服务器磁盘规划：`/data/seafile`（库+文件+备份）与 `/data/seafile-mysql` 所在盘要够大
- [ ] 钉钉回调域名准备好切到 `https://<域名>/dingtalk/callback/`（上线后改）

## 3. 镜像构建（GitHub Actions）

镜像是 CI 自动构建并推送到 ghcr.io 的，**服务器上不需要构建**。完整机制见
[010 CI 发布流水线](010-ci-release-pipeline.md)，这里只列日常操作。

```bash
# 日常：在 seahub 分支上改完代码后
cd deploy && ./export-patches.sh          # 重导补丁 + 刷新 patches/MANIFEST.md
git add -A && git commit -m "..." && git push     # 推 main 会自动触发构建
gh run watch                              # 看构建进度（也可在网页 Actions 页看）

# 手工触发 / 覆盖已存在的 tag
gh workflow run build-image.yml
gh workflow run build-image.yml -f force=true
```

**构建成功即发布完成，没有任何人工步骤。** CI 会自己完成剩下两件事（详见
[010 §4](010-ci-release-pipeline.md)）：把 `latest` 通道 tag 搬到这次构建的镜像上
（搬之前会断言它与不可变 tag 是同一个 digest），并建一个 GitHub Release 作为发布记录。
服务器侧只要 `docker compose pull && docker compose up -d` 就拿到新版本——**不需要
重取或修改任何文件**。理由与流程见 §6。

**CI 在构建前会跑三道校验**，任何一道不过都会拒绝发布：源码树必须等于
`patches/MANIFEST.md` 记录的 tree sha、tag 血缘（补丁数/基础镜像版本/编号连续性）、
tag 未被占用。**本地构建同样会校验补丁树**，所以开发机上不可能构建出与补丁不一致的镜像。

### 3.1 本地构建（备选路径）

`deploy/build-image.sh` 保留完整构建能力，用于本地彩排（§7）。它依赖开发机上存在
`seahub/` 检出；推 registry 时需自行 `docker login`（本地推 ACR 时用，ghcr 已免登录）：

```bash
cd deploy
./build-image.sh --local                                  # 本地彩排：仅 arm64、不推送
./build-image.sh registry.cn-hangzhou.aliyuncs.com/myns    # 推 ACR（ghcr 不可达时的后路）
```

- tag 由 `./build-image.sh --print-tag` 算出：`12.0.14-dingtalk.<N>.<8位哈希>`。
  哈希段是**构建输入的内容哈希**（补丁内容 + `deploy/image/**` + `build-image.sh`），
  所以改模板/Dockerfile 也会自动得到新 tag —— 同 tag 即同内容（详见 010 §4）
- 防呆：seahub 工作区不干净、或补丁树与分支树不一致，都会拒绝构建
- 推 registry 默认双架构（amd64+arm64）；CI 只构建 amd64（runner 原生，arm64 走 QEMU 会拖到一小时以上）

**网络坑**（开发机在国内网络下实测）：
- `docker pull node:24-bookworm-slim` 等基础镜像可能因 DNS 污染超时——**重试即可**（间歇性），成功后本地有缓存
- Dockerfile 不用 `# syntax=` 指令（会去 docker.io 拉前端镜像，同样受 DNS 污染影响）
- git 经代理推送偶发 HTTP/2 中断（`stream ... was not CANCEL cleanly`）：重试，或改用 SSH

**冒烟验证**（CI 对每个推上去的镜像自动跑同一套；手工验证时用）：

```bash
docker run --rm --entrypoint sh \
  -v "$PWD/deploy/smoke-test.sh:/smoke.sh:ro" \
  <镜像> /smoke.sh
# 例：<镜像> = seafile-mc-devbuild:12.0.14-dingtalk.8（本地彩排）或 ghcr.io/topiceyes/seafile-mc:<tag>
```

断言都在 [`deploy/smoke-test.sh`](../deploy/smoke-test.sh)，**只有这一份** —— CI 与本文都引用它。
（这套断言曾在 workflow 和本文里各维护一份，结果本文那份写错了路径：断言
`frontend/build/static/js`，而 CRA 的 `appBuild` 实际是 `build/frontend`，且真正被浏览器
请求的是 collectstatic 产物 `media/assets/frontend/static/js`。CI 首次运行才暴露。
**改断言只改那个脚本**，并注意：改它不会自动触发构建，要验证得
`gh workflow run build-image.yml -f force=true` 重跑一次。）

脚本还会打印三个指纹（二开 overlay 内容哈希、被服务的前端产物清单、media/assets 清单），
CI 的 run summary 里也有一份 —— 用于比对 CI 的 amd64 产物与开发机的 arm64 产物（§10）。

## 4. 服务器部署

**这一步一辈子只做一次。** 装完之后，升级永远只是 `docker compose pull && docker compose
up -d`，不需要再取任何文件（版本由 CI 搬动通道 tag，见 §6）。

**运行时只需要 `seafile-prod.yml` + `.env` 两个文件。** 生产 compose 里**没有任何
宿主机相对路径**（`backup.sh` 与两个 cron 已烘进镜像），所以

> **放哪个目录都能起。** 这一点是刻意设计的：以前那三个 bind-mount 会让「换个目录
> 启动」变成**静默故障** —— 挂载落空、容器照常起，但备份和离职同步都不再执行。

`seafile-prod.yml` 是**运行时**必需，`.env` 由 `init-prod-env.sh` 生成。要取的第三个文件
就是那个生成器本身。三个都挂在固定的 release 资产 URL 上，不需要仓库、不需要凭据。

> 早先这里还有一步「首启之后手工跑 `init-conf.sh --prod` 追加二开定制」。**2026-09-21 起
> 那一步已在镜像内自动完成**，部署不再需要它——见 §4.2.2。

```bash
# ---- 4.1 取部署文件（免代理、免凭据）----
# 从 GitHub Release 的固定 URL 取，仓库是 public，裸 curl 即可。
# （服务器到 github.com 的 git 协议不通，但 HTTPS 下载这条路可直连，见 §2）
# ⚠️ 目录名是 deploy/ ：§6 的升级与回滚命令都写 `cd /opt/seafile-custom/deploy`，
#    下面 codeload 兜底解出来的也是 deploy/ 。两条入口必须落到同一个位置，
#    否则升级那条命令照抄就是 No such file or directory。
mkdir -p /opt/seafile-custom/deploy && cd /opt/seafile-custom/deploy
B=https://github.com/topiceyes/seafile-custom/releases/latest/download
curl -fLO $B/seafile-prod.yml
curl -fLO $B/env.prod.example
curl -fLfo init-prod-env.sh $B/init-prod-env.sh && chmod +x init-prod-env.sh

# ---- 4.2 配置：一条命令生成 .env（密钥自动生成，零提问）----
./init-prod-env.sh                 # 零交互，直接跑
# 想提前定好就带参数（都可省略）：
#   ./init-prod-env.sh --domain seafile.x.cn --admin-email a@x.cn --admin-password 'xxx'
#
# 脚本做三件事：生成全部密钥、只改该改的行（反代模式那两个开关原样保留，并会自检）、
# 拒绝含单引号的值（单引号会破坏 .env 的 '值' 解析）。
# 它还会把 .env 里那两个数据目录**直接建好**，并打印后续命令。

# 管理员密码默认自动生成、只在终端显示这一次 —— 记得抄进密码管理器。

# （没有 mkdir 那一步了：init-prod-env.sh 已经按 .env 里的路径建好数据目录）

# ---- 4.3 起服务（就这一条命令，没有下一步）----
docker compose pull                # 镜像包是 public，不需要 docker login
docker compose up -d               # db + memcached + seafile 一起起，按依赖顺序
# 这一条命令自己会等：compose 里 db 带 healthcheck，seafile 是
#   depends_on: {db: {condition: service_healthy}, memcached: {condition: service_started}}
# 所以不需要「先起 db、等一会儿、再起 seafile」那样分段启动。
#
# 容器内首启顺序（全部自动，不需要人工介入）：
#   渲染 nginx 配置 → 等 MariaDB → setup 生成基础配置 + 建管理员
#   → 追加二开定制（SSO/钉钉默认开关/账号管控 + 开 WebDAV）← custom_bootstrap.py
#   → 起 seafile/seahub/seafdav
# （LETSENCRYPT=true 时中间还会签发证书；本项目是反代模式，不签）
```

> 机器上只有 `docker-compose`（v1）的：把文中 `docker compose` 原样换成
> `docker-compose` 即可，两者对本项目的文件等效（§2）。`init-prod-env.sh`
> 打印的「下一步」已按本机探测到的入口写好，照抄它就行。

**装完就完了。** 二开定制的追加已在镜像内完成（见 §4.2.2），生产上**没有**"再跑一个脚本"
这一步；仓库里的 `init-conf.sh` 现在只剩 dev 用途，`--prod` 会直接报错退出。

**资产 URL 的真实链路**（2026-09-21 实测，不是推断）：

```
…/releases/latest/download/<名>      302 →  …/releases/download/<tag>/<名>
                                     302 →  release-assets.githubusercontent.com/…
                                     200
```

也就是说要通两个域名：`github.com`（两次 302 都在这台上）+ `release-assets.githubusercontent.com`
（真正吐字节的那台）。**这两个域名从没在生产服务器上验过**——本机实测 `github.com`
直连超时（得走代理），而服务器代理机可能又是另一回事。

所以下面这条 `codeload.github.com` 入口**不是「万一不通再说」的备选，而是并列的第二条路**：
它已在服务器上实测可达（§2）。两条都给全，你按哪条走都能成，**不需要先试错**：

```bash
curl -fL --max-time 120 \
  https://codeload.github.com/topiceyes/seafile-custom/tar.gz/refs/tags/<tag> \
  | tar -xz --strip-components=1 -C /opt/seafile-custom
```

（<tag> 取 GitHub Releases 上最新那条，形如 `12.0.14-dingtalk.9.ed2042da`。这是一棵钉死的树，
解出来就是 `deploy/`，与上面固定 URL 那条落到同一个位置。）

`init-prod-env.sh` 会自检取回来的 `seafile-prod.yml` 是否完整（形状 + `docker compose
config -q` 能整份解析），弄坏了会立刻报错而不是等 `pull` 时才炸。

### 4.2.1 部署时不需要知道的东西（装完再配）

上面这套流程刻意**不要求部署时就知道域名和钉钉凭据**——这两样都能装完之后再定，而且
`init-prod-env.sh` 因此可以零提问地一口气跑完。分别说明：

**域名**：`.env` 里的 `SEAFILE_DOMAIN` 填的只是**初始默认值**（可以先用占位值 `seafile.local`）。
`SERVICE_URL` 已 constance 化（补丁 0009），装完在**系统管理 → 设置 → Site → Site URL** 填真域名，
**保存即生效、不用重启**。分享链接、下载链接、钉钉回调地址全部跟着它走。

- `FILE_SERVER_ROOT` **不用单独填**——由 `SERVICE_URL` 推导（上游那两处分开填是冗余，
  改一处忘另一处的症状是「页面能开、上传下载坏」）
- nginx `server_name` 仍然是首启渲染的一次性产物，但反代模式下它是**装饰性**的
  （只有一个 server 块 = 默认虚拟主机），域名不匹配照样能访问
- 详见 [docs/011](011-service-url-admin-config.md)

> **为什么不能只改 `.env` 重来**：容器里的 `bootstrap.py:generate_local_nginx_conf()` 只在
> `/shared/nginx/conf/seafile.nginx.conf` **不存在**时才渲染，首启之后改环境变量不再有任何效果。
> 但 `SERVICE_URL` 现在走数据库，不受这个限制——这正是补丁 0009 要解决的问题。

> **模板更新会自动传播（2026-09-23 起）**：镜像里的 `custom_bootstrap.sync_nginx_conf()`
> 在每次启动时校验数据卷里的 nginx conf 是否出自**当前**模板（sidecar 指纹快路径 +
> 逐字节比对），旧模板的滞留件自动挪走为 `.bak-*` 并由上游 renderer 重渲染。
> 2026-09-22 生产 403 第三形态（拉了三版新镜像、容器里跑的还是首启模板的规则）
> 由此根除；彩排 §7.2 步骤 10b 钉住这条升级路径。域名变更仍按上面的流程走
> （域名是渲染输入之一，改 `.env` 后 `down && up -d` 即重渲染）。

> **改完域名要手工同步的只有一处**：钉钉开发者后台的回调域名。那是钉钉侧的配置，
> Seafile 只能生成地址、改不了对方后台。

**钉钉凭据**：`.env` 里的 `SEAHUB_DINGTALK_APP_KEY/SECRET` 留空即可。钉钉配置走 constance
（数据库表），装完在**系统管理 → 设置**页填，**免重启生效**（见 [docs/002](002-dingtalk-admin-config.md)）。
先填后填不影响首启，也不影响扫码登录之外的任何功能。

**管理员密码**：自动生成并只显示一次。登录后自己在页面上改，不用记在 `.env` 里。

> **（历史记录）转 public 之前，这一步是本项目最容易卡住的地方**：当时仓库与镜像包都是私有，
> 要用一个 classic PAT（`repo` + `read:packages`）覆盖「取 tarball + 拉镜像」两件事。
> 最坑的是 **`docker login ghcr.io` 对 scope 不足的 token 会报 `Login Succeeded`**，
> 真正的 403 要到 `docker pull` 才暴露——用 gh 的 OAuth token 实测过这个现象。
> 转 public 后这一整类失败面消失，这也是当初决定公开的主要动因。

### 4.2.2 二开定制是怎么自动生效的

定制项（SSO / 钉钉默认开关 / 账号管控 + 开 WebDAV）的追加**已在镜像内完成，部署时没有这一步**。

**为什么不能预渲染进镜像。** 全新数据卷首启时，镜像内 `setup-seafile-mysql.py` 用 `open('w')`
**无条件重写** `seahub_settings.py`（SECRET_KEY 随机、DB 密码取 `DB_PASSWORD` 环境变量、
SERVICE_URL 取 `SEAFILE_SERVER_*`）和 `seafdav.conf`。镜像里预置的内容会被整体覆盖，
这条路走不通。

**所以只能在"setup 写完、服务起来"之间那个窗口里追加。** 这个窗口是 `start.py` 里的两行之间：

```
start.py: main()
  ├─ init_letsencrypt()            （仅 LETSENCRYPT=true）
  ├─ generate_local_nginx_conf()
  ├─ wait_for_mysql()
  ├─ init_seafile_server()         ← setup 在这里写 seahub_settings.py / seafdav.conf
  ├─ init_custom_settings()        ← ★ 二开定制在这里追加（镜像插入的那一行）
  ├─ seafile.sh start              ← WebDAV 由这个起
  └─ seahub.sh start               ← seahub_settings.py 由这个读
```

时机只有这一种选法：**早了**会被 setup 的 `open('w')` 覆盖；**晚了** seahub 已经起来，
而 `seahub_settings.py` 是**导入期**读的，改了必须重启。就这个窗口，改完**直接生效、不需要重启**。

实现在 `deploy/image/custom_bootstrap.py`，由 Dockerfile 第 8 项 COPY 进镜像、并往 `start.py`
插一行调用（**构建期有断言**，见 `smoke-test.sh` 第 6 项：不只检查接线，还在假配置目录上
真跑一遍验行为和幂等）。

**幂等**：**逐项核对，缺哪行补哪行**（不是「整块在就跳过」）。每次容器启动都校验一遍，
所以配置文件被覆盖 / 丢掉 / 只丢其中一项 / 数据卷重建，下次启动都会自动补回来。

> 早先是整块级的（看见标记就跳过）。2026-09-21 撞到了它的盲区：给**已部署**的机器
> **新增**一项设置时，标记块早就在了，于是新设置**永远写不进去**——这个机制能自愈
> 「块被删掉」，却自愈不了「块里少一行」。反代模式那个登录 403 之所以没被自动修好，
> 就是撞在这里（见 §9）。改成逐项之后没有这个盲区，`smoke-test.sh` 第 6 项专门钉住了
> 升级路径。

> **这一条为什么值得从"手工脚本"改成"烘进镜像"。** 原先它是部署时人手工跑的
> `init-conf.sh --prod`（等首启 → 追加 → 重启两个服务）。手工步骤的问题不是麻烦，是
> **忘了不会报错**：SSO、账号管控、WebDAV 全部静默失效，而页面照常打开。这和本项目
> 一路上在消灭的其它静默失败（换目录挂载落空、`from seahub.settings import` 静默过期）
> 是同一个模式。

**代价**：动了上游的启动脚本（`start.py` 与 `enterpoint.sh`，共三处；清单与理由见 §4.2.3）。
这是升级 Seafile 时的漂移点，Dockerfile 头部列了完整清单。鉴于本项目已冻结在 12.0.14
（不再跟随上游），这个代价可以接受；即便如此，断言仍然保留——它防的不再是上游漂移，
而是**我自己的编辑静默失效**。

> **（被否决的替代方案）** 不改 `start.py`，改为让二开代码从环境变量 / constance 读这三项。
> 否决理由：`CLIENT_SSO_VIA_LOCAL_BROWSER` 在 `urls.py` 导入期决定路由注册、
> `ENABLE_DELETE_ACCOUNT` 在 `profile/views.py` 模块级绑定——这两处本来就必须在**模块导入期**
> 拿到值，改成运行时读只是把"写文件"换成"改二开代码去读别处"，并没有消灭那个约束，
> 反而把配置来源从一处变成两处。

**为什么这几项非得写文件、不能像 `SERVICE_URL` 那样走 constance**：判据是**调用点的绑定方式**，
不是「重不重要」。清单（改一处要对照一处）：

| 设置 | 调用点 | 绑定时机 |
|---|---|---|
| `CLIENT_SSO_VIA_LOCAL_BROWSER` | `urls.py` / `api2/urls.py` / `views/sso.py` | 模块导入期读它注册路由 → 后台改了 URL 也不会注册 |
| `ENABLE_DINGTALK` | `settings.py:1236` | 它决定 constance 里该键的**默认值**（真正生效的开关仍是 constance） |
| `ENABLE_DELETE_ACCOUNT` | `profile/views.py:27` | 模块级 `from seahub.settings import` → 启动期固化 |
| `SECURE_PROXY_SSL_HEADER` | Django 的 `HttpRequest.scheme` | **不属于调用点绑定**，属于部署形态——上游从没设过它，只能落在配置文件里。见 §9 |

清单的准确定义在 `custom_bootstrap.py` 的 `MANAGED_SETTINGS`（键名 + 赋值行），加新项改那里。

（`DINGTALK_APP_KEY/SECRET` 不在这个清单里：它们已是纯 constance，`.env` 留空、装完在后台填。）

**首启时容器内发生的事**（顺序，两处按 §9 的模式分叉）：
1. `init_letsencrypt()`：**仅 `LETSENCRYPT=true` 时执行** —— 先起临时 http 配置 → acme.sh
   webroot 验证 → 证书落 `/shared/ssl/<域名>.crt|key` → 装每日续期 cron。
   本项目是反代模式，这一步整个跳过（证书在云代理上）
2. `generate_local_nginx_conf()`：渲染 nginx server 块（我们修过的模板，含 X-Forwarded-Proto）。
   监听 443+证书 还是只有 80，由第 1 步结果决定
3. setup 初始化 MariaDB 三库（`DB_USER`/`DB_PASSWORD` 环境变量决定 seafile 库用户）+ 建 `INIT_SEAFILE_ADMIN_EMAIL` 管理员 + 生成基础 seahub_settings.py 与 seafdav.conf
4. `custom_bootstrap.py` 追加二开定制（SSO / 钉钉默认开关 / 账号管控）+ 开 WebDAV（见 §4.2.2）
5. 起 seafile/seahub/seafdav

### 4.2.3 对上游启动脚本的三处改动（`deploy/image/patch-upstream.py`）

二开本身只动 `seahub/`，但**启动链路**上有三处非改不可。三处全部由 `patch-upstream.py` 在
构建期打入，每处都带前后断言（匹配不上 → 构建失败）。脚本跑完即删，不进最终镜像。

| # | 文件 | 改了什么 | 不改会怎样 |
|---|---|---|---|
| 1 | `start.py` | 插入 `custom_bootstrap` 的 import 与 `init_custom_settings()` 调用 | 二开定制不生效（见 §4.2.2） |
| 2 | `start.py` | 起 seahub 的 `call(...)` → `start_service_retry(...)` | 忙时误判启动失败，容器反复重启 |
| 3 | `enterpoint.sh` | 记下 `start.py` 的 PID；它死掉时容器跟着退出 | **容器永远 `Up`、网站却是死的** |

**为什么用脚本而不是 Dockerfile 里堆 `sed`**：`sed` 的失败方式是静默的——正则没匹配上时它
**成功返回**，改动没进去而构建照样绿。这里统一要求「改前匹配恰好 N 处、改后确实生效」，
任一不满足就 `exit 1`。

#### 第 2 处：`seahub.sh` 的 5 秒误判

上游 `seahub.sh` 判定 seahub 起没起来的方式是硬编码 `sleep 5` 再 `pgrep` 一次：

```bash
$PYTHON $gunicorn_exe seahub.wsgi:application -c "${gunicorn_conf}" --preload &
sleep 5
if ! pgrep -f "seahub.wsgi:application"; then ... exit 1; fi
```

`--preload` 要求 gunicorn master 先把整个 Django 应用导入完才 fork。机器一忙就可能超过 5 秒
→ **误判成失败** → `start.py` 退出。2026-09-21 本地彩排实测撞到过一次：日志报
`Seahub failed to start`，而手工再跑一次 `seahub.sh start` 立刻就好。

重试是对症的：它不关心失败原因，在上层重来一次即可。`utils.call()` 默认走
`subprocess.check_call`，失败抛 `CalledProcessError`，所以重试**真的会被触发**，不是装饰性的。
默认 3 次、间隔 5 秒。

> **为什么不直接改 `seahub.sh`**：那个 5 秒是上游对「启动快慢」的假设，改成轮询等待要重写它的
> 判定逻辑；而我们需要的只是「失败就再来一次」。改 `start.py` 的调用点，改动面小得多。

#### 第 3 处：保活循环为什么必须跟着死（本次最要紧的一条）

上游 `enterpoint.sh` 的保活循环：

```bash
/scripts/start.py &
...
while [ 1 ]; do sleep 60 & wait $!; done
```

只要这个循环还在，容器就一直是 `Up`。于是**任何**导致 `start.py` 退出的原因（setup 失败、
MySQL 等不到、seahub 起不来、LE 签发失败）都会留下一个「`docker ps` 显示 `Up`、网站却是死的」
容器——而且 `restart: unless-stopped` **救不了它，因为容器根本没有退出**。

这是最坏的一类静默失败：它骗过所有常规检查（进程在、容器在、端口在监听），只有真去访问站点
才会发现。修法是让保活循环检查 `start.py` 是否还活着，死了就 `exit 1` → 容器退出 →
重启策略接管 → 失败可见、可自愈。

**检测延迟最长 60 秒**（受 `sleep 60 & wait $!` 的粒度限制），可接受——重启策略本来就不是秒级的。
改完之后容器多了一种「反复重启」的表现，那是**好**现象：它把静默失败换成了可见失败。

> `SERVER_PID=$!` 放在 `if/else` **之后**：两个分支（cluster server / 普通）都以后台方式启动，
> 所以 `$!` 在两种情况下都指向它。位置若放错（比如塞进某个分支里），`kill -0 ""` 恒失败，
> 容器会一启动就退出、陷入无限重启。`smoke-test.sh` 第 6 项对 `SERVER_PID=$!` 独占一行有断言，
> 就是为了拦住这类改法。

### ⚠️ 首启常见失败与处置

**1. LE 首签失败**（签发失败会 `RuntimeError` 杀死启动脚本，容器随之退出并进入重启循环——
这是 2026-09-21 保活补丁之后的行为，见 §4.2.3；补丁之前容器会一直显示 `Up` 而网站是死的）。
症状：容器反复重启、`docker logs` 停在 letsencrypt 相关错误。排查：
- `dig +short <域名>` 是否解析到本机
- 80 端口公网可达性（见前置检查）
- `/shared/ssl/letsencrypt.log`（容器内路径）
- 注意 LE 频控：同域名每周最多 5 次失败签发，反复重试前先解决根因

**2. MariaDB 首次初始化竞态 —— 已由 compose 结构性消除。** 全新数据卷时 MariaDB 初始化
分两阶段（先只用 unix socket 建 root 密码 + 跑 init SQL，再带网络重启一次）。早期 compose
没写 `healthcheck`，`depends_on` 也不带条件，于是 seafile 会和 db 同时起，setup 撞上还没
就绪的 MariaDB 以 `exit 255` 退出 —— 当时的处置是「人工先起 db、等 30 秒、再起 seafile」。

现在 `db` 带 `healthcheck: healthcheck.sh --connect --innodb_initialized`
（两项缺一不可：`--connect` 只证明能连上，`--innodb_initialized` 才证明两阶段都走完；
只看端口开放会把第一阶段那个临时服务器误判成就绪），`seafile` 用
`condition: service_healthy` 等它。**手工分段启动那段流程因此不再需要。**

若在非 compose 场景（例如手写 `docker run`）重现此错，处置仍是：等
`docker logs seafile-mysql` 出现 `ready for connections` 且不再滚动，然后
`docker restart seafile` 重跑。setup 是幂等的（没建完 seafile-data 前重跑无副作用）。

**3. `seafile-data already exists`**：镜像构建期残留的 `/opt/seafile/seafile-data` 空目录会让 setup 的 auto 模式直接拒绝。我们的 Dockerfile 已修复（collectstatic 的临时目录随层清理）；若自定义镜像时重现此错，检查镜像里 `/opt/seafile/` 下是否只有 `seafile-server-12.0.14`。

**4. 登录 403 `CSRF verification failed`**（**页面能打开、一提交表单就 403**，很像 cookie 问题）：
反代模式下 `SECURE_PROXY_SSL_HEADER` 没写进 `seahub_settings.py`。Django 因此不认
`X-Forwarded-Proto`，`request.is_secure()` 恒为假，CSRF 的 `good_origin` 算成
`http://域名`，与浏览器的 `Origin: https://域名` 对不上。

先确认原因（页面上因 `DEBUG=False` 不显示细节，日志里有）：

```bash
docker exec seafile grep -iE "Forbidden|csrf" /shared/seafile/logs/seahub.log | tail -5
```

- `Origin checking failed - https://… does not match any trusted origins` → 就是这条，按 §9 处置
- `CSRF cookie not set` → 另一回事：代理没把 cookie 转发进来

根因与完整推演见 §9。**不要手工往容器里 `echo` 配置**——那台机器下次重建就丢了，
按 §9 的机制走镜像。

## 5. 上线后动作

0. **切真域名**：管理员登录 → 系统管理 → 设置 → Site → Site URL 填 `https://你的域名` → 保存。
   **不用重启**（补丁 0009，见 [docs/011](011-service-url-admin-config.md)）。
   然后试一次**文件上传 + 下载**——这条过了就说明新地址完全生效了。
1. **钉钉开发者后台**：回调域名改为 `https://<域名>/dingtalk/callback/`
2. 管理员登录 → 系统管理 → 设置：核对钉钉开关与密钥（constance 默认值来自渲染的 seahub_settings.py）
3. 验证清单（**按本项目的反代形态写的**；`LETSENCRYPT=true` 的自签形态另有几条，见括号）：
   - `curl -sI https://<域名>/` → 200，证书链正常（**反代模式下签发者是你的云代理/证书服务，
     不是 Let's Encrypt**——那台机器不跑 acme.sh）
   - 容器 80 只被**代理**访问：`curl -sI http://<容器IP>/` 有响应即可，
     **不要**期待浏览器访问 `http://<域名>/` 会 301 到 https——那次跳转是云代理做的，
     不是容器做的（容器侧只在 `LETSENCRYPT=true` 时才渲染那条 `rewrite … permanent`）
   - 钉钉扫码登录（真实手机）
   - 桌面客户端 client-SSO（`https://<域名>`，正式证书无需手动信任）
   - 普通用户密码登录被拒（0008 生效）、管理员可登录
   - WebDAV：`https://<域名>/seafdav/`
4. 次日检查 `backup.log` 与 `/data/seafile/backup/` 产物
5. **做一次恢复演练**（docs/009），确认备份可用

## 6. 更新与回滚

**升级就是一条命令。服务器上不需要改任何文件，也不需要重取仓库。**

```bash
cd /opt/seafile-custom/deploy
docker compose pull && docker compose up -d
```

> 只有 `docker-compose`（v1）的机器：把 `docker compose` 换成 `docker-compose` 照抄，等效（§2）。

为什么不用改文件：compose 里那行是

```yaml
image: ${SEAFILE_PRO_IMAGE:-ghcr.io/topiceyes/seafile-mc:latest}
```

`latest` 是个**通道 tag——一个指针**，由 CI 在「构建 + 冒烟全绿」之后自动搬过去
（[010 §4](010-ci-release-pipeline.md)）。所以「发布完成」这件事不需要任何人通知服务器：
下一次 `pull` 自然就落到新版本上。**发布全程零人工步骤。**

> **盘一下哪些不再是人工动作**（2026-09-21 之前每一条都是）：
> 把 digest 抄进 compose 并推送、手工往台账补一行、升级前重取一次仓库 tarball。
> 第三种是最阴的：忘了重取时 `pull` 照样报 `Pulled`、`up -d` 照样报 `Recreated`，
> 跑的却是**旧镜像，全程没有任何一处报错**——2026-09-21 的发布事故就是这个形状。
> 现在这条失败路径在结构上不存在了。

**回滚**＝把通道换成某个不可变 tag，一条命令，不用动仓库：

```bash
cd /opt/seafile-custom/deploy
SEAFILE_PRO_IMAGE='ghcr.io/topiceyes/seafile-mc:12.0.14-dingtalk.9.<hash>' \
  docker compose pull && SEAFILE_PRO_IMAGE='ghcr.io/topiceyes/seafile-mc:12.0.14-dingtalk.9.<hash>' \
  docker compose up -d
```

两处都要带，因为 `pull` 和 `up` 是两次独立的命令解析。要滚回哪个版本去
[GitHub Releases](https://github.com/topiceyes/seafile-custom/releases) 找——每个版本一条记录，
unreleased 的 tag、digest、构建输入指纹都在里面。数据卷全程不动。

> **建议命令行内联，而不是写进 `.env`。** 写进 `.env` 且没注释掉，这台机器就**永久钉死**
> 在那个版本上、不再跟随发布——这是刻意的 pin，不是「改了没生效」。回滚是临时状态，
> 内联更贴合它的寿命；回滚完再跑一次不带变量的 `pull && up -d` 就回到通道。

**离线导入**同理不留痕：`make-offline-bundle.sh` 打的包里同时带了通道 tag，服务器
`gunzip | docker load` 之后直接 `docker compose up -d`（**不要** `pull`）即可，
`.env` 一行都不用改。

**首次生产更新后做一次回滚演练**：按上面的方式切回旧 tag → 确认行为回到旧版本，
再切回新版。数据卷全程不动。

（这里以前还有一句「更新前先记下当前镜像的 digest」——那是手工台账时代的习惯，
现在每一版的 tag 与 digest 都记在 [GitHub Releases](https://github.com/topiceyes/seafile-custom/releases) 上，
不需要你在服务器上抄任何东西。）

> ⚠️ **一条通道 = 所有服务器共用一道闸门。** 冒烟测不出、但真坏了的版本（反代下登录 403
> 那一类）会随下一次 `pull` 扩散到所有机器。最便宜的缓解：**先在一台 pull + 真浏览器走一遍
> 登录**，确认了再滚其余；真出事就上面那条回滚命令。



**升级 Seafile 版本**（如 12.0.14 → 12.1.x）时三处硬编码要同步：
`deploy/image/Dockerfile` 的 BASE_IMAGE 与 INSTALLPATH、seahub 仓库基线（patches 重放）。官方镜像可能改 bootstrap 行为，升级前**必须重跑本地彩排**。

## 7. 本地彩排

两个模式，**覆盖的东西不一样，别只跑一个**：

| | §7.1 模式 A：容器自签 TLS | §7.2 模式 B：反代模式 |
|---|---|---|
| `SEAFILE_SERVER_LETSENCRYPT` | `true`（容器自己终止 TLS） | `false`（代理终止 TLS） |
| 对应生产形态 | ❌ 不是本项目形态 | ✅ **就是本项目形态** |
| 速度 | 快（arm64 本地产物） | 慢（要拉 amd64 通道 tag） |
| 用途 | 改 nginx 模板 / settings 时的快速回归 | **上线前必跑** |

### 7.1 模式 A：容器自签 TLS（快速回归，**不覆盖反代模式**）

利用 `init_letsencrypt()` 的特性——证书有效期 >30 天就跳过签发只装续期 cron——在 Mac 上完整走一遍生产首启链路（唯一差异：证书是自签而非 LE）。

```bash
cd deploy

# 1) 本地构建镜像（arm64，不推送）
./build-image.sh --local

# 2) 彩排环境配置（独立数据目录 + 独立项目名 + macOS db 覆盖）
cp env.prod.example .env.rehearsal
vi .env.rehearsal     # ⚠️ SEAFILE_SERVER_LETSENCRYPT='true' —— 彩排必须显式设回 true！
                      #    模板默认是 false（反代模式，见 §9），那会让容器只监听 80、
                      #    不渲染 443 块，下面的自签证书就白做了。LE 模式才是
                      #    「证书有效期>30天则跳过签发」这条彩排技巧成立的前提。
                      # SEAFILE_DOMAIN=<生产规划域名>（仅本机解析，curl 用 --resolve 即可不改 /etc/hosts）
                      # SEAFILE_PRO_IMAGE=seafile-mc-devbuild:<tag>（本地产物；要走已发布的
                      #    amd64 通道 tag 就别设这一行，见 §7.2）
                      # SEAFILE_VOLUME=./rehearsal-data
                      # SEAFILE_MYSQL_VOLUME=./rehearsal-mysql（数据卷改相对路径）
                      # COMPOSE_FILE='seafile-prod.yml:rehearsal-db-override.yml'   ⚠️ mac 必加
# rehearsal-db-override.yml：db 加 --lower-case-table-names=1。macOS 文件系统大小写不敏感，
# MariaDB 默认 lctn=2 会让 seafevents 统计表（Monthly*）.frm/.ibd 大小写错位 → mysqldump 中断。
# ⚠️ lctn 只在首次初始化生效，必须配全新数据卷。

# 3) 域名自签证书（>30 天才会跳过 LE 签发）
SEAFILE_VOLUME=./rehearsal-data ./gen-ssl-cert.sh <域名>

# 4) 首启：一条命令。db 的 healthcheck + seafile 的 service_healthy 依赖会自己排好序
#    （§4 失败场景 2 的 MariaDB 竞态已由此消除，不再需要手工分段启动）。
#    注意：--env-file 必须显式带（compose 默认只读 .env，那是 dev 的配置）
export COMPOSE_PROJECT_NAME=seafile-rehearsal
docker compose --env-file .env.rehearsal up -d
docker logs seafile 2>&1 | grep -E "letsencrypt|Skip"   # 期望 Skip letsencrypt verification

# 5) 没有第 5 步了。二开定制的追加已由镜像内的 custom_bootstrap.py 在 up -d 过程中
#    自动完成（§4.2.2）。直接验结果即可：
grep -A2 '二开定制' rehearsal-data/seafile/conf/seahub_settings.py
grep '^enabled' rehearsal-data/seafile/conf/seafdav.conf    # 期望 enabled = true
```

> ⚠️ **§7.1 覆盖不到反代模式。** 这里为了让自签证书生效，把
> `SEAFILE_SERVER_LETSENCRYPT` 设回了 `true`（容器自己终止 TLS），于是
> `$scheme` 就是 https、`request.is_secure()` 天然为真。**生产的形态是
> `false`（TLS 在云代理终止、容器只听 80），那条登录路径在 §7.1 里根本没跑过**——
> 2026-09-21 的登录 403 就藏在这个缺口里（见 §9）。
>
> 所以 **§7.1 通过 ≠ 生产能登录**。反代模式必须跑 **§7.2**——那不是可选项。

彩排验证清单（docs/008/009 的功能都在这里验）：
- [ ] `rehearsal-data/nginx/conf/seafile.nginx.conf` 是**模板渲染产物**且含 `X-Forwarded-Proto`
- [ ] `curl -sI http://<域名>/` → 301；`curl -skI https://<域名>/` → 200
- [ ] 管理员是 `INIT_SEAFILE_ADMIN_EMAIL` 指定的账号（查 `ccnet_db.EmailUser`），不是 me@example.com
- [ ] 钉钉回调域名临时改成彩排域名 → 扫码登录成功
- [ ] 0008：非管理员密码登录被拒（中文提示）、管理员可登；`/api2/auth-token/` 非管理员 400
      （web 表单 POST 字段名是 `login` 不是 `username`；https 下 Django CSRF 还要求带 Referer 头）
- [ ] `docker exec seafile /usr/local/bin/seafile-backup.sh` 手动跑一次 → `/shared/backup/` 出现两件套
- [ ] 用该备份按 docs/009 恢复到第三个目录，能登录（含重建 seafile@% 用户）→ 删除彩排环境

**收尾**（必做）：
```bash
docker compose -f seafile-prod.yml -f rehearsal-db-override.yml --env-file .env.rehearsal down -v
rm -rf rehearsal-data rehearsal2-* .env.rehearsal .env.rehearsal-restore
# 若往 /etc/hosts 加过域名，务必移除（残留会导致生产切换期本机解析冲突）
# 恢复 dev 栈：docker compose up -d（dev 与彩排容器同名，彩排 down 后才能起 dev）
# 钉钉回调域名：直接切成生产域名（上线时）
```

### 7.2 模式 B：反代模式（上线前必跑）

```bash
cd deploy && ./rehearsal-rp.sh
```

一条命令，全自动，跑完自己清理现场。它做的事：从 **Release 固定 URL** 取三个安装文件
（与真服务器同一条路）→ `init-prod-env.sh` 生成 `.env` → 拉通道 tag 的 amd64 镜像 →
`up -d` 起全栈 → 一个本地 nginx 容器扮演云代理（终止 TLS + 明文转发 + `X-Forwarded-Proto`）
→ 真表单登录 → 文件上传下载 → 升级/回滚机制断言。任何一步不满足预期立刻红。

**与 dev 栈完全隔离**：三个容器全部改名、端口走 18080/18443、数据卷在 `deploy/rehearsal-rp/`
（gitignore 已覆盖）。dev 栈全程不动。

断言的完整清单以 **`rehearsal-rp.sh` 为唯一事实来源**（文档里不复制全文——同一套断言存
两份的教训见 §10）。其中最有诊断价值的是三条对照探针，它们直连容器 80、其余输入完全
相同、唯一变量是转发头：

| 探针 | 输入 | 期望 | 证明了什么 |
|---|---|---|---|
| P1 | `X-Forwarded-Proto: https` | 302 | 域名入口链路健康（`SECURE_PROXY_SSL_HEADER` 生效） |
| P2 | `X-Forwarded-Proto: http` | 302 | **域名入口免疫乱发转发头**：Host=域名时恒判 https |
| P3 | 不发该头 | 302 | 域名入口同样免疫缺头（代理不配转发头也不 403） |
| P4 | 不发头 + **IP 直连**（Host/Origin 全是 `http://<IP>`） | 302 | **原版行为**：按明文 http 如实处理，**不配域名也能登录**（2026-09-22 生产需求：二开不能比原版镜像少） |

> 历史注：09-21 首起 403 是「根本没设 `SECURE_PROXY_SSL_HEADER`」；09-22 生产又撞
> 403，一度诊为「代理乱发头」并改成「恒判 https」——随后日志证据表明用户实际在
> **IP 直连**，那一版反而掐死了原版的直连能力。最终规则是按访问入口分流（§9），
> P1–P4 把两类行为都钉住。

开发机注意两点（脚本失败时会把这两条也打出来）：
- 取 Release 资产需要 `HTTPS_PROXY=…`（开发机直连 `github.com` 超时，§2）；**服务器上不需要**。
- 代理变量会劫持后面所有指向 127.0.0.1 的探针——脚本内部已统一 `--noproxy '*'`，不用管。

**它覆盖不到什么**（如实列在这里，跑通了也别当成「生产万事大吉」）：

| 覆盖不到 | 为什么 |
|---|---|
| 你的云代理配置（请求体上限 / 超时 / WebSocket / 证书链） | 本机用的是 nginx 替身，厂商行为各异 |
| 公网 DNS 与真实证书 | `seafile.localhost` + 自签，浏览器会告警 |
| `github.com` 在服务器上的可达性 | 本机走代理验的；服务器按 §2 那条命令自验 |
| amd64 真硬件 | Rosetta 翻译能照出逻辑错误，不能替代一次真机冒烟 |

**上线后的收尾动作**（不属于彩排，属于 §5）：用真域名 + 真浏览器走一遍表单登录。

## 8. 环境变量对照（compose）

| 变量 | 说明 |
|---|---|
| `SEAFILE_DOMAIN` | 纯域名。证书文件名 + nginx server_name + SERVICE_URL 三处引用 |
| `SEAFILE_PRO_IMAGE` | **正常永远不设**。默认值（通道 tag `…:latest`）在入库的 `seafile-prod.yml` 里，见 §6。只在回滚时**命令行内联**成某个不可变 tag；一旦写进 `.env` 没注释掉，这台机器就永久钉死、不再跟随发布 |
| `SEAFILE_SERVER_LETSENCRYPT=true` | **唯一** https 开关（小写；`SEAFILE_SERVER_PROTOCOL` 只影响 SERVICE_URL） |
| `INIT_SEAFILE_ADMIN_EMAIL/PASSWORD` | 首启建管理员。**镜像不认 `SEAFILE_ADMIN_*`**（dev 环境踩过的坑：静默建成 me@example.com） |
| `DB_ROOT_PASSWD` | 首启初始化库 + 容器内 backup.sh 都用它 |
| `JWT_PRIVATE_KEY` | Seafile 12 内部服务认证（openssl rand -base64 48） |

## 9. 反代模式：TLS 在上游终止（本项目生产实际形态）

### 9.0 全链路分叉图（动协议/配置/链路层的修复，先核这张表再动手）

2026-09-21~23 的四轮 403 复盘结论：四轮不是四个 bug，是**一张没画的图**。每层的修复
各自都对，但没人先把完整路径与配置生命周期铺开——铺开的话，下表 nginx conf 那行的
空格（首启渲染后无人再管）第一天就可见。

**请求全链路（每一层都可能让 scheme/Host 分叉）：**

```
浏览器
 └─(https,域名)→ 云代理：终止 TLS → 明文 http → 本机:80      ← Host、XFP 在这里成形
     └─→ 容器 nginx :80（conf 是【数据卷】里的首启渲染件，sync_nginx_conf 保证随模板刷新）
          ├─ /media    → 静态文件直发
          ├─ /seafhttp → fileserver :8082（上传下载；绝对链接来自 SERVICE_URL）
          └─ 其余      → gunicorn :8000 → Django
               ├─ 协议判定：SECURE_PROXY_SSL_HEADER + XFP（Host=域名→恒 https；其它→原版行为）
               ├─ CSRF 信任源 = 协议 × get_host()（Host 头）
               └─ 绝对链接 = SERVICE_URL（constance/数据库，后台改、免重启）
```

**配置生命周期（谁写、何时写、升级镜像后会不会自己跟上）：**

| 配置 | 首启谁写 | 之后谁改 | 升级镜像后 |
|---|---|---|---|
| `.env` | init-prod-env.sh | 人（域名可只在后台改） | 不变（设计如此） |
| `seahub_settings.py` | setup 无条件重写 | custom_bootstrap **每次启动逐项补** | ✅ 自动 |
| `seafdav.conf` | setup | custom_bootstrap 每次启动 | ✅ 自动 |
| `nginx conf` | 首启渲染进数据卷 | **曾长期：无人（403 第三形态病根）** | ✅ sync_nginx_conf（2026-09-23 补） |
| constance（SERVICE_URL/钉钉） | 首启默认值 | 管理后台，免重启 | 不受影响 |

**访问方式矩阵（每行必须有断言，或显式标注未覆盖）：**

| 入口 | 用途 | 断言 |
|---|---|---|
| 域名经代理 https | 生产主路径 | 彩排登录 302、P1–P3 |
| IP 直连 http | 内网/调试（原版能力） | 彩排 P4 |
| WebDAV /seafdav | 文件协议 | smoke（enabled=true） |
| 域名经宿主反代（宝塔等面板）https | 生产主路径（m-disc 形态） | 容器侧与云反代**同字节**（明文 http + Host 头 + host 分流兜底），P1–P4 覆盖；面板改写 Host 的坑见 §9.1 与 §10 第四形态 |
| 桌面客户端 SSO / 钉钉回调 | 外部入口 | 钉钉 redirect_uri 跟随发起域名：彩排 9b（D1/D2 双 Host）；真机扫码全流程仍待生产复验（§7.2 边界表）。桌面客户端 SSO 未覆盖 |


生产不是「容器自己签 LE 证书」，而是：**docker 跑在本地，公网服务由云上的反向代理提供**。
代理持有证书并终止 TLS，用明文 http 转发到本机的 80 端口。

```
浏览器 ──https──→ 云反向代理（证书在这，TLS 终止）
                      └──http──→ 本地 docker 的 nginx:80 ──→ seahub:8000
```

### 配置（`.env`）

```bash
SEAFILE_DOMAIN='<用户在浏览器里输入的域名>'   # 不是容器地址
SEAFILE_SERVER_LETSENCRYPT='false'            # 不签 LE 证书 → 容器只监听 80
SEAFILE_SERVER_PROTOCOL='https'               # ⚠️ 必须显式设，见下
```

### ⚠️ 两个变量为什么要分开设

`bootstrap.py` 与 `setup-seafile-mysql.py` 里各有一份 `get_proto()`，逻辑一致：

```python
proto = 'https' if is_https() else 'http'          # is_https() 只认 LETSENCRYPT
if os.environ.get('SEAFILE_SERVER_PROTOCOL') == 'https':
    proto = 'https'                                 # 这一条独立生效
```

- `LETSENCRYPT` 决定 **nginx 监听什么**（443+证书，还是只有 80）
- `PROTOCOL` 决定 **生成的链接是什么协议**（`SERVICE_URL` / `FILE_SERVER_ROOT`）

反代模式下前者必须 false、后者必须 https。**漏设 `PROTOCOL` 的症状很隐蔽**：页面能正常
打开（因为浏览器确实在 https 上），但 `SERVICE_URL` 会写成 `http://域名`，于是文件上传
下载、分享链接、钉钉回调地址全部指向 http —— 在只放行 https 的代理后面就是坏的。

### X-Forwarded-Proto 与 `SECURE_PROXY_SSL_HEADER` —— **两半都要有**

这一条本文件曾经写错过，代价是生产登录直接 403，所以完整记一遍。

容器 nginx 只监听 80 时 `$scheme` 恒为 `http`。要让 Django 知道「浏览器那一侧其实是
https」，需要**两个条件同时成立**：

| # | 在哪 | 做什么 | 少了它会怎样 |
|---|---|---|---|
| 1 | 容器 nginx（模板） | 把真实协议放进 `X-Forwarded-Proto` 传下去 | Django 无从得知 |
| 2 | Django（`seahub_settings.py`） | 设 `SECURE_PROXY_SSL_HEADER`，**它才会去读那个头** | **登录 403** |

第 1 条：模板在 server 块顶部定义一次 `$seafile_fwd_proto`

- `https=true` → `$scheme`（容器内终止，就是真实协议）
- `https=false` → **按访问入口分流**（2026-09-22 定稿）：
  - `Host` 是配置的域名（`$server_name`，来自 `SEAFILE_DOMAIN`）→ 恒为 `https`。
    浏览器侧协议由部署形态决定，不看上游转发头——代理可能把它「自己到后端这段」
    的协议写进头（`http`、或多级拼出的逗号串），而 Django 要求头值与配置**逐字
    相等**，任何偏差都回到 403。
  - 其它 `Host`（**IP 直连**、内部名字）→ **原版行为**：有转发头按转发头，没有按
    `$scheme`（明文 http）。Django 如实按 http 处理，http Origin 对得上——**不配
    域名也能登录访问**（绝对链接仍按 `SERVICE_URL` 生成）。上游原版镜像 IP 直连
    能用，二开不能比原版少。
  - 边界：改域名要同步 `.env` 的 `SEAFILE_DOMAIN`（`server_name` 首启渲染一次，
    §4.2.1）；代理改写 Host 不保留域名，属于代理侧配置问题（本表「转发头」行；
    真实案例：宝塔面板把 Host 写死成 IP → 全 POST 403，见 §9.1 与 §10 第四形态）。

第 2 条由镜像内的 `custom_bootstrap.py` 写入（§4.2.2）。上游从没设过它——`settings.py`、
`bootstrap.py`、`setup-seafile-mysql.py` 逐个查过，全镜像只有 Django 自己的默认值 `None`。

> **⚠️ 只做第 1 条是不够的。** 本文件早先写过「透传 `X-Forwarded-Proto` 就能让
> `request.is_secure()` 为真」——**这句推论是错的**。Django 只在
> `SECURE_PROXY_SSL_HEADER` 非 `None` 时才去看那个头（`django/http/request.py:255`）。
> 少了第 2 条，`request.is_secure()` 恒为假，CSRF 中间件于是把 `good_origin` 算成
> `http://域名`（`django/middleware/csrf.py` 的 `_origin_verified`），与浏览器发的
> `Origin: https://域名` 不匹配 → **表单一提交就 403，而页面照常打开**。
> 2026-09-21 生产实测撞到；`12.0.14-dingtalk.9.1464e1b4` 起修复。

> **为什么彩排没拦住它。** §7 的彩排为了让自签证书生效，**故意把
> `SEAFILE_SERVER_LETSENCRYPT` 设回 `true`**（容器自己终止 TLS）。那个模式下
> `$scheme` 就是 https，`is_secure()` 天然为真——**反代模式（`https=false`）的登录
> 路径从来没被跑过**。这是彩排与生产之间唯一没被覆盖的差异，而 bug 恰好藏在那里。
> 教训：彩排的「唯一差异」如果不止证书一项，那份清单就得写全。
> **缺口已补**：§7.2 的反代彩排就是为它加的，2026-09-21 首跑全绿（含 P2 探针
> 精确复现这个 403）；此后改 nginx 模板或 Django 配置，跑 §7.2 即可覆盖这条路径。

`deploy/smoke-test.sh` 两侧都守：第 5 项把两种模式各渲染一遍跑 `nginx -t`（拦第 1 条
写坏），第 6 项断言 `SECURE_PROXY_SSL_HEADER` 确实写进了配置、且**老部署升级时会补齐**
（拦第 2 条丢失）。

### 代理侧必须注意

| 项 | 说明 |
|---|---|
| **请求体大小上限** | 容器 `location /` 已设 `client_max_body_size 0`（不限），但**代理默认通常是 1m** —— 不改的话大文件上传会 413 |
| **转发头** | 建议设 `X-Forwarded-Proto $scheme`、`X-Forwarded-For`、`Host`。不设也能工作（容器会假定 https），但设了更准确 |
| **超时** | 大文件上传/下载走 `/seafhttp`，容器侧给了 36000s，代理侧的 `proxy_read_timeout` 要跟上 |
| **WebSocket** | `/notification` 需要 `Upgrade`/`Connection` 透传，否则通知不实时（功能不致命） |
| **不要只转 80** | `/media` 是容器 nginx 直接从磁盘发的，`/seafhttp` 走 8082，都由容器 nginx 内部分流。代理只要把**整个域名**转给容器 80 即可，不用按路径拆 |

### 9.1 宿主机反代（宝塔面板等）：80/443 归宿主 nginx 时

TLS 不在云上、就在跑 docker 的这台机器上终止的形态（2026-09-23 生产实例：
`https://m-disc.moresec.cn`，宝塔面板管的宿主 nginx）：

```
浏览器 ──https://域名──→ 宿主 nginx:443（宝塔管，证书在这，TLS 终止）
                           │ proxy_pass http://127.0.0.1:8080（明文）
浏览器 ──http://IP────→ 宿主 nginx:80（可选：IP 透传，或 301 到 https）
                           ▼
                    seafile 容器 :80（.env 里 SEAFILE_HTTP_LISTEN='127.0.0.1:8080'，
                                     容器端口只绑本机回环，外部流量必经反代）
```

**`.env` 三要素：**

```bash
SEAFILE_DOMAIN='m-disc.moresec.cn'            # 真域名——host 分流兜底规则上膛，
                                              # 以后代理头再被写歪也不会 403（§9 XFP 节）
SEAFILE_HTTP_LISTEN='127.0.0.1:8080'          # 把容器挪出 80，只绑回环
# SEAFILE_SERVER_LETSENCRYPT='false' 与 SEAFILE_SERVER_PROTOCOL='https' 保持不动
```

改完 `docker-compose pull && docker-compose up -d`：容器 conf 由 `sync_nginx_conf`
自动重渲染（指纹含域名），**不用碰数据卷里的任何文件**。

**⚠️ 宝塔面板的坑（2026-09-23 生产实证，§10 第四形态）：** 宝塔「反向代理」默认生成

```nginx
proxy_set_header Host 192.168.11.141;    # ← Host 被写死成 IP
```

后果：容器看到的 Host 永远是 IP，Django 算出的合法来源是 `https://<IP>`，而浏览器
`Origin` 是 `https://<域名>`——**所有 POST 一律 403（网页登录、客户端 SSO 同死），
GET 却全通**，极具迷惑性。修法：面板 → 网站 → 该域名 → **配置文件**，把这行改成
`proxy_set_header Host $host;` 保存（面板会自动 `nginx -t` + reload）。其余
`X-Forwarded-Proto $scheme` 等行宝塔默认就是对的，别动。
**注意**：之后在面板「反向代理」设置页重新保存，会把这行覆盖回 IP——要再改一次。

服务器侧完整步骤（装过宝塔、证书已挂到网站的前提下）：

```bash
# 1) 宝塔面板：网站 → <域名> → 设置 → 配置文件
#    proxy_set_header Host <IP>;  →  proxy_set_header Host $host;
# 2) 对齐仓库与 .env
cd /opt/seafile-custom/deploy && git pull
sed -i "s/^SEAFILE_DOMAIN=.*/SEAFILE_DOMAIN='<你的域名>'/" .env
grep -q '^SEAFILE_HTTP_LISTEN=' .env || echo "SEAFILE_HTTP_LISTEN='127.0.0.1:8080'" >> .env
docker-compose pull && docker-compose up -d
docker exec seafile grep server_name /shared/nginx/conf/seafile.nginx.conf   # 期望：你的域名
```

（`git pull` 若撞上手改过的 compose：`git checkout -- deploy/seafile-prod.yml` 后重新
pull——端口已由 `SEAFILE_HTTP_LISTEN` 接管，手工映射不再需要。）

**钉钉收尾**（域名 + https 就位后）：Seafile 后台 → 系统设置 → Site URL 改为
`https://<域名>`；钉钉开发者后台 → 登录与分享 → 回调域名填
`https://<域名>/dingtalk/callback/`；扫码一律从 `https://<域名>` 登录页发起
（state 绑会话 cookie，跨地址必掉 `invalid state`）。钉钉回调域名接受 IP 与内网
域名——匹配是纯字符串比对，回跳由浏览器发起，不要求钉钉服务器能访问该地址。

### 9.2 多入口：内网 + 外网双域名同时扫码登录（2026-09-24，0010 补丁）

同一系统两个入口（生产实例：内网 `m-disc.moresec.cn` 走宿主反代直入；外网
`i-disc.moresec.cn` 走云服务器反代 → 公司出口 IP 端口映射回系统）：

```
内网用户 ──https──→ 宿主 nginx（宝塔，§9.1）──────────┐
                                                       ├─→ 容器 :80
外网用户 ──https──→ 云反代（TLS 终止）──http──→ 出口IP:端口 ┘
```

**钉钉扫码登录在两个入口都可用**，因为回调地址跟随发起域名（`redirect_uri` 由
`request.scheme + request.get_host()` 构造，不再是 SERVICE_URL 单值）——state 所在
的会话 cookie 按 host 隔离，回发起域才读得到。需要做的只有两件事：

1. 钉钉后台「登录与分享 → 回调域名」把**两个入口都登记**（多个回调域名用英文
   逗号分隔，钉钉官方支持）：

   ```
   https://m-disc.moresec.cn/dingtalk/callback/,https://i-disc.moresec.cn/dingtalk/callback/
   ```

2. 外网链路的 `X-Forwarded-Proto: https` 要一路传到容器（云代理设置；沿途中间层
   不得用 `$scheme` 覆盖——云→公司那段是明文 http，覆盖会把 https 冲掉，
   redirect_uri 变 http 与登记不符，钉钉在授权页直接拒绝）。验证：

   ```bash
   curl -s -o /dev/null -w '%{redirect_url}\n' https://i-disc.moresec.cn/dingtalk/login/
   ```

Site URL（SERVICE_URL）保持主域名不动——管邮件/分享链接的规范地址，不影响扫码
登录。**已知边界**：网页里的文件上传/下载绝对链接（FILE_SERVER_ROOT）仍从
SERVICE_URL 派生（单值），外网入口会拿到指向主域名的链接；外网若解析不了主域名，
文件操作受影响（可改相对形式 `/seafhttp`，另行验证后成文）。彩排 9b（D1/D2 双
Host 探针）已把「回调跟随发起域名」钉成断言。

## 10. 验证记录

**本地彩排（2026-09-20，arm64，镜像 12.0.14-dingtalk.8）——全链路通过：**

| 项 | 实测 |
|---|---|
| 首启链路（LE 跳过 → setup → seahub） | ✅ "Skip letsencrypt verification"；登录页 200 |
| 首启耗时 | seafile 容器 ~2.5 分钟到登录页 200（当时用的是手工 db-first 顺序；现已由 compose 依赖条件取代） |
| nginx conf | ✅ 模板渲染产物，X-Forwarded-Proto ×2，server_name 正确 |
| http→https | ✅ 301 → https |
| 管理员 | ✅ `INIT_SEAFILE_ADMIN_EMAIL` 账号（is_staff=1），非 me@example.com |
| init-conf --prod | ✅ seafdav enabled + 定制块幂等追加（ENV_FILE=.env.rehearsal） |
| 0008 双层拦截 | ✅ web 非管理员中文提示 / 管理员 302；api2 非管理员 400 + seahub.log 有 "Blocked password login" |
| backup.sh | ✅ 44K 两件套（详见 docs/009 §5） |
| 恢复演练 | ✅ 第三目录完整恢复可登录（踩坑：需重建 seafile@% 用户，已写入 docs/009） |
| 钉钉扫码 | 留生产切换时验（需临时改真实回调域名；dev 已验同代码路径） |

**部署脚本（2026-09-20）**：

| 项 | 实测 |
|---|---|
| `init-prod-env.sh` 零提问 | ✅ 无参数直接跑通，密钥全自动生成；自检「反代两开关未被改动」通过 |
| 域名改到管理后台 | 见 [docs/011](011-service-url-admin-config.md) §6 的完整验证矩阵（含跨进程即时生效与 HTTP 端到端） |
| 脚本报错路径 | ✅ 容器不存在 / 容器没在跑 / 环境文件缺失，三种都给明确提示而非堆栈 |
| compose 双形态支持（2026-09-21：老 docker 报 `unknown shorthand flag: 'f' in -f` 一度被误判成文件损坏；生产服务器实为老 docker + `docker-compose` v1，**且就这么跑起来了**） | ✅ `init-prod-env.sh` 探测入口：v2 插件 → `docker-compose` ≥1.27（awk 校验版本）→ 皆无才 die（两种装法都给）；末尾自检与「下一步」按探测结果打印。三路径实测：本机 v2 全通；垫片模拟用户服务器（真实 1.29.2 二进制）全通、打印 `docker-compose …`；皆无 → die 报错可照抄。v1 对 `seafile-prod.yml` 解析 **exit 0**、`service_healthy` 条件保留、三镜像全部解析 |

**安装步骤精简（2026-09-21）——把「装的人该做的」和「脚本该做的」分开：**

用户反馈「安装分了那么多步」。复核后其中两步确实是我的问题，不是 Seafile 的固有复杂度：

| 项 | 实测 |
|---|---|
| MariaDB healthcheck 真的可用 | ✅ 干净卷上 `healthcheck.sh --connect --innodb_initialized`：`starting → healthy` 用时 9s（正确等过了两阶段初始化，没有把第一阶段的临时服务器误判成就绪） |
| 两个 healthcheck 参数缺一不可 | ✅ `--connect` 单独用会在初始化期间就返回成功；必须配 `--innodb_initialized` |
| `docker compose up -d` 一条命令 | ✅ 由 `condition: service_healthy` 保证顺序；**「先起 db、等 30s、再起 seafile」那段人工步骤删除** |
| `init-conf.sh --prod` 一条命令 | ✅（**该步骤已于 2026-09-21 整个删除**，见下条）空跑/写入/幂等三种路径都验过：等待逻辑、写入结果、`ast.parse` 确认追加后仍是合法 python、容器内 `seafile.sh`+`seahub.sh` restart 及重启后自检（实测重启后 gunicorn 与 nginx 均恢复 302） |
| 二开定制改为镜像内自动追加（`--prod` 删除） | ✅ `custom_bootstrap.py` 的五条路径全验：写入、幂等（第二遍不重复追加）、已存旧标记时不追加第二块、钉钉凭据走环境变量、`seahub_settings.py` 缺失时明确报错退出 |
| `smoke-test.sh` 覆盖该钩子 | ✅ 第 6 项：断言接线顺序（`init_custom_settings()` 必须紧跟 `init_seafile_server()`）+ **在假配置目录上真跑一遍**验写入与幂等。**这不是可选项**——打补丁那一步一旦失效，必须是构建失败 |
| 上游脚本补丁改用 `patch-upstream.py`（2026-09-21） | ✅ 三处改动在基础镜像上实测全部命中：`start.py` 的 import 与调用点各 1 处、seahub 启动调用 root/non-root 各 1 处、`enterpoint.sh` 2 处。断言按「恰好 N 处」校验，**改前失配会直接让构建失败**（此前 `sed` 是静默成功）。已弃用 `sed` 路线，那条「BSD sed 会假失败」的注意事项随之作废 |
| 保活补丁真的会让容器退出 | ✅ 行为实测（不只是 grep）：假 `start.py` 起来 2 秒后自杀 → `enterpoint.sh` 在下个检查点打印 `start.py exited unexpectedly...` 并 `exit 1`。**注意测法**：裸 `--entrypoint bash` 里没有 nginx，会先卡死在第 13–22 行的等 nginx 循环（表现为 `timeout` 杀掉、退出码 124，看着像补丁没生效），必须用一个假的 `ps` 让该循环放行 |
| 重试真的会被触发 | ✅ `utils.call()` 默认 `subprocess.check_call`（`utils.py:53`），失败抛 `CalledProcessError`，`start_service_retry` 捕获后重试。前提成立，重试不是装饰性的 |
| 第 6 项断言仍成立（补丁改动后重跑） | ✅ 在基础镜像上打完补丁、拷入 `custom_bootstrap.py`，抽出 `smoke-test.sh` 第 6 节单独跑（断言仍只有这一份来源，不是复制件）→ 全绿 |

**反代模式登录 403 的修复（2026-09-21，tag `12.0.14-dingtalk.9.1464e1b4`）——已验证的部分：**

| 项 | 实测 |
|---|---|
| 根因定位（读源码，非推断） | ✅ Django 4.2.21；`SECURE_PROXY_SSL_HEADER` 在 `settings.py`/`bootstrap.py`/`setup-seafile-mysql.py` 三处**都没设**，全镜像只有 `global_settings.py` 的默认值 `None`；`request.py:255` 证明只在它非 `None` 时才读 `X-Forwarded-Proto`；`csrf.py` 的 `_origin_verified` 证明 `is_secure()` 为假时 `good_origin` 取 `http://` |
| 彩排为何漏掉 | ✅ §7 明确要求彩排把 `SEAFILE_SERVER_LETSENCRYPT` **设回 `true`**（容器自己终止 TLS），`$scheme`=https → `is_secure()` 天然为真。**反代模式的登录路径从未被跑过** |
| `custom_bootstrap.py` 四条路径 | ✅ 全新文件（补 4 项）、二次运行（文件逐字节不变）、**老部署只缺新项（只补 1 行、不追加第二块）**、钉钉凭据经环境变量。三种产物都 `exec` 过——**是合法 Python**，配置写坏会让 seahub 整个起不来 |
| 冒烟断言有牙齿 | ✅ 把逻辑退回整块级（模拟旧实现）后跑第 6 节 → **报错退出 1**，信息是「SECURE_PROXY_SSL_HEADER 没被补上」。断言不是装饰性的 |
| 第 6 节在 `sh`（dash）下可跑 | ✅ CI 用镜像的 `/smoke.sh`（shebang `#!/bin/sh`）执行，本机用 `sh` 复现 → 全绿。新增的 heredoc 语法 POSIX 兼容 |

**端到端（§7.2 反代彩排，2026-09-21，发布镜像 `12.0.14-dingtalk.9.ed2042da` = `latest`，
digest `sha256:57a953eb…`，amd64、Rosetta 模拟；31 条断言全绿，命令即 `./rehearsal-rp.sh`，
可随时重跑复现）**：

| 项 | 实测 |
|---|---|
| Release 固定 URL 取三资产 → `init-prod-env.sh` → 通道 tag `pull` → `up -d` | ✅ 全链一条路跑通；db healthcheck 自动排序；二开定制自动落地 |
| 真表单登录（CSRF → POST） | ✅ **302 → `/`，非 403**；`sessionid` 会话有效（`/api2/account/info/` 返回管理员本人） |
| `SERVICE_URL` / `FILE_SERVER_ROOT` 协议 | ✅ 生成链接均为 `https://<域名>`（页面能开、上传下载坏的静默症状排除） |
| 文件上传 + 下载 | ✅ 全新实例先建「我的资料库」（惰性创建），上传返回文件 id、下载内容与上传**逐字节一致** |
| P1/P2/P3 对照探针 | ✅ 302 / **403**（精确复现事故）/ 302——`SECURE_PROXY_SSL_HEADER` 真的生效、且由转发头驱动 |
| 升级无操作 / 回滚内联覆盖 | ✅ 通道未动时 `pull && up -d` 镜像不变；内联 `SEAFILE_PRO_IMAGE` 能覆盖通道默认值 |

> 上面那条「尚未验证：浏览器登录真的通了」的警告**已被本表取代**（2026-09-21 §7.2 首跑
> 全绿后）。curl 覆盖的是 CSRF + 表单提交 + 会话这条**代码路径**，与浏览器点击等价；
> 仍留给生产复验的只有：真域名、真证书、云代理行为（§7.2 的覆盖边界表）。

**协议判定定稿：按访问入口分流（2026-09-22，tag `12.0.14-dingtalk.9.52946cde` = `latest`，
digest `sha256:3fb8de1a…`）**。当天完整弧线（三版，前两版各错一半）：

| 版本 | 规则 | 错在哪 |
|---|---|---|
| 09-21 修复 | 采信上游 X-Forwarded-Proto，缺失兜底 https | 生产日志实证用户在 **IP 直连**：直连无头 → 兜底 https → Django 按 `https://<IP>` 算信任源，对不上浏览器的 `http://<IP>` Origin → 403。原版镜像没这问题——它不设 `SECURE_PROXY_SSL_HEADER`，按连接如实判 http，**IP 直连本来就能用** |
| 09-22 中午「恒判 https」 | 反代模式一律 https | 掐死 IP 直连（用户：「不配域名就不让访问了吗」）。且它防的「代理写坏头」形态**从未被日志证实**——推测错误，根因一直是直连 |
| **09-22 晚（现行）** | **Host=域名 → 恒 https；其它 Host → 原版行为（有头按头、无头按 $scheme）** | —— |

彩排实测（**35 断言全绿**，amd64/Rosetta，发布字节）：登录 302、上传下载逐字节一致、
P1/P2/P3（域名入口：带头 https / 带头 http / 无头）全 302，**P4（IP 直连无头）→ 302**
——「不配域名也能登录」从此是钉死的断言，不是口头承诺。彩排端口同日改为可覆盖
（`SEAFILE_RP_HTTP_PORT` / `SEAFILE_RP_TLS_PORT`）：宿主口被本机其它服务占用时
（2026-09-22 实撞：`/tmp/fake_openai.py` 占了 18080），换口即跑、不杀别人的进程。

**403 第三形态：数据卷 conf 滞留不随镜像更新（2026-09-23 修，远程探针定位）**

| 项 | 实测 |
|---|---|
| 定位证据（从开发机直探生产 `http://192.168.11.141`，用真实凭据发登录表单） | ✅ 三探针：`XFP: http` → **302**（**凭据有效、登录成功**）、无头 → 403、`XFP: https` → 403。这是旧规则（透传 + 缺失兜底 https）的精确指纹——与新镜像行为完全不符，证明容器里跑的是**首启时的旧 conf** |
| 根因 | ✅ nginx conf 是首启渲染进数据卷的一次性产物，上游 `generate_local_nginx_conf()` 只在文件缺失时渲染。用户机首启于 09-22 中午（ed2042da 时代），此后拉的三版新镜像都不触碰旧 conf。**彩排每次都是全新数据卷，结构上测不到「已有卷 + 模板更新」**——盲区 |
| 修复：`custom_bootstrap.sync_nginx_conf()`，start.py 在渲染**之前**调用 | ✅ sidecar 指纹快路径 + 逐字节比对（借道上游同一 `render_template`）；旧滞留件自动挪 `.bak-*` 重渲染。dev 容器内真跑四条路径（陈旧→挪走、一致→保留、快路径零动作、缺模板不崩）；固化进 smoke 第 6 项；彩排新增步骤 10b（手工制造滞留 → restart → 自动重渲染断言） |
| 用户机解锁 | ✅ `pull && up -d` + 挪走旧 conf + `restart seafile`；带 sync 的新镜像落地后，同类升级纯 `pull && up -d` 即自动完成 |
| 端到端验证（tag `8976cc65` = `latest`，digest `a302a2db…`） | ✅ 彩排 **38 断言全绿**，含新增 10b：手工把旧规则 conf 写进数据卷 → `restart seafile` → sync 自动挪 `.bak` 并用当前模板重渲染、登录页 200。CI 侧同日堵住管线洞：**publish 模式此前跳过冒烟**——「tag 已存在」只证明推过不证明验证过（8976cc65 首次构建就冒烟红、重跑本会无验证发布）；现除 `none` 外所有模式都对 tag 冒烟 |

> 顺带查出一个**潜伏 bug**：`init-conf.sh`、`init-prod-env.sh`、`smoke-test.sh` 里共 5 处
> `$VAR` 后面直接跟中文标点（如 `$ENV_FILE，`）。bash 会把多字节字符并进变量名，
> 于是 `set -u` 下报 `ENV_FILE?: unbound variable` —— 而且**全都在错误提示分支里**，
> 平时不执行，一旦触发就是「报错时报不出错」。已全部改为 `${VAR}`。
> （复现：`bash -c 'set -u; V=abc; echo "x/$V，y"'`）

**403 第四形态：宿主反代改写 Host（宝塔面板）（2026-09-23 定位，与镜像无关）**

| 项 | 实测 |
|---|---|
| 症状 | 客户端单点登录 + 网页登录 POST 一律 403，GET 全通（登录页、静态资源正常）——「页面能开、表单全死」组合与第三形态不同源 |
| 定位手法（开发机远程探针，零登录服务器） | ✅ 443 有效证书 `*.moresec.cn`；容器被挪到 `8080`；任意 Host 的 GET 都 200（反代是 catch-all）；完整 CSRF 流程（cookie+token 配对）POST **18 组 Origin/Referer 组合全 403**；同流程容器直连 `IP:8080` → **200**。结论：容器健康，反代把容器看到的 Host 改成了一个猜不到/对不上的值 |
| 根因（配置现行） | ✅ 宝塔面板「反向代理」默认配方 `proxy_set_header Host 192.168.11.141;`（写死成 IP；`X-Forwarded-Proto $scheme` 是对的）。Django secure 下 `good_origin=https://192.168.11.141` ≠ 浏览器 `https://m-disc.moresec.cn` → 全 POST 403 |
| 容器 conf 侧因 | `.env` 的 `SEAFILE_DOMAIN` 仍是占位 `seafile.local`，host 分流兜底规则对真域名不生效（命中条件是 `Host == server_name`，§9） |
| 修复 | ① 宝塔配置文件把 Host 改回 `$host`（用户侧，一行）；② `.env` 设真域名 + `up -d`（sync 自动重渲染 conf，兜底上膛）。两条独立成立，合做是双保险 |
| 结构性收尾 | ✅ compose ports 改为 `${SEAFILE_HTTP_LISTEN:-80}:80`——把用户手工改的 `8080:80`（和顺手加的 `8443:443` 摆设映射）吸收成正式配置，消除 git pull 冲突与「手改文件失飘」类别；`env.prod.example` 与 §9.1 成文 |
| 端到端复验 | 待用户执行 §9.1 server 步骤后远程回填（GET 域名 200 / POST 域名 非403 / IP 直连不破） |

> 教训与前三形态同源但各补一块：这次容器、镜像、模板全部无辜，**环境组件（宝塔）的
> 默认配方**是根因。「迎合环境」原则的具体化——宝塔用户一定会撞上这行，所以把它写成
> §9.1 的醒目警告，而不是等下一个用户再踩。定位上再次验证：远程探针（Origin/Referer
> 反推容器视角）在不碰服务器的情况下把嫌疑从 18 维空间收敛到「Host 被改写」一件事上。

**sync_nginx_conf 的秒级时间戳抖动（2026-09-24，CI 冒烟拦截，先于通道搬移）**

| 项 | 实测 |
|---|---|
| 症状 | 0010 补丁推送后 CI 冒烟红：「一致的 conf 被误挪」——同一份测试本地绿、CI 红 |
| 定位 | 本地拉同一 tag 镜像原样重放：通过。差异只有时间——CI 日志里两次 .bak 名跨秒（`…035508`→`…035509`）。读镜像内 `/scripts/utils.py` 现行：`_add_default_context` 注入 `current_timestr = datetime.now()`（秒级），模板第 2 行就是 `# Auto generated at {{ current_timestr }}`。两次渲染跨秒 → 一字节之差 → 逐字节比对误判滞留。本地同秒渲染所以永远绿 |
| 影响评估 | 不只是测试抖动：生产上「conf 已是当前模板渲染、但 sidecar 缺失」的比对**必跨秒必误挪**（挪走后上游用同模板重渲染，内容等价、多一次重写）——「补记指纹」分支实际永远命不中 |
| 修复 | 比对前把时间戳行归一化（`_normalize_rendered`：`# Auto generated at …` → 占位符）。比对要回答「规则是不是当前模板的」，不是「是不是同一秒渲染的」 |
| 断言加固 | 冒烟 path2 强制 `sleep 1.1` 跨秒（把 CI 撞红的形态钉成回归测试）；新增 path2b 负控：真差异（换域名）必须仍判滞留——防归一化实现过宽把真漂移也抹平 |
| 端到端 | 四路径在镜像内重放全绿（陈旧→挪走 / 一致+跨秒→保留 / 真差异→挪走 / 缺模板→不崩） |

> 流水线按设计工作：红在冒烟、通道未动、Release 未发。另一个教训：**「本地绿 CI 红」
> 时先怀疑非确定性（时间、随机、顺序），别急着怀疑 CI 环境**——证据（两个 .bak 名的
> 秒数差）就躺在日志里。

> **那一步已经删掉了（2026-09-21）。** 上面那条「还能再少一步」的笔记当时判为「暂缓，
> 等下次有别的理由出镜像时一并带上」——**这个判断是错的**。用户随后直接问「为什么我二开
> 的内容还要单独搞？难道不是应该融合到里面吗？」——对。对交付物而言这就是个缺陷：
> 一个 1.0 版本不该在 `docker compose up -d` 之外还有个人工步骤。
>
> 于是做了：镜像的 `start.py` 在 `init_seafile_server()` 之后挂幂等的
> `custom_bootstrap.py`（见 §4.2.2），`init-conf.sh --prod` 整个删除、只留一个会报错的
> 空壳（防旧镜像用户以为跑过了）。代价是动一个上游脚本——但用户已明确**此后不跟随上游**，
> 这个代价基本消失；断言仍保留，防的是我自己的编辑静默失效。
>
> 教训记在案：**「等下一次有别的理由再一起做」在交付物缺陷面前不成立**——缺陷的代价是
> 用户自己撞上，而不是在某个合适的时机被顺手修掉。

> **（历史记录）曾经有个 `deploy/set-domain.sh`**，用来在首启之后直接改数据卷里的
> `seahub_settings.py` 与 nginx conf——因为当时域名只在首启写一次、之后改环境变量无效。
> 补丁 0009 把 `SERVICE_URL` 挪进 constance 之后，**该脚本已删除**：改域名现在是管理
> 后台点一下的事，留着「绕过正常路径直接改文件」的工具反而有害。
>
> 它踩过的两个坑仍值得记（写任何「改数据卷文件」的脚本都适用）：无差别替换所有
> `server_name` 行会**误伤 `server_name _ default_server;`**（80 端口的默认虚拟主机，
> 症状是别的 Host 头 404，离原因很远）；提取旧域名的字符类要**同时排除单双引号**。
> 两个 bug 都是 fixture 测出来的、不是推演出来的。

**彩排踩坑记录**（都已固化到流程/文件）：
1. MariaDB 竞态 → **已结构性消除**：db 加 healthcheck、seafile 用 `condition: service_healthy`
   等它（§4 失败场景 2）。当时的人工 db-first 顺序已废弃，`up -d` 一条命令即可
2. macOS lctn=2 统计表损坏 → rehearsal-db-override.yml（§7 步骤 2）
3. 恢复缺 MySQL 授权 → docs/009 §3 步骤 3
4. `seahub.sh python-env` 是交互式入口不接收参数，非交互用法：`echo '<code>' | docker exec -i seafile .../seahub.sh python-env`（代码需自带 django.setup() prologue）
5. 登录表单 POST 字段名是 `login`；https 下 CSRF 需要 Referer 头
6. **镜像冒烟断言写错路径**（CI 首跑才暴露）：断言 `frontend/build/static/js`，实际是
   `build/frontend/static/js`，且真正被服务的是 collectstatic 产物 `media/assets/frontend/static/js`。
   根因是同一套断言在 workflow 与本文各存一份 → 已收敛为 `deploy/smoke-test.sh` 单一来源，
   并改为拿 webpack-stats 的 chunk 清单逐个核对落点（只断言 build 目录存在会漏掉
   「collectstatic 没跑」这类白屏故障）

**CI 流水线（2026-09-20，源码树复现链路已在本地逐条验过）**：

| 项 | 实测 |
|---|---|
| 补丁串行 `git am` 复现二开分支 | ✅ 在 `git worktree` 的干净 0877ad7 检出上应用 8 个补丁，`HEAD^{tree}` == `a0fe634…` |
| `build-image.sh --check-tree` 硬校验 | ✅ 通过；人为改动补丁后能正确拒绝 |
| `--print-tag` | ✅ 补丁数与 tag 数字一致（当时格式还是 `12.0.14-dingtalk.8`，现已加哈希段） |
| tag 内容寻址 | ✅ 连续两次相同；改 nginx 模板或补丁内容都会得到新 tag；还原后回到原值 |
| 反代模式 nginx 修复 | ✅ 在 CI 构建并推送的 amd64 镜像上验证：两种模式都渲染且 `nginx -t` 通过，反代模式 `X-Forwarded-Proto` 取值正确 |
| 内容寻址 tag 免 force | ✅ 改动 `build-image.sh` 后自动得到新 tag `…8.4261dd78`，tag 守卫正常放行（此前同类改动每次都要 force）。再次验于 `…8.e9313643`（改 `deploy/image/**`） |
| 运维脚本烘进镜像 | ✅ 本机 arm64 与 CI amd64 两份产物都跑通新增断言：三个文件就位、cron 属性为 `644 root`；且三层指纹与上一版**逐字节相同**，证明这次只增文件、未触碰 seahub 与前端 |
| `git archive` 文件完整性 | ✅ 3812 个文件，含 `frontend/package-lock.json` |
| 取部署 tarball（免代理免凭据） | ✅ `codeload.github.com` 直连 200（public 后实测：裸 curl 拿到 56 个文件） |
| 首次 CI 运行 + 镜像发布 | ✅ 构建 8m27s；tag `12.0.14-dingtalk.8`（当时还没有发布记录，digest 只留在 run summary 里） |
| tag 已存在守卫 | ✅ 被真实触发过一次并正确拦截（在昂贵构建之前） |
| **CI amd64 产物 vs 本地 arm64 产物** | ✅ 三层指纹**完全一致**：overlay `bee2ffbe…`(937)、前端产物 `e1f7eb47…`(269)、media/assets `6dd7b6e9…`(305) —— 连 webpack 产物都跨架构逐字节相同 |
| **服务器直连 ghcr.io** | ✅ 2026-09-21 在**生产服务器上**实测：`https://ghcr.io/v2/` → `401  0.673s`。这是全案从设计之初就一直挂着的唯一未验证假设（开发机可达 ≠ 服务器可达），至此消除。仓库 public + 三个镜像包 public 也已用**裸 curl**（不带任何 `Authorization`）复验，故服务器侧凭据数为 0 |
| **`compose pull` 会不会跳过本地已有的 tag** | ✅ 2026-09-21 本机实测（Compose 5.5.0），这条决定通道叫什么名字：给同一镜像打 `:stable` 与 `:latest` 两个 tag 各写一个 compose，**两个都被拉取**、都访问了 registry。源码依据是 `docker/compose` `pkg/compose/pull.go` 里 `shouldPullImage()` **switch 之上**的提前返回 `if service.PullPolicy == "" { return true, "", nil }`——没显式写 `pull_policy` 时，显式 `pull` 一律刷新，`isLatestTag()` 那个特例走不到。（**先得出过一个相反的错误结论，已推翻**，留档以免重犯：通道名选 `latest` 的真正理由不是「非 latest 会被跳过」，而是「万一将来有人加了 `pull_policy: missing`，`latest` 构造性免疫而 `stable` 会静默停更」。） |
| **`imagetools create` 会不会改 digest** | ✅ 2026-09-21 本机 `--dry-run` 复验：不带 `--prefer-index=false` 时，单平台的 `image.manifest.v1+json` 被包成新的 `image.index.v1+json`，digest 随之改变；带上则逐字节拷贝、digest 保持为 `sha256:bfe7bfe2…`。所以通道搬运步骤里那条 `imagetools create` 必须带这个标志，且搬完要断言两个 tag 的 digest 相等（[010 §4](010-ci-release-pipeline.md)） |
| **离线包带通道 tag** | ✅ 2026-09-21 本机真跑一次（693MB）：`manifest.json` 里 seafile 那条 `RepoTags` 同时列出不可变 tag 与 `:latest`，服务器 load 后 compose 直接命中本地镜像，`.env` 一行不用改 |
| **通道搬运 + Release 全链路** | ✅ 2026-09-21 首跑（run 35590588040）：`imagetools create` 搬通道 → digest 断言通过 → Release 建出。**红在最后一步**：资产 `.env.prod.example` 被 GitHub 改写成 `default.env.prod.example`，固定 URL 取不到。已把模板改名 `env.prod.example` |
| **守卫的补做路径** | ✅ 2026-09-21 修完重跑（run 35590876529）：守卫判出「发布不完整（资产齐全=false）」→ 只补做搬运与发布，**40 秒、无重建**，并删掉那个陈旧资产 |
| **固定安装 URL** | ✅ 三个资产 `curl -fL …/releases/latest/download/<名>` 全部 200，且与仓库逐字节一致（`cmp` 通过）。`latest` 标记指向该 Release，非 draft、非 prerelease |
| **资产 URL 的真实重定向目标** | ✅ 2026-09-21 实测链路：`…/releases/latest/download/<名>` →302→ `…/releases/download/<tag>/<名>` →302→ **`release-assets.githubusercontent.com/…`** →200。文档里早先写的 `objects.githubusercontent.com` 是错的，已统一 |
| ⚠️ **资产会静默腐坏（2026-09-21 发现并修）** | ❌→✅ 三个资产不在 tag 哈希的输入里，所以**单独改它们不产生新 tag**；而 `paths:` 过滤不含它们、守卫第 ③ 条又只查「名字在不在」→ 判「发布完整」→ `mode=none` → **固定 URL 上那份永远是旧的**，新服务器装到「旧 compose + 新镜像」，全程全绿。**已修**：`paths:` 补三个资产，第 ③ 条改为**逐字节比对**（用 release asset API 的 `digest` 字段，实测与仓库 `sha256` 完全相同）。此后改资产 → `mode=publish` → 40 秒重传、**不重建** |
| **新装入口（干净目录）** | ✅ 2026-09-21 复验：从固定 URL 取三个文件 → `./init-prod-env.sh --domain … --admin-email …` 生成密钥齐全的 `.env`（且**不含** `SEAFILE_PRO_IMAGE`）→ `docker compose config` 三行镜像全部解析。仅未真起容器（那一步在服务器上） |
| ⚠️ **开发机直连 `github.com` 会超时** | 2026-09-21 实测：`codeload.github.com` 可直连，但 `github.com`（release 资产入口）直连 000/超时，走 `HTTPS_PROXY=127.0.0.1:8118` 才通。**服务器上必须单独验**，见 §2 那条⚠️——这是安装入口唯一的未验证假设 |
| **空转不动通道** | ⚠️ **当时是假绿**，见下一行。2026-09-21（run 35592557433）：修好后复验——只改文档的 push 撞上「tag 已存在且发布完整」→ 守卫判 `mode=none`，**构建与冒烟都 skipped**、通道未动，运行结论为**成功**（不是失败——空转报红会天天给管理员发误报邮件） |
| ⚠️ **同一 tag 被重建覆盖（本设计出的唯一一次事故）** | ❌→✅ 2026-09-21：守卫当时用两个布尔输出 `skip`/`skip_build`，判「发布完整」时只写了 `skip=true`，而构建步骤只看 `skip_build`（空串 ≠ `'true'`）→ **构建照跑**，用新字节覆盖了不可变 tag `ed2042da`。全程全绿、通道未动、零告警；只有比对 registry 才发现 tag 的 digest 与 Release 记录对不上。**已改成单三态输出 `mode`**（两个布尔天然能互相矛盾，三态不会），并在补做路径的 Release 正文加 ℹ️ 提示。两次构建的三层指纹逐字节相同，故内容无差异、只需把通道与记录收敛到新 digest |

**生产首次上线后回填**：LE 签发耗时、扫码登录、client-SSO、首次备份、服务器 ghcr 拉取实测耗时。
