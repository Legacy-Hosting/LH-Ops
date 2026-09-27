#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 /etc/legacy-hosting/backups/NAME.env" >&2
  exit 2
fi
environment_file=$(readlink -f "$1")
if [[ ! -f $environment_file || $environment_file != /etc/legacy-hosting/backups/*.env ]]; then
  echo "Backup environment must be a file under /etc/legacy-hosting/backups" >&2
  exit 1
fi
permissions=$(stat -c '%a' "$environment_file")
owner=$(stat -c '%u' "$environment_file")
if (( (8#$permissions & 077) != 0 )) || [[ $owner != 0 ]]; then
  echo "$environment_file must have mode 0600 or stricter" >&2
  exit 1
fi
. "$environment_file"

required=(
  BACKUP_NAME DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD DB_SSL_CA
  BACKUP_AGE_RECIPIENT BACKUP_S3_ENDPOINT BACKUP_S3_BUCKET BACKUP_S3_PREFIX
  BACKUP_S3_ACCESS_KEY_ID BACKUP_S3_SECRET_ACCESS_KEY
)
for name in "${required[@]}"; do
  if [[ -z ${!name:-} ]]; then
    echo "Missing backup setting: $name" >&2
    exit 1
  fi
done
if [[ ! $BACKUP_NAME =~ ^[a-z][a-z0-9-]{1,31}$ ]]; then
  echo "BACKUP_NAME must use lowercase letters, numbers, and hyphens" >&2
  exit 1
fi
if [[ ! $DB_PORT =~ ^[0-9]+$ ]] || (( DB_PORT < 1 || DB_PORT > 65535 )); then
  echo "DB_PORT must be between 1 and 65535" >&2
  exit 1
fi
if [[ ! $BACKUP_AGE_RECIPIENT =~ ^age1[ac-hj-np-z02-9]{20,}$ ]]; then
  echo "BACKUP_AGE_RECIPIENT must be an age public recipient" >&2
  exit 1
fi
if [[ ! $BACKUP_S3_ENDPOINT =~ ^[a-z0-9][a-z0-9.-]+$ || \
      ! $BACKUP_S3_BUCKET =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ || \
      ! $BACKUP_S3_PREFIX =~ ^[a-z0-9][a-z0-9/_-]{0,127}$ || \
      $BACKUP_S3_PREFIX == *..* ]]; then
  echo "Unsafe S3 endpoint, bucket, or prefix" >&2
  exit 1
fi
if (( ${#BACKUP_S3_ACCESS_KEY_ID} < 16 || ${#BACKUP_S3_SECRET_ACCESS_KEY} < 32 )); then
  echo "S3 backup credentials do not meet the minimum length" >&2
  exit 1
fi
if [[ ! -r $DB_SSL_CA ]]; then
  echo "Cannot read database CA certificate" >&2
  exit 1
fi
retention_days=${BACKUP_RETENTION_DAYS:-14}
if ! [[ $retention_days =~ ^[0-9]+$ ]] || (( retention_days < 1 || retention_days > 365 )); then
  echo "BACKUP_RETENTION_DAYS must be between 1 and 365" >&2
  exit 1
fi
for command in age cmp flock gzip mysqldump rclone sha256sum sync; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Required backup command is unavailable: $command" >&2
    exit 1
  fi
done

backup_directory="/var/backups/legacy-hosting/mysql/$BACKUP_NAME"
install -d -m 0700 "$backup_directory"
lock_file="/run/lock/lh-mysql-backup-$BACKUP_NAME.lock"
exec 9>"$lock_file"
if ! flock -n 9; then
  echo "Another $BACKUP_NAME backup is already running" >&2
  exit 1
fi
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
temporary=$(mktemp "$backup_directory/.${BACKUP_NAME}-${timestamp}.XXXXXX.sql.gz")
encrypted="$backup_directory/${BACKUP_NAME}-${timestamp}.sql.gz.age"
encrypted_temporary=$(mktemp "$backup_directory/.${BACKUP_NAME}-${timestamp}.XXXXXX.sql.gz.age")
checksum="$encrypted.sha256"
checksum_temporary=$(mktemp "$backup_directory/.${BACKUP_NAME}-${timestamp}.XXXXXX.sha256")
trap 'rm -f -- "$temporary" "$encrypted_temporary" "$checksum_temporary"' EXIT
if [[ -e $encrypted || -e $checksum ]]; then
  echo "Refusing to overwrite an existing backup" >&2
  exit 1
fi

MYSQL_PWD=$DB_PASSWORD mysqldump \
  --host="$DB_HOST" --port="$DB_PORT" --user="$DB_USER" \
  --ssl-mode=VERIFY_IDENTITY --ssl-ca="$DB_SSL_CA" \
  --single-transaction --quick --triggers \
  --set-gtid-purged=OFF --no-tablespaces --default-character-set=utf8mb4 \
  "$DB_NAME" | gzip -9 > "$temporary"

gzip -t "$temporary"
age --recipient "$BACKUP_AGE_RECIPIENT" --output "$encrypted_temporary" "$temporary"
rm -f -- "$temporary"
sync -f "$encrypted_temporary"
chmod 0600 "$encrypted_temporary"
mv -n "$encrypted_temporary" "$encrypted"
(cd "$backup_directory" && sha256sum "$(basename "$encrypted")") > "$checksum_temporary"
sync -f "$checksum_temporary"
chmod 0600 "$checksum_temporary"
mv -n "$checksum_temporary" "$checksum"

expected_hash=$(cut -d ' ' -f 1 "$checksum")
export RCLONE_CONFIG=/dev/null
export RCLONE_CONFIG_LHBACKUP_TYPE=s3
export RCLONE_CONFIG_LHBACKUP_PROVIDER=DigitalOcean
export RCLONE_CONFIG_LHBACKUP_ENV_AUTH=false
export RCLONE_CONFIG_LHBACKUP_ACCESS_KEY_ID=$BACKUP_S3_ACCESS_KEY_ID
export RCLONE_CONFIG_LHBACKUP_SECRET_ACCESS_KEY=$BACKUP_S3_SECRET_ACCESS_KEY
export RCLONE_CONFIG_LHBACKUP_ENDPOINT=$BACKUP_S3_ENDPOINT
export RCLONE_CONFIG_LHBACKUP_ACL=private
export RCLONE_CONFIG_LHBACKUP_NO_CHECK_BUCKET=true
remote_root="lhbackup:${BACKUP_S3_BUCKET}/${BACKUP_S3_PREFIX}/${BACKUP_NAME}"

upload_tier() {
  local tier=$1
  local remote_directory="$remote_root/$tier"
  local remote_backup="$remote_directory/$(basename "$encrypted")"
  local remote_checksum="$remote_backup.sha256"
  rclone copyto --no-traverse "$encrypted" "$remote_backup"
  rclone copyto --no-traverse "$checksum" "$remote_checksum"
  remote_hash=$(rclone cat "$remote_backup" | sha256sum | cut -d ' ' -f 1)
  if [[ $remote_hash != "$expected_hash" ]] || \
     ! cmp -s <(rclone cat "$remote_checksum") "$checksum"; then
    echo "Off-site verification failed for $BACKUP_NAME $tier backup" >&2
    return 1
  fi
}

upload_tier daily
day=$(date -u +%d)
month=$(date -u +%m)
if [[ $day == 01 ]]; then
  upload_tier monthly
  if [[ $month == 01 ]]; then
    upload_tier yearly
  fi
fi

prune_tier() {
  local tier=$1
  local minimum_age=$2
  if rclone lsf "$remote_root/$tier" --max-depth 1 >/dev/null 2>&1; then
    rclone delete "$remote_root/$tier" --min-age "$minimum_age" \
      --include "${BACKUP_NAME}-*.sql.gz.age" \
      --include "${BACKUP_NAME}-*.sql.gz.age.sha256"
  fi
}
prune_tier daily 35d
prune_tier monthly 366d
prune_tier yearly 1096d

find "$backup_directory" -maxdepth 1 -type f \
  \( -name "${BACKUP_NAME}-*.sql.gz.age" -o -name "${BACKUP_NAME}-*.sql.gz.age.sha256" \) \
  -mtime "+$retention_days" -delete

trap - EXIT
echo "Encrypted $BACKUP_NAME backup created and verified off-site: $encrypted"
