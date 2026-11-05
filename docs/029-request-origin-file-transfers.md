# 029 - 文件传输跟随当前访问入口（1.3.2）

日期：2026-11-05。状态：1.3.2 已正式发布并部署到 198；m-disc 传输地址及约 322 MB 文件上传下载、SHA256 校验通过。

本地候选镜像：`seafile-mc-devbuild:1.3.2.2efab1af`，完整构建成功，统一冒烟结果 `SMOKE_OK`（32 项部门业务回归、4 项任务包装回归、13 项文件传输入口回归，以及静态资源、Nginx、启动配置检查通过）。Seahub 修复提交 `3d1f237bccb77c60ad7ddf27d5862003da39db8a`，已导出第 13 个发布补丁并通过树哈希一致性校验。

## 正式发布及部署进度

- 发布提交：`523cedb41033eedd8ebbf3a1887896c918209796`；`release/1.3.2` 和 Release tag 锚定该提交，后续文档记录在 main。
- [CI 41974444528](https://github.com/topiceyes/seafile-custom/actions/runs/41974444528) 成功完成构建、正式镜像冒烟和发布；包含 13 项入口测试。三层文件指纹与本地镜像逐一一致。
- [Release 1.3.2.2efab1af](https://github.com/topiceyes/seafile-custom/releases/tag/1.3.2.2efab1af) 已发布；不可变镜像与 latest 均为 `sha256:fc3e662d657486512b124e0916c171754495aebb3f1102d63e2b06d2e743fcac`。三个安装资产的发布摘要与仓库文件逐一相同。
- 部署前，通过本机已登录 m-disc 客户端账号读取新的 upload-link，仍返回 `https://i-disc.moresec.cn:7443`，确认线上旧版的地址缺陷。
- 首次部署被 `Insufficient free disk for an upgrade backup plus 2 GiB reserve.` 拦截；用户清理旧升级备份后通知继续，可用空间恢复至约 37 GiB。
- 重试通过空间检查，备份三库、配置和文件数据；gzip 完整性及 SHA256 校验通过，备份位于 `/var/lib/seafile-project-ops/backup-20261105-134839`。随后仅重建应用容器，数据库、Redis 持续运行。
- 198 当前运行 `ghcr.io/topiceyes/seafile-mc:1.3.2.2efab1af`，config digest 为 `sha256:b47a5d28b94ef7e199a81fa756a74364f02f66868f498eea310b1a2778882b2c`。登录页 200，Django 检查无问题；196 组织节点（含根）、195 空间全部 active、177 条 desired/applied 授权、grant_errors=0、群组仍为 2。验证入口未执行额外组织同步。
- 用本机已登录 m-disc 客户端账号新建独立临时资料库；普通上传、覆盖上传、Web 上传三个实际 API 均返回 `https://m-disc.moresec.cn/seafhttp/...`。实际上传 321,670,659 B 随机文件返回 200。
- 大文件往返复测：上传及下载均为 200，目的域名保持 m-disc，实际接收 321,670,659 B；原始及下载 SHA256 同为 `d0075e3460fa70c5ee79c5c6fc61d8d6f12eee3a3ae6dc437b56f0cfb921bbc8`，全流程约 109.7 秒。另一次 16 MiB 往返也通过。各次临时资料库已通过 API 删除，不读取或修改原业务文件。
- 首次 321,670,659 B 验收中上传成功，下载阶段触发断言；当次脚本未输出失败断言内容，不能确认具体原因。补充响应码、字节数及摘要诊断后，16 MiB 和同等大文件复测均通过，暂未复现。此记录保留该次异常，不将后续成功解释为首次异常原因已查明。

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

生产验证使用同一客户端账号及实际 HTTP API，不模拟 Qt 界面点击。已排队的旧上传任务可能继续保留旧链接，应在升级后取消旧任务、新建上传任务验证客户端界面。

## 生产验收

1. 用 m-disc 获取新的 upload-link/update-link，确认返回地址为 `https://m-disc.moresec.cn/seafhttp/...`；使用其它入口则返回该入口的协议、域名及端口。
2. 本地客户端从 m-disc 新建上传任务，日志中的实际文件请求仍为 m-disc。验证上传、下载及覆盖更新，下载内容与原文件一致。
3. 内外网请求同时进行，确认两者互不改写；邮件/规范分享链接保持 Site URL。

本次不处理 i-disc:7443 自身的 413，也不通过修改全局 Site URL 把外网用户改导向内网。
