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

- [ ] **（上线时才需要，不是部署前提）** 域名 DNS 已指向**云反向代理**（不是本机）：
  `dig +short <域名>` 确认解析到代理的 IP
  - 反代模式下本机不需要公网 DNS；`SEAFILE_DOMAIN` 填的就是这个域名
  - **域名还没定也能先装**：`init-prod-env.sh` 默认用占位值 `seafile.local`，
    装完随时 `./set-domain.sh <域名>` 换掉——见 §4.2.1
- [ ] **本机 80 端口可被云代理访问到**（反代模式下只需要这一个）
  - 验证：从云代理那台机器 `curl -I http://<本机IP>/` 有响应即可
  - 反代模式下**不需要**本机 443 公网可达，也不需要 DNS 指向本机——证书和 DNS 都在云代理侧
  - （只有在用 `SEAFILE_SERVER_LETSENCRYPT=true` 时才需要 80 公网可达 + DNS 指向本机，
    因为那是容器自己跑 acme.sh webroot 验证）
- [x] **不需要任何凭据**：仓库与镜像包都是 public，取部署文件和拉镜像都免登录
  （曾是 classic PAT，2026-09-20 转 public 后取消）。CI 推镜像用内置 `GITHUB_TOKEN`
- [ ] 服务器网络可达 `ghcr.io` / `codeload.github.com`：已确认与开发机同网络（开发机实测可达）。
  免凭据后失败面只剩纯网络：拉不动先 `curl -I https://ghcr.io/v2/` 看通不通；
  真不通走 [010 §8](010-ci-release-pipeline.md) 的 ACR 备选
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

构建成功后，run summary 里会给出镜像地址与 digest；把 tag 填进服务器 `.env` 的
`SEAFILE_PRO_IMAGE` 即可（见 §4）。

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

服务器在国内网络，到 `github.com` 的 **git 协议不通**，但 `codeload.github.com` 可直连
（已实测），所以用 tarball 取部署文件，不需要配代理。

**运行时只需要 `seafile-prod.yml` + `.env` 两个文件。** 生产 compose 里**没有任何
宿主机相对路径**（`backup.sh` 与两个 cron 已烘进镜像），所以

> **放哪个目录都能起。** 这一点是刻意设计的：以前那三个 bind-mount 会让「换个目录
> 启动」变成**静默故障** —— 挂载落空、容器照常起，但备份和离职同步都不再执行。

唯一还需要仓库文件的地方是**首启之后**跑一次 `deploy/init-conf.sh --prod`（见 4.3 的最后一步），
所以下面仍然取整个 tarball —— 仓库很小，且这样脚本与文档永远同版本。

```bash
# ---- 4.1 取部署文件（免代理、免凭据）----
# 仓库是 public，直接裸 curl；服务器 git 协议到 github.com 不通，但 codeload 可直连
mkdir -p /opt/seafile-custom && cd /opt/seafile-custom
curl -fL --max-time 120 \
  https://codeload.github.com/topiceyes/seafile-custom/tar.gz/refs/heads/main \
  | tar -xz --strip-components=1 -C /opt/seafile-custom
cd deploy                          # 只是习惯，不再是硬要求

# ---- 4.2 配置：一条命令生成 .env（密钥自动生成，零提问）----
./init-prod-env.sh                 # 什么都不用给，直接回车到底
# 想提前定好就带参数（都可省略）：
#   ./init-prod-env.sh --domain seafile.x.cn --admin-email a@x.cn --admin-password 'xxx'
#
# 脚本做三件事：生成全部密钥、只改该改的行（反代模式那两个开关原样保留，并会自检）、
# 拒绝含单引号的值（单引号会破坏 .env 的 '值' 解析）。末尾直接打印后续命令。

# 管理员密码默认自动生成、只在终端显示这一次 —— 记得抄进密码管理器。

mkdir -p /data/seafile /data/seafile-mysql

# ---- 4.3 首启（db-first：先 db+memcached，等 MariaDB 完全就绪再起 seafile）----
docker compose pull                # 镜像包是 public，不需要 docker login

# 一把梭 up -d 在【全新数据卷】上有 MariaDB 竞态（见 §4 失败场景 2）：
# MariaDB 初始化要建 root 密码 + 跑 init SQL + 自己重启一次，可能超出 setup 的等待窗口。
# db-first 在彩排里实测稳定，且不比一把梭多花时间。
docker compose up -d db memcached
# 等到能真正连上（看到 "ready for connections" 还不够——MariaDB 初始化分两阶段）
docker exec seafile-mysql mariadb -uroot -p"$SEAFILE_MYSQL_ROOT_PASSWORD" -e "select 1"

docker compose up -d seafile   # 首启：setup 生成基础配置 + 建管理员
                               # （LETSENCRYPT=true 时这里还会签发证书；本项目是反代模式，不签）
docker logs -f seafile         # 等到 seahub 启动完成（能 curl 通登录页）

./init-conf.sh --prod          # ⚠️ 必须在首启完成后跑：追加钉钉/SSO/账号管控 + 开 WebDAV
                               # （脚本会打印生效用的 restart 命令，执行即可）
```

