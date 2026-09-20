# 008 - 密码登录仅限管理员

> 完成日期：2026-09-20 ｜ 补丁：`patches/0008` ｜ 状态：dev 已验证，随生产镜像上线

## 1. 需求

生产环境钉钉扫码是普通用户的唯一登录入口后，密码登录成为唯一能**绕过钉钉、绕过离职自动禁用**的口子（离职员工只要知道密码仍可登录）。因此：**除管理员外，禁止所有密码登录**。

此前在开发环境阶段用户曾要求此功能但因「先不做」推迟，本次生产部署一并落地。

## 2. 设计：双层拦截

开关 `PASSWORD_LOGIN_ADMIN_ONLY`（`seahub/settings.py` 定义，默认 `True`；渲染进 seahub_settings.py，可改）。

### 2.1 表单层（用户看到的提示）

`seahub/seahub/auth/forms.py` 的 `AuthenticationForm.clean()`：在密码校验**之前**、账号存在性检查之后拦截：

```python
if settings.PASSWORD_LOGIN_ADMIN_ONLY and not user.is_staff:
    self.db_record = False   # 策略拒绝不算登录失败（不触发验证码/冻结）
    raise forms.ValidationError('账号密码登录仅对管理员开放，请使用钉钉扫码登录。')
```

配套改登录模板 `templates/registration/login.html`：模板对错误键有精确的 elif 链，加了 `form.errors.password_login_admin_only` 分支展示中文提示（否则落入 generic 的「Incorrect email or password」）。

**注意**：拦截在密码校验前，所以非管理员输错密码也得到同样的中文提示——这是有意的（不向攻击者泄露「密码是否正确」的信息）。

### 2.2 Backend 层（兜底 API 通道）

`seahub/seahub/base/accounts.py` 的 `AuthBackend.authenticate()`：在 `check_password` 成功**之后**拦截并 `return None`，同时记 warning 日志。

兜住绕过表单直接调 `authenticate(username, password)` 的路径——主要是 `POST /api2/auth-token/`（客户端密码换 token 的 API）。

放在密码校验之后：密码错误时行为与报错时序完全不变。

## 3. 影响面（逐条核实过代码路径）

| 通道 | 影响 | 原因 |
|---|---|---|
| Web 密码登录（非管理员） | ❌ 拦截，中文提示 | 表单层 |
| Web 密码登录（管理员 is_staff） | ✅ 正常 | `not user.is_staff` 才拦 |
| `/api2/auth-token/`（非管理员） | ❌ 400 | backend 层兜底 |
| 钉钉扫码 SSO | ✅ 不受影响 | `OauthRemoteUserBackend` 的 `authenticate(remote_user=...)` 签名不同，不经过密码 backend |
| 已签发的 API token / 既有会话 | ✅ 不受影响 | `TokenAuthentication` 只查 Token 表 |
| 桌面/移动端 client-SSO | ✅ 不受影响 | 本地浏览器登录流程，token 由钉钉回调签发 |
| WebDAV basic auth | ✅ 不拦（有意） | seafdav 走 ccnet RPC 验证，不经 Django backend；文件协议密码在设置里单独生成；离职用户已被 0006 置 inactive，seafdav 同样拒绝 |
| 不存在的用户 | ✅ generic 报错 | 不引入账号枚举差异 |

## 4. dev 验证矩阵（全过）

| # | 场景 | 结果 |
|---|---|---|
| 1 | 非管理员正确密码（表单层） | ✅ `password_login_admin_only` 错误 + 中文消息，`db_record=False` |
| 2 | 非管理员错误密码 | ✅ 同样中文提示（设计如此，见 2.1 注） |
| 2b | 管理员错误密码 / 不存在的用户 | ✅ generic 报错（路径未变） |
| 3 | 管理员密码登录 | ✅ 成功（HTTP 302） |
| 4 | API：非管理员 / 管理员 | ✅ 400 / 200+token |
| 5 | 钉钉入口 `/dingtalk-sso/` | ✅ 302 正常（扫码全流程在生产验证） |
| 7 | 开关关闭（conf 设 False + restart） | ✅ 非管理员可密码登录；恢复后重新拦截 |
| 8 | WebDAV 未认证 PROPFIND | ✅ 401 不变 |

## 5. 紧急放开

```bash
# seahub_settings.py 里改（或追加）：
#   PASSWORD_LOGIN_ADMIN_ONLY = False
docker exec seafile /opt/seafile/seafile-server-latest/seahub.sh restart
```

## 6. 踩坑记录

- **登录模板的 elif 链**：`login.html` 按错误键精确分支渲染，自定义错误键必须加对应分支，否则永远显示 generic 报错。
- **curl 测登录表单会被验证码挡**：连续失败 5 次后 view 切换到 `CaptchaAuthenticationForm`，curl 没填 captcha 字段会得到「This field is required」，看似拦截逻辑失效。表单层测试用 Django shell 直接构造 form 更可靠。
- **bash 变量名后跟全角字符**：`$SAN）` 会把 `）` 的多字节序列并进变量名解析（set -u 报 unbound），要写 `${SAN}）`。
