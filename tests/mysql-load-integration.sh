#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "MySQL load-test integration must run as root inside an isolated CI runner" >&2
  exit 1
fi
repository_root=$(cd "$(dirname "$0")/.." && pwd)
temporary_directory=$(mktemp -d)
fake_bin=$temporary_directory/bin
report_directory=$temporary_directory/reports
mysql_log=$temporary_directory/mysql.log
config_directory=/etc/legacy-hosting/load-tests
install -d -m 0755 "$fake_bin"

cleanup() {
  rm -f -- "$config_directory/ci-load.env" "$config_directory/ci-read.sql" \
    "$config_directory/ci-unsafe.sql" "$config_directory/ci-ca.crt"
  rm -rf -- "$temporary_directory"
  rmdir --ignore-fail-on-non-empty "$config_directory" /etc/legacy-hosting 2>/dev/null || true
}
trap cleanup EXIT

cat > "$fake_bin/mysql" <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
execute=
while (( $# > 0 )); do
  case $1 in
    --execute) execute=$2; shift 2 ;;
    *) shift ;;
  esac
done
case $execute in
  'SHOW GRANTS FOR CURRENT_USER')
    printf '%s\n' 'GRANT USAGE ON *.* TO `ci_load`@`%`' \
      'GRANT SELECT ON `legacyhosting_api`.* TO `ci_load`@`%`'
    ;;
  'SELECT 1') printf '1\n' ;;
  'SHOW GLOBAL STATUS'*)
    printf 'Questions\t100\nSlow_queries\t0\nThreads_connected\t2\nThreads_running\t1\n'
    ;;
  'SELECT COALESCE(DIGEST_TEXT'*)
    printf 'SELECT `status` , COUNT ( * ) FROM `applications`\t10\t0.010000\t1.000000\t20\t10\n'
    ;;
  '')
    count=$(grep -c '^SELECT ' || true)
    printf '%s\n' "$count" >> "$LH_TEST_MYSQL_LOAD_LOG"
    ;;
  *) echo "Unexpected mysql query: $execute" >&2; exit 1 ;;
esac
SCRIPT
chmod 0755 "$fake_bin/mysql"

install -d -m 0700 "$config_directory"
install -m 0644 /dev/null "$config_directory/ci-ca.crt"
cat > "$config_directory/ci-read.sql" <<'SQL'
SELECT status, COUNT(*) AS application_count
FROM applications
WHERE deleted_at IS NULL
GROUP BY status
SQL
cat > "$config_directory/ci-load.env" <<'ENV'
LOAD_TEST_NAME=ci-api-read
DB_HOST=mysql.internal
DB_PORT=25060
DB_NAME=legacyhosting_api
DB_USER=ci_load
DB_PASSWORD=not-a-real-password
DB_SSL_CA=/etc/legacy-hosting/load-tests/ci-ca.crt
DB_QUERY_FILE=/etc/legacy-hosting/load-tests/ci-read.sql
DB_CONCURRENCY=3
DB_QUERIES_PER_WORKER=7
MINIMUM_QUERIES_PER_SECOND=0.1
MAXIMUM_TOTAL_SECONDS=20
ENV
chmod 0600 "$config_directory/ci-load.env"
chmod 0644 "$config_directory/ci-read.sql"

export LH_TEST_MYSQL_LOAD_LOG=$mysql_log
PATH="$fake_bin:$PATH" LH_LOAD_TEST_CONFIRM=legacyhosting_api \
  bash "$repository_root/scripts/load-test-mysql.sh" \
  "$config_directory/ci-load.env" "$report_directory"
report=$(find "$report_directory" -maxdepth 1 -type f -name 'ci-api-read-*.json' -print -quit)
[[ -n $report && $(stat -c '%a' "$report") == 600 ]]
jq -e '.passed == true and .queries == 21 and .concurrency == 3 and .performanceSchema.after != ""' \
  "$report" >/dev/null
executed=$(awk '{ total += $1 } END { print total }' "$mysql_log")
[[ $executed == 21 ]]

printf '%s\n' 'DELETE FROM applications' > "$config_directory/ci-unsafe.sql"
chmod 0644 "$config_directory/ci-unsafe.sql"
sed 's#ci-read.sql#ci-unsafe.sql#' "$config_directory/ci-load.env" \
  > "$temporary_directory/unsafe.env"
install -m 0600 "$temporary_directory/unsafe.env" "$config_directory/ci-load.env"
if PATH="$fake_bin:$PATH" LH_LOAD_TEST_CONFIRM=legacyhosting_api \
  bash "$repository_root/scripts/load-test-mysql.sh" \
  "$config_directory/ci-load.env" "$report_directory" >/dev/null 2>&1; then
  echo "MySQL load test accepted a mutating statement" >&2
  exit 1
fi

echo "Bounded read-only MySQL load test and mutation rejection passed."
