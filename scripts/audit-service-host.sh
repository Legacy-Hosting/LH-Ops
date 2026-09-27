#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  echo "Usage: $0 SERVICE [--deploy-ready]" >&2
  echo "SERVICE: api, panel, sso, hub, or status" >&2
  exit 2
}

service=${1:-}
mode=${2:-}
if [[ -z $service || ( -n $mode && $mode != --deploy-ready ) || $# -gt 2 ]]; then
  usage
fi

case $service in
  api)
    expected_hostname=ams3-api-01
    public_domain=api.legacyhosting.xyz
    private_prefix_regex='^10\.18\.([0-9]{1,2})\.[0-9]{1,3}$'
    private_cidr=10.18.0.0/20
    environment_file=/etc/legacy-hosting/api.env
    backup_name=api
    release_keys=(lh-api.pub lh-agent.pub)
    ;;
  panel)
    expected_hostname=ams3-panel-01
    public_domain=panel.legacyhosting.xyz
    private_prefix_regex='^10\.18\.([0-9]{1,2})\.[0-9]{1,3}$'
    private_cidr=10.18.0.0/20
    environment_file=
    backup_name=
    release_keys=(lh-panel.pub lh-discord.pub)
    ;;
  sso)
    expected_hostname=ams3-sso-01
    public_domain=auth.legacyhosting.xyz
    private_prefix_regex='^10\.18\.([0-9]{1,2})\.[0-9]{1,3}$'
    private_cidr=10.18.0.0/20
    environment_file=/etc/legacy-hosting/sso.env
    backup_name=sso
    release_keys=(lh-sso.pub)
    ;;
  hub)
    expected_hostname=ams3-hub-01
    public_domain=hub.legacyhosting.xyz
    private_prefix_regex='^10\.18\.([0-9]{1,2})\.[0-9]{1,3}$'
    private_cidr=10.18.0.0/20
    environment_file=/etc/legacy-hosting/hub.env
    backup_name=
    release_keys=(lh-hub.pub)
    ;;
  status)
    expected_hostname=fra1-status-01
    public_domain=status.legacyhosting.xyz
    private_prefix_regex='^10\.19\.([0-9]{1,2})\.[0-9]{1,3}$'
    private_cidr=10.19.0.0/20
    environment_file=/etc/legacy-hosting/status.env
    backup_name=
    release_keys=(lh-status.pub)
    ;;
  *) usage ;;
esac

failures=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1" >&2; failures=$((failures + 1)); }

if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  if [[ ${ID:-} == ubuntu && ${VERSION_ID:-} == 26.04 ]]; then
    pass "Ubuntu 26.04 LTS"
  else
    fail "expected Ubuntu 26.04 LTS, found ${PRETTY_NAME:-unknown}"
  fi
else
  fail "cannot read /etc/os-release"
fi

actual_hostname=$(hostname --short 2>/dev/null || true)
if [[ ${actual_hostname,,} == "$expected_hostname" ]]; then
  pass "hostname $actual_hostname"
else
  fail "expected hostname $expected_hostname, found ${actual_hostname:-unknown}"
fi

