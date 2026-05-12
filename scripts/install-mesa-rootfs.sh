#!/bin/bash
# install-mesa-rootfs.sh — Extract Mesa i386 EGL + swrast DRI driver into rootfs/
#
# Required for MapLibre GL Native HeadlessFrontend EGL pbuffer rendering.
# Without these, MapLibreItem falls back to placeholder grid at runtime.
#
# Packages extracted:
#   libegl-mesa0:i386      — libEGL_mesa.so.0 (Mesa EGL backend; GLVND split naming)
#   libgl1-mesa-dri:i386   — swrast_dri.so (software rasterizer DRI driver)
#   libgbm1:i386           — GBM (Generic Buffer Manager, needed by EGL)
#   libglapi-mesa:i386     — Mesa GL dispatch table
#
# On device, these land at:
#   /opt/nav/lib/libEGL_mesa.so.0.0.0  — real library
#   /opt/nav/lib/libEGL.so.1           → libEGL_mesa.so.0.0.0 (bypass GLVND on embedded)
#   /opt/nav/lib/libEGL.so             → libEGL.so.1
#   /opt/nav/lib/dri/swrast_dri.so     — loaded via LIBGL_DRIVERS_PATH
#
# NOTE: Ubuntu/Debian Bullseye+ uses GLVND split: libegl-mesa0 ships libEGL_mesa.so.0
#       (not libEGL.so.1). On a minimal embedded system without the GLVND loader,
#       we symlink libEGL.so.1 → libEGL_mesa.so.0.0.0 directly.
#
# Usage: ./scripts/install-mesa-rootfs.sh
# Idempotent — skips if swrast_dri.so already present.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
ROOTFS="$ROOT/rootfs"

DEBIAN_MIRROR="https://ftp.debian.org/debian"
DEBIAN_SUITE="bullseye"
TMP_DIR="/tmp/mesa-i386-debs"

echo "[install-mesa] Installing Mesa i386 EGL + swrast into rootfs/"

# ── Idempotency check ─────────────────────────────────────────────────────────
if [ -f "$ROOTFS/opt/nav/lib/dri/swrast_dri.so" ]; then
    echo "[install-mesa] swrast_dri.so already present — skipping"
    echo "[install-mesa] To force reinstall: rm $ROOTFS/opt/nav/lib/dri/swrast_dri.so"
    exit 0
fi

mkdir -p "$TMP_DIR"
mkdir -p "$ROOTFS/opt/nav/lib/dri"

# ── Package list ──────────────────────────────────────────────────────────────
PKGS="libegl-mesa0 libgl1-mesa-dri libgbm1 libglapi-mesa"

echo "[install-mesa] Resolving package URLs from Debian $DEBIAN_SUITE..."

docker run --rm \
    -v "$ROOT:/build" \
    -v "$TMP_DIR:/debs" \
    q60-toolchain \
    bash -c "
        set -e
        apt-get update -qq 2>/dev/null

        for pkg in $PKGS; do
            echo \"[install-mesa] Downloading \$pkg:i386...\"
            # Get the .deb path from apt
            apt-get download \"\${pkg}:i386\" 2>/dev/null || {
                echo \"  WARNING: \$pkg:i386 not available — skipping\"
                continue
            }
            deb=\$(ls \${pkg}*.deb 2>/dev/null | head -1)
            if [ -n \"\$deb\" ]; then
                mv \"\$deb\" /debs/
                echo \"  Downloaded: \$deb\"
            fi
        done

        # Extract into rootfs
        cd /debs
        for deb in *.deb; do
            [ -f \"\$deb\" ] || continue
            echo \"[install-mesa] Extracting \$deb...\"
            dpkg-deb --extract \"\$deb\" /build/rootfs/
        done

        # Move EGL + swrast to /opt/nav/lib for explicit LD_LIBRARY_PATH control
        # (avoids polluting system lib paths on the device)
        RLIB=/build/rootfs/usr/lib/i386-linux-gnu

        # GLVND split: libegl-mesa0 ships libEGL_mesa.so.0.0.0, not libEGL.so.1
        # On embedded (no GLVND loader), symlink directly: libEGL.so.1 → libEGL_mesa.so.0.0.0
        REGL=\$(find /build/rootfs/usr -name 'libEGL_mesa.so.0.0.0' -type f 2>/dev/null | head -1)
        if [ -n \"\$REGL\" ]; then
            cp \"\$REGL\" /build/rootfs/opt/nav/lib/libEGL_mesa.so.0.0.0
            ln -sf libEGL_mesa.so.0.0.0 /build/rootfs/opt/nav/lib/libEGL_mesa.so.0
            ln -sf libEGL_mesa.so.0.0.0 /build/rootfs/opt/nav/lib/libEGL.so.1
            ln -sf libEGL.so.1          /build/rootfs/opt/nav/lib/libEGL.so
            echo '  libEGL_mesa.so.0.0.0 + symlinks -> /opt/nav/lib/'
        elif [ -f \"\$RLIB/libEGL.so.1\" ]; then
            cp \"\$RLIB/libEGL.so.1\" /build/rootfs/opt/nav/lib/
            ln -sf libEGL.so.1 /build/rootfs/opt/nav/lib/libEGL.so
            echo '  libEGL.so.1 -> /opt/nav/lib/'
        fi

        if [ -f \"\$RLIB/libgbm.so.1\" ]; then
            cp \"\$RLIB/libgbm.so.1\" /build/rootfs/opt/nav/lib/
            ln -sf libgbm.so.1 /build/rootfs/opt/nav/lib/libgbm.so
            echo '  libgbm.so.1 -> /opt/nav/lib/'
        fi

        if [ -f \"\$RLIB/libglapi.so.0\" ]; then
            cp \"\$RLIB/libglapi.so.0\" /build/rootfs/opt/nav/lib/
            echo '  libglapi.so.0 -> /opt/nav/lib/'
        fi

        # swrast_dri.so — the actual software renderer
        SWRAST=\$(find /build/rootfs/usr -name 'swrast_dri.so' 2>/dev/null | head -1)
        if [ -n \"\$SWRAST\" ]; then
            cp \"\$SWRAST\" /build/rootfs/opt/nav/lib/dri/
            echo '  swrast_dri.so -> /opt/nav/lib/dri/'
        else
            echo '  WARNING: swrast_dri.so not found in extracted packages'
        fi
    "

echo ""
echo "[install-mesa] Verification:"
ls -lh "$ROOTFS/opt/nav/lib/libEGL"* 2>/dev/null || echo "  WARNING: libEGL not found"
ls -lh "$ROOTFS/opt/nav/lib/dri/swrast_dri.so" 2>/dev/null || echo "  WARNING: swrast_dri.so not found"

echo ""
echo "[install-mesa] Done. Rebuild rootfs image to include Mesa libs:"
echo "  ./scripts/package-rootfs.sh"
