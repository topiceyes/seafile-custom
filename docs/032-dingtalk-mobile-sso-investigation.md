# iPhone 客户端钉钉登录

日期：2026-11-06。当前版本：[1.3.7.5c0ca473 已部署到 198 生产环境](https://github.com/topiceyes/seafile-custom/releases/tag/1.3.7.5c0ca473)。完整备份、镜像校验、独立迁移和正式 HTTPS 登录链路检查通过。部署后用户反馈“可以登录”，iPhone Seafile App 钉钉登录主流程真机验收通过。下文前半部分保留分阶段实施记录，以末尾生产结果为准。

## 已取得的真机证据

用户在 iPhone Safari 打开临时验证页，点击 `dingtalk://dingtalkclient/page/link` 后唤起钉钉，在钉钉内访问现有 `/dingtalk/login/`，反馈能够进入系统。此次只是独立网页登录，没有携带客户端请求，也没有签发客户端 API token。

这证明了本次设备上的 Safari 唤起和钉钉内授权。新增中转链接中的 URL fragment 能否由钉钉完整保留，以及 Seafile App 发起的完整登录链路，仍需真机验收。

## 与 iOS 客户端协议的对应

核对了 [官方 SeafShibbolethViewController.m](https://github.com/haiwen/seafile-iOS/blob/master/seafile/SeafShibbolethViewController.m)：服务端声明 `client-sso-via-local-browser` 时，iOS 客户端 POST `/api2/client-sso-link/`，在 Safari 打开返回的链接；回到 App 时查询状态、读取服务器签发的 API token。此模式不依赖把钉钉的浏览器 cookie 传回 Safari，也不需要修改 iOS App。

官方该流程没有传完整的 `shib_*` 设备参数。已修正原兜底逻辑把 iPhone UA 中的 “Mac OS X” 识别成 Mac 的问题：iPhone/iPad/iPod 优先识别为 iOS，合成的设备 ID 满足现有 iOS UUID 长度校验。仍为 UA 推断，不能代替原生设备标识。

用户安装版本是否使用同一路径，最终以真机请求及测试结果为准。

## 开发实现

1. 客户端 SSO 入口把目标确认页和参数存入发起端 session；每个请求独立保存，最多保留五个，避免多个登录页互相覆盖。
2. iPhone 登录页上的钉钉图标改走中转 POST，也提供明确的“在钉钉中登录客户端”按钮。桌面和普通网页登录保留原入口。
3. 服务端检查 session 中的目标与提交内容完全一致，确认客户端请求仍在等待且未过期，再生成 256 位随机中转凭据。数据库只保存 SHA-256 摘要。
4. 唤起 URL 只携带中转凭据，放在目标网页的 fragment 中；不携带客户端 token、设备参数、OAuth 授权码或用户会话。落地页不加载外部资源，读取后立即移除 fragment，通过带 CSRF 校验的 POST 领取。
5. 领取时检查原始域名/协议、请求状态和有效期，并用事务及行锁单次消费。重新生成链接会作废同一客户端尚未领取的旧链接。
6. 在钉钉自身 session 内重新发起现有 OAuth，使用该 session 的 state 校验；授权成功后进入原客户端确认页。确认页显示账号和可用的设备名，用户 POST 确认后才签发客户端 token。
7. 客户端确认使用事务和行锁，重复确认不会再次签发 token；禁用账号、超时请求被拒绝。授权取消、无效 state、网络超时和失效链接均有错误提示。OAuth 回调消费 state，日志不再输出 state 或客户端成功令牌。

默认客户端有效期仍为五分钟。未安装钉钉、浏览器禁止唤起或取消授权时，页面指引返回 App 重新发起，或返回登录页使用网页登录。

## 迁移核验

只读检查本地开发库发现：SQL 初始化部署的 `base` 迁移记录与源码中的 `base` 迁移文件不一致。之前开发的 `base.0005` 方案已移除，不能运行 `migrate base` 来安装此功能，也不能通过随意 fake 原有历史绕过。

最终模型为 `dingtalk.ClientSSOHandoff`，迁移为 `dingtalk.0001_client_sso_handoff`，没有跨 app 迁移依赖或外键；客户端引用在服务端逻辑中验证。实际开发库的 `migrate dingtalk --plan` 只包含创建该表，未执行迁移。

镜像启动脚本已接入 `migrate_dingtalk_sso()`：配置完成后、服务启动前，只运行 `migrate dingtalk --noinput`。检查显式成功标记，避免上游 seahub.sh 吞掉 Python 失败状态。失败会阻止继续启动。

## 第一步验证结果

- 独立 SQLite 内存库模拟旧 base 迁移记录：仅执行钉钉迁移、重复执行无操作、模型与迁移一致；生成 SQL 不涉及 base 表。
- 24 项实际视图测试通过（含原客户端 SSO 的 11 项回归）：真实模板渲染、CSRF、跨 session OAuth 发起、设备参数保留、用户确认前不签发 token、重复确认、重试作废旧链接、多登录页隔离、跨域拒绝、过期/已完成/已删除请求、禁用账号、授权取消和网络超时，以及原生 iOS 不带设备参数的格式校验。
- 钉钉新旧回调的 2 项兼容性测试通过，回调不直接签发客户端 token。
- 启动迁移成功及失败标记检查通过；Python 编译、shell 语法、中文 gettext 编译和 diff 空白检查通过。
- iPhone/桌面 UA 的按钮路由及 fragment 处理 JavaScript 检查通过。
- 390×844 浏览器视口下检查了中文唤起页，缺少 fragment 时显示重新发起登录的指引。此为静态页面检查，不是真机登录验收。

测试未访问真实钉钉 API、没有真实账号授权，也没有验证 MariaDB 上的并发竞争；完整后端套件和镜像冒烟尚未执行。本次没有修改业务库或重启服务。

## 下一步：测试环境构建与部署（第二步，尚未执行）

- 整理 seahub 提交、导出补丁并通过树校验；构建测试镜像，运行镜像冒烟（已接入新增中转及启动检查）。
- 本地开发环境备份后执行独立钉钉迁移，加载新代码，检查入口和错误页，提供明确的测试地址。
- 用户在 iPhone 的 Seafile App 发起 SSO，点击钉钉图标，完成钉钉授权和客户端确认，再切回 App 检查登录状态。确认前不应登录成功。
- 继续检查取消/拒绝授权、未安装钉钉、过期、重复点击、不同入口域名、桌面扫码及管理后台设备记录。
- 真机通过后才准备生产版本、发布影响和回退说明。独立新增表可以在回退应用时保留；本次不包含生产发布。

## 发布结果

- 发布提交：`ba3457d286cad5a883a3e1d9dbf93f9e03cdafd2`；源码提交：`686aad5bfb079f11cd15ad61b7f2801716bb2596`，通过补丁 0016 随主仓库发布。
- 冻结分支：`release/1.3.6`。
- [发布流水线](https://github.com/topiceyes/seafile-custom/actions/runs/42207366067) 成功；新增迁移检查、24 项中转/客户端回归及整镜像冒烟通过。
- 镜像：`ghcr.io/topiceyes/seafile-mc:1.3.6.a7ce5f47`，与 `latest` 的 digest 相同：`sha256:8e47b841ff42b9a9ef03906ca11af9ea85e16cd74ea848746de55f6cea5a7362`。
- Release 的 compose、初始化脚本、环境模板三个资产齐全；说明已包含新增迁移及尚未完成的真机验收。
- 尚未部署：下一步在测试环境加载此镜像、执行独立迁移，并由用户验证 iPhone 全链路。生产服务器本次没有执行 pull/up 或重启。

## 本地部署及 500 恢复（2026-11-06）

用户访问 `https://10.10.2.44` 反馈 500。检查确认旧 Web 进程处理 `/` 和 `/accounts/login/` 返回 500，而同容器中新进程加载当前源码时分别返回 302、200。已在本地开发环境执行以下操作，198 生产环境未修改：

- 三库迁移前快照：`/private/tmp/seafile-local-before-1.3.6-20261106-193100`，gzip 解压及 SHA256 已校验；首轮导出实际为未压缩 SQL，已保留原始 SQL 并生成正确的 gzip。
- 独立迁移 `dingtalk.0001_client_sso_handoff` 成功，系统检查通过。另保存三库与配置快照：`/private/tmp/seafile-local-before-1.3.6-20261106-193118`（迁移后），gzip 与配置归档已校验。快照仅供本地操作回退，位于临时目录，不作为长期备份。
- 加载已发布源码及中文文案。Web 重启时发现原文件服务监控进程已经退出；文件服务本身仍在，恢复标准监控脚本后成功启动 Web，未重建数据库或 Redis。
- 实际本地 HTTPS 登录页返回 200；携带局域网 Host 的 `/`、`/accounts/login/` 均返回 200；文件服务 RPC 正常。
- 真实 HTTPS 匿名探测通过客户端 SSO、中转 POST/CSRF、落地领取和 OAuth 跳转；未访问外部钉钉授权页，客户端仍为 waiting、没有签发客户端 token。

本地以源码挂载方式加载本版功能，容器基础镜像仍为官方 14.0.9，未替换成已发布 amd64 镜像。局域网入口为 `https://10.10.2.44`；现有开发证书 SAN 仅含 127.0.0.1、localhost、seafile-dev.test，尚不包含该局域网 IP。钉钉回调对本地 IP 的允许情况及真机完整登录仍需用户验证。

## 本地真机反馈：CSRF 403（2026-11-06）

iPhone 反馈中转页 403。日志明确记录落地 POST 因 Origin 为 null 被拒绝。通过无凭据的真实 WebKit 浏览器自动表单验证：`no-referrer` 会使自动 POST 带 Origin:null，`same-origin` 则保留正确的同源 Origin/Referer。

本地修正落地页 meta 和中转响应 Referrer-Policy 为 same-origin；凭据仍在 fragment 中，落地后立即移除，不加载外部资源，跨域请求不发送 Referer。没有信任 null 来源或关闭 CSRF。补充有效 CSRF token 配合 null 来源仍拒绝的测试，共 25 项通过。修正已加载到本地 Web 服务；正式 1.3.6 镜像尚未包含此后续补丁。

用户应从 Seafile App 重新发起 SSO，不能续用去掉 fragment 后的旧错误页。真机下一轮结果待确认。

## 本地登录后首页 500（2026-11-06）

用户反馈 Page unavailable。日志显示桌面浏览器完成 OAuth 回调后跳转首页，首页因 `Missing staticfiles manifest entry for frontend/static/js/runtime.10358ed3.js` 返回 500。此前匿名登录页 200 的检查没有覆盖已登录的 React 主页；本地 Webpack 索引引用的 runtime 与已有 bundle/collectstatic 清单不匹配。

已备份容器旧 build 和 webpack-stats 到 `/tmp/frontend-before-136-recovery`，从已有本地发布镜像 `seafile-mc-devbuild:1.3.5.70c7f317` 同时恢复配套 build 和 webpack-stats。已核验此镜像对应源码至当前 HEAD 的 frontend 目录无差异，本次登录改动只涉及服务端及 Django 模板。分别编译中英文 JavaScript 语言包并重新 collectstatic，重启 Web 清理旧索引缓存。

真实 React 主页模板渲染成功；47 个 Webpack 入口全部可解析；主页引用的 6 个 HTTPS 静态资源返回 200。Django 系统检查及匿名真实 HTTPS 中转链路通过。此为本地静态部署修复，不涉及生产环境，也不代表已完成 iPhone 客户端登录验收。

## 本地入口被钉钉拦截（2026-11-06）

用户明确说明：已唤起钉钉，但页面加载失败，刷新后提示网站存在风险；点击“使用系统浏览器打开”后进入钉钉网页登录页。由此确认该轮测试没有在钉钉端内继续授权，而是转回系统浏览器，不能据此认定钉钉端内 OAuth 不支持当前身份。

核对本地证书：自签发，CN=127.0.0.1，SAN 只有 127.0.0.1、localhost、seafile-dev.test，不含实际访问的 10.10.2.44。这是无效的 HTTPS 测试入口；修改 Cookie、关闭 CSRF 或仅给证书增加 IP 均不能替代有效信任链。

现有 m-disc.moresec.cn 和 i-disc.moresec.cn:7443 的登录页均通过严格 HTTPS 校验（ssl_verify_result=0）并返回 200。下一轮应使用具有有效证书和已登记 OAuth 回调的域名：升级 198 后使用现有正式域名，或为隔离测试环境准备独立域名、有效证书及 OAuth 回调。选择生产环境将涉及应用重建，不能把本地测试部署等同于生产升级。目前生产未升级，CSRF 修复尚未发布。

## 1.3.7 生产升级准备

用户已明确授权升级 198。补丁 0017 修复中转页 Referrer-Policy 导致 WebKit POST Origin:null 的问题，保留 CSRF 校验；25 项中转及客户端回归测试通过。计划先发布 1.3.7 并验证镜像冒烟，再由现有运维工具保存三库、配置及文件数据备份，按不可变镜像 tag 和已发布 digest 升级应用容器，保持数据库、Redis 与每日备份挂载。正式域名的真实钉钉授权及客户端确认由用户验收。


## 1.3.7 生产升级结果（2026-11-06 21:14 CST）

用户明确授权“上生产吧”后，198 通过现有 seafile-project-ops 完成升级：

- 版本：`ghcr.io/topiceyes/seafile-mc:1.3.7.5c0ca473`；发布提交 `e71088ec6124e49f8985cb39ceb885bc8db8a664`，源码提交 `db530b790a43b1f9cca3a07afd474d4e9de3c6f1`，补丁 0017。
- [CI 42216108812](https://github.com/topiceyes/seafile-custom/actions/runs/42216108812) 构建与整镜像冒烟成功；运行镜像与发布 digest `sha256:84e0cff75188cb4ed85489dc3befb31054c24751fe913cf1a02effa5e7f3cf2a` 一致。
- 升级前备份：`/var/lib/seafile-project-ops/backup-20261106-202455`，含三库 SQL、部署配置和完整文件数据；gzip 测试及 SHA256 校验均通过。该路径在 /home 所在数据盘，旧版本镜像及回退状态已保存。
- 应用容器已重建并返回登录页 200。MariaDB、Redis 的启动时间未变，`/shared` 与 `/shared/backup` 仍为原数据及每日备份挂载；每日备份状态检查通过。
- 启动日志确认仅执行独立钉钉中转迁移；数据库 `dingtalk.0001_client_sso_handoff` 已应用，新表存在。没有执行 `migrate base`。
- Django 检查通过；部门 196、空间 195（全部 active）、应有授权 200、已应用授权 200、授权错误 0，与升级前一致。
- React 主页真实模板可渲染，全部 Webpack 入口可解析；正式域名引用的静态资源严格 HTTPS 检查通过。
- `https://m-disc.moresec.cn` 与 `https://i-disc.moresec.cn:7443` 均通过真实匿名客户端 SSO 创建、登录入口、中转 CSRF POST、落地单次领取和正确域名 OAuth 回调跳转检查；同源 Referrer-Policy 正确，请求仍为 waiting，未签发用户 API token。

真机验收结果：生产部署后，已请用户从 iPhone Seafile App 通过正式域名重新发起 SSO，唤起钉钉授权、确认客户端登录并切回 App。用户反馈“可以登录”，据此确认本次 iPhone 客户端登录主流程通过。取消授权、未安装钉钉和过期等分支未新增真机验收结论。

回退入口（198 root）：`SSH_ORIGINAL_COMMAND=rollback /usr/local/sbin/seafile-project-ops`。当前保存的旧镜像为 1.3.5.70c7f317（配置 ID `sha256:d4a66d298906f15faff607d62c7b2d87a41d96da132af17becd02fc0d9f10804`）；回退只切换应用，保留新增中转表及业务数据。
