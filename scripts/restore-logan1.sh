#!/bin/bash
# restore-logan1.sh — Emergency recovery: restore original firmware boot
# Run from Mac with eMMC mounted via USB adapter
# Resets elilo.conf default to logan1 (original Clarion firmware)
set -e

BOOT_VOL="/Volumes/boot 1"

if [ ! -d "$BOOT_VOL" ]; then
    echo "ERROR: Boot partition not mounted at '$BOOT_VOL'"
    echo "Mount the eMMC via USB adapter and try again."
    exit 1
fi

echo "[restore] Current elilo.conf default:"
grep "^default=" "$BOOT_VOL/elilo.conf"

sed -i '' 's/^default=.*/default=logan1/' "$BOOT_VOL/elilo.conf"

echo "[restore] Restored to:"
grep "^default=" "$BOOT_VOL/elilo.conf"

echo "[restore] Removing boot counter if present..."
rm -f "$BOOT_VOL/q60_boot_attempts" 2>/dev/null || true

sync
echo "[restore] Done. Eject eMMC and reinsert into Q60 — will boot original Clarion firmware."
