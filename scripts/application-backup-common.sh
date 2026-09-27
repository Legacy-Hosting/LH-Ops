#!/usr/bin/env bash
set -Eeuo pipefail

lh_application_config_directory=/etc/legacy-hosting/application-backups
lh_application_backup_root=/var/backups/legacy-hosting/applications
lh_application_restore_root=/var/lib/legacy-hosting/application-restores
lh_application_audit_log=/var/log/legacy-hosting/application-backups.jsonl

lh_require_root_secret_file() {
  local path=$1
  local description=$2
  if [[ ! -f $path || -L $path ]]; then
    echo "$description must be a regular file" >&2
    return 1
  fi
  local permissions owner
  permissions=$(stat -c '%a' "$path")
  owner=$(stat -c '%u' "$path")
  if (( (8#$permissions & 077) != 0 )) || [[ $owner != 0 ]]; then
    echo "$description must be owned by root with mode 0600 or stricter" >&2
    return 1
  fi
}

lh_validate_application_id() {
  [[ $1 =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$ ]]
}

lh_validate_storage_path() {
  local path=$1
  local host_pattern='^[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?$'
  [[ $path =~ ^/home/([^/]+)/([^/]+)$ ]] || return 1
  local owner_directory=${BASH_REMATCH[1]}
  local application_directory=${BASH_REMATCH[2]}
  [[ $owner_directory =~ $host_pattern && $application_directory =~ $host_pattern ]]
}

lh_assert_no_symlink_ancestors() {
  local root=$1
  local relative_path=$2
  if [[ -L $root ]]; then
    echo "Unsafe symbolic-link root: $root" >&2
    return 1
  fi
  local current=$root
  local segment
  IFS=/ read -ra segments <<< "$relative_path"
  for segment in "${segments[@]}"; do
    current="$current/$segment"
    if [[ -L $current ]]; then
      echo "Persistent path crosses a symbolic link: $relative_path" >&2
      return 1
    fi
  done
}

lh_validate_relative_path() {
  local path=$1
  [[ -n $path && $path != /* && $path != \\* && $path != *//* && \
     $path != *$'\n'* && $path != *$'\r'* && $path =~ ^[A-Za-z0-9._/-]+$ ]] || return 1
  local segment
  IFS=/ read -ra segments <<< "$path"
  for segment in "${segments[@]}"; do
    [[ -n $segment && $segment != . && $segment != .. ]] || return 1
    case "${segment,,}" in
      node_modules|.cache|cache|tmp|temp|.git) return 1 ;;
    esac
  done
  case "${path,,}" in
    *.sock|*.sqlite|*.sqlite3|*.db) return 1 ;;
  esac
}

lh_load_application_config() {
  local environment_file=$1
  local require_restore_identity=${2:-false}
  environment_file=$(readlink -f "$environment_file")
  if [[ ! -f $environment_file || \
        $environment_file != "$lh_application_config_directory"/*.env ]]; then
    echo "Application backup configuration must be an .env file under $lh_application_config_directory" >&2
    return 1
  fi
  lh_require_root_secret_file "$environment_file" "Application backup configuration"
  # The file is safe to source because it is root-owned and not group/world readable.
  # shellcheck disable=SC1090
  . "$environment_file"

  local required=(
    APPLICATION_ID APPLICATION_NAME APPLICATION_STORAGE_PATH
    PERSISTENT_PATHS_FILE
  )
  if [[ $require_restore_identity == true ]]; then
    required+=(BACKUP_AGE_IDENTITY APPLICATION_PM2_PROCESSES)
  else
    required+=(
      BACKUP_AGE_RECIPIENT BACKUP_S3_ENDPOINT BACKUP_S3_BUCKET
      BACKUP_S3_PREFIX BACKUP_S3_ACCESS_KEY_ID BACKUP_S3_SECRET_ACCESS_KEY
    )
  fi
  local name
  for name in "${required[@]}"; do
    if [[ -z ${!name:-} ]]; then
      echo "Missing application backup setting: $name" >&2
      return 1
    fi
  done
  if ! lh_validate_application_id "$APPLICATION_ID"; then
    echo "APPLICATION_ID must be a UUID" >&2
    return 1
  fi
  if [[ ! $APPLICATION_NAME =~ ^[a-z0-9][a-z0-9-]{1,79}$ ]]; then
    echo "APPLICATION_NAME must be a lowercase application slug" >&2
    return 1
  fi
  if ! lh_validate_storage_path "$APPLICATION_STORAGE_PATH"; then
    echo "APPLICATION_STORAGE_PATH must be an application path directly below /home/HOST" >&2
    return 1
  fi

  PERSISTENT_PATHS_FILE=$(readlink -f "$PERSISTENT_PATHS_FILE")
  if [[ $PERSISTENT_PATHS_FILE != "$lh_application_config_directory"/*.paths ]]; then
    echo "PERSISTENT_PATHS_FILE must be under $lh_application_config_directory" >&2
    return 1
  fi
  lh_require_root_secret_file "$PERSISTENT_PATHS_FILE" "Persistent path allowlist"

  declare -g -a LH_PERSISTENT_PATHS=()
  declare -g -a LH_PERSISTENT_TYPES=()
  declare -A seen=()
  local line type path
  while IFS= read -r line || [[ -n $line ]]; do
    [[ -z $line || $line == \#* ]] && continue
    if [[ $line != *:* ]]; then
      echo "Invalid persistent path entry: $line" >&2
      return 1
    fi
    type=${line%%:*}
    path=${line#*:}
    if [[ $type != file && $type != directory ]]; then
      echo "Persistent path type must be file or directory" >&2
      return 1
    fi
    if ! lh_validate_relative_path "$path"; then
      echo "Unsafe or excluded persistent path: $path" >&2
      return 1
    fi
    if [[ -n ${seen[$path]:-} ]]; then
      echo "Duplicate persistent path: $path" >&2
      return 1
    fi
    local existing
    for existing in "${LH_PERSISTENT_PATHS[@]}"; do
      if [[ $path == "$existing"/* || $existing == "$path"/* ]]; then
        echo "Persistent paths must not overlap: $existing and $path" >&2
        return 1
      fi
    done
    seen[$path]=1
    LH_PERSISTENT_TYPES+=("$type")
    LH_PERSISTENT_PATHS+=("$path")
  done < "$PERSISTENT_PATHS_FILE"
  if (( ${#LH_PERSISTENT_PATHS[@]} == 0 )); then
    echo "Persistent path allowlist is empty" >&2
    return 1
  fi

  LH_PERSISTENT_ROOT="$(dirname "$APPLICATION_STORAGE_PATH")/.lh-persistent-$(basename "$APPLICATION_STORAGE_PATH")"
  lh_assert_no_symlink_ancestors /home "${LH_PERSISTENT_ROOT#/home/}"

  if [[ $require_restore_identity == true ]]; then
    BACKUP_AGE_IDENTITY=$(readlink -f "$BACKUP_AGE_IDENTITY")
    if [[ $BACKUP_AGE_IDENTITY != /etc/legacy-hosting/restore/* ]]; then
      echo "BACKUP_AGE_IDENTITY must be under /etc/legacy-hosting/restore" >&2
      return 1
    fi
    lh_require_root_secret_file "$BACKUP_AGE_IDENTITY" "age restore identity"
    local process
    for process in $APPLICATION_PM2_PROCESSES; do
      if [[ ! $process =~ ^[A-Za-z0-9_.-]{2,120}$ ]]; then
        echo "Unsafe PM2 process name: $process" >&2
        return 1
      fi
    done
  else
    if [[ ! $BACKUP_AGE_RECIPIENT =~ ^age1[ac-hj-np-z02-9]{20,}$ ]]; then
      echo "BACKUP_AGE_RECIPIENT must be an age public recipient" >&2
      return 1
    fi
    if [[ ! $BACKUP_S3_ENDPOINT =~ ^[a-z0-9][a-z0-9.-]+$ || \
          ! $BACKUP_S3_BUCKET =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ || \
          ! $BACKUP_S3_PREFIX =~ ^[a-z0-9][a-z0-9/_-]{0,127}$ || \
          $BACKUP_S3_PREFIX == *..* ]]; then
      echo "Unsafe S3 endpoint, bucket, or prefix" >&2
      return 1
    fi
    if (( ${#BACKUP_S3_ACCESS_KEY_ID} < 16 || ${#BACKUP_S3_SECRET_ACCESS_KEY} < 32 )); then
      echo "S3 backup credentials do not meet the minimum length" >&2
      return 1
    fi
  fi
}

lh_assert_regular_tree() {
  local root=$1
  [[ -e $root ]] || return 0
  if [[ -L $root ]] || [[ -n $(find -P "$root" -type l -print -quit) ]]; then
    echo "Backup data contains a symbolic link: $root" >&2
    return 1
  fi
  if [[ -n $(find -P "$root" ! -type f ! -type d -print -quit) ]]; then
    echo "Backup data contains a socket, device, or other special file: $root" >&2
    return 1
  fi
}

lh_configured_paths_json() {
  printf '%s\n' "${LH_PERSISTENT_PATHS[@]}" | jq -R . | jq -s .
}

lh_append_application_audit() {
  local action=$1
  local result=$2
  local details=${3-}
  if [[ -z $details ]]; then details='{}'; fi
  local audit_directory
  audit_directory=$(dirname "$lh_application_audit_log")
  install -d -m 0750 "$audit_directory"
  touch "$lh_application_audit_log"
  chown root:root "$lh_application_audit_log"
  chmod 0600 "$lh_application_audit_log"
  exec 8>>"$lh_application_audit_log"
  flock 8
  jq -cn \
    --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg applicationId "$APPLICATION_ID" \
    --arg application "$APPLICATION_NAME" \
    --arg action "$action" \
    --arg result "$result" \
    --arg operator "${LH_RESTORE_OPERATOR:-${LH_BACKUP_OPERATOR:-systemd}}" \
    --argjson details "$details" \
    '{timestamp:$timestamp,applicationId:$applicationId,application:$application,action:$action,result:$result,operator:$operator,details:$details}' >&8
  flock -u 8
  exec 8>&-
}

lh_configure_rclone() {
  export RCLONE_CONFIG=/dev/null
  export RCLONE_CONFIG_LHBACKUP_TYPE=s3
  export RCLONE_CONFIG_LHBACKUP_PROVIDER=DigitalOcean
  export RCLONE_CONFIG_LHBACKUP_ENV_AUTH=false
  export RCLONE_CONFIG_LHBACKUP_ACCESS_KEY_ID=$BACKUP_S3_ACCESS_KEY_ID
  export RCLONE_CONFIG_LHBACKUP_SECRET_ACCESS_KEY=$BACKUP_S3_SECRET_ACCESS_KEY
  export RCLONE_CONFIG_LHBACKUP_ENDPOINT=$BACKUP_S3_ENDPOINT
  export RCLONE_CONFIG_LHBACKUP_ACL=private
}
