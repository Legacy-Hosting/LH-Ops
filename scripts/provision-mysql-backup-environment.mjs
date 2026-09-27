#!/usr/bin/env node

import {
  chmodSync,
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { resolve } from "node:path";

if (process.getuid?.() !== 0 || process.argv.length !== 6) {
  console.error(
    "Usage as root: provision-mysql-backup-environment.mjs SERVICE SERVICE_ENV SPACES_ENV AGE_RECIPIENT_FILE",
  );
  process.exit(2);
}

const service = process.argv[2].toLowerCase();
if (service !== "api" && service !== "sso") {
  throw new Error("SERVICE must be api or sso.");
}
const serviceEnvironment = resolve(process.argv[3]);
const spacesEnvironment = resolve(process.argv[4]);
const recipientFile = resolve(process.argv[5]);
for (const input of [serviceEnvironment, spacesEnvironment, recipientFile]) {
  if (!existsSync(input) || lstatSync(input).isSymbolicLink() || !lstatSync(input).isFile()) {
    throw new Error(`Input must be a regular file: ${input}`);
  }
}
for (const input of [serviceEnvironment, spacesEnvironment]) {
  if ((statSync(input).mode & 0o077) !== 0) {
    throw new Error(`Secret input must have mode 0600 or stricter: ${input}`);
  }
}

function unquote(value) {
  if (value.startsWith("'") && value.endsWith("'")) {
    return value.slice(1, -1).replaceAll(`'\\''`, "'");
  }
  if (value.startsWith('"') && value.endsWith('"')) return value.slice(1, -1);
  return value;
}

function parseEnvironment(contents, source) {
  const values = new Map();
  for (const rawLine of contents.split(/\r?\n/u)) {
    if (!rawLine || rawLine.startsWith("#")) continue;
    const match = /^([A-Z][A-Z0-9_]*)=(.*)$/u.exec(rawLine);
    if (!match || values.has(match[1])) throw new Error(`Invalid or duplicate setting in ${source}.`);
    values.set(match[1], unquote(match[2]));
  }
  return values;
}

function requireValue(values, name, source) {
  const value = values.get(name);
  if (!value) throw new Error(`Missing ${name} in ${source}.`);
  return value;
}

function shellQuote(value) {
  return `'${value.replaceAll("'", `'\\''`)}'`;
}

const serviceValues = parseEnvironment(readFileSync(serviceEnvironment, "utf8"), serviceEnvironment);
const spacesValues = parseEnvironment(readFileSync(spacesEnvironment, "utf8"), spacesEnvironment);
const databaseUrl = new URL(requireValue(serviceValues, "DATABASE_URL", serviceEnvironment));
if (databaseUrl.protocol !== "mysql:") throw new Error("DATABASE_URL must use mysql://.");
const databaseName = databaseUrl.pathname.replace(/^\//u, "");
if (!databaseName) throw new Error("DATABASE_URL must include a database name.");
const recipient = readFileSync(recipientFile, "utf8").trim();
if (!/^age1[ac-hj-np-z02-9]{20,}$/u.test(recipient)) {
  throw new Error("AGE_RECIPIENT_FILE does not contain a native age recipient.");
}

const outputDirectory = "/etc/legacy-hosting/backups";
const output = `${outputDirectory}/${service}.env`;
if (existsSync(output)) throw new Error(`Refusing to overwrite backup environment: ${output}`);
mkdirSync(outputDirectory, { recursive: true, mode: 0o700 });
chmodSync(outputDirectory, 0o700);

const lines = [
  `BACKUP_NAME=${service}`,
  `DB_HOST=${shellQuote(databaseUrl.hostname)}`,
  `DB_PORT=${databaseUrl.port || "3306"}`,
  `DB_NAME=${shellQuote(databaseName)}`,
  `DB_USER=${shellQuote(decodeURIComponent(databaseUrl.username))}`,
  `DB_PASSWORD=${shellQuote(decodeURIComponent(databaseUrl.password))}`,
  `DB_SSL_CA=${shellQuote(requireValue(serviceValues, "DATABASE_SSL_CA", serviceEnvironment))}`,
  `BACKUP_AGE_RECIPIENT=${recipient}`,
  `BACKUP_S3_ENDPOINT=${shellQuote(requireValue(spacesValues, "BACKUP_S3_ENDPOINT", spacesEnvironment))}`,
  `BACKUP_S3_BUCKET=${shellQuote(requireValue(spacesValues, "BACKUP_S3_BUCKET", spacesEnvironment))}`,
  `BACKUP_S3_PREFIX=${shellQuote(requireValue(spacesValues, "BACKUP_S3_PREFIX", spacesEnvironment))}`,
  `BACKUP_S3_ACCESS_KEY_ID=${shellQuote(requireValue(spacesValues, "BACKUP_S3_ACCESS_KEY_ID", spacesEnvironment))}`,
  `BACKUP_S3_SECRET_ACCESS_KEY=${shellQuote(requireValue(spacesValues, "BACKUP_S3_SECRET_ACCESS_KEY", spacesEnvironment))}`,
  "BACKUP_RETENTION_DAYS=14",
  "",
];
writeFileSync(output, lines.join("\n"), { encoding: "utf8", flag: "wx", mode: 0o600 });
chmodSync(output, 0o600);
console.log(`Created protected ${service} MySQL backup environment: ${output}`);
