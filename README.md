# Minecraft over Cloudflare Tunnel

A Paper (Java Edition) server that players reach through a Cloudflare Tunnel, so your router needs no open
ports and your home IP stays private. It comes with one-click join scripts for players and a web admin panel.

- `docker-compose.yml`: the Paper server ([itzg/minecraft-server](https://github.com/itzg/docker-minecraft-server)),
  the admin panel, and an optional bundled `cloudflared` connector
- `player/`: join scripts to hand to players (Windows, macOS, Linux)
- `admin/`: the admin panel (live console, players, whitelist/ops/bans, backups, restart)
- `scripts/proxmox-create-lxc.sh`: optional script that sets this up in a Proxmox LXC

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
3. Zip the `player/` folder and send it to your players.

**Windows:** players double-click `join.bat`. It:
1. installs `cloudflared` through winget (first run only),
2. starts the tunnel in the background,
3. adds your server to the top of their Multiplayer list (keeping a backup at `servers.dat.bak`),
4. opens the Minecraft Launcher,
5. disconnects when Minecraft closes.

Players then click **Play → Multiplayer → your server**. The official launcher can't join a server automatically.

**macOS / Linux:** players run `./join.sh` and keep it running while they play, then add the server
`localhost:25565` in Minecraft. On macOS it also opens the launcher.

If port 25565 is already taken on a player's PC (for example, they host their own server), they set `LOCAL_PORT`
in `server.conf`, or run `join.bat <hostname> 25570`.

## Admin panel

Open `http://<server>:8080` and sign in with `ADMIN_PASSWORD`.

- **Online now:** shows players, tick rate and version. Click a player's head to kick, ban or op them.
- **Console:** the live server log. Run any command from the box under it; ↑/↓ steps through your history.
- **Players:** the whitelist, operators and bans, with add and remove.
- **Backups:** a backup runs automatically every `BACKUP_INTERVAL_HOURS`, and the newest `BACKUP_KEEP` are kept in `./backups`.
  You can also back up now, download or delete. Each archive holds the world, configs and plugins.
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
