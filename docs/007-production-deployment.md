# 007 - 生产部署（正式服务器）

> 完成日期：2026-09-20 ｜ 状态：镜像构建/彩排流程已建立，首次上线按本文执行

## 1. 架构

```
开发机（Mac）                          生产服务器（amd64，已装 docker compose）
─────────────────                     ──────────────────────────────────────
seahub 二开分支 ──┐
patches/0001-0008 │                   docker compose pull   （自建镜像）
                  ├→ build-image.sh → 推 ACR ──────────────→ docker compose up -d
deploy/image/*   ─┘   （多阶段构建）                          ├─ LE 自动签发/续期证书
                                                      80/443 ← 公网（DNS A 记录）
```

与 dev 环境的本质差异：**二开代码不再 bind-mount，全部烘进自建镜像**（seahub Python 包 + 前端构建产物 + collectstatic 静态资源），服务器不需要 node、不需要 seahub 源码、容器重建不丢任何东西。

## 2. 前置条件（上线检查清单）

- [ ] 域名 DNS A 记录已指向服务器公网 IP（`dig +short <域名>` 确认）
- [ ] 服务器 80 和 443 端口公网可达（80 是 LE webroot 验证的硬要求）
  - 验证：`curl -I http://<域名>/.well-known/acme-challenge/test` 返回 404/502 都算通，超时就是被墙/被防火墙挡
- [ ] ACR 仓库就绪（如阿里云容器镜像服务，个人版免费）：建命名空间 + 本地仓库（类型选「本地」）
- [ ] 服务器磁盘规划：`/data/seafile`（库+文件+备份）与 `/data/seafile-mysql` 所在盘要够大
- [ ] 钉钉回调域名准备好切到 `https://<域名>/dingtalk/callback/`（上线后改）

## 3. 镜像构建与推送（开发机）

```bash
cd deploy
docker login <registry>            # ACR 凭据
./build-image.sh <registry>/<namespace>
# 例：./build-image.sh registry.cn-hangzhou.aliyuncs.com/myns
```

- tag 自动取 `12.0.14-dingtalk.<N>`（N = seahub 分支领先基线 0877ad7 的提交数，必然递增）
- 双架构（amd64 生产 + arm64 彩排机）一次构建推送
- 防呆：seahub 工作区不干净会拒绝构建（镜像内容 = 提交内容）

**网络坑**（开发机在国内网络下实测）：
- `docker pull node:24-bookworm-slim` 等基础镜像可能因 DNS 污染超时——**重试即可**（间歇性），成功后本地有缓存
- Dockerfile 不用 `# syntax=` 指令（会去 docker.io 拉前端镜像，同样受 DNS 污染影响）

**冒烟验证（推送前后均可）**：

```bash
docker run --rm --entrypoint sh seafile-mc-devbuild:<tag> -c '
  set -e
  grep "^SEAFILE_VERSION = \"12.0.14\"" /opt/seafile/seafile-server-12.0.14/seahub/seahub/settings.py
  test -f /opt/seafile/seafile-server-12.0.14/seahub/frontend/webpack-stats.pro.json
  ls /opt/seafile/seafile-server-12.0.14/seahub/frontend/build/static/js >/dev/null
  test $(grep -c X-Forwarded-Proto /templates/seafile.nginx.conf.template) -ge 2
  command -v mysqldump
  grep -q PASSWORD_LOGIN_ADMIN_ONLY /opt/seafile/seafile-server-12.0.14/seahub/seahub/settings.py
  ls /opt/seafile/seafile-server-12.0.14/seahub/media/assets >/dev/null
  echo SMOKE_OK'
```

## 4. 服务器部署

```bash
# 服务器上（任意目录）
git clone https://github.com/topiceyes/seafile-custom.git   # 私有库需凭据
cd seafile-custom/deploy

cp .env.prod.example .env
vi .env    # 填：域名、ACR 镜像 tag、所有密码/密钥（都重新生成，勿沿用 dev 值）

mkdir -p /data/seafile /data/seafile-mysql

docker compose pull
docker compose up -d           # 首启：LE 签发 + setup 生成基础配置 + 建管理员
docker logs -f seafile         # 等到 seahub 启动完成（能 curl 通登录页）

./init-conf.sh --prod          # ⚠️ 必须在首启完成后跑：追加钉钉/SSO/账号管控 + 开 WebDAV
                               # （脚本会打印生效用的 restart 命令，执行即可）
```

**为什么 init-conf --prod 在首启之后**：全新数据卷首启时，镜像内 `setup-seafile-mysql.py` 用 `open('w')` **无条件重写** `seahub_settings.py`（SECRET_KEY 随机、DB 密码取 `DB_PASSWORD` 环境变量、SERVICE_URL 取 `SEAFILE_SERVER_*`）。预渲染会被覆盖。所以流程是：环境变量喂给 setup 完成基础配置 → 首启后追加二开定制块（幂等，带标记）→ 重启生效。

**首启时容器内发生的事**（顺序）：
1. `init_letsencrypt()`：先起临时 http 配置 → acme.sh webroot 验证 → 证书落 `/shared/ssl/<域名>.crt|key` → 装每日续期 cron
2. `generate_local_nginx_conf()`：渲染 443 server 块（我们修过的模板，含 X-Forwarded-Proto）
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
# 更新（开发机推完新镜像 tag 后）
vi .env                          # SEAFILE_PRO_IMAGE 改新 tag
docker compose pull && docker compose up -d

# 回滚 = 改回旧 tag（数据卷不动，LE 证书仍在）
```

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
vi .env.rehearsal     # SEAFILE_DOMAIN=<生产规划域名>（仅本机解析，curl 用 --resolve 即可不改 /etc/hosts）
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
| `SEAFILE_PRO_IMAGE` | 自建镜像 tag |
| `SEAFILE_SERVER_LETSENCRYPT=true` | **唯一** https 开关（小写；`SEAFILE_SERVER_PROTOCOL` 只影响 SERVICE_URL） |
| `INIT_SEAFILE_ADMIN_EMAIL/PASSWORD` | 首启建管理员。**镜像不认 `SEAFILE_ADMIN_*`**（dev 环境踩过的坑：静默建成 me@example.com） |
| `DB_ROOT_PASSWD` | 首启初始化库 + 容器内 backup.sh 都用它 |
| `JWT_PRIVATE_KEY` | Seafile 12 内部服务认证（openssl rand -base64 48） |

## 9. 验证记录

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

**彩排踩坑记录**（都已固化到流程/文件）：
1. MariaDB 竞态 → db-first 启动顺序（§7 步骤 4）
2. macOS lctn=2 统计表损坏 → rehearsal-db-override.yml（§7 步骤 2）
3. 恢复缺 MySQL 授权 → docs/009 §3 步骤 3
4. `seahub.sh python-env` 是交互式入口不接收参数，非交互用法：`echo '<code>' | docker exec -i seafile .../seahub.sh python-env`（代码需自带 django.setup() prologue）
5. 登录表单 POST 字段名是 `login`；https 下 CSRF 需要 Referer 头

**生产首次上线后回填**：LE 签发耗时、扫码登录、client-SSO、首次备份。