要点：tarball 根目录是 `<owner>-<repo>-<sha>/` 故需 `--strip-components=1`；`.env` 不在
tarball 内，重取代码不会覆盖它。

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

**为什么 init-conf --prod 在首启之后**：全新数据卷首启时，镜像内 `setup-seafile-mysql.py` 用 `open('w')` **无条件重写** `seahub_settings.py`（SECRET_KEY 随机、DB 密码取 `DB_PASSWORD` 环境变量、SERVICE_URL 取 `SEAFILE_SERVER_*`）。预渲染会被覆盖。所以流程是：环境变量喂给 setup 完成基础配置 → 首启后追加二开定制块（幂等，带标记）→ 重启生效。

**首启时容器内发生的事**（顺序，两处按 §9 的模式分叉）：
1. `init_letsencrypt()`：**仅 `LETSENCRYPT=true` 时执行** —— 先起临时 http 配置 → acme.sh
   webroot 验证 → 证书落 `/shared/ssl/<域名>.crt|key` → 装每日续期 cron。
   本项目是反代模式，这一步整个跳过（证书在云代理上）
2. `generate_local_nginx_conf()`：渲染 nginx server 块（我们修过的模板，含 X-Forwarded-Proto）。
   监听 443+证书 还是只有 80，由第 1 步结果决定
3. setup 初始化 MariaDB 三库（`DB_USER`/`DB_PASSWORD` 环境变量决定 seafile 库用户）+ 建 `INIT_SEAFILE_ADMIN_EMAIL` 管理员 + 生成基础 seahub_settings.py
4. 起 seafile/seahub/seafdav

### ⚠️ 首启常见失败与处置

**1. LE 首签失败**（签发失败会 `RuntimeError` 杀死启动脚本，但容器**看起来还是 running**——保活循环还在）。症状：网站无响应、`docker logs` 停在 letsencrypt 相关错误。排查：
- `dig +short <域名>` 是否解析到本机
- 80 端口公网可达性（见前置检查）
- `/shared/ssl/letsencrypt.log`（容器内路径）
- 注意 LE 频控：同域名每周最多 5 次失败签发，反复重试前先解决根因

**2. MariaDB 首次初始化竞态**：全新数据卷时 MariaDB 初始化（建 root 密码 + init SQL + 重启一次）可能超过 setup 的等待窗口，setup 以 `exit 255` 退出。处置：等 30 秒让 MariaDB 完全就绪（`docker logs seafile-mysql` 出现 `ready for connections` 且不再滚动），然后 `docker restart seafile` 重跑。setup 是幂等的（没建完 seafile-data 前重跑无副作用）。

**3. `seafile-data already exists`**：镜像构建期残留的 `/opt/seafile/seafile-data` 空目录会让 setup 的 auto 模式直接拒绝。我们的 Dockerfile 已修复（collectstatic 的临时目录随层清理）；若自定义镜像时重现此错，检查镜像里 `/opt/seafile/` 下是否只有 `seafile-server-12.0.14`。

