#!/bin/bash
# build-geocoder-server.sh — Compile geocoder-server for i386 inside q60-toolchain
#
# Produces: output/geocoder/geocoder-server  (ELF 32-bit, Intel 80386)
# Copies to: rootfs/opt/geocoder/bin/geocoder-server
#
# Requires:
#   - Docker running
#   - q60-toolchain image built (./Dockerfile.toolchain)
#   - rootfs/opt/geocoder/geocoder.c present
#
# Usage:
#   ./scripts/build-geocoder-server.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
SRC="$ROOT/rootfs/opt/geocoder/geocoder.c"
OUT_DIR="$ROOT/output/geocoder"
OUT_BIN="$OUT_DIR/geocoder-server"
ROOTFS_BIN="$ROOT/rootfs/opt/geocoder/bin/geocoder-server"

# ── Preflight ──────────────────────────────────────────────────────────────

echo "[build-geocoder-server] Checking prerequisites..."

if [ ! -f "$SRC" ]; then
    echo "ERROR: Source not found: $SRC"
    exit 1
fi

docker info >/dev/null 2>&1 || { echo "ERROR: Docker not running"; exit 1; }

docker image inspect q60-toolchain >/dev/null 2>&1 || {
    echo "ERROR: Docker image 'q60-toolchain' not found."
    echo "       Build it first: docker build -t q60-toolchain -f Dockerfile.toolchain ."
    exit 1
}

mkdir -p "$OUT_DIR"
mkdir -p "$(dirname "$ROOTFS_BIN")"

echo "[build-geocoder-server] Compiling geocoder-server for i386 (Bonnell)..."

# ── Compile inside q60-toolchain ──────────────────────────────────────────

docker run --rm \
    -v "$ROOT:/build" \
    q60-toolchain \
    bash -c "
        set -e

        echo '[container] Installing libsqlite3-dev:i386 ...'
        dpkg --add-architecture i386 2>/dev/null || true
        apt-get update -qq 2>/dev/null || true
        apt-get install -y --no-install-recommends libsqlite3-dev:i386 2>/dev/null || true

        # Verify sqlite3 header is available
        if [ ! -f /usr/include/sqlite3.h ] && [ ! -f /usr/include/i386-linux-gnu/sqlite3.h ]; then
            echo 'WARNING: sqlite3.h not found in standard paths — checking sysroot...'
            find /usr -name 'sqlite3.h' 2>/dev/null | head -5 || true
        fi

        echo '[container] Compiling...'
        gcc -m32 -march=i686 -mtune=bonnell -O2 \
            -o /build/output/geocoder/geocoder-server \
            /build/rootfs/opt/geocoder/geocoder.c \
            -lsqlite3 -lpthread \
            -Wall -Wextra \
            -std=c99

        echo '[container] Verifying ELF type...'
        file /build/output/geocoder/geocoder-server
        echo '[container] Done.'
    "

# ── Copy to rootfs ─────────────────────────────────────────────────────────

cp "$OUT_BIN" "$ROOTFS_BIN"
chmod 755 "$ROOTFS_BIN"

echo ""
echo "[build-geocoder-server] Binary verified:"
file "$OUT_BIN"
ls -lh "$OUT_BIN"
echo ""
echo "[build-geocoder-server] Copied to $ROOTFS_BIN"
echo ""
echo "Next step: ./scripts/package-rootfs.sh"
