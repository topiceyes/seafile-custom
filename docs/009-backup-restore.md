# 009 - 备份与恢复

> 2026-11-05 更新：修复 cron 环境缺少数据库凭据的问题；新方案尚需生产恢复演练。

2026-11-05 已在独立临时 Docker 网络中使用真实 MariaDB 验证备份与恢复：三库各写入测试记录，执行备份后导入第二个数据库，记录及归档中的测试数据均可恢复；临时资源已清理。该验证不等同于生产数据、真实 cron 和整机恢复演练。

## 1. 方案

容器内每日 cron（03:30，避开整点与钉钉同步 xx:17）跑 `deploy/image/backup.sh`——它已烘进镜像的 `/usr/local/bin/seafile-backup.sh`，不再由 compose 挂载（挂载会带来「换目录即静默失效」）。备份脚本用镜像内的 mariadb-client（官方镜像没有，自建镜像已装）。

产物：`<SEAFILE_VOLUME>/backup/<时间戳>/`

| 文件 | 内容 |
|---|---|
| `all-dbs.sql.gz` | 三库完整 dump：ccnet_db（用户）、seafile_db（文件元数据）、seahub_db（Web 层） |
| `data.tar.gz` | `/shared/seafile/{conf,seafile-data,seahub-data}`：配置 + 文件块存储 |

保留最近 **7** 份（`RETENTION`，脚本内可调）。日志：`/shared/seafile/logs/backup.log`。

启动时 `custom_bootstrap.py` 根据容器数据库环境生成 `conf/.backup-mysql.cnf`（权限 600），供 cron 使用；备份成功后目录内有 `COMPLETE` 标记，失败的临时目录不会作为成功备份保留。仅有该标记的新备份参与自动保留策略，旧备份不会自动删除。异常断电可能留下 `.backup-lock` 或 `.incomplete-*`；确认没有备份进程后再人工清理。日志中的 `backup FAILED` 需要接入现有监控；日志本身不是主动告警。

备份包含数据库、文件和敏感配置，必须限制访问并复制到独立位置。此脚本只写本地卷，不提供异地、不可变或加密副本；上线后必须核实实际 cron 运行，并在隔离环境完成恢复验证。

## 2. 一致性设计

1. **先 mysqldump 后 tar**（顺序不能反）：Seafile 的 commit/fs/block 对象不可变、只增不改（删除只发生在 seafile-gc）。先导库（元数据快照 T1）后打包数据（T2>T1），T1 引用的对象在 T2 必然存在；反序可能在 dump 里引用了 tar 里还没有（或已被 GC 删掉）的块。
2. **三库一次导出**：`--single-transaction --databases ccnet_db seafile_db seahub_db` 同一一致性时间点。
3. **备份窗口禁跑 seafile-gc**：GC 可能在 T1~T2 之间删掉快照仍引用的对象。若未来上定时 GC，与 03:30 错开并加互斥。

残余风险：备份期间新写入的数据不在本次备份里（下次备份覆盖）；在线 tar 是 Seafile 官方手册认可的做法。要求绝对一致的话用停服窗口方案，本期不做。

### 每日备份独立挂载（198，2026-11-05 已完成）

服务器源路径实际为 `/home/seafile/backup`，本来已使用 `/dev/sda4`；本次将它独立挂载到 `/home/seafile-daily-backups`，容器输出路径仍为 `/shared/backup`，目录权限为 root:root 700。迁移时源目录为空，没有历史每日备份；未删除源目录。Compose 回退文件为 `/opt/seafile-custom/deploy/seafile-prod.yml.before-daily-backup-20261105-191917`。Seafile 重建后仍运行 1.3.4，网页返回 200，挂载验证通过。

另在实际容器中使用精简 cron 环境，运行真实三库导出与临时小型文件归档，确认新挂载中生成 `COMPLETE` 并能读取归档测试文件，测试产物已清理。这不等同于下一次 03:30 的完整生产文件备份；首轮定时备份完成情况仍需核验。

迁移脚本为 `deploy/migrate-daily-backup.py`，需要在 198 的 root 终端运行，依赖 Python 3、rsync 和 Docker。无参数仅检查计划，`--apply` 才执行。脚本读取现有容器的 `/shared` 挂载，复制其 `backup/` 到 `/home/seafile-daily-backups`，逐文件校验内容，并在 `/opt/seafile-custom/deploy/seafile-prod.yml` 中添加 `/home/seafile-daily-backups:/shared/backup`。现有镜像固定不变，仅重建应用容器，网页就绪和挂载检查失败时尝试回退 Compose 与容器。

迁移持有升级运维锁，并使用备份锁阻止并发 cron；发现正在运行的备份或非空目标目录会停止。源备份不删除，原 Compose 保存为同目录的 `seafile-prod.yml.before-daily-backup-*`，目录权限收紧为 700。迁移复制内容的校验不替代数据库恢复演练。脚本本地测试覆盖计划、成功、复制不一致、备份占锁以及切换后检查失败的回退。