## 5. 上线后动作

0. **切真域名**：管理员登录 → 系统管理 → 设置 → Site → Site URL 填 `https://你的域名` → 保存。
   **不用重启**（补丁 0009，见 [docs/011](011-service-url-admin-config.md)）。
   然后试一次**文件上传 + 下载**——这条过了就说明新地址完全生效了。
1. **钉钉开发者后台**：回调域名改为 `https://<域名>/dingtalk/callback/`
2. 管理员登录 → 系统管理 → 设置：核对钉钉开关与密钥（constance 默认值来自渲染的 seahub_settings.py）
3. 验证清单：
   - `curl -I http://<域名>/` → 301 https
   - `curl -sI https://<域名>/` → 200；`openssl s_client` 确认证书签发者是 Let's Encrypt
   - 钉钉扫码登录（真实手机）
   - 桌面客户端 client-SSO（`https://<域名>`，正式证书无需手动信任）
   - 普通用户密码登录被拒（0008 生效）、管理员可登录
   - WebDAV：`https://<域名>/seafdav/`
4. 次日检查 `backup.log` 与 `/data/seafile/backup/` 产物
5. **做一次恢复演练**（docs/009），确认备份可用

## 6. 更新与回滚

```bash
# 更新（CI 构建完、新 tag 出现在 docs/010 §9 台账后）
vi .env                          # SEAFILE_PRO_IMAGE 改新 tag（或钉新 digest）
docker compose pull && docker compose up -d

# 回滚 = 改回旧 tag（数据卷不动，LE 证书仍在）
```

更新前先记下当前镜像的 digest（`docker inspect --format '{{index .RepoDigests 0}}' <镜像>`），
回滚时就有确切落点。**首次生产更新后做一次回滚演练**：把 `SEAFILE_PRO_IMAGE` 指回该
digest → `pull && up -d` → 确认行为回到旧版本，再切回新版。数据卷全程不动。

**升级 Seafile 版本**（如 12.0.14 → 12.1.x）时三处硬编码要同步：
`deploy/image/Dockerfile` 的 BASE_IMAGE 与 INSTALLPATH、seahub 仓库基线（patches 重放）。官方镜像可能改 bootstrap 行为，升级前**必须重跑本地彩排**。

## 7. 本地彩排（上线前预演，已验证流程）

利用 `init_letsencrypt()` 的特性——证书有效期 >30 天就跳过签发只装续期 cron——在 Mac 上完整走一遍生产首启链路（唯一差异：证书是自签而非 LE）。

