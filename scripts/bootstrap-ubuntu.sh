#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Run as root" >&2
  exit 1
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
repository_root=$(cd "$(dirname "$0")/.." && pwd)
if [[ ! -f $repository_root/logrotate/legacy-hosting ]]; then
  echo "Missing Legacy Hosting logrotate policy" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
  age \
  ca-certificates \
  certbot \
  curl \
  git \
  git-lfs \
  gnupg \
  jq \
  logrotate \
  mysql-client \
  nginx \
  python3-certbot-dns-cloudflare \
  python3-certbot-nginx \
  rclone \
  unattended-upgrades \
  xz-utils

install -d -m 0700 /etc/legacy-hosting /etc/legacy-hosting/backups
install -d -m 0700 /var/backups/legacy-hosting/mysql
install -d -m 0755 /opt/legacy-hosting /var/www
install -m 0644 "$repository_root/logrotate/legacy-hosting" \
  /etc/logrotate.d/legacy-hosting
systemctl enable --now nginx
systemctl enable --now certbot.timer
systemctl enable unattended-upgrades
"$repository_root/scripts/ensure-swap.sh"

echo "Common Ubuntu dependencies, TLS tooling, swap, and protected directories are ready."
echo "Firewall and SSH policy were intentionally not changed by this script."
