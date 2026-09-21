# Seafile 企业定制版（二开）

基于 [Seafile CE 12.0](https://github.com/haiwen/seafile) 的二次开发，核心是**把企业钉钉通讯录接入 Seafile 的账号体系**：钉钉扫码登录、配置后台管理化、离职员工自动禁用。

知识库（每个功能的需求/方案/实现/踩坑）见 [`docs/`](docs/README.md)。

## 目录结构

```
.
├── deploy/                 # Docker 部署（本仓库的主体）
│   ├── seafile-server.yml      # dev compose（源码 bind-mount，本地开发）
│   ├── seafile-prod.yml        # 生产 compose（自建镜像；无宿主机相对路径）
│   ├── .env.example / .env.prod.example   # dev / 生产配置模板
│   ├── init-prod-env.sh        # 生成生产 .env（密钥自动生成，零提问）
│   ├── init-conf.sh            # 渲染配置进数据卷（仅 dev；生产已由镜像自动完成）
│   ├── gen-ssl-cert.sh         # 自签证书（dev IP / 彩排域名）
│   ├── build-image.sh          # 镜像构建（开发机与 CI 共用的唯一构建入口）
│   ├── export-patches.sh       # 重导补丁 + 刷新 MANIFEST（改完二开代码必跑）
│   ├── smoke-test.sh           # 镜像冒烟断言（CI 与人工验证共用的唯一一份）
│   ├── rebuild-frontend.sh     # dev 前端构建（生产走镜像内构建）
│   ├── sync-dingtalk-users.sh  # 手动触发离职同步
│   ├── rehearsal-db-override.yml  # 本地彩排的 macOS MariaDB 覆盖
│   ├── image/                  # ⬇ 这里的东西全部烘进生产镜像（不是挂载）
│   │   ├── Dockerfile              # 镜像定义
│   │   ├── patch-upstream.py       # 构建期给上游启动脚本打的三处补丁（带断言，跑完即删）
│   │   ├── custom_bootstrap.py     # 启动时追加二开定制（SSO/钉钉开关/账号管控 + WebDAV）
│   │   ├── nginx/seafile.nginx.conf.template
│   │   ├── backup.sh / backup.cron # 每日备份（三库 dump + 数据打包）
│   │   └── dingtalk-sync.cron      # 离职员工同步（dev 从同一路径挂载）
│   ├── conf-templates/         # 配置模板（占位符形式，无密钥）
│   └── seafile-data/           # ⛔ 运行时数据，不入库
├── patches/                # seahub 二开改动（patch 系列 + MANIFEST.md 基线清单）
├── .github/workflows/      # CI：复现源码树 → 构建镜像 → 推 ghcr.io
└── docs/                   # 知识库
```

## 什么没有入库

| 内容 | 原因 |
|---|---|
| `deploy/seafile-data/`、`deploy/seafile-mysql-db/` | 本地调试数据：MariaDB 库文件、用户上传的文件实体、日志、TLS 私钥 |
| `deploy/.env` | 含真实密钥（数据库密码、JWT 密钥、钉钉 AppSecret） |
| `seafile/`、`seahub/` | 上游源码克隆，各自是独立仓库（`haiwen/seafile`、`haiwen/seahub`） |

运行时配置**不是**直接入库的，而是入库模板（`deploy/conf-templates/`，占位符形式）再由 `init-conf.sh` 用 `.env` 的值渲染进数据卷。这样密钥永远不进 git 历史，配置本身仍受版本控制。

> C 侧的 `seafile.conf` / `seafevents.conf` 由 C 守护进程解析，**不支持环境变量替换**，所以必须走「模板渲染」而不是「读环境变量」。

## 二开代码在哪

Seafile 的二开改动集中在 `seahub`（Django Web 层），共 9 个提交，以 patch 形式记录在 `patches/`：

| 补丁 | 内容 | 文档 |
|---|---|---|
| 0001 | 社区版解锁钉钉扫码登录 | [001](docs/001-dingtalk-login.md) |
| 0002 | 源码挂载部署需手动提供 `SEAFILE_VERSION` | [001](docs/001-dingtalk-login.md) |
| 0003 | 钉钉配置挪到管理后台、免重启生效 | [002](docs/002-dingtalk-admin-config.md) |
| 0004 | 通讯录接口失败时返回友好错误 | [002](docs/002-dingtalk-admin-config.md) |
| 0005 | 禁止断开钉钉绑定 | [003](docs/003-lockdown-settings.md) |
| 0006 | 离职员工自动禁用命令 | [004](docs/004-auto-deactivate-departed-users.md) |
| 0007 | 钉钉登录 `invalid state` 可诊断 | [001](docs/001-dingtalk-login.md) |
| 0008 | 密码登录仅限管理员（钉钉 SSO 唯一入口） | [008](docs/008-restrict-password-login.md) |
| 0009 | 站点地址 `SERVICE_URL` 挪到管理后台、免重启生效 | [011](docs/011-service-url-admin-config.md) |

基线是 `haiwen/seahub` 分支 `12.0` 的 commit `0877ad7`（全 SHA 与目标 tree sha 记在
[`patches/MANIFEST.md`](patches/MANIFEST.md)，**由脚本生成，勿手工编辑**）。应用到上游源码：

```bash
git clone https://github.com/haiwen/seahub.git && cd seahub
git checkout 0877ad7                      # 固定 commit，不受上游分支前进影响
git am /path/to/this/repo/patches/*.patch
```

改完二开代码后**不要手工导补丁**，跑：

```bash
cd deploy && ./export-patches.sh   # 重导补丁 → 刷新 MANIFEST → 自检树哈希
```

它会校验「补丁逐个应用后的源码树」等于「二开分支的源码树」，不过就拒绝结束。构建镜像时
（本地与 CI 都一样）还会再验一遍，所以发不出与补丁不一致的镜像。

## 快速上手

**本地开发**：

```bash
cd deploy
cp .env.example .env          # 填入数据库密码、JWT 密钥等
./gen-ssl-cert.sh             # 生成自签证书
./init-conf.sh                # 渲染配置到 seafile-data/
docker compose up -d
```

**生产部署**（CI 构建镜像 → ghcr.io → 服务器拉取；TLS 由上游反向代理终止，见 [docs/007 §9](docs/007-production-deployment.md)）：完整流程见 [docs/007](docs/007-production-deployment.md)。上线前先跑本地彩排（docs/007 §7）。

部署**零提问**：`./init-prod-env.sh` 不带参数直接跑（密钥全自动生成，域名先用占位值当默认），
装完在**系统管理 → 设置 → Site** 里填真域名和钉钉凭据——**都免重启生效**。
理由见 [docs/011](docs/011-service-url-admin-config.md) 与 [docs/002](docs/002-dingtalk-admin-config.md)。

启动后访问 <https://127.0.0.1>（自签证书，浏览器需点「继续前往」）。

部署二开源码：把 `seahub/seahub` 以 bind-mount 挂进容器，或直接把打好补丁的 `seahub/` 挂进去。细节见 [docs/006](docs/006-https-setup.md) 与 [docs/README](docs/README.md) 的「关键约定」。

## 发布流程（改代码 → 上生产）

镜像不在开发机手工推，由 **GitHub Actions 构建并推到 ghcr.io**；生产机只 `docker compose pull`。
机制、排障与 ACR 备选见 [docs/010](docs/010-ci-release-pipeline.md)。

```
开发机                                GitHub                                生产服务器
seahub 改代码                          Actions（ubuntu-latest, amd64）        重取 deploy/ → compose pull
  └ deploy/export-patches.sh   ──push──→  按 MANIFEST 的固定 SHA 浅取上游       （ghcr.io public 镜像）
       └ patches/ + MANIFEST.md            → git am patches/*.patch                  │
                                           → 断言 tree sha                          └ 云反向代理终止 TLS
                                           → deploy/build-image.sh（同一份脚本）       明文转发到本机 :80
                                           → ghcr.io/topiceyes/seafile-mc:<tag>
                                                │
                  digest 写进 deploy/seafile-prod.yml（入库）←┘
```

```bash
cd deploy && ./export-patches.sh        # 1. 重导补丁 + 刷新 MANIFEST（会自检）
git add -A && git commit -m "..." && git push main   # 2. 推送触发构建
gh run watch                            # 3. 看构建（约 12–18 分钟）

# 4. 把 run summary 给的 digest 写进 deploy/seafile-prod.yml 的 image: 行，提交 ← 发布动作
# 5. 生产服务器上：重取 deploy/ → docker compose pull && docker compose up -d
```

**版本钉在入库的 compose 文件里，不在服务器 `.env` 里。** 于是「服务器知道有新版」这件事
就是「重取了一次 `deploy/`」，不需要有人记得改某个本地文件——而漏改是静默的：pull 照样报
`Pulled`、up 照样报 `Recreated`，跑的却是旧镜像。2026-09-21 踩过（[docs/007 §6](docs/007-production-deployment.md)）。

**为什么走补丁路线而不是 fork**：决定性的理由是补丁路线带来一条更硬的性质——
CI 每次构建都重新验证「补丁能逐字节复现二开分支」，上游漂移或补丁改坏会变成**构建失败**，
而不是悄悄发出一个内容不对的镜像。fork 路线下 CI 直接构建分支，没有东西做这个验证。

> 转 public 之前还有一条策略性理由（上游是公开仓库、其 fork 无法设为私有），
> 但 2026-09-20 本仓库已转为 public，那条已不适用。详见 [docs/010 §2](docs/010-ci-release-pipeline.md)。

**tag 规则**：`12.0.14-dingtalk.<补丁数>.<8位哈希>`。哈希段是**构建输入的内容哈希**
（补丁内容 + `deploy/image/**` + `build-image.sh`），所以改模板或 Dockerfile 也会自动得到新
tag —— **同 tag ⇒ 同内容**，正常发布不需要 `force`（只有重建以刷新上游基础镜像才需要）。

即便如此，生产上仍**钉 digest**：它是唯一不依赖命名约定的保障。digest 写在入库的
`deploy/seafile-prod.yml` 里（不是服务器 `.env`），每次构建的 digest 记在 docs/010 §9
台账，也在 CI 的 run summary 里。

## 分支约定

上游基线是 **`12.0` 维护分支**（不是 `master`——master 是 13.x 线，Django 5.2，与本项目不兼容）。升级 Seafile 版本时需同步处理：compose 里的版本目录硬编码路径、patch 基线、以及手写的 nginx 配置。
