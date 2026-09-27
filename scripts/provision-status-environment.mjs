#!/usr/bin/env node

import { createECDH } from "node:crypto";
import { chmodSync, existsSync, lstatSync, mkdirSync, writeFileSync } from "node:fs";

if (process.getuid?.() !== 0) {
  console.error("Run this script as root on the Status host.");
  process.exit(1);
}

const environmentDirectory = "/etc/legacy-hosting";
const environmentFile = `${environmentDirectory}/status.env`;
if (existsSync(environmentFile)) {
  console.error(`Refusing to overwrite existing Status environment: ${environmentFile}`);
  process.exit(1);
}
if (existsSync(environmentDirectory) && lstatSync(environmentDirectory).isSymbolicLink()) {
  console.error(`${environmentDirectory} must not be a symlink.`);
  process.exit(1);
}

mkdirSync(environmentDirectory, { recursive: true, mode: 0o755 });

const vapid = createECDH("prime256v1");
vapid.generateKeys();
const components = [
  { key: "api", name: "API", url: "https://api.legacyhosting.xyz/health" },
  { key: "sso", name: "SSO", url: "https://auth.legacyhosting.xyz/health" },
  { key: "panel", name: "Web Panel", url: "https://panel.legacyhosting.xyz/" },
];
const allowedPushHosts = [
  "fcm.googleapis.com",
  "updates.push.services.mozilla.com",
  "web.push.apple.com",
  "notify.windows.com",
];
const lines = [
  "NODE_ENV=production",
  "HOST=127.0.0.1",
  "PORT=8082",
  "TRUST_PROXY=true",
  "STATUS_PUBLIC_ORIGIN=https://status.legacyhosting.xyz",
  `STATUS_COMPONENTS='${JSON.stringify(components)}'`,
  "STATUS_DATA_FILE=/var/lib/legacy-hosting-status/status-snapshot.json",
  "STATUS_HISTORY_FILE=/var/lib/legacy-hosting-status/status-history.ndjson",
  "STATUS_EVENTS_FILE=/var/lib/legacy-hosting-status/status-events.json",
  "STATUS_PUSH_STATE_FILE=/var/lib/legacy-hosting-status/push-state.json",
  "STATUS_PUSH_VAPID_SUBJECT=mailto:status@legacyhosting.xyz",
  `STATUS_PUSH_VAPID_PUBLIC_KEY=${vapid.getPublicKey().toString("base64url")}`,
  `STATUS_PUSH_VAPID_PRIVATE_KEY=${vapid.getPrivateKey().toString("base64url")}`,
  `STATUS_PUSH_ALLOWED_HOSTS='${JSON.stringify(allowedPushHosts)}'`,
  "STATUS_POLL_INTERVAL_MS=30000",
  "STATUS_REQUEST_TIMEOUT_MS=5000",
  "STATUS_DEGRADED_AFTER_MS=1500",
  "",
];

writeFileSync(environmentFile, lines.join("\n"), {
  encoding: "utf8",
  flag: "wx",
  mode: 0o600,
});
chmodSync(environmentFile, 0o600);
console.log(`Created protected Status production environment: ${environmentFile}`);
