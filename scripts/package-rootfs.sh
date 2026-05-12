#!/bin/bash
# package-rootfs.sh — Build ext4 rootfs image from rootfs/ directory
# Creates a 3GB image for writing to the DCU's slot B root partition.
#
# Size budget (approximate):
#   Qt6 i386 libs (essential only):  ~180MB
#   Valhalla service binary:          ~11MB
#   q60nav app binary + QML:          ~1MB
#   Valhalla routing tiles:          ~717MB
#   MapLibre vector tiles (mbtiles): ~464MB
#   Photon geocoder JAR + index:     ~700MB  (NC region, optional)
#   Base rootfs + misc:              ~50MB
#   Total (with Photon):            ~2.12GB  →  3GB image gives comfortable headroom
#
# Usage:
#   ./scripts/package-rootfs.sh          # default 3GB
#   ./scripts/package-rootfs.sh 4G       # override size
#
# Output: output/q60nav-rootfs.img
#
# To write to device (verify partition with 'diskutil list' first):
#   sudo dd if=output/q60nav-rootfs.img of=/dev/rdisk4s3 bs=4m status=progress
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
ROOTFS_DIR="$ROOT/rootfs"
OUTPUT="$ROOT/output/q60nav-rootfs.img"
APP_BUILD="$ROOT/output/app-build/bin"
VALHALLA_BIN="$ROOT/output/valhalla-i386/bin"
QT6_LIBS="$ROOT/output/qt6-i386/lib"
VECTOR_TILES="$ROOT/output/vector-tiles/nc.mbtiles"
ROUTING_TILES="$ROOT/output/valhalla-tiles"
SIZE_MB="${1:-3072}"   # default 3GB in MiB

echo "[package-rootfs] Building ${SIZE_MB}MiB ext4 rootfs image..."

# ── Verify required build artifacts ────────────────────────────────────────
MISSING=0
check() {
    if [ ! -e "$1" ]; then
        echo "  WARNING: $2 not found ($1)"
        MISSING=$((MISSING+1))
    else
        echo "  OK: $2"
    fi
}
check "$APP_BUILD/q60nav"               "q60nav binary (run build-app.sh)"
check "$VALHALLA_BIN/valhalla_service"  "valhalla_service (run Valhalla i386 build)"
check "$QT6_LIBS/libQt6Core.so.6"       "Qt6 i386 libs (run deps/build-qt6-i386.sh)"
check "$VECTOR_TILES"                   "vector tiles nc.mbtiles (run build-map-tiles.sh)"
check "$ROUTING_TILES/admins.db"        "routing tiles (run build-tiles.sh)"
check "$ROOT/output/photon-data"        "Photon geocoder data (run scripts/download-photon.sh)"
check "$ROOTFS_DIR/usr/bin/java"        "Java JRE in rootfs (run scripts/install-jre-rootfs.sh)"

if [ "$MISSING" -gt 0 ]; then
    echo ""
    echo "  $MISSING artifact(s) missing — image will be incomplete."
    echo "  Continuing anyway (image can be rebuilt once artifacts are ready)."
fi

# ── Create blank sparse image (host) ───────────────────────────────────────
# macOS has dd but not mkfs.ext4 — create the sparse file here, format + populate
# inside Docker where ext4 tools are available.
echo ""
echo "[package-rootfs] Creating ${SIZE_MB}MiB sparse image file..."
dd if=/dev/zero of="$OUTPUT" bs=1M count=0 seek="${SIZE_MB}" 2>/dev/null
echo "[package-rootfs] Sparse file created ($(ls -lh "$OUTPUT" | awk '{print $5}'))"

# ── Format + populate inside Docker ────────────────────────────────────────
echo "[package-rootfs] Formatting ext4 + populating via Docker (privileged)..."

