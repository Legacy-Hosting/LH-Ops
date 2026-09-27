#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -ne 0 || $# -ne 3 ]]; then
  echo "Usage as root: $0 SERVICE PUBLIC_KEY EXPECTED_SHA256_FINGERPRINT" >&2
  exit 2
fi

service=$1
public_key_source=$2
expected_fingerprint=${3,,}
install_root=${LH_INSTALL_ROOT:-}
case $service in
  api|panel|agent|discord|sso|hub|status) ;;
  *)
    echo "Unknown release signing service: $service" >&2
    exit 1
    ;;
esac
if [[ ! -f $public_key_source || -L $public_key_source || \
      ! $expected_fingerprint =~ ^[a-f0-9]{64}$ ]]; then
  echo "Public key must be a regular file with an expected SHA-256 fingerprint" >&2
  exit 1
fi
if [[ -n $install_root ]]; then
  if [[ ! -d $install_root || -L $install_root ]]; then
    echo "LH_INSTALL_ROOT must be an existing, non-symlink test root" >&2
    exit 1
  fi
  install_root=$(readlink -f "$install_root")
fi

repository_root=$(cd "$(dirname "$0")/.." && pwd)
verifier_source="$repository_root/scripts/verify-release-artifact.sh"
if [[ ! -f $verifier_source || -L $verifier_source ]]; then
  echo "Trusted release verifier is missing from LH-Ops" >&2
  exit 1
fi

normalized_key=$(mktemp)
cleanup() {
  rm -f -- "$normalized_key"
}
trap cleanup EXIT
if ! openssl pkey -pubin -in "$public_key_source" -pubout \
  -out "$normalized_key" >/dev/null 2>&1; then
  echo "Release public key is not a valid OpenSSL public key" >&2
  exit 1
fi
actual_fingerprint=$(openssl pkey -pubin -in "$normalized_key" -outform DER 2>/dev/null | \
  sha256sum | cut -d ' ' -f 1)
if [[ $actual_fingerprint != "$expected_fingerprint" ]]; then
  echo "Release public key fingerprint does not match the reviewed value" >&2
  exit 1
fi

key_directory="$install_root/etc/legacy-hosting/release-keys"
key_target="$key_directory/lh-$service.pub"
fingerprint_target="$key_target.sha256"
if [[ -L $key_directory || -L $key_target || -L $fingerprint_target ]]; then
  echo "Release trust paths must not be symlinks" >&2
  exit 1
fi
if [[ -f $key_target ]]; then
  installed_fingerprint=$(openssl pkey -pubin -in "$key_target" -outform DER 2>/dev/null | \
    sha256sum | cut -d ' ' -f 1)
  if [[ $installed_fingerprint != "$actual_fingerprint" && \
        ${LH_RELEASE_KEY_ROTATION_CONFIRM:-} != "$service:$actual_fingerprint" ]]; then
    echo "Refusing release-key rotation without LH_RELEASE_KEY_ROTATION_CONFIRM=$service:$actual_fingerprint" >&2
    exit 1
  fi
fi

verifier_target="$install_root/usr/local/lib/legacy-hosting-ops/verify-release-artifact.sh"
install -d -m 0755 "$(dirname "$verifier_target")" "$key_directory"
install -m 0755 "$verifier_source" \
  "$verifier_target"
install -m 0644 "$normalized_key" "$key_target"
printf '%s  %s\n' "$actual_fingerprint" "$(basename "$key_target")" > \
  "$fingerprint_target"
chmod 0644 "$fingerprint_target"
chown root:root \
  "$verifier_target" \
  "$key_target" "$fingerprint_target"

echo "Installed pinned $service release key: $actual_fingerprint"
