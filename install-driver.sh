#!/bin/bash
# Installs the CUPS side of the Anko Inkless A4 (MV-B530) driver.
# Run with sudo:  sudo ./install-driver.sh
#
# Installs three things:
#   1. a spool directory writable by cupsd's _lp user and by you
#   2. the "timini" CUPS backend
#   3. a print queue named Anko_Inkless_A4
#
# It does NOT install any auto-start item. The print agent is started
# separately (see README).

set -eu

OWNER="${SUDO_USER:-$(stat -f '%Su' /dev/console)}"
BASE="/Users/$OWNER/Library/Application Support/TiMiniPrint"
SPOOL="/usr/local/var/spool/timini"
BACKEND="/usr/libexec/cups/backend/timini"
QUEUE="Anko_Inkless_A4"

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run with sudo." >&2
    exit 1
fi

echo "==> installing for user: $OWNER"

echo "==> spool directory: $SPOOL"
mkdir -p "$SPOOL"
chown "$OWNER":_lp "$SPOOL"
chmod 770 "$SPOOL"

echo "==> backend: $BACKEND"
install -o root -g wheel -m 0755 "$BASE/timini-backend.sh" "$BACKEND"

echo "==> restarting cupsd so it picks up the backend"
launchctl kickstart -k system/org.cups.cupsd 2>/dev/null || killall -HUP cupsd 2>/dev/null || true
sleep 2

echo "==> creating queue: $QUEUE"
lpadmin -p "$QUEUE" -E -v "timini:/mv_b530" -P "$BASE/timini.ppd" -o printer-is-shared=false
lpoptions -d "$QUEUE" >/dev/null 2>&1 || true
cupsenable "$QUEUE" 2>/dev/null || true
cupsaccept "$QUEUE" 2>/dev/null || true

echo
echo "==> done"
lpstat -p "$QUEUE" -v "$QUEUE" || true
echo
echo "The queue is installed. The print agent must be running for jobs to"
echo "actually reach the printer - see README.md."
