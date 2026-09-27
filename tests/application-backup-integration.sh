#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Application backup integration test must run as root inside an isolated CI runner" >&2
  exit 1
fi
repository_root=$(cd "$(dirname "$0")/.." && pwd)
temporary_directory=$(mktemp -d)
fake_bin=$temporary_directory/bin
remote_root=$temporary_directory/remote
pm2_log=$temporary_directory/pm2.log
application_id=11111111-1111-4111-8111-111111111111
application_name=ci-application
storage_path=/home/ci.legacyh.test/app.legacyh.test
persistent_root=/home/ci.legacyh.test/.lh-persistent-app.legacyh.test
config_directory=/etc/legacy-hosting/application-backups
backup_directory=/var/backups/legacy-hosting/applications/$application_id
restore_directory=/var/lib/legacy-hosting/application-restores/$application_id
audit_log=/var/log/legacy-hosting/application-backups.jsonl
audit_backup=$temporary_directory/application-backups.original.jsonl
audit_existed=false
install -d -m 0755 "$fake_bin"
if [[ -f $audit_log ]]; then
  cp -- "$audit_log" "$audit_backup"
  audit_existed=true
fi

cleanup() {
  if [[ $audit_existed == true ]]; then
    cp -- "$audit_backup" "$audit_log"
  else
    rm -f -- "$audit_log"
  fi
  rm -f -- "$config_directory/ci-application.env" \
    "$config_directory/ci-application-restore.env" \
    "$config_directory/ci-application.paths" \
    /etc/legacy-hosting/restore/ci-application-age-key.txt \
    "/run/lock/lh-application-backup-$application_id.lock"
  rm -rf -- "$backup_directory" "$restore_directory" \
    /home/ci.legacyh.test "$temporary_directory"
  rmdir --ignore-fail-on-non-empty /var/log/legacy-hosting \
    /var/backups/legacy-hosting/applications /var/backups/legacy-hosting \
    /var/lib/legacy-hosting/application-restores /var/lib/legacy-hosting \
    /etc/legacy-hosting/application-backups /etc/legacy-hosting/restore \
    /etc/legacy-hosting 2>/dev/null || true
}
trap cleanup EXIT

cat > "$fake_bin/age" <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
output=
input=
while (( $# > 0 )); do
  case $1 in
    --recipient|--identity) shift 2 ;;
    --decrypt) shift ;;
    --output) output=$2; shift 2 ;;
    *) input=$1; shift ;;
  esac
done
cp -- "$input" "$output"
SCRIPT
cat > "$fake_bin/rclone" <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
command=$1
shift
remote_path() {
  printf '%s/%s' "$LH_TEST_REMOTE_ROOT" "${1#lhbackup:}"
}
case $command in
  copyto)
    if [[ ${1:-} == --no-traverse ]]; then shift; fi
    source=$1
    destination=$(remote_path "$2")
    mkdir -p "$(dirname "$destination")"
    cp -- "$source" "$destination"
    ;;
  cat) cat -- "$(remote_path "$1")" ;;
  lsf)
    directory=$(remote_path "$1")
    [[ -d $directory ]] && find "$directory" -maxdepth 1 -type f -printf '%f\n'
    ;;
  delete) ;;
  *) echo "Unexpected fake rclone command: $command" >&2; exit 1 ;;
