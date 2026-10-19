"""Minimal Source RCON client for the Minecraft server."""
import os
import re
import socket
import struct
import threading
from pathlib import Path

HOST = os.environ.get("RCON_HOST", "minecraft")
PORT = int(os.environ.get("RCON_PORT", "25575"))
DATA = Path(os.environ.get("MC_DATA", "/data"))

AUTH, COMMAND = 3, 2
COLOR_CODES = re.compile("§.")
_lock = threading.Lock()


class RconError(Exception):
    pass


def _password() -> str:
    if os.environ.get("RCON_PASSWORD"):
        return os.environ["RCON_PASSWORD"]
    # itzg/minecraft-server generates a password on each start and writes it here
    try:
        for line in (DATA / ".rcon-cli.env").read_text(encoding="utf-8").splitlines():
            key, _, value = line.partition("=")
            if key.strip().lower() == "password":
                return value.strip()
    except OSError:
        pass
    raise RconError("No RCON password found. Is the server running?")


def _send(sock: socket.socket, request_id: int, kind: int, body: str) -> None:
    payload = struct.pack("<ii", request_id, kind) + body.encode("utf-8") + b"\x00\x00"
    sock.sendall(struct.pack("<i", len(payload)) + payload)


def _recv_exact(sock: socket.socket, size: int) -> bytes:
    buf = b""
    while len(buf) < size:
        chunk = sock.recv(size - len(buf))
        if not chunk:
            raise RconError("The server closed the connection.")
        buf += chunk
    return buf


def _recv(sock: socket.socket) -> tuple[int, str]:
    (length,) = struct.unpack("<i", _recv_exact(sock, 4))
    if not 10 <= length <= 1 << 20:
        raise RconError("The server sent a malformed reply.")
    data = _recv_exact(sock, length)
    (request_id,) = struct.unpack("<i", data[:4])
    return request_id, data[8:-2].decode("utf-8", "replace")


# One long-lived connection: the server logs two lines for every new RCON client,
# so reconnecting on each poll would flood the console.
_sock: socket.socket | None = None
_next_id = 1


def _connect() -> socket.socket:
    sock = socket.create_connection((HOST, PORT), timeout=5)
    try:
        _send(sock, 0, AUTH, _password())
        if _recv(sock)[0] == -1:
            raise RconError("The server rejected the RCON password.")
    except BaseException:
        sock.close()
        raise
    return sock


def _close() -> None:
    global _sock
    if _sock:
        try:
            _sock.close()
        except OSError:
            pass
    _sock = None


def _exchange(sock: socket.socket, cmd: str, timeout: float) -> str:
    global _next_id
    _next_id = _next_id % 2_000_000_000 + 1
    request_id = _next_id
    sock.settimeout(timeout)
    _send(sock, request_id, COMMAND, cmd)
    # Skip late replies to earlier commands that timed out
    while True:
        reply_id, body = _recv(sock)
        if reply_id == request_id:
            break
    parts = [body]
    # Replies longer than 4096 bytes arrive split across several packets
    if len(body.encode("utf-8")) >= 4000:
        sock.settimeout(0.3)
        try:
            while True:
                reply_id, more = _recv(sock)
                if reply_id == request_id:
                    parts.append(more)
        except socket.timeout:
            pass
    return COLOR_CODES.sub("", "".join(parts)).strip()


def command(cmd: str, timeout: float = 5.0) -> str:
    """Runs one console command and returns the reply with color codes removed."""
    global _sock
    with _lock:
        reused = _sock is not None
        try:
            if _sock is None:
                _sock = _connect()
            return _exchange(_sock, cmd, timeout)
        except (OSError, RconError) as first:
            _close()
            if not reused or isinstance(first, socket.timeout):
                raise _wrap(first) from first
        # The kept-open connection had gone stale (e.g. the server restarted); retry once on a fresh one
        try:
            _sock = _connect()
            return _exchange(_sock, cmd, timeout)
        except (OSError, RconError) as e:
            _close()
            raise _wrap(e) from e


def _wrap(e: Exception) -> RconError:
    if isinstance(e, RconError):
        return e
    if isinstance(e, socket.timeout):
        return RconError("The server took too long to answer.")
    return RconError(f"Can't reach the server ({e.strerror or e}).")
