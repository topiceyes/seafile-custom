# 019 - cron 定时任务自 14.0 升级起静默失效的修复（产品 1.2.5）

> 完成日期：2026-10-29 ｜ 状态：1.2.5 已发布并灰度到 198，验证全绿
> 起因：018（1.2.4）灰度后盯首跑，发现部门同步 cron 失败——深挖后确认**两个 manage.py
> 定时任务（离职同步 004 / 部门同步 018）自 14.0 升级以来每小时静默失败，dev/198 全中**
> （198 从 10-27 装上起就没跑成过；141 同理）。

## 1. 故障形态

`dingtalk-sync.log` 每个整点只有一行：

```
Error: .env file not found.
Please follow the upgrade manual to set the .env file.
2026-10-29T12:17:01+08:00 dingtalk-sync FAILED (...)
```

无任何其他报错，符合「静默失效」特征：cron 的 `|| echo ...FAILED` 兜底在，所以不是
完全无痕迹，但 1.2.1 给 FAILED 行加了时间戳之前连这点痕迹都没有。

## 2. 根因

14.0 的 `seahub.sh` 新增 `set_env_config()`：**环境里没有 `JWT_PRIVATE_KEY` 时强制读
`{central_config_dir}/.env`，读不到直接退出**（seafile.sh/seafile-monitor.sh 同款检查）。

- 容器主进程（start.py → runit 服务）有完整容器 env → 没事；
- **cron 服务（phusion runit 拉起）拿不到容器 env** → 检查失败 → manage.py 一条都跑不了。

而我们所有部署形态（dev compose / seafile-prod.yml）都不把 `.env` 挂进容器——
它是宿主机 compose 的输入，不是容器内文件。

**为什么现有防线全没拦住**：0013 修的 cron 路径硬编码（smoke 有断言）只保证 cd 得进
目录；smoke 从未真正执行过 cron 命令；1.2.4 给「cron 挂了命令」加了断言，但断言的是
静态文件内容，不是执行结果。盲区 = 「静态在位 ≠ 跑得起来」。

## 3. 修复（0016，deploy 侧，无 seahub 补丁）

`custom_bootstrap.py` 新增 `ensure_cron_env(confdir)`，每次容器启动时从容器 env
**幂等生成 `conf/.env`**（JWT_PRIVATE_KEY 必备，SEAFILE_SERVER_HOSTNAME/
LETSENCRYPT/PROTOCOL 有则带上；值跟随 env，下次启动自动覆盖，手改无效）。
conf 目录在数据卷里，写一次持久，全机器通用，升级路径天然覆盖。

smoke 加动态断言：带 fake JWT 跑 bootstrap 必须生成 `.env`、连跑两遍 md5 不变（幂等）、
无 JWT 时必须 loud warning（0014 的「静默关」教训同款——不给静默失败留位置）。

## 4. 影响面回填

- **离职自动禁用（004）**：在 14.0 环境（1.2.0 起，10-27 之后）从未真正跑过。
  1.2.5 灰度后恢复，中间窗口期离职的人会在下次同步被补禁用。
- **部门自动同步（018）**：1.2.4 发布即失效，1.2.5 随修复生效，无实际损失。
- **教训**：①「静态断言 ≠ 执行验证」——cron 类任务以后要在目标环境真跑一遍再宣布
  可用；②14.0 的 `.env` 检查是上游行为变化，升级评估（docs/014）漏了「cron 环境
  与主进程环境的 env 差异」这个维度。

## 5. 灰度结果（2026-10-29 灰度到 198，全绿）

- [x] digest 溯源链完整：ghcr `1.2.5.5df84dfe` == `:latest` == 198 运行镜像
      （`sha256:89f526a6…`）
- [x] 容器内 `/opt/seafile/conf/.env` 已生成（bootstrap 首次启动时写入）
- [x] 手动触发 `sync_dingtalk_departments` 成功：195 部门创建、23 名已登录钉钉用户
      挂入各自部门、349 名未登录成员跳过（首登后下次同步自动挂入）
- [x] `deactivate_departed_users --dry-run` 在 198 跑通（Departments: 196, active
      members: 331，无离职）——同一 .env 修复覆盖，下个小时整点 cron 双任务恢复
