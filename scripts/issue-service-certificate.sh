#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -ne 0 || $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage as root: $0 SERVICE ACME_EMAIL [CLOUDFLARE_CREDENTIALS_FILE]" >&2
  echo "SERVICE: api, panel, sso, hub, or status" >&2
  exit 2
fi

service=$1
email=$2
default_cloudflare_credentials=/root/.secrets/certbot/cloudflare.ini
if [[ $# -eq 3 ]]; then
  cloudflare_credentials=$3
elif [[ -f $default_cloudflare_credentials ]]; then
  cloudflare_credentials=$default_cloudflare_credentials
else
  cloudflare_credentials=
fi
case $service in
  api) domain=api.legacyhosting.xyz ;;
  panel) domain=panel.legacyhosting.xyz ;;
  sso) domain=auth.legacyhosting.xyz ;;
  hub) domain=hub.legacyhosting.xyz ;;
  status) domain=status.legacyhosting.xyz ;;
  *)
    echo "Unknown service: $service" >&2
    exit 2
    ;;
esac
if [[ $email != *@*.* ]]; then
  echo "A valid ACME contact email is required" >&2
  exit 2
fi
if [[ ! -r /etc/os-release ]]; then
  echo "Cannot identify the operating system" >&2
  exit 1
fi
. /etc/os-release
if [[ ${ID:-} != ubuntu || ${VERSION_ID:-} != 26.04 ]]; then
  echo "Ubuntu 26.04 LTS is required" >&2
  exit 1
fi
for command in certbot curl nginx; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "$command is required" >&2
    exit 1
  fi
done

webroot=/var/lib/letsencrypt
temporary_site=/etc/nginx/sites-available/lh-acme-bootstrap.conf
temporary_link=/etc/nginx/sites-enabled/lh-acme-bootstrap.conf
certbot_arguments=(
  certonly
  --non-interactive
  --agree-tos
  --no-eff-email
  --keep-until-expiring
  --cert-name "$domain"
  --email "$email"
  --deploy-hook "systemctl reload nginx"
  --domain "$domain"
)

if [[ -n $cloudflare_credentials ]]; then
  cloudflare_credentials=$(readlink -f "$cloudflare_credentials")
  if [[ ! -f $cloudflare_credentials ]]; then
    echo "Cloudflare credentials file was not found" >&2
    exit 1
  fi
  credentials_mode=$(stat -c '%a' "$cloudflare_credentials")
  if (( (8#$credentials_mode & 077) != 0 )); then
    echo "$cloudflare_credentials must have mode 0600 or stricter" >&2
    exit 1
  fi
  if ! grep -Eq '^dns_cloudflare_api_token[[:space:]]*=' "$cloudflare_credentials"; then
    echo "$cloudflare_credentials must contain dns_cloudflare_api_token" >&2
    exit 1
  fi
  certbot_arguments+=(
    --dns-cloudflare
    --dns-cloudflare-credentials "$cloudflare_credentials"
    --dns-cloudflare-propagation-seconds 30
  )
else
  expected_public_ipv4=$(getent ahostsv4 "$domain" | awk '{ print $1 }' | sort -u)
  local_public_ipv4=$(curl --fail --silent --show-error --ipv4 \
    --connect-timeout 5 https://api.ipify.org)
  if [[ -z $expected_public_ipv4 ]] || \
     ! grep -Fxq "$local_public_ipv4" <<< "$expected_public_ipv4"; then
    echo "$domain does not resolve to this host ($local_public_ipv4)" >&2
    echo "Use Cloudflare DNS credentials or point DNS at this host first." >&2
    exit 1
  fi
  if [[ -e $temporary_site || -L $temporary_link ]]; then
    echo "Temporary ACME Nginx configuration already exists" >&2
    exit 1
  fi
  install -d -m 0755 "$webroot/.well-known/acme-challenge"
  cat > "$temporary_site" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $domain;

    location ^~ /.well-known/acme-challenge/ {
        default_type text/plain;
        root $webroot;
    }

    location / {
        return 404;
    }
}
EOF
  chmod 0644 "$temporary_site"
  ln -s "$temporary_site" "$temporary_link"

  cleanup() {
    rm -f -- "$temporary_link" "$temporary_site"
    nginx -t >/dev/null 2>&1 && systemctl reload nginx || true
  }
  trap cleanup EXIT
  nginx -t
  systemctl reload nginx
  certbot_arguments+=(--webroot --webroot-path "$webroot")
fi

certbot "${certbot_arguments[@]}"

for certificate_file in fullchain.pem privkey.pem; do
  if [[ ! -r /etc/letsencrypt/live/$domain/$certificate_file ]]; then
    echo "Certificate issuance did not create $certificate_file" >&2
    exit 1
  fi
done

echo "TLS certificate for $domain is installed and renewal is configured."
