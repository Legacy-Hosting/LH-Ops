# Production release public keys

These are the reviewed Ed25519 public keys used to verify immutable Legacy
Hosting release archives. The matching private keys are encrypted offline and
stored outside Git, GitHub, and production servers.

Install a service key only through `scripts/install-release-verifier.sh` and
provide the fingerprint from the matching `.pub.sha256` file. Key rotation
requires the explicit confirmation enforced by that script.

