#!/bin/bash
# Removes the Kuaimai / Hangzhou TaoYun "Tomato Print Manager" (番茄打印管家)
# app and its printer driver.
#
# None of it works with the Kmart/Anko Inkless A4 (MV-B530): that driver only
# prints over USB, and this printer's USB-C port is power-only. The MV-B530 is
# driven over Bluetooth by the TiMini CUPS driver instead, which shares nothing
# with these files.
#
#   sudo ./uninstall-kuaimai.sh          app + driver + prefs
#   sudo ./uninstall-kuaimai.sh --all    also delete the 165 MB installer DMG

set -u

if [ "$(id -u)" -ne 0 ]; then
    echo "Run with sudo." >&2
    exit 1
fi

OWNER="${SUDO_USER:-$(stat -f '%Su' /dev/console)}"
WITH_DMG=0
[ "${1:-}" = "--all" ] && WITH_DMG=1

APP="/Applications/番茄打印管家.app"
AGENT_PLIST="/Library/LaunchAgents/com.kuaimai.kmprtdrvsvc.plist"
KMSVC="/Users/Shared/kmsvc"
CTRL="/usr/local/bin/km-prt-drv-ctrl"
FILTER="/usr/libexec/cups/filter/km-raster-filter"
PPDS="/Library/Printers/PPDs/Contents/Resources"
PREFS="/Users/$OWNER/Library/Preferences/com.kuaimai.print.tomato.steward.plist"
DMG="/Users/$OWNER/Downloads/番茄打印管家.dmg"

remove() {
    if [ -e "$1" ]; then
        rm -rf "$1" && echo "  removed  $1"
    else
        echo "  absent   $1"
    fi
}

echo "==> stopping the driver service"
launchctl bootout "gui/$(id -u "$OWNER")/com.kuaimai.kmprtdrvsvc" 2>/dev/null \
    || launchctl unload "$AGENT_PLIST" 2>/dev/null || true
pkill -f "$KMSVC/km-prt-drv-service" 2>/dev/null && echo "  killed km-prt-drv-service" || echo "  service not running"

echo "==> removing persistence"
remove "$AGENT_PLIST"

echo "==> removing driver binaries"
remove "$KMSVC"
remove "$CTRL"
remove "$FILTER"

# Every file here was installed by this package: the filename set matches
# $KMSVC/PPDs exactly (88 files), and no CUPS queue references any of them.
echo "==> removing bundled PPDs"
if [ -d "$PPDS" ]; then
    n=$(find "$PPDS" -maxdepth 1 -name '*.ppd.gz' | wc -l | tr -d ' ')
    rm -f "$PPDS"/*.ppd.gz
    rmdir "$PPDS" "$(dirname "$PPDS")" 2>/dev/null || true
    echo "  removed  $n PPD files from $PPDS"
else
    echo "  absent   $PPDS"
fi

echo "==> removing the application"
remove "$APP"

echo "==> removing preferences"
remove "$PREFS"

if [ "$WITH_DMG" -eq 1 ]; then
    echo "==> removing the installer image"
    remove "$DMG"
else
    echo "==> keeping the installer DMG (pass --all to delete it):"
    [ -e "$DMG" ] && echo "     $DMG"
fi

echo "==> restarting cupsd so it forgets the removed filter"
launchctl kickstart -k system/org.cups.cupsd 2>/dev/null || killall -HUP cupsd 2>/dev/null || true
sleep 2

echo
echo "==> verifying"
for p in "$APP" "$AGENT_PLIST" "$KMSVC" "$CTRL" "$FILTER" "$PREFS"; do
    [ -e "$p" ] && echo "  STILL PRESENT: $p"
done
pgrep -f km-prt-drv-service >/dev/null && echo "  STILL RUNNING: km-prt-drv-service"
echo "  done"
echo
echo "==> our printer queue should be unaffected:"
lpstat -p Anko_Inkless_A4 -v Anko_Inkless_A4 2>&1 | sed 's/^/     /'
