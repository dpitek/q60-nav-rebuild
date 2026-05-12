#!/bin/bash
# deploy-to-image.sh — Deploy Q60 nav stack to the DCU eMMC
#
# Run from Mac with the DCU's eMMC mounted via USB adapter.
#
# What this script touches:
#   FAT32 boot partition (p1): kernel file + elilo.conf entry
#   Slot B root (p3):          q60nav-rootfs.img written via dd
#
# What this script NEVER touches:
#   Slot A root (p2):          Factory logan1 — permanently preserved
#   Data partitions (p7-p9):   User/nav data — untouched
#
# Usage:
#   ./scripts/deploy-to-image.sh --verify       # check image contents only
#   ./scripts/deploy-to-image.sh                # write kernel + rootfs, keep default=logan1
#   ./scripts/deploy-to-image.sh --test         # same + set default=q60nav (live test boot)
#   ./scripts/deploy-to-image.sh --restore      # revert elilo.conf to default=logan1
#
# Safety model:
#   Without --test, the car always boots logan1 (factory). The new kernel and
#   rootfs are written but never activated. Add --test only when ready to test
#   boot. If two consecutive boots fail, start.sh auto-reverts to logan1.
#
# Finding your slot B device:
#   diskutil list            → find the eMMC disk (usually /dev/diskN)
#   diskutil list /dev/diskN → find partition 3 (slot B root, type Linux)
#   Then: SLOT_B_DEV=/dev/diskNs3 ./scripts/deploy-to-image.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."

ROOTFS_IMG="$ROOT/output/q60nav-rootfs.img"
KERNEL="$ROOT/output/bzImage-4.19-q60"
BOOT_VOL="/Volumes/boot 1"     # FAT32 p1 — adjust if mounted elsewhere
SLOT_B_DEV="${SLOT_B_DEV:-}"   # set via env or prompted interactively

MODE="${1:-deploy}"
[ "$1" = "--test"    ] && MODE="test"
[ "$1" = "--verify"  ] && MODE="verify"
[ "$1" = "--restore" ] && MODE="restore"

# ── Verify mode — inspect image without writing anything ─────────────────────
if [ "$MODE" = "verify" ]; then
    echo "[deploy] === VERIFY MODE — read-only ==="
    if [ ! -f "$ROOTFS_IMG" ]; then
        echo "ERROR: $ROOTFS_IMG not found — run package-rootfs.sh first"
        exit 1
    fi
    echo "[deploy] Image: $(ls -lh "$ROOTFS_IMG" | awk '{print $5}') — $ROOTFS_IMG"
    echo "[deploy] Mounting image via Docker to inspect contents..."
    docker run --rm --privileged \
        -v "$ROOTFS_IMG:/image.img:ro" \
        q60-toolchain \
        bash -c "
            set -e
            MOUNT=\$(mktemp -d)
            mount -o loop,ro /image.img \$MOUNT
            echo ''
            echo '--- Key files ---'
            ls -lh \$MOUNT/opt/nav/bin/      2>/dev/null || echo '  /opt/nav/bin/ MISSING'
            ls -lh \$MOUNT/opt/valhalla/bin/ 2>/dev/null || echo '  /opt/valhalla/bin/ MISSING'
            ls -lh \$MOUNT/opt/nav/tiles/    2>/dev/null || echo '  /opt/nav/tiles/ MISSING'
            echo ''
            echo '--- Tile directory ---'
            du -sh \$MOUNT/opt/valhalla/tiles 2>/dev/null || echo '  routing tiles MISSING'
            du -sh \$MOUNT/opt/nav/tiles      2>/dev/null || echo '  vector tiles MISSING'
            echo ''
            echo '--- Qt6 libs ---'
            ls \$MOUNT/usr/lib/i386-linux-gnu/ 2>/dev/null | grep libQt6 | head -10 || echo '  Qt6 libs MISSING'
            echo ''
            echo '--- Disk usage ---'
            df -h \$MOUNT
            umount \$MOUNT
            rmdir \$MOUNT
        "
    exit 0
fi

# ── Restore mode — revert elilo.conf to default=logan1 ──────────────────────
if [ "$MODE" = "restore" ]; then
    echo "[deploy] === RESTORE MODE ==="
    if [ ! -f "$BOOT_VOL/elilo.conf" ]; then
        echo "ERROR: elilo.conf not found at $BOOT_VOL/elilo.conf"
        echo "       Is the boot partition mounted?"
        exit 1
    fi
    sed -i '' 's/^default=.*/default=logan1/' "$BOOT_VOL/elilo.conf"
    echo "[deploy] elilo.conf restored: default=logan1"
    grep "^default=" "$BOOT_VOL/elilo.conf"
    exit 0
fi

# ── Deploy / Test mode ───────────────────────────────────────────────────────
echo "[deploy] === DEPLOY MODE${MODE:+ (--$MODE)} ==="
echo ""

# ── Pre-flight checks ────────────────────────────────────────────────────────
FAIL=0
check_file() {
    if [ ! -f "$1" ]; then
        echo "  MISSING: $2 ($1)"
        FAIL=$((FAIL+1))
    else
        echo "  OK: $2 ($(ls -lh "$1" | awk '{print $5}'))"
    fi
}
echo "Artifacts:"
check_file "$ROOTFS_IMG" "rootfs image"
check_file "$KERNEL"     "kernel bzImage"
echo ""