```bash
cd deploy

# 1) 本地构建镜像（arm64，不推送）
./build-image.sh --local

# 2) 彩排环境配置（独立数据目录 + 独立项目名 + macOS db 覆盖）
cp .env.prod.example .env.rehearsal
vi .env.rehearsal     # ⚠️ SEAFILE_SERVER_LETSENCRYPT='true' —— 彩排必须显式设回 true！
                      #    模板默认是 false（反代模式，见 §9），那会让容器只监听 80、
                      #    不渲染 443 块，下面的自签证书就白做了。LE 模式才是
                      #    「证书有效期>30天则跳过签发」这条彩排技巧成立的前提。
                      # SEAFILE_DOMAIN=<生产规划域名>（仅本机解析，curl 用 --resolve 即可不改 /etc/hosts）
                      # SEAFILE_PRO_IMAGE=seafile-mc-devbuild:<tag>
                      # SEAFILE_VOLUME=./rehearsal-data
                      # SEAFILE_MYSQL_VOLUME=./rehearsal-mysql（数据卷改相对路径）
                      # COMPOSE_FILE='seafile-prod.yml:rehearsal-db-override.yml'   ⚠️ mac 必加
# rehearsal-db-override.yml：db 加 --lower-case-table-names=1。macOS 文件系统大小写不敏感，
# MariaDB 默认 lctn=2 会让 seafevents 统计表（Monthly*）.frm/.ibd 大小写错位 → mysqldump 中断。
# ⚠️ lctn 只在首次初始化生效，必须配全新数据卷。

# 3) 域名自签证书（>30 天才会跳过 LE 签发）
SEAFILE_VOLUME=./rehearsal-data ./gen-ssl-cert.sh <域名>

# 4) 首启：db-first 顺序（先 db+memcached，等 MariaDB 双阶段初始化完成，再起 seafile）。
#    一把梭 up -d 全家桶有 MariaDB 竞态（§4 失败场景 2），db-first 已实测稳定。
#    注意：--env-file 必须显式带（compose 默认只读 .env，那是 dev 的配置）
export COMPOSE_PROJECT_NAME=seafile-rehearsal
docker compose --env-file .env.rehearsal up -d db memcached
# 等 docker logs seafile-mysql 出现 "ready for connections" 且不再滚动 Initializing
docker exec seafile-mysql mariadb -uroot -p<root密码> -e "select 1"   # 能连上才算真就绪
docker compose --env-file .env.rehearsal up -d seafile
docker logs seafile 2>&1 | grep -E "letsencrypt|Skip"   # 期望 Skip letsencrypt verification

# 5) 首启完成后追加二开定制（ENV_FILE 指向彩排 env，不影响 dev 的 .env）
ENV_FILE=.env.rehearsal ./init-conf.sh --prod
docker exec seafile /opt/seafile/seafile-server-latest/seafile.sh restart
docker exec seafile /opt/seafile/seafile-server-latest/seahub.sh restart
```

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

## 8. 环境变量对照（compose）

| 变量 | 说明 |
|---|---|
| `SEAFILE_DOMAIN` | 纯域名。证书文件名 + nginx server_name + SERVICE_URL 三处引用 |
| `SEAFILE_PRO_IMAGE` | 自建镜像（ghcr.io，public），tag 或 digest，见 [010 §9](010-ci-release-pipeline.md) 台账 |
| `SEAFILE_SERVER_LETSENCRYPT=true` | **唯一** https 开关（小写；`SEAFILE_SERVER_PROTOCOL` 只影响 SERVICE_URL） |
| `INIT_SEAFILE_ADMIN_EMAIL/PASSWORD` | 首启建管理员。**镜像不认 `SEAFILE_ADMIN_*`**（dev 环境踩过的坑：静默建成 me@example.com） |
| `DB_ROOT_PASSWD` | 首启初始化库 + 容器内 backup.sh 都用它 |
| `JWT_PRIVATE_KEY` | Seafile 12 内部服务认证（openssl rand -base64 48） |

## 9. 反代模式：TLS 在上游终止（本项目生产实际形态）


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

### X-Forwarded-Proto（模板已处理）

容器 nginx 只监听 80 时 `$scheme` 恒为 `http`，直接透传给 Django 会让
`request.is_secure()` 为假 → CSRF 校验、Secure cookie、重定向出零散问题。
模板现在在 server 块顶部定义一次 `$seafile_fwd_proto`：

- `https=true` → `$scheme`（容器内终止，就是真实协议）
- `https=false` → 取上游代理传来的 `$http_x_forwarded_proto`，**缺失时假定 https**

`deploy/smoke-test.sh` 会把两种模式都渲染一遍并跑 `nginx -t`，模板语法坏会在 CI 就拦住。

### 代理侧必须注意

| 项 | 说明 |
|---|---|
| **请求体大小上限** | 容器 `location /` 已设 `client_max_body_size 0`（不限），但**代理默认通常是 1m** —— 不改的话大文件上传会 413 |
| **转发头** | 建议设 `X-Forwarded-Proto $scheme`、`X-Forwarded-For`、`Host`。不设也能工作（容器会假定 https），但设了更准确 |
| **超时** | 大文件上传/下载走 `/seafhttp`，容器侧给了 36000s，代理侧的 `proxy_read_timeout` 要跟上 |
| **WebSocket** | `/notification` 需要 `Upgrade`/`Connection` 透传，否则通知不实时（功能不致命） |
| **不要只转 80** | `/media` 是容器 nginx 直接从磁盘发的，`/seafhttp` 走 8082，都由容器 nginx 内部分流。代理只要把**整个域名**转给容器 80 即可，不用按路径拆 |

