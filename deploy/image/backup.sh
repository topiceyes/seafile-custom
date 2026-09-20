#!/usr/bin/env bash
# Seafile 每日备份（容器内 cron 触发，见 backup.cron；镜像内含 mariadb-client）。
#
# 产物：/shared/backup/<时间戳>/{all-dbs.sql.gz, data.tar.gz}，保留 RETENTION 份。
# 恢复步骤见 docs/009-backup-restore.md。
#
# 一致性设计（重要）：
#   1. 先 mysqldump（元数据快照 T1），后 tar 数据目录（T2 > T1）。
#      Seafile 的 commit/fs/block 对象不可变、只增不改（删除仅发生在 seafile-gc），
#      因此 T1 快照引用的对象在 T2 的 tar 中必然存在；反序（先 tar 后 dump）可能缺块。
#   2. 三库一次 --single-transaction 导出 = 同一一致性时间点。
#   3. 备份窗口内禁止运行 seafile-gc（可能在 T1~T2 之间删掉快照仍引用的对象）。
set -euo pipefail

RETENTION=7
STAMP=$(date +%Y%m%d-%H%M%S)
DEST=/shared/backup/$STAMP
: "${DB_ROOT_PASSWD:?缺少 DB_ROOT_PASSWD（应由 compose environment 注入）}"
DB_HOST="${DB_HOST:-db}"

mkdir -p "$DEST"

echo "[$STAMP] mysqldump ccnet_db seafile_db seahub_db"
mysqldump -h"$DB_HOST" -uroot -p"$DB_ROOT_PASSWD" \
  --single-transaction --quick --routines --triggers --hex-blob \
  --databases ccnet_db seafile_db seahub_db | gzip > "$DEST/all-dbs.sql.gz"

echo "[$STAMP] tar /shared/seafile/{conf,seafile-data,seahub-data}"
tar -C /shared/seafile -cf - conf seafile-data seahub-data | gzip > "$DEST/data.tar.gz"

echo "[$STAMP] done: $(du -sh "$DEST" | cut -f1)"

# 只保留最近 RETENTION 份
ls -1dt /shared/backup/*/ | tail -n +$((RETENTION + 1)) | xargs -r rm -rf
