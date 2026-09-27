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

swap_size_gib=${SWAP_SIZE_GIB:-2}
if [[ ! $swap_size_gib =~ ^[1-9][0-9]*$ || $swap_size_gib -gt 16 ]]; then
  echo "SWAP_SIZE_GIB must be an integer between 1 and 16" >&2
  exit 1
fi

required_bytes=$((swap_size_gib * 1024 * 1024 * 1024))
minimum_active_bytes=$((required_bytes - 1024 * 1024))
active_bytes=$(swapon --show=SIZE --noheadings --bytes 2>/dev/null | \
  awk '{ total += $1 } END { print total + 0 }')
if (( active_bytes >= minimum_active_bytes )); then
  echo "At least ${swap_size_gib} GiB of swap is already active."
  exit 0
fi

swap_directory=/var/lib/legacy-hosting
swap_file=$swap_directory/swapfile
install -d -m 0755 "$swap_directory"
if [[ -e $swap_file ]]; then
  echo "$swap_file already exists but the active swap total is below ${swap_size_gib} GiB" >&2
  exit 1
fi

available_bytes=$(df --output=avail -B1 "$swap_directory" | awk 'NR == 2 { print $1 }')
if (( available_bytes < required_bytes + 1073741824 )); then
  echo "At least ${swap_size_gib} GiB plus 1 GiB free disk space is required" >&2
  exit 1
fi

if ! fallocate -l "${swap_size_gib}G" "$swap_file"; then
  dd if=/dev/zero of="$swap_file" bs=1M count=$((swap_size_gib * 1024)) status=progress
fi
chmod 0600 "$swap_file"
mkswap "$swap_file" >/dev/null
swapon "$swap_file"
if ! grep -Fqs "$swap_file none swap sw 0 0" /etc/fstab; then
  printf '%s\n' "$swap_file none swap sw 0 0" >> /etc/fstab
fi

active_bytes=$(swapon --show=SIZE --noheadings --bytes | \
  awk '{ total += $1 } END { print total + 0 }')
if (( active_bytes < minimum_active_bytes )); then
  echo "Swap activation did not reach ${swap_size_gib} GiB" >&2
  exit 1
fi

echo "${swap_size_gib} GiB of persistent swap is active."
