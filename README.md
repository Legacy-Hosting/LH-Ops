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

## Database backups

API and SSO use separate environment files:

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

## Agent distribution on the API server

LH-API serves the installer and immutable LH-Agent runtime from
`/var/lib/legacy-hosting/agent-distributions/current`. Promote a verified
LH-Agent release on the API server with:

```bash
sudo scripts/install-agent-distribution.sh \
  /path/to/lh-agent-1.0.0.tar.gz \
  /path/to/lh-agent-1.0.0.tar.gz.sha256 \
  1.0.0
```

Set `AGENT_DISTRIBUTION_DIRECTORY` in `/etc/legacy-hosting/api.env` to that
`current` path. The script verifies the release checksum, extracts the
installer, keeps earlier versions, and switches the active distribution with
an atomic symlink replacement.
