# Legacy Hosting Operations

Private infrastructure repository for shared Legacy Hosting operations. It owns server topology, common Ubuntu bootstrap, encrypted database backup jobs, restore drills, hardening policy, and future Terraform/Ansible code.

This repository is deliberately not a deployment monolith. Service-specific Nginx files, PM2 definitions, environment validation, deployment, rollback, and release scripts belong to the service repository that uses them.

## Layout

```text
docs/          Architecture and ownership rules
env/           Non-secret environment templates
inventory/     Committed topology without credentials
logrotate/     Shared retention policy for Legacy Hosting Nginx logs
scripts/       Shared idempotent operational scripts
systemd/       Shared systemd unit templates
```

Never commit Terraform state, private inventory, `.env` files, tokens, certificates, database passwords, age identities, or SSH keys.

The ordered production procedure is in
[`docs/production-rollout.md`](docs/production-rollout.md).

## Release signatures

New production archives use a detached Ed25519 signature in addition to their
SHA-256 manifest. `scripts/sign-release-artifact.sh` creates the signature and
immediately verifies it against the derived public key;
`scripts/verify-release-artifact.sh` validates the pinned public key, checksum,
filename, and archive before extraction. Each service uses an independent
private key held by its release workflow. Key generation, custody, rotation,
and server provisioning are documented in
[`docs/release-signing.md`](docs/release-signing.md).

## Service host bootstrap

All five service hosts use Ubuntu 26.04 LTS and the same pinned runtime baseline. From a reviewed checkout on each new Droplet, run:

```bash
sudo scripts/bootstrap-ubuntu.sh
sudo scripts/install-node-runtime.sh
sudo scripts/install-digitalocean-monitoring.sh
sudo scripts/install-release-verifier.sh SERVICE PUBLIC_KEY EXPECTED_SHA256_FINGERPRINT
sudo scripts/audit-service-host.sh SERVICE
```

Replace `SERVICE` with `api`, `panel`, `sso`, `hub`, or `status`. Add
`--deploy-ready` after certificates, protected environment files, and database
backup prerequisites have been installed. Install both the API and Agent keys
on the API host, and both the Panel and Discord keys on the Panel host.

