#!/usr/bin/env bash
# Switches this stack from Paper to Fabric, keeping the existing world. Run as root from the stack
# directory (the one with .env, e.g. /opt/minecraft) after copying in the updated docker-compose.yml:
#
#   cd /opt/minecraft && bash /path/to/paper-to-fabric.sh
#
# Paper (26.x) saves world-wide data (world gen settings with the seed, game rules, weather, the
# day clock) inside each dimension's folder, while vanilla/Fabric reads one copy from world/data.
# Without it, Fabric stops with "Overworld settings missing". This copies the overworld's files up.
#
# Optional: MODRINTH (fabric-api), the Modrinth projects to install.
set -euo pipefail

MODRINTH="${MODRINTH:-fabric-api}"

[ -f .env ] || { echo "No .env here. Run this from the stack directory (e.g. /opt/minecraft)."; exit 1; }
grep -q 'MC_TYPE:-' docker-compose.yml || { echo "docker-compose.yml has no MC_TYPE setting. Update it from the repo first."; exit 1; }

set_env() {
  if grep -q "^$1=" .env; then sed -i "s|^$1=.*|$1=$2|" .env; else echo "$1=$2" >> .env; fi
}

world_data=data/world/data/minecraft
paper_data=data/world/dimensions/minecraft/overworld/data/minecraft

docker compose stop minecraft

backup="backups/pre-fabric-$(date +%Y-%m-%d_%H%M%S).tar.gz"
mkdir -p backups
tar -czf "$backup" data .env docker-compose.yml
echo "Backed up to $backup"

# A world already in vanilla layout (e.g. after an earlier run) is left alone, so this never
# overwrites newer Fabric data with stale Paper copies.
if [ -f "$world_data/world_gen_settings.dat" ]; then
  echo "World already has $world_data/world_gen_settings.dat; not touching world files."
elif [ -f "$paper_data/world_gen_settings.dat" ]; then
  for f in world_gen_settings game_rules weather scheduled_events wandering_trader world_clocks; do
    if [ -f "$paper_data/$f.dat" ]; then cp -p "$paper_data/$f.dat" "$world_data/$f.dat"; fi
  done
  echo "Moved Paper's world data to $world_data"
else
  echo "No world found yet; Fabric will generate a new one."
fi

# Pin the version Paper was running, so a new Minecraft release can't break the mods
version="$(grep -oE '^MC_VERSION=.*' .env | cut -d= -f2)"
if [ -z "$version" ] || [ "$version" = LATEST ]; then
  jar="$(ls data/paper-*.jar 2>/dev/null | head -1)"
  version="$(basename "${jar:-}" .jar | sed -nE 's/^paper-(.+)-[0-9]+$/\1/p')"
  if [ -n "$version" ]; then set_env MC_VERSION "$version"; else echo "Couldn't detect the version; set MC_VERSION in .env."; fi
fi

set_env MC_TYPE FABRIC
set_env MC_MODRINTH_PROJECTS "$MODRINTH"
set_env MC_REMOVE_OLD_MODS TRUE
mkdir -p mods

docker compose up -d minecraft
echo "Starting on Fabric${version:+ $version}. Watch it with: docker compose logs -f minecraft"
echo "To undo: docker compose stop minecraft, then restore $backup"
