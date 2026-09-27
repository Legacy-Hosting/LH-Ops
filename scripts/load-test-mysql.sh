#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 /etc/legacy-hosting/load-tests/NAME.env [REPORT_DIRECTORY]" >&2
  exit 2
fi
environment_file=$(readlink -f "$1")
config_directory=/etc/legacy-hosting/load-tests
if [[ ! -f $environment_file || -L $environment_file || \
      $environment_file != "$config_directory"/*.env ]]; then
  echo "MySQL load-test configuration must be an .env file under $config_directory" >&2
  exit 1
fi
permissions=$(stat -c '%a' "$environment_file")
owner=$(stat -c '%u' "$environment_file")
if (( (8#$permissions & 077) != 0 )) || [[ $owner != 0 ]]; then
  echo "MySQL load-test configuration must be root-owned with mode 0600 or stricter" >&2
  exit 1
fi
# The file is safe to source because it is root-owned and not group/world readable.
# shellcheck disable=SC1090
. "$environment_file"

required=(
  LOAD_TEST_NAME DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD DB_SSL_CA
  DB_QUERY_FILE DB_CONCURRENCY DB_QUERIES_PER_WORKER
  MINIMUM_QUERIES_PER_SECOND MAXIMUM_TOTAL_SECONDS
)
for name in "${required[@]}"; do
  if [[ -z ${!name:-} ]]; then
    echo "Missing MySQL load-test setting: $name" >&2
    exit 1
  fi
done
if [[ ! $LOAD_TEST_NAME =~ ^[a-z0-9][a-z0-9-]{1,63}$ ]]; then
  echo "LOAD_TEST_NAME must be a lowercase identifier" >&2
  exit 1
fi
if [[ ! $DB_PORT =~ ^[0-9]+$ ]] || (( DB_PORT < 1 || DB_PORT > 65535 )); then
  echo "DB_PORT must be between 1 and 65535" >&2
  exit 1
fi
if [[ ! $DB_NAME =~ ^[A-Za-z0-9_]{1,64}$ ]]; then
  echo "DB_NAME must be a safe MySQL schema name" >&2
  exit 1
fi
if [[ ! $DB_CONCURRENCY =~ ^[0-9]+$ ]] || \
   (( DB_CONCURRENCY < 1 || DB_CONCURRENCY > 10 )); then
  echo "DB_CONCURRENCY must be between 1 and 10" >&2
  exit 1
fi
if [[ ! $DB_QUERIES_PER_WORKER =~ ^[0-9]+$ ]] || \
   (( DB_QUERIES_PER_WORKER < 1 || DB_QUERIES_PER_WORKER > 10000 )); then
  echo "DB_QUERIES_PER_WORKER must be between 1 and 10000" >&2
  exit 1
fi
total_queries=$((DB_CONCURRENCY * DB_QUERIES_PER_WORKER))
if (( total_queries > 100000 )); then
  echo "A single run may execute at most 100000 read-only queries" >&2
  exit 1
fi
if [[ ! $MINIMUM_QUERIES_PER_SECOND =~ ^[0-9]+([.][0-9]+)?$ || \
      ! $MAXIMUM_TOTAL_SECONDS =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "MySQL thresholds must be positive numbers" >&2
  exit 1
fi
if ! awk -v minimum="$MINIMUM_QUERIES_PER_SECOND" -v maximum="$MAXIMUM_TOTAL_SECONDS" \
  'BEGIN { exit !(minimum > 0 && maximum > 0) }'; then
  echo "MySQL thresholds must be greater than zero" >&2
  exit 1
fi
if [[ ${LH_LOAD_TEST_CONFIRM:-} != "$DB_NAME" ]]; then
  echo "Set LH_LOAD_TEST_CONFIRM=$DB_NAME to authorize the bounded read-only test" >&2
  exit 1
fi
if [[ ! -r $DB_SSL_CA || -L $DB_SSL_CA ]]; then
  echo "Database CA must be a readable regular file" >&2
  exit 1
fi
DB_QUERY_FILE=$(readlink -f "$DB_QUERY_FILE")
if [[ ! -f $DB_QUERY_FILE || -L $DB_QUERY_FILE || \
      $DB_QUERY_FILE != "$config_directory"/*.sql ]]; then
  echo "DB_QUERY_FILE must be a regular .sql file under $config_directory" >&2
  exit 1
fi
query_owner=$(stat -c '%u' "$DB_QUERY_FILE")
query_permissions=$(stat -c '%a' "$DB_QUERY_FILE")
if [[ $query_owner != 0 ]] || (( (8#$query_permissions & 022) != 0 )); then
  echo "DB_QUERY_FILE must be root-owned and not group/world writable" >&2
  exit 1
fi
for command in awk date flock jq mysql sed tr; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Required MySQL load-test command is unavailable: $command" >&2
    exit 1
  fi
done

lock_file="/run/lock/lh-mysql-load-test-$LOAD_TEST_NAME.lock"
exec 9>"$lock_file"
if ! flock -n 9; then
  echo "Another $LOAD_TEST_NAME database load test is already running" >&2
  exit 1
fi

if grep -Eq '(^|[[:space:]])(--|#)|/\*|\*/' "$DB_QUERY_FILE"; then
  echo "DB_QUERY_FILE must contain one explicit statement without comments" >&2
  exit 1
fi
statement=$(tr '\r\n\t' '   ' < "$DB_QUERY_FILE" | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//;s/[[:space:]]+/ /g')
statement=${statement%;}
if [[ -z $statement || $statement == *';'* ]]; then
  echo "DB_QUERY_FILE must contain exactly one SQL statement" >&2
  exit 1
fi
if ! grep -Eiq '^(SELECT|SHOW|EXPLAIN)[[:space:]]' <<< "$statement"; then
  echo "Only SELECT, SHOW, or EXPLAIN statements are allowed" >&2
  exit 1
fi
if grep -Eiq '(^|[^A-Za-z_])(INSERT|UPDATE|DELETE|REPLACE|CREATE|ALTER|DROP|TRUNCATE|GRANT|REVOKE|CALL|LOAD|LOCK|UNLOCK|SET|INTO[[:space:]]+OUTFILE|INTO[[:space:]]+DUMPFILE|FOR[[:space:]]+UPDATE|SLEEP|BENCHMARK|GET_LOCK|RELEASE_LOCK)([^A-Za-z_]|$)' <<< "$statement"; then
  echo "DB_QUERY_FILE contains a forbidden operation" >&2
  exit 1
fi

mysql_args=(
  mysql --protocol=TCP --host="$DB_HOST" --port="$DB_PORT" --user="$DB_USER"
  --ssl-mode=VERIFY_IDENTITY --ssl-ca="$DB_SSL_CA" --connect-timeout=5
  --batch --skip-column-names --database="$DB_NAME"
)
grants=$(MYSQL_PWD=$DB_PASSWORD "${mysql_args[@]}" --execute 'SHOW GRANTS FOR CURRENT_USER')
if ! grep -Eiq 'GRANT .*SELECT' <<< "$grants" || \
   grep -Eiq 'ALL PRIVILEGES|INSERT|UPDATE|DELETE|REPLACE|CREATE|ALTER|DROP|TRUNCATE|GRANT OPTION|EXECUTE|FILE|SUPER' <<< "$grants"; then
  echo "The load-test account must be read-only and must not have administrative grants" >&2
  exit 1
fi
MYSQL_PWD=$DB_PASSWORD "${mysql_args[@]}" --execute 'SELECT 1' >/dev/null

report_directory=${2:-/var/log/legacy-hosting/load-tests}
if [[ $report_directory != /* ]]; then
  echo "REPORT_DIRECTORY must be absolute" >&2
  exit 1
fi
install -d -m 0700 "$report_directory"
temporary_directory=$(mktemp -d)
trap 'rm -rf -- "$temporary_directory"' EXIT
status_query="SHOW GLOBAL STATUS WHERE Variable_name IN ('Threads_connected','Threads_running','Questions','Slow_queries')"
digest_query="SELECT COALESCE(DIGEST_TEXT,''),COUNT_STAR,ROUND(SUM_TIMER_WAIT/1000000000000,6),ROUND(AVG_TIMER_WAIT/1000000000,6),SUM_ROWS_EXAMINED,SUM_ROWS_SENT FROM performance_schema.events_statements_summary_by_digest WHERE SCHEMA_NAME='${DB_NAME}' ORDER BY SUM_TIMER_WAIT DESC LIMIT 20"
before_status=$(MYSQL_PWD=$DB_PASSWORD "${mysql_args[@]}" --execute "$status_query")
before_digests=$(MYSQL_PWD=$DB_PASSWORD "${mysql_args[@]}" --execute "$digest_query" 2>/dev/null || printf 'performance_schema_unavailable')

started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
started_ns=$(date +%s%N)
declare -a workers=()
for ((worker = 1; worker <= DB_CONCURRENCY; worker += 1)); do
  (
    {
      printf 'SET SESSION MAX_EXECUTION_TIME=5000;\n'
      for ((query = 0; query < DB_QUERIES_PER_WORKER; query += 1)); do
        printf '%s;\n' "$statement"
      done
    } | MYSQL_PWD=$DB_PASSWORD "${mysql_args[@]}" >/dev/null
  ) 2>"$temporary_directory/worker-$worker.err" &
  workers+=("$!")
done
failed_workers=0
for worker in "${workers[@]}"; do
  if ! wait "$worker"; then failed_workers=$((failed_workers + 1)); fi
done
finished_ns=$(date +%s%N)
finished_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
if (( failed_workers > 0 )); then
  sed -n '1,20p' "$temporary_directory"/worker-*.err >&2
fi

elapsed_seconds=$(awk -v start="$started_ns" -v finish="$finished_ns" 'BEGIN { printf "%.6f", (finish-start)/1000000000 }')
queries_per_second=$(awk -v queries="$total_queries" -v elapsed="$elapsed_seconds" 'BEGIN { if (elapsed == 0) print 0; else printf "%.3f", queries/elapsed }')
throughput_passed=$(awk -v actual="$queries_per_second" -v minimum="$MINIMUM_QUERIES_PER_SECOND" 'BEGIN { print (actual >= minimum ? "true" : "false") }')
duration_passed=$(awk -v actual="$elapsed_seconds" -v maximum="$MAXIMUM_TOTAL_SECONDS" 'BEGIN { print (actual <= maximum ? "true" : "false") }')
workers_passed=false
if (( failed_workers == 0 )); then workers_passed=true; fi
after_status=$(MYSQL_PWD=$DB_PASSWORD "${mysql_args[@]}" --execute "$status_query")
after_digests=$(MYSQL_PWD=$DB_PASSWORD "${mysql_args[@]}" --execute "$digest_query" 2>/dev/null || printf 'performance_schema_unavailable')
passed=false
if [[ $workers_passed == true && $throughput_passed == true && $duration_passed == true ]]; then
  passed=true
fi

timestamp=$(date -u +%Y%m%dT%H%M%SZ)
report="$report_directory/${LOAD_TEST_NAME}-${timestamp}.json"
jq -n \
  --argjson formatVersion 1 \
  --arg name "$LOAD_TEST_NAME" \
  --arg database "$DB_NAME" \
  --arg startedAt "$started_at" \
  --arg finishedAt "$finished_at" \
  --argjson concurrency "$DB_CONCURRENCY" \
  --argjson queries "$total_queries" \
  --argjson elapsedSeconds "$elapsed_seconds" \
  --argjson queriesPerSecond "$queries_per_second" \
  --argjson failedWorkers "$failed_workers" \
  --argjson minimumQueriesPerSecond "$MINIMUM_QUERIES_PER_SECOND" \
  --argjson maximumTotalSeconds "$MAXIMUM_TOTAL_SECONDS" \
  --argjson throughputPassed "$throughput_passed" \
  --argjson durationPassed "$duration_passed" \
  --argjson workersPassed "$workers_passed" \
  --argjson passed "$passed" \
  --arg beforeStatus "$before_status" \
  --arg afterStatus "$after_status" \
  --arg beforeDigests "$before_digests" \
  --arg afterDigests "$after_digests" \
  '{formatVersion:$formatVersion,name:$name,database:$database,startedAt:$startedAt,finishedAt:$finishedAt,concurrency:$concurrency,queries:$queries,elapsedSeconds:$elapsedSeconds,queriesPerSecond:$queriesPerSecond,failedWorkers:$failedWorkers,thresholds:{minimumQueriesPerSecond:$minimumQueriesPerSecond,maximumTotalSeconds:$maximumTotalSeconds},checks:{throughput:$throughputPassed,duration:$durationPassed,workers:$workersPassed},performanceSchema:{before:$beforeDigests,after:$afterDigests},globalStatus:{before:$beforeStatus,after:$afterStatus},passed:$passed}' \
  > "$report"
chmod 0600 "$report"
trap - EXIT
rm -rf -- "$temporary_directory"
echo "MySQL load-test report: $report"
echo "Queries: $total_queries; elapsed: ${elapsed_seconds}s; throughput: ${queries_per_second} qps; passed: $passed"
if [[ $passed != true ]]; then exit 1; fi