此方案由 Compose 保存持久挂载，无需为备份目录新增 fstab 项。后续若重新下载并覆盖生产 Compose，需要保留这条本机挂载配置。升级前备份仍使用 `/var/lib/seafile-project-ops`，与每日备份分开。`/home` 与根分区同在 `/dev/sda`，解决容量问题，异地副本仍需另行配置。

## 3. 恢复（整机粒度）

单文件级恢复不现实（block 是内容寻址的对象，无文件名），恢复粒度 = 整机。

```bash
# 0) 停服务
cd deploy && docker compose down

# 1) 准备空目录（SEAFILE_VOLUME / SEAFILE_MYSQL_VOLUME 指向新空目录），
#    或在原机删除旧数据后重建空目录

# 2) 起 db，等完全就绪（日志出现 mariadbbd "ready for connections" 且初始化结束），导入三库
#    （dump 自带 CREATE DATABASE / USE；⏱ 等待就绪别只看容器状态——初始化有两次重启）
docker compose up -d db
gunzip -c backup/all-dbs.sql.gz | \
  docker exec -i seafile-mysql sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD"'

# 3) ⚠️ 重建应用数据库用户（mysqldump 不含 mysql.user 授权——彩排实测踩坑：
#    缺这步 seafile 容器的 wait_for_mysql 会无限等待，日志刷 "mysql is not ready"）
#    密码 = .env 的 SEAFILE_MYSQL_DB_PASSWORD（与备份里 seafile.conf 中的一致）
docker exec -i seafile-mysql sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD"' <<'SQL'
CREATE USER 'seafile'@'%' IDENTIFIED BY '<SEAFILE_MYSQL_DB_PASSWORD>';
GRANT ALL PRIVILEGES ON `seafile_db`.* TO 'seafile'@'%';
GRANT ALL PRIVILEGES ON `ccnet_db`.*  TO 'seafile'@'%';
GRANT ALL PRIVILEGES ON `seahub_db`.* TO 'seafile'@'%';
FLUSH PRIVILEGES;
SQL

# 4) 还原数据目录
mkdir -p <SEAFILE_VOLUME>/seafile
tar -C <SEAFILE_VOLUME>/seafile -xzf backup/data.tar.gz

# 5) 证书不在备份内（生产 LE 会在下次首启自动重签；自签环境重跑 gen-ssl-cert.sh）

# 6) 起全部服务并验证
docker compose up -d
# 验证：管理员登录 → 库列表 → 下载一个历史文件 → 钉钉扫码
```

注意事项：
- conf 里含 SECRET_KEY / 数据库密码——恢复后若与 .env 不一致以 conf 为准（整包恢复天然一致）
- 恢复到**新机器**时：`.env` 的 `SEAFILE_VOLUME` 等路径、以及钉钉回调域名（若域名变更）要同步处理

## 4. 运维建议

- **磁盘监控**：`data.tar.gz` 随库增长（当前 dev 环境 <1M，生产随文件量线性增长），`/shared/backup` 至少留 7 份的空间
- **异地容灾**（后续项）：198 的 `/shared/backup` 已独立挂载到 `/home/seafile-daily-backups`，但同机同盘不能替代异地副本，建议 rsync/rclone 定期同步到 NAS 或对象存储
- **演练**：每次大版本升级前做一次恢复演练（彩排环境即是现成的演练场）

## 5. 验证记录（本地彩排，2026-09-20）

| 项 | 结果 |
|---|---|
| backup.sh 手动运行 | ✅ 无错；产物 44K（all-dbs.sql.gz 20K + data.tar.gz 21K，空库基线） |
| 恢复演练（第三套目录：解包 → 空库导入 → 起服务） | ✅ 登录页 200；管理员 302 登录成功；0008 策略生效（非管理员被拦）——备份完整携带二开定制 |
| ⚠️ 发现并修复的坑 | mysqldump 不含 MySQL 用户授权：恢复后必须重建 `seafile`@`%` 用户（§3 步骤 3），否则 wait_for_mysql 死循环 |
| MariaDB 就绪判定 | 初始化有**两个阶段**（临时实例 → 正式重启），只有第二阶段的 "ready for connections" 才可用；连接过早报 `Access denied` |
| 证书 | 不在备份内：/shared/ssl 未打包。生产 LE 次日自动重签（域名解析不变即可）；彩排重跑 gen-ssl-cert.sh |

**彩排环境特别说明**：macOS 文件系统大小写不敏感，MariaDB 默认 `lower_case_table_names=2` 下
seafevents 统计表（Monthly*）会因 .frm/.ibd 大小写错位而损坏，mysqldump 中断。彩排必须加
`rehearsal-db-override.yml`（lctn=1，见 docs/007 §7）。生产 Linux 无此问题，backup.sh 原样可用。
