# 029 - 文件传输跟随当前访问入口（1.3.2）

日期：2026-11-05。状态：源码修复、13 项回归及本地真实文件服务验证通过；未发布，未部署生产。

本地候选镜像：`seafile-mc-devbuild:1.3.2.2efab1af`，完整构建成功，统一冒烟结果 `SMOKE_OK`（32 项部门业务回归、4 项任务包装回归、13 项文件传输入口回归，以及静态资源、Nginx、启动配置检查通过）。Seahub 修复提交 `3d1f237bccb77c60ad7ddf27d5862003da39db8a`，已导出第 13 个发布补丁并通过树哈希一致性校验。

## 问题与原因

用户通过 `m-disc.moresec.cn` 使用系统，客户端上传却发往 `i-disc.moresec.cn:7443`，导致内网文件流量绕行外网，也暴露于另一入口的大小限制和网络条件。

此前补丁 0009 把 `FILE_SERVER_ROOT` 简化为从全局 `SERVICE_URL` 的协议和域名推导。`UploadLinkView` 返回的是绝对上传地址，客户端按返回值发起上传；它不会因为最初连接 m-disc 就自动改回该域名。这是服务端二开逻辑的多入口设计缺陷，不能只通过调整反向代理解决。

修复前：`m-disc → 获取上传地址 → 全局 SERVICE_URL 指向 i-disc:7443 → 文件体发到外网入口`。

修复后：`m-disc → 获取上传地址 → https://m-disc/seafhttp/... → 文件体留在当前入口`；其它入口同理，保留非标准端口。

## 实现

- `get_fileserver_root(request=None)` 接受可选请求；有请求时通过 Django `request.build_absolute_uri('/seafhttp')` 生成地址。使用 Django 的 Host 校验及可信代理协议处理，不手工信任任意转发头。
- 普通上传、覆盖上传、块上传/提交、文件/块下载、文件预览和压缩下载的 HTTP 处理器显式传递 request。Web 上下文的 `FILE_SERVER_ROOT` 同样跟随请求，避免页面和 API 行为不一致。
- 返回值仍是客户端可直接使用的绝对地址；没有改成相对路径，也没有修改全局 SERVICE_URL 或在进程级保存“最近请求”的域名。并发内外网请求相互独立。
- 邮件和规范分享链接继续使用 SERVICE_URL。无 request 的后台任务及 Office/SeaDoc/Exdraw 服务间回调继续沿用规范地址；内部文件服务 URL 保留原路径和配置。
- 不涉及数据库迁移、资料库权限、SSO token 或上传协议变更。修改 Site URL 无法代替按请求生成传输地址。

## 验证

`seahub/tests/seahub/utils/test_fileserver_origin.py` 的 13 项测试通过：

- 两个 HTTPS 域名、非标准端口、HTTP/IP 直连；覆盖全部文件地址帮助函数、中文文件名编码及 replace/commit 参数。
- 实际 DRF 上传、更新、块上传、块提交、下载处理器，以及 Web 页面上下文均保留请求入口。
- 匿名、权限不足、资料库不存在、令牌创建失败仍按原逻辑拒绝；未授权请求不会生成文件令牌。
- 非法/不允许的 Host 被 Django 拒绝；可信协议头生效，未启用信任的 X-Forwarded-Host 不改变目的域名。
- 40 个交错并发请求各自保留域名；全局 SERVICE_URL、规范分享链接及内部文件服务地址不被改写。

测试入口为 `deploy/image/test-fileserver-origin.py`，使用临时 SQLite/LocMem 配置和模拟 RPC，不连接业务数据库。Dockerfile 将测试装入镜像，统一 `smoke-test.sh` 已接入，防止后续补丁重放时丢失。

`deploy/probe-fileserver-origin.py` 在本地开发栈完成额外验证：独立临时账号和资料库，模拟 m-disc 与带 7443 端口的 i-disc 两个 Host，通过真实 CE 文件服务分别上传、下载 8 MiB 随机文件，SHA256 一致；资源已清理。只连接本机回环，不读取现有用户资料，也不把文件发往真实外网。

此验证覆盖真实文件服务读写，但尚未完成生产客户端的新上传链接及大文件验收。生产需要安装包含此补丁的新镜像，单独修改宝塔配置不会改变当前镜像生成的地址。已排队的旧上传任务可能继续保留旧链接，应在升级后新建上传任务验证。

## 生产验收

1. 用 m-disc 获取新的 upload-link/update-link，确认返回地址为 `https://m-disc.moresec.cn/seafhttp/...`；使用其它入口则返回该入口的协议、域名及端口。
2. 本地客户端从 m-disc 新建上传任务，日志中的实际文件请求仍为 m-disc。验证上传、下载及覆盖更新，下载内容与原文件一致。
3. 内外网请求同时进行，确认两者互不改写；邮件/规范分享链接保持 Site URL。

本次不处理 i-disc:7443 自身的 413，也不通过修改全局 Site URL 把外网用户改导向内网。
