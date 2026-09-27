#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -ne 0 || $# -lt 1 || $# -gt 3 ]]; then
  echo "Usage as root: $0 BUCKET [ENDPOINT] [PREFIX]" >&2
  exit 2
fi

bucket=$1
endpoint=${2:-ams3.digitaloceanspaces.com}
prefix=${3:-legacy-hosting/mysql}
output=/root/.secrets/spaces-backup.env

if [[ ! $bucket =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]]; then
  echo "Bucket name is not valid" >&2
  exit 1
fi
if [[ ! $endpoint =~ ^[a-z0-9][a-z0-9.-]+$ ]]; then
  echo "Spaces endpoint is not valid" >&2
  exit 1
fi
if [[ ! $prefix =~ ^[a-z0-9][a-z0-9/_-]{0,127}$ || $prefix == *..* ]]; then
  echo "Backup prefix is not valid" >&2
  exit 1
fi
if [[ -e $output ]]; then
  echo "$output already exists; refusing to overwrite credentials" >&2
  exit 1
fi

read -r -p "Spaces access key ID: " access_key_id
read -r -s -p "Spaces secret access key: " secret_access_key
printf '\n'

if (( ${#access_key_id} < 16 )); then
  echo "Spaces access key ID is too short" >&2
  exit 1
fi
if (( ${#secret_access_key} < 32 )); then
  echo "Spaces secret access key is too short" >&2
  exit 1
fi
if [[ $access_key_id =~ [[:space:]] || $secret_access_key =~ [[:space:]] ]]; then
  echo "Spaces credentials must not contain whitespace" >&2
  exit 1
fi

umask 077
install -d -m 0700 /root/.secrets
temporary=$(mktemp /root/.secrets/.spaces-backup.env.XXXXXX)
trap 'rm -f -- "$temporary"' EXIT

printf '%s\n' \
  "BACKUP_S3_ENDPOINT=$endpoint" \
  "BACKUP_S3_BUCKET=$bucket" \
  "BACKUP_S3_PREFIX=$prefix" \
  "BACKUP_S3_ACCESS_KEY_ID=$access_key_id" \
  "BACKUP_S3_SECRET_ACCESS_KEY=$secret_access_key" \
  > "$temporary"
chmod 0600 "$temporary"
mv -n "$temporary" "$output"
trap - EXIT

unset access_key_id secret_access_key
echo "Protected Spaces backup credentials were written to $output."
