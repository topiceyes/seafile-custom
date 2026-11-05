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
STATUS_TOOL="$(dirname "$0")/backup-status.py"
[ -f "$STATUS_TOOL" ] || STATUS_TOOL=/usr/local/libexec/backup-status.py
status() { python3 "$STATUS_TOOL" record --root "$BACKUP_ROOT" "$@"; }
mkdir -p "$BACKUP_ROOT"
LOCK="$BACKUP_ROOT/.backup-lock"
mkdir "$LOCK" || { echo "Backup already running or lock requires inspection: $LOCK" >&2; exit 1; }
STAGE=''
PHASE=preflight
cleanup() {
  result=$?
  trap - EXIT
  set +e
  if [ -n "$STAGE" ] && [ -d "$STAGE" ]; then rm -rf "$STAGE"; fi
  if [ "$result" -ne 0 ]; then
    status failed --phase "$PHASE" --exit-code "$result"
    echo "[$STAMP] backup FAILED phase=$PHASE exit=$result" >&2
  fi
  rmdir "$LOCK" || true
  exit "$result"
}
trap cleanup EXIT
status running --pid "$$"
[ -r "$CREDENTIALS" ] || { echo "Backup credentials unavailable: $CREDENTIALS" >&2; exit 1; }
STAGE=$(mktemp -d "$BACKUP_ROOT/.incomplete-$STAMP.XXXXXX")
DEST="$BACKUP_ROOT/$STAMP"
[ ! -e "$DEST" ] || { echo "Backup destination already exists: $DEST" >&2; exit 1; }

echo "[$STAMP] mysqldump ccnet_db seafile_db seahub_db"
PHASE=database
mysqldump --defaults-extra-file="$CREDENTIALS" \
  --single-transaction --quick --routines --triggers --hex-blob \
  --databases ccnet_db seafile_db seahub_db | gzip > "$STAGE/all-dbs.sql.gz"

echo "[$STAMP] tar conf, seafile-data, seahub-data"
PHASE=files
tar -C "$DATA_ROOT" -cf - conf seafile-data seahub-data | gzip > "$STAGE/data.tar.gz"
PHASE=verify
gzip -t "$STAGE/all-dbs.sql.gz" "$STAGE/data.tar.gz"
printf '%s\n' "$STAMP" > "$STAGE/COMPLETE"
mv "$STAGE" "$DEST"
STAGE=''
status success --backup "$STAMP"
echo "[$STAMP] backup complete: $DEST"

# Only completed backups are candidates for retention; legacy backups are untouched.
count=0
PHASE=retention
dirs=("$BACKUP_ROOT"/[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9])
for ((i=${#dirs[@]}-1; i>=0; i--)); do
  dir="${dirs[i]}"
  [ -d "$dir" ] || continue
  [ ! -L "$dir" ] || continue
  [ -f "$dir/COMPLETE" ] || continue
  count=$((count + 1))
  if [ "$count" -gt "$RETENTION" ]; then rm -rf "$dir"; fi
done
