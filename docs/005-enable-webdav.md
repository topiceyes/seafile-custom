# 005 - 启用 WebDAV (SeafDAV)

> 完成日期：2026-09-17 ｜ 状态：已上线验证

## 1. 问题

访问 `http://127.0.0.1:8180/seafdav/` 报 **502 Bad Gateway**。

## 2. 根因

官方 Docker 镜像默认**关闭** WebDAV：

```
# deploy/seafile-data/seafile/conf/seafdav.conf
[WEBDAV]
enabled = false      # ← 默认值
port = 8080
share_name = /seafdav
```

服务未启动 → 8080 端口无监听 → nginx `location /seafdav/` 转发失败 → 502。

## 3. 修复

```bash
# 宿主机编辑（数据卷内，容器重建不丢）
sed -i '' 's/^enabled = false/enabled = true/' \
  deploy/seafile-data/seafile/conf/seafdav.conf

# 重启 seafile 服务（注意：不是 seahub.sh）
docker exec seafile /opt/seafile/seafile-server-latest/seafile.sh restart
```

启动后 `seafile-monitor.sh` 会持续守护 seafdav 进程（`wsgidav.server.server_cli`）。

## 4. 验证

| 检查 | 结果 |
|---|---|
| 进程 | ✅ wsgidav 运行，8080 监听 |
| 未认证 `GET /seafdav/` | ✅ 401 |
| 认证 `GET /seafdav/` | ✅ 200 |
| 认证 `PROPFIND`（目录列表） | ✅ 207 Multi-Status，标准 WebDAV XML |

## 5. 使用

客户端（Finder / Windows 资源管理器 / rclone / Cyberduck）：

- 地址：`https://127.0.0.1/seafdav/`（站点已转 HTTPS，见 006 文档；原 `http://127.0.0.1:8180` 会 301 跳转）
- 账号：Seafile 登录邮箱 + 密码（如 `dev@local.test` / `dev123456`）
- 也可在「设置 → WebDAV 密码」生成专用密码（不暴露登录密码）

命令行验证：
```bash
curl -k -X PROPFIND -u "dev@local.test:dev123456" -H "Depth: 1" https://127.0.0.1/seafdav/
```

> WebDAV 客户端连自签证书需先把 `deploy/seafile-data/ssl/127.0.0.1.crt` 导入系统信任，或临时关闭证书校验。

## 6. 注意

- `seafdav.conf` 在 `/shared` 卷内（`deploy/seafile-data/seafile/conf/`），容器重建后配置保留
- 修改后必须重启 **seafile 服务**（`seafile.sh restart`），只重启 seahub 不生效
- 生产环境建议走 HTTPS，否则 WebDAV 凭据以明文传输
