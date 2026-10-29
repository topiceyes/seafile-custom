# 020 - 我的资料库报错：用户组列表 group_quota 的 CE 守卫（产品 1.2.6）

> 完成日期：2026-10-29 ｜ 状态：1.2.6 已发布并灰度到 198，验证全绿
> 起因：用户反馈用户界面「我的资料库」显示错误。

## 1. 故障与根因

198 seahub.log 证据（用户浏览器在反复重试）：

```
Internal Server Error: /api/v2.1/groups/
AttributeError: 'SeafileAPI' object has no attribute 'get_group_quota'
```

「我的资料库」侧边栏的共享小组列表调 `GET /api/v2.1/groups/`。上游
`api2/endpoints/groups.py` 的 `get_group_info` 里：

```python
if group.parent_group_id != 0:                    # 部门才进这个分支
    group_info['group_quota'] = seafile_api.get_group_quota(group_id)   # CE 无此 RPC → 500
```

- `get_group_quota` 是 Pro C 核心 API，CE 不存在（0014 已实测建档）。
- **普通小组 `parent_group_id = 0` 不进这个分支**——所以 CE 用小组功能多年不炸。
- **部门 `parent_group_id = -1`（顶层）或 >0（子部门）必进这个分支**——0014/0015
  解锁部门 + 钉钉同步把真实用户挂进 195 个部门后，用户组列表里全是部门，逢调必 500。
- 讽刺的是同函数下一行的 `group_quota_usage` 有 `is_pro_version()` 守卫——上游
  自己guard了用法却漏了 quota 本体。

这是「解锁 Pro 功能到 CE」的**第三类连锁反应**（0014 拆门 → 0015 进真实数据 →
沉睡的 CE 假设被惊醒）。与 0014 顺手修掉的 admin/groups.py PUT quota 500 同款。

## 2. 修复（补丁 0017）

`groups.py` 单行守卫：`...get_group_quota(group_id) if is_pro_version() else 0`，
对齐同函数 `group_quota_usage` 的既有写法。用户侧表现：部门正常出现在共享列表，
quota 字段显示 0（与 admin API 的 CE 行为一致）。

**排查过但未动的调用点**（均 unreachable 或另有门）：
- `group_owned_libraries.py` / `admin/group_owned_libraries.py`：端点自带 IsProVersion 门；
- `admin/dingtalk.py:378` set_group_quota：所在类 IsProVersion 门；
- `wiki2.py` ×3：知识库已整体关闭（docs/013）。

## 3. 验证

- dev 栈复现：修复前同步用户调 `/api/v2.1/groups/` 500（与 198 日志同款）；
  修复后 200，返回其所属两个部门（顶层+子部门），quota=0。
- 本地镜像 1.2.6.ec1fb771：smoke SMOKE_OK。

## 4. 方法论补一条

0014 的盘点清单查的是「部门功能自身的端点」，没查「**用户已有的通用端点在部门
数据出现后的行为**」。CE 假设「parent_group_id != 0 的组不存在」这类沉睡断言，
解锁 Pro 数据模型后是逐个引爆的。以后每次 CE 解锁类改动，排查面要加一圈：
所有以组/部门为输入的**通用**（非该功能专属）端点。

## 5. 灰度结果（2026-10-29 灰度到 198，全绿）

- [x] digest 溯源链完整：ghcr `1.2.6.ec1fb771` == `:latest` == 198 运行镜像
      （`sha256:aa119871…`）；容器内 0017 守卫在位
- [x] 以真实部门成员身份（组列表含顶层+子部门）调 `/api/v2.1/groups/` → 200，
      quota=0（修复前同调用 500）
- [x] 用户浏览器「我的资料库」待用户确认（服务端证据已闭合）
