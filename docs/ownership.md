# Operations ownership

## LH-Ops owns

- shared Ubuntu bootstrap and hardening;
- infrastructure inventory without credentials;
- future Terraform and Ansible code;
- DigitalOcean/VPC/firewall and Monitoring Agent policy;
- generic encrypted MySQL backup and restore-drill tooling;
- promotion of signed-off LH-Agent releases to the API distribution directory;
- disaster-recovery orchestration and cross-service smoke checks.

## Service repositories own

- their release archive and checksum generation;
- service-specific install, deploy, rollback, and health verification;
- PM2 or systemd process definitions;
- service-specific Nginx configuration;
- non-secret environment templates and environment validation;
- database migrations owned by that service.

## Files that must not survive the Platform migration

The old combined `build-release.sh`, `deploy-release.sh`, `rollback-release.sh`, `verify-release.sh`, and `configure-production.sh` couple API, Panel, and Agent into one release. They are retired instead of copied into LH-Ops.

The root `ops` directory can be deleted only after every retained file has a verified owner and the service-specific deployment scripts pass CI in their destination repositories.
