#!/bin/bash
# package-rootfs-worktree.sh — Build rootfs image from a git worktree, reusing
# the main worktree's heavy artifacts (Qt6 libs, Valhalla tiles, vector tiles,
# geocoder DB, mesa libs, JRE). Worktree contributes the updated q60nav binary,
# QML, and any rootfs overlays.
set -e

WORKTREE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN_ROOT="/Users/dpitek/Developer/q60-rebuild"
OUTPUT="$WORKTREE_ROOT/output/q60nav-rootfs.img"
SIZE_MB="${1:-3072}"

# Worktree-built binary takes precedence; fall back to main worktree's.
if [ -f "$WORKTREE_ROOT/output/app-build/bin/q60nav" ]; then
    APP_BIN="$WORKTREE_ROOT/output/app-build/bin/q60nav"
elif [ -f "$MAIN_ROOT/output/app-build/bin/q60nav" ]; then
    APP_BIN="$MAIN_ROOT/output/app-build/bin/q60nav"
else
    echo "ERROR: no q60nav binary found — run build-app-worktree.sh first"
    exit 1
fi

mkdir -p "$WORKTREE_ROOT/output"

echo "[package-rootfs-worktree] Worktree:  $WORKTREE_ROOT"
echo "[package-rootfs-worktree] Main repo: $MAIN_ROOT"
echo "[package-rootfs-worktree] Binary:    $APP_BIN"
echo "[package-rootfs-worktree] Image:     $OUTPUT  (${SIZE_MB} MiB)"

echo "[package-rootfs-worktree] Creating sparse image..."
dd if=/dev/zero of="$OUTPUT" bs=1M count=0 seek="${SIZE_MB}" 2>/dev/null

