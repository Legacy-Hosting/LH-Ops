# Legacy Hosting Operations

Private infrastructure repository for shared Legacy Hosting operations. It owns server topology, common Ubuntu bootstrap, encrypted database backup jobs, restore drills, hardening policy, and future Terraform/Ansible code.

This repository is deliberately not a deployment monolith. Service-specific Nginx files, PM2 definitions, environment validation, deployment, rollback, and release scripts belong to the service repository that uses them.

## Layout

```text
docs/          Architecture and ownership rules
env/           Non-secret environment templates
inventory/     Committed topology without credentials
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
