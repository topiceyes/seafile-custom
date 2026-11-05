#!/usr/bin/env bash
# Daily online backup: database snapshot first, then immutable Seafile objects.
# Never run seafile-gc while this backup is in progress; see docs/009.
set -euo pipefail
umask 077

RETENTION=7
BACKUP_ROOT="${SEAFILE_BACKUP_ROOT:-/shared/backup}"
DATA_ROOT="${SEAFILE_BACKUP_DATA_ROOT:-/shared/seafile}"
CREDENTIALS="${SEAFILE_BACKUP_CREDENTIALS:-$DATA_ROOT/conf/.backup-mysql.cnf}"
STAMP=$(date +%Y%m%d-%H%M%S)
mkdir -p "$BACKUP_ROOT"
[ -r "$CREDENTIALS" ] || { echo "Backup credentials unavailable: $CREDENTIALS" >&2; exit 1; }
LOCK="$BACKUP_ROOT/.backup-lock"
mkdir "$LOCK" || { echo "Backup already running or lock requires inspection: $LOCK" >&2; exit 1; }
STAGE=''
cleanup() {
  if [ -n "$STAGE" ] && [ -d "$STAGE" ]; then rm -rf "$STAGE"; fi
  rmdir "$LOCK" || true
}
trap cleanup EXIT
STAGE=$(mktemp -d "$BACKUP_ROOT/.incomplete-$STAMP.XXXXXX")
DEST="$BACKUP_ROOT/$STAMP"
[ ! -e "$DEST" ] || { echo "Backup destination already exists: $DEST" >&2; exit 1; }

echo "[$STAMP] mysqldump ccnet_db seafile_db seahub_db"
mysqldump --defaults-extra-file="$CREDENTIALS" \
  --single-transaction --quick --routines --triggers --hex-blob \
  --databases ccnet_db seafile_db seahub_db | gzip > "$STAGE/all-dbs.sql.gz"

echo "[$STAMP] tar conf, seafile-data, seahub-data"
tar -C "$DATA_ROOT" -cf - conf seafile-data seahub-data | gzip > "$STAGE/data.tar.gz"
gzip -t "$STAGE/all-dbs.sql.gz" "$STAGE/data.tar.gz"
printf '%s\n' "$STAMP" > "$STAGE/COMPLETE"
mv "$STAGE" "$DEST"
STAGE=''
echo "[$STAMP] backup complete: $DEST"

# Only completed backups are candidates for retention; legacy backups are untouched.
count=0
dirs=("$BACKUP_ROOT"/20????????-??????)
for ((i=${#dirs[@]}-1; i>=0; i--)); do
  dir="${dirs[i]}"
  [ -d "$dir" ] || continue
  [ -f "$dir/COMPLETE" ] || continue
  count=$((count + 1))
  if [ "$count" -gt "$RETENTION" ]; then rm -rf "$dir"; fi
done
