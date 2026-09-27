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

## Service host bootstrap

All five service hosts use Ubuntu 26.04 LTS and the same pinned runtime baseline. From a reviewed checkout on each new Droplet, run:

```bash
sudo scripts/bootstrap-ubuntu.sh
sudo scripts/install-node-runtime.sh
sudo scripts/install-digitalocean-monitoring.sh
sudo scripts/audit-service-host.sh SERVICE
```

Replace `SERVICE` with `api`, `panel`, `sso`, `hub`, or `status`. Add
`--deploy-ready` after certificates, protected environment files, and database
backup prerequisites have been installed.

The bootstrap requires Ubuntu 26.04 LTS, installs Certbot with its Nginx and
Cloudflare DNS plugins,
and activates at least 2 GiB of persistent swap for the 1 GiB service Droplets.
The runtime installer downloads the [official Node.js 24.21.0 release](https://nodejs.org/dist/v24.21.0/) and verifies it against its official SHA-256 manifest before installing pnpm 12.4.1 and PM2 7.0.4. The monitoring installer follows DigitalOcean's [signed repository installation](https://docs.digitalocean.com/products/monitoring/how-to/install-metrics-agent-repository/), verifies the expected signing-key fingerprint, installs `do-agent`, and requires the service to be active. Firewall and SSH policy remain a separate reviewed operation because applying an incorrect rule remotely can lock out the server.

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

## Agent distribution on the API server

LH-API serves the installer and immutable LH-Agent runtime from
`/var/lib/legacy-hosting/agent-distributions/current`. Promote a verified
LH-Agent release on the API server with:

```bash
sudo scripts/install-agent-distribution.sh \
  /path/to/lh-agent-1.0.32.tar.gz \
  /path/to/lh-agent-1.0.32.tar.gz.sha256 \
  1.0.32
```

Set `AGENT_DISTRIBUTION_DIRECTORY` in `/etc/legacy-hosting/api.env` to that
`current` path. The script verifies the release checksum, extracts the
installer, keeps earlier versions, and switches the active distribution with
an atomic symlink replacement.
