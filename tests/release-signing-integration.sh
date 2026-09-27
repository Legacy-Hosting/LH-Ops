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

install_root="$workspace/install-root"
mkdir -p "$install_root"
fingerprint=$(openssl pkey -pubin -in "$public_key" -outform DER 2>/dev/null | \
  sha256sum | cut -d ' ' -f 1)
LH_INSTALL_ROOT="$install_root" \
  "$repository_root/scripts/install-release-verifier.sh" \
  api "$public_key" "$fingerprint"
installed_verifier="$install_root/usr/local/lib/legacy-hosting-ops/verify-release-artifact.sh"
installed_key="$install_root/etc/legacy-hosting/release-keys/lh-api.pub"
[[ -x $installed_verifier && -f $installed_key ]]
"$installed_verifier" "$installed_key" "$archive" "$checksum" "$signature"

other_fingerprint=$(openssl pkey -pubin -in "$other_public_key" -outform DER 2>/dev/null | \
  sha256sum | cut -d ' ' -f 1)
if LH_INSTALL_ROOT="$install_root" \
  "$repository_root/scripts/install-release-verifier.sh" \
  api "$other_public_key" "$other_fingerprint" >/dev/null 2>&1; then
  echo "An installed release trust key was rotated without confirmation" >&2
  exit 1
fi

LH_INSTALL_ROOT="$install_root" \
  "$repository_root/scripts/install-release-verifier.sh" \
  agent "$public_key" "$fingerprint"
agent_source="$workspace/agent-source"
agent_version=9.8.7
agent_archive="$workspace/lh-agent-$agent_version.tar.gz"
agent_checksum="$workspace/lh-agent-$agent_version.tar.gz.sha256"
agent_signature="$workspace/lh-agent-$agent_version.tar.gz.sig"
mkdir -p "$agent_source/lh-agent-$agent_version/ops/scripts"
printf '#!/usr/bin/env bash\necho installed\n' > \
  "$agent_source/lh-agent-$agent_version/ops/scripts/install-node-agent.sh"
tar -C "$agent_source" -czf "$agent_archive" "lh-agent-$agent_version"
(cd "$workspace" && sha256sum "$(basename "$agent_archive")" > \
  "$(basename "$agent_checksum")")
"$repository_root/scripts/sign-release-artifact.sh" \
  "$private_key" "$agent_archive" "$agent_checksum" "$agent_signature"
LH_INSTALL_ROOT="$install_root" \
  "$repository_root/scripts/install-agent-distribution.sh" \
  "$agent_archive" "$agent_checksum" "$agent_signature" "$agent_version"
agent_current="$install_root/var/lib/legacy-hosting/agent-distributions/current"
[[ -L $agent_current ]]
[[ -f $agent_current/lh-agent-runtime.tar.gz ]]
[[ -x $agent_current/install-node-agent.sh ]]

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
