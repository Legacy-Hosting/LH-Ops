# Capacity testing

Capacity tests answer two different questions and must not mix them:

1. A production smoke profile verifies the real Cloudflare, Nginx, service,
   TLS, and database-readiness path at no more than 5 requests per second.
2. A capacity profile finds saturation only against an isolated staging clone
   with production-like CPU, memory, database indexes, and anonymized data.

Never run the capacity profile against `api.legacyhosting.xyz` or
`auth.legacyhosting.xyz`. The HTTP harness enforces this even when the operator
confirms the hostname. All routes are limited to `GET` and `HEAD`.

## Production smoke test

Run one service at a time while DigitalOcean CPU, memory, load, network, and
Managed MySQL connections/CPU are visible:

```bash
mkdir -p load-test-reports
node scripts/load-http.mjs load-tests/api-production-smoke.json \
  --confirm-host api.legacyhosting.xyz \
  --output load-test-reports/api-$(date -u +%Y%m%dT%H%M%SZ).json

node scripts/load-http.mjs load-tests/sso-production-smoke.json \
  --confirm-host auth.legacyhosting.xyz \
  --output load-test-reports/sso-$(date -u +%Y%m%dT%H%M%SZ).json
```

The report fails if readiness JSON is degraded even when an endpoint returns
HTTP 200. It also enforces success rate, network-error count, p95/p99 latency,
and minimum achieved throughput. Do not weaken a threshold just to make a run
green; retain the failed report and document the cause.

Abort the run when database CPU stays above 70%, memory exceeds 80%, active
connections approach 80% of the cluster limit, slow-query count rises rapidly,
or any customer request starts failing. A production smoke result establishes
availability only; it is not a capacity claim.

## Staging capacity ladder

Clone the production service size and schema into an isolated VPC target. Use
anonymized data with comparable row counts and distributions. Start from
`load-tests/nonproduction-capacity.example.json` and run a ladder such as 5,
10, 25, 50, and 100 requests per second. Hold each level for at least two
minutes, change one variable at a time, and stop at the first failed threshold
or resource abort condition.

Record for every level:

- exact service commit and configuration;
- Droplet and database plan;
- request mix, concurrency, duration, and achieved RPS;
- p50, p95, p99, maximum latency, status codes, and network errors;
- service CPU/memory and MySQL CPU/memory/connections;
- top Performance Schema statement digests and rows examined/sent;
- the first saturated component and the rollback or scaling decision.

## Direct MySQL read benchmark

The database test uses persistent `mysql` sessions rather than spawning a
client for every query. It accepts exactly one read-only `SELECT`, `SHOW`, or
`EXPLAIN` statement, rejects mutation/admin keywords, caps concurrency at 10
and total statements at 100,000, verifies TLS identity, and refuses accounts
with write or administrative grants.

Create a dedicated user with only `SELECT` on the one test schema. If
Performance Schema visibility requires extra access, grant only the documented
read access needed for `events_statements_summary_by_digest`; never reuse an
application, migration, backup, or admin credential.

Install a protected configuration based on
`env/mysql-load-test.env.example`, copy the relevant query from `load-tests/`
to `/etc/legacy-hosting/load-tests`, then run during an approved window:

```bash
sudo env LH_LOAD_TEST_CONFIRM=legacyhosting_api \
  scripts/load-test-mysql.sh \
  /etc/legacy-hosting/load-tests/api.env \
  /var/log/legacy-hosting/load-tests
```

The mode-`0600` JSON report contains before/after global status and the top
Performance Schema digests, but never the password or full connection string.
Run concurrency 1 first, then 2 and 5. Do not run the HTTP and direct database
tests simultaneously, do not enable `log_queries_not_using_indexes` for the
benchmark, and do not raise concurrency after an abort condition.

## Initial acceptance gates

Before customer growth, the production smoke profile must pass three times at
separate times of day. The staging ladder must sustain the documented expected
peak plus 100% headroom for ten minutes with:

- at least 99.9% successful requests;
- p95 at or below 300 ms and p99 at or below 1 second for the public read mix;
- no network errors, HTTP 5xx responses, or exhausted connection queues;
- database CPU below 70% sustained and memory below 80%;
- no new unindexed high-volume statement digest.

These are engineering gates, not a customer SLA. Re-run the smoke profile
after infrastructure, schema/index, connection-pool, proxy, or major runtime
changes.