## 10. 验证记录

**本地彩排（2026-09-20，arm64，镜像 12.0.14-dingtalk.8）——全链路通过：**

| 项 | 实测 |
|---|---|
| 首启链路（LE 跳过 → setup → seahub） | ✅ "Skip letsencrypt verification"；登录页 200 |
| 首启耗时 | db-first 顺序下 seafile 容器 ~2.5 分钟到登录页 200 |
| nginx conf | ✅ 模板渲染产物，X-Forwarded-Proto ×2，server_name 正确 |
| http→https | ✅ 301 → https |
| 管理员 | ✅ `INIT_SEAFILE_ADMIN_EMAIL` 账号（is_staff=1），非 me@example.com |
| init-conf --prod | ✅ seafdav enabled + 定制块幂等追加（ENV_FILE=.env.rehearsal） |
| 0008 双层拦截 | ✅ web 非管理员中文提示 / 管理员 302；api2 非管理员 400 + seahub.log 有 "Blocked password login" |
| backup.sh | ✅ 44K 两件套（详见 docs/009 §5） |
| 恢复演练 | ✅ 第三目录完整恢复可登录（踩坑：需重建 seafile@% 用户，已写入 docs/009） |
| 钉钉扫码 | 留生产切换时验（需临时改真实回调域名；dev 已验同代码路径） |

**部署脚本（2026-09-20，两地 fixture 实测）**：

| 项 | 实测 |
|---|---|
| `init-prod-env.sh` 零提问 | ✅ 无参数直接跑通，密钥全自动生成；自检「反代两开关未被改动」通过 |
| `set-domain.sh` 双引号 `SERVICE_URL` | ✅ `"https://127.0.0.1"` → `"https://seafile.acme.cn"`，`FILE_SERVER_ROOT` 同步 |
| `set-domain.sh` 单引号 `SERVICE_URL` | ✅ `'http://seafile.local'` → 正确识别旧域名（首版正则漏了单引号，已修） |
| **不误伤 `server_name _ default_server;`** | ✅ 双 server 块 fixture 下，只改含旧域名那一行，80 端口默认虚拟主机完好（首版无差别替换，已修） |
| 幂等性 | ✅ 同域名重跑输出「无需改动」并退出 0 |
| 备份 | ✅ 两个文件都留 `.bak-<时间戳>` |

> 两个 bug 都是 fixture 测出来的、不是推演出来的——尤其第二个：无差别替换 `server_name`
> 会悄悄把 80 端口的默认虚拟主机改掉，症状（别的 Host 头 404）离原因很远。

**彩排踩坑记录**（都已固化到流程/文件）：
1. MariaDB 竞态 → db-first 启动顺序（§7 步骤 4）
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
| 首次 CI 运行 + 镜像发布 | ✅ 构建 8m27s；tag `12.0.14-dingtalk.8`，digest 记在 [010 §9](010-ci-release-pipeline.md) 台账 |
| tag 已存在守卫 | ✅ 被真实触发过一次并正确拦截（在昂贵构建之前） |
| **CI amd64 产物 vs 本地 arm64 产物** | ✅ 三层指纹**完全一致**：overlay `bee2ffbe…`(937)、前端产物 `e1f7eb47…`(269)、media/assets `6dd7b6e9…`(305) —— 连 webpack 产物都跨架构逐字节相同 |
| 服务器 ghcr 拉取 | ⏳ 上线时验（用户确认与开发机同网络） |

**生产首次上线后回填**：LE 签发耗时、扫码登录、client-SSO、首次备份、服务器 ghcr 拉取实测耗时。
