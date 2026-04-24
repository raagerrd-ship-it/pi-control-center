#!/usr/bin/env python3
"""
Pi Control Center API — persistent HTTP frontend.

Replaces the legacy `socat -> bash --handle-request` per-request architecture
with a long-lived Python process. The bash script is still the source of truth
for all install/update/uninstall/repair logic — Python only:

  1. Spawns the bash script in `--background-only` mode as a child process.
     Bash keeps running its three background loops:
        - status_cache_loop  (writes /tmp/pi-control-center/status-cache.json)
        - health_poll_loop
        - watchdog_loop
  2. Serves cheap GET endpoints directly from an in-memory cache of the
     status-cache.json file (mtime-based invalidation, zero forks per poll).
  3. Proxies every other endpoint to a one-shot `bash --handle-request`
     subprocess using the exact same wire protocol socat used. This keeps the
     huge install/update/factory-reset logic untouched.

Requires only the Python 3 standard library (Raspberry Pi OS Bookworm ships
with python3.11).
"""

from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Optional, Tuple

# --- Paths (mirror the bash script) ---------------------------------------

STATUS_DIR = Path("/tmp/pi-control-center")
INSTALL_DIR = STATUS_DIR / "install"
CACHE_FILE = STATUS_DIR / "status-cache.json"
REBOOT_REQUIRED_FILE = STATUS_DIR / "reboot-required.json"
FACTORY_RESET_FILE = STATUS_DIR / "factory-reset.json"
REGISTRY_FILE = Path("/var/www/pi-control-center/services.json")

# Resolve bash script. Prefer the canonical /usr/local/bin symlink which
# `pi-control-center-api.sh` keeps fresh on every invocation.
BASH_CANDIDATES = (
    "/usr/local/bin/pi-control-center-api.sh",
    "/home/pi/pi-control-center/public/pi-scripts/pi-control-center-api.sh",
    str(Path(__file__).with_name("pi-control-center-api.sh")),
)


def resolve_bash_script() -> str:
    for candidate in BASH_CANDIDATES:
        if os.path.isfile(candidate):
            return candidate
    raise FileNotFoundError(
        "pi-control-center-api.sh not found in any known location: "
        + ", ".join(BASH_CANDIDATES)
    )


PORT = int(os.environ.get("PORT", "8585"))
BASH_SCRIPT = resolve_bash_script()

# Default empty status payload (kept identical to the bash fallback so the
# frontend never sees a different shape during the first ~4s of boot).
EMPTY_STATUS = (
    b'{"cpu":0,"temp":0,"ramUsed":0,"ramTotal":0,'
    b'"diskUsed":0,"diskTotal":0,"uptime":"\xe2\x80\x94","services":{}}'
)

CORS_HEADERS = (
    ("Access-Control-Allow-Origin", "*"),
    ("Access-Control-Allow-Methods", "GET, POST, OPTIONS"),
    ("Access-Control-Allow-Headers", "Content-Type"),
)


# --- In-memory cache for status-cache.json --------------------------------

class StatusCache:
    """Mtime-based read-through cache for the bash-written status file.

    The bash background loop rewrites $CACHE_FILE every CACHE_MAX_AGE seconds
    (default 4s). We re-read it only when its mtime changes, so the hot
    /api/status path is one stat() + one in-memory copy per request.
    """

    def __init__(self, path: Path) -> None:
        self.path = path
        self._lock = threading.Lock()
        self._payload: bytes = EMPTY_STATUS
        self._mtime_ns: int = 0

    def get(self) -> bytes:
        try:
            st = os.stat(self.path)
        except FileNotFoundError:
            return self._payload  # whatever we last had (or EMPTY_STATUS)

        if st.st_mtime_ns == self._mtime_ns and self._payload is not EMPTY_STATUS:
            return self._payload

        try:
            with open(self.path, "rb") as fh:
                data = fh.read()
        except OSError:
            return self._payload

        if not data:
            return self._payload

        with self._lock:
            self._payload = data
            self._mtime_ns = st.st_mtime_ns
        return data


STATUS_CACHE = StatusCache(CACHE_FILE)


def read_file_or(path: Path, fallback: bytes) -> bytes:
    try:
        with open(path, "rb") as fh:
            data = fh.read()
        return data if data else fallback
    except OSError:
        return fallback


