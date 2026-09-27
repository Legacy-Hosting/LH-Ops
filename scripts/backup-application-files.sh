#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 /etc/legacy-hosting/application-backups/APPLICATION.env" >&2
  exit 2
fi
script_directory=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=application-backup-common.sh
. "$script_directory/application-backup-common.sh"
lh_load_application_config "$1" false

local_retention_days=${BACKUP_LOCAL_RETENTION_DAYS:-2}
if [[ ! $local_retention_days =~ ^[0-9]+$ ]] || \
   (( local_retention_days < 1 || local_retention_days > 30 )); then
  echo "BACKUP_LOCAL_RETENTION_DAYS must be between 1 and 30" >&2
  exit 1
fi
for command in age cmp flock jq rclone sha256sum sync tar; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Required application backup command is unavailable: $command" >&2
    exit 1
  fi
done
if [[ ! -d $LH_PERSISTENT_ROOT ]]; then
  echo "Persistent root does not exist: $LH_PERSISTENT_ROOT" >&2
  exit 1
fi

backup_directory="$lh_application_backup_root/$APPLICATION_ID"
install -d -m 0700 "$backup_directory"
lock_file="/run/lock/lh-application-backup-$APPLICATION_ID.lock"
exec 9>"$lock_file"
if ! flock -n 9; then
  echo "Another backup or restore is active for $APPLICATION_NAME" >&2
  exit 1
fi

timestamp=$(date -u +%Y%m%dT%H%M%SZ)
archive_name="${APPLICATION_NAME}-${timestamp}.tar.gz.age"
encrypted="$backup_directory/$archive_name"
checksum="$encrypted.sha256"
workspace=$(mktemp -d "$backup_directory/.snapshot-${timestamp}.XXXXXX")
plaintext="$workspace/${APPLICATION_NAME}-${timestamp}.tar.gz"
encrypted_temporary="$workspace/$archive_name"
checksum_temporary="$workspace/$archive_name.sha256"
completed=false
cleanup() {
  rm -rf -- "$workspace"
  if [[ $completed != true ]]; then
    lh_append_application_audit "backup.create" "failed" \
      "$(jq -cn --arg backup "$archive_name" '{backup:$backup}')" || true
  fi
}
trap cleanup EXIT
if [[ -e $encrypted || -e $checksum ]]; then
  echo "Refusing to overwrite an existing application backup" >&2
  exit 1
fi

install -d -m 0700 "$workspace/snapshot/data"
declare -a available_paths=()
declare -a missing_paths=()
for index in "${!LH_PERSISTENT_PATHS[@]}"; do
  path=${LH_PERSISTENT_PATHS[$index]}
  expected_type=${LH_PERSISTENT_TYPES[$index]}
  source="$LH_PERSISTENT_ROOT/$path"
  lh_assert_no_symlink_ancestors "$LH_PERSISTENT_ROOT" "$path"
  if [[ ! -e $source ]]; then
    missing_paths+=("$path")
    continue
  fi
  lh_assert_regular_tree "$source"
  if [[ $expected_type == file && ! -f $source ]] || \
     [[ $expected_type == directory && ! -d $source ]]; then
    echo "Persistent path has the wrong type: $path" >&2
    exit 1
  fi
  available_paths+=("$path")
