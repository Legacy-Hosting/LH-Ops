#!/usr/bin/env bash
set -Eeuo pipefail

repository_root=$(cd "$(dirname "$0")/.." && pwd)
backup=$repository_root/scripts/backup-mysql.sh
restore=$repository_root/scripts/restore-drill.sh
service=$repository_root/systemd/lh-mysql-backup@.service

grep -q -- '--ssl-mode=VERIFY_IDENTITY' "$backup"
grep -q -- '--no-tablespaces' "$backup"
grep -q 'flock -n' "$backup"
grep -q 'RCLONE_CONFIG_LHBACKUP_SECRET_ACCESS_KEY' "$backup"
grep -q 'RCLONE_CONFIG=/dev/null' "$backup"
grep -q 'rclone cat.*remote_backup' "$backup"
grep -q 'BACKUP_S3_SECRET_ACCESS_KEY' "$repository_root/env/api-backup.env.example"
grep -q 'BACKUP_S3_SECRET_ACCESS_KEY' "$repository_root/env/sso-backup.env.example"
if grep -q 'BACKUP_AGE_IDENTITY' "$repository_root/env/api-backup.env.example" \
  "$repository_root/env/sso-backup.env.example"; then
  echo "Private age identities must not be stored in daily backup environments" >&2
  exit 1
fi
grep -q 'LH_RESTORE_OPERATOR' "$restore"
grep -q 'RESTORE_REQUIRED_TABLES' "$restore"
grep -q '^NoNewPrivileges=true$' "$service"
grep -q '^ProtectSystem=strict$' "$service"
grep -q '^CapabilityBoundingSet=$' "$service"

echo "Backup policy checks passed."
