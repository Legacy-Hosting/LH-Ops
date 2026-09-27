#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 /etc/legacy-hosting/backups/NAME.env BACKUP.sql.gz.age" >&2
  exit 2
fi
environment_file=$(readlink -f "$1")
backup=$(readlink -f "$2")
if [[ ! -f $environment_file || $environment_file != /etc/legacy-hosting/backups/*.env ]]; then
  echo "Restore environment must be a file under /etc/legacy-hosting/backups" >&2
  exit 1
fi
permissions=$(stat -c '%a' "$environment_file")
if (( 10#$permissions > 600 )); then
  echo "$environment_file must have mode 0600 or stricter" >&2
  exit 1
fi
. "$environment_file"

required=(
  BACKUP_NAME DB_HOST DB_PORT DB_ADMIN_USER DB_ADMIN_PASSWORD DB_SSL_CA
  BACKUP_AGE_IDENTITY RESTORE_DATABASE_PREFIX MIGRATION_TABLE
)
for name in "${required[@]}"; do
  if [[ -z ${!name:-} ]]; then
    echo "Missing restore setting: $name" >&2
    exit 1
  fi
done
if [[ ! $BACKUP_NAME =~ ^[a-z][a-z0-9-]{1,31}$ ]]; then
  echo "Invalid BACKUP_NAME" >&2
  exit 1
fi
backup_directory="/var/backups/legacy-hosting/mysql/$BACKUP_NAME"
if [[ ! -f $backup || $backup != "$backup_directory"/${BACKUP_NAME}-*.sql.gz.age ]]; then
  echo "Backup must be an encrypted $BACKUP_NAME file in $backup_directory" >&2
  exit 1
fi
if [[ ! $RESTORE_DATABASE_PREFIX =~ ^[a-z][a-z0-9_]{2,39}$ ]]; then
  echo "Unsafe RESTORE_DATABASE_PREFIX" >&2
  exit 1
fi
if [[ ! $MIGRATION_TABLE =~ ^[a-z][a-z0-9_]{2,63}$ ]]; then
  echo "Unsafe MIGRATION_TABLE" >&2
  exit 1
fi
if [[ ! -r $DB_SSL_CA || ! -r $BACKUP_AGE_IDENTITY ]]; then
  echo "Database CA or age identity is unreadable" >&2
  exit 1
fi
sha256sum --check "$backup.sha256"

database_name="${RESTORE_DATABASE_PREFIX}_$(date -u +%Y%m%d_%H%M%S)"
if [[ ! $database_name =~ ^[a-z][a-z0-9_]{2,63}$ ]]; then
  echo "Unsafe generated restore database name" >&2
  exit 1
fi
mysql_command=(
  mysql --host="$DB_HOST" --port="$DB_PORT" --user="$DB_ADMIN_USER"
  --ssl-mode=VERIFY_IDENTITY --ssl-ca="$DB_SSL_CA"
)
cleanup() {
  MYSQL_PWD=$DB_ADMIN_PASSWORD "${mysql_command[@]}" \
    -e "DROP DATABASE IF EXISTS \`$database_name\`;" >/dev/null
}
trap cleanup EXIT

MYSQL_PWD=$DB_ADMIN_PASSWORD "${mysql_command[@]}" \
  -e "CREATE DATABASE \`$database_name\` CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;"
age --decrypt --identity "$BACKUP_AGE_IDENTITY" "$backup" | gzip -dc | \
  MYSQL_PWD=$DB_ADMIN_PASSWORD "${mysql_command[@]}" "$database_name"
migration_count=$(MYSQL_PWD=$DB_ADMIN_PASSWORD "${mysql_command[@]}" \
  --batch --skip-column-names "$database_name" \
  -e "SELECT COUNT(*) FROM \`$MIGRATION_TABLE\`;" )
if ! [[ $migration_count =~ ^[0-9]+$ ]] || (( migration_count < 1 )); then
  echo "Restore drill failed: migration ledger is missing" >&2
  exit 1
fi

echo "Restore drill passed with $migration_count migrations."
echo "The disposable database $database_name will now be removed."
