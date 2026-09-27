#!/usr/bin/env bash
set -Eeuo pipefail

repository_root=$(cd "$(dirname "$0")/.." && pwd)
http_test=$repository_root/scripts/load-http.mjs
mysql_test=$repository_root/scripts/load-test-mysql.sh

grep -q 'Production targets allow only the bounded smoke profile' "$http_test"
grep -q 'method !== "GET" && method !== "HEAD"' "$http_test"
grep -q 'minimumSuccessRate' "$http_test"
grep -q 'maximumP95Ms' "$http_test"
grep -q 'maximumP99Ms' "$http_test"
grep -q -- '--ssl-mode=VERIFY_IDENTITY' "$mysql_test"
grep -q 'SHOW GRANTS FOR CURRENT_USER' "$mysql_test"
grep -q 'performance_schema.events_statements_summary_by_digest' "$mysql_test"
grep -q 'LH_LOAD_TEST_CONFIRM' "$mysql_test"
if grep -Eq -- '--password(=|[[:space:]])' "$mysql_test"; then
  echo "Database passwords must not appear in process arguments" >&2
  exit 1
fi

node --input-type=module - "$repository_root" <<'NODE'
import { readFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";
import { resolve } from "node:path";

const root = process.argv[2];
const module = await import(pathToFileURL(resolve(root, "scripts/load-http.mjs")));
for (const file of ["api-production-smoke.json", "sso-production-smoke.json"]) {
  const raw = JSON.parse(await readFile(resolve(root, "load-tests", file), "utf8"));
  const config = module.validateHttpLoadConfig(raw);
  if (config.mode !== "smoke" || config.maxRequestsPerSecond > 5 || config.concurrency > 5) {
    throw new Error(`${file} exceeds the production smoke boundary`);
  }
  module.assertHttpTargetAllowed(config, new URL(config.baseUrl).hostname);
}
NODE

echo "Load-test safety policy checks passed."
