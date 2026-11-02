# 022 - 钉钉用户显示名改为真实姓名（产品 1.2.8）

> 完成日期：2026-11-02 ｜ 状态：1.2.8 已发布并灰度到 198，验证全绿
> 起因：用户反馈「当前同步钉钉的个人的昵称，不是真实姓名，昵称查找不方便」。

## 1. 现象与根因

钉钉扫码登录时，Seafile 的展示名 `Profile.nickname` 取自 OAuth userinfo 的 `nick`
（`seahub/dingtalk/views.py` 的 `dingtalk_callback_new` / `dingtalk_connect_callback_new`）。
`nick` 是**钉钉昵称**（常为英文名、别名或个人化昵称），不是企业通讯录里的真实姓名。
198 实测旧昵称包括 `Timedout`、`abcd`、`老鱼干`、`汐安`、`不然`、`无` 等，按真实
姓名自然搜不到人。

真实姓名就在 topapi v2 `user/get` 的 `result.name` 里。登录回调本来就会为了取
`email` 调用这个接口（`views.py:425-431` 一带），只是 `name` 一直没用上。
dev 实测（2026-11-02）：`user/get` 返回 `name='汪利辉'`；topapi v2 `user/list` 的
成员对象同样含 `name`，按真实部门拉取返回 `汪利辉/刘黎丽/周新荣` 等通讯录姓名。

展示和搜索读的是同一个字段：

- 展示：`email2nickname`（`seahub/base/templatetags/seahub_tags.py`），读
  `Profile.nickname`，带 24h 缓存；
- 搜索：`/api2/search-user/`（共享对话框，`search_user.py`）与
  `/api/v2.1/admin/search-user/`（管理后台，`admin/users.py`）均按
  `nickname__icontains` 匹配。

所以**只要把真实姓名写进 `Profile.nickname`，展示和搜索同时修好**，不需要改搜索
端点。已确认 `ENABLE_ADDRESSBOOK_OPT_IN = False`（全站用户可被搜到），不存在
「名字对了但没开地址簿才搜不到」的隐藏前置。

## 2. 修复（补丁 0019）

**登录 / 绑定回调**（`seahub/dingtalk/views.py`）

- 新增 `_dingtalk_detailed_name()` / `_pick_display_name()`：真实姓名优先；
  `user/get` 失败时，**已有昵称保持不动**（避免一次瞬时失败把已修正的真实姓名打回
  `nick`，这正是本次要修的 bug）；只有当前昵称为空时才用 OAuth `nick` 兜底（首次
  登录场景）。
- 昵称与 `contact_email` 分开保存：`contact_email` 是 `unique=True`，冲突异常不能
  连带回滚昵称。
- 9.0 legacy 回调不改：本部署 AppKey/Secret 已配置，只会走 `_new` 流程；legacy 的
  `user/get` 响应结构也不同（顶层字段，不在 `result` 里）。

**每小时部门同步回填**（`sync_dingtalk_departments.py`）

- `_fetch_dept_union_ids` → `_fetch_dept_members`，顺便取 `user/list` 的 `name`
  （零额外 DingTalk API 调用）。
- 先拉成员再查 `ExternalDepartment` 映射，映射缺失的部门其成员姓名也能回填；根部门
  `dept_id=1` 补拉一次（只取名字、不建 Seafile 部门），覆盖只挂根部门的用户。
- `_sync_nicknames()`：只更新有绑定且 name 非空的账号；空 name 跳过，**绝不清空
  昵称**；`Profile.save()` 触发 post_save 信号刷新 `email2nickname` 的 24h 缓存
  （`QuerySet.update()` 不会，会留下旧缓存）；`--dry-run` 只打印不写库；输出
  `Nickname sync: renamed/unchanged/skipped_empty`，幂等。

**冒烟**（`deploy/smoke-test.sh`）：断言镜像内 `views.py` 含 `[dev] 0019`、
部门同步命令含 `_sync_nicknames`，防补丁重放丢失（存在性审计）。

无数据库迁移，`Profile.nickname` 是既有字段。

