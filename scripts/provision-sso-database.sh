#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

backup_environment=${1:-/etc/legacy-hosting/backup.env}
api_environment=${2:-/etc/legacy-hosting/api.env}
output=${3:-/root/sso-database.env}

if [[ ${EUID} -ne 0 ]]; then
  echo "Run this script as root on the existing API host." >&2
  exit 1
fi
for input in "$backup_environment" "$api_environment"; do
  if [[ ! -f $input || -L $input ]]; then
    echo "Protected environment must be a regular file: $input" >&2
    exit 1
  fi
  permissions=$(stat -c '%a' "$input")
  if (( (8#$permissions & 077) != 0 )); then
    echo "Protected environment is accessible to group or other users: $input" >&2
    exit 1
  fi
done
if [[ -e $output || -L $output ]]; then
  echo "Refusing to overwrite SSO database transfer file: $output" >&2
  exit 1
fi
for command in mysql openssl stat; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "Required command is missing: $command" >&2
    exit 1
  }
done

set -a
. "$backup_environment"
set +a
for name in DB_ADMIN_USER DB_ADMIN_PASSWORD DB_HOST DB_PORT DB_SSL_CA; do
  if [[ -z ${!name:-} ]]; then
    echo "Missing database administrator setting: $name" >&2
    exit 1
  fi
done
if [[ ! $DB_HOST =~ ^[A-Za-z0-9.-]+$ || ! $DB_PORT =~ ^[0-9]{1,5}$ || ! -r $DB_SSL_CA ]]; then
  echo "Invalid database host, port, or CA file." >&2
  exit 1
fi

unset DATABASE_URL
set -a
. "$api_environment"
set +a
legacy_database_url=${DATABASE_URL:-}
if [[ -z $legacy_database_url ]]; then
  echo "The existing API environment does not define DATABASE_URL." >&2
  exit 1
fi

mysql_admin=(
  mysql --batch --skip-column-names
  --host="$DB_HOST" --port="$DB_PORT" --user="$DB_ADMIN_USER"
  --ssl-mode=VERIFY_CA --ssl-ca="$DB_SSL_CA"
)
schema_count=$(MYSQL_PWD="$DB_ADMIN_PASSWORD" "${mysql_admin[@]}" \
  -e "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name='legacyhosting_sso'")
user_count=$(MYSQL_PWD="$DB_ADMIN_PASSWORD" "${mysql_admin[@]}" \
  -e "SELECT COUNT(*) FROM mysql.user WHERE user='legacyhosting_sso'")
if [[ $schema_count != 0 || $user_count != 0 ]]; then
  echo "SSO database or user already exists; refusing to rotate unknown credentials." >&2
  exit 1
fi

database_password=$(openssl rand -hex 32)
MYSQL_PWD="$DB_ADMIN_PASSWORD" "${mysql_admin[@]}" <<SQL
CREATE DATABASE legacyhosting_sso CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'legacyhosting_sso'@'%' IDENTIFIED BY '$database_password';
GRANT ALL PRIVILEGES ON legacyhosting_sso.* TO 'legacyhosting_sso'@'%';
SQL

MYSQL_PWD="$database_password" mysql --batch --skip-column-names \
  --host="$DB_HOST" --port="$DB_PORT" --user=legacyhosting_sso \
  --ssl-mode=VERIFY_CA --ssl-ca="$DB_SSL_CA" \
  legacyhosting_sso -e 'SELECT DATABASE()' | grep -Fxq legacyhosting_sso

{
  printf 'DATABASE_URL=mysql://legacyhosting_sso:%s@%s:%s/legacyhosting_sso?ssl-mode=REQUIRED\n' \
    "$database_password" "$DB_HOST" "$DB_PORT"
  printf 'LEGACY_DATABASE_URL=%s\n' "$legacy_database_url"
} > "$output"
chmod 0600 "$output"
chown root:root "$output"

echo "Created isolated SSO database and protected transfer file: $output"

