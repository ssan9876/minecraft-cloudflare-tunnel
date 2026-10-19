"""Admin panel for the Minecraft server: status, console, players and backups."""
import asyncio
import hashlib
import hmac
import json
import os
import re
import secrets
import tarfile
import threading
import time
from contextlib import asynccontextmanager
from datetime import datetime
from pathlib import Path

from fastapi import Depends, FastAPI, HTTPException, Request, Response
from fastapi.responses import FileResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

from . import rcon

DATA = Path(os.environ.get("MC_DATA", "/data"))
BACKUPS = Path(os.environ.get("BACKUP_DIR", "/backups"))
ADMIN_PASSWORD = os.environ.get("ADMIN_PASSWORD", "")
PUBLIC_ADDRESS = os.environ.get("PUBLIC_ADDRESS", "")
BACKUP_INTERVAL_HOURS = float(os.environ.get("BACKUP_INTERVAL_HOURS") or 24)
BACKUP_KEEP = int(os.environ.get("BACKUP_KEEP") or 7)
STATIC = Path(__file__).parent / "static"

COOKIE = "mcadmin"
SESSION_SECONDS = 12 * 3600
# Regenerated on every start, so restarting the panel signs everyone out
SECRET = secrets.token_bytes(32)

NAME_RE = re.compile(r"[A-Za-z0-9_]{1,16}")
BACKUP_RE = re.compile(r"backup-\d{4}-\d{2}-\d{2}_\d{6}\.tar\.gz")
LIST_RE = re.compile(r"There are (\d+) of a max(?: of)? (\d+) players online:?(.*)", re.S)
ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")

# Regenerable or secret files left out of backups
BACKUP_SKIP = {"libraries", "versions", "cache", ".cache", "logs", ".rcon-cli.env", ".rcon-cli.yaml"}

STARTED = time.time()
_backup_lock = threading.Lock()
_backup = {"running": False, "error": None, "failed_at": 0.0}


@asynccontextmanager
async def lifespan(_: FastAPI):
    task = asyncio.create_task(_backup_scheduler())
    yield
    task.cancel()


app = FastAPI(lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)


# --- auth -------------------------------------------------------------------

def _sign(value: str) -> str:
    return hmac.new(SECRET, value.encode(), hashlib.sha256).hexdigest()


def require_auth(request: Request) -> None:
    expires, _, sig = request.cookies.get(COOKIE, "").partition(".")
    valid = (
        expires.isdigit()
        and hmac.compare_digest(sig.encode(), _sign(expires).encode())
        and int(expires) > time.time()
    )
    if not valid:
        raise HTTPException(401, "Sign in to continue.")


class Login(BaseModel):
    password: str


@app.post("/api/login")
async def login(body: Login, response: Response):
    if not ADMIN_PASSWORD:
        raise HTTPException(503, "No admin password is set. Add ADMIN_PASSWORD to .env and restart the panel.")
    if not hmac.compare_digest(body.password.encode(), ADMIN_PASSWORD.encode()):
        await asyncio.sleep(1)
        raise HTTPException(401, "That password is wrong.")
    expires = str(int(time.time()) + SESSION_SECONDS)
    response.set_cookie(
        COOKIE, f"{expires}.{_sign(expires)}", max_age=SESSION_SECONDS, httponly=True, samesite="strict"
    )
    return {"ok": True}


@app.post("/api/logout")
async def logout(response: Response):
    response.delete_cookie(COOKIE)
    return {"ok": True}


# --- helpers ----------------------------------------------------------------

async def _run(cmd: str, timeout: float = 5.0) -> str:
    try:
        return await asyncio.to_thread(rcon.command, cmd, timeout)
    except rcon.RconError as e:
        raise HTTPException(503, f"The server isn't taking commands right now. {e}") from e


def _one_line(text: str, limit: int) -> str:
    return " ".join(text.split())[:limit]


