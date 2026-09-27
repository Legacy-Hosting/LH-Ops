#!/usr/bin/env bash
set -Eeuo pipefail

repository_root=$(cd "$(dirname "$0")/.." && pwd)
workspace=$(mktemp -d)
cleanup() {
  rm -rf -- "$workspace"
}
trap cleanup EXIT

private_key="$workspace/private.pem"
public_key="$workspace/public.pub"
other_private_key="$workspace/other-private.pem"
other_public_key="$workspace/other-public.pub"
archive="$workspace/lh-example-1.0.0.tar.gz"
checksum="$workspace/lh-example-1.0.0.tar.gz.sha256"
signature="$workspace/lh-example-1.0.0.tar.gz.sig"

openssl genpkey -algorithm Ed25519 -out "$private_key" >/dev/null 2>&1
openssl pkey -in "$private_key" -pubout -out "$public_key" >/dev/null 2>&1
openssl genpkey -algorithm Ed25519 -out "$other_private_key" >/dev/null 2>&1
openssl pkey -in "$other_private_key" -pubout -out "$other_public_key" >/dev/null 2>&1
chmod 0600 "$private_key" "$other_private_key"
printf 'immutable release payload\n' > "$archive"
(cd "$workspace" && sha256sum "$(basename "$archive")" > "$(basename "$checksum")")

"$repository_root/scripts/sign-release-artifact.sh" \
  "$private_key" "$archive" "$checksum" "$signature"
"$repository_root/scripts/verify-release-artifact.sh" \
  "$public_key" "$archive" "$checksum" "$signature"

if "$repository_root/scripts/sign-release-artifact.sh" \
  "$private_key" "$archive" "$checksum" "$signature" >/dev/null 2>&1; then
  echo "An existing immutable signature was overwritten" >&2
  exit 1
fi

if "$repository_root/scripts/verify-release-artifact.sh" \
  "$other_public_key" "$archive" "$checksum" "$signature" >/dev/null 2>&1; then
  echo "A release signed by another key was accepted" >&2
  exit 1
fi

archive_link="$workspace/archive-link.tar.gz"
ln -s "$archive" "$archive_link"
if "$repository_root/scripts/verify-release-artifact.sh" \
  "$public_key" "$archive_link" "$checksum" "$signature" >/dev/null 2>&1; then
  echo "A symlinked release input was accepted" >&2
  exit 1
fi

printf 'tampered\n' >> "$archive"
if "$repository_root/scripts/verify-release-artifact.sh" \
  "$public_key" "$archive" "$checksum" "$signature" >/dev/null 2>&1; then
  echo "A tampered release was accepted" >&2
  exit 1
fi

printf 'Release signing integration checks passed.\n'
