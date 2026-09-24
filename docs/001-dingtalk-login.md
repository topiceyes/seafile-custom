# 001 - 钉钉扫码登录

> 完成日期：2026-09-16 ｜ 分支：`seahub/dev-dingtalk` ｜ 状态：已上线验证

> ⚠️ **2026-09-17 更新**：站点已由 HTTP 全面转为 **HTTPS**（见 [006](006-https-setup.md)）。
> 本文中所有 `http://127.0.0.1:8180` / `http://seafile-dev.test` 的地址**均已失效**，请一律替换为 `https://127.0.0.1`；
> 钉钉后台的回调域名也需同步改为 `https://127.0.0.1/dingtalk/callback/`。下文保留当时的原始记录。

> ⚠️ **2026-09-24 更新（第 0010 补丁，tag `12.0.14-dingtalk.10.*` 起）**：`redirect_uri`
> 不再取 SERVICE_URL，改为**跟随用户发起登录的域名**（`request.scheme + request.get_host()`，
> 四处构造点统一走 `get_request_scheme_and_netloc()`）。同一系统经多个域名访问
> （内网域名 + 外网云反代域名）从此都能扫码登录，配置见 §8。

## 1. 需求

企业用户在 Seafile 登录页点击钉钉图标 → 跳转钉钉扫码 → 确认后自动登录 Seafile：

- 首次登录**自动创建** Seafile 账号（虚拟 ID 用户，昵称取钉钉昵称）
- 钉钉身份与 Seafile 账号持久绑定，后续扫码直接登录
- 已登录用户可在「设置 → SSO」里解绑/重新绑定钉钉

## 2. 关键发现：功能本来就内置，只是被 Pro 门槛锁住

seahub 代码库**自带完整的钉钉登录模块** `seahub/dingtalk/`，包含：

| 能力 | 位置 |
|---|---|
| 新版 OAuth2 流程（≥10.0） | `seahub/dingtalk/views.py` 的 `dingtalk_login_new` / `dingtalk_callback_new` |
| 旧版扫码（≤9.0，未用） | 同文件上半部分 |
| 账号绑定/解绑 | `dingtalk_connect(_callback)` / `dingtalk_disconnect` |
| 登录页图标 | `seahub/templates/registration/login.html`（由 context_processors 注入 `enable_dingtalk`） |
| 设置页绑定 UI（React） | `frontend/src/pages/settings/social-login-dingtalk/` |
| 配置项 | `seahub/dingtalk/settings.py` |

社区版唯一障碍是 `seahub/dingtalk/settings.py:7`：

```python
ENABLE_DINGTALK = getattr(settings, 'ENABLE_DINGTALK', False) and is_pro_version()
```

**本功能的实质 = 解除 Pro 门槛（一行）+ 建立源码挂载机制 + 配置钉钉应用**，零新业务代码。

## 3. 认证流程（代码即此逻辑）

```
浏览器                          Seafile(django)                      钉钉
  │ 点击登录页钉钉图标                 │                                │
  │ GET /dingtalk/login/  ──────────▶│ 生成 state(uuid) 存 session      │
  │◀── 302 ─────────────────────────│                                │
  │ GET login.dingtalk.com/oauth2/auth?client_id=AppKey              │
  │   &redirect_uri={site}/dingtalk/callback/&scope=openid ──────────▶│
  │   ...用户扫码确认...                                              │
  │◀── 302 redirect_uri?authCode=xxx&state=xxx ───────────────────────│
  │ GET /dingtalk/callback/ ────────▶│ 校验 state == session           │
  │                                 │ POST api.dingtalk.com/v1.0/oauth2/userAccessToken
  │                                 │   {clientId, clientSecret, code, grantType}
  │                                 │ GET api.dingtalk.com/v1.0/contact/users/me
  │                                 │   header: x-acs-dingtalk-access-token
  │                                 │   → unionId / nick / mobile ...
  │                                 │ 查 social_auth_usersocialauth(dingtalk, unionId)
  │                                 │   未绑定 → OauthRemoteUserBackend 自动建号
  │                                 │   + SocialAuthUser.add(username,'dingtalk',unionId)
  │                                 │ auth.login() 发 session + seahub_auth cookie
  │◀── 302 首页（已登录）────────────│                                │
```

## 4. 实现内容

### 4.1 代码改动（2 个 commit，`seahub/dev-dingtalk` 分支）

**commit `82dfab8` — Enable DingTalk login in community edition**

`seahub/dingtalk/settings.py` 去掉 `and is_pro_version()`：

```python
# [dev] 去掉社区版的 pro 门槛，允许社区版启用钉钉登录
ENABLE_DINGTALK = getattr(settings, 'ENABLE_DINGTALK', False)
```

