#!/bin/bash
# Starts the print agent inside TiMiniRunner.app.
#
# It must go through LaunchServices (`open`) rather than being exec'd directly:
# a shell-spawned process inherits the terminal's TCC responsibility and gets
# refused Bluetooth. Launched this way the bundle is its own responsible
# process, so its NSBluetoothAlwaysUsageDescription applies.

set -euo pipefail

BASE="$HOME/Library/Application Support/TiMiniPrint"
APP="$BASE/TiMiniRunner.app"

[ -d "$APP" ] || { echo "TiMiniRunner.app missing - run ./setup.sh first" >&2; exit 1; }

if pgrep -f "TiMiniPrint/agent.py" >/dev/null 2>&1; then
    echo "agent already running (pid $(pgrep -f 'TiMiniPrint/agent.py' | tr '\n' ' '))"
    exit 0
fi

export PYTHONHOME="$(python3 -c 'import sys; print(sys.base_prefix)')"
open -g "$APP" --args "$BASE/agent.py"
sleep 2

if pgrep -f "TiMiniPrint/agent.py" >/dev/null 2>&1; then
    echo "agent started. log: $BASE/agent.log"
else
    echo "agent failed to start - check $BASE/agent.log" >&2
    exit 1
fi
