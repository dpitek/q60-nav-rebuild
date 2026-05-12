#!/bin/bash
# package-rootfs.sh — Build ext4 rootfs image from rootfs/ directory
# Creates a 1GB image suitable for writing to mmcblk0p3 (slot B root)
#
# Usage:
#   ./scripts/package-rootfs.sh [--size 1G]
#
# Output: /Users/dpitek/q60-rebuild/output/q60nav-rootfs.img
#
# To write to device:
#   sudo dd if=output/q60nav-rootfs.img of=/dev/[disk]s3 bs=4M status=progress
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
ROOTFS_DIR="$ROOT/rootfs"
OUTPUT="$ROOT/output/q60nav-rootfs.img"
APP_BUILD="$ROOT/output/app-build"
VALHALLA_BIN="$ROOT/output/valhalla-i386/bin"
QT6_LIBS="$ROOT/output/qt6-i386/lib"
MAPLIBRE_LIBS="$ROOT/output/maplibre-i386/lib"
SIZE="${1:-1G}"

echo "[package-rootfs] Building ${SIZE} ext4 rootfs image..."

# ── Verify required build artifacts ────────────────────────────────────────
MISSING=0
if [ ! -f "$APP_BUILD/q60nav" ]; then
    echo "  WARNING: q60nav binary not found — run build-app.sh first"
    MISSING=$((MISSING+1))
fi
if [ ! -f "$VALHALLA_BIN/valhalla_service" ]; then
    echo "  WARNING: valhalla_service not found — run Valhalla i386 build first"
    MISSING=$((MISSING+1))
fi
if [ $MISSING -gt 0 ]; then
    echo "  Creating image with available artifacts (${MISSING} missing)"
fi

# ── Create blank image ──────────────────────────────────────────────────────
echo "[package-rootfs] Creating ${SIZE} blank image..."
dd if=/dev/zero of="$OUTPUT" bs=1M count=0 seek=1024 status=none
mkfs.ext4 -L q60nav -F "$OUTPUT"
echo "[package-rootfs] ext4 formatted"

# ── Mount and populate ──────────────────────────────────────────────────────
MOUNT=$(mktemp -d)
echo "[package-rootfs] Mounting at $MOUNT..."

# macOS: use hdiutil; Linux: use mount -o loop
if [ "$(uname)" = "Darwin" ]; then
    # macOS can't mount ext4 natively — use Docker for population
    echo "[package-rootfs] macOS detected — using Docker to populate ext4 image"

    docker run --rm --privileged \
        -v "$ROOT:/build" \
        -v "$OUTPUT:/image.img" \
        q60-toolchain \
        bash -c "
            set -e
            MOUNT=\$(mktemp -d)
            mount -o loop /image.img \$MOUNT

            # Copy base rootfs
            cp -a /build/rootfs/. \$MOUNT/

            # Copy q60nav binary
            [ -f /build/output/app-build/q60nav ] && \
                cp /build/output/app-build/q60nav \$MOUNT/opt/nav/bin/q60nav

            # Copy QML files
            cp -r /build/app/src/qml/. \$MOUNT/opt/nav/qml/

            # Copy Valhalla service binary
            [ -f /build/output/valhalla-i386/bin/valhalla_service ] && \
                cp /build/output/valhalla-i386/bin/valhalla_service \$MOUNT/opt/valhalla/bin/

            # Copy Qt6 shared libs (stripped, i386)
            if [ -d /build/output/qt6-i386/lib ]; then
                mkdir -p \$MOUNT/usr/lib
                find /build/output/qt6-i386/lib -name 'libQt6*.so.*' \
                    | head -20 \
                    | xargs -I{} cp {} \$MOUNT/usr/lib/
            fi

            # Create essential device nodes
            mkdir -p \$MOUNT/dev
            mknod \$MOUNT/dev/console c 5 1 2>/dev/null || true
            mknod \$MOUNT/dev/null    c 1 3 2>/dev/null || true
            mknod \$MOUNT/dev/urandom c 1 9 2>/dev/null || true
            mknod \$MOUNT/dev/random  c 1 8 2>/dev/null || true

            # Set permissions
            chmod 755 \$MOUNT/etc/init.d/* 2>/dev/null || true
            chmod 755 \$MOUNT/opt/nav/*.sh  2>/dev/null || true
            chmod 755 \$MOUNT/etc/rc        2>/dev/null || true

            # Size check
            df -h \$MOUNT
            umount \$MOUNT
            rmdir \$MOUNT
        "
else
    # Linux: direct mount
    sudo mount -o loop "$OUTPUT" "$MOUNT"
    sudo cp -a "$ROOTFS_DIR/." "$MOUNT/"
    [ -f "$APP_BUILD/q60nav" ] && sudo cp "$APP_BUILD/q60nav" "$MOUNT/opt/nav/bin/"
    sudo cp -r "$ROOT/app/src/qml/." "$MOUNT/opt/nav/qml/"
    df -h "$MOUNT"
    sudo umount "$MOUNT"
    rmdir "$MOUNT"
fi

ls -lh "$OUTPUT"
echo "[package-rootfs] Done: $OUTPUT"
echo ""
echo "To write to eMMC slot B (replace disk4s3 with your device):"
echo "  sudo dd if=$OUTPUT of=/dev/disk4s3 bs=4M status=progress"
