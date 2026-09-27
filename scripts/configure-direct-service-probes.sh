#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -ne 0 || $# -ne 6 ]]; then
  echo "Usage as root: $0 PM2_PROCESS API_IPV4 SSO_IPV4 HUB_IPV4 PANEL_IPV4 STATUS_IPV4" >&2
  exit 2
fi

process_name=$1
shift
addresses=("$@")
hosts=(api.legacyhosting.xyz auth.legacyhosting.xyz hub.legacyhosting.xyz panel.legacyhosting.xyz status.legacyhosting.xyz)

if [[ ! $process_name =~ ^lh-[a-z0-9-]+$ ]]; then
  echo "PM2 process name must use the lh-* naming convention" >&2
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

for address in "${addresses[@]}"; do
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

backup=${hosts_file}.pre-lh-direct-origins
if [[ ! -e $backup ]]; then
  cp -p -- "$hosts_file" "$backup"
fi

begin_marker="# BEGIN Legacy Hosting direct origin probes"
end_marker="# END Legacy Hosting direct origin probes"
temporary=$(mktemp "${hosts_file}.lh-direct.XXXXXX")
trap 'rm -f -- "$temporary"' EXIT

awk -v begin="$begin_marker" -v end="$end_marker" '
  $0 == begin { managed = 1; next }
  $0 == end { managed = 0; next }
  !managed { print }
' "$hosts_file" > "$temporary"

printf '\n%s\n' "$begin_marker" >> "$temporary"
for index in "${!hosts[@]}"; do
  printf '%s %s\n' "${addresses[$index]}" "${hosts[$index]}" >> "$temporary"
done
printf '%s\n' "$end_marker" >> "$temporary"

chown --reference="$hosts_file" "$temporary"
chmod --reference="$hosts_file" "$temporary"
mv -- "$temporary" "$hosts_file"
trap - EXIT

for index in "${!hosts[@]}"; do
  resolved=$(getent ahostsv4 "${hosts[$index]}" | awk 'NR == 1 { print $1 }')
  if [[ $resolved != "${addresses[$index]}" ]]; then
    echo "Direct origin lookup failed for ${hosts[$index]}" >&2
    exit 1
  fi
done

if command -v pm2 >/dev/null 2>&1 && pm2 describe "$process_name" >/dev/null 2>&1; then
  pm2 restart "$process_name" --update-env >/dev/null
  pm2 save >/dev/null
fi

echo "$process_name now resolves Legacy Hosting service probes directly to origin servers."
