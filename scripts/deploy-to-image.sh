#!/bin/bash
# deploy-to-image.sh — Write new OS to slot B (mmcblk0p3) and nav app to p8
# Run from Mac with eMMC mounted via USB adapter
# SAFE: Never touches slot A (p1=boot FAT32 kept, p2=slot A root never written)
#
# Usage: ./scripts/deploy-to-image.sh [--test]
#   --test: set default=q60nav in elilo.conf (for test boot)
#   (no flag): write rootfs only, leave default=logan1
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."

BINARY="$ROOT/output/app-build/q60nav"
ROOTFS="$ROOT/rootfs"
VALHALLA_TILES="$ROOT/output/valhalla-tiles"
KERNEL="$ROOT/output/bzImage-4.19-q60"

# eMMC partitions (adjust if your USB adapter enumerates differently)
BOOT_VOL="/Volumes/boot 1"
SLOT_B_DEV=""   # e.g. /dev/disk4s3 — set by detect below

# ── Detect eMMC ─────────────────────────────────────────────────────────────
echo "[deploy] Detecting eMMC..."
if [ -d "$BOOT_VOL" ]; then
    echo "[deploy] Boot partition mounted at: $BOOT_VOL"
else
    echo "ERROR: Boot partition not mounted. Mount the eMMC via USB adapter first."
    exit 1
fi

# ── Verify artifacts ─────────────────────────────────────────────────────────
if [ ! -f "$BINARY" ]; then
    echo "ERROR: q60nav binary not found at $BINARY — run build-app.sh first"
    exit 1
fi
if [ ! -f "$KERNEL" ]; then
    echo "ERROR: Kernel not found at $KERNEL"
    exit 1
fi

echo "[deploy] q60nav: $(ls -lh $BINARY | awk '{print $5}')"
echo "[deploy] Kernel: $(ls -lh $KERNEL | awk '{print $5}')"

# ── Step 1: Copy kernel to FAT32 boot partition ───────────────────────────────
echo "[deploy] Writing kernel to boot partition..."
cp "$KERNEL" "$BOOT_VOL/vmlinuz-4.19-q60"
echo "[deploy] Kernel written: $(ls -lh "$BOOT_VOL/vmlinuz-4.19-q60" | awk '{print $5}')"

# ── Step 2: Verify q60nav entry exists in elilo.conf ─────────────────────────
if ! grep -q "label=q60nav" "$BOOT_VOL/elilo.conf"; then
    echo "WARNING: q60nav entry missing from elilo.conf — adding..."
    cat >> "$BOOT_VOL/elilo.conf" << 'EOF'

image=vmlinuz-4.19-q60
	label=q60nav
	description="Q60 New Nav System (Linux 4.19, Qt 6.6)"
	root=/dev/mmcblk0p3
	append="rw quiet rootwait lpj=1296800 panic=1 mem=1G"
EOF
fi

# ── Step 3: Set test mode if requested ───────────────────────────────────────
if [ "$1" = "--test" ]; then
    echo "[deploy] TEST MODE: setting default=q60nav in elilo.conf"
    sed -i '' 's/^default=.*/default=q60nav/' "$BOOT_VOL/elilo.conf"
    echo "[deploy] WARNING: If boot fails twice, auto-restore will revert to logan1"
else
    echo "[deploy] Safe mode: default=logan1 preserved (manual --test flag to switch)"
fi

grep "^default=" "$BOOT_VOL/elilo.conf"

# ── Step 4: Rootfs summary ───────────────────────────────────────────────────
echo ""
echo "[deploy] === MANUAL STEPS REQUIRED ==="
echo "The following cannot be done automatically (requires raw partition write as root):"
echo ""
echo "  1. Write rootfs to mmcblk0p3 (slot B root, 1GB):"
echo "     sudo dd if=$ROOTFS.img of=/dev/[disk]s3 bs=4M status=progress"
echo "     (create rootfs.img first: sudo mkfs.ext4 -L q60nav $ROOTFS.img)"
echo ""
echo "  2. Write nav app (Valhalla tiles + binary) to mmcblk0p8 (3GB):"
echo "     sudo mount /dev/[disk]s8 /mnt/navapp"
echo "     sudo cp $BINARY /mnt/navapp/bin/q60nav"
echo "     sudo cp -r $VALHALLA_TILES /mnt/navapp/valhalla_tiles"
echo "     sudo cp $ROOT/output/valhalla-config.json /mnt/navapp/"
echo "     sudo umount /mnt/navapp"
echo ""
echo "[deploy] Boot partition updated. Eject and insert into Q60."
echo "[deploy] Done."
