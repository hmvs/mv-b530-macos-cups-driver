#!/bin/bash
# Assembles "Anko Inkless A4.app" around the built binary.
#
# A real bundle rather than a bare binary buys three things:
#
#   - Finder installation. Drag to Applications, double-click, done - no
#     terminal, no make.
#   - A normal Info.plist instead of a __TEXT,__info_plist section, so the
#     Bluetooth usage description is declared the way macOS expects.
#   - Login-item registration through SMAppService, which puts the app in
#     System Settings > General > Login Items where it can be turned off,
#     instead of a LaunchAgent the user never sees.
#
# The printer itself is then added through System Settings > Printers, because
# the app advertises over DNS-SD as an IPP Everywhere device.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BINDIR="${BINDIR:-$ROOT/.build/release}"
OUT="${OUT:-$ROOT/.build/Anko Inkless A4.app}"
BUNDLE_ID="org.hmvs.mvb530"

if [ ! -x "$BINDIR/mvb530-printer-app" ]; then
    echo "build it first: make build" >&2
    exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"

cp "$BINDIR/mvb530-printer-app" "$OUT/Contents/MacOS/Anko Inkless A4"

# PAPPL's menu bar item is a copy of the application icon, so without one the
# menu bar shows an empty square. Regenerate with: swift scripts/make-icon.swift
cp "$ROOT/packaging/AppIcon.icns" "$OUT/Contents/Resources/AppIcon.icns"

cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Anko Inkless A4</string>
    <key>CFBundleDisplayName</key>
    <string>Anko Inkless A4</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>
    <string>Anko Inkless A4</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>

    <!-- Menu bar only: PAPPL puts a status item there, and a Dock icon for a
         background print service would be noise. -->
    <key>LSUIElement</key>
    <true/>

    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>Sends print jobs to your Anko Inkless A4 thermal printer over Bluetooth.</string>
    <key>NSBluetoothPeripheralUsageDescription</key>
    <string>Sends print jobs to your Anko Inkless A4 thermal printer over Bluetooth.</string>
</dict>
</plist>
PLIST

# The identity TCC keys the Bluetooth grant against. A Developer ID signature
# would go here for distribution; ad-hoc is enough to run locally.
codesign --force --sign - --identifier "$BUNDLE_ID" "$OUT" >/dev/null 2>&1

echo "built: $OUT"
codesign -dv "$OUT" 2>&1 | grep -E 'Identifier|Signature' | sed 's/^/  /'
