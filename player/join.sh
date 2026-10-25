#!/usr/bin/env bash
# Opens a local port that forwards to the Minecraft server through Cloudflare (macOS/Linux).
# For a Fabric server it also installs Fabric and the server's mods (MODS in server.conf).
# Settings come from server.conf next to this script (copy server.conf.example); arguments override it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF_HOST="mc.example.com"
CONF_PORT="25565"
SERVER_NAME="Minecraft Server"
MODS=""
CONF_FILE="$SCRIPT_DIR/server.conf"
if [ -f "$CONF_FILE" ]; then
  while IFS='=' read -r key value || [ -n "$key" ]; do
    value="${value%$'\r'}"; value="${value#\"}"; value="${value%\"}"
    case "$key" in
      HOSTNAME) CONF_HOST="$value" ;;
      LOCAL_PORT) CONF_PORT="$value" ;;
      SERVER_NAME) SERVER_NAME="$value" ;;
      MODS) MODS="$value" ;;
    esac
  done < "$CONF_FILE"
fi

MC_HOST="${1:-$CONF_HOST}"
LOCAL_PORT="${2:-$CONF_PORT}"
if [ "$MC_HOST" = "mc.example.com" ]; then
  echo "No server address set. Copy server.conf.example to server.conf and set HOSTNAME."
  exit 1
fi

if [ "$(uname)" = "Darwin" ]; then
  MC_DIR="$HOME/Library/Application Support/minecraft"
else
  MC_DIR="$HOME/.minecraft"
fi

# Installs Fabric and the mods from the list (see mods.txt.example) into their own game folder, with a
# launcher installation named after the server, so the player's own mods are left alone.
install_mods() {
  local source="$1" list base=""
  if [[ "$source" == https://* ]]; then
    list="$(curl -fsSL "$source")"
  else
    [[ "$source" == /* ]] || source="$SCRIPT_DIR/$source"
    list="$(cat "$source")"
    base="$(dirname "$source")"
  fi

  local mc_version="" loader="" mods=() key value
  while read -r key value; do
    case "$key" in
      minecraft) mc_version="$value" ;;
      fabric-loader) loader="$value" ;;
      mod)
        if [[ "$value" == https://* ]]; then mods+=("$value")
        elif [ -n "$base" ]; then mods+=("$base/$value")
        else echo "mod '$value' in $source must be an https:// link"; return 1
        fi ;;
    esac
  done < <(printf '%s\n' "$list" | tr -d '\r' | grep -v '^[[:space:]]*#' || true)
  if [ -z "$mc_version" ] || [ -z "$loader" ]; then
    echo "$source needs 'minecraft' and 'fabric-loader' lines"; return 1
  fi
  [ -d "$MC_DIR" ] || { echo "Open the Minecraft Launcher once first, then run join again."; return 1; }

  # Fabric's launcher version, as the Fabric installer would set it up
  local version_id="fabric-loader-$loader-$mc_version"
  local version_json="$MC_DIR/versions/$version_id/$version_id.json"
  if [ ! -f "$version_json" ]; then
    echo "Installing Fabric $loader for Minecraft $mc_version..."
    mkdir -p "$(dirname "$version_json")"
    curl -fsSL -o "$version_json.part" "https://meta.fabricmc.net/v2/versions/loader/$mc_version/$loader/profile/json"
    mv -f "$version_json.part" "$version_json"
  fi

  local slug
  slug="$(printf '%s' "$SERVER_NAME" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
  [ -n "$slug" ] || slug=server
  local game_dir="$MC_DIR/profiles/$slug"
  local mods_dir="$game_dir/mods" managed="$game_dir/mods/.server-mods.txt"
  mkdir -p "$mods_dir"

  # Jars from an earlier list that aren't on this one are removed. Ones the player added are left alone.
  local wanted=() mod name old
  for mod in ${mods[@]+"${mods[@]}"}; do
    name="${mod##*/}"
    [[ "$mod" == https://* ]] && name="$(printf '%b' "${name//%/\\x}")"
    [[ "$name" =~ ^[^/]+\.jar$ ]] || { echo "not a .jar: $mod"; return 1; }
    wanted+=("$name")
    [ -f "$mods_dir/$name" ] && continue
    echo "Downloading $name..."
    if [[ "$mod" == https://* ]]; then curl -fsSL -o "$mods_dir/$name.part" "$mod"; else cp "$mod" "$mods_dir/$name.part"; fi
    mv -f "$mods_dir/$name.part" "$mods_dir/$name"
  done
  if [ -f "$managed" ]; then
    while read -r old; do
      [[ "$old" =~ ^[^/]+\.jar$ ]] || continue
      [[ " ${wanted[*]-} " == *" $old "* ]] || rm -f "$mods_dir/$old"
    done < "$managed"
  fi
  printf '%s\n' ${wanted[@]+"${wanted[@]}"} > "$managed"

  # Start from the player's usual settings (controls, video) the first time
  if [ ! -f "$game_dir/options.txt" ] && [ -f "$MC_DIR/options.txt" ]; then cp "$MC_DIR/options.txt" "$game_dir/options.txt"; fi

  # The launcher installation, marked as just used so the launcher selects it
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$MC_DIR" "$slug" "$SERVER_NAME" "$version_id" "$game_dir" <<'PY'
import datetime, json, os, sys
mc_dir, slug, name, version_id, game_dir = sys.argv[1:]
files = [os.path.join(mc_dir, f) for f in ("launcher_profiles.json", "launcher_profiles_microsoft_store.json")]
files = [f for f in files if os.path.exists(f)] or files[:1]
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
for path in files:
    data = json.load(open(path, encoding="utf-8")) if os.path.exists(path) else {}
    profiles = data.setdefault("profiles", {})
    installation = profiles.get(slug) or {"created": now}
    installation.update(name=name, type="custom", icon="Grass", lastVersionId=version_id, gameDir=game_dir, lastUsed=now)
    profiles[slug] = installation
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
PY
  else
    echo "In the launcher, add an installation: version $version_id, game directory $game_dir"
  fi
}

if [ -n "$MODS" ]; then
  echo "Checking the server's mods..."
  install_mods "$MODS" || { echo "Couldn't install the server's mods."; exit 1; }
  echo "Mods are up to date."
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
if [ -n "$MODS" ]; then
  echo "In the launcher, pick the '$SERVER_NAME' installation next to PLAY."
fi
echo "In Minecraft: Multiplayer > Add Server > address: localhost:$LOCAL_PORT"
echo "Leave this running while you play. Ctrl+C to disconnect."
echo
exec cloudflared access tcp --hostname "$MC_HOST" --url "127.0.0.1:$LOCAL_PORT"