if [ $FAIL -gt 0 ]; then
    echo "ERROR: $FAIL required artifact(s) missing. Run the missing build steps first."
    exit 1
fi

if [ ! -d "$BOOT_VOL" ]; then
    echo "ERROR: Boot partition not found at '$BOOT_VOL'"
    echo "       Mount the eMMC via USB adapter. Expected FAT32 volume named 'boot 1'."
    echo "       If mounted under a different name: BOOT_VOL='/Volumes/yourname' ./scripts/deploy-to-image.sh"
    exit 1
fi
echo "Boot partition: $BOOT_VOL"
echo ""

# ── Step 1: Slot B raw write ─────────────────────────────────────────────────
# Find or prompt for the slot B block device
if [ -z "$SLOT_B_DEV" ]; then
    echo "=== Slot B device detection ==="
    echo "Run: diskutil list"
    echo "Find the eMMC disk (e.g. /dev/disk4) — look for ~4-8GB, Linux partitions."
    echo "Slot B = partition 3 (type Linux, ~3GB)"
    echo ""
    echo "Then run:"
    echo "  SLOT_B_DEV=/dev/disk4s3 ./scripts/deploy-to-image.sh $1"
    echo ""
    echo "Or set SLOT_B_DEV and press Enter to continue:"
    read -r -p "SLOT_B_DEV> " SLOT_B_DEV
    SLOT_B_DEV="${SLOT_B_DEV:-}"
fi

if [ -z "$SLOT_B_DEV" ]; then
    echo "ERROR: SLOT_B_DEV not set. Cannot write rootfs."
    echo "       Kernel and elilo.conf will still be updated."
    SKIP_ROOTFS=1
else
    SKIP_ROOTFS=0
fi

# ── Step 2: Write kernel to boot partition ───────────────────────────────────
echo "[deploy] Writing kernel to boot partition..."
cp "$KERNEL" "$BOOT_VOL/vmlinuz-4.19-q60"
echo "[deploy] Kernel written: $BOOT_VOL/vmlinuz-4.19-q60"

# ── Step 3: Ensure q60nav entry in elilo.conf ────────────────────────────────
ELILO="$BOOT_VOL/elilo.conf"
if ! grep -q "label=q60nav" "$ELILO"; then
    echo "[deploy] Adding q60nav boot entry to elilo.conf..."
    # Ensure blank line before new entry
    echo "" >> "$ELILO"
    cat >> "$ELILO" << 'ENTRY'
image=vmlinuz-4.19-q60
	label=q60nav
	description="Q60 Nav Rebuild (Linux 4.19 / Qt 6.6)"
	root=/dev/mmcblk0p3
	append="rw quiet rootwait lpj=1296800 panic=1 mem=1G"
ENTRY
    echo "[deploy] Entry added."
else
    echo "[deploy] q60nav entry already present in elilo.conf"
fi

# ── Step 4: Set boot default ─────────────────────────────────────────────────
if [ "$MODE" = "test" ]; then
    echo "[deploy] TEST MODE: switching default boot to q60nav"
    sed -i '' 's/^default=.*/default=q60nav/' "$ELILO"
    echo "[deploy] ⚠️  If the system fails to boot twice in a row, start.sh auto-reverts to logan1."
else
    echo "[deploy] SAFE MODE: default=logan1 preserved"
    echo "         To activate test boot: run with --test flag"
fi

echo ""
echo "elilo.conf boot default:"
grep "^default=" "$ELILO"
echo ""

# ── Step 5: Write rootfs image to slot B ─────────────────────────────────────
if [ "$SKIP_ROOTFS" -eq 0 ]; then
    echo "[deploy] Writing rootfs image to $SLOT_B_DEV..."
    echo "         Source: $ROOTFS_IMG ($(ls -lh "$ROOTFS_IMG" | awk '{print $5}'))"
    echo ""
    echo "         This will take several minutes. Do NOT unplug the adapter."
    echo ""
    # Use rdisk for raw access on macOS (much faster than disk)
    RAW_DEV="${SLOT_B_DEV/\/dev\/disk//dev/rdisk}"
    sudo diskutil unmount "$SLOT_B_DEV" 2>/dev/null || true
    sudo dd if="$ROOTFS_IMG" of="$RAW_DEV" bs=4m status=progress
    sudo diskutil mount "$SLOT_B_DEV" 2>/dev/null || true
    echo ""
    echo "[deploy] Rootfs written to $SLOT_B_DEV"
fi

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo "[deploy] === COMPLETE ==="
echo "  Kernel:    $BOOT_VOL/vmlinuz-4.19-q60"
echo "  elilo.conf: default=$(grep '^default=' "$ELILO" | cut -d= -f2)"
if [ "$SKIP_ROOTFS" -eq 0 ]; then
    echo "  Rootfs:    written to $SLOT_B_DEV"
else
    echo "  Rootfs:    NOT written (no SLOT_B_DEV)"
    echo "             To write manually:"
    echo "             SLOT_B_DEV=/dev/diskNs3 ./scripts/deploy-to-image.sh"
fi
echo ""
echo "Eject the eMMC adapter and reinstall in the DCU."
[ "$MODE" = "test" ] && echo "System will boot Q60 nav on next power cycle."
[ "$MODE" != "test" ] && echo "System will boot factory logan1 (safe). Add --test when ready."
