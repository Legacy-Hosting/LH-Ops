#!/usr/bin/env bash
set -Eeuo pipefail

export LC_ALL=C

info() {
  echo "[+] $*"
}

warning() {
  echo "[!] $*" >&2
}

die() {
  echo "[-] $*" >&2
  exit 1
}

trap 'echo "[-] Oppsettet stoppet på linje ${LINENO}." >&2' ERR

if [[ ${EUID} -ne 0 ]]; then
  die "Vennligst kjør dette skriptet med sudo eller som root."
fi
if [[ ! -r /etc/os-release ]]; then
  die "Kan ikke identifisere operativsystemet."
fi
. /etc/os-release
if [[ ${ID:-} != ubuntu || ${VERSION_ID:-} != 26.04 ]]; then
  die "Ubuntu 26.04 LTS er påkrevd. Fant ${PRETTY_NAME:-ukjent operativsystem}."
fi
repository_root=$(cd "$(dirname "$0")/.." && pwd)
if [[ ! -f $repository_root/logrotate/legacy-hosting ]]; then
  die "Mangler Legacy Hosting sin logrotate-policy."
fi
runtime_installer="$repository_root/scripts/install-node-runtime.sh"
if [[ ! -x $runtime_installer ]]; then
  die "Mangler kjørbar runtime-installer: $runtime_installer"
fi

normalize_boolean() {
  case ${1,,} in
    1|true|yes|on) echo true ;;
    0|false|no|off) echo false ;;
    *) die "Ugyldig boolsk verdi: $1" ;;
  esac
}

allow_web=$(normalize_boolean "${LH_UFW_ALLOW_WEB:-true}")
block_known_bad_ips=$(normalize_boolean "${LH_BLOCK_KNOWN_BAD_IPS:-true}")
extra_tcp_ports=${LH_UFW_EXTRA_TCP_PORTS:-}

