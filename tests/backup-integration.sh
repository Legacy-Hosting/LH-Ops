#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Backup integration test must run as root inside an isolated CI runner" >&2
  exit 1
fi
repository_root=$(cd "$(dirname "$0")/.." && pwd)
temporary_directory=$(mktemp -d)
fake_bin=$temporary_directory/bin
remote_root=$temporary_directory/remote
mysql_log=$temporary_directory/mysql.log
config_directory=/etc/legacy-hosting/backups
backup_directory=/var/backups/legacy-hosting/mysql/ci-test
restore_audit=/var/log/legacy-hosting/restore-drills.jsonl
audit_backup=$temporary_directory/restore-drills.original.jsonl
audit_existed=false
install -d -m 0755 "$fake_bin"
if [[ -f $restore_audit ]]; then
  cp -- "$restore_audit" "$audit_backup"
  audit_existed=true
fi

cleanup() {
  if [[ $audit_existed == true ]]; then
    cp -- "$audit_backup" "$restore_audit"
  else
    rm -f -- "$restore_audit"
  fi
  rm -f -- "$config_directory/ci-test.env" \
    "$config_directory/ci-test-restore.env" \
    "$config_directory/ci-test-ca.pem" \
    "$config_directory/ci-test-age-key.txt"
  rm -f -- /run/lock/lh-mysql-backup-ci-test.lock
  rm -rf -- "$backup_directory" "$temporary_directory"
  rmdir --ignore-fail-on-non-empty /var/log/legacy-hosting \
    /var/backups/legacy-hosting/mysql /var/backups/legacy-hosting \
    "$config_directory" /etc/legacy-hosting 2>/dev/null || true
}
trap cleanup EXIT

cat > "$fake_bin/mysqldump" <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' 'CREATE TABLE schema_migrations (migration varchar(255));' \
  'INSERT INTO schema_migrations VALUES ("001_test.sql");'
SCRIPT
cat > "$fake_bin/age" <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ ${1:-} == --decrypt ]]; then
  shift
  [[ ${1:-} == --identity ]]
  shift 2
  cat -- "$1"
  exit 0
fi
output=
input=
while (( $# > 0 )); do
  case $1 in
    --recipient) shift 2 ;;
    --output) output=$2; shift 2 ;;
    *) input=$1; shift ;;
  esac
done
cp -- "$input" "$output"
SCRIPT
cat > "$fake_bin/rclone" <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
command=$1
shift
remote_path() {
  printf '%s/%s' "$LH_TEST_REMOTE_ROOT" "${1#lhbackup:}"
}
case $command in
  copyto)
    if [[ ${1:-} == --no-traverse ]]; then shift; fi
    source=$1
    destination=$(remote_path "$2")
    mkdir -p "$(dirname "$destination")"
    cp -- "$source" "$destination"
    ;;
  cat)
    cat -- "$(remote_path "$1")"
    ;;
  lsf)
    [[ -d $(remote_path "$1") ]]
    ;;
  delete)
    ;;
  *)
    echo "Unexpected fake rclone command: $command" >&2
    exit 1
    ;;
esac
SCRIPT
cat > "$fake_bin/mysql" <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >> "$LH_TEST_MYSQL_LOG"
arguments=$*
if [[ $arguments == *'SELECT COUNT(*) FROM `schema_migrations`'* ]]; then
  printf '24\n'
elif [[ $arguments == *'information_schema.tables'* ]]; then
  printf '1\n'
elif [[ $arguments != *' -e '* && $arguments != -e\ * ]]; then
  cat >/dev/null
fi
SCRIPT
chmod 0755 "$fake_bin"/*

install -d -m 0700 "$config_directory" /var/backups/legacy-hosting/mysql
install -m 0644 /dev/null "$config_directory/ci-test-ca.pem"
cat > "$config_directory/ci-test.env" <<'ENV'
BACKUP_NAME=ci-test
DB_HOST=mysql.internal
DB_PORT=25060
DB_NAME=ci_test
DB_USER=ci_backup
DB_PASSWORD=not-a-real-password
DB_SSL_CA=/etc/legacy-hosting/backups/ci-test-ca.pem
BACKUP_AGE_RECIPIENT=age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
BACKUP_RETENTION_DAYS=14
BACKUP_S3_ENDPOINT=ams3.digitaloceanspaces.com
BACKUP_S3_BUCKET=legacy-hosting-ci-backups
BACKUP_S3_PREFIX=mysql
BACKUP_S3_ACCESS_KEY_ID=CIACCESSKEY000000
BACKUP_S3_SECRET_ACCESS_KEY=ci-secret-key-with-more-than-32-characters
ENV
chmod 0600 "$config_directory/ci-test.env"

export LH_TEST_REMOTE_ROOT=$remote_root
export LH_TEST_MYSQL_LOG=$mysql_log
PATH="$fake_bin:$PATH" bash "$repository_root/scripts/backup-mysql.sh" \
  "$config_directory/ci-test.env"

backup=$(find "$backup_directory" -maxdepth 1 -type f -name 'ci-test-*.sql.gz.age' -print -quit)
[[ -n $backup && -f $backup.sha256 ]]
[[ $(stat -c '%a' "$backup") == 600 ]]
if find "$backup_directory" -maxdepth 1 -type f -name '*.sql.gz' | grep -q .; then
  echo "Plaintext backup survived the encrypted backup job" >&2
  exit 1
fi
remote_backup=$(find "$remote_root" -type f -path '*/daily/ci-test-*.sql.gz.age' -print -quit)
[[ -n $remote_backup ]]
cmp -s "$backup" "$remote_backup"

install -m 0600 /dev/null "$config_directory/ci-test-age-key.txt"
cat > "$config_directory/ci-test-restore.env" <<'ENV'
BACKUP_NAME=ci-test
DB_HOST=mysql.internal
DB_PORT=25060
DB_ADMIN_USER=ci_restore
DB_ADMIN_PASSWORD=not-a-real-admin-password
DB_SSL_CA=/etc/legacy-hosting/backups/ci-test-ca.pem
BACKUP_AGE_IDENTITY=/etc/legacy-hosting/backups/ci-test-age-key.txt
RESTORE_DATABASE_PREFIX=lh_ci_restore_drill
MIGRATION_TABLE=schema_migrations
RESTORE_REQUIRED_TABLES="users teams applications"
ENV
chmod 0600 "$config_directory/ci-test-restore.env"

before_lines=0
if [[ -f $restore_audit ]]; then before_lines=$(wc -l < "$restore_audit"); fi
PATH="$fake_bin:$PATH" LH_RESTORE_OPERATOR=ci@example.com \
  bash "$repository_root/scripts/restore-drill.sh" \
  "$config_directory/ci-test-restore.env" "$backup"
after_lines=$(wc -l < "$restore_audit")
[[ $after_lines -eq $((before_lines + 1)) ]]
tail -n 1 "$restore_audit" | jq -e '.result == "passed" and .operator == "ci@example.com"' >/dev/null
grep -q 'DROP DATABASE IF EXISTS' "$mysql_log"

chmod 0640 "$config_directory/ci-test.env"
if PATH="$fake_bin:$PATH" bash "$repository_root/scripts/backup-mysql.sh" \
  "$config_directory/ci-test.env" >/dev/null 2>&1; then
  echo "Backup job accepted a group-readable environment file" >&2
  exit 1
fi

echo "Encrypted backup and audited restore integration test passed."