done
if (( ${#available_paths[@]} == 0 )); then
  echo "No configured persistent data exists yet" >&2
  exit 1
fi

tar -C "$LH_PERSISTENT_ROOT" \
  --exclude='*/node_modules' --exclude='*/node_modules/*' \
  --exclude='*/.cache' --exclude='*/.cache/*' \
  --exclude='*/cache' --exclude='*/cache/*' \
  --exclude='*/tmp' --exclude='*/tmp/*' \
  --exclude='*/temp' --exclude='*/temp/*' \
  --exclude='*.sock' --exclude='*.sqlite' --exclude='*.sqlite3' --exclude='*.db' \
  -cf - -- "${available_paths[@]}" | \
  tar --no-same-owner -C "$workspace/snapshot/data" -xf -
lh_assert_regular_tree "$workspace/snapshot/data"

paths_json=$(printf '%s\n' "${available_paths[@]}" | jq -R . | jq -s .)
if (( ${#missing_paths[@]} > 0 )); then
  missing_json=$(printf '%s\n' "${missing_paths[@]}" | jq -R . | jq -s .)
else
  missing_json='[]'
fi
file_count=$(find -P "$workspace/snapshot/data" -type f | wc -l)
byte_count=$(du -sb "$workspace/snapshot/data" | cut -f1)
jq -n \
  --arg formatVersion "1" \
  --arg applicationId "$APPLICATION_ID" \
  --arg application "$APPLICATION_NAME" \
  --arg createdAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson paths "$paths_json" \
  --argjson missingPaths "$missing_json" \
  --argjson fileCount "$file_count" \
  --argjson uncompressedBytes "$byte_count" \
  '{formatVersion:$formatVersion,applicationId:$applicationId,application:$application,createdAt:$createdAt,paths:$paths,missingPaths:$missingPaths,fileCount:$fileCount,uncompressedBytes:$uncompressedBytes}' \
  > "$workspace/snapshot/manifest.json"

tar -C "$workspace/snapshot" -czf "$plaintext" manifest.json data
gzip -t "$plaintext"
age --recipient "$BACKUP_AGE_RECIPIENT" --output "$encrypted_temporary" "$plaintext"
rm -f -- "$plaintext"
sync -f "$encrypted_temporary"
chmod 0600 "$encrypted_temporary"
mv -n "$encrypted_temporary" "$encrypted"
(cd "$backup_directory" && sha256sum "$archive_name") > "$checksum_temporary"
sync -f "$checksum_temporary"
chmod 0600 "$checksum_temporary"
mv -n "$checksum_temporary" "$checksum"

expected_hash=$(cut -d ' ' -f 1 "$checksum")
lh_configure_rclone
remote_root="lhbackup:${BACKUP_S3_BUCKET}/${BACKUP_S3_PREFIX}/${APPLICATION_ID}"
upload_tier() {
  local tier=$1
  local remote_backup="$remote_root/$tier/$archive_name"
  rclone copyto --no-traverse "$encrypted" "$remote_backup"
  rclone copyto --no-traverse "$checksum" "$remote_backup.sha256"
  local remote_hash
  remote_hash=$(rclone cat "$remote_backup" | sha256sum | cut -d ' ' -f 1)
  if [[ $remote_hash != "$expected_hash" ]] || \
     ! cmp -s <(rclone cat "$remote_backup.sha256") "$checksum"; then
    echo "Off-site verification failed for $APPLICATION_NAME $tier backup" >&2
    return 1
  fi
}
declare -a uploaded_tiers=(daily)
upload_tier daily
day=$(date -u +%d)
month=$(date -u +%m)
if [[ $day == 01 ]]; then
  upload_tier monthly
  uploaded_tiers+=(monthly)
  if [[ $month == 01 ]]; then
    upload_tier yearly
    uploaded_tiers+=(yearly)
  fi
fi

prune_tier() {
  local tier=$1
  local minimum_age=$2
  local expired count
  expired=$(rclone lsf "$remote_root/$tier" --files-only --max-depth 1 \
    --min-age "$minimum_age" --include "${APPLICATION_NAME}-*.tar.gz.age" \
    --include "${APPLICATION_NAME}-*.tar.gz.age.sha256" 2>/dev/null || true)
  count=$(printf '%s\n' "$expired" | sed '/^$/d' | wc -l)
  if (( count > 0 )); then
    rclone delete "$remote_root/$tier" --min-age "$minimum_age" \
      --include "${APPLICATION_NAME}-*.tar.gz.age" \
      --include "${APPLICATION_NAME}-*.tar.gz.age.sha256"
    lh_append_application_audit "backup.retention_delete" "succeeded" \
      "$(jq -cn --arg tier "$tier" --argjson objects "$count" '{tier:$tier,objects:$objects}')"
  fi
}
prune_tier daily 35d
prune_tier monthly 366d
prune_tier yearly 1096d
find "$backup_directory" -maxdepth 1 -type f \
  \( -name "${APPLICATION_NAME}-*.tar.gz.age" -o -name "${APPLICATION_NAME}-*.tar.gz.age.sha256" \) \
  -mtime "+$local_retention_days" -delete

encrypted_bytes=$(stat -c '%s' "$encrypted")
tiers_json=$(printf '%s\n' "${uploaded_tiers[@]}" | jq -R . | jq -s .)
lh_append_application_audit "backup.create" "succeeded" \
  "$(jq -cn --arg backup "$archive_name" --arg sha256 "$expected_hash" \
    --argjson bytes "$encrypted_bytes" --argjson files "$file_count" \
    --argjson tiers "$tiers_json" \
    '{backup:$backup,sha256:$sha256,encryptedBytes:$bytes,files:$files,tiers:$tiers}')"
completed=true
trap - EXIT
rm -rf -- "$workspace"
echo "Encrypted persistent-file backup created and verified off-site: $encrypted"
