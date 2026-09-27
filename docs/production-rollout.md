# Production rollout

The split services are introduced without replacing the currently running
Platform until each dependency is verified. Run the steps in this order.

## 1. Verify SSH identity

Do not accept a new SSH host key without comparing its fingerprint. In each
Droplet's DigitalOcean Recovery Console, run:

```bash
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

Compare that SHA-256 fingerprint with a local `ssh-keyscan` result. Add the key
to `known_hosts` only after an exact match. This is required once for:

```text
ams3-api-01.legacyh.fyi
ams3-panel-01.legacyh.fyi
ams3-sso-01.legacyh.fyi
ams3-hub-01.legacyh.fyi
fra1-status-01.legacyh.fyi
```

## 2. Bootstrap and audit

Clone a reviewed LH-Ops revision on each host, then run:

```bash
sudo scripts/bootstrap-ubuntu.sh
sudo scripts/install-node-runtime.sh
sudo scripts/install-digitalocean-monitoring.sh
sudo scripts/audit-service-host.sh SERVICE
```

The audit must pass before secrets or release archives are copied to the host.

## 3. Prepare dependencies

1. Create the isolated `legacyhosting_sso` database and user.
2. Trust only `ams3-api-01` and `ams3-sso-01` in Managed MySQL.
3. Copy the DigitalOcean database CA to API and SSO.
4. Install encrypted API and SSO backup jobs and complete a restore drill.
5. Promote a verified LH-Agent release on API.
6. Create protected service environment files with mode `0600`.
7. Generate the SSO private JWKS directly on `ams3-sso-01`.

Do not place database credentials on Panel, Hub, Status, or Discord.

## 4. Issue origin certificates

Point each public DNS record at its new host before requesting its certificate.
If Cloudflare proxying prevents the HTTP-01 challenge, temporarily set only
that record to DNS-only, issue the certificate, then restore the proxy.

```bash
sudo scripts/issue-service-certificate.sh SERVICE angel@legacyhosting.xyz
sudo scripts/audit-service-host.sh SERVICE --deploy-ready
```

The deployed Nginx sites preserve the ACME challenge path on HTTP and HTTPS,
so normal `certbot renew` runs can continue without taking the service down.

## 5. Deploy in dependency order

1. SSO with `OIDC_LOGIN_MODE=legacy_bridge`.
2. API and its three PM2 workers.
3. Panel, followed by the Discord process on the same host.
4. Hub.
5. Status in FRA1.
6. Migrate passkeys in dry-run mode, then apply and verify the counts.
7. Change SSO to `OIDC_LOGIN_MODE=passkey` only after browser verification.

Use only versioned archives and matching SHA-256 files from `LH-Releases`.
Run the service-owned verification script after every deployment.

## 6. Cut over and retire Platform

Move one public DNS record at a time. Verify health, authentication, browser
flows, deploy commands, logs, monitoring, certificate renewal, and rollback
before moving the next record. Keep the previous Platform deployment available
until all split services have completed an observation window and a restore
drill. Archive LH-Platform only after that checkpoint.
