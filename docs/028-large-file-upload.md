# 028 - 大文件上传排查

日期：2026-11-05。状态：m-disc 关闭缓冲已通过网络复测；客户端日志及独立探测确认实际上传走 i-disc:7443，后者仍以 413 拒绝大请求。外网代理待修复，真实大文件验收未完成。

## 用户现象

入口为 `https://m-disc.moresec.cn`。客户端上传几百 MB 文件，无进度条，提示“上传失败，要不要重试”；Web 上传大文件慢。

## 已取得的证据

- 当前 198 容器运行 `1.3.1.c6fed2c4`，映射 `9800:80`。系统分区空余约 20 GiB；未取得数据卷、Nginx 临时目录所在分区及 inode 状态。
- 域名与 `http://192.168.11.198:9800` 的 `/api2/server-info/` 均为 200，核心版本 14.0.9；两者 `/seafhttp/protocol-version` 均为 200。
- 向 `/seafhttp/upload-api/00000000-0000-0000-0000-000000000000` 发送 2 MiB 请求体，使用无效令牌，不创建资料库或用户文件。客户端传输限速用于观察服务端是否提前返回，不能作为带宽测速。

| 路径 | 请求方式 | 返回 | 已发送请求体 | 首字节耗时 |
|---|---|---|---|---|
| 容器直连 9800 | Content-Length，256 KiB/s | 403，Access token not found | 65,332 B | 0.254 s |
| m-disc 域名 | Content-Length，256 KiB/s | 502 | 2,097,152 B（全部） | 8.853 s |
| 容器直连 9800 | chunked，256 KiB/s | 403，Access token not found | 135,905 B | 0.702 s |
| m-disc 域名复测 | Content-Length，512 KiB/s | 403，Access token not found | 2,097,152 B（全部） | 4.030 s |

域名小请求可以返回预期的 403。502 只在一次探测中出现，不能描述为稳定复现的大小限制。

**判断：域名代理与容器直连存在明显的请求体处理差异，符合代理先接收完整请求体再转发的缓冲行为。** 需要实际 Nginx 配置和失败时的 error log 确认。无效令牌探测不能替代真实客户端的有效上传，也不能证明几百 MB 失败的全部原因。

仓库内生产和开发 Nginx 的 `/seafhttp` 已有 `client_max_body_size 0`、`proxy_request_buffering off`、`proxy_buffering off`。容器内配置不会改变宝塔或其他外层代理的行为。

## 用户提供的宝塔配置

实际站点通过 `location ^~ /` 转发至 `http://127.0.0.1:9800`；其中已有 `proxy_http_version 1.1`，连接超时 60s、发送和读取超时 600s。该块没有 `proxy_request_buffering`、`proxy_buffering` 或 `client_max_body_size`，会继承上层设置；未显式配置时，Nginx 默认启用请求缓冲。外部探测观察到了先接收完整请求再返回的行为。

站点存在 extension include，因此不能仅凭这一份文本判定上层请求大小限制的具体值。没有失败时间对应日志，尚不能确定单次 502 或实际几百 MB 上传失败的直接原因。

## 代理修改

准备好的宿主机配置：[seafhttp-proxy.conf.example](../deploy/nginx/seafhttp-proxy.conf.example)。插入对应 server 的 `#PROXY-CONF-START` 后、现有 `location ^~ /` 前。新增的 `location ^~ /seafhttp` 是更长的前缀，覆盖文件服务路径；原根 location 继续承接其他请求。它转发到当前 198 的容器端口 9800，保留 `/seafhttp` 前缀；容器 Nginx 自己负责去掉前缀后转发到文件服务 8082。

重点是每一层实际命中的代理 location 都要关闭请求缓冲、允许所需请求大小，并为 chunked 请求显式使用 HTTP/1.1。只增加 `proxy_read_timeout` 或只修改镜像内配置，不会消除外层请求缓冲。

