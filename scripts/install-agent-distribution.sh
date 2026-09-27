#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -ne 0 || $# -ne 3 ]]; then
  echo "Usage as root: $0 ARCHIVE CHECKSUM VERSION" >&2
  exit 2
fi

archive=$(readlink -f "$1")
checksum=$(readlink -f "$2")
version=$3
if [[ ! -f $archive || ! -f $checksum || \
      ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]]; then
  echo "Invalid LH-Agent release archive, checksum, or version" >&2
  exit 1
fi

expected=$(awk 'NR==1 {print $1}' "$checksum")
actual=$(sha256sum "$archive" | awk '{print $1}')
if [[ ! $expected =~ ^[a-f0-9]{64}$ || $expected != "$actual" ]]; then
  echo "LH-Agent release checksum verification failed" >&2
  exit 1
fi

archive_root="lh-agent-$version"
installer_member="$archive_root/ops/scripts/install-node-agent.sh"
if ! tar -tzf "$archive" | grep -Fx "$installer_member" >/dev/null; then
  echo "LH-Agent release does not contain its installer" >&2
  exit 1
fi

base=/var/lib/legacy-hosting/agent-distributions
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
