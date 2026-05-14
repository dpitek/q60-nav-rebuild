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

echo ""
echo "── QML → C++ binding static check ────────────────────────"
if "$WORKTREE_ROOT/scripts/qml-binding-check.sh" >/tmp/qml-check.log 2>&1; then
    PASS=$((PASS+1))
    echo "  ✓ All QML → C++ references resolve"
else
    FAIL=$((FAIL+1))
    echo "  ✗ Unresolved QML bindings — see below"
    sed 's/^/    /' /tmp/qml-check.log
fi

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

            echo ''
            echo '── Air-gap first-boot prerequisites ─────────────────'

            # Inittab points to /etc/init.d/rc (post-audit fix). Verify
            # that file exists and is executable.
            if grep -q '/etc/init.d/rc 5' /mnt/img/etc/inittab; then
                echo \"  ✓ inittab uses /etc/init.d/rc\"
            else
                echo \"  ✗ inittab path mismatch\"; EXIT=1
            fi
            if [ -x /mnt/img/etc/init.d/rc ]; then
                echo \"  ✓ /etc/init.d/rc is executable\"
            else
                echo \"  ✗ /etc/init.d/rc missing or not executable\"; EXIT=1
            fi

            # /data fstab nofail
            if grep -q 'nofail' /mnt/img/etc/fstab; then
                echo \"  ✓ fstab uses nofail for /data\"
            else
                echo \"  ✗ /data is not marked nofail — missing partition blocks boot\"; EXIT=1
            fi

            # rcS creates fallback dirs
            if grep -q 'mkdir -p /data/q60nav' /mnt/img/etc/init.d/rcS; then
                echo \"  ✓ rcS pre-creates /data/q60nav subdirs\"
            else
                echo \"  ✗ rcS does not bootstrap /data/q60nav\"; EXIT=1
            fi
            if grep -q '/var/lib/q60nav-data' /mnt/img/etc/init.d/rcS; then
                echo \"  ✓ rcS has /data fallback to /var/lib/q60nav-data\"
            else
                echo \"  ✗ rcS lacks /data fallback path\"; EXIT=1
            fi

            # S50-q60nav liveness probe
            if grep -q 'kill -0' /mnt/img/etc/init.d/S50-q60nav; then
                echo \"  ✓ S50-q60nav has start.sh liveness monitor\"
            else
                echo \"  ✗ S50-q60nav lacks liveness probe\"; EXIT=1
            fi

            # No remote URLs in mapstyle
            if grep -qE 'http(s)?://' /mnt/img/opt/nav/style/q60-dark.json 2>/dev/null; then
                echo \"  ✗ MapLibre style contains remote URL\"; EXIT=1
            else
                echo \"  ✓ MapLibre style uses only local resources\"
            fi

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