The bootstrap requires Ubuntu 26.04 LTS, installs Certbot with its Nginx and
Cloudflare DNS plugins,
and activates at least 2 GiB of persistent swap for the 1 GiB service Droplets.
The runtime installer downloads the [official Node.js 24.21.0 release](https://nodejs.org/dist/v24.21.0/) and verifies it against its official SHA-256 manifest before installing pnpm 12.4.1 and PM2 7.0.4. The monitoring installer follows DigitalOcean's [signed repository installation](https://docs.digitalocean.com/products/monitoring/how-to/install-metrics-agent-repository/), verifies the expected signing-key fingerprint, installs `do-agent`, and requires the service to be active. Firewall and SSH policy remain a separate reviewed operation because applying an incorrect rule remotely can lock out the server.

## Capacity and latency tests

`scripts/load-http.mjs` provides dependency-free, rate-limited HTTP smoke and
staging-capacity profiles with readiness assertions, p50/p95/p99 latency,
throughput, status/error counts, and machine-readable threshold reports.
Production hosts accept only the bounded smoke profile and require exact
hostname confirmation. `scripts/load-test-mysql.sh` runs a separately
confirmed, TLS-verified, SELECT-only database workload with a dedicated
read-only account and captures before/after Performance Schema evidence.

Use the procedure and stop conditions in
[`docs/capacity-testing.md`](docs/capacity-testing.md). Generated reports can
contain topology and statement digests and must stay outside Git.

## Database backups

API and SSO use separate root-owned backup environment files:

```text
/etc/legacy-hosting/backups/api.env
/etc/legacy-hosting/backups/sso.env
```

Install the shared scripts and timers from a clean checkout:

```bash
sudo scripts/install-backup-jobs.sh
sudo systemctl enable --now lh-mysql-backup@api.timer
sudo systemctl enable --now lh-mysql-backup@sso.timer
```

The timers create encrypted backups below `/var/backups/legacy-hosting/mysql/<name>`. Restore drills always target a new, validated disposable database and remove only that database afterward.

Each backup is a transaction-consistent, compressed MySQL dump encrypted to an
`age` public recipient before it receives its final atomic filename. The job
uploads the encrypted file and checksum to a private DigitalOcean Spaces bucket
through `rclone`, reads the remote object back to verify its SHA-256 hash, and
fails the systemd unit if off-site verification does not pass. Credentials are
provided to rclone through its environment-based remote configuration and do
not appear in command arguments. Use a separate scoped Spaces key and bucket
for API and SSO in FRA1, outside the AMS3 database failure region.

The database backup users need only `SELECT`, `SHOW VIEW`, and `TRIGGER` on
their own database. They must not receive write access, global privileges, or
access to the other service database. Stored routines and MySQL events are not
dumped because neither service defines them.

Retention is 14 days locally, 35 daily copies off-site, 12 monthly copies, and
3 yearly copies. Monthly and yearly copies are created from the UTC backup run
on the first day of the month/year. Concurrent manual and timer runs are
rejected with `flock`.

Generate the age identity on a separate trusted operator machine, copy only its
public recipient into `api.env` and `sso.env`, and keep the private identity out
of both database hosts and the Spaces account. After creating each mode-`0600`
environment file, verify the first run before enabling its timer:

```bash
sudo systemctl start lh-mysql-backup@api.service
sudo journalctl -u lh-mysql-backup@api.service --since today
sudo systemctl enable --now lh-mysql-backup@api.timer
```

Restore credentials and the private age identity belong in a separate,
temporary operator environment based on `env/api-restore.env.example` or
`env/sso-restore.env.example`. Download a backup and checksum into the matching
local backup directory, then run a named, audited drill:

```bash
sudo env LH_RESTORE_OPERATOR=operator@example.com \
  /usr/local/lib/legacy-hosting-ops/restore-drill.sh \
  /etc/legacy-hosting/backups/api-restore.env \
  /var/backups/legacy-hosting/mysql/api/api-YYYYMMDDTHHMMSSZ.sql.gz.age
```

The drill verifies checksum, TLS, migration ledger, and service-specific core
tables, writes a secret-free JSONL result to
`/var/log/legacy-hosting/restore-drills.jsonl`, and drops only its generated
disposable database.

## Customer persistent-file backups

Persistent application data is backed up on hosting nodes, independently of
the control-plane database. Opt-in is explicit: an application is protected
only after Infrastructure installs a root-owned mode-`0600` environment file
and path allowlist from `env/application-backup.env.example` and
`env/application.paths.example`, then enables its timer instance:

```bash
sudo scripts/install-backup-jobs.sh
sudo systemctl start lh-application-backup@APPLICATION.service
sudo systemctl enable --now lh-application-backup@APPLICATION.timer
```

The allowlist must exactly match the application's `file:` and `directory:`
entries in LH-Panel. The job rejects absolute paths, traversal, symlinks in any
path component, sockets/devices, database files, caches, `node_modules`, and
temporary paths. A root-only snapshot is compressed, encrypted with the public
`age` recipient, uploaded to a private FRA1 Spaces bucket, and read back for
SHA-256 verification. The private `age` identity never belongs in the daily
backup configuration or on the Spaces account.

Initial retention is 2 days locally, 35 daily copies, 12 monthly copies, and 3
yearly copies off-site. Successful backups, retention deletions, failed jobs,
staging, and live restores are recorded without secrets in
`/var/log/legacy-hosting/application-backups.jsonl`.

Restore is intentionally two-step. Download the selected encrypted archive and
its checksum into `/var/backups/legacy-hosting/applications/APPLICATION_ID`,
install a temporary mode-`0600` restore configuration based on
`env/application-restore.env.example`, and stage it first:

```bash
sudo env LH_RESTORE_OPERATOR=operator@example.com \
  /usr/local/lib/legacy-hosting-ops/stage-application-restore.sh \
  /etc/legacy-hosting/application-backups/APPLICATION-restore.env \
  /var/backups/legacy-hosting/applications/APPLICATION_ID/APPLICATION-TIMESTAMP.tar.gz.age
```

Staging verifies the checksum, decrypts, validates the manifest and current
allowlist, rejects unsafe archive members and symlinks, and does not touch live
data. After reviewing the staged restore, apply it with an explicit application
ID confirmation:

```bash
sudo env LH_RESTORE_OPERATOR=operator@example.com \
  LH_RESTORE_CONFIRM=APPLICATION_ID \
  /usr/local/lib/legacy-hosting-ops/apply-application-restore.sh \
  /etc/legacy-hosting/application-backups/APPLICATION-restore.env \
  /var/lib/legacy-hosting/application-restores/APPLICATION_ID/STAGING_NAME
```

Apply stops only the configured PM2 processes, takes a local pre-restore copy,
replaces each allowlisted path, and restarts those processes. A failed apply
restores already changed paths from that copy. Successful pre-restore copies
are kept locally for 7 days. Remove the temporary private identity and restore
environment immediately after the operation.

## Agent distribution on the API server

LH-API serves the installer and immutable LH-Agent runtime from
`/var/lib/legacy-hosting/agent-distributions/current`. Promote a verified
LH-Agent release on the API server with:

```bash
sudo scripts/install-agent-distribution.sh \
  /path/to/lh-agent-1.0.32.tar.gz \
  /path/to/lh-agent-1.0.32.tar.gz.sha256 \
  /path/to/lh-agent-1.0.32.tar.gz.sig \
  1.0.32
```

Set `AGENT_DISTRIBUTION_DIRECTORY` in `/etc/legacy-hosting/api.env` to that
`current` path. The script verifies the release checksum, extracts the
installer, keeps earlier versions, and switches the active distribution with
an atomic symlink replacement.