**commit `bc6529d` — Provide SEAFILE_VERSION for source-mounted deployment**

`seahub/settings.py` 尾部补：

```python
SEAFILE_VERSION = "12.0.14-dev"
```

原因：官方发布构建时才往 settings.py 注入这个变量，`seahub/base/context_processors.py:20` 直接 `from seahub.settings import SEAFILE_VERSION`，源码挂载运行时缺失会 ImportError 导致 seahub 起不来。

### 4.2 源码基线对齐

- 容器运行 **12.0.14**（Django 4.2），宿主机原克隆是 master（13.x 线，Django 5.2）——**不兼容**
- 12.0.14 无 git tag，采用 `origin/12.0` 维护分支 HEAD（0877ad7）为基线建 `dev-dingtalk` 分支
- 校验方法：容器内与 git 树逐文件 md5 对比（675 个 .py，30 个差异 = 12.0.14 之后的 bugfix + settings.py 一行版本注入，dingtalk 模块逐字节一致，无 migration 差异）

### 4.3 部署配置

`deploy/seafile-server.yml`（seafile 服务）：

```yaml
volumes:
  - ${SEAFILE_VOLUME}:/shared
  # 只挂 Python 包目录！容器 seahub/thirdpart/ 是 pip 已装依赖（含 gunicorn）
  - ../seahub/seahub:/opt/seafile/seafile-server-12.0.14/seahub/seahub
ports:
  - "8180:80"
  - "80:80"     # 供 http://seafile-dev.test（钉钉回调域名走 80）
```

`deploy/seafile-data/seafile/conf/seahub_settings.py`：

```python
ENABLE_DINGTALK = True
DINGTALK_APP_KEY = '<AppKey>'
DINGTALK_APP_SECRET = '<AppSecret>'
SERVICE_URL = 'http://seafile-dev.test'   # 或 http://127.0.0.1:8180
FILE_SERVER_ROOT = 'http://seafile-dev.test/seafhttp'
```

### 4.4 钉钉开放平台配置

- 应用类型：**企业内部应用**，取 AppKey/AppSecret
- **安全设置 → 回调域名**：必须是**完整 URL（带协议头）**，如 `https://127.0.0.1`（转 HTTPS 前的写法是 `http://127.0.0.1:8180`）
- **权限管理 → 开通「通讯录个人信息读权限」（`Contact.User.Read`）**——扫码后取用户信息必需
- ⚠️ 权限变更必须**发布应用新版本**才生效
- 本地开发若回调走域名：`/etc/hosts` 加 `127.0.0.1 seafile-dev.test`，compose 已绑 80 端口

## 5. 踩坑记录（按时间序）

| # | 坑 | 解法 |
|---|---|---|
| 1 | 镜像名 `seafileltd/seafile` 不存在 | 正确为 `seafileltd/seafile-mc:12.0-latest` |
| 2 | 初始化报 `localhost is not a valid ip or domain` | `SEAFILE_SERVER_HOSTNAME` 用 `127.0.0.1:8180` |
| 3 | Seafile 12 启动报 `.env file not found`（JWT_PRIVATE_KEY） | compose 传 `JWT_PRIVATE_KEY` 环境变量（openssl rand -base64 48 生成） |
| 4 | 镜像不认 `SEAFILE_ADMIN_EMAIL/PASSWORD`，自建 `me@example.com`+随机密码 | `printf "邮箱\n密码\n密码\n" \| docker exec -i seafile .../reset-admin.sh` 重置 |
| 5 | 手工 Django `create_superuser` 建出 `uuid@auth.local` 且触发 `DuplicatedContactEmailError` | Seafile 12 用户机制：登录凭证在 `ccnet_db.EmailUser`（内部名 uuid@auth.local），邮箱在 `seahub_db.profile_profile.contact_email`，登录输入邮箱即可 |
| 6 | 宿主机 master 源码 ≠ 容器 12.0.14（Django 5.2 vs 4.2、依赖栈、migration 均不同） | 基于 `origin/12.0` 分支建二开分支，挂载前逐文件 md5 校验 |
| 7 | 挂载源码后 seahub 起不来（ImportError SEAFILE_VERSION） | settings.py 手动补 `SEAFILE_VERSION`（见 4.1） |
| 8 | 钉钉回调域名校验：必须完整 URL 带 `http://`，纯 IP:端口/裸域名都会被拒 | 填 `http://127.0.0.1:8180`；若被拒用 `http://seafile-dev.test` + hosts + 80 端口 |
| 9 | 扫码后「出错了请联系管理员」：`AccessTokenPermissionDenied, requiredScopes: [Contact.User.Read]` | 钉钉后台开权限 + **发布新版本** |
| 10 | 首次扫码 `invalid state` | 正常现象：换访问域名后浏览器旧 session 里的 state 失效，重扫即可 |
| 11 | 扫码后必现「出错了，请联系管理员」，日志 `invalid state` | （2026-09-24 前的机制）**访问域名与 SERVICE_URL 不一致**：钉钉按 SERVICE_URL 回调，session cookie 绑在访问域上 → 跨域丢失 → state 校验失败。**0010 补丁起已根治**：回调跟随发起域名，host 不一致不再导致 state 丢失；仍出现时查会话/cookie（无痕窗口、禁 cookie、会话过期）。诊断日志打印 `got/expected/host` |