Nginx 的 `proxy_buffering` 管响应，`proxy_request_buffering` 管上传请求体，两者不能互相替代。依据：[Nginx 请求缓冲文档](https://nginx.org/en/docs/http/ngx_http_proxy_module.html#proxy_request_buffering)、[Seafile 大文件上传说明](https://manual.seafile.com/13.0/setup_binary/https_with_nginx/#large-file-uploads)。

## 继续定位与验收

现有项目 SSH 密钥由 forced-command 入口限制，仅开放固定运维动作，不提供任意 Shell、代理配置或上传日志读取。需要服务器管理员提供：

1. 主站点配置已收到。若专用 location 生效后仍失败，再核对其 include 的配置和其他代理层，重点为大小限制、缓冲、超时及限速设置。
2. 失败时间附近站点 Nginx 的 error log、access log 中 `/seafhttp` 请求的状态；容器 `/shared/seafile/logs/seafhttp.error.log`、文件服务日志中的对应记录。不要提供 TLS 私钥或上传链接令牌。
3. 如出现临时文件或空间错误，再核对 `client_body_temp_path`、数据卷所在分区的空间、inode 和写入权限。

实际修改前保留相关站点配置备份；用宝塔所运行的 Nginx 执行 `-t` 通过后再 reload。复测同一有效文件的客户端上传和 Web 上传，确认完成、大小及下载内容一致，并核对无对应 413、499、502、504 或临时文件写入错误。文件令牌探测只用于观察请求处理方式，不作为修复完成的依据。

本地验证：已将新增 location 与原有 `location ^~ /` 放入同一 server，用本地 `nginx:1.27-alpine` 临时容器执行 `nginx -t`，语法检查通过。此检查不包含生产的证书、扩展 include 或实际上传。

按用户要求另提供完整覆盖版：[m-disc.moresec.cn.conf.example](../deploy/nginx/m-disc.moresec.cn.conf.example)。保留原站点的证书路径、HTTP/2、HTTP/3、宝塔标记、根代理和日志设置，新增文件服务专用 location。完整文件也已在本地 Nginx 1.27.5 中通过 `nginx -t`；验证使用临时证书及空 include，不代表生产证书、include 或实际上传已验证。

## 配置应用后的客户端继续失败：实际入口为 i-disc:7443

已读取本机 Seafile Client 9.0.21 的 `~/.ccnet/logs/applet.log`。13:11:49 的手动上传文件大小为 321,670,659 B，实际请求为 `https://i-disc.moresec.cn:7443/seafhttp/upload-api/[令牌已隐去]`，反复返回 413。此前 885,971,535 B 文件同样返回 413；76,163 B 的小图片在同一资料库上传成功。这里是客户端文件浏览器的手动上传，直接使用 upload-api，不能套用同步守护进程的分块上传流程。

m-disc 配置应用后，同一 2 MiB、256 KiB/s 的无效令牌探测约 0.499 秒即返回 403，仅发送 130,870 B，证明此前观察到的整包缓冲差异已消失。

进一步使用相同路径、声明 `Content-Length: 321670659` 和 `Expect: 100-continue`，仅发送请求头，不发送任何文件内容：

| 入口 | 首个响应 |
|---|---|
| m-disc.moresec.cn:443 | 100 Continue |
| 192.168.11.198:9800 | 100 Continue |
| i-disc.moresec.cn:7443 | **413 Request Entity Too Large** |

这将当前失败定位到 **i-disc:7443 链路的请求大小限制**，不是客户端协议不兼容的证据。小请求在外网入口能够到达文件服务，不代表大文件被允许。此前对不带端口的 i-disc:443 的证书/404 探测不适用于实际 7443 入口；7443 的 server-info 为 200 且证书校验通过。

需核对 i-disc:7443 的实际 Nginx server/location 配置，给文件上传路径配置 `client_max_body_size 0`、关闭请求缓冲，并检查后续各层限制。不能直接将 m-disc 的完整配置覆盖到外网代理：域名、监听端口、证书及 upstream 都可能不同。

另一个需要核对的产品行为是：源码中 `gen_file_upload_url()` 通过 `get_fileserver_root()` 从全局 SERVICE_URL 生成绝对地址，客户端登录入口并不保证等于上传入口。内外网需同时使用时，应修复外网入口；直接把全局 Site URL 改为内网域名会影响外网用户，不作为默认处理。

用户进一步明确此次不处理外网入口，要求内网访问的文件流量留在内网。已将上述全局地址派生确认为二开设计缺陷，修复及回归见 [029](029-request-origin-file-transfers.md)。修复尚未发布部署。
