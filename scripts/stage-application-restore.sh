#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 RESTORE.env APPLICATION-TIMESTAMP.tar.gz.age" >&2
  exit 2
fi
if [[ -z ${LH_RESTORE_OPERATOR:-} || ! $LH_RESTORE_OPERATOR =~ ^[^[:space:]]{3,191}$ ]]; then
  echo "LH_RESTORE_OPERATOR must identify the person staging the restore" >&2
  exit 1
fi
script_directory=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=application-backup-common.sh
. "$script_directory/application-backup-common.sh"
lh_load_application_config "$1" true
for command in age flock gzip jq sha256sum tar; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Required application restore command is unavailable: $command" >&2
    exit 1
  fi
done

backup=$(readlink -f "$2")
backup_directory="$lh_application_backup_root/$APPLICATION_ID"
if [[ ! -f $backup || -L $backup || $backup != "$backup_directory"/${APPLICATION_NAME}-*.tar.gz.age ]]; then
  echo "Backup must be an encrypted $APPLICATION_NAME archive in $backup_directory" >&2
  exit 1
fi
checksum="$backup.sha256"
if [[ ! -f $checksum || -L $checksum ]]; then
  echo "Backup checksum is missing or unsafe" >&2
  exit 1
fi
read -r expected_hash checksum_filename < "$checksum"
if [[ ! $expected_hash =~ ^[a-f0-9]{64}$ || $checksum_filename != "$(basename "$backup")" ]]; then
  echo "Backup checksum does not identify the selected archive" >&2
  exit 1
fi
actual_hash=$(sha256sum "$backup" | cut -d ' ' -f 1)
if [[ $actual_hash != "$expected_hash" ]]; then
  echo "Backup checksum verification failed" >&2
  exit 1
fi

install -d -m 0700 "$lh_application_restore_root/$APPLICATION_ID"
lock_file="/run/lock/lh-application-backup-$APPLICATION_ID.lock"
exec 9>"$lock_file"
if ! flock -n 9; then
  echo "Another backup or restore is active for $APPLICATION_NAME" >&2
  exit 1
fi
restore_name=$(basename "$backup" .tar.gz.age)
staged="$lh_application_restore_root/$APPLICATION_ID/$restore_name"
if [[ -e $staged ]]; then
  echo "Restore is already staged: $staged" >&2
  exit 1
fi
workspace=$(mktemp -d "$lh_application_restore_root/$APPLICATION_ID/.staging.XXXXXX")
plaintext="$workspace/restore.tar.gz"
completed=false
cleanup() {
  rm -rf -- "$workspace"
  if [[ $completed != true ]]; then
    lh_append_application_audit "restore.stage" "failed" \
      "$(jq -cn --arg backup "$(basename "$backup")" '{backup:$backup}')" || true
  fi
}
trap cleanup EXIT

age --decrypt --identity "$BACKUP_AGE_IDENTITY" --output "$plaintext" "$backup"
gzip -t "$plaintext"
while IFS= read -r member; do
  member=${member#./}
  if [[ -z $member || $member == /* || $member == *\\* || \
        $member == .. || $member == ../* || $member == */../* || \
        ( $member != manifest.json && $member != data && $member != data/* ) ]]; then
    echo "Backup contains an unsafe archive member" >&2
    exit 1
  fi
done < <(tar -tzf "$plaintext")
install -d -m 0700 "$workspace/extracted"
tar --no-same-owner --no-same-permissions -C "$workspace/extracted" -xzf "$plaintext"
rm -f -- "$plaintext"
if [[ ! -f $workspace/extracted/manifest.json || ! -d $workspace/extracted/data ]]; then
  echo "Backup manifest or data directory is missing" >&2
  exit 1
fi
if ! jq -e \
  --arg applicationId "$APPLICATION_ID" \
  --arg application "$APPLICATION_NAME" \
  '.formatVersion == "1" and .applicationId == $applicationId and .application == $application and (.paths | type == "array")' \
  "$workspace/extracted/manifest.json" >/dev/null; then
  echo "Backup manifest belongs to another application or format" >&2
  exit 1
fi
mapfile -t archived_paths < <(jq -r '.paths[]' "$workspace/extracted/manifest.json")
if (( ${#archived_paths[@]} == 0 )); then
  echo "Backup manifest contains no persistent paths" >&2
  exit 1
fi
for path in "${archived_paths[@]}"; do
  configured=false
  for configured_path in "${LH_PERSISTENT_PATHS[@]}"; do
    if [[ $path == "$configured_path" ]]; then configured=true; break; fi
  done
  if [[ $configured != true ]]; then
    echo "Backup contains a path that is no longer allowlisted: $path" >&2
    exit 1
  fi
  lh_assert_no_symlink_ancestors "$workspace/extracted/data" "$path"
  if [[ ! -e $workspace/extracted/data/$path ]]; then
    echo "Backup is missing an archived path: $path" >&2
    exit 1
  fi
done
lh_assert_regular_tree "$workspace/extracted/data"
chmod -R u=rwX,go= "$workspace/extracted"
mv "$workspace/extracted" "$staged"
chmod 0700 "$staged"
lh_append_application_audit "restore.stage" "succeeded" \
  "$(jq -cn --arg backup "$(basename "$backup")" --arg staging "$restore_name" \
    --arg sha256 "$actual_hash" '{backup:$backup,staging:$staging,sha256:$sha256}')"
completed=true
trap - EXIT
rm -rf -- "$workspace"
echo "Restore validated and staged without changing live data: $staged"
