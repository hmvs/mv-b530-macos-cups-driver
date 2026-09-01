"""Print agent for the MV-B530 / Kmart Anko Inkless A4 thermal printer.

Runs inside TiMiniRunner.app so it holds the Bluetooth TCC grant that a CUPS
backend can never obtain: backends are spawned by cupsd as _lp, a context that
cannot hold a Bluetooth grant or show a permission prompt.

The handoff is HTTP on the loopback interface rather than a shared spool
directory, because macOS sandboxes CUPS backends away from arbitrary
filesystem paths (a backend cannot even stat /usr/local/var/spool/...).
Networking is permitted, since ipp/socket/lpd backends depend on it.
"""

import glob
import io
import json
import os
import sys
import time
import runpy
import threading
import traceback
import contextlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BASE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.join(BASE, "TiMini-Print")
LOG = os.path.join(BASE, "agent.log")
TMP = os.path.join(BASE, "tmp")

HOST = "127.0.0.1"
PORT = int(os.environ.get("TIMINI_PORT", "9101"))

# Empty PRINTER means "first supported printer in range", which is what you
# want unless several TiMini-compatible printers are nearby. Pin one with
# e.g. TIMINI_PRINTER=MV-B530-38AC.
PRINTER = os.environ.get("TIMINI_PRINTER", "")
MODEL = os.environ.get("TIMINI_MODEL", "mv_b530")
PAPER = os.environ.get("TIMINI_PAPER", "a4sheet_1600r_1632p_32pl_2460mh")

MAX_BODY = 64 * 1024 * 1024

for _sp in glob.glob(os.path.join(REPO, ".venv", "lib", "python*", "site-packages")):
    sys.path.insert(0, _sp)
sys.path.insert(0, REPO)

# The Bluetooth link handles one job at a time.
_print_lock = threading.Lock()


def log(msg):
    with open(LOG, "a") as fh:
        fh.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}\n")


def run_timiniprint(path, darkness):
    """Print one file. Returns (ok, combined output)."""
    argv = ["timiniprint"]
    if PRINTER:
        argv += ["--bluetooth", PRINTER]
    argv += ["--printer-model", MODEL, "--paper", PAPER, "--verbose"]
    if darkness:
        argv += ["--darkness", str(darkness)]
    argv.append(path)

    saved, sys.argv = sys.argv, argv
    buf = io.StringIO()
    try:
        with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
            runpy.run_module("timiniprint", run_name="__main__")
        return True, buf.getvalue()
    except SystemExit as exc:
        return (exc.code or 0) == 0, buf.getvalue()
    except Exception:
        return False, buf.getvalue() + "\n" + traceback.format_exc()
    finally:
        sys.argv = saved


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass  # keep cupsd's stderr clean; we have our own log

    def _reply(self, code, body):
        payload = body.encode("utf-8", "replace")
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        if self.path == "/health":
            self._reply(200, "ok\n")
        else:
            self._reply(404, "not found\n")

    def do_POST(self):
        if self.path != "/print":
            self._reply(404, "not found\n")
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = 0
        if length <= 0:
            self._reply(400, "empty job\n")
            return
        if length > MAX_BODY:
            self._reply(413, "job too large\n")
            return

        data = self.rfile.read(length)
        darkness = self.headers.get("X-Timini-Darkness", "").strip()
        if darkness not in {"1", "2", "3", "4", "5"}:
            darkness = ""

        os.makedirs(TMP, exist_ok=True)
        # timiniprint dispatches on file extension, so the suffix matters.
        path = os.path.join(TMP, f"job-{int(time.time())}-{threading.get_ident()}.pdf")
        with open(path, "wb") as fh:
            fh.write(data)

        log(f"job received: {len(data)} bytes darkness={darkness or 'default'}")
        with _print_lock:
            ok, out = run_timiniprint(path, darkness)
        try:
            os.remove(path)
        except OSError:
            pass

        log(f"job {'OK' if ok else 'FAILED'}\n{out.strip()[-2000:]}")
        self._reply(200 if ok else 500, out[-4000:] or ("ok\n" if ok else "failed\n"))


def main():
    os.makedirs(TMP, exist_ok=True)
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    log(f"agent started (pid {os.getpid()}) listening on http://{HOST}:{PORT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
