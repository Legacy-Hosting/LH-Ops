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
ams3.api-01.legacyh.fyi
ams3.panel-01.legacyh.fyi
ams3.sso-01.legacyh.fyi
ams3.hub-01.legacyh.fyi
fra1.status-01.legacyh.fyi
```

## 2. Bootstrap and audit

Clone a reviewed LH-Ops revision on each host, then run:

```bash
sudo scripts/bootstrap-ubuntu.sh
sudo scripts/install-digitalocean-monitoring.sh
sudo scripts/install-release-verifier.sh SERVICE PUBLIC_KEY EXPECTED_SHA256_FINGERPRINT
sudo scripts/audit-service-host.sh SERVICE
```

Run the host setup from an active SSH session or the DigitalOcean Recovery
Console. It discovers the effective SSH port and permits it before UFW is
enabled, preserves existing firewall rules, opens ports 80 and 443, and starts
the Fail2Ban SSH jail. The audit must pass before secrets or release archives
are copied to the host.

After the node is enrolled in LH-Agent and the firewall migration has been
applied to LH-API, verify that its heartbeat appears in Panel. Fail2Ban keeps
the immediate local response; LH-Agent then reports public banned addresses to
LH-API and reconciles the global UFW denylist on each heartbeat. Administrative
unbans are performed only from **Admin → Firewall** so they propagate to every
online server and are recorded in the audit log.

## 3. Prepare dependencies

1. Create the isolated `legacyhosting_sso` database and user.
2. Trust only `ams3-api-01` and `ams3-sso-01` in Managed MySQL.
3. Copy the DigitalOcean database CA to API and SSO.
4. Install encrypted API and SSO backup jobs, verify each off-site Spaces object by SHA-256, and complete a named restore drill from the independent copy.
5. Promote a verified LH-Agent release on API.
6. Create protected service environment files with mode `0600`.
7. Generate the SSO private JWKS directly on `ams3-sso-01`.

Do not place database credentials on Panel, Hub, Status, or Discord.

## 4. Issue origin certificates

Issue certificates before changing public traffic. Create a Cloudflare API
token restricted to DNS edit access for only the `legacyhosting.xyz` zone,
then store it independently on each service host:

```ini
dns_cloudflare_api_token = replace-with-scoped-token
```

Protect the file with mode `0600`. Certbot stores its path for unattended
renewal, so retain it until that certificate is replaced with another renewal
method. The standard location on every service host is
`/root/.secrets/certbot/cloudflare.ini`. Its parent directories must use mode
`0700`; never apply a recursive file mode such as `chmod -R 640` because
directories require the execute bit. The bootstrap repairs these modes without
reading or replacing the token.

```bash
sudo scripts/issue-service-certificate.sh \
  SERVICE \
  angel@legacyhosting.xyz
sudo scripts/audit-service-host.sh SERVICE --deploy-ready
```

The certificate script automatically uses the standard Cloudflare credentials
file when it exists. An explicit third argument can still select another file.
Certificates issued for infrastructure names such as
`ams3.api-01.legacyh.fyi` may coexist, but they do not cover
`api.legacyhosting.xyz`, `panel.legacyhosting.xyz`,
`auth.legacyhosting.xyz`, `hub.legacyhosting.xyz`, or
`status.legacyhosting.xyz`. Each public Nginx endpoint must use a certificate
whose names include that endpoint.

If the public record already resolves directly to the new host, omit the
credentials argument to use HTTP-01. The deployed Nginx sites preserve that
challenge path on HTTP and HTTPS. Both methods configure normal unattended
`certbot renew` runs without taking the service down.

## 5. Deploy in dependency order

1. SSO with `OIDC_LOGIN_MODE=legacy_bridge`.
2. API and its three PM2 workers.
3. Panel, followed by the Discord process on the same host.
4. Hub.
5. Status in FRA1.
6. Migrate passkeys in dry-run mode, then apply and verify the counts.
7. Change SSO to `OIDC_LOGIN_MODE=passkey` only after browser verification.

Use only versioned archives with matching SHA-256 files and detached Ed25519
signatures from `LH-Releases`. Deploy scripts verify the service key provisioned
from LH-Ops before extraction. Run the service-owned verification script after
every deployment.

## 6. Cut over and retire Platform

Move one public DNS record at a time. Verify health, authentication, browser
flows, deploy commands, logs, monitoring, certificate renewal, and rollback
before moving the next record. Keep the previous Platform deployment available
until all split services have completed an observation window and a restore
drill. Archive LH-Platform only after that checkpoint.
