# Seafile 二开知识库

本项目是基于 Seafile 社区版的二次开发工作区。本目录记录每个功能的需求、方案、实现与踩坑，便于后续维护和新人上手。

## 文档索引

| 编号 | 文档 | 功能 | 状态 |
|---|---|---|---|
| 001 | [钉钉扫码登录](001-dingtalk-login.md) | 企业用户钉钉扫码登录 Seafile | ✅ 已完成（2026-09-16） |
| 002 | [钉钉配置管理化](002-dingtalk-admin-config.md) | 钉钉登录配置挪到管理后台、免重启生效 | ✅ 已完成（2026-09-16） |
| 003 | [账号管控收紧](003-lockdown-settings.md) | 禁止用户注销账号、禁止断开钉钉绑定 | ✅ 已完成（2026-09-16） |
| 004 | [离职账号自动禁用](004-auto-deactivate-departed-users.md) | 定时比对钉钉通讯录，禁用离职员工账号 | ✅ 已完成（2026-09-17） |
| 005 | [启用 WebDAV](005-enable-webdav.md) | 开启官方默认关闭的 SeaFDAV 服务（502 修复） | ✅ 已完成（2026-09-17） |
| 006 | [全站 HTTPS](006-https-setup.md) | 自签证书 + 手写 nginx，客户端 SSO 需要 | ✅ 已完成（2026-09-17） |
| 007 | [生产部署](007-production-deployment.md) | 自建镜像 + Let's Encrypt 正式上线（含本地彩排流程） | ✅ 已完成（2026-09-20） |
| 008 | [密码登录仅限管理员](008-restrict-password-login.md) | 钉钉 SSO 成为普通用户唯一入口 | ✅ 已完成（2026-09-20） |
| 009 | [备份与恢复](009-backup-restore.md) | 三库 dump + 数据目录打包，每日 cron | ✅ 已完成（2026-09-20） |
| 010 | [CI 发布流水线](010-ci-release-pipeline.md) | 推 GitHub → Actions 构建 + 冒烟 → 搬通道 tag `latest` + 建 Release → 生产机 `compose pull` | ✅ 已完成（2026-09-20） |
| 011 | [站点地址管理化](011-service-url-admin-config.md) | SERVICE_URL 挪到管理后台、免重启生效 | ✅ 已完成（2026-09-20） |
| 012 | [Seafile 13.x 升级评估](012-seafile-13-upgrade-assessment.md) | 12.0→13.0 差异分析：补丁重放实测 + 镜像破坏点 + 决策点 | 📋 评估完成（2026-09-24），未动手 |

## 工作区结构

```
/Volumes/newdisc/appdev/Seafile/
├── seafile/     # C 核心源码（master，官方仓库，未改动；不入库）
├── seahub/      # Web 层源码（二开主战场，dev-dingtalk 分支；不入库，以补丁形式发布）
├── patches/     # 二开补丁系列 + MANIFEST.md（入库，CI 的唯一源码输入）
├── deploy/      # Docker 部署（compose 配置 + 构建脚本 + 持久化数据）
├── docs/        # 本知识库
├── .github/     # GitHub Actions（构建并推送镜像到 ghcr.io）
└── .claude/     # Claude Code 会话配置
```

> `seahub/` 与 `seafile/` 各是上游 1.4 GB / 数百 MB 的仓库，**不入库**。二开内容以
> `patches/*.patch` 的形式入库，CI 按固定 SHA 拉上游再应用补丁 —— 见 010 文档。

## 快速上手

- **启动/停止服务**：`cd deploy && docker compose up -d` / `docker compose stop`
- **访问**：https://127.0.0.1（自签证书，浏览器需点「继续前往」；http 及 8180 端口会 301 跳转到这里。见 006 文档）
- **管理员**：`dev@local.test` / `dev123456`
- **改 seahub Python 代码后生效**：`docker exec seafile /opt/seafile/seafile-server-latest/seahub.sh restart`
- **改前端代码后生效**：`cd deploy && ./rebuild-frontend.sh`（无需重启 seahub，浏览器强刷）
- **看应用日志**：`tail -f deploy/seafile-data/seafile/logs/seahub.log`

## 关键约定（重要）

1. seahub 源码以 bind-mount 方式挂进容器（只挂 `seahub/seahub` Python 包目录，**不能**挂整个 `seahub/`，容器内 `thirdpart/` 是已装依赖含 gunicorn）
2. 二开分支基于 **12.0 维护分支**（容器运行 12.0.14，Django 4.2），不要直接用 master（13.x 线，Django 5.2，不兼容）
3. 源码运行需手动提供 `SEAFILE_VERSION`（发布构建时才注入的变量，缺失导致 ImportError）
4. 升级 Seafile 镜像版本时：compose 里的版本目录硬编码路径、源码基线都要同步处理
