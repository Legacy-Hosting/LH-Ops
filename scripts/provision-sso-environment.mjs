#!/usr/bin/env node

import {
  generateKeyPairSync,
  randomBytes,
  randomUUID,
} from "node:crypto";
import {
  chmodSync,
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  statSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { resolve } from "node:path";

if (process.getuid?.() !== 0 || process.argv.length !== 3) {
  console.error("Usage as root: provision-sso-environment.mjs DATABASE_TRANSFER_FILE");
  process.exit(2);
}

const transferFile = resolve(process.argv[2]);
if (!existsSync(transferFile) || lstatSync(transferFile).isSymbolicLink()) {
  throw new Error("Database transfer input must be a regular file.");
}
if ((statSync(transferFile).mode & 0o077) !== 0) {
  throw new Error("Database transfer input must have mode 0600 or stricter.");
}

function parseEnvironment(contents) {
  const values = new Map();
  for (const rawLine of contents.split(/\r?\n/u)) {
    if (!rawLine || rawLine.startsWith("#")) continue;
    const match = /^([A-Z][A-Z0-9_]*)=(.*)$/u.exec(rawLine);
    if (!match || values.has(match[1])) throw new Error("Invalid database transfer file.");
    values.set(match[1], match[2]);
  }
  return values;
}

function secret() {
  return randomBytes(32).toString("base64url");
}

function shellQuote(value) {
  return `'${value.replaceAll("'", `'\\''`)}'`;
}

function privateSigningKey() {
  const { privateKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
  return {
    ...privateKey.export({ format: "jwk" }),
    kid: randomUUID(),
    use: "sig",
    alg: "ES256",
  };
}

const database = parseEnvironment(readFileSync(transferFile, "utf8"));
const databaseUrl = database.get("DATABASE_URL");
const legacyDatabaseUrl = database.get("LEGACY_DATABASE_URL");
if (!databaseUrl?.startsWith("mysql://") || !legacyDatabaseUrl?.startsWith("mysql://")) {
  throw new Error("Database transfer file is missing valid database URLs.");
}

const environmentDirectory = "/etc/legacy-hosting";
const fragmentDirectory = `${environmentDirectory}/service-fragments`;
const targets = {
  environment: `${environmentDirectory}/sso.env`,
  jwks: `${environmentDirectory}/sso-oidc-jwks.json`,
  api: `${fragmentDirectory}/api-sso.env`,
  hub: `${fragmentDirectory}/hub-sso.env`,
  discord: `${fragmentDirectory}/discord-sso.env`,
};
for (const target of Object.values(targets)) {
  if (existsSync(target)) throw new Error(`Refusing to overwrite protected file: ${target}`);
}
if (existsSync(environmentDirectory) && lstatSync(environmentDirectory).isSymbolicLink()) {
  throw new Error(`${environmentDirectory} must not be a symlink.`);
}
mkdirSync(environmentDirectory, { recursive: true, mode: 0o700 });
mkdirSync(fragmentDirectory, { recursive: true, mode: 0o700 });
chmodSync(environmentDirectory, 0o700);
chmodSync(fragmentDirectory, 0o700);

const discordToken = secret();
const identityBridgeToken = secret();
const panelClientSecret = secret();
const hubClientSecret = secret();
const cookieKeys = [secret(), secret()];
const clients = [
  {
    client_id: "lh-panel",
    client_secret: panelClientSecret,
    redirect_uris: ["https://api.legacyhosting.xyz/api/v1/auth/oidc/callback"],
    post_logout_redirect_uris: ["https://panel.legacyhosting.xyz/"],
    backchannel_logout_uri: "https://api.legacyhosting.xyz/api/v1/auth/oidc/backchannel-logout",
    backchannel_logout_session_required: true,
    grant_types: ["authorization_code", "refresh_token"],
    response_types: ["code"],
    token_endpoint_auth_method: "client_secret_basic",
    lh_resource: "https://api.legacyhosting.xyz",
  },
  {
    client_id: "lh-hub",
    client_secret: hubClientSecret,
    redirect_uris: ["https://hub.legacyhosting.xyz/auth/callback"],
    post_logout_redirect_uris: ["https://hub.legacyhosting.xyz/"],
    backchannel_logout_uri: "https://hub.legacyhosting.xyz/auth/backchannel-logout",
    backchannel_logout_session_required: true,
    grant_types: ["authorization_code", "refresh_token"],
    response_types: ["code"],
    token_endpoint_auth_method: "client_secret_basic",
    lh_resource: "https://hub.legacyhosting.xyz",
  },
];
const resources = [
  { identifier: "https://api.legacyhosting.xyz", audience: "lh-api", scopes: ["openid", "profile", "email", "roles"] },
  { identifier: "https://hub.legacyhosting.xyz", audience: "lh-hub", scopes: ["openid", "profile", "email", "roles"] },
];

const environment = [
  "NODE_ENV=production",
  "HOST=127.0.0.1",
  "PORT=8080",
  "OIDC_PORT=8081",
  "TRUST_PROXY=true",
  `DATABASE_URL=${shellQuote(databaseUrl)}`,
  "DATABASE_SSL_CA=/etc/legacy-hosting/database-ca.pem",
  `LEGACY_DATABASE_URL=${shellQuote(legacyDatabaseUrl)}`,
  "LEGACY_DATABASE_SSL_CA=/etc/legacy-hosting/database-ca.pem",
  "LEGACY_WEBAUTHN_RP_ID=legacyhosting.xyz",
  "DATABASE_CONNECT_TIMEOUT_MS=5000",
  "DATABASE_HEALTH_TIMEOUT_MS=3000",
  `LH_DISCORD_INTERNAL_TOKEN=${discordToken}`,
  `LH_IDENTITY_BRIDGE_TOKEN=${identityBridgeToken}`,
  "OIDC_ISSUER=https://auth.legacyhosting.xyz",
  `OIDC_COOKIE_KEYS_JSON=${shellQuote(JSON.stringify(cookieKeys))}`,
  `OIDC_JWKS_FILE=${targets.jwks}`,
  `OIDC_CLIENTS_JSON=${shellQuote(JSON.stringify(clients))}`,
  `OIDC_RESOURCES_JSON=${shellQuote(JSON.stringify(resources))}`,
  "OIDC_LEGACY_LOGIN_URL=https://panel.legacyhosting.xyz/login",
  "OIDC_LOGIN_MODE=legacy_bridge",
  `WEBAUTHN_RP_NAME=${shellQuote("Legacy Hosting")}`,
  "WEBAUTHN_RP_ID=legacyhosting.xyz",
  "WEBAUTHN_ORIGIN=https://auth.legacyhosting.xyz",
  "",
].join("\n");
const apiFragment = [
  "SSO_INTERNAL_URL=https://auth.legacyhosting.xyz",
  "SSO_ISSUER=https://auth.legacyhosting.xyz",
  "SSO_JWKS_URL=https://auth.legacyhosting.xyz/.well-known/jwks.json",
  "HUB_SSO_AUDIENCE=lh-hub",
  `SSO_IDENTITY_BRIDGE_TOKEN=${identityBridgeToken}`,
  "SSO_CLIENT_ID=lh-panel",
  `SSO_CLIENT_SECRET=${panelClientSecret}`,
  "SSO_REDIRECT_URI=https://api.legacyhosting.xyz/api/v1/auth/oidc/callback",
  "SSO_RESOURCE=https://api.legacyhosting.xyz",
  "SSO_REQUEST_TIMEOUT_MS=5000",
  "",
].join("\n");
const hubFragment = [
  "SSO_ISSUER=https://auth.legacyhosting.xyz",
  "SSO_AUDIENCE=lh-hub",
  "SSO_JWKS_URL=https://auth.legacyhosting.xyz/.well-known/jwks.json",
  "SSO_CLIENT_ID=lh-hub",
  `SSO_CLIENT_SECRET=${hubClientSecret}`,
  "SSO_REDIRECT_URI=https://hub.legacyhosting.xyz/auth/callback",
  "SSO_RESOURCE=https://hub.legacyhosting.xyz",
  "",
].join("\n");
const discordFragment = `LH_DISCORD_INTERNAL_TOKEN=${discordToken}\n`;
const jwks = `${JSON.stringify({ keys: [privateSigningKey(), privateSigningKey()] }, null, 2)}\n`;

for (const [target, contents] of [
  [targets.environment, environment],
  [targets.jwks, jwks],
  [targets.api, apiFragment],
  [targets.hub, hubFragment],
  [targets.discord, discordFragment],
]) {
  writeFileSync(target, contents, { encoding: "utf8", flag: "wx", mode: 0o600 });
  chmodSync(target, 0o600);
}
unlinkSync(transferFile);

console.log("Created protected SSO environment, private JWKS, and service fragments without printing secrets.");
