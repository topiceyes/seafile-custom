# 006 - 全站 HTTPS（自签证书）

> 完成日期：2026-09-17 ｜ 状态：已上线验证

## 1. 需求

**客户端（桌面 / 移动端）单点登录必须走 HTTPS**——Seafile 客户端的本地浏览器 SSO 流程对回调地址有安全要求，HTTP 站点无法完成登录。因此本地开发环境也需要一套 TLS。

## 2. 方案

自签证书 + 手写 nginx 配置。**端口 443 为唯一入口，80 永久 301 跳转。**

### 2.1 为什么不用官方 letsencrypt 流程

镜像自带的 `ssl.sh` / `init_letsencrypt()` 有两个硬伤：

1. **无法为 IP 签发**——Let's Encrypt 不给 IP 地址发证书，`SEAFILE_SERVER_LETSENCRYPT=true` 会注册一个注定失败的续期 cron，日志持续报错。
2. **模板的 `https` 开关只认 `SEAFILE_SERVER_LETSENCRYPT`**，不认 `SEAFILE_SERVER_PROTOCOL`。所以即使设了 `SEAFILE_SERVER_PROTOCOL=https`，容器重新生成的 nginx 配置**仍然只有 `listen 80`**。

### 2.2 为什么手写配置能持久

容器启动脚本 `generate_local_nginx_conf()` **只在文件不存在时才渲染模板**。因此手写一份 `seafile.nginx.conf` 后，容器重建也不会被覆盖。

> ⚠️ 代价：升级 Seafile 镜像版本时，需人工比对官方模板（`/templates/seafile.nginx.conf.template`）同步新 location。

## 3. 实施

### 3.1 生成自签证书

```bash
openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
  -keyout deploy/seafile-data/ssl/127.0.0.1.key \
  -out    deploy/seafile-data/ssl/127.0.0.1.crt \
  -subj "/CN=127.0.0.1" \
  -addext "subjectAltName=IP:127.0.0.1,DNS:localhost,DNS:seafile-dev.test"
```

| 项 | 值 |
|---|---|
| CN | `127.0.0.1` |
| SAN | `IP:127.0.0.1`, `DNS:localhost`, `DNS:seafile-dev.test` |
| 有效期 | 3650 天（至 2036-09-14） |

`ssl/` 目录位于 `/shared` 卷内，容器重建不丢。

### 3.2 compose 改动

`deploy/seafile-server.yml`：

```yaml
ports:
  - "443:443"      # HTTPS 主入口
  - "80:80"        # 301 → https://127.0.0.1
  - "8180:80"      # 保留（落在 80 上，同样会被 301）
environment:
  - SEAFILE_SERVER_HOSTNAME=127.0.0.1   # 不能带端口，否则回调地址带端口
  - SEAFILE_SERVER_PROTOCOL=https
```

### 3.3 nginx 配置

`deploy/seafile-data/nginx/conf/seafile.nginx.conf`（手写，两道 server 块）：

```nginx
server {
    listen 80;
    server_name _ default_server;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name 127.0.0.1;
    ssl_certificate      /shared/ssl/127.0.0.1.crt;
    ssl_certificate_key  /shared/ssl/127.0.0.1.key;
    ssl_protocols        TLSv1.2 TLSv1.3;
    # ... 原有 location 全量保留（/、/seafhttp、/notification、/seafdav/、/:dir_browser、/media）
}
```

相比官方模板额外加了 `proxy_set_header X-Forwarded-Proto $scheme;`（`/` 和 `/seafdav/`），让后端能识别原始协议。

### 3.4 seahub_settings.py

```python
SERVICE_URL = "https://127.0.0.1"
FILE_SERVER_ROOT = 'https://127.0.0.1/seafhttp'
CLIENT_SSO_VIA_LOCAL_BROWSER = True   # 必须写在文件里：URL 注册发生模块导入期，constance 动态开关管不到
```

> `SEAFILE_SERVER_HOSTNAME` / `SEAFILE_SERVER_PROTOCOL` 环境变量会**覆盖** `SERVICE_URL`（见 `seahub/settings.py:1172`），两处必须一致。

## 4. 验证

| 检查 | 结果 |
|---|---|
| `nginx -t` | ✅ successful |
| `GET https://127.0.0.1/` | ✅ 200，页面标题正常 |
| `GET http://127.0.0.1/` | ✅ 301 → `https://127.0.0.1/accounts/login/` |
| 证书 | ✅ CN/SAN 匹配，TLSv1.2+1.3 |
| `SERVICE_URL` / `FILE_SERVER_ROOT` | ✅ 均为 `https://127.0.0.1` |
| 客户端 SSO 入口 `/client-sso/<token>/` | ✅ 302 → `https://127.0.0.1/accounts/login/?next=...` |
| WebDAV `PROPFIND https://127.0.0.1/seafdav/` | ✅ 401（未认证即为正常） |

## 5. 副作用与后续动作

### 5.1 钉钉回调地址已变更（**必须处理**）

SERVICE_URL 从 `http://127.0.0.1:8180` 变为 `https://127.0.0.1`，钉钉授权请求里的 `redirect_uri` 随之改变：

```
旧：http://127.0.0.1:8180/dingtalk/callback/
新：https://127.0.0.1/dingtalk/callback/    ← 已实测确认
```

**需要在钉钉开发者后台把「回调域名」同步更新为上面的新地址**，否则扫码登录会在回调环节报错。

### 5.2 客户端信任自签证书

自签证书不被系统信任，客户端首次连接会报证书错误。开发环境可选择：

- 将 `deploy/seafile-data/ssl/127.0.0.1.crt` 导入系统钥匙串并设为「始终信任」（macOS：钥匙串访问 → 系统 → 拖入 crt → 信任 → 始终信任）
- 或客户端设置里关闭证书校验（仅限开发）

浏览器访问 `https://127.0.0.1/` 会提示"不安全"，点「继续前往」即可。

### 5.3 其他

- 原 `http://127.0.0.1:8180` 入口保留，但会 301 到 https
- WebDAV 客户端地址改为 `https://127.0.0.1/seafdav/`（见 005 文档）
- 生产环境请换正式 CA 证书，不要沿用本方案的自签证书

## 6. 关键文件

| 文件 | 说明 |
|---|---|
| `deploy/seafile-data/ssl/127.0.0.1.crt` / `.key` | 自签证书（`/shared/ssl/`） |
| `deploy/seafile-data/nginx/conf/seafile.nginx.conf` | 手写 HTTPS 配置（不会被容器覆盖） |
| `deploy/seafile-server.yml` | 端口 443/80 + 协议环境变量 |
| `deploy/seafile-data/seafile/conf/seahub_settings.py` | `SERVICE_URL` 等 |

## 7. 回退

删除 `deploy/seafile-data/nginx/conf/seafile.nginx.conf` 并重建容器，会重新生成官方 HTTP-only 模板；同时把 compose 的环境变量改回 `SEAFILE_SERVER_HOSTNAME=127.0.0.1:8180`、去掉 `SEAFILE_SERVER_PROTOCOL`，并改回 `SERVICE_URL` / `FILE_SERVER_ROOT` 为 http。
