#!/bin/bash
# 离职员工同步：比对钉钉在职成员，禁用已离职的 Seafile 账号
# 用法：./sync-dingtalk-users.sh [--dry-run]
# 建议配 cron 每小时跑一次（见 docs/004）
set -euo pipefail

CONTAINER=seafile
SEAHUB=/opt/seafile/seafile-server-latest/seahub.sh
WORKDIR=/opt/seafile/seafile-server-12.0.14/seahub
LOG=/Volumes/newdisc/appdev/Seafile/deploy/sync-dingtalk-users.log

echo "==== $(date '+%F %T') ====" >> "$LOG"
docker exec -w "$WORKDIR" "$CONTAINER" "$SEAHUB" python-env \
  python3 manage.py deactivate_departed_users "$@" >> "$LOG" 2>&1
tail -5 "$LOG"