docker run --rm --privileged \
    -v "$ROOT:/build" \
    -v "$OUTPUT:/image.img" \
    q60-toolchain \
    bash -c "
        set -e

        # Format inside container (mkfs.ext4 not available on macOS host)
        mkfs.ext4 -L q60nav -F /image.img
        echo '[package-rootfs] ext4 formatted'

        MOUNT=\$(mktemp -d)
        mount -o loop /image.img \$MOUNT
        echo '[package-rootfs] Mounted at '\$MOUNT

        # ── Base rootfs skeleton ───────────────────────────────────────────
        cp -a /build/rootfs/. \$MOUNT/
        echo '  rootfs skeleton copied'

        # ── q60nav app binary ──────────────────────────────────────────────
        if [ -f /build/output/app-build/bin/q60nav ]; then
            mkdir -p \$MOUNT/opt/nav/bin
            cp /build/output/app-build/bin/q60nav \$MOUNT/opt/nav/bin/q60nav
            chmod 755 \$MOUNT/opt/nav/bin/q60nav
            echo '  q60nav binary copied'
        fi

        # ── QML source files (interpreted at runtime, NO_CACHEGEN build) ──
        mkdir -p \$MOUNT/opt/nav/qml
        cp -r /build/app/src/qml/. \$MOUNT/opt/nav/qml/
        echo '  QML files copied'

        # ── Valhalla service binary ────────────────────────────────────────
        if [ -f /build/output/valhalla-i386/bin/valhalla_service ]; then
            mkdir -p \$MOUNT/opt/valhalla/bin
            cp /build/output/valhalla-i386/bin/valhalla_service \$MOUNT/opt/valhalla/bin/
            chmod 755 \$MOUNT/opt/valhalla/bin/valhalla_service
            echo '  valhalla_service copied'
        fi

        # ── Valhalla routing tiles ─────────────────────────────────────────
        if [ -d /build/output/valhalla-tiles ] && [ -f /build/output/valhalla-tiles/admins.db ]; then
            mkdir -p \$MOUNT/opt/valhalla/tiles
            cp -r /build/output/valhalla-tiles/. \$MOUNT/opt/valhalla/tiles/
            echo '  routing tiles copied'
        fi

        # ── Photon offline geocoder ────────────────────────────────────────
        if [ -d /build/output/photon-data/photon_data ] && [ -f /build/output/photon-data/photon.jar ]; then
            mkdir -p \$MOUNT/opt/photon
            cp /build/output/photon-data/photon.jar \$MOUNT/opt/photon/
            cp -r /build/output/photon-data/photon_data/. \$MOUNT/opt/photon/photon_data/
            echo '  Photon geocoder JAR + data copied'
        else
            echo '  WARNING: Photon data not found — geocoder will be unavailable'
            echo '           Run scripts/download-photon.sh to build it'
        fi

        # ── MapLibre vector tiles ──────────────────────────────────────────
        if [ -f /build/output/vector-tiles/nc.mbtiles ]; then
            mkdir -p \$MOUNT/opt/nav/tiles
            cp /build/output/vector-tiles/nc.mbtiles \$MOUNT/opt/nav/tiles/
            echo '  nc.mbtiles copied'
        fi

        # ── Qt6 i386 shared libraries (essential subset) ───────────────────
        # Only copy libs actually needed by q60nav to keep image lean.
        # Full list: Core Gui Quick QuickControls2 Network Qml Positioning
        # Plus: OpenGL, QmlModels, QmlIntegration (transitive deps)
        if [ -d /build/output/qt6-i386/lib ]; then
            mkdir -p \$MOUNT/usr/lib/i386-linux-gnu
            for lib in \
                libQt6Core libQt6Gui libQt6Quick libQt6QuickControls2 \
                libQt6Network libQt6Qml libQt6QmlModels libQt6Positioning \
                libQt6OpenGL libQt6WaylandClient libQt6WaylandCompositor \
                libQt6XkbCommonSupport libQt6EglSupport \
                libicui18n libicuuc libicudata \
                libdouble-conversion libpcre2-16; do
                find /build/output/qt6-i386/lib -name \"\${lib}.so.*\" -not -name '*.debug' \
                    | head -3 | xargs -I{} cp -n {} \$MOUNT/usr/lib/i386-linux-gnu/ 2>/dev/null || true
            done
            # Qt platform plugins (wayland + eglfs)
            mkdir -p \$MOUNT/usr/lib/i386-linux-gnu/qt6/plugins/platforms
            find /build/output/qt6-i386/plugins/platforms -name '*.so' 2>/dev/null \
                | xargs -I{} cp {} \$MOUNT/usr/lib/i386-linux-gnu/qt6/plugins/platforms/ 2>/dev/null || true
            # Qt QML imports (Quick, Controls)
            mkdir -p \$MOUNT/usr/lib/i386-linux-gnu/qt6/qml
            cp -r /build/output/qt6-i386/qml/QtQuick \
                  \$MOUNT/usr/lib/i386-linux-gnu/qt6/qml/ 2>/dev/null || true
            cp -r /build/output/qt6-i386/qml/QtQuick/Controls \
                  \$MOUNT/usr/lib/i386-linux-gnu/qt6/qml/QtQuick/ 2>/dev/null || true
            echo '  Qt6 libs + plugins copied'
        fi

        # ── Essential device nodes ─────────────────────────────────────────
        mkdir -p \$MOUNT/dev
        mknod \$MOUNT/dev/console c 5 1 2>/dev/null || true
        mknod \$MOUNT/dev/null    c 1 3 2>/dev/null || true
        mknod \$MOUNT/dev/urandom c 1 9 2>/dev/null || true
        mknod \$MOUNT/dev/random  c 1 8 2>/dev/null || true
        mknod \$MOUNT/dev/tty     c 5 0 2>/dev/null || true

        # ── Permissions ────────────────────────────────────────────────────
        chmod 755 \$MOUNT/etc/init.d/*   2>/dev/null || true
        chmod 755 \$MOUNT/opt/nav/*.sh   2>/dev/null || true
        chmod 755 \$MOUNT/opt/valhalla/*.sh 2>/dev/null || true
        chmod 755 \$MOUNT/etc/rc         2>/dev/null || true

        # ── Size summary ───────────────────────────────────────────────────
        echo ''
        echo '--- Image contents ---'
        du -sh \$MOUNT/opt/nav/bin    2>/dev/null || true
        du -sh \$MOUNT/opt/nav/tiles  2>/dev/null || true
        du -sh \$MOUNT/opt/valhalla   2>/dev/null || true
        du -sh \$MOUNT/opt/photon     2>/dev/null || true
        du -sh \$MOUNT/usr/lib        2>/dev/null || true
        echo '--- Disk usage ---'
        df -h \$MOUNT

        umount \$MOUNT
        rmdir \$MOUNT
        echo '[package-rootfs] Image populated and unmounted'
    "

ls -lh "$OUTPUT"
echo ""
echo "[package-rootfs] Done: $OUTPUT"
echo ""
echo "Next steps:"
echo "  1. Verify image:  scripts/deploy-to-image.sh --verify"
echo "  2. Write to DCU:  sudo dd if=$OUTPUT of=/dev/rdisk4s3 bs=4m status=progress"
echo "     (verify partition with 'diskutil list' before writing)"
