# Seafile 企业定制版（二开）

基于 [Seafile CE 12.0](https://github.com/haiwen/seafile) 的二次开发，核心是**把企业钉钉通讯录接入 Seafile 的账号体系**：钉钉扫码登录、配置后台管理化、离职员工自动禁用。

知识库（每个功能的需求/方案/实现/踩坑）见 [`docs/`](docs/README.md)。

## 目录结构

```
.
├── deploy/                 # Docker 部署（本仓库的主体）
│   ├── seafile-server.yml      # dev compose（源码 bind-mount，本地开发）
│   ├── seafile-prod.yml        # 生产 compose（自建镜像 + Let's Encrypt）
│   ├── .env.example / .env.prod.example   # dev / 生产配置模板
│   ├── init-conf.sh            # 把 conf-templates/ 渲染进数据卷（--prod 生产模式）
│   ├── gen-ssl-cert.sh         # 自签证书（dev IP / 彩排域名）
│   ├── build-image.sh          # 生产镜像构建（git archive 上下文 + buildx 多架构）
│   ├── image/                  # Dockerfile + 修好的 nginx 模板
│   ├── backup.sh / backup.cron # 每日备份（三库 dump + 数据打包）
│   ├── rebuild-frontend.sh     # dev 前端构建（生产走镜像内构建）
│   ├── sync-dingtalk-users.sh / dingtalk-sync.cron
│   ├── conf-templates/         # 配置模板（占位符形式，无密钥）
│   └── seafile-data/           # ⛔ 运行时数据，不入库
├── patches/                # seahub 二开改动（patch 系列）
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

Seafile 的二开改动集中在 `seahub`（Django Web 层），共 7 个提交，以 patch 形式记录在 `patches/`：

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

应用到上游源码（基线 `haiwen/seahub` 分支 `12.0`，commit `0877ad7`）：

```bash
git clone -b 12.0 https://github.com/haiwen/seahub.git
cd seahub && git checkout 0877ad7
git am /path/to/this/repo/patches/*.patch
```

## 快速上手

**本地开发**：

```bash
cd deploy
cp .env.example .env          # 填入数据库密码、JWT 密钥等
./gen-ssl-cert.sh             # 生成自签证书
./init-conf.sh                # 渲染配置到 seafile-data/
docker compose up -d
```

**生产部署**（自建镜像 → ACR → 服务器，Let's Encrypt 正式证书）：见 [docs/007](docs/007-production-deployment.md)。核心命令 `./build-image.sh <registry>/<ns>`，上线前先跑本地彩排（docs/007 §7）。

启动后访问 <https://127.0.0.1>（自签证书，浏览器需点「继续前往」）。

部署二开源码：把 `seahub/seahub` 以 bind-mount 挂进容器，或直接把打好补丁的 `seahub/` 挂进去。细节见 [docs/006](docs/006-https-setup.md) 与 [docs/README](docs/README.md) 的「关键约定」。

## 分支约定

上游基线是 **`12.0` 维护分支**（不是 `master`——master 是 13.x 线，Django 5.2，与本项目不兼容）。升级 Seafile 版本时需同步处理：compose 里的版本目录硬编码路径、patch 基线、以及手写的 nginx 配置。
