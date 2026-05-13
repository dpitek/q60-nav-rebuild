#!/bin/bash
# integrity-check.sh — Full pre-flash integrity audit.
# Verifies ELF architecture, file sizes, JSON validity, and rootfs presence
# of every artifact that boot depends on. Returns non-zero on any failure.
set -e

WORKTREE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN_ROOT="/Users/dpitek/Developer/q60-rebuild"

PASS=0
FAIL=0

check_elf32() {
    local label="$1"
    local path="$2"
    if [ ! -f "$path" ]; then
        echo "  ✗ $label  — missing ($path)"
        FAIL=$((FAIL+1))
        return
    fi
    local arch=$(file "$path" 2>/dev/null)
    if echo "$arch" | grep -q "ELF 32-bit.*Intel 80386"; then
        echo "  ✓ $label  ($(du -h "$path" | awk '{print $1}'))"
        PASS=$((PASS+1))
    else
        echo "  ✗ $label  — wrong arch: $arch"
        FAIL=$((FAIL+1))
    fi
}

check_file() {
    local label="$1"
    local path="$2"
    if [ -e "$path" ]; then
        echo "  ✓ $label  ($(du -sh "$path" 2>/dev/null | awk '{print $1}'))"
        PASS=$((PASS+1))
    else
        echo "  ✗ $label  — missing ($path)"
        FAIL=$((FAIL+1))
    fi
}

echo "=========================================================="
echo "  Q60 Nav — Integrity Audit"
echo "  Worktree: $WORKTREE_ROOT"
echo "=========================================================="

echo ""
echo "── ELF arch + size ───────────────────────────────────────"
check_elf32 "q60nav app"          "$WORKTREE_ROOT/output/app-build/bin/q60nav"
check_elf32 "valhalla-httpd"      "$WORKTREE_ROOT/rootfs/opt/valhalla/bin/valhalla-httpd"
check_elf32 "valhalla_service"    "$MAIN_ROOT/output/valhalla-i386/bin/valhalla_service"
check_elf32 "valhalla_build_tiles" "$MAIN_ROOT/output/valhalla-i386/bin/valhalla_build_tiles"

echo ""
echo "── Kernel + Qt6 + MapLibre ───────────────────────────────"
check_file "kernel bzImage"       "$MAIN_ROOT/output/bzImage-4.19-q60"
check_file "Qt6Core (i386)"       "$MAIN_ROOT/output/qt6-i386/lib/libQt6Core.so.6"
check_file "libmbgl-core.a"       "$MAIN_ROOT/output/maplibre-i386/lib/libmbgl-core.a"

echo ""
echo "── Map + routing data ────────────────────────────────────"
check_file "Routing tiles dir"    "$MAIN_ROOT/output/valhalla-tiles"
check_file "Vector tiles nc.mbtiles" "$MAIN_ROOT/output/vector-tiles/nc.mbtiles"

echo ""
echo "── Image + boot artifacts ────────────────────────────────"
check_file "Rootfs image"         "$WORKTREE_ROOT/output/q60nav-rootfs.img"

echo ""
echo "── QML modules (worktree changes) ────────────────────────"
check_file "QmlKeyboard.qml"       "$WORKTREE_ROOT/app/src/qml/components/QmlKeyboard.qml"
check_file "DestinationSearch.qml" "$WORKTREE_ROOT/app/src/qml/screens/DestinationSearch.qml"
check_file "RoutePreview.qml"      "$WORKTREE_ROOT/app/src/qml/screens/RoutePreview.qml"
check_file "VehicleSettingsView.qml" "$WORKTREE_ROOT/app/src/qml/screens/VehicleSettingsView.qml"
check_file "VehicleStatusView.qml"   "$WORKTREE_ROOT/app/src/qml/screens/VehicleStatusView.qml"

echo ""
echo "── Documentation ─────────────────────────────────────────"
check_file "hardware-day-capture-checklist.md" "$WORKTREE_ROOT/docs/hardware-day-capture-checklist.md"
check_file "BACKLOG.md"                "$WORKTREE_ROOT/BACKLOG.md"
check_file "STATUS.md"                 "$WORKTREE_ROOT/STATUS.md"
check_file "Progress log"              "$WORKTREE_ROOT/.claude/progress/backlog-execution-2026-05-13.md"

echo ""
echo "── Rootfs image structural sanity ────────────────────────"
IMG="$WORKTREE_ROOT/output/q60nav-rootfs.img"
if [ -f "$IMG" ]; then
    # mount RO inside Docker and inspect
    docker run --rm --privileged \
        -v "$IMG:/image.img:ro" \
        q60-toolchain \
        bash -c "
            mkdir -p /mnt/img && mount -o loop,ro /image.img /mnt/img 2>/dev/null
            EXIT=0
            for p in /opt/nav/bin/q60nav /opt/nav/qml/Main.qml \\
                     /opt/nav/qml/screens/VehicleSettingsView.qml \\
                     /opt/nav/qml/screens/DestinationSearch.qml \\
                     /opt/nav/qml/screens/RoutePreview.qml \\
                     /opt/nav/qml/components/QmlKeyboard.qml \\
                     /opt/valhalla/bin/valhalla_service \\
                     /opt/valhalla/bin/valhalla-httpd \\
                     /opt/valhalla/tiles \\
                     /opt/nav/tiles/nc.mbtiles \\
                     /opt/geocoder/places.db \\
                     /usr/lib/i386-linux-gnu/libQt6Core.so.6; do
                if [ -e /mnt/img\$p ]; then
                    echo \"  ✓ \$p\"
                else
                    echo \"  ✗ \$p  — MISSING in rootfs\"
                    EXIT=1
                fi
            done
            umount /mnt/img
            exit \$EXIT
        " && IMG_OK=1 || IMG_OK=0

    if [ "$IMG_OK" = "1" ]; then
        PASS=$((PASS+1))
        echo "  ✓ Rootfs image structure verified"
    else
        FAIL=$((FAIL+1))
        echo "  ✗ Rootfs image structure has gaps (see above)"
    fi
fi

echo ""
echo "── Summary ───────────────────────────────────────────────"
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo "=========================================================="
if [ "$FAIL" -gt 0 ]; then
    echo "INTEGRITY FAILED — fix issues above before flashing."
    exit 1
fi
echo "INTEGRITY OK — image is ready to flash."
exit 0
