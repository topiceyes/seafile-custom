# 003 - 账号管控收紧（禁注销、禁钉钉解绑）

> 完成日期：2026-09-16 ｜ 分支：`seahub/dev-dingtalk` ｜ 状态：已上线验证

## 1. 需求

企业管控策略：

1. **用户不能自助注销账号**
2. **用户不能断开钉钉绑定**（钉钉是普通用户唯一登录方式，解绑会把账号锁死）

## 2. 实现

### 2.1 禁注销（纯配置，零代码）

seahub 现成开关 `ENABLE_DELETE_ACCOUNT`（默认 True），在 `deploy/seafile-data/seafile/conf/seahub_settings.py`：

```python
ENABLE_DELETE_ACCOUNT = False
```

三层联动（seahub 自带逻辑）：
- 前端：设置页注入 `enableDeleteAccount: false`，注销入口隐藏
- API：`seahub/profile/views.py:271` 直接拒绝删除请求
- 注：需 `seahub.sh restart` 生效（静态配置，非 constance）

### 2.2 禁钉钉解绑（前后端各一处）

**后端**（`seahub/dingtalk/views.py` 的 `dingtalk_disconnect`）：视图入口直接返回错误页，防 API 直调绕过：

```python
@login_required
def dingtalk_disconnect(request):
    # [dev] 企业策略：钉钉身份是普通用户的登录方式，禁止解绑
    return render_error(request, _('Disconnecting DingTalk account is not allowed. Please contact administrator.'))
    # 下方原逻辑保留（不可达），回退时删除此行 return 即可
```

**前端**（`frontend/src/components/user-settings/social-login-dingtalk.js`）：已绑定时 Disconnect 按钮换成状态文本「已连接（如需更换请联系管理员）」；未绑定时 Connect 保留。

部署：改前端后跑 `deploy/rebuild-frontend.sh` + `seahub.sh restart`。

## 3. 验证

| 项 | 结果 |
|---|---|
| `ENABLE_DELETE_ACCOUNT = False` 生效 | ✅ 设置页 `enableDeleteAccount: false` |
| 解绑 API 直调（POST /dingtalk/disconnect/） | ✅ 返回「Disconnecting DingTalk account is not allowed」 |
| 新前端 bundle 上线 | ✅ settings.4b74b649.js |

## 4. 注意

- 解绑禁了但**绑定（Connect）保留**：管理员/用户仍可把钉钉绑到已有 Seafile 账号（如管理员自建账号后再绑钉钉）
- 用户侧"换绑"需管理员介入（数据库操作或先删 SocialAuthUser 记录）：
  ```sql
  delete from seahub_db.social_auth_usersocialauth where provider='dingtalk' and username='<虚拟ID>';
  ```
- 若未来要恢复解绑功能：删掉 `dingtalk_disconnect` 里的 return 行即可（原逻辑完整保留）
