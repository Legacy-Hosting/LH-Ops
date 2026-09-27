#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -ne 0 || $# -ne 4 ]]; then
  echo "Usage as root: $0 ARCHIVE CHECKSUM SIGNATURE VERSION" >&2
  exit 2
fi

version=$4
install_root=${LH_INSTALL_ROOT:-}
if [[ ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]]; then
  echo "Invalid LH-Agent release version" >&2
  exit 1
fi
if [[ -n $install_root ]]; then
  if [[ ! -d $install_root || -L $install_root ]]; then
    echo "LH_INSTALL_ROOT must be an existing, non-symlink test root" >&2
    exit 1
  fi
  install_root=$(readlink -f "$install_root")
fi
verifier="$install_root/usr/local/lib/legacy-hosting-ops/verify-release-artifact.sh"
public_key="$install_root/etc/legacy-hosting/release-keys/lh-agent.pub"
if [[ ! -x $verifier || ! -r $public_key ]]; then
  echo "LH-Agent release verifier or pinned public key is not installed" >&2
  exit 1
fi
"$verifier" "$public_key" "$1" "$2" "$3"
archive=$(readlink -f "$1")
actual=$(sha256sum "$archive" | cut -d ' ' -f 1)

archive_root="lh-agent-$version"
installer_member="$archive_root/ops/scripts/install-node-agent.sh"
if ! tar -tzf "$archive" | grep -Fx "$installer_member" >/dev/null; then
  echo "LH-Agent release does not contain its installer" >&2
  exit 1
fi

base="$install_root/var/lib/legacy-hosting/agent-distributions"
release="$base/releases/$version"
if [[ -e $release ]]; then
  echo "Agent distribution already exists: $release" >&2
  exit 1
fi
if [[ -e $base/current && ! -L $base/current ]]; then
  echo "$base/current must be a release symlink" >&2
  exit 1
fi

install -d -m 0755 "$base/releases"
staging=$(mktemp -d "$base/releases/.staging-${version}.XXXXXX")
temporary_link="$base/.current-${version}.$$"
cleanup() {
  rm -rf -- "$staging"
  rm -f -- "$temporary_link"
}
trap cleanup EXIT

install -m 0644 "$archive" "$staging/lh-agent-runtime.tar.gz"
printf '%s  lh-agent-runtime.tar.gz\n' "$actual" > \
  "$staging/lh-agent-runtime.tar.gz.sha256"
tar -xOf "$archive" "$installer_member" > "$staging/install-node-agent.sh"
if [[ ! -s $staging/install-node-agent.sh ]]; then
  echo "Extracted LH-Agent installer is empty" >&2
  exit 1
fi
chmod 0755 "$staging/install-node-agent.sh"
chmod 0644 "$staging/lh-agent-runtime.tar.gz.sha256"
printf '%s\n' "$version" > "$staging/VERSION"
chown -R root:root "$staging"
mv "$staging" "$release"

ln -s "$release" "$temporary_link"
mv -Tf "$temporary_link" "$base/current"
trap - EXIT

echo "LH-Agent $version is now served by LH-API from $base/current."
