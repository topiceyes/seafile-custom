# 004 - 离职员工账号自动禁用（钉钉同步）

> 完成日期：2026-09-17 ｜ 分支：`seahub/dev-dingtalk` ｜ 状态：已上线验证

## 1. 需求

员工离职（被移出钉钉企业通讯录）后，其 Seafile 账号应在可控时间内自动禁用。采用**方案 A：定时比对同步**（方案 B「钉钉事件订阅实时推送」需公网回调地址，留待生产环境评估）。

## 2. 实现

新增 management command：`seahub/dingtalk/management/commands/deactivate_departed_users.py`

流程：
```
orgapp token（复用 dingtalk/utils.py 带缓存实现）
  → topapi/v2/department/listsub 递归拉全部部门（根部门 id=1）
  → topapi/v2/user/list 按部门分页拉在职成员 unionId 全集
  → 比对 SocialAuthUser(provider='dingtalk') 绑定
  → unionId 不在职集合 → 禁用：user.is_active=False + inactive_user()（撤 token）+ save
```

**安全阀**（防止误杀全公司）：
- 钉钉侧拉取结果为**空集合**（token 失效 / 权限被回收 / API 异常）→ 直接中止，不动任何账号
- 跳过管理员（is_staff）
- 已禁用账号不重复处理
- 支持 `--dry-run` 只打印不动库

被禁用账号：session 立即失效、token 撤销，**数据保留**（可交接给同事，管理员可随时重新启用）。

依赖：钉钉应用「通讯录部门成员读权限」（`qyapi_get_department_member`，与部门导入同族权限，已开通）。

## 3. 使用

**定时执行（系统自带，无需宿主机配置）**：
- Seafile 容器是 phusion/baseimage 镜像，**自带 cron 服务**（runit 管理）
- `deploy/image/dingtalk-sync.cron` 已烘进镜像的 `/etc/cron.d/dingtalk-sync`（生产）；dev 用官方镜像，由 compose 从同一路径挂载进去。两处同一份文件，不会漂移
- 每小时第 17 分自动执行，日志：`deploy/seafile-data/seafile/logs/dingtalk-sync.log`（卷内，宿主机直接可看）
- 已实测：cron 服务确实触发执行（临时任务 2 分钟内跑通）

**手动执行**（立即同步 / 排查问题）：
```bash
# 宿主机封装
/Volumes/newdisc/appdev/Seafile/deploy/sync-dingtalk-users.sh [--dry-run]

# 或容器内直跑
docker exec -w /opt/seafile/seafile-server-12.0.14/seahub seafile \
  /opt/seafile/seafile-server-latest/seahub.sh python-env \
  python3 manage.py deactivate_departed_users [--dry-run]
```

## 4. 验证记录

| 项 | 结果 |
|---|---|
| dry-run（真实企业） | 194 部门 / 332 在职成员，现有绑定用户 0 误伤 |
| 伪造离职绑定（假 unionId + 测试账号） | ✅ 识别为 departed，`is_active` 置 0，token 撤销 |
| 在职用户 | ✅ 不受影响 |
| 测试数据 | 已清理（EmailUser/绑定/Profile） |

## 5. 运维注意

- 全量同步耗时与部门和人数相关（332 人约 200 次 API 调用，本机网络下 1-3 分钟），cron 频率不必过密，每小时足够
- 误禁用的恢复：管理后台「用户」里重新启用，或 SQL `update ccnet_db.EmailUser set is_active=1 where email='...'`
- 离职员工**数据交接**：管理员后台把其资料库转移给同事后再考虑清理账号
- 方案 B（实时）预留：钉钉事件订阅 `通讯录用户离职`，需公网回调 + 验签，生产部署时按需补
