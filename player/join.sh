#!/usr/bin/env bash
# Opens a local port that forwards to the Minecraft server through Cloudflare (macOS/Linux).
# Settings come from server.conf next to this script (copy server.conf.example); arguments override it.
set -euo pipefail

CONF_HOST="mc.example.com"
CONF_PORT="25565"
CONF_FILE="$(cd "$(dirname "$0")" && pwd)/server.conf"
if [ -f "$CONF_FILE" ]; then
  while IFS='=' read -r key value || [ -n "$key" ]; do
    value="${value%$'\r'}"; value="${value#\"}"; value="${value%\"}"
    case "$key" in
      HOSTNAME) CONF_HOST="$value" ;;
      LOCAL_PORT) CONF_PORT="$value" ;;
    esac
  done < "$CONF_FILE"
fi

MC_HOST="${1:-$CONF_HOST}"
LOCAL_PORT="${2:-$CONF_PORT}"
if [ "$MC_HOST" = "mc.example.com" ]; then
  echo "No server address set. Copy server.conf.example to server.conf and set HOSTNAME."
  exit 1
fi

if ! command -v cloudflared >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    brew install cloudflared
  else
    echo "Install cloudflared first: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/"
    exit 1
  fi
fi

if [ "$(uname)" = "Darwin" ]; then
  open -a "Minecraft" 2>/dev/null || echo "Couldn't find the Minecraft Launcher. Open Minecraft yourself."
fi

echo
echo "Connected to $MC_HOST."
echo "In Minecraft: Multiplayer > Add Server > address: localhost:$LOCAL_PORT"
echo "Leave this running while you play. Ctrl+C to disconnect."
echo
exec cloudflared access tcp --hostname "$MC_HOST" --url "127.0.0.1:$LOCAL_PORT"