## 6. 运维手册

```bash
# 改 seahub Python 代码后生效（不需要重建容器）
docker exec seafile /opt/seafile/seafile-server-latest/seahub.sh restart

# 应用日志（钉钉登录错误在这里）
tail -f deploy/seafile-data/seafile/logs/seahub.log

# 核验登录落库（用户/绑定/资料）
docker exec seafile-mysql mariadb -uroot -p'dev_root_pw_2026' -e "
select email,is_staff,is_active from ccnet_db.EmailUser;
select username,provider,left(uid,12) from seahub_db.social_auth_usersocialauth;
select user,nickname,contact_email from seahub_db.profile_profile;"

# 解绑某用户的钉钉
docker exec seafile-mysql mariadb -uroot -p'dev_root_pw_2026' \
  -e "delete from seahub_db.social_auth_usersocialauth where provider='dingtalk' and username='<虚拟ID>';"
```

## 7. 遗留事项

- **contact_email 未同步**：要把钉钉企业邮箱写入 Seafile，需再开通「通讯录部门成员读权限」（代码路径 `dingtalk_get_userid_by_unionid_new` → `dingtalk_get_detailed_user_info_new`，失败仅记日志不影响登录）
- **绕过 2FA**：钉钉扫码登录（及所有 OAuth 类登录）不走 seahub 双因素认证，企业安全评估需知悉
- **上游同步成本**：`dingtalk/settings.py` 一行 diff 是永久性的，升级 seahub 版本时注意保留
- 旧版扫码协议（`DINGTALK_QR_CONNECT_*` 配置组）未使用，忽略即可

## 8. 多入口部署：一个系统、多个域名都扫码登录（2026-09-24，0010 补丁）

生产形态：内网用户走 `m-disc.moresec.cn`（宿主反代直入），外网用户走
`i-disc.moresec.cn`（云服务器反代 → 公司出口 IP 端口映射）。SERVICE_URL 只有一个
（链接生成的规范地址），但**扫码登录哪个入口都能用**——机制：

- `redirect_uri` 跟随**发起请求的域名**（`get_request_scheme_and_netloc(request)`），
  回调与发起同域，state 所在的会话 cookie（按 host 隔离）自然可读；
- 登录完成后的跳转是相对路径，用户全程留在原入口；
- 钉钉后台「登录与分享 → 回调域名」**支持配多个**（英文逗号分隔），每个入口
  各登记一条。

**配置（一次性）：**

1. 钉钉开发者后台 → 应用 → 登录与分享 → 回调域名：

   ```
   https://m-disc.moresec.cn/dingtalk/callback/,https://i-disc.moresec.cn/dingtalk/callback/
   ```

   （逗号分隔、不要空格；两个地址都要在。）
2. Site URL（SERVICE_URL）保持主域名（`https://m-disc.moresec.cn`）不动——它管的是
   邮件/分享链接等**规范地址**，不再影响扫码登录。
3. **外网链路的协议头要传对**：云代理必须发 `X-Forwarded-Proto: https`，且沿途
   任何中间层（宿主 nginx/宝塔）**不要用 `$scheme` 覆盖它**——云→公司这段通常是
   明文 http，中间层若写 `proxy_set_header X-Forwarded-Proto $scheme` 会把它冲成
   http，redirect_uri 就成了 `http://i-disc…`，与钉钉后台登记的 https 地址不匹配，
   钉钉会在授权页直接拒绝。验证一条命令（外网机器上）：

   ```bash
   curl -s -o /dev/null -w '%{redirect_url}\n' https://i-disc.moresec.cn/dingtalk/login/
   # 期望 Location 里的 redirect_uri=https%3A%2F%2Fi-disc.moresec.cn%2Fdingtalk%2Fcallback%2F
   ```

**边界与已知限制：**

- 文件上传/下载的绝对链接（FILE_SERVER_ROOT）仍从 SERVICE_URL 派生（单值），
  外网入口的网页文件链接会指向主域名——若外网解析不了主域名，这是下一个要处理
  的事项（可改用相对形式 `/seafhttp`，届时单独验证）。
- 彩排断言：`rehearsal-rp.sh` 步骤 9b（D1/D2 双 Host 探针）钉住「回调跟随发起域名」。