esac
SCRIPT
cat > "$fake_bin/pm2" <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >> "$LH_TEST_PM2_LOG"
SCRIPT
chmod 0755 "$fake_bin"/*

install -d -m 0700 "$config_directory" /etc/legacy-hosting/restore \
  "$persistent_root/var/secrets" "$persistent_root/var/uploads"
printf '%s\n' 'original-secret' > "$persistent_root/var/secrets/settings.key"
printf '%s\n' 'original-upload' > "$persistent_root/var/uploads/customer.txt"
cat > "$config_directory/ci-application.paths" <<'PATHS'
file:var/secrets/settings.key
directory:var/uploads
PATHS
cat > "$config_directory/ci-application.env" <<'ENV'
APPLICATION_ID=11111111-1111-4111-8111-111111111111
APPLICATION_NAME=ci-application
APPLICATION_STORAGE_PATH=/home/ci.legacyh.test/app.legacyh.test
PERSISTENT_PATHS_FILE=/etc/legacy-hosting/application-backups/ci-application.paths
BACKUP_AGE_RECIPIENT=age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
BACKUP_LOCAL_RETENTION_DAYS=2
BACKUP_S3_ENDPOINT=fra1.digitaloceanspaces.com
BACKUP_S3_BUCKET=legacy-hosting-ci-application-backups
BACKUP_S3_PREFIX=applications
BACKUP_S3_ACCESS_KEY_ID=CIACCESSKEY000000
BACKUP_S3_SECRET_ACCESS_KEY=ci-secret-key-with-more-than-32-characters
ENV
chmod 0600 "$config_directory/ci-application.paths" \
  "$config_directory/ci-application.env"

ln -s "$temporary_directory" "$persistent_root/var/uploads/escape"
export LH_TEST_REMOTE_ROOT=$remote_root
export LH_TEST_PM2_LOG=$pm2_log
if PATH="$fake_bin:$PATH" bash "$repository_root/scripts/backup-application-files.sh" \
  "$config_directory/ci-application.env" >/dev/null 2>&1; then
  echo "Application backup followed or accepted a symbolic link" >&2
  exit 1
fi
rm -- "$persistent_root/var/uploads/escape"

PATH="$fake_bin:$PATH" bash "$repository_root/scripts/backup-application-files.sh" \
  "$config_directory/ci-application.env"
backup=$(find "$backup_directory" -maxdepth 1 -type f \
  -name 'ci-application-*.tar.gz.age' -print -quit)
[[ -n $backup && -f $backup.sha256 ]]
[[ $(stat -c '%a' "$backup") == 600 ]]
remote_backup=$(find "$remote_root" -type f \
  -path '*/daily/ci-application-*.tar.gz.age' -print -quit)
[[ -n $remote_backup ]]
cmp -s "$backup" "$remote_backup"

printf '%s\n' 'modified-live-secret' > "$persistent_root/var/secrets/settings.key"
install -m 0600 /dev/null /etc/legacy-hosting/restore/ci-application-age-key.txt
cat > "$config_directory/ci-application-restore.env" <<'ENV'
APPLICATION_ID=11111111-1111-4111-8111-111111111111
APPLICATION_NAME=ci-application
APPLICATION_STORAGE_PATH=/home/ci.legacyh.test/app.legacyh.test
PERSISTENT_PATHS_FILE=/etc/legacy-hosting/application-backups/ci-application.paths
APPLICATION_PM2_PROCESSES="ci-application-web ci-application-worker"
BACKUP_AGE_IDENTITY=/etc/legacy-hosting/restore/ci-application-age-key.txt
ENV
chmod 0600 "$config_directory/ci-application-restore.env"

PATH="$fake_bin:$PATH" LH_RESTORE_OPERATOR=ci@example.com \
  bash "$repository_root/scripts/stage-application-restore.sh" \
  "$config_directory/ci-application-restore.env" "$backup"
grep -qx 'modified-live-secret' "$persistent_root/var/secrets/settings.key"
staged=$(find "$restore_directory" -mindepth 1 -maxdepth 1 -type d \
  ! -name '.staging.*' -print -quit)
[[ -n $staged && -f $staged/manifest.json ]]
if PATH="$fake_bin:$PATH" LH_RESTORE_OPERATOR=ci@example.com \
  bash "$repository_root/scripts/apply-application-restore.sh" \
  "$config_directory/ci-application-restore.env" "$staged" >/dev/null 2>&1; then
  echo "Application restore did not require explicit application confirmation" >&2
  exit 1
fi
grep -qx 'modified-live-secret' "$persistent_root/var/secrets/settings.key"
[[ -d $staged ]]

PATH="$fake_bin:$PATH" LH_RESTORE_OPERATOR=ci@example.com \
  LH_RESTORE_CONFIRM=$application_id \
  bash "$repository_root/scripts/apply-application-restore.sh" \
  "$config_directory/ci-application-restore.env" "$staged"
grep -qx 'original-secret' "$persistent_root/var/secrets/settings.key"
grep -qx 'original-upload' "$persistent_root/var/uploads/customer.txt"
grep -q '^stop ci-application-web ci-application-worker$' "$pm2_log"
grep -q '^restart ci-application-web ci-application-worker$' "$pm2_log"
jq -s -e 'any(.[]; .action == "backup.create" and .result == "succeeded")' \
  "$audit_log" >/dev/null
jq -s -e 'any(.[]; .action == "restore.stage" and .result == "succeeded")' \
  "$audit_log" >/dev/null
jq -s -e 'any(.[]; .action == "restore.apply" and .result == "succeeded")' \
  "$audit_log" >/dev/null

echo "Persistent-file backup, symlink rejection, staging, and restore passed."
