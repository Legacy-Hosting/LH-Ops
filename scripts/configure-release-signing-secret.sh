#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  echo "Usage: $0 SERVICE ENCRYPTED_PRIVATE_KEY AGE_IDENTITY PUBLIC_KEY FINGERPRINT_FILE [--apply]" >&2
  exit 1
}

if [[ $# -lt 5 || $# -gt 6 ]]; then
  usage
fi

service=${1,,}
encrypted_private_key=$2
age_identity=$3
public_key=$4
fingerprint_file=$5
apply=false
if [[ $# -eq 6 ]]; then
  [[ $6 == --apply ]] || usage
  apply=true
fi

case "$service" in
  api) repository=Legacy-Hosting/LH-API ;;
  panel) repository=Legacy-Hosting/LH-Panel ;;
  agent) repository=Legacy-Hosting/LH-Agent ;;
  discord) repository=Legacy-Hosting/LH-Discord ;;
  sso) repository=Legacy-Hosting/LH-SSO ;;
  hub) repository=Legacy-Hosting/LH-Hub ;;
  status) repository=Legacy-Hosting/LH-Status ;;
  *) usage ;;
esac

for command in age cmp id mktemp openssl sha256sum stat; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Required command is missing: $command" >&2
    exit 1
  fi
done

for file in "$encrypted_private_key" "$age_identity" "$public_key" "$fingerprint_file"; do
  if [[ ! -f $file || -L $file || ! -r $file ]]; then
    echo "Key inputs must be readable regular files without symlinks: $file" >&2
    exit 1
  fi
done

for protected_file in "$encrypted_private_key" "$age_identity"; do
  protected_mode=$(stat -c '%a' "$protected_file")
  protected_owner=$(stat -c '%u' "$protected_file")
  if (( (8#$protected_mode & 077) != 0 )) || [[ $protected_owner != "$(id -u)" ]]; then
    echo "Protected key input must be owned by the current user and inaccessible to group and other users: $protected_file" >&2
    exit 1
  fi
done

expected_public_name="lh-$service.pub"
if [[ $(basename "$public_key") != "$expected_public_name" ]]; then
  echo "Public key filename must be $expected_public_name" >&2
  exit 1
fi

fingerprint_extra=
read -r expected_fingerprint fingerprint_name fingerprint_extra < "$fingerprint_file"
expected_fingerprint=${expected_fingerprint,,}
if [[ ! $expected_fingerprint =~ ^[a-f0-9]{64}$ || $fingerprint_name != "$expected_public_name" || -n $fingerprint_extra ]]; then
  echo "Fingerprint file must contain one SHA-256 fingerprint for $expected_public_name" >&2
  exit 1
fi

umask 077
workspace=$(mktemp -d)
trap 'rm -rf -- "$workspace"' EXIT
normalized_public="$workspace/expected.pub"
derived_public="$workspace/derived.pub"

if ! openssl pkey -pubin -in "$public_key" -pubout -out "$normalized_public" >/dev/null 2>&1; then
  echo "Public key is not a valid OpenSSL public key" >&2
  exit 1
fi
actual_fingerprint=$(openssl pkey -pubin -in "$normalized_public" -outform DER 2>/dev/null | sha256sum)
actual_fingerprint=${actual_fingerprint%% *}
if [[ $actual_fingerprint != "$expected_fingerprint" ]]; then
  echo "Public key does not match the reviewed fingerprint" >&2
  exit 1
fi

if ! age --decrypt --identity "$age_identity" "$encrypted_private_key" 2>/dev/null | openssl pkey -pubout -out "$derived_public" >/dev/null 2>&1; then
  echo "Encrypted private key could not be decrypted and parsed" >&2
  exit 1
fi
if ! cmp -s "$normalized_public" "$derived_public"; then
  echo "Encrypted private key does not match the reviewed public key" >&2
  exit 1
fi

confirmation="$repository:$expected_fingerprint"
if [[ $apply != true ]]; then
  echo "Validated release signing key for $repository: $expected_fingerprint"
  echo "No GitHub secret was changed. Re-run with --apply and LH_RELEASE_SECRET_CONFIRM=$confirmation"
  exit 0
fi

if [[ ${LH_RELEASE_SECRET_CONFIRM:-} != "$confirmation" ]]; then
  echo "Refusing to change GitHub without LH_RELEASE_SECRET_CONFIRM=$confirmation" >&2
  exit 1
fi
for command in base64 gh grep; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Required command is missing: $command" >&2
    exit 1
  fi
done

gh auth status --hostname github.com >/dev/null
resolved_repository=$(gh repo view "$repository" --json nameWithOwner --jq .nameWithOwner)
if [[ ${resolved_repository,,} != ${repository,,} ]]; then
  echo "GitHub resolved an unexpected repository: $resolved_repository" >&2
  exit 1
fi

age --decrypt --identity "$age_identity" "$encrypted_private_key" 2>/dev/null | base64 -w0 | gh secret set RELEASE_SIGNING_PRIVATE_KEY_B64 --repo "$repository"
if ! gh secret list --repo "$repository" --json name --jq '.[].name' | grep -Fxq RELEASE_SIGNING_PRIVATE_KEY_B64; then
  echo "GitHub did not report the release signing secret after configuration" >&2
  exit 1
fi

echo "Configured RELEASE_SIGNING_PRIVATE_KEY_B64 for $repository"
