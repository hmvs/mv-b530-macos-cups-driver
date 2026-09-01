"""Spool watcher for the MV-B530 thermal printer.

Runs inside TiMiniRunner.app so it holds the Bluetooth TCC grant that a CUPS
backend (running as _lp under cupsd) can never obtain. The backend drops a job
in the spool directory; this agent prints it and writes back a result file.
"""

import io
import json
import os
import sys
import time
import runpy
import traceback
import contextlib

BASE = os.path.dirname(os.path.abspath(__file__))
SPOOL = os.environ.get("TIMINI_SPOOL", "/usr/local/var/spool/timini")
REPO = os.path.join(BASE, "TiMini-Print")
LOG = os.path.join(BASE, "agent.log")

PRINTER = "MV-B530-38AC"
MODEL = "mv_b530"
PAPER = "a4sheet_1600r_1632p_32pl_2460mh"

sys.path.insert(0, os.path.join(REPO, ".venv", "lib", "python3.14", "site-packages"))
sys.path.insert(0, REPO)


def log(msg):
    line = f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}\n"
    with open(LOG, "a") as fh:
        fh.write(line)


def print_file(path, opts):
    """Run timiniprint against one file. Returns (ok, output)."""
    argv = [
        "timiniprint",
        "--bluetooth", PRINTER,
        "--printer-model", MODEL,
        "--paper", opts.get("paper", PAPER),
        "--verbose",
    ]
    darkness = opts.get("darkness")
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
        code = exc.code or 0
        return code == 0, buf.getvalue()
    except Exception:
        return False, buf.getvalue() + "\n" + traceback.format_exc()
    finally:
        sys.argv = saved


def claim(ready):
    """Atomically take ownership of a job so two agents can't double-print."""
    taken = ready + ".taken"
    try:
        os.rename(ready, taken)
        return taken
    except OSError:
        return None


def handle(job_id):
    data = os.path.join(SPOOL, job_id + ".pdf")
    optf = os.path.join(SPOOL, job_id + ".opts")
    opts = {}
    if os.path.exists(optf):
        try:
            opts = json.load(open(optf))
        except Exception:
            pass

    log(f"job {job_id}: printing {data} opts={opts}")
    ok, out = print_file(data, opts)
    log(f"job {job_id}: {'OK' if ok else 'FAILED'}\n{out.strip()[-2000:]}")

    result = os.path.join(SPOOL, job_id + (".done" if ok else ".err"))
    with open(result, "w") as fh:
        fh.write(out[-4000:])

    for leftover in (data, optf, os.path.join(SPOOL, job_id + ".ready.taken")):
        try:
            os.remove(leftover)
        except OSError:
            pass


def main():
    os.makedirs(SPOOL, exist_ok=True)
    log(f"agent started (pid {os.getpid()}) watching {SPOOL}")
    while True:
        try:
            entries = sorted(f for f in os.listdir(SPOOL) if f.endswith(".ready"))
        except OSError:
            entries = []
        for entry in entries:
            if claim(os.path.join(SPOOL, entry)):
                handle(entry[: -len(".ready")])
        time.sleep(0.5)


if __name__ == "__main__":
    main()
