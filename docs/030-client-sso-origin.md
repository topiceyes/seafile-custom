# 030 - 客户端 SSO 登录入口跟随请求（1.3.3）

日期：2026-11-05。状态：1.3.3 已发布；198 部署因完整备份空间不足被拦截，生产仍为 1.3.2。

本地候选镜像 `seafile-mc-devbuild:1.3.3.e787d69d` 构建及统一冒烟 `SMOKE_OK`；包含 32 项部门业务、4 项任务包装、13 项文件传输和 10 项 SSO 入口回归。Seahub 提交 `18848266c2ddd1dff29c4f2fe3b33c6973679625`，第 14 个发布补丁已导出并通过源码树一致性校验。

## 发布与部署记录

- 发布提交 `1f1e4d3f0b266266424e98e57ad8fdc2b04df31b`，发布分支 `release/1.3.3`。
- [CI 41982881452](https://github.com/topiceyes/seafile-custom/actions/runs/41982881452) 成功，包含实际镜像的 10 项 SSO 回归、13 项文件传输入口回归及完整冒烟。三层文件指纹与本地构建一致。
- [Release 1.3.3.e787d69d](https://github.com/topiceyes/seafile-custom/releases/tag/1.3.3.e787d69d) 已发布；固定镜像和 latest 摘要均为 `sha256:ae0183817ab55145835764f58aedefe5f61abc1ae324fd895b1b34a8f1cfc0b3`。三个安装资产摘要与发布提交一致。
- 198 已拉取且校验新镜像，受限升级入口报告 `Insufficient free disk for an upgrade backup plus 2 GiB reserve.`，尚未进入新备份和应用替换。上一轮备份为 `/var/lib/seafile-project-ops/backup-20261105-134839`；等待用户决定空间处理方式，不删除或绕过备份检查。
- 生产 SSO 跳转验收尚未执行。线上现有 1.3.2 只包含文件传输地址修复，不包含本次 SSO 修复。

## 原因

客户端以 `https://m-disc.moresec.cn` 发起单点登录，`POST /api2/client-sso-link/` 却返回 `https://i-disc.moresec.cn:7443/client-sso/...`。已在生产用匿名请求复现；没有完成该请求的用户登录，也没有输出一次性 SSO 令牌。

`ClientSSOLink.post()` 使用 `get_site_scheme_and_netloc()`（全局 SERVICE_URL）拼接浏览器链接。客户端照返回地址打开浏览器，因此尚未进入钉钉 OAuth 流程就已经换了域名。1.3.2 修复的是文件传输，未包含此独立 SSO 接口。

## 修改

在 SSO 链接创建时使用 `request.build_absolute_uri(reverse('client_sso', ...))`。返回值继续为客户端可用的绝对地址，保留当前协议、Host、端口及 SITE_ROOT 路径；设备参数保留原编码逻辑。Host 校验在令牌保存前完成，非法入口不会创建 SSO 令牌。

未修改全局 Site URL、SSO 令牌生成/有效期/轮询逻辑、用户登录权限或确认流程。后续 `client_sso()` 跳转使用相对登录路径，钉钉回调此前已跟随请求入口；修复起点后可以继续留在同一入口。

## 验证

隔离测试使用真实 SSO 处理器、ClientSSOToken 模型和临时 SQLite 表，不连接业务数据：

- m-disc、带 7443 端口的 i-disc 和 HTTP/IP 直连分别返回自身入口，设备参数和中文设备名保持一致。
- 无设备参数请求、反向代理协议、非信任 X-Forwarded-Host、SITE_ROOT 前缀覆盖。
- 浏览器登录页重定向为相对路径，`next` 中的确认路径和设备参数保留，令牌被正确标记访问。
- waiting 状态不发 API token，过期成功状态不返回凭据，不存在的令牌返回 404。
- 非法 Host 不创建令牌；数据库保存失败回滚并恢复 autocommit。

测试文件 `seahub/tests/seahub/views/test_client_sso_origin.py`，入口 `deploy/image/test-client-sso-origin.py`；Dockerfile 与统一冒烟均已接入。

生产验收应从 m-disc 新建一次客户端单点登录请求，确认返回链接、浏览器登录页和 OAuth 回调均留在 m-disc；扫码与最终确认仍由用户本人完成。旧登录请求不能用于验证新接口生成的地址。
