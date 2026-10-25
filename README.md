# Minecraft over Cloudflare Tunnel

A Minecraft Java Edition server (Paper, or Fabric for mods) that players reach through a Cloudflare Tunnel, so your router needs no open
ports and your home IP stays private. It comes with one-click join scripts for players and a web admin panel.

- `docker-compose.yml`: the Minecraft server ([itzg/minecraft-server](https://github.com/itzg/docker-minecraft-server)),
  the admin panel, and an optional bundled `cloudflared` connector
- `player/`: join scripts to hand to players (Windows, macOS, Linux)
- `admin/`: the admin panel (live console, players, whitelist/ops/bans, backups, restart)
- `scripts/proxmox-create-lxc.sh`: optional script that sets this up in a Proxmox LXC
- `scripts/paper-to-fabric.sh`: switches an existing Paper server to Fabric, keeping the world

## How it works

```
Player's Minecraft ─► localhost:25565 ─► cloudflared access tcp (player's PC)
   ═══ HTTPS/WebSocket to Cloudflare ═══►
cloudflared connector (your network) ─► Minecraft server :25565
```

On the free plan, a Cloudflare Tunnel only accepts HTTP(S) from the internet. Minecraft speaks raw TCP, so
Cloudflare carries it inside a WebSocket, and **each player runs `cloudflared`** to unwrap it. The join scripts
install it and handle everything. Typing the hostname straight into Minecraft would need Cloudflare Spectrum, a paid add-on.

## Requirements

- A domain on Cloudflare (free plan is fine)
- Docker with Compose v2 on the server machine
- Minecraft: Java Edition for players

## Setup

### 1. Configure

```bash
cp .env.example .env
```

| Setting | What it's for |
|---|---|
| `MC_WHITELIST`, `MC_OPS` | Comma-separated usernames. The whitelist is enforced, so nobody else can join. |
| `ADMIN_PASSWORD` | Password for the admin panel. Use a long random one. |
| `ADMIN_BIND` | `127.0.0.1` keeps the panel on this machine; `0.0.0.0` opens it to your LAN. |
| `PUBLIC_ADDRESS` | The tunnel hostname, shown in the admin panel. |
| `MC_BIND` | `0.0.0.0` if a `cloudflared` on *another* machine forwards to this server. |
| `COMPOSE_PROFILES`, `TUNNEL_TOKEN` | Only for the bundled connector (step 2, option A). |
| `MC_MOTD`, `MC_MEMORY`, `MC_VERSION`, `TZ` | Server name, memory, version, timezone. |
| `MC_TYPE`, `MC_MODRINTH_PROJECTS`, `MC_REMOVE_OLD_MODS` | `PAPER` (default) or `FABRIC`, and the mods to install. See [Mods (Fabric)](#mods-fabric). |

### 2. Create the tunnel route

In the [Cloudflare Zero Trust dashboard](https://one.dash.cloudflare.com), pick one of these:

**A. New tunnel, bundled connector** (simplest: everything on one machine)
1. **Networks → Tunnels → Create a tunnel → Cloudflared.** Copy the token from the install command (the part after `--token`).
   You don't need to install anything; Docker runs the connector.
2. Add a **published application route** (older dashboards call it a **public hostname**):
   - Hostname: `mc.yourdomain.com`
   - Service type: **TCP**
   - URL: **`minecraft:25565`**
3. In `.env`, set `COMPOSE_PROFILES=tunnel` and `TUNNEL_TOKEN=<token>`.

**B. Existing tunnel** (you already run `cloudflared` somewhere on your network)
1. Open that tunnel and add a published application route:
   - Hostname: `mc.yourdomain.com`
   - Service type: **TCP**
   - URL: **`<server LAN IP>:25565`**
2. In `.env`, set `MC_BIND=0.0.0.0`.

Cloudflare creates the DNS record for you. If it reports that a record already exists, delete that DNS record and save again.

### 3. Start

```bash
docker compose up -d
docker compose logs -f minecraft   # wait for: Done (...)! For help, type "help"
```

The first start downloads Paper and generates the world, which takes a few minutes.

### 4. Hand out the join scripts

1. Copy `player/server.conf.example` to `player/server.conf`.
2. Set `HOSTNAME` to your tunnel hostname and `SERVER_NAME` to what players should see.
3. On a Fabric server, set `MODS` too (see [Mods (Fabric)](#mods-fabric)).
4. Optionally set `SCRIPTS` to where the latest join scripts are published (see
   [Keeping the scripts up to date](#keeping-the-scripts-up-to-date)).
5. Zip the `player/` folder and send it to your players.

**Windows:** players double-click `join.bat`. It:
1. on a Fabric server, installs Fabric and the server's mods (see [Mods for players](#mods-for-players)),
2. installs `cloudflared` through winget (first run only),
3. starts the tunnel in the background,
4. adds your server to the top of their Multiplayer list (keeping a backup at `servers.dat.bak`),
5. opens the Minecraft Launcher,
6. disconnects when Minecraft closes.

Players then click **Play → Multiplayer → your server**. The official launcher can't join a server automatically.

**macOS / Linux:** players run `./join.sh` and keep it running while they play, then add the server
`localhost:25565` in Minecraft. On macOS it also opens the launcher.

#### Keeping the scripts up to date

With `SCRIPTS` set in `server.conf` to a folder link holding the latest `join.ps1` and `join.sh` (for this repo,
`https://raw.githubusercontent.com/ssan9876/minecraft-cloudflare-tunnel/main/player`), the scripts check it each
time they run. If the copy there has a higher version number (`$JoinScriptVersion` in `join.ps1`,
`JOIN_SCRIPT_VERSION` in `join.sh`) and parses, it replaces the player's copy and runs instead. So once players
have a zip with `SCRIPTS` set, they never need a new one: bump the version when changing a script and push it.
If the check fails (offline, GitHub down), the script carries on with the copy it has.

If port 25565 is already taken on a player's PC (for example, they host their own server), they set `LOCAL_PORT`
in `server.conf`, or run `join.bat <hostname> 25570`.

## Admin panel

Open `http://<server>:8080` and sign in with `ADMIN_PASSWORD`.

- **Online now:** shows players, tick rate and version. Click a player's head to kick, ban or op them.
- **Console:** the live server log. Run any command from the box under it; ↑/↓ steps through your history.
- **Players:** the whitelist, operators and bans, with add and remove.
- **Backups:** a backup runs automatically every `BACKUP_INTERVAL_HOURS`, and the newest `BACKUP_KEEP` are kept in `./backups`.
  You can also back up now, download or delete. Each archive holds the world, configs, and plugins or mods.
  Saving is paused while it's written, so the world stays consistent.
- **Restart server:** sends `stop`, and Docker starts the server again (about 30 s).
- **Broadcast:** sends a chat message to everyone online.

The panel talks to the server over RCON on the internal compose network and mounts the world read-only. It has
no Docker socket access. It uses a single password over plain HTTP, so keep it on your LAN or VPN. **Don't publish it
through the tunnel** unless a Cloudflare Access policy sits in front of it.

To restore a backup:
```bash
docker compose stop minecraft
mv data/world data/world.old && tar -xzf backups/<file>.tar.gz -C data world
docker compose start minecraft
```

Command-line console: `docker exec -it minecraft rcon-cli`.

## Mods (Fabric)

Paper runs plugins, which live only on the server, so players need nothing extra. To run mods that add
new blocks, items or creatures, switch the server to [Fabric](https://fabricmc.net):

```bash
# .env
MC_TYPE=FABRIC
MC_VERSION=26.3                     # pin it: mods are built for one Minecraft version
MC_MODRINTH_PROJECTS=fabric-api     # comma-separated Modrinth slugs, downloaded on start
MC_REMOVE_OLD_MODS=TRUE             # clear old jars each start so replaced versions don't pile up
```

Put your own mod jars in `./mods`. They're copied into the server on every start, so after replacing a jar,
restart the server (from the admin panel, or `docker compose restart minecraft`).

**Switching an existing Paper world:** Paper stores the world's seed, game rules, weather and day clock inside
each dimension's folder. Fabric reads them from `world/data`, and without them it stops with
`Overworld settings missing`. `scripts/paper-to-fabric.sh` backs up `data/`, copies those files across,
pins `MC_VERSION` to the version Paper was running, sets the variables above and starts the server. Copy the
updated `docker-compose.yml` into the stack directory first, then run the script from there:

```bash
cd /opt/minecraft && bash /path/to/scripts/paper-to-fabric.sh
```

To go back, stop the server and restore the `backups/pre-fabric-*.tar.gz` it made.

On Fabric:
- **Players need the same mods.** The server turns away anyone without Fabric and every mod that adds content.
  Server-only mods (for example Lithium for performance) don't need installing client-side.
- **The admin panel's tick rate stays blank.** It comes from Paper's `/tps` command. Everything else works.
- **Paper's settings files** (`bukkit.yml`, `spigot.yml`, `config/paper-*.yml`) and `plugins/` are ignored.

### Mods for players

The join scripts install Fabric and the server's mods for each player. List them in a mods file
(see `player/mods.txt.example`): the Minecraft and Fabric Loader versions, then a download link for each mod.

```
minecraft 26.3
fabric-loader 0.20.1
mod https://cdn.modrinth.com/data/P7dR8mSH/versions/EQKgpeKu/fabric-api-0.165.0%2B26.3.jar
mod https://github.com/you/your-mod/releases/download/v1.0.0/your-mod-1.0.0.jar
```

Then set `MODS` in `player/server.conf`, either to the file (`MODS=mods.txt`, sent along in the zip, where
`mod` lines may also name jars next to it) or to an https:// link to it. With a link, players pick up mod
updates the next time they run the join script, without new files from you.

Each time it runs, the join script:
1. installs Fabric for the listed version,
2. downloads any listed mods it doesn't have yet, and removes ones it installed before that are no longer listed
   (jars the player added themselves stay),
3. creates an installation in the launcher named after `SERVER_NAME`, selected and ready to play.

The installation has its own game folder (`.minecraft/profiles/<server name>`), so the player's other mods and
versions are untouched. The first time, it copies their settings across. Pin the server's mods to the same
versions as the list, for example `MC_MODRINTH_PROJECTS=fabric-api:EQKgpeKu` (a Modrinth version ID).

## Running on Proxmox

`scripts/proxmox-create-lxc.sh` creates an unprivileged Debian 13 LXC with nesting, installs Docker, copies this
stack to `/opt/minecraft` and starts it. Run it as root on the Proxmox host, from a checkout with `.env` filled in:

```bash
CTID=120 IP=192.168.1.50/24 GATEWAY=192.168.1.1 ./scripts/proxmox-create-lxc.sh
```

Optional variables, with their defaults: `CT_NAME` (minecraft), `BRIDGE` (vmbr0), `STORAGE` (local-lvm),
`DISK_GB` (32), `CORES` (4), `MEMORY_MB` (6144), `TEMPLATE` (the newest Debian 13 standard template).

## What players can reach

Only the Minecraft port. The tunnel forwards your one hostname to one TCP port. It isn't a VPN, so players can't
see your LAN or other machines. To keep it that way:

- **Expose only what you mean to.** Every published route on the tunnel is a service on the internet.
- **No private network routes.** Under Zero Trust → Networks → Routes, don't add CIDR ranges to this tunnel, and
  keep WARP routing off. Routes are what turn a tunnel into LAN access for WARP clients. Players don't need WARP.
- **Secure your Cloudflare account** with 2FA. Anyone who can edit the tunnel can change what it exposes.
- **Optional: Cloudflare Access.** Add a self-hosted Access application for your Minecraft hostname with a policy
  that lists your players' emails. The join script opens a browser sign-in on first connect, and strangers can't
  even reach the server.

The containers are locked down too. `cloudflared` runs read-only with no Linux capabilities, the admin panel the
same, and the Minecraft server runs as a non-root user.

## Caveats

- **Java Edition only.** Bedrock uses UDP, which a TCP route can't carry.
- **All players share one IP** (the connector's). IP bans don't work, so use the whitelist and name bans.
  `config/bukkit.yml` turns off Bukkit's per-IP connection throttle so players who join together aren't rejected.
- **Expect a little more latency** than a direct connection, because traffic goes through Cloudflare's nearest data center at both ends.
