#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Run as root" >&2
  exit 1
fi
if [[ ! -r /etc/os-release ]]; then
  echo "Cannot identify the operating system" >&2
  exit 1
fi
. /etc/os-release
if [[ ${ID:-} != ubuntu || ${VERSION_ID:-} != 26.04 ]]; then
  echo "Ubuntu 26.04 LTS is required" >&2
  exit 1
fi

node_version=${NODE_VERSION:-24.21.0}
pnpm_version=${PNPM_VERSION:-12.4.1}
pm2_version=${PM2_VERSION:-7.0.4}
if [[ ! $node_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || \
      ! $pnpm_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || \
      ! $pm2_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Node.js, pnpm, and PM2 versions must be exact semantic versions" >&2
  exit 1
fi

case $(uname -m) in
  x86_64) node_arch=x64 ;;
  aarch64|arm64) node_arch=arm64 ;;
  *)
    echo "Unsupported architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl xz-utils

runtime_root=/opt/legacy-hosting/runtime
node_directory="$runtime_root/node-v${node_version}-linux-${node_arch}"
archive_name="node-v${node_version}-linux-${node_arch}.tar.xz"
download_base="https://nodejs.org/dist/v${node_version}"
install -d -m 0755 "$runtime_root"

if [[ -e $node_directory && ! -x $node_directory/bin/node ]]; then
  echo "Incomplete Node.js runtime already exists: $node_directory" >&2
  exit 1
fi
if [[ ! -x $node_directory/bin/node ]]; then
  temporary_directory=$(mktemp -d)
  trap 'rm -rf -- "$temporary_directory"' EXIT
  curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    "$download_base/SHASUMS256.txt" -o "$temporary_directory/SHASUMS256.txt"
  curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    "$download_base/$archive_name" -o "$temporary_directory/$archive_name"
  (
    cd "$temporary_directory"
    grep "  $archive_name\$" SHASUMS256.txt | sha256sum --check --strict -
  )
  install -d -m 0755 "$node_directory"
  tar -xJf "$temporary_directory/$archive_name" \
    --strip-components=1 -C "$node_directory"
  "$node_directory/bin/node" --version | grep -qx "v$node_version"
  trap - EXIT
  rm -rf -- "$temporary_directory"
fi

for command in node npm npx corepack; do
  if [[ -x $node_directory/bin/$command ]]; then
    ln -sfn "$node_directory/bin/$command" "/usr/local/bin/$command"
  fi
done

"$node_directory/bin/npm" install --global --prefix "$node_directory" \
  "pnpm@$pnpm_version" "pm2@$pm2_version"
for command in pnpm pnpx pm2 pm2-dev pm2-docker pm2-runtime; do
  if [[ -x $node_directory/bin/$command ]]; then
    ln -sfn "$node_directory/bin/$command" "/usr/local/bin/$command"
  fi
done

node --version | grep -qx "v$node_version"
pnpm --version | grep -qx "$pnpm_version"
pm2 --version | grep -qx "$pm2_version"
pm2 startup systemd -u root --hp /root >/dev/null
systemctl enable pm2-root

echo "Node.js $node_version, pnpm $pnpm_version, and PM2 $pm2_version are ready."
