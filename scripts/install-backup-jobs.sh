#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Run as root" >&2
  exit 1
fi
repository_root=$(cd "$(dirname "$0")/.." && pwd)
for command in age flock gzip mysqldump rclone sha256sum; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Install the required backup command before continuing: $command" >&2
    exit 1
  fi
done
for path in \
  scripts/backup-mysql.sh \
  scripts/restore-drill.sh \
  systemd/lh-mysql-backup@.service \
  systemd/lh-mysql-backup@.timer; do
  if [[ ! -f "$repository_root/$path" ]]; then
    echo "Missing repository file: $path" >&2
    exit 1
  fi
done

install -d -m 0755 /usr/local/lib/legacy-hosting-ops
install -d -m 0700 /etc/legacy-hosting/backups /etc/legacy-hosting/restore \
  /var/backups/legacy-hosting/mysql
install -d -m 0750 /var/log/legacy-hosting
install -m 0755 "$repository_root/scripts/backup-mysql.sh" \
  /usr/local/lib/legacy-hosting-ops/backup-mysql.sh
install -m 0755 "$repository_root/scripts/restore-drill.sh" \
  /usr/local/lib/legacy-hosting-ops/restore-drill.sh
install -m 0644 "$repository_root/systemd/lh-mysql-backup@.service" \
  /etc/systemd/system/lh-mysql-backup@.service
install -m 0644 "$repository_root/systemd/lh-mysql-backup@.timer" \
  /etc/systemd/system/lh-mysql-backup@.timer
systemctl daemon-reload

echo "Backup tooling installed. Add protected instance environment files before enabling timers."