valid_port() {
  local port=$1
  [[ $port =~ ^[0-9]+$ ]] && ((10#$port >= 1 && 10#$port <= 65535))
}

append_unique_port() {
  local port=$1
  local existing
  for existing in "${firewall_ports[@]}"; do
    if [[ $existing == "$port" ]]; then
      return
    fi
  done
  firewall_ports+=("$port")
}

append_unique_ssh_port() {
  local port=$1
  local existing
  for existing in "${ssh_ports[@]}"; do
    if [[ $existing == "$port" ]]; then
      return
    fi
  done
  ssh_ports+=("$port")
}

info "Finner SSH-portene som må være åpne før UFW aktiveres..."
declare -a ssh_ports=()
sshd_binary=$(command -v sshd || true)
if [[ -z $sshd_binary && -x /usr/sbin/sshd ]]; then
  sshd_binary=/usr/sbin/sshd
fi
if [[ -n $sshd_binary ]]; then
  sshd_effective_config=$("$sshd_binary" -T 2>/dev/null || true)
  while IFS= read -r candidate; do
    if valid_port "$candidate"; then
      append_unique_ssh_port "$candidate"
    fi
  done < <(awk '$1 == "port" { print $2 }' <<< "$sshd_effective_config")
fi

# SSH_CONNECTION ender med serverporten til den aktive SSH-tilkoblingen.
# Denne tas med som en ekstra sikkerhet hvis sshd -T ikke kunne leses.
if [[ -n ${SSH_CONNECTION:-} ]]; then
  connected_ssh_port=${SSH_CONNECTION##* }
  if valid_port "$connected_ssh_port"; then
    append_unique_ssh_port "$connected_ssh_port"
  fi
fi
if ((${#ssh_ports[@]} == 0)); then
  warning "Fant ingen SSH-port automatisk. Bruker standardport 22."
  append_unique_ssh_port 22
fi
ssh_port_list=$(IFS=,; echo "${ssh_ports[*]}")
info "SSH beholdes åpen på TCP-port(er): $ssh_port_list"

info "Oppdaterer pakkelister og installerer serveravhengigheter..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
  age \
  ca-certificates \
  curl \
  fail2ban \
  git \
  git-lfs \
  gnupg \
  jq \
  logrotate \
  mysql-client \
  nginx \
  openssl \
  rclone \
  snapd \
  unattended-upgrades \
  ufw \
  xz-utils

info "Fjerner eventuelle eldre Certbot-pakker fra APT..."
declare -a apt_certbot_packages=()
for package in certbot python3-certbot-dns-cloudflare python3-certbot-nginx; do
  if dpkg-query -W -f='${Status}' "$package" 2>/dev/null | \
     grep -q '^install ok installed$'; then
    apt_certbot_packages+=("$package")
  fi
done
if ((${#apt_certbot_packages[@]} > 0)); then
  apt-get remove -y "${apt_certbot_packages[@]}"
else
  info "Ingen eldre Certbot-pakker fra APT ble funnet."
fi

info "Installerer og oppdaterer Certbot med Cloudflare-plugin via Snap..."
systemctl enable --now snapd.socket
snap wait system seed.loaded
if snap list core >/dev/null 2>&1; then
  snap refresh core
else
  snap install core
fi
if snap list certbot >/dev/null 2>&1; then
  snap refresh certbot
else
  snap install --classic certbot
fi
ln -sfn /snap/bin/certbot /usr/local/bin/certbot
snap set certbot trust-plugin-with-root=ok
if snap list certbot-dns-cloudflare >/dev/null 2>&1; then
  snap refresh certbot-dns-cloudflare
else
  snap install certbot-dns-cloudflare
fi
systemctl is-active --quiet snap.certbot.renew.timer || \
  die "Certbot sin automatiske Snap-renewal-timer er ikke aktiv."

info "Oppretter beskyttede mapper og installerer logrotate-policy..."
install -d -m 0700 /etc/legacy-hosting /etc/legacy-hosting/backups
install -d -o root -g root -m 0700 /root/.secrets /root/.secrets/certbot
install -d -m 0755 /etc/legacy-hosting/release-keys
install -d -m 0700 /etc/legacy-hosting/application-backups \
  /var/backups/legacy-hosting/mysql /var/backups/legacy-hosting/applications \
  /var/lib/legacy-hosting/application-restores
install -d -m 0755 /opt/legacy-hosting /var/www
install -m 0644 "$repository_root/logrotate/legacy-hosting" \
  /etc/logrotate.d/legacy-hosting

cloudflare_credentials=/root/.secrets/certbot/cloudflare.ini
if [[ -e $cloudflare_credentials || -L $cloudflare_credentials ]]; then
  if [[ ! -f $cloudflare_credentials || -L $cloudflare_credentials ]]; then
    die "$cloudflare_credentials må være en vanlig fil, ikke en symbolsk lenke."
  fi
  chown root:root "$cloudflare_credentials"
  chmod 0600 "$cloudflare_credentials"
  info "Bevarte Cloudflare-legitimasjonen og reparerte rettighetene til 0600."
else
  warning "$cloudflare_credentials finnes ikke ennå; ingen hemmelighet ble opprettet."
fi

info "Aktiverer Nginx og automatiske sikkerhetsoppdateringer..."
systemctl enable --now nginx
systemctl enable unattended-upgrades

info "Kontrollerer persistent swap..."
"$repository_root/scripts/ensure-swap.sh"

info "Installerer verifisert Node.js-runtime, npm, pnpm og PM2..."
"$runtime_installer"

declare -a firewall_ports=()
for port in "${ssh_ports[@]}"; do
  append_unique_port "$port"
done
if [[ $allow_web == true ]]; then
  append_unique_port 80
  append_unique_port 443
  info "HTTP (80/tcp) og HTTPS (443/tcp) blir tillatt for tjenestehosten."
else
  info "HTTP og HTTPS åpnes ikke fordi LH_UFW_ALLOW_WEB=false."
fi
if [[ -n $extra_tcp_ports ]]; then
  IFS=',' read -r -a requested_extra_ports <<< "$extra_tcp_ports"
  for port in "${requested_extra_ports[@]}"; do
    port=${port//[[:space:]]/}
    valid_port "$port" || die "Ugyldig port i LH_UFW_EXTRA_TCP_PORTS: $port"
    append_unique_port "$port"
  done
  info "Ekstra TCP-porter er lagt til fra LH_UFW_EXTRA_TCP_PORTS."
fi

info "Konfigurerer UFW uten å nullstille eksisterende regler..."
ufw default deny incoming
ufw default allow outgoing
for port in "${firewall_ports[@]}"; do
  ufw allow "${port}/tcp" comment "Legacy Hosting TCP ${port}"
done

known_bad_ips=(
  "95.85.245.227"
  "45.148.10.141"
  "193.47.62.69"
  "37.120.162.199"
)
if [[ $block_known_bad_ips == true ]]; then
  info "Kontrollerer den statiske denylisten..."
  for ip in "${known_bad_ips[@]}"; do
    legacy_rule_number=$(ufw status numbered | awk -v ip="$ip" '
      index($0, ip) && /# Legacy Hosting denylist/ {
        value=$0
        sub(/^\[[[:space:]]*/, "", value)
        sub(/\].*$/, "", value)
        gsub(/[[:space:]]/, "", value)
        print value
        exit
      }')
    if [[ -n $legacy_rule_number ]]; then
      ufw --force delete "$legacy_rule_number"
      echo "    -> $ip sin eldre lokale regel ble migrert."
    fi
    if ufw status | awk -v ip="$ip" '
      index($0, ip) && /DENY IN/ && /# Legacy Hosting global ban/ { found=1 }
      END { exit !found }
    '; then
      echo "    -> $ip er allerede blokkert."
    else
      ufw insert 1 deny from "$ip" to any comment "Legacy Hosting global ban"
      echo "    -> $ip er blokkert permanent i UFW."
    fi
  done
else
  info "Den statiske denylisten hoppes over fordi LH_BLOCK_KNOWN_BAD_IPS=false."
fi

info "Aktiverer UFW etter at SSH-reglene er på plass..."
ufw --force enable
ufw reload

info "Konfigurerer Fail2Ban for SSH med UFW som blokkeringsmekanisme..."
jail_directory=/etc/fail2ban/jail.d
jail_file="$jail_directory/legacy-hosting-sshd.local"
install -d -m 0755 "$jail_directory"
jail_temporary=$(mktemp "$jail_directory/.legacy-hosting-sshd.XXXXXX")
trap 'rm -f -- "${jail_temporary:-}"' EXIT
cat > "$jail_temporary" <<EOF
# Managed by LH-Ops/scripts/bootstrap-ubuntu.sh.
# Local changes will be replaced the next time the script runs.
[DEFAULT]
banaction = ufw
banaction_allports = ufw

[sshd]
enabled = true
backend = systemd
port = $ssh_port_list
maxretry = 3
findtime = 10m
bantime = 24h
EOF
chmod 0644 "$jail_temporary"
chown root:root "$jail_temporary"
mv -f -- "$jail_temporary" "$jail_file"
trap - EXIT

info "Validerer Fail2Ban-konfigurasjonen..."
fail2ban-client -t
systemctl enable fail2ban
systemctl restart fail2ban
systemctl is-active --quiet fail2ban || die "Fail2Ban startet ikke. Kontroller journalctl -u fail2ban."
fail2ban-client status sshd >/dev/null || die "Fail2Ban-jailen sshd er ikke aktiv."

echo "=========================================================="
echo "[Vellykket] Den nye serveren er ferdig klargjort."
echo " - Node.js: $(node --version)"
echo " - npm:     $(npm --version)"
echo " - pnpm:    $(pnpm --version)"
echo " - PM2:     $(pm2 --version)"
echo " - Nginx, Certbot, swap og automatiske oppdateringer er aktivert."
echo " - Certbot og Cloudflare DNS-plugin kjører via Snap med automatisk renewal."
echo " - Fail2Ban beskytter SSH på port(er): $ssh_port_list"
echo " - Fail2Ban blokkerer i 24 timer etter 3 feil på 10 minutter."
echo " - UFW er aktiv med standardregelen: nekt innkommende, tillat utgående."
if [[ $allow_web == true ]]; then
  echo " - HTTP og HTTPS er åpne på port 80 og 443."
fi
if [[ $block_known_bad_ips == true ]]; then
  echo " - De 4 oppgitte IP-adressene er permanent blokkert."
fi
echo "=========================================================="
ufw status verbose
fail2ban-client status sshd
