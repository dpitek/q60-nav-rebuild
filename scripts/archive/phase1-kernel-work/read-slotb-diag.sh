#!/bin/bash
# read-slotb-diag.sh — Inspect rootfs (Slot B, ext4) for v16 diagnostic markers.
#
# Slot B is ext4 — macOS can't read it natively. This script:
#   1. dd's Slot B from /dev/diskNs3 into /tmp/slotb-read.img
#   2. Mounts that image in a Docker container
#   3. Extracts /RCS_REACHED.MARKER + /diag-rootfs/ to /tmp/slotb-diag/
#   4. Prints what was found
#
# Usage: sudo bash /Users/dpitek/Developer/q60-rebuild/scripts/read-slotb-diag.sh [diskN]

set -uo pipefail

TARGET="${1:-disk4}"
SRC="/dev/${TARGET}s3"
IMG="/tmp/slotb-read.img"
OUT="/tmp/slotb-diag"

[ "$(id -u)" -eq 0 ] || { echo "Run as root: sudo bash $0 [diskN]" >&2; exit 1; }
[ -b "$SRC" ] || { echo "$SRC not found" >&2; exit 1; }

echo "=== Reading Slot B (${SRC}) → ${IMG} (1.1 GB) ==="
dd if="${SRC}" of="${IMG}" bs=4m count=275 2>&1 | tail -2

rm -rf "${OUT}"
mkdir -p "${OUT}"

echo ""
echo "=== Mounting in Docker + extracting markers ==="
docker run --rm --privileged --platform linux/amd64 \
    -v "${IMG}:/disk.img:ro" \
    -v "${OUT}:/extract" \
    alpine sh -ec '
        apk add -q util-linux e2fsprogs >/dev/null
        LOOP=$(losetup --show -f -r /disk.img)
        mkdir -p /mnt
        mount -r ${LOOP} /mnt

        echo "--- /RCS_REACHED.MARKER ---"
        if [ -f /mnt/RCS_REACHED.MARKER ]; then
            cat /mnt/RCS_REACHED.MARKER
            cp /mnt/RCS_REACHED.MARKER /extract/RCS_REACHED.MARKER
        else
            echo "(absent — rcS never reached userspace)"
        fi
        echo ""

        echo "--- /diag-rootfs/ contents ---"
        if [ -d /mnt/diag-rootfs ]; then
            ls -la /mnt/diag-rootfs
            cp -r /mnt/diag-rootfs /extract/ 2>/dev/null
            echo ""
            echo "--- /diag-rootfs/_stages.log ---"
            cat /mnt/diag-rootfs/_stages.log 2>/dev/null || echo "(no stages log)"
        else
            echo "(absent)"
        fi
        echo ""

        echo "--- Stage marker files ---"
        ls /mnt/diag-rootfs/STAGE_*.txt 2>/dev/null | head -25 || echo "(none)"

        umount /mnt
        losetup -d ${LOOP}
    '

echo ""
echo "=== Extracted to ${OUT}/ ==="
ls -la "${OUT}/" 2>/dev/null
