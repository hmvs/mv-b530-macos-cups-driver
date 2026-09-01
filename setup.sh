#!/bin/bash
# User-side setup: dependencies + the Bluetooth-capable runner bundle.
# Run WITHOUT sudo.  Then run:  sudo ./install-driver.sh

set -euo pipefail

BASE="$HOME/Library/Application Support/TiMiniPrint"
SRC="$(cd "$(dirname "$0")" && pwd)"
REPO="$BASE/TiMini-Print"
APP="$BASE/TiMiniRunner.app"

if [ "$(id -u)" -eq 0 ]; then
    echo "Run this WITHOUT sudo." >&2
    exit 1
fi

command -v python3 >/dev/null || { echo "python3 not found" >&2; exit 1; }
command -v git >/dev/null || { echo "git not found" >&2; exit 1; }

PREFIX=$(python3 -c 'import sys; print(sys.base_prefix)')
STUB="$PREFIX/Resources/Python.app/Contents/MacOS/Python"
PYVER=$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')

if [ ! -x "$STUB" ]; then
    echo "ERROR: framework Python stub not found at:" >&2
    echo "  $STUB" >&2
    echo "A framework build of Python is required (e.g. 'brew install python')." >&2
    exit 1
fi

echo "==> base: $BASE"
mkdir -p "$BASE"

# TiMini-Print is vendored as a submodule pinned to a known-good commit, so a
# fresh install cannot be broken by an upstream change.
VENDOR="$SRC/vendor/TiMini-Print"
if [ ! -f "$VENDOR/requirements.txt" ]; then
    echo "==> initialising the TiMini-Print submodule"
    git -C "$SRC" submodule update --init --depth 1 vendor/TiMini-Print || true
fi
if [ ! -f "$VENDOR/requirements.txt" ]; then
    echo "ERROR: vendor/TiMini-Print is empty. Run:" >&2
    echo "  git submodule update --init --recursive" >&2
    exit 1
fi

echo "==> installing TiMini-Print $(git -C "$VENDOR" rev-parse --short HEAD 2>/dev/null || echo pinned)"
rm -rf "$REPO"
mkdir -p "$REPO"
tar -C "$VENDOR" --exclude .git -cf - . | tar -C "$REPO" -xf -

echo "==> virtualenv + dependencies"
python3 -m venv "$REPO/.venv"
"$REPO/.venv/bin/python" -m pip install --quiet --upgrade pip
"$REPO/.venv/bin/python" -m pip install --quiet -r "$REPO/requirements.txt"
"$REPO/.venv/bin/python" -c 'import bleak, PIL, pypdfium2, objc' \
    && echo "    dependencies ok"

# A bare interpreter is killed by TCC the instant it touches Bluetooth. Running
# it from inside a bundle that declares NSBluetoothAlwaysUsageDescription is
# what makes Bluetooth access possible at all.
echo "==> building TiMiniRunner.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$STUB" "$APP/Contents/MacOS/Python"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Python</string>
  <key>CFBundleIdentifier</key><string>local.timini.runner</string>
  <key>CFBundleName</key><string>TiMiniRunner</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>NSBluetoothAlwaysUsageDescription</key><string>Connects to the thermal printer over Bluetooth to print documents.</string>
  <key>NSBluetoothPeripheralUsageDescription</key><string>Connects to the thermal printer over Bluetooth to print documents.</string>
</dict></plist>
PLIST
codesign --force -s - "$APP"

echo "==> installing driver files"
cp "$SRC/agent.py" "$SRC/timini.ppd" "$SRC/timini-backend.sh" "$BASE/"

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$APP" 2>/dev/null || true

cat <<EOF

==> done

PYTHONHOME for the agent:
  $PREFIX

Next:
  1. sudo $SRC/install-driver.sh
  2. open -g "$APP" --args "$BASE/agent.py"      # approve the Bluetooth prompt
  3. print to "Anko_Inkless_A4" from any app
EOF