def _read_json(name: str) -> list:
    try:
        return json.loads((DATA / name).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []


def _properties() -> dict:
    props = {}
    try:
        for line in (DATA / "server.properties").read_text(encoding="utf-8").splitlines():
            if line and not line.startswith("#") and "=" in line:
                key, value = line.split("=", 1)
                props[key] = value
    except OSError:
        pass
    return props


def _version() -> str | None:
    try:
        with open(DATA / "logs" / "latest.log", encoding="utf-8", errors="replace") as f:
            for _, line in zip(range(300), f):
                m = re.search(r"Starting minecraft server version (\S+)", line)
                if m:
                    return m.group(1)
    except OSError:
        pass
    return None


# --- status & players -------------------------------------------------------

@app.get("/api/status", dependencies=[Depends(require_auth)])
async def status():
    props = _properties()
    result = {
        "online": False,
        "players": [],
        "max_players": int(props.get("max-players") or 0),
        "tps": None,
        "version": _version(),
        "motd": rcon.COLOR_CODES.sub("", props.get("motd", "")),
        "address": PUBLIC_ADDRESS,
    }
    try:
        listing = await asyncio.to_thread(rcon.command, "list")
    except rcon.RconError as e:
        result["error"] = str(e)
        return result
    result["online"] = True
    m = LIST_RE.search(listing)
    if m:
        result["max_players"] = int(m.group(2))
        result["players"] = [n.strip() for n in m.group(3).split(",") if n.strip()]
    try:
        tps = await asyncio.to_thread(rcon.command, "tps")
        values = re.findall(r"\d+(?:\.\d+)?", tps.rsplit(":", 1)[-1])
        result["tps"] = [float(v) for v in values[:3]] or None
    except rcon.RconError:
        pass
    return result


@app.get("/api/players", dependencies=[Depends(require_auth)])
async def players():
    return {
        "whitelist": [{"name": p.get("name"), "uuid": p.get("uuid")} for p in _read_json("whitelist.json")],
        "ops": [{"name": p.get("name"), "uuid": p.get("uuid"), "level": p.get("level")} for p in _read_json("ops.json")],
        "bans": [
            {"name": p.get("name"), "uuid": p.get("uuid"), "reason": p.get("reason"), "source": p.get("source"), "created": p.get("created")}
            for p in _read_json("banned-players.json")
        ],
    }


class PlayerAction(BaseModel):
    name: str
    reason: str = ""


PLAYER_COMMANDS = {
    "whitelist-add": "whitelist add {name}",
    "whitelist-remove": "whitelist remove {name}",
    "op": "op {name}",
    "deop": "deop {name}",
    "kick": "kick {name}{reason}",
    "ban": "ban {name}{reason}",
    "unban": "pardon {name}",
}


@app.post("/api/players/{action}", dependencies=[Depends(require_auth)])
async def player_action(action: str, body: PlayerAction):
    if action not in PLAYER_COMMANDS:
        raise HTTPException(404, "Unknown player action.")
    if not NAME_RE.fullmatch(body.name):
        raise HTTPException(400, "Minecraft usernames are 1 to 16 letters, numbers or underscores.")
    reason = _one_line(body.reason, 200)
    cmd = PLAYER_COMMANDS[action].format(name=body.name, reason=f" {reason}" if reason else "")
    return {"reply": await _run(cmd)}


class Command(BaseModel):
    command: str


@app.post("/api/command", dependencies=[Depends(require_auth)])
async def run_command(body: Command):
    cmd = _one_line(body.command, 1000).lstrip("/")
    if not cmd:
        raise HTTPException(400, "Type a command to run.")
    return {"reply": await _run(cmd, timeout=15)}


class Broadcast(BaseModel):
    message: str


@app.post("/api/broadcast", dependencies=[Depends(require_auth)])
async def broadcast(body: Broadcast):
    message = _one_line(body.message, 256)
    if not message:
        raise HTTPException(400, "Write a message to send.")
    await _run(f"say {message}")
    return {"ok": True}


@app.post("/api/restart", dependencies=[Depends(require_auth)])
async def restart():
    await _run("list")  # fail clearly if the server is already down
    try:
        # Docker's restart policy starts the container again once the server exits
        await asyncio.to_thread(rcon.command, "stop", 3)
    except rcon.RconError:
        pass  # the connection usually drops mid-shutdown
    return {"ok": True}


# --- console ----------------------------------------------------------------

def _sse(data: str, event: str | None = None) -> str:
    prefix = f"event: {event}\n" if event else ""
    return f"{prefix}data: {json.dumps(data)}\n\n"


@app.get("/api/console", dependencies=[Depends(require_auth)])
async def console(request: Request):
    path = DATA / "logs" / "latest.log"

    async def events():
        handle, inode, pending, first, idle = None, None, b"", True, 0
        try:
            while not await request.is_disconnected():
                try:
                    st = path.stat()
                except FileNotFoundError:
                    st = None
                # The server starts a fresh latest.log on every start
                if st and (handle is None or st.st_ino != inode or st.st_size < handle.tell()):
                    if handle:
                        handle.close()
                        yield _sse("", event="rotate")
                    handle, inode, pending = open(path, "rb"), st.st_ino, b""
                    if first:
                        start = max(0, st.st_size - 128 * 1024)
                        handle.seek(start)
                        lines = handle.read().split(b"\n")
                        pending = lines.pop()
                        if start:
                            lines = lines[1:]
                        for line in lines[-300:]:
                            yield _sse(ANSI_RE.sub("", line.decode("utf-8", "replace").rstrip("\r")))
                        first = False
                chunk = handle.read() if handle else b""
                if chunk:
                    *lines, pending = (pending + chunk).split(b"\n")
                    for line in lines:
                        yield _sse(ANSI_RE.sub("", line.decode("utf-8", "replace").rstrip("\r")))
                    idle = 0
                    continue
                idle += 1
                if idle % 30 == 0:
                    yield ": keepalive\n\n"
                await asyncio.sleep(0.5)
        finally:
            if handle:
                handle.close()

    return StreamingResponse(
        events(), media_type="text/event-stream", headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"}
    )


# --- backups ----------------------------------------------------------------

def _list_backups() -> list[dict]:
    try:
        entries = [p for p in BACKUPS.iterdir() if BACKUP_RE.fullmatch(p.name)]
    except OSError:
        return []
    entries.sort(key=lambda p: p.name, reverse=True)
    return [{"name": p.name, "size": p.stat().st_size, "created": p.stat().st_mtime} for p in entries]


def _skip_remapped(info: tarfile.TarInfo):
    return None if ".paper-remapped" in info.name.split("/") or info.name.endswith("session.lock") else info


def _create_backup() -> None:
    if not _backup_lock.acquire(blocking=False):
        raise RuntimeError("A backup is already running.")
    _backup.update(running=True, error=None)
    name = datetime.now().strftime("backup-%Y-%m-%d_%H%M%S.tar.gz")
    partial = BACKUPS / f".{name}.partial"
    saving_paused = False
    try:
        try:
            rcon.command("save-off")
            saving_paused = True
            rcon.command("save-all flush", timeout=120)
        except rcon.RconError:
            pass  # server is down, so the files on disk aren't changing
        with tarfile.open(partial, "w:gz", compresslevel=6) as tar:
            for entry in sorted(DATA.iterdir()):
                if entry.name not in BACKUP_SKIP and entry.suffix != ".jar":
                    tar.add(entry, arcname=entry.name, filter=_skip_remapped)
        partial.rename(BACKUPS / name)
        if BACKUP_KEEP > 0:
            for old in _list_backups()[BACKUP_KEEP:]:
                (BACKUPS / old["name"]).unlink(missing_ok=True)
    except Exception as e:
        partial.unlink(missing_ok=True)
        _backup.update(error=str(e), failed_at=time.time())
        raise
    finally:
        if saving_paused:
            try:
                rcon.command("save-on")
            except rcon.RconError:
                pass
        _backup["running"] = False
        _backup_lock.release()


def _next_backup_at() -> float | None:
    if BACKUP_INTERVAL_HOURS <= 0:
        return None
    backups = _list_backups()
    due = backups[0]["created"] + BACKUP_INTERVAL_HOURS * 3600 if backups else STARTED + 600
    # After a failure, wait an hour before trying again
    return max(due, _backup["failed_at"] + 3600)


async def _backup_scheduler():
    while (due := _next_backup_at()) is not None:
        await asyncio.sleep(min(max(due - time.time(), 30), 3600))
        if time.time() >= (_next_backup_at() or float("inf")) and not _backup["running"]:
            try:
                await asyncio.to_thread(_create_backup)
            except Exception:
                pass  # recorded in _backup["error"] and shown in the panel


@app.get("/api/backups", dependencies=[Depends(require_auth)])
async def backups():
    return {
        "backups": _list_backups(),
        "running": _backup["running"],
        "error": _backup["error"],
        "interval_hours": BACKUP_INTERVAL_HOURS,
        "keep": BACKUP_KEEP,
        "next": _next_backup_at(),
        "writable": os.access(BACKUPS, os.W_OK),
    }


@app.post("/api/backups", status_code=202, dependencies=[Depends(require_auth)])
async def start_backup():
    if _backup["running"]:
        raise HTTPException(409, "A backup is already running.")
    if not os.access(BACKUPS, os.W_OK):
        raise HTTPException(500, "The panel can't write to the backups folder.")

    async def run():
        try:
            await asyncio.to_thread(_create_backup)
        except Exception:
            pass  # recorded in _backup["error"]

    asyncio.create_task(run())
    return {"ok": True}


def _backup_path(name: str) -> Path:
    path = BACKUPS / name
    if not BACKUP_RE.fullmatch(name) or not path.is_file():
        raise HTTPException(404, "That backup doesn't exist.")
    return path


@app.get("/api/backups/{name}", dependencies=[Depends(require_auth)])
async def download_backup(name: str):
    return FileResponse(_backup_path(name), filename=name, media_type="application/gzip")


@app.delete("/api/backups/{name}", dependencies=[Depends(require_auth)])
async def delete_backup(name: str):
    _backup_path(name).unlink()
    return {"ok": True}


app.mount("/", StaticFiles(directory=STATIC, html=True), name="static")
