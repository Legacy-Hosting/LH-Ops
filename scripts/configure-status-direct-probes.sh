#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -ne 0 || $# -ne 3 ]]; then
  echo "Usage as root: $0 API_ORIGIN_IPV4 SSO_ORIGIN_IPV4 PANEL_ORIGIN_IPV4" >&2
  exit 2
fi

valid_ipv4() {
  local address=$1 octet
  [[ $address =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r -a octets <<< "$address"
  for octet in "${octets[@]}"; do
    (( 10#$octet <= 255 )) || return 1
  done
}

api_address=$1
sso_address=$2
panel_address=$3
for address in "$api_address" "$sso_address" "$panel_address"; do
  if ! valid_ipv4 "$address"; then
    echo "Invalid origin IPv4 address: $address" >&2
    exit 2
  fi
done

hosts_file=/etc/hosts
if [[ ! -f $hosts_file || -L $hosts_file ]]; then
  echo "$hosts_file must be a regular file and not a symbolic link" >&2
  exit 1
fi

backup=${hosts_file}.pre-lh-status-direct
if [[ ! -e $backup ]]; then
  cp -p -- "$hosts_file" "$backup"
fi

begin_marker="# BEGIN LH-Status direct origin probes"
end_marker="# END LH-Status direct origin probes"
temporary=$(mktemp "${hosts_file}.lh-status.XXXXXX")
cleanup() {
  rm -f -- "$temporary"
}
trap cleanup EXIT

awk -v begin="$begin_marker" -v end="$end_marker" '
  $0 == begin { managed = 1; next }
  $0 == end { managed = 0; next }
  !managed { print }
' "$hosts_file" > "$temporary"

printf '\n%s\n%s api.legacyhosting.xyz\n%s auth.legacyhosting.xyz\n%s panel.legacyhosting.xyz\n%s\n' \
  "$begin_marker" \
  "$api_address" \
  "$sso_address" \
  "$panel_address" \
  "$end_marker" >> "$temporary"

chown --reference="$hosts_file" "$temporary"
chmod --reference="$hosts_file" "$temporary"
mv -- "$temporary" "$hosts_file"
trap - EXIT

for expected in \
  "$api_address api.legacyhosting.xyz" \
  "$sso_address auth.legacyhosting.xyz" \
  "$panel_address panel.legacyhosting.xyz"; do
  read -r address hostname <<< "$expected"
  resolved=$(getent ahostsv4 "$hostname" | awk 'NR == 1 { print $1 }')
  if [[ $resolved != "$address" ]]; then
    echo "Direct probe lookup failed for $hostname" >&2
    exit 1
  fi
done

if command -v pm2 >/dev/null 2>&1 && pm2 describe lh-status >/dev/null 2>&1; then
  pm2 restart lh-status --update-env >/dev/null
  pm2 save >/dev/null
fi

echo "Status probes now resolve API, SSO, and Web Panel directly to their origins."