## 3. dev 栈验证

| 场景 | 结果 |
|---|---|
| `user/get` 真实姓名 | ✅ `result.name='汪利辉'`（绑定用户） |
| 单元行为（真实名优先 / 已有昵称不回退 / 空昵称用 nick） | ✅ 四个分支全过 |
| `--dry-run` 零写入 | ✅ 打印 RENAME，profile 表 SHA-256 不变 |
| 回填 + 缓存 | ✅ 预热缓存为 `test-wrong-nick` → 同步后 DB 与 `email2nickname` 均为 `汪利辉` |
| 幂等 | ✅ 第二次 `renamed=0 unchanged=1` |
| 成员同步无回归 | ✅ `added=0 removed=0` |
| HTTP 搜索 | ✅ `/api2/search-user/?q=汪` 与 `/api/v2.1/admin/search-user/?query=汪` 均返回 `name=汪利辉` |
| 本地镜像 smoke | ✅ `SMOKE_OK`（含 0019 断言） |

## 4. 灰度结果（198，2026-11-02）

- [x] digest 溯源：部署前 `ghcr.io/topiceyes/seafile-mc@sha256:f7e41c34…`（1.2.7）
      → 部署后 `sha256:53152dbd…`，与 ghcr `1.2.8.fb119d65` = `:latest` 的 manifest
      digest 一致；容器内 `[dev] 0019` 标记在位
- [x] 部署前：22 个钉钉绑定、22 个 Profile、0 个空昵称（旧值如 `Timedout`/`abcd`/
      `老鱼干`/`汐安`/`不然`/`无`）
- [x] dry-run：`renamed=8 unchanged=14 skipped_empty=0`，零写入
- [x] 正式同步：`renamed=8`（另有成员同步 `added=4 removed=0`，属正常对齐）；
      样本：`无→袁文龙`、`abcd→张一凡`、`老鱼干→王云鹤`、`汐安→周鹏辉`、
      `Timedout→周凌达`、`不然→赖相民`
- [x] 缓存：同步前预热 `email2nickname='abcd'`，同步后返回 `'张一凡'`（缓存已失效）
- [x] 搜索：`search_user_from_profile('张一凡')`、`('袁文龙')` 均命中
- [x] 幂等：第二次同步 `renamed=0 unchanged=22 added=0`
- [x] CI run `41387552223` success；反代彩排全绿
- [ ] 用户浏览器复验（共享对话框 / 成员列表 / 按姓名搜索）

## 5. 风险与边界

- **会覆盖用户手动改过的昵称**：钉钉真实姓名是权威值（企业实名场景，与 0015 的
  「成员完全对齐钉钉」一致），每小时同步覆盖。若要保留自定义昵称，需要另存「上次
  同步名」做差异合并，本次不做；也可考虑关闭 `ENABLE_USER_SET_NAME`。
- **重名**：真实姓名可能重复，搜索结果多条属正常，可结合 contact_email/部门区分。
- **API 失败回退**：`user/get` 瞬时失败时已有昵称保持不动，不阻断登录；同步里空
  name 跳过。
- **legacy 9.0 回调未修**：仅在 AppKey/Secret 被清空时才暴露。
- **guest 角色**：guest 无全局通讯录搜索权限；本部署 SSO 用户为默认角色，已抽查
  198 的绑定用户 `role=default`。
- 首次回填会在 `dingtalk-sync.log` 打印改名行（198 本次 8 行；用户规模大的部署会
  更多，日志管理员可见）。

## 6. 方法论

- **展示名和搜索同源**：先确认两者都读 `Profile.nickname`，再决定改哪里——本次
  没有动搜索端点，只改数据来源。
- **回退逻辑要防「回退到错误值」**：`user/get` 失败时回退 `nick` 看似安全，实际会把
  已修正的真实姓名打回昵称；正确规则是「已有昵称就不动，只有空昵称才兜底」。
- **存量数据借既有调度回填**：部门同步每小时本来就要拉 `user/list`，`name` 白拿，
  零新增任务、零额外 API 调用。
