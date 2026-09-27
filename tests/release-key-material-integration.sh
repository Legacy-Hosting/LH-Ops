#!/usr/bin/env bash
set -Eeuo pipefail

repository_root=$(cd "$(dirname "$0")/.." && pwd)
workspace=$(mktemp -d)
trap 'rm -rf -- "$workspace"' EXIT

identity="$workspace/recovery-identity.txt"
key_directory="$workspace/keys"
mkdir -m 0700 "$key_directory"
age-keygen -o "$identity" >/dev/null 2>&1
chmod 0600 "$identity"
recipient=$(age-keygen -y "$identity")

"$repository_root/scripts/generate-release-key-material.sh" api "$recipient" "$key_directory"

encrypted="$key_directory/lh-api-release-private.pem.age"
public_key="$key_directory/lh-api.pub"
fingerprint_file="$public_key.sha256"
[[ -s $encrypted && -s $public_key && -s $fingerprint_file ]]
[[ $(stat -c '%a' "$encrypted") == 600 ]]
[[ $(stat -c '%a' "$public_key") == 644 ]]
[[ $(stat -c '%a' "$fingerprint_file") == 644 ]]
[[ ! -e $key_directory/lh-api-release-private.pem ]]

decrypted="$workspace/private.pem"
age --decrypt --identity "$identity" --output "$decrypted" "$encrypted"
chmod 0600 "$decrypted"
derived_public="$workspace/derived.pub"
openssl pkey -in "$decrypted" -pubout -out "$derived_public" >/dev/null 2>&1
cmp "$public_key" "$derived_public"

read -r expected_fingerprint expected_name fingerprint_extra < "$fingerprint_file"
actual_fingerprint=$(openssl pkey -pubin -in "$public_key" -outform DER 2>/dev/null | sha256sum)
actual_fingerprint=${actual_fingerprint%% *}
[[ $expected_fingerprint == "$actual_fingerprint" ]]
[[ $expected_name == lh-api.pub && -z ${fingerprint_extra:-} ]]

archive="$workspace/archive.tar.gz"
checksum="$workspace/archive.tar.gz.sha256"
signature="$workspace/archive.tar.gz.sig"
printf 'signed release test\n' > "$archive"
(cd "$workspace" && sha256sum archive.tar.gz > archive.tar.gz.sha256)
"$repository_root/scripts/sign-release-artifact.sh" "$decrypted" "$archive" "$checksum" "$signature"
"$repository_root/scripts/verify-release-artifact.sh" "$public_key" "$archive" "$checksum" "$signature"

"$repository_root/scripts/configure-release-signing-secret.sh" api "$encrypted" "$identity" "$public_key" "$fingerprint_file"

if LH_RELEASE_SECRET_CONFIRM=incorrect "$repository_root/scripts/configure-release-signing-secret.sh" api "$encrypted" "$identity" "$public_key" "$fingerprint_file" --apply >/dev/null 2>&1; then
  echo "GitHub secret configuration did not require exact confirmation" >&2
  exit 1
fi

fake_bin="$workspace/fake-bin"
mkdir "$fake_bin"
cat > "$fake_bin/gh" <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
case "$1 $2" in
  "auth status")
    exit 0
    ;;
  "repo view")
    printf '%s\n' "$GH_TEST_REPOSITORY"
    ;;
  "secret set")
    printf '%s\n' "$*" > "$GH_TEST_LOG"
    cat > "$GH_TEST_BODY"
    ;;
  "secret list")
    printf '%s\n' RELEASE_SIGNING_PRIVATE_KEY_B64
    ;;
  *)
    echo "Unexpected gh invocation: $*" >&2
    exit 1
    ;;
esac
SCRIPT
chmod 0755 "$fake_bin/gh"
export GH_TEST_REPOSITORY=Legacy-Hosting/LH-API
export GH_TEST_LOG="$workspace/gh.log"
export GH_TEST_BODY="$workspace/secret.body"
confirmation="Legacy-Hosting/LH-API:$expected_fingerprint"
PATH="$fake_bin:$PATH" LH_RELEASE_SECRET_CONFIRM="$confirmation" "$repository_root/scripts/configure-release-signing-secret.sh" api "$encrypted" "$identity" "$public_key" "$fingerprint_file" --apply
grep -Fqx 'secret set RELEASE_SIGNING_PRIVATE_KEY_B64 --repo Legacy-Hosting/LH-API' "$GH_TEST_LOG"
base64 -d "$GH_TEST_BODY" > "$workspace/configured-private.pem"
cmp "$decrypted" "$workspace/configured-private.pem"

if "$repository_root/scripts/generate-release-key-material.sh" api "$recipient" "$key_directory" >/dev/null 2>&1; then
  echo "Existing release key material was overwritten" >&2
  exit 1
fi

insecure_directory="$workspace/insecure"
mkdir -m 0750 "$insecure_directory"
if "$repository_root/scripts/generate-release-key-material.sh" panel "$recipient" "$insecure_directory" >/dev/null 2>&1; then
  echo "An insecure key-material directory was accepted" >&2
  exit 1
fi

if "$repository_root/scripts/generate-release-key-material.sh" status invalid-recipient "$key_directory" >/dev/null 2>&1; then
  echo "An invalid age recipient was accepted" >&2
  exit 1
fi

echo "Release key material integration test passed"
