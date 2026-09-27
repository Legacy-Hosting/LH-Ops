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
if (( 10#$permissions > 600 )); then
  echo "$environment_file must have mode 0600 or stricter" >&2
  exit 1
fi
. "$environment_file"

required=(
  BACKUP_NAME DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD DB_SSL_CA
  BACKUP_AGE_RECIPIENT
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
if [[ ! -r $DB_SSL_CA ]]; then
  echo "Cannot read database CA certificate" >&2
  exit 1
fi
retention_days=${BACKUP_RETENTION_DAYS:-14}
if ! [[ $retention_days =~ ^[0-9]+$ ]] || (( retention_days < 1 || retention_days > 365 )); then
  echo "BACKUP_RETENTION_DAYS must be between 1 and 365" >&2
  exit 1
fi

backup_directory="/var/backups/legacy-hosting/mysql/$BACKUP_NAME"
install -d -m 0700 "$backup_directory"
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
temporary=$(mktemp "$backup_directory/.${BACKUP_NAME}-${timestamp}.XXXXXX.sql.gz")
encrypted="$backup_directory/${BACKUP_NAME}-${timestamp}.sql.gz.age"
trap 'rm -f -- "$temporary"' EXIT

MYSQL_PWD=$DB_PASSWORD mysqldump \
  --host="$DB_HOST" --port="$DB_PORT" --user="$DB_USER" \
  --ssl-mode=VERIFY_IDENTITY --ssl-ca="$DB_SSL_CA" \
  --single-transaction --quick --routines --triggers --events \
  --set-gtid-purged=OFF --default-character-set=utf8mb4 \
  "$DB_NAME" | gzip -9 > "$temporary"

gzip -t "$temporary"
age --recipient "$BACKUP_AGE_RECIPIENT" --output "$encrypted" "$temporary"
sha256sum "$encrypted" > "$encrypted.sha256"
chmod 0600 "$encrypted" "$encrypted.sha256"
rm -f -- "$temporary"
trap - EXIT

find "$backup_directory" -maxdepth 1 -type f \
  \( -name "${BACKUP_NAME}-*.sql.gz.age" -o -name "${BACKUP_NAME}-*.sql.gz.age.sha256" \) \
  -mtime "+$retention_days" -delete

echo "Encrypted $BACKUP_NAME backup created: $encrypted"
