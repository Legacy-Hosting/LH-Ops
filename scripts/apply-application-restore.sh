#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 RESTORE.env /var/lib/legacy-hosting/application-restores/UUID/STAGING" >&2
  exit 2
fi
if [[ -z ${LH_RESTORE_OPERATOR:-} || ! $LH_RESTORE_OPERATOR =~ ^[^[:space:]]{3,191}$ ]]; then
  echo "LH_RESTORE_OPERATOR must identify the person performing the restore" >&2
  exit 1
fi
script_directory=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=application-backup-common.sh
. "$script_directory/application-backup-common.sh"
lh_load_application_config "$1" true
if [[ ${LH_RESTORE_CONFIRM:-} != "$APPLICATION_ID" ]]; then
  echo "Set LH_RESTORE_CONFIRM=$APPLICATION_ID to approve the live overwrite" >&2
  exit 1
fi
for command in cp find flock jq pm2; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Required application restore command is unavailable: $command" >&2
    exit 1
  fi
done

staged=$(readlink -f "$2")
expected_parent="$lh_application_restore_root/$APPLICATION_ID"
if [[ ! -d $staged || -L $staged || $staged != "$expected_parent"/* || \
      ! -f $staged/manifest.json || ! -d $staged/data ]]; then
  echo "Restore staging directory is invalid" >&2
  exit 1
fi
owner=$(stat -c '%u' "$staged")
permissions=$(stat -c '%a' "$staged")
if [[ $owner != 0 ]] || (( (8#$permissions & 077) != 0 )); then
  echo "Restore staging directory must be root-owned with mode 0700 or stricter" >&2
  exit 1
fi
if ! jq -e --arg applicationId "$APPLICATION_ID" --arg application "$APPLICATION_NAME" \
  '.formatVersion == "1" and .applicationId == $applicationId and .application == $application' \
  "$staged/manifest.json" >/dev/null; then
  echo "Restore staging manifest belongs to another application" >&2
  exit 1
fi
mapfile -t archived_paths < <(jq -r '.paths[]' "$staged/manifest.json")
if (( ${#archived_paths[@]} == 0 )); then
  echo "Restore staging manifest contains no paths" >&2
  exit 1
fi
for path in "${archived_paths[@]}"; do
  configured=false
  expected_type=
  for index in "${!LH_PERSISTENT_PATHS[@]}"; do
    if [[ $path == "${LH_PERSISTENT_PATHS[$index]}" ]]; then
      configured=true
      expected_type=${LH_PERSISTENT_TYPES[$index]}
      break
    fi
  done
  if [[ $configured != true ]]; then
    echo "Staged restore path is no longer allowlisted: $path" >&2
    exit 1
  fi
  source="$staged/data/$path"
  lh_assert_no_symlink_ancestors "$staged/data" "$path"
  lh_assert_regular_tree "$source"
  if [[ $expected_type == file && ! -f $source ]] || \
     [[ $expected_type == directory && ! -d $source ]]; then
    echo "Staged restore path has the wrong type: $path" >&2
    exit 1
  fi
done

install -d -m 0700 "$LH_PERSISTENT_ROOT"
lock_file="/run/lock/lh-application-backup-$APPLICATION_ID.lock"
exec 9>"$lock_file"
if ! flock -n 9; then
  echo "Another backup or restore is active for $APPLICATION_NAME" >&2
  exit 1
fi
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
rollback_root="$lh_application_backup_root/$APPLICATION_ID/pre-restore/$timestamp"
install -d -m 0700 "$rollback_root/data"
declare -A had_current=()
declare -A touched=()
for path in "${archived_paths[@]}"; do
  target="$LH_PERSISTENT_ROOT/$path"
  lh_assert_no_symlink_ancestors "$LH_PERSISTENT_ROOT" "$path"
  if [[ -e $target ]]; then
    lh_assert_regular_tree "$target"
    install -d -m 0700 "$rollback_root/data/$(dirname "$path")"
    cp -a --reflink=auto -- "$target" "$rollback_root/data/$path"
    had_current[$path]=true
  else
    had_current[$path]=false
  fi
done
cp -- "$staged/manifest.json" "$rollback_root/restore-manifest.json"

processes_stopped=false
completed=false
recover_on_error() {
  local status=$?
  set +e
  if [[ $completed != true ]]; then
    for path in "${archived_paths[@]}"; do
      [[ ${touched[$path]:-false} == true ]] || continue
      target="$LH_PERSISTENT_ROOT/$path"
      rm -rf -- "$target"
      if [[ ${had_current[$path]:-false} == true ]]; then
        install -d -m 0700 "$(dirname "$target")"
        cp -a -- "$rollback_root/data/$path" "$target"
      fi
    done
    if [[ $processes_stopped == true ]]; then
      # shellcheck disable=SC2086
      pm2 restart $APPLICATION_PM2_PROCESSES >/dev/null 2>&1 || true
    fi
    lh_append_application_audit "restore.apply" "failed" \
      "$(jq -cn --arg staging "$(basename "$staged")" --arg rollback "$timestamp" \
        '{staging:$staging,rollback:$rollback}')" || true
  fi
  exit "$status"
}
trap recover_on_error EXIT

# shellcheck disable=SC2086
pm2 stop $APPLICATION_PM2_PROCESSES >/dev/null
processes_stopped=true
restore_token=${timestamp//[^0-9A-Za-z]/}
for path in "${archived_paths[@]}"; do
  source="$staged/data/$path"
  target="$LH_PERSISTENT_ROOT/$path"
  install -d -m 0700 "$(dirname "$target")"
  replacement="${target}.lh-restore-$restore_token"
  if [[ -e $replacement || -L $replacement ]]; then
    echo "Restore replacement path already exists: $replacement" >&2
    exit 1
  fi
  cp -a --reflink=auto -- "$source" "$replacement"
  lh_assert_regular_tree "$replacement"
  touched[$path]=true
  rm -rf -- "$target"
  mv -- "$replacement" "$target"
done
# shellcheck disable=SC2086
pm2 restart $APPLICATION_PM2_PROCESSES >/dev/null
processes_stopped=false
lh_append_application_audit "restore.apply" "succeeded" \
  "$(jq -cn --arg staging "$(basename "$staged")" --arg rollback "$timestamp" \
    --argjson paths "$(printf '%s\n' "${archived_paths[@]}" | jq -R . | jq -s .)" \
    '{staging:$staging,rollback:$rollback,paths:$paths}')"
completed=true
trap - EXIT
rm -rf -- "$staged"
find "$lh_application_backup_root/$APPLICATION_ID/pre-restore" -mindepth 1 -maxdepth 1 \
  -type d -mtime +7 -exec rm -rf -- {} +
echo "Persistent data restored. Rollback copy retained at: $rollback_root"
