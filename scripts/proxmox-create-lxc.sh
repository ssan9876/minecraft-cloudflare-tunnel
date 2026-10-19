#!/usr/bin/env bash
# Creates an unprivileged Debian LXC on a Proxmox VE host, installs Docker, and starts this stack in it.
# Run as root on the Proxmox host, from a checkout of this repo with .env filled in:
#
#   CTID=120 IP=192.168.1.50/24 GATEWAY=192.168.1.1 ./scripts/proxmox-create-lxc.sh
#
# Optional: CT_NAME (minecraft), BRIDGE (vmbr0), STORAGE (local-lvm), DISK_GB (32), CORES (4),
#           MEMORY_MB (6144), SWAP_MB (1024), TEMPLATE (e.g. local:vztmpl/debian-13-standard_..._amd64.tar.zst)
set -euo pipefail

: "${CTID:?Set CTID, the new container ID (e.g. CTID=120)}"
: "${IP:?Set IP in CIDR form (e.g. IP=192.168.1.50/24)}"
: "${GATEWAY:?Set GATEWAY (e.g. GATEWAY=192.168.1.1)}"
CT_NAME="${CT_NAME:-minecraft}"
BRIDGE="${BRIDGE:-vmbr0}"
STORAGE="${STORAGE:-local-lvm}"
DISK_GB="${DISK_GB:-32}"
CORES="${CORES:-4}"
MEMORY_MB="${MEMORY_MB:-6144}"
SWAP_MB="${SWAP_MB:-1024}"
TEMPLATE="${TEMPLATE:-}"

REPO="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$REPO/.env" ] || { echo "Create $REPO/.env from .env.example first."; exit 1; }

if pct status "$CTID" >/dev/null 2>&1; then
  echo "CT $CTID already exists. Pick another CTID."; exit 1
fi

if [ -z "$TEMPLATE" ]; then
  pveam update >/dev/null
  name=$(pveam available --section system | awk '{print $2}' | grep '^debian-13-standard_.*_amd64' | sort -V | tail -1)
  [ -n "$name" ] || { echo "No Debian 13 template found. Set TEMPLATE."; exit 1; }
  pveam list local | grep -q "$name" || pveam download local "$name"
  TEMPLATE="local:vztmpl/$name"
fi

keys=()
[ -s /root/.ssh/authorized_keys ] && keys=(--ssh-public-keys /root/.ssh/authorized_keys)

echo "Creating CT $CTID ($CT_NAME) at $IP from $TEMPLATE"
pct create "$CTID" "$TEMPLATE" \
  --hostname "$CT_NAME" \
  --cores "$CORES" --memory "$MEMORY_MB" --swap "$SWAP_MB" \
  --rootfs "$STORAGE:$DISK_GB" \
  --net0 "name=eth0,bridge=$BRIDGE,ip=$IP,gw=$GATEWAY,type=veth" \
  --unprivileged 1 --features nesting=1,keyctl=1 \
  --onboot 1 \
  "${keys[@]}" \
  --description "Minecraft server (Paper via Docker), stack in /opt/minecraft"

pct start "$CTID"
for _ in $(seq 1 30); do
  pct exec "$CTID" -- ping -c1 -W1 deb.debian.org >/dev/null 2>&1 && break
  sleep 2
done

pct exec "$CTID" -- bash -c '
  set -e
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q
  apt-get -y -q full-upgrade
  apt-get -y -q install curl ca-certificates
  curl -fsSL https://get.docker.com | sh
  mkdir -p /opt/minecraft/backups
  chown 1000:1000 /opt/minecraft/backups
'

bundle=$(mktemp)
tar -C "$REPO" -cf "$bundle" docker-compose.yml config admin .env
pct push "$CTID" "$bundle" /tmp/stack.tar
rm -f "$bundle"
pct exec "$CTID" -- bash -c '
  set -e
  cd /opt/minecraft
  tar -xf /tmp/stack.tar --no-same-owner && rm /tmp/stack.tar
  chmod 600 .env
  docker compose up -d --build
'
echo "Done. Server: ${IP%/*}:25565  Admin panel: http://${IP%/*}:8080 (if ADMIN_BIND=0.0.0.0)"
