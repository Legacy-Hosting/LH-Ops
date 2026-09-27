#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 4 ]]; then
  echo "Usage: $0 PUBLIC_KEY ARCHIVE CHECKSUM SIGNATURE" >&2
  exit 2
fi

for command in openssl readlink sha256sum; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "Required command is missing: $command" >&2
    exit 1
  }
done

for path in "$1" "$2" "$3" "$4"; do
  if [[ ! -f $path || -L $path ]]; then
    echo "Release verification input must be a regular, non-symlink file: $path" >&2
    exit 1
  fi
done

public_key=$(readlink -f "$1")
archive=$(readlink -f "$2")
checksum=$(readlink -f "$3")
signature=$(readlink -f "$4")

if [[ $(wc -c < "$signature") -ne 64 ]]; then
  echo "Release signature must be a 64-byte Ed25519 signature" >&2
  exit 1
fi

read -r expected_hash checksum_name extra < "$checksum"
archive_name=$(basename "$archive")
actual_hash=$(sha256sum "$archive" | cut -d ' ' -f 1)
if [[ -n ${extra:-} || ! $expected_hash =~ ^[a-f0-9]{64}$ || \
      $checksum_name != "$archive_name" || $actual_hash != "$expected_hash" ]]; then
  echo "Release checksum verification failed for $archive_name" >&2
  exit 1
fi

if ! openssl pkeyutl -verify -rawin -pubin -inkey "$public_key" \
  -in "$archive" -sigfile "$signature" >/dev/null 2>&1; then
  echo "Release signature verification failed for $archive_name" >&2
  exit 1
fi

echo "Verified SHA-256 and Ed25519 signature for $archive_name"
