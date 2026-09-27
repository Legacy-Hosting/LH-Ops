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

expected_fingerprint=902C44B42EA9A17F8578510977B79B3FFAF7EF65
repository_url=https://repos.insights.digitalocean.com/apt/do-agent/
key_url=https://repos.insights.digitalocean.com/sonar-agent.asc
keyring=/usr/share/keyrings/digitalocean-agent.gpg
source_file=/etc/apt/sources.list.d/digitalocean-agent.list

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gnupg
temporary_directory=$(mktemp -d)
trap 'rm -rf -- "$temporary_directory"' EXIT
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
  "$key_url" -o "$temporary_directory/sonar-agent.asc"
actual_fingerprint=$(gpg --show-keys --with-colons "$temporary_directory/sonar-agent.asc" | \
  awk -F: '$1 == "fpr" { print $10; exit }')
if [[ $actual_fingerprint != "$expected_fingerprint" ]]; then
  echo "DigitalOcean agent signing key fingerprint did not match" >&2
  exit 1
fi
gpg --batch --yes --dearmor --output "$keyring" "$temporary_directory/sonar-agent.asc"
chmod 0644 "$keyring"
printf 'deb [signed-by=%s] %s main main\n' "$keyring" "$repository_url" > "$source_file"
chmod 0644 "$source_file"

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y do-agent
systemctl enable --now do-agent
systemctl is-active --quiet do-agent

echo "DigitalOcean Metrics Agent is installed, enabled, and active."
