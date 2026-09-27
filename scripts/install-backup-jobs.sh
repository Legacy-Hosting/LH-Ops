#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Run as root" >&2
  exit 1
fi
repository_root=$(cd "$(dirname "$0")/.." && pwd)
for command in age flock gzip jq mysqldump rclone sha256sum tar; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Install the required backup command before continuing: $command" >&2
    exit 1
  fi
done
for path in \
  scripts/backup-mysql.sh \
  scripts/application-backup-common.sh \
  scripts/backup-application-files.sh \
  scripts/stage-application-restore.sh \
  scripts/apply-application-restore.sh \
  scripts/restore-drill.sh \
  systemd/lh-application-backup@.service \
  systemd/lh-application-backup@.timer \
  systemd/lh-mysql-backup@.service \
  systemd/lh-mysql-backup@.timer; do
  if [[ ! -f "$repository_root/$path" ]]; then
    echo "Missing repository file: $path" >&2
    exit 1
  fi
done

install -d -m 0755 /usr/local/lib/legacy-hosting-ops
install -d -m 0700 /etc/legacy-hosting/backups \
  /etc/legacy-hosting/application-backups /etc/legacy-hosting/restore \
  /var/backups/legacy-hosting/mysql /var/backups/legacy-hosting/applications \
  /var/lib/legacy-hosting/application-restores
install -d -m 0750 /var/log/legacy-hosting
install -m 0755 "$repository_root/scripts/backup-mysql.sh" \
  /usr/local/lib/legacy-hosting-ops/backup-mysql.sh
install -m 0755 "$repository_root/scripts/restore-drill.sh" \
  /usr/local/lib/legacy-hosting-ops/restore-drill.sh
for script in application-backup-common.sh backup-application-files.sh \
  stage-application-restore.sh apply-application-restore.sh; do
  install -m 0755 "$repository_root/scripts/$script" \
    "/usr/local/lib/legacy-hosting-ops/$script"
done
install -m 0644 "$repository_root/systemd/lh-application-backup@.service" \
  /etc/systemd/system/lh-application-backup@.service
install -m 0644 "$repository_root/systemd/lh-application-backup@.timer" \
  /etc/systemd/system/lh-application-backup@.timer
install -m 0644 "$repository_root/systemd/lh-mysql-backup@.service" \
  /etc/systemd/system/lh-mysql-backup@.service
install -m 0644 "$repository_root/systemd/lh-mysql-backup@.timer" \
  /etc/systemd/system/lh-mysql-backup@.timer
systemctl daemon-reload

echo "Backup tooling installed. Add protected instance environment files before enabling timers."
