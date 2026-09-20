# 009 - 备份与恢复

> 完成日期：2026-09-20 ｜ 状态：随生产部署上线（本地彩排含恢复演练）

## 1. 方案

容器内每日 cron（03:30，避开整点与钉钉同步 xx:17）跑 `deploy/backup.sh`（由 seafile-prod.yml 挂载为 `/usr/local/bin/seafile-backup.sh`）。备份脚本用镜像内的 mariadb-client（官方镜像没有，自建镜像已装）。

产物：`<SEAFILE_VOLUME>/backup/<时间戳>/`

| 文件 | 内容 |
|---|---|
| `all-dbs.sql.gz` | 三库完整 dump：ccnet_db（用户）、seafile_db（文件元数据）、seahub_db（Web 层） |
| `data.tar.gz` | `/shared/seafile/{conf,seafile-data,seahub-data}`：配置 + 文件块存储 |

保留最近 **7** 份（`RETENTION`，脚本内可调）。日志：`/shared/seafile/logs/backup.log`。

## 2. 一致性设计

1. **先 mysqldump 后 tar**（顺序不能反）：Seafile 的 commit/fs/block 对象不可变、只增不改（删除只发生在 seafile-gc）。先导库（元数据快照 T1）后打包数据（T2>T1），T1 引用的对象在 T2 必然存在；反序可能在 dump 里引用了 tar 里还没有（或已被 GC 删掉）的块。
2. **三库一次导出**：`--single-transaction --databases ccnet_db seafile_db seahub_db` 同一一致性时间点。
3. **备份窗口禁跑 seafile-gc**：GC 可能在 T1~T2 之间删掉快照仍引用的对象。若未来上定时 GC，与 03:30 错开并加互斥。

残余风险：备份期间新写入的数据不在本次备份里（下次备份覆盖）；在线 tar 是 Seafile 官方手册认可的做法。要求绝对一致的话用停服窗口方案，本期不做。

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
- **异地容灾**（后续项）：`/shared/backup` 目前在系统盘上，建议 rsync/rclone 定期同步到 NAS 或对象存储
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
