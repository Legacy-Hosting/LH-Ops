#!/usr/bin/env bash
set -Eeuo pipefail

repository_root=$(cd "$(dirname "$0")/.." && pwd)
setup=$repository_root/scripts/bootstrap-ubuntu.sh

test -x "$setup"
grep -q 'install-node-runtime.sh' "$setup"
grep -q 'sshd_effective_config=.*-T' "$setup"
grep -q '/etc/fail2ban/jail.d' "$setup"
grep -q 'backend = systemd' "$setup"
grep -q 'fail2ban-client -t' "$setup"
grep -q 'maxretry = 3' "$setup"
grep -q 'findtime = 10m' "$setup"
grep -q 'bantime = 24h' "$setup"
grep -q 'append_unique_port 80' "$setup"
grep -q 'append_unique_port 443' "$setup"
grep -q 'Legacy Hosting global ban' "$setup"
grep -q 'snap install --classic certbot' "$setup"
grep -q 'snap install certbot-dns-cloudflare' "$setup"
grep -q 'snap set certbot trust-plugin-with-root=ok' "$setup"
grep -q '/root/.secrets/certbot/cloudflare.ini' "$setup"
grep -q 'chmod 0600 "$cloudflare_credentials"' "$setup"
if grep -Eq 'apt-get install.*certbot|^[[:space:]]+certbot[[:space:]]*\\' "$setup"; then
  echo "Certbot must be installed through Snap, not APT" >&2
  exit 1
fi

for ip in 95.85.245.227 45.148.10.141 193.47.62.69 37.120.162.199; do
  grep -q "\"$ip\"" "$setup"
done

first_allow=$(grep -n 'ufw allow ' "$setup" | head -n 1 | cut -d: -f1)
enable=$(grep -n 'ufw --force enable' "$setup" | head -n 1 | cut -d: -f1)
if [[ -z $first_allow || -z $enable || $first_allow -ge $enable ]]; then
  echo "SSH/web rules must be installed before UFW is enabled" >&2
  exit 1
fi
if grep -Eq 'ufw[[:space:]]+(--force[[:space:]]+)?reset' "$setup"; then
  echo "The host setup must not erase existing UFW rules" >&2
  exit 1
fi
if grep -q '/etc/fail2ban/jail.local' "$setup"; then
  echo "The host setup must not replace the global Fail2Ban jail.local" >&2
  exit 1
fi

echo "Node host security policy checks passed."
