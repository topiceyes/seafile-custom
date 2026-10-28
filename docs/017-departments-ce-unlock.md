# 017 - 解锁部门功能（Departments）到 CE（产品 1.2.3）

> 完成日期：2026-10-28 ｜ 状态：1.2.3 已发布，198 灰度待用户验收
> 起因：用户发现管理后台没有「部门」菜单，并问到帮助文档里的部门功能
> （部门树、部门资料库、管理部门间共享的资料库）是否可用。

## 1. 结论先行

**「部门」= address-book groups（creator_name == 'system admin' 的群组）**，是 Seafile
Pro 功能，但 CE 的封锁绝大多数只是 API 层的 `IsProVersion` 权限门——底层 ccnet
CE 全支持（群组表、parent_group_id、纯 SQL 的部门转换/移动）。补丁 0014 把这些门
拆掉后，**CE 下部门树/成员/增删改/移动/群组转部门全部可用**（dev 栈逐项实测，§4）。

两项是 **CE C 核心硬缺口**（不是门，拆了也没有 RPC，与配额同类）：

| 功能 | 缺什么 | 处置 |
|---|---|---|
| 部门配额 | `seafile_api.set/get_group_quota` 不存在 | 前后端守卫隐藏（对齐 0014 之前 admin/groups.py:45 的既有写法）；API 返回 quota=0；PUT quota 明确 400（修复了此前 CE 下直接 500 的潜在炸点） |
| 部门资料库（部门拥有的库） | `add_group_owned_repo` 等组属主库 RPC **CE 不存在**（dev 容器 hasattr 实测 False） | 前端隐藏「Add Library」菜单项与建库对话框；**共享给部门的库**仍在部门页列表可见、正常工作 |

「管理部门间共享的资料库」在 CE 的落地形态 = 把普通资料库共享给部门（群组）——
CE 群组共享本来就有，部门即群组，**无需任何改动**（§4 实测共享/拒删/撤共享全链路）。

## 2. 改动清单（补丁 0014，seahub 分支 upgrade-14.0.9，两个提交）

**后端 `api2/endpoints/admin/address_book/groups.py`**
- `AdminAddressBookGroups`/`AdminAddressBookGroup` 的 `permission_classes` 去掉
  `IsProVersion`（部门树浏览/创建/详情/删除解锁）。
- `address_book_group_to_dict` 的 quota：`get_group_quota(...) if is_pro_version() else 0`。
- POST 创建的 `set_group_quota(-2)` 加 `is_pro_version()` 守卫。
- DELETE 的 has_repo 检查：非 Pro 用 `get_repos_by_group(group_id)` 判空兜底。

**后端 `api2/endpoints/admin/groups.py`**
- `AdminGroupToDeptView` 去 `IsProVersion`；`set_group_quota` 加守卫。
- `AdminGroup.put` 的 set quota 分支（原本**未守卫**，CE 下必 500）加显式 400 拒绝。

**前端**
- `side-panel.js`：部门菜单 `{isPro && canManageGroup}` → `{canManageGroup}`。
- `department-menu.js`：「Set quota」「Add Library」按 `isPro` 条件挂载（CE 两项都隐藏；
  Add Library 是 0014 实测修正——原计划以为组属主库 CE 可用，实测 C 核心无 RPC）。
- `departments/index.js`：`SetGroupQuotaDialog`、`AddRepoDialog` 渲染加 `isPro` 兜底。

**刻意未动**：`AdminGroupOwnedLibraries` 等组属主库端点的 `IsProVersion` 门保持原样
（CE 解锁了也是 500，门反而成了友好 403）；其余 isPro 菜单门不动，只开部门这一项。

## 3. 已知边界（均非本次引入）

- **DELETE 部门的 CE 兜底语义略宽**：Pro 只拒「有组属主库」，CE 有**任意**共享库即拒
  （含成员共享进来的库）。方向更保守（拒删比误删安全），记录在案。
- **`GET /api/v2.1/admin/departments/`（AdminDepartments）CE 下 500**：调用
  `ccnet_api.list_all_departments`，CE 无此 RPC——**这是上游自带的潜在炸点**（该端点
  本来就没设 IsProVersion 门），前端部门页不走它（走 address-book 端点），不影响功能，
  保持原样。
- **`admin/groups.py` 的 `parent_group_id` 在 CE 下恒报 0**（上游 `if is_pro_version()`
  守卫的显示字段）；部门树走 address-book 端点，真实父子关系不受影响，纯管理群组页
  的显示值。

## 4. 验证（dev 栈，seafile-mc:14.0.9 + 分支代码 bind-mount，管理员 token）

| 项 | 结果 |
|---|---|
| 列表部门 `GET admin/address-book/groups/` | ✅ 200，quota=0（原 403） |
| 建一级/子部门（parent_group） | ✅ 200，parent_group_id 正确 |
| 部门详情（子部门/成员/祖先） | ✅ |
| 加成员 | ✅ |
| 把普通库共享给部门 → 删部门 | ✅ 400「There are libraries in this department.」（CE 兜底生效） |
| 撤共享后删部门 | ✅ 200 |
| 删空子部门 | ✅ 200 |
| PUT quota | ✅ 400「Setting group quota is not available in this edition.」（原 500） |
| 普通群组 → 转部门 | ✅ owner 变 system admin，进部门树 |
| 移动部门 / 重命名 | ✅（移动后 address-book 端点 parent_group_id 正确） |
| 管理群组页回归 `GET admin/groups/` | ✅ 200 |
| 组属主库 RPC 存在性 | ❌ CE 无 `add_group_owned_repo`（hasattr 实测）→ 前端隐藏建库入口 |
| 本地镜像 1.2.3.da0b2059 | smoke SMOKE_OK；后端 0014 标记在位、IsProVersion 真引用清零；sysAdmin chunk 两次重建（`59d3c4aa`→`dcb9ee55`→`0e6c1233`），commons/css/runtime 不动，改动面精确 |

## 5. 发布

- tag `1.2.3.da0b2059`；CI 构建 → 反代彩排 → release/1.2.3 → :latest，流程同 015/016。
- 198 灰度：`docker compose pull && docker compose up -d`。

## 6. 灰度结果（待灰度后回填）

- [ ] 管理后台侧边栏出现「部门」菜单
- [ ] 建部门/子部门/加成员走通（用户侧浏览器）
- [ ] 把资料库共享给部门、部门页可见
- [ ] 无配额/建库入口（CE 隐藏符合预期）
