# 018 - 钉钉组织架构自动同步 Seafile 部门（产品 1.2.4）

> 完成日期：2026-10-29 ｜ 状态：1.2.4 发布中（198 灰度前需用户批准）
> 起因：用户要求「组织架构的部门自动从钉钉同步」。前置条件 = 017（1.2.3）把部门功能
> 解锁到了 CE，否则同步进来的部门树在 CE 下根本不可见。

## 1. 结论先行

新命令 `sync_dingtalk_departments`（补丁 0015）每小时随 dingtalk-sync cron 执行：
把钉钉通讯录的**完整部门树 + 成员**对齐进 Seafile 部门（address-book group）。
复用 `deactivate_departed_users` 已验证的 topapi v2 通道（同一 orgapp token，同一套
部门/成员读权限——离职同步每小时在用，零新授权）。

对齐语义（用户拍板 2026-10-29）：

| 钉钉侧变化 | Seafile 侧动作 |
|---|---|
| 新部门 | 按父子关系递归创建（BFS 父先于子），登记 `ExternalDepartment` 映射（provider='dingtalk', outer_id=dept_id） |
| 部门改名 | 自动跟随改名 |
| 成员在部门 | 拉进 Seafile 部门 |
| 成员不在部门 | **移出**（完全对齐钉钉） |
| 部门被删 | **仅告警不删**（部门可能已挂共享资料库） |

保护项：is_staff 管理员**只加不删**（与离职同步的 is_staff 跳过同思路）；从未登录过
Seafile 的钉钉成员没有账号可挂，跳过计数（首次扫码登录后，下次同步自动挂入）。

## 2. 实现要点

- **映射表零新增**：复用上游现成的 `ExternalDepartment`（group_id ↔ provider+outer_id，
  seahub_db 表现成）。0014 已确认删除部门时会清映射（address_book DELETE 内建）。
  老的 `fix_dingtalk_departments_sync` 命令（按名字补链接、走 legacy oapi + 独立
  APP_KEY）被本命令取代，保留未删。
- **身份**：部门操作一律以 creator 'system admin' 执行（ccnet 按 creator_name 校验，
  与 AdminGroupMembers 同款）；`create_group(name, 'system admin', parent_group_id=pid)`
  在 CE 创建部门 = 1.2.3 已实测的 API 路径。
- **安全阀**（沿用离职同步思路）：钉钉侧拉到空部门树 → 直接中止不动任何东西；
  单个部门创建/改名失败 → 记日志跳过不中断；支持 `--dry-run`。
- **cron**：`deploy/image/dingtalk-sync.cron` 新增 23 分任务（离职同步 17 分之后），
  失败时写带时间戳的 FAILED 行到 dingtalk-sync.log；smoke-test 已加防回归断言
  （cron 必须挂 sync_dingtalk_departments——纯增量同步漏挂 cron 的表象是
  「钉钉改了架构 Seafile 不动」，无任何报错）。

## 3. 验证（dev 栈，真实钉钉 API）

- `--dry-run`：拉到 195 个部门，created=195 renamed=0 failed=0，全程零写。
- 真实跑：195 部门全部创建（group 5-199），部门树父子关系正确（13 个一级部门
  与钉钉架构一致，抽查「运营与支撑中心」子部门/成员正确）；钉钉用户汪利辉按其
  真实所属 2 个部门自动挂入；skipped_no_account=370（未登录过的钉钉成员，预期）。
- 幂等：第二次跑 created=0 renamed=0。
- 移除对齐：手动把汪利辉塞进「总裁办」+ 把 is_staff 管理员塞进「总裁办」→ 重跑
  → `REMOVE` 汪利辉、`SKIP remove admin`（管理员保护生效）。
- 本地镜像 1.2.4.c049bb16：smoke SMOKE_OK（含新 cron 断言）；镜像内命令文件与
  cron 行在位。

## 4. 发布

- tag `1.2.4.c049bb16`；CI 构建 → 反代彩排 → release/1.2.4 → :latest，流程同 015-017。
- 198 灰度：pull+up 后 cron 自动开始每小时同步。**首次同步会把 198 现有钉钉用户
  全部挂进各自部门**（用户侧可见的即时变化）。

## 5. 灰度结果（2026-10-29 灰度到 198）

- [x] digest 溯源链完整：ghcr `1.2.4.c049bb16` == `:latest` == 198 运行镜像
      （`sha256:26d74621…`）；容器内命令文件与 cron 行在位；登录页 200
- [ ] ~~首次 cron 同步日志~~ **首跑失败，牵出 019**：cron 服务拿不到容器 env，14.0 的
      `seahub.sh` 强制读 `conf/.env` → 离职同步（17 分）和部门同步（23 分）每小时
      双双失败，log 只有 "Error: .env file not found"。**14.0 环境（1.2.0 起）这两个
      定时任务从未跑成过**（dev/198 全中，141 同理）。修复 = 1.2.5（docs/019）。
- [ ] 1.2.5 灰度后：conf/.env 在位，手动/整点触发同步成功，部门树与钉钉一致
