#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 /etc/legacy-hosting/backups/NAME-restore.env BACKUP.sql.gz.age" >&2
  exit 2
fi
environment_file=$(readlink -f "$1")
backup=$(readlink -f "$2")
if [[ ! -f $environment_file || $environment_file != /etc/legacy-hosting/backups/*-restore.env ]]; then
  echo "Restore environment must be a *-restore.env file under /etc/legacy-hosting/backups" >&2
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
  BACKUP_NAME DB_HOST DB_PORT DB_ADMIN_USER DB_ADMIN_PASSWORD DB_SSL_CA
  BACKUP_AGE_IDENTITY RESTORE_DATABASE_PREFIX MIGRATION_TABLE
  RESTORE_REQUIRED_TABLES
)
for name in "${required[@]}"; do
  if [[ -z ${!name:-} ]]; then
    echo "Missing restore setting: $name" >&2
    exit 1
  fi
done
for command in age gzip jq mysql sha256sum; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Required restore command is unavailable: $command" >&2
    exit 1
  fi
done
if [[ ! $BACKUP_NAME =~ ^[a-z][a-z0-9-]{1,31}$ ]]; then
  echo "Invalid BACKUP_NAME" >&2
  exit 1
fi
if [[ ! $DB_PORT =~ ^[0-9]+$ ]] || (( DB_PORT < 1 || DB_PORT > 65535 )); then
  echo "DB_PORT must be between 1 and 65535" >&2
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
identity_permissions=$(stat -c '%a' "$BACKUP_AGE_IDENTITY" 2>/dev/null || true)
identity_owner=$(stat -c '%u' "$BACKUP_AGE_IDENTITY" 2>/dev/null || true)
if [[ ! -r $DB_SSL_CA || ! -r $BACKUP_AGE_IDENTITY || \
      -z $identity_permissions || $identity_owner != 0 ]] || \
   (( (8#$identity_permissions & 077) != 0 )); then
  echo "Database CA or age identity is unreadable" >&2
  exit 1
fi
if [[ ! -f $backup.sha256 || -L $backup || -L $backup.sha256 ]]; then
  echo "Backup and checksum must be regular, non-symlink files" >&2
  exit 1
fi
read -r expected_hash checksum_filename < "$backup.sha256"
if [[ ! $expected_hash =~ ^[a-f0-9]{64}$ || \
      $checksum_filename != "$(basename "$backup")" ]]; then
  echo "Checksum file does not identify the selected backup" >&2
  exit 1
fi
actual_hash=$(sha256sum "$backup" | cut -d ' ' -f 1)
if [[ $actual_hash != "$expected_hash" ]]; then
  echo "Backup checksum verification failed" >&2
  exit 1
fi

operator=${LH_RESTORE_OPERATOR:-}
if [[ ! $operator =~ ^[A-Za-z0-9][A-Za-z0-9_.@-]{2,127}$ ]]; then
  echo "Set LH_RESTORE_OPERATOR to the named operator running this drill" >&2
  exit 1
fi

database_name="${RESTORE_DATABASE_PREFIX}_$(date -u +%Y%m%d_%H%M%S)"
if [[ ! $database_name =~ ^[a-z][a-z0-9_]{2,63}$ ]]; then
  echo "Unsafe generated restore database name" >&2
  exit 1
fi
mysql_command=(
  mysql --host="$DB_HOST" --port="$DB_PORT" --user="$DB_ADMIN_USER"
  --ssl-mode=VERIFY_IDENTITY --ssl-ca="$DB_SSL_CA"
)
started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
audit_directory=/var/log/legacy-hosting
audit_log=$audit_directory/restore-drills.jsonl
install -d -m 0750 "$audit_directory"
touch "$audit_log"
chmod 0600 "$audit_log"
database_created=false
drill_result=failed
migration_count=0
cleanup() {
  exit_code=$?
  trap - EXIT
  set +e
  if [[ $database_created == true ]]; then
    if ! MYSQL_PWD=$DB_ADMIN_PASSWORD "${mysql_command[@]}" \
      -e "DROP DATABASE IF EXISTS \`$database_name\`;" >/dev/null; then
      drill_result=cleanup_failed
      exit_code=1
    fi
  fi
  if ! jq -nc \
    --arg operator "$operator" \
    --arg backup "$(basename "$backup")" \
    --arg database "$database_name" \
    --arg result "$drill_result" \
    --arg startedAt "$started_at" \
    --arg finishedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson migrationCount "$migration_count" \
    '{operator:$operator,backup:$backup,database:$database,result:$result,startedAt:$startedAt,finishedAt:$finishedAt,migrationCount:$migrationCount}' \
    >> "$audit_log"; then
    echo "Could not append the restore-drill audit event" >&2
    exit_code=1
  fi
  exit "$exit_code"
}
trap cleanup EXIT

MYSQL_PWD=$DB_ADMIN_PASSWORD "${mysql_command[@]}" \
  -e "CREATE DATABASE \`$database_name\` CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;"
database_created=true
age --decrypt --identity "$BACKUP_AGE_IDENTITY" "$backup" | gzip -dc | \
  MYSQL_PWD=$DB_ADMIN_PASSWORD "${mysql_command[@]}" "$database_name"
migration_count=$(MYSQL_PWD=$DB_ADMIN_PASSWORD "${mysql_command[@]}" \
  --batch --skip-column-names "$database_name" \
  -e "SELECT COUNT(*) FROM \`$MIGRATION_TABLE\`;" )
if ! [[ $migration_count =~ ^[0-9]+$ ]] || (( migration_count < 1 )); then
  echo "Restore drill failed: migration ledger is missing" >&2
  exit 1
fi
read -r -a required_tables <<< "$RESTORE_REQUIRED_TABLES"
for table in "${required_tables[@]}"; do
  if [[ ! $table =~ ^[a-z][a-z0-9_]{2,63}$ ]]; then
    echo "Unsafe table name in RESTORE_REQUIRED_TABLES" >&2
    exit 1
  fi
  table_exists=$(MYSQL_PWD=$DB_ADMIN_PASSWORD "${mysql_command[@]}" \
    --batch --skip-column-names \
    -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${database_name}' AND table_name='${table}';")
  if [[ $table_exists != 1 ]]; then
    echo "Restore drill failed: required table is missing: $table" >&2
    exit 1
  fi
done

if ! MYSQL_PWD=$DB_ADMIN_PASSWORD "${mysql_command[@]}" \
  -e "DROP DATABASE IF EXISTS \`$database_name\`;" >/dev/null; then
  echo "Restore drill passed validation but the disposable database could not be removed" >&2
  exit 1
fi
database_created=false
drill_result=passed
echo "Restore drill passed with $migration_count migrations."
echo "The disposable database $database_name was removed."
