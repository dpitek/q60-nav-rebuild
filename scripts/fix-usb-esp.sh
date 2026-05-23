#!/bin/bash
# fix-usb-esp.sh — Cleanly rewrite USB stick (disk5) MBR so it has a single
# partition typed 0xEF (EFI System Partition) for strict UEFI compatibility.
#
# Non-destructive to FAT32 contents — only changes the partition type byte.
# Also wipes any stale GPT signature that's causing the phantom disk5s2 entry.
#
# Usage: sudo bash /Users/dpitek/Developer/q60-rebuild/scripts/fix-usb-esp.sh

set -uo pipefail

DISK="${1:-disk5}"
DEV="/dev/${DISK}"

[ "$(id -u)" -eq 0 ] || { echo "Run as root: sudo bash $0" >&2; exit 1; }
[ -b "${DEV}" ]      || { echo "${DEV} not found" >&2; exit 1; }

# Confirm this is the USB (Removable + Flash)
INFO=$(diskutil info "${DEV}")
echo "${INFO}" | grep -q "Removable Media:.*Removable" || \
    { echo "${DEV} is NOT removable — refusing"; exit 1; }
echo "${INFO}" | grep -q "Flash" || \
    { echo "${DEV} doesn't look like flash — refusing"; exit 1; }

echo ">> Unmounting ${DEV} ..."
diskutil unmountDisk force "${DEV}" 2>&1 | sed 's/^/   /'

echo ">> Checking for GPT signature at sector 1 (only zero if actually present) ..."
GPT_MAGIC=$(dd if="${DEV}" bs=8 count=1 skip=64 2>/dev/null | head -c 8)
if [ "${GPT_MAGIC}" = "EFI PART" ]; then
    echo "   GPT magic found — surgical zero of sector 1 ONLY (NOT sectors 2-33,"
    echo "   because those overlap the start of the FAT32 partition on some layouts)"
    dd if=/dev/zero of="${DEV}" bs=512 count=1 seek=1 conv=notrunc 2>/dev/null
else
    echo "   no GPT magic — skipping GPT cleanup (good, your FAT32 is safe)"
fi

echo ">> Changing partition 1 type byte 0x0C → 0xEF in MBR ..."
python3 - "${DEV}" <<'PYEOF'
import sys
dev = sys.argv[1]
with open(dev, 'r+b') as f:
    f.seek(0x1BE + 4)        # MBR partition 1 entry, type byte offset
    old = f.read(1)
    f.seek(0x1BE + 4)
    f.write(bytes([0xEF]))
    f.flush()
    print(f"   type byte: 0x{old.hex()} → 0xEF")
PYEOF

# Force kernel to re-read the partition table
diskutil reset "${DEV}" 2>/dev/null || true
sleep 1

echo ">> Result:"
diskutil list "${DEV}"

# Re-mount
diskutil mount "${DEV}s1" 2>&1 | sed 's/^/   /'

echo ""
echo ">> Done. USB now has a single ESP-typed FAT32 partition."