# --- Bash bridge for non-cached endpoints ---------------------------------

def proxy_to_bash(method: str, path: str, body: bytes) -> Tuple[int, bytes, str]:
    """Invoke `bash script --handle-request <port>` exactly the way socat did.

    Builds the same HTTP-1.1 request bytes the bash router expects on stdin,
    parses the status line + body out of stdout, and returns
    (status_code, body_bytes, content_type).

    NOTE: bash often forks long-running background jobs (`( ... ) &`) for
    install/update/factory-reset. Those jobs inherit our stdout/stderr pipes
    via fork(), so a naive `subprocess.run(..., capture_output=True)` would
    block until every background job finished (or our 120s timeout fired,
    causing the frontend to receive an empty body — "Unexpected end of JSON
    input"). To avoid this we use Popen + a reader thread per pipe, wait
    only on the main bash process, and then forcibly close the pipes so
    any orphaned background fds don't keep us hanging.
    """

    request = (
        f"{method} {path} HTTP/1.1\r\n"
        f"Host: 127.0.0.1\r\n"
        f"Content-Length: {len(body)}\r\n"
        f"Content-Type: application/json\r\n"
        f"Connection: close\r\n"
        f"\r\n"
    ).encode("utf-8") + body

    try:
        proc = subprocess.Popen(
            [BASH_SCRIPT, "--handle-request", str(PORT)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except FileNotFoundError:
        return 500, b'{"error":"bash handler missing"}', "application/json"

    stdout_chunks: list[bytes] = []

    def drain(pipe, sink):
        try:
            for chunk in iter(lambda: pipe.read(65536), b""):
                if sink is not None:
                    sink.append(chunk)
        except Exception:
            pass

    out_thread = threading.Thread(target=drain, args=(proc.stdout, stdout_chunks), daemon=True)
    err_thread = threading.Thread(target=drain, args=(proc.stderr, None), daemon=True)
    out_thread.start()
    err_thread.start()

    try:
        proc.stdin.write(request)
        proc.stdin.close()
    except BrokenPipeError:
        pass

    # Wait only for the foreground bash process (handle_request). Background
    # jobs spawned via `&` keep running detached — we don't care about them.
    try:
        proc.wait(timeout=120)
    except subprocess.TimeoutExpired:
        proc.kill()
        return 504, b'{"error":"bash handler timed out"}', "application/json"

    # Force-close the pipes so the reader threads exit even if background
    # children inherited the fds and are still holding them open.
    try:
        proc.stdout.close()
    except Exception:
        pass
    try:
        proc.stderr.close()
    except Exception:
        pass
    out_thread.join(timeout=1.0)
    err_thread.join(timeout=1.0)

    raw = b"".join(stdout_chunks)
    if not raw:
        return 502, b'{"error":"empty bash response"}', "application/json"

    # Split headers/body. socat-style response uses \r\n\r\n.
    sep = raw.find(b"\r\n\r\n")
    if sep < 0:
        return 502, b'{"error":"malformed bash response"}', "application/json"

    header_blob = raw[:sep].decode("iso-8859-1", errors="replace")
    resp_body = raw[sep + 4:]

    status_code = 200
    content_type = "application/json"
    for i, line in enumerate(header_blob.split("\r\n")):
        if i == 0 and line.startswith("HTTP/"):
            parts = line.split(" ", 2)
            if len(parts) >= 2 and parts[1].isdigit():
                status_code = int(parts[1])
            continue
        lower = line.lower()
        if lower.startswith("content-type:"):
            content_type = line.split(":", 1)[1].strip()
    return status_code, resp_body, content_type


# --- Background bash supervisor -------------------------------------------

class BashSupervisor:
    """Keeps `bash --background-only` alive as a child process."""

    def __init__(self) -> None:
        self.proc: Optional[subprocess.Popen[bytes]] = None
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, name="bash-supervisor", daemon=True)

    def start(self) -> None:
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self.proc and self.proc.poll() is None:
            try:
                self.proc.terminate()
                try:
                    self.proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self.proc.kill()
            except ProcessLookupError:
                pass

    def _run(self) -> None:
        backoff = 1.0
        while not self._stop.is_set():
            try:
                self.proc = subprocess.Popen(
                    [BASH_SCRIPT, "--background-only", str(PORT)],
                    stdout=sys.stdout,
                    stderr=sys.stderr,
                )
            except Exception as exc:  # pragma: no cover — defensive
                print(f"[supervisor] failed to spawn bash: {exc}", file=sys.stderr, flush=True)
                if self._stop.wait(backoff):
                    return
                backoff = min(backoff * 2, 30.0)
                continue

            backoff = 1.0
            ret = self.proc.wait()
            if self._stop.is_set():
                return
            print(
                f"[supervisor] bash background process exited with {ret}, restarting in 2s",
                file=sys.stderr,
                flush=True,
            )
            if self._stop.wait(2.0):
                return


# --- HTTP handler ----------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    server_version = "PiControlCenter/2.0"
    # Quiet the default access log — systemd journal would balloon otherwise.
    def log_message(self, format: str, *args) -> None:  # noqa: A002
        return

    # --- Helpers ----------------------------------------------------------

    def _send(self, status: int, body: bytes, content_type: str = "application/json") -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        for name, value in CORS_HEADERS:
            self.send_header(name, value)
        self.send_header("Connection", "close")
        self.end_headers()
        if body and self.command != "HEAD":
            self.wfile.write(body)

    def _read_body(self) -> bytes:
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0:
            return b""
        return self.rfile.read(length)

    # --- Fast-path endpoints (served from memory / direct file read) ------

    def _try_fast_path(self) -> bool:
        path = self.path
        method = self.command

        if method == "OPTIONS":
            self._send(204, b"", "text/plain")
            return True

        if method == "GET":
            if path == "/api/ping":
                self._send(200, b'{"pong":true}')
                return True
            if path == "/api/status":
                self._send(200, STATUS_CACHE.get())
                return True
            if path == "/api/available-services":
                self._send(200, read_file_or(REGISTRY_FILE, b"[]"))
                return True
            if path == "/api/factory-reset-status":
                self._send(200, read_file_or(FACTORY_RESET_FILE, b'{"status":"idle"}'))
                return True
            if path.startswith("/api/install-status/"):
                app = path[len("/api/install-status/"):]
                # Match the bash sanitisation: only letters/digits/_/-
                safe = "".join(c for c in app if c.isalnum() or c in "_-")
                fallback = (
                    f'{{"app":"{safe}","status":"idle"}}'.encode("utf-8")
                )
                self._send(200, read_file_or(INSTALL_DIR / f"{safe}.json", fallback))
                return True

        return False

    # --- Default: proxy to bash ------------------------------------------

    def _proxy(self) -> None:
        body = self._read_body() if self.command in ("POST", "PUT", "DELETE", "PATCH") else b""
        status, resp, ct = proxy_to_bash(self.command, self.path, body)
        self._send(status, resp, ct)

    # --- BaseHTTPRequestHandler dispatch ---------------------------------

    def do_GET(self) -> None:
        if not self._try_fast_path():
            self._proxy()

    def do_POST(self) -> None:
        if not self._try_fast_path():
            self._proxy()

    def do_OPTIONS(self) -> None:
        self._try_fast_path()

    def do_PUT(self) -> None:
        self._proxy()

    def do_DELETE(self) -> None:
        self._proxy()

    def do_PATCH(self) -> None:
        self._proxy()


# --- Entry point -----------------------------------------------------------

def main() -> int:
    STATUS_DIR.mkdir(parents=True, exist_ok=True)

    supervisor = BashSupervisor()
    supervisor.start()

    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    server.daemon_threads = True

    def shutdown(signum, _frame) -> None:  # pragma: no cover
        print(f"[main] received signal {signum}, shutting down", file=sys.stderr, flush=True)
        supervisor.stop()
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    print(
        f"Pi Control Center API (Python) listening on port {PORT} — bash script: {BASH_SCRIPT}",
        flush=True,
    )

    try:
        server.serve_forever(poll_interval=1.0)
    finally:
        supervisor.stop()
        server.server_close()
    return 0


if __name__ == "__main__":
    # Give the supervisor a head start so the cache file exists when the first
    # /api/status request arrives. Not strictly required (we have EMPTY_STATUS)
    # but avoids one empty-payload response right after restart.
    try:
        sys.exit(main())
    except Exception as exc:  # pragma: no cover
        print(f"[main] fatal: {exc}", file=sys.stderr, flush=True)
        sys.exit(1)
