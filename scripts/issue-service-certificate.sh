#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -ne 0 || $# -ne 2 ]]; then
  echo "Usage as root: $0 SERVICE ACME_EMAIL" >&2
  echo "SERVICE: api, panel, sso, hub, or status" >&2
  exit 2
fi

service=$1
email=$2
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

expected_public_ipv4=$(getent ahostsv4 "$domain" | awk '{ print $1 }' | sort -u)
local_public_ipv4=$(curl --fail --silent --show-error --ipv4 \
  --connect-timeout 5 https://api.ipify.org)
if [[ -z $expected_public_ipv4 ]] || \
   ! grep -Fxq "$local_public_ipv4" <<< "$expected_public_ipv4"; then
  echo "$domain does not resolve to this host ($local_public_ipv4)" >&2
  echo "Point the DNS record at this host before requesting a certificate." >&2
  exit 1
fi

webroot=/var/lib/letsencrypt
temporary_site=/etc/nginx/sites-available/lh-acme-bootstrap.conf
temporary_link=/etc/nginx/sites-enabled/lh-acme-bootstrap.conf
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

certbot certonly \
  --non-interactive \
  --agree-tos \
  --no-eff-email \
  --keep-until-expiring \
  --cert-name "$domain" \
  --email "$email" \
  --webroot \
  --webroot-path "$webroot" \
  --deploy-hook "systemctl reload nginx" \
  --domain "$domain"

for certificate_file in fullchain.pem privkey.pem; do
  if [[ ! -r /etc/letsencrypt/live/$domain/$certificate_file ]]; then
    echo "Certificate issuance did not create $certificate_file" >&2
    exit 1
  fi
done

echo "TLS certificate for $domain is installed and renewal is configured."
