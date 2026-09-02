#!/bin/bash
# Builds a static, universal libpappl.a for linking into the printer app.
#
# PAPPL is not packaged for Homebrew, so it is vendored as a submodule and
# built here. Two deliberate reductions:
#
#   - PKG_CONFIG_LIBDIR is restricted to OpenSSL, so PAPPL's libusb-backed USB
#     device scheme is compiled out. A BLE printer never uses it, and it would
#     otherwise become a runtime dependency.
#   - libpng and libjpeg are disabled: those are for PAPPL's direct PNG/JPEG
#     print paths, and everything reaches us as raster from cupsd anyway.
#
# TLS is not optional in PAPPL, hence OpenSSL.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/vendor/pappl"
OPENSSL="${OPENSSL_PREFIX:-/opt/homebrew/opt/openssl@3}"

if [ ! -f "$SRC/configure" ] && [ ! -f "$SRC/configure.ac" ]; then
    echo "vendor/pappl is empty - run: git submodule update --init --recursive" >&2
    exit 1
fi
if [ ! -d "$OPENSSL" ]; then
    echo "OpenSSL not found at $OPENSSL" >&2
    echo "install it (brew install openssl@3) or set OPENSSL_PREFIX" >&2
    exit 1
fi

cd "$SRC"
if [ ! -f configure ]; then
    autoconf -f
fi

if [ ! -f Makedefs ] || [ ! -f pappl/libpappl.a ]; then
    PKG_CONFIG_LIBDIR="$OPENSSL/lib/pkgconfig" \
        ./configure --with-tls=openssl --with-dnssd=mdnsresponder \
                    --disable-shared --disable-libjpeg --disable-libpng
fi

make -C pappl -j"$(sysctl -n hw.ncpu)"

echo
echo "built: $SRC/pappl/libpappl.a"
lipo -info "$SRC/pappl/libpappl.a"
