#!/bin/bash
# qemu-prep-disk.sh — Build a QEMU disk image that mimics the Q60 SD card.
#
# Output: /tmp/q60-qemu.img — 1 GB raw image with:
#   p1 = FAT32 (boot) — empty; rcS will write BOOT_STAGE_*.TXT here
#   p2 = ext4 labeled "q60diag" — contents of Phase 1 diagnostic rootfs
#
# Usage: bash scripts/qemu-prep-disk.sh [/path/to/rootfs.img] [/tmp/output.img]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOTFS_SRC="${1:-${SCRIPT_DIR}/output/q60-diag-rootfs-phase1.img}"
OUT_IMG="${2:-/tmp/q60-qemu.img}"

[ -f "${ROOTFS_SRC}" ] || { echo "rootfs not found: ${ROOTFS_SRC}" >&2; exit 1; }

echo ">> building ${OUT_IMG} (1 GB) from rootfs ${ROOTFS_SRC}"

# Strip any prior loop attachments before re-creating
rm -f "${OUT_IMG}"
dd if=/dev/zero of="${OUT_IMG}" bs=1M count=0 seek=1024 status=none

# Use Docker (alpine) for parted+mkfs — macOS lacks both natively
RCS_SRC="${SCRIPT_DIR}/rootfs/etc/init.d/rcS"
[ -f "${RCS_SRC}" ] || { echo "rcS source not found: ${RCS_SRC}" >&2; exit 1; }

docker run --rm \
    --privileged \
    --platform linux/amd64 \
    -v "${OUT_IMG}:/disk.img" \
    -v "${ROOTFS_SRC}:/rootfs.img:ro" \
    -v "${RCS_SRC}:/rcS.new:ro" \
    alpine sh -ec '
        apk add -q parted e2fsprogs e2fsprogs-extra dosfstools util-linux
        # Partition: msdos label, p1=FAT32 (1-129 MiB), p2=ext4 (129-end)
        parted -s /disk.img mklabel msdos
        parted -s /disk.img mkpart primary fat32 1MiB 129MiB
        parted -s /disk.img mkpart primary ext4  129MiB 100%
        parted -s /disk.img set 1 boot on

        # Use per-partition loop devices via --offset/--sizelimit.
        # This avoids needing kernel partition-node auto-creation, which is
        # unreliable in containers without udev.
        P1_OFF=$((1   * 1024 * 1024))           # 1 MiB
        P1_LEN=$((128 * 1024 * 1024))           # 128 MiB
        P2_OFF=$((129 * 1024 * 1024))           # 129 MiB onward, fills rest

        LOOP_P1=$(losetup --show -f --offset $P1_OFF --sizelimit $P1_LEN /disk.img)
        echo "p1 loop: ${LOOP_P1}"
        LOOP_P2=$(losetup --show -f --offset $P2_OFF /disk.img)
        echo "p2 loop: ${LOOP_P2}"

        # Format p1 (FAT32) and write rootfs into p2
        mkfs.vfat -n boot ${LOOP_P1}
        dd if=/rootfs.img of=${LOOP_P2} bs=1M status=none

        # Resize p2 ext4 to fill (rootfs is 512 MB, p2 is ~895 MB)
        e2fsck -fy ${LOOP_P2} >/dev/null
        resize2fs ${LOOP_P2} >/dev/null

        # Inject the latest rcS — the on-disk rootfs image may be stale.
        # This makes QEMU validate the SAME rcS we will deploy.
        mkdir -p /mnt/root
        mount ${LOOP_P2} /mnt/root
        cp /rcS.new /mnt/root/etc/init.d/rcS
        chmod 755 /mnt/root/etc/init.d/rcS
        echo ">> rcS injected; sha:"; sha256sum /mnt/root/etc/init.d/rcS
        sync
        umount /mnt/root

        # Verify
        echo ">> verify p1 FAT32:"
        fsck.vfat -v -n ${LOOP_P1} 2>&1 | head -3
        echo ">> verify p2 label:"
        e2label ${LOOP_P2}

        # Pre-populate p1 with an elilo.conf so failsafe restore has something
        # to rewrite (mirrors real SD card layout).
        mkdir -p /mnt/boot
        mount -t vfat ${LOOP_P1} /mnt/boot
        cat > /mnt/boot/elilo.conf <<EOF
verbose=0
legacy-free
default=q60nav

image=vmlinuz-2.6.37
   label=logan1
   description="Factory Wind River"
   root=/dev/mmcblk0p2
   append="ro quiet rootwait android"
   read-only

image=vmlinuz-4.19-q60
   label=q60nav
   description="Q60 Nav Rebuild (Linux 4.19)"
   append="root=LABEL=q60diag rw rootwait"
EOF
        sync
        ls -la /mnt/boot/
        umount /mnt/boot

        losetup -d ${LOOP_P1}
        losetup -d ${LOOP_P2}
    '

echo ">> QEMU disk ready: ${OUT_IMG} ($(stat -f%z "${OUT_IMG}" 2>/dev/null || stat -c%s "${OUT_IMG}") bytes)"
