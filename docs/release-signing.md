# Release signing

Every new production release must have three immutable files:

1. the `tar.gz` archive;
2. its `SHA256/<archive>.sha256` manifest;
3. its `SIGNATURES/<archive>.sig` detached Ed25519 signature.

SHA-256 detects accidental corruption. The Ed25519 signature proves that the
archive was approved by the release workflow holding that service's private
key. Each service has an independent key so compromise of one repository does
not authorize releases for another service.

## Key custody

Generate each key pair on a separate trusted operator machine. First create or
select an offline `age` identity and a mode-`0700` output directory on its
encrypted storage. Then run:

```bash
scripts/generate-release-key-material.sh \
  api AGE_RECIPIENT /encrypted/offline/release-keys
```

The script never writes an unencrypted private key outside its temporary
workspace. It creates `lh-api-release-private.pem.age`, `lh-api.pub`, and
`lh-api.pub.sha256`; refuses insecure output-directory permissions, symlinks,
and overwrites; and signs a challenge before accepting the generated key.

After independently reviewing the public-key fingerprint, decrypt the private
key only on the trusted operator machine and pipe its base64 representation
directly into the repository secret:

```bash
temporary_key=$(mktemp)
trap 'rm -f -- "$temporary_key"' EXIT
chmod 0600 "$temporary_key"
age --decrypt --identity /offline/recovery-identity.txt \
  --output "$temporary_key" \
  /encrypted/offline/release-keys/lh-api-release-private.pem.age
base64 -w0 < "$temporary_key" | \
  gh secret set RELEASE_SIGNING_PRIVATE_KEY_B64 \
    --repo Legacy-Hosting/LH-API
```

Repeat with a different key for every service. Keep each encrypted recovery
copy outside GitHub and production hosts. Never commit private keys or
encrypted recovery keys. Commit only the public key and its independently
reviewed SHA-256 fingerprint.

Install the service public key as a root-owned mode-`0644` file below
`/etc/legacy-hosting/release-keys`. Deployment must use the copy provisioned by
LH-Ops, not a key extracted from the release being verified.

## Signing and verification

The release workflow decodes its private key into an ephemeral runner file and
invokes:

```bash
scripts/sign-release-artifact.sh PRIVATE_KEY ARCHIVE CHECKSUM SIGNATURE
```

Before extraction or package installation, the target server invokes:

```bash
scripts/verify-release-artifact.sh \
  /etc/legacy-hosting/release-keys/lh-api.pub \
  lh-api-1.2.1.tar.gz \
  SHA256/lh-api-1.2.1.tar.gz.sha256 \
  SIGNATURES/lh-api-1.2.1.tar.gz.sig
```

Verification rejects symlink inputs, malformed checksum manifests, a checksum
for another filename, signatures with the wrong size, a mismatched key, and any
modified archive. Existing unsigned releases remain historical artifacts; do
not promote them as new production releases.

Provision a reviewed public key and fingerprint idempotently with:

```bash
sudo scripts/install-release-verifier.sh \
  api lh-api-release.pub EXPECTED_SHA256_FINGERPRINT
```

Replacing an installed key requires the explicit one-command confirmation
printed by the installer. Retain old public keys with the historical release
records before rotating; an old release cannot be verified by a new key.
