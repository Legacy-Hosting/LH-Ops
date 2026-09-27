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
    private_prefix_regex='^10\.110\.([0-9]{1,2})\.[0-9]{1,3}$'
    private_cidr=10.110.0.0/20
    environment_file=/etc/legacy-hosting/api.env
    backup_name=api
    ;;
  panel)
    expected_hostname=ams3-panel-01
    public_domain=panel.legacyhosting.xyz
    private_prefix_regex='^10\.110\.([0-9]{1,2})\.[0-9]{1,3}$'
    private_cidr=10.110.0.0/20
    environment_file=
    backup_name=
    ;;
  sso)
    expected_hostname=ams3-sso-01
    public_domain=auth.legacyhosting.xyz
    private_prefix_regex='^10\.110\.([0-9]{1,2})\.[0-9]{1,3}$'
    private_cidr=10.110.0.0/20
    environment_file=/etc/legacy-hosting/sso.env
    backup_name=sso
    ;;
  hub)
    expected_hostname=ams3-hub-01
    public_domain=hub.legacyhosting.xyz
    private_prefix_regex='^10\.110\.([0-9]{1,2})\.[0-9]{1,3}$'
    private_cidr=10.110.0.0/20
    environment_file=/etc/legacy-hosting/hub.env
    backup_name=
    ;;
  status)
    expected_hostname=fra1-status-01
    public_domain=status.legacyhosting.xyz
    private_prefix_regex='^10\.114\.([0-9]{1,2})\.[0-9]{1,3}$'
    private_cidr=10.114.0.0/20
    environment_file=/etc/legacy-hosting/status.env
    backup_name=
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

for command in certbot curl git jq nginx node pm2 pnpm python3 sha256sum tar; do
  if command -v "$command" >/dev/null 2>&1; then
    pass "$command is installed"
  else
    fail "$command is not installed"
  fi
done
if python3 -c 'import certbot_dns_cloudflare' >/dev/null 2>&1; then
  pass "Certbot Cloudflare DNS plugin is installed"
else
  fail "Certbot Cloudflare DNS plugin is not installed"
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

for unit in nginx do-agent; do
  if systemctl is-enabled --quiet "$unit" && systemctl is-active --quiet "$unit"; then
    pass "$unit is enabled and active"
  else
    fail "$unit must be enabled and active"
  fi
done
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
if systemctl is-enabled --quiet certbot.timer && systemctl is-active --quiet certbot.timer; then
  pass "certbot.timer is enabled and active"
else
  fail "certbot.timer must be enabled and active"
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

swap_bytes=$(swapon --show --noheadings --bytes --output SIZE 2>/dev/null | \
  awk '{ total += $1 } END { print total + 0 }')
if (( swap_bytes >= 2147483648 )); then
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
    if [[ -x /usr/local/lib/legacy-hosting-ops/backup-mysql.sh && \
          -f /etc/legacy-hosting/backups/$backup_name.env ]]; then
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
