#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  echo "Usage: $0 SERVICE AGE_RECIPIENT OUTPUT_DIRECTORY" >&2
  exit 1
}

if [[ $# -ne 3 ]]; then
  usage
fi

service=${1,,}
recipient=$2
output_directory=$3

case "$service" in
  api|panel|agent|discord|sso|hub|status) ;;
  *) usage ;;
esac

if [[ ! $recipient =~ ^age1[ac-hj-np-z02-9]{20,}$ ]]; then
  echo "AGE_RECIPIENT must be a native age public recipient" >&2
  exit 1
fi

for command in age id install mktemp openssl realpath sha256sum stat; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Required command is missing: $command" >&2
    exit 1
  fi
done

if [[ ! -d $output_directory || -L $output_directory ]]; then
  echo "OUTPUT_DIRECTORY must be an existing non-symlink directory" >&2
  exit 1
fi
output_directory=$(realpath "$output_directory")
directory_mode=$(stat -c '%a' "$output_directory")
directory_owner=$(stat -c '%u' "$output_directory")
if (( (8#$directory_mode & 077) != 0 )) || [[ $directory_owner != "$(id -u)" ]]; then
  echo "OUTPUT_DIRECTORY must be owned by the current user and inaccessible to group and other users" >&2
  exit 1
fi

private_archive="$output_directory/lh-$service-release-private.pem.age"
public_key="$output_directory/lh-$service.pub"
fingerprint_file="$public_key.sha256"
for target in "$private_archive" "$public_key" "$fingerprint_file"; do
  if [[ -e $target || -L $target ]]; then
    echo "Refusing to overwrite existing key material: $target" >&2
    exit 1
  fi
done

umask 077
workspace=$(mktemp -d "$output_directory/.lh-$service-keygen.XXXXXX")
temporary_encrypted=
completed=false
cleanup() {
  rm -rf -- "$workspace"
  if [[ -n $temporary_encrypted ]]; then
    rm -f -- "$temporary_encrypted"
  fi
  if [[ $completed != true ]]; then
    rm -f -- "$private_archive" "$public_key" "$fingerprint_file"
  fi
}
trap cleanup EXIT

private_key="$workspace/private.pem"
temporary_public="$workspace/public.pub"
temporary_fingerprint="$workspace/public.pub.sha256"
challenge="$workspace/challenge"
signature="$workspace/challenge.sig"

openssl genpkey -algorithm Ed25519 -out "$private_key" >/dev/null 2>&1
chmod 0600 "$private_key"
openssl pkey -in "$private_key" -pubout -out "$temporary_public" >/dev/null 2>&1

printf 'Legacy Hosting release-key self-test\n' > "$challenge"
openssl pkeyutl -sign -rawin -inkey "$private_key" -in "$challenge" -out "$signature"
openssl pkeyutl -verify -rawin -pubin -inkey "$temporary_public" -in "$challenge" -sigfile "$signature" >/dev/null
if [[ $(wc -c < "$signature") -ne 64 ]]; then
  echo "Generated key did not produce a valid Ed25519 signature" >&2
  exit 1
fi

fingerprint=$(openssl pkey -pubin -in "$temporary_public" -outform DER 2>/dev/null | sha256sum)
fingerprint=${fingerprint%% *}
printf '%s  %s\n' "$fingerprint" "$(basename "$public_key")" > "$temporary_fingerprint"

temporary_encrypted=$(mktemp "$output_directory/.lh-$service-release.XXXXXX.age")
age --recipient "$recipient" --output "$temporary_encrypted" "$private_key"
if [[ ! -s $temporary_encrypted ]]; then
  echo "Encrypted private-key recovery file is empty" >&2
  exit 1
fi

install -m 0644 "$temporary_public" "$public_key"
install -m 0644 "$temporary_fingerprint" "$fingerprint_file"
chmod 0600 "$temporary_encrypted"
mv -- "$temporary_encrypted" "$private_archive"
temporary_encrypted=
completed=true

printf 'Created encrypted recovery key: %s\n' "$private_archive"
printf 'Created public key: %s\n' "$public_key"
printf 'Created reviewed fingerprint: %s\n' "$fingerprint"
