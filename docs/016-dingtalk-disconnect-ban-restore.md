# 016 - 恢复 0005 钉钉解绑禁令（产品 1.2.2）

> 完成日期：2026-10-28 ｜ 状态：1.2.2 已发布并灰度验证
> 起因：用户发现设置页仍有 Disconnect 按钮，质疑 0005（docs/003 禁解绑）是否失效。

## 1. 结论先行

**用户没记错，是真 bug：0005 在 13.0.28 补丁重放（204aea5e）时前后端两处防线就都没打上，
141/198 从 1.1.x 起裸奔至今。** 14.0 重放（cd12d4b9）原样继承了 13.0 的遗漏。

| 防线 | 12.0（0005 原始提交 81071d53） | 13.0 重放 | 14.0 现状（修复前） |
|---|---|---|---|
| 后端 `dingtalk_disconnect` | 视图顶 `return render_error` 硬拦 | 上游原始实现 | 上游原始实现 |
| 前端 Disconnect 按钮 | 已绑定态换状态文本（components/user-settings/…） | 文件被上游重构，改动未随迁 | 上游迁至 `pages/settings/social-login-dingtalk/index.js`，**带活按钮** |

后果链（生产可触发）：点 Disconnect → 真删 `SocialAuthUser` 绑定（virtual id 用户还删
Profile 联系邮箱）→ 再扫码时 `create_unknown_user` 建**全新空账号**，旧账号数据"消失"。

## 2. 修复（补丁 0013）

- **后端** `seahub/dingtalk/views.py` `dingtalk_disconnect`：视图入口恢复 0005 硬拦，
  原逻辑留不可达（回退=删一行 return）。
- **前端** `frontend/src/pages/settings/social-login-dingtalk/index.js`：已绑定态渲染
  「已连接（如需更换请联系管理员）」状态文本，Disconnect 按钮与确认弹窗整体移除
  （bundle 里 `dingtalk/disconnect` 零残留；残留的 `confirmDisconnect` 属企业微信组件，非本面）。
- **顺手修**：`deploy/rebuild-frontend.sh` 的 INSTALL_PATH 硬编码 `seafile-server-12.0.14`
  改走 `seafile-server-latest`——与 dingtalk-sync cron 同款病，本次宿主前端重建实际踩到
  （docker cp 进了一个不存在的路径）。

## 3. 0001-0010 存在性审计（本 bug 的结构性教训）

docs/014 §3.3 的语义复测只做了 0008/0009 的**对撞**复测，没核对每个补丁的**存在性**，
0005 因此漏网。本次逐补丁核对（grep 语义标记 → 树中确认）：

| 补丁 | 核对标记 | 结果 |
|---|---|---|
| 0001 钉钉登录核心 | `dingtalk_login_new`/`is_dingtalk_enabled` 全链路 | ✅ |
| 0002 SEAFILE_VERSION 源挂载 | settings.py + 构建期 sed | ✅ |
| 0003 钉钉配置后台化 | `STRING_WEB_SETTINGS_ALLOW_EMPTY`（web_settings.py） | ✅ |
| 0004 通讯录错误友好化 | `get_dingtalk_app_key/secret`（utils.py） | ✅ |
| 0005 禁解绑 | — | ❌ **丢失 → 0013 恢复** |
| 0006 离职同步命令 | `deactivate_departed_users.py` | ✅ |
| 0007 invalid state 可诊断 | `invalid dingtalk login state` 日志（got/expected/host） | ✅ |
| 0008 密码仅管理员 | 表单层 `password_login_admin_only` + 后端 `PASSWORD_LOGIN_ADMIN_ONLY` 双拦 | ✅ |
| 0009 SERVICE_URL 后台化 | utils SERVICE_URL 推导注释 + web_settings | ✅ |
| 0010 redirect_uri 域名跟随 | `get_request_scheme_and_netloc`（6 处调用） | ✅ |

**方法论沉淀**：语义对撞复测（"新代码会不会撞坏补丁"）和存在性审计（"补丁还在不在"）是
两种检查，升级文档的检查清单（docs/014 §8）已补存在性审计一项。

## 4. 验证

**dev 栈（后端）**：登录用户带 CSRF POST `/dingtalk/disconnect/` → 200 返回
「Disconnecting DingTalk account is not allowed. Please contact administrator.」
错误页；`social_auth_usersocialauth` 绑定行完好未删。

**本地镜像 1.2.2.d7aa394b**：smoke SMOKE_OK；`dingtalk/views.py` 0013 标记在位；
settings chunk 含状态文本、`dingtalk/disconnect` 零残留；frontend 指纹随改动变化
（716→718 文件，与 1.2.1 不同，符合预期）。

**CI / 彩排 / 灰度**：沿用 1.2.1 同款流程（CI 预演 → 反代彩排 → 合 main → release/1.2.2 →
198 `pull && up -d`，compose 未变）。198 灰度验证：

| 项 | 结果 |
|---|---|
| 溯源 | 容器 `.Image` == ghcr `:latest` == `:1.2.2.d7aa394b` ✅ |
| 补丁 0013 | 容器内 `dingtalk/views.py` 0013 标记在位 ✅ |
| 后端拦截 | 198 上 POST `/dingtalk/disconnect/`（带 session+CSRF）→ 返回禁令错误页，绑定未删 ✅ |
| 前端 bundle | 容器内 settings chunk 无 `dingtalk/disconnect`、含状态文本 ✅ |
| 回归 | 登录页 200、WebDAV 401、钉钉扫码入口未动 ✅ |

**待用户侧验证**：用普通钉钉账号登录后看「个人设置 → Single Sign On (SSO)」，
已绑定应显示状态文本、无 Disconnect 按钮。

## 5. 踩坑回写

1. **语义复测 ≠ 存在性审计**：对撞类复测再全，也查不出「整个补丁没打上」。升级检查清单
   必须有逐补丁存在性核对（本 docs §3 的表格就是模板）。
2. **合并式补丁重放放大遗漏面**：10 合 1 补丁 + `git apply -3` 时，单个 hunk 的失败
   容易被「整体 apply 成功」掩盖。重放后对照原始 10 个提交的 `--stat` 逐文件清点。
3. **版本目录硬编码是慢性病**：cron（001 修）、rebuild-frontend.sh 与 sync-dingtalk-users.sh
   （本次修）都是同一模式——凡写死 `seafile-server-X.Y.Z` 的路径，升级即静默断。已全仓库
   清扫（剩余仅有的两处版本目录：seafile-server.yml 的 dev bind-mount、smoke-test 的
   INSTALLPATH，都是升级清单显式 touchpoint，镜像内无 latest 符号链接的场景无法走链接）。