docker run --rm --privileged \
    -v "$WORKTREE_ROOT:/build" \
    -v "$MAIN_ROOT/output:/build-shared/output:ro" \
    -v "$MAIN_ROOT/rootfs:/build-shared/rootfs:ro" \
    -v "$OUTPUT:/image.img" \
    q60-toolchain \
    bash -c "
        set -e
        mkfs.ext4 -L q60nav -F /image.img
        echo '[package-rootfs-worktree] ext4 formatted'

        MOUNT=\$(mktemp -d)
        mount -o loop /image.img \$MOUNT

        # 1) Base rootfs skeleton from MAIN (full /usr, /lib, /bin, JRE, mesa).
        echo '[package-rootfs-worktree] Layering MAIN rootfs base...'
        cp -a /build-shared/rootfs/. \$MOUNT/

        # 2) Overlay worktree's rootfs/ (etc/, opt/nav/style, opt/valhalla,
        #    opt/geocoder, anything else we customized). This is the worktree's
        #    chance to win for any file it also defines.
        echo '[package-rootfs-worktree] Overlaying worktree rootfs/...'
        cp -a /build/rootfs/. \$MOUNT/

        # 3) q60nav binary — the worktree's freshly built one.
        echo '[package-rootfs-worktree] Installing q60nav binary...'
        mkdir -p \$MOUNT/opt/nav/bin
        cp /build/output/app-build/bin/q60nav \$MOUNT/opt/nav/bin/q60nav
        chmod 755 \$MOUNT/opt/nav/bin/q60nav

        # 4) QML — worktree's qml/ (includes new keyboard / dest search /
        #    route preview / vehicle settings).
        echo '[package-rootfs-worktree] Installing QML...'
        rm -rf \$MOUNT/opt/nav/qml
        mkdir -p \$MOUNT/opt/nav/qml
        cp -r /build/app/src/qml/. \$MOUNT/opt/nav/qml/

        # 5) Heavy artifacts from MAIN — Qt libs, Valhalla service + tiles,
        #    vector tiles, geocoder DB. These haven't changed; mounted RO.
        echo '[package-rootfs-worktree] Installing Valhalla service + tiles...'
        if [ -f /build-shared/output/valhalla-i386/bin/valhalla_service ]; then
            mkdir -p \$MOUNT/opt/valhalla/bin
            cp /build-shared/output/valhalla-i386/bin/valhalla_service \$MOUNT/opt/valhalla/bin/
            chmod 755 \$MOUNT/opt/valhalla/bin/valhalla_service
        fi
        if [ -d /build-shared/output/valhalla-tiles ]; then
            mkdir -p \$MOUNT/opt/valhalla/tiles
            cp -r /build-shared/output/valhalla-tiles/. \$MOUNT/opt/valhalla/tiles/
        fi

        echo '[package-rootfs-worktree] Installing geocoder DB...'
        if [ -f /build-shared/output/geocoder/places.db ]; then
            mkdir -p \$MOUNT/opt/geocoder
            cp /build-shared/output/geocoder/places.db \$MOUNT/opt/geocoder/places.db
        fi

        echo '[package-rootfs-worktree] Installing vector tiles...'
        if [ -f /build-shared/output/vector-tiles/nc.mbtiles ]; then
            mkdir -p \$MOUNT/opt/nav/tiles
            cp /build-shared/output/vector-tiles/nc.mbtiles \$MOUNT/opt/nav/tiles/
        fi

        echo '[package-rootfs-worktree] Installing Qt6 libs + plugins...'
        if [ -d /build-shared/output/qt6-i386/lib ]; then
            mkdir -p \$MOUNT/usr/lib/i386-linux-gnu
            for lib in libQt6Core libQt6Gui libQt6Quick libQt6QuickControls2 \
                       libQt6Network libQt6Qml libQt6QmlModels libQt6Positioning \
                       libQt6OpenGL libQt6WaylandClient libQt6WaylandCompositor \
                       libicui18n libicuuc libicudata libdouble-conversion libpcre2-16; do
                find /build-shared/output/qt6-i386/lib -name \"\${lib}.so.*\" -not -name '*.debug' \
                    | head -3 | xargs -I{} cp -n {} \$MOUNT/usr/lib/i386-linux-gnu/ 2>/dev/null || true
            done
            mkdir -p \$MOUNT/usr/lib/i386-linux-gnu/qt6/plugins/platforms
            find /build-shared/output/qt6-i386/plugins/platforms -name '*.so' 2>/dev/null \
                | xargs -I{} cp {} \$MOUNT/usr/lib/i386-linux-gnu/qt6/plugins/platforms/ 2>/dev/null || true
            mkdir -p \$MOUNT/usr/lib/i386-linux-gnu/qt6/qml
            cp -r /build-shared/output/qt6-i386/qml/QtQuick \
                  \$MOUNT/usr/lib/i386-linux-gnu/qt6/qml/ 2>/dev/null || true
        fi

        # 6) libsqlite3 for geocoder-server
        SQLITE_FOUND=\$(find /usr/lib/i386-linux-gnu /lib/i386-linux-gnu \
            -maxdepth 2 -name 'libsqlite3.so.0*' -not -name '*.debug' 2>/dev/null | head -1)
        if [ -n \"\$SQLITE_FOUND\" ]; then
            mkdir -p \$MOUNT/usr/lib/i386-linux-gnu
            cp \"\$SQLITE_FOUND\" \$MOUNT/usr/lib/i386-linux-gnu/ 2>/dev/null
            SQLITE_BASE=\${SQLITE_FOUND##*/}
            ln -sf \"\$SQLITE_BASE\" \$MOUNT/usr/lib/i386-linux-gnu/libsqlite3.so.0 2>/dev/null
        fi

        # 7) Essential device nodes
        mknod \$MOUNT/dev/console c 5 1 2>/dev/null || true
        mknod \$MOUNT/dev/null    c 1 3 2>/dev/null || true
        mknod \$MOUNT/dev/zero    c 1 5 2>/dev/null || true
        mknod \$MOUNT/dev/random  c 1 8 2>/dev/null || true
        mknod \$MOUNT/dev/urandom c 1 9 2>/dev/null || true

        # 8) Summary
        echo ''
        echo '[package-rootfs-worktree] Image contents:'
        du -sh \$MOUNT/opt/nav   \$MOUNT/opt/valhalla \$MOUNT/opt/geocoder \\
                \$MOUNT/usr      2>/dev/null | sort -hr | head
        df -h /image.img

        umount \$MOUNT
        echo '[package-rootfs-worktree] Image built.'
    "

echo ""
echo "[package-rootfs-worktree] Done. Image: $OUTPUT"
ls -lh "$OUTPUT"
