# 021 - 共享给部门 Permission denied 的修复（产品 1.2.7）

> 完成日期：2026-10-30 ｜ 状态：1.2.7 已发布并灰度到 198，验证全绿
> 起因：用户反馈「文件共享只有群组，没有部门；在群组里能看见部门，但点击共享提示 Permission denied」。

## 1. 现象与证据

198 上诊断（容器内脚本 + 真实账号）：

| 检查项 | 结果 |
|---|---|
| `settings.ENABLE_SHARE_TO_DEPARTMENT` | True（部门本应出现在共享列表） |
| `constance ENABLE_SHARE_TO_ALL_GROUPS` | 1（共享列表返回全部群组） |
| `GET /api/v2.1/shareable-groups/`（管理员） | 197 条，其中 196 个部门——**列表里其实有部门** |
| 管理员在部门里的身份 | `is_group_member=1` 或 `0`，**`is_group_admin=0`（全公司无部门管理员）** |
| 共享 POST 结果 | `Permission denied.`（成员/非成员都拒） |

dev 栈逐一复现：
- 管理员共享给非成员部门 6 → Permission denied（成员门）
- 管理员共享给「是成员但不是管理员」的部门 12 → Permission denied（部门管理员门）

## 2. 根因：两个上游门在同步部门上都不成立

`seahub/api2/endpoints/dir_shared_items.py`（共享给群组的唯一落点）：

```python
if not config.ENABLE_SHARE_TO_ALL_GROUPS and not is_group_member(gid, username):   # 门 1
    ... Permission denied

if group.parent_group_id != 0:                          # 部门
    if ... not is_group_admin(gid, username):           # 门 2：必须是部门管理员
        ... Permission denied
```

- **门 2 是 Pro 语义**：部门由「部门管理员」管理，只有他们能往里共享资料库。
- 但 0014 解锁部门 + 0015 钉钉同步后，部门的 owner 是 `system admin` 伪账号，成员
  全部是钉钉同步进来的普通成员 → **没有任何人满足 `is_group_admin`**，共享给部门
  对所有账号都是 Permission denied，部门功能实际不可用。
- 门 1（必须是群组成员）在 198 因 `ENABLE_SHARE_TO_ALL_GROUPS=1` 被跳过，但全新部署
  默认是 0——管理员不是部门成员时同样被拒。

用户看到的「列表里没有部门」在 198 上复测不成立（API 返回 196 个部门），属于列表在
数百个群组里不易辨认 + 共享必然失败的组合观感；本补丁同时让管理员在任何部署配置下
都能看到全部群组，避免该观感复现。

## 3. 修复（补丁 0018）

**`dir_shared_items.py`**
- 门 1：`is_staff`（系统管理员）不受「必须是成员」限制。
- 门 2：部门共享放行条件改为 **部门成员 或 系统管理员**（替代「必须是部门管理员」）。
  非成员且非管理员仍拒绝——部门不能被任意人灌库。

**`shareable_groups.py`**
- `ENABLE_SHARE_TO_ALL_GROUPS` 为假时，**系统管理员仍返回全部群组/部门**（否则全新
  部署里管理员也只看到自己加入的群组，部门一个都不出现）。

语义定位：CE 里部门即群组，部门共享按群组语义（成员可共享）工作；Pro 的「部门管理员」
限制在同步部门上无法成立，故放宽为成员级。若将来要收紧，把门 2 的 `is_group_member`
换回 `is_group_admin`，并在部门页给相应人员设置「管理员」即可。

## 4. 验证（dev 栈）

| 场景 | 结果 |
|---|---|
| 管理员 → 非成员部门 6 | ✅ 成功（修复前 403） |
| 管理员 → 成员但非管理员部门 12 | ✅ 成功（修复前 403） |
| 部门成员（普通用户）→ 本部门 6 | ✅ 成功 |
| 普通用户 → 非本部门 12 | ✅ 仍 Permission denied |
| `ALL_GROUPS=1` 下普通用户 → 非本部门 | ✅ 仍 Permission denied（部门门生效，不靠成员门兜底） |
| 管理员 shareable-groups（ALL_GROUPS=0 的 dev） | ✅ 195 条全部为部门（修复前只有 1 条） |
| 本地镜像 1.2.7.d0b0fad3 | smoke SMOKE_OK |

测试数据（两个测试库、临时共享）已全部清理；dev 的 `ENABLE_SHARE_TO_ALL_GROUPS` 已还原为 0。

## 5. 灰度结果（2026-10-30 灰度到 198）

- [x] digest 溯源链完整：ghcr `1.2.7.d0b0fad3` == `:latest` == 198 运行镜像
      （`sha256:f7e41c34…`）；容器内 0018 标记在位（两个文件）
- [x] 198 管理员用临时库共享给「运营与支撑中心」（非成员部门）→ **成功**
      （修复前同一调用 Permission denied）；临时库与共享已清理
- [x] 部门成员→本部门成功、非成员→非本部门仍拒绝：dev 用相同代码验证（含
      `ALL_GROUPS=1` 场景），198 与 dev 代码树一致（CI 树哈希断言）
- [ ] 用户浏览器共享给部门复验（待用户确认）

## 6. 方法论

与 020 同属「CE 解锁 Pro 数据模型后的沉睡断言」系列：这次是**权限模型假设**
（「部门一定有管理员」）。0014 盘点时只看了功能端点能不能跑，没看**权限规则在
同步出的数据上是否可满足**。以后 CE 解锁类改动，检查清单要加一条：
「Pro 的权限/治理假设（管理员、配额、所有者）在 CE 生成的数据上成立吗？」