private_addresses=$(hostname -I 2>/dev/null || true)
private_address_found=false
for address in $private_addresses; do
  if [[ $address =~ $private_prefix_regex ]] && (( 10#${BASH_REMATCH[1]} <= 15 )); then
    private_address_found=true
    break
  fi
done
if [[ $private_address_found == true ]]; then
  pass "private address in $private_cidr"
else
  fail "no private address belongs to $private_cidr"
fi

for command in certbot curl fail2ban-client git jq nginx node openssl pm2 pnpm python3 sha256sum tar ufw; do
  if command -v "$command" >/dev/null 2>&1; then
    pass "$command is installed"
  else
    fail "$command is not installed"
  fi
done
if snap list certbot >/dev/null 2>&1 && \
   snap list certbot-dns-cloudflare >/dev/null 2>&1 && \
   certbot plugins 2>/dev/null | grep -q 'dns-cloudflare'; then
  pass "Certbot and its Cloudflare DNS plugin are installed through Snap"
else
  fail "Certbot and its Cloudflare DNS plugin must be installed through Snap"
fi

if [[ $(node --version 2>/dev/null || true) == v24.21.0 ]]; then
  pass "Node.js 24.21.0"
else
  fail "Node.js 24.21.0 is required"
fi
if [[ $(pnpm --version 2>/dev/null || true) == 12.4.1 ]]; then
  pass "pnpm 12.4.1"
else
  fail "pnpm 12.4.1 is required"
fi
if [[ $(pm2 --version 2>/dev/null | tail -n 1 || true) == 7.0.4 ]]; then
  pass "PM2 7.0.4"
else
  fail "PM2 7.0.4 is required"
fi

for unit in nginx do-agent fail2ban; do
  if systemctl is-enabled --quiet "$unit" && systemctl is-active --quiet "$unit"; then
    pass "$unit is enabled and active"
  else
    fail "$unit must be enabled and active"
  fi
done
if ufw status | head -n 1 | grep -q '^Status: active$'; then
  pass "UFW is active"
else
  fail "UFW must be active"
fi
if fail2ban-client status sshd >/dev/null 2>&1; then
  pass "Fail2Ban sshd jail is active"
else
  fail "Fail2Ban sshd jail must be active"
fi
if systemctl is-enabled --quiet unattended-upgrades; then
  pass "unattended-upgrades is enabled"
else
  fail "unattended-upgrades must be enabled"
fi
if systemctl is-enabled --quiet pm2-root; then
  pass "pm2-root is enabled"
else
  fail "pm2-root must be enabled"
fi
if systemctl is-active --quiet snap.certbot.renew.timer; then
  pass "snap.certbot.renew.timer is active"
else
  fail "snap.certbot.renew.timer must be active"
fi

memory_kib=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)
if (( memory_kib >= 900000 )); then
  pass "at least 1 GiB-class memory is available"
else
  fail "less than 1 GiB-class memory is available"
fi
root_bytes=$(df --output=size -B1 / | awk 'NR == 2 { print $1 }')
if (( root_bytes >= 20000000000 )); then
  pass "root disk is at least 20 GB"
else
  fail "root disk is smaller than 20 GB"
fi

swap_bytes=$(swapon --show=SIZE --noheadings --bytes 2>/dev/null | \
  awk '{ total += $1 } END { print total + 0 }')
minimum_swap_bytes=$((2 * 1024 * 1024 * 1024 - 1024 * 1024))
if (( swap_bytes >= minimum_swap_bytes )); then
  pass "at least 2 GiB swap is active"
else
  fail "less than 2 GiB swap is active"
fi

for directory_mode in /etc/legacy-hosting:700 /opt/legacy-hosting:755; do
  path=${directory_mode%:*}
  expected_mode=${directory_mode#*:}
  actual_mode=$(stat -c '%a' "$path" 2>/dev/null || true)
  if [[ $actual_mode == "$expected_mode" ]]; then
    pass "$path has mode $expected_mode"
  else
    fail "$path must have mode $expected_mode"
  fi
done

if [[ $mode == --deploy-ready ]]; then
  cloudflare_credentials=/root/.secrets/certbot/cloudflare.ini
  credentials_mode=$(stat -c '%a' "$cloudflare_credentials" 2>/dev/null || true)
  credentials_owner=$(stat -c '%u:%g' "$cloudflare_credentials" 2>/dev/null || true)
  if [[ -f $cloudflare_credentials && ! -L $cloudflare_credentials && \
        $credentials_mode == 600 && $credentials_owner == 0:0 ]]; then
    pass "$cloudflare_credentials is protected"
  else
    fail "$cloudflare_credentials must be a root-owned, mode-600 regular file"
  fi
  verifier=/usr/local/lib/legacy-hosting-ops/verify-release-artifact.sh
  if [[ -x $verifier && ! -L $verifier ]]; then
    pass "trusted release verifier is installed"
  else
    fail "trusted release verifier is missing"
  fi
  for release_key in "${release_keys[@]}"; do
    key_path=/etc/legacy-hosting/release-keys/$release_key
    fingerprint_path=$key_path.sha256
    key_mode=$(stat -c '%a' "$key_path" 2>/dev/null || true)
    key_owner=$(stat -c '%u' "$key_path" 2>/dev/null || true)
    fingerprint_mode=$(stat -c '%a' "$fingerprint_path" 2>/dev/null || true)
    fingerprint_owner=$(stat -c '%u' "$fingerprint_path" 2>/dev/null || true)
    expected_fingerprint=
    fingerprint_name=
    fingerprint_extra=
    if [[ -f $fingerprint_path && ! -L $fingerprint_path ]]; then
      read -r expected_fingerprint fingerprint_name fingerprint_extra < \
        "$fingerprint_path" || true
    fi
    actual_fingerprint=$(openssl pkey -pubin -in "$key_path" -outform DER \
      2>/dev/null | sha256sum | cut -d ' ' -f 1 || true)
    if [[ -f $key_path && ! -L $key_path && $key_mode == 644 && \
          $key_owner == 0 && $fingerprint_mode == 644 && \
          $fingerprint_owner == 0 && $expected_fingerprint =~ ^[a-f0-9]{64}$ && \
          $expected_fingerprint == "$actual_fingerprint" && \
          $fingerprint_name == "$release_key" && -z $fingerprint_extra ]]; then
      pass "$release_key is pinned and readable"
    else
      fail "$release_key must be a root-owned mode-644 public key"
    fi
  done
  for certificate_file in fullchain.pem privkey.pem; do
    if [[ -r /etc/letsencrypt/live/$public_domain/$certificate_file ]]; then
      pass "$public_domain $certificate_file is readable"
    else
      fail "missing TLS file /etc/letsencrypt/live/$public_domain/$certificate_file"
    fi
  done
  if [[ -n $environment_file ]]; then
    environment_mode=$(stat -c '%a' "$environment_file" 2>/dev/null || true)
    if [[ $environment_mode == 600 ]]; then
      pass "$environment_file exists with mode 600"
    else
      fail "$environment_file must exist with mode 600"
    fi
  fi
  if [[ -n $backup_name ]]; then
    backup_environment=/etc/legacy-hosting/backups/$backup_name.env
    backup_mode=$(stat -c '%a' "$backup_environment" 2>/dev/null || true)
    backup_owner=$(stat -c '%u' "$backup_environment" 2>/dev/null || true)
    if [[ -x /usr/local/lib/legacy-hosting-ops/backup-mysql.sh && \
          -f $backup_environment && $backup_mode == 600 && $backup_owner == 0 ]] && \
       command -v age >/dev/null 2>&1 && command -v rclone >/dev/null 2>&1 && \
       systemctl is-enabled --quiet "lh-mysql-backup@$backup_name.timer"; then
      pass "$backup_name backup prerequisite is installed"
    else
      fail "$backup_name backup prerequisite is missing"
    fi
  fi
fi

if (( failures > 0 )); then
  printf '\n%s host audit failed with %d issue(s).\n' "$service" "$failures" >&2
  exit 1
fi
printf '\n%s host audit passed.\n' "$service"
