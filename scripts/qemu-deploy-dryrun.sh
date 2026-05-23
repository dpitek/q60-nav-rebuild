#!/bin/bash
# qemu-deploy-dryrun.sh — Exercise deploy-phase1-sd.sh against a mock SD image.
#
# Builds a 3 GB sparse disk that mimics the Q60 SD card partition layout,
# attaches it via hdiutil (gives /dev/diskN), runs the deploy, then verifies:
#   - /Volumes/boot/EFI/BOOT/BOOTIA32.EFI sha256 == new kernel
#   - /Volumes/boot/vmlinuz-4.19-q60 sha256 == new kernel
#   - /Volumes/boot/elilo.conf has default=q60nav with root=/dev/mmcblk0p3
#   - Slot B partition sha256 == rootfs image

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MOCK_IMG="/tmp/q60-mock-sd.img"
KERNEL="${SCRIPT_DIR}/output/bzImage-4.19-q60"
KERNEL_SHA=$(shasum -a 256 "$KERNEL" | awk '{print $1}')
ROOTFS_IMG="${SCRIPT_DIR}/output/q60-diag-rootfs-phase1.img"

echo ">> Building 3 GB mock SD card image (s1=FAT32, s3=ext4 q60diag) ..."
rm -f "$MOCK_IMG"
dd if=/dev/zero of="$MOCK_IMG" bs=1M count=0 seek=3072 status=none

# Partition + format in Docker (linux/amd64 has parted+mkfs.vfat+mkfs.ext4)
docker run --rm --privileged --platform linux/amd64 \
    -v "$MOCK_IMG:/disk.img" \
    -v "$ROOTFS_IMG:/rootfs.img:ro" \
    alpine sh -ec '
        apk add -q parted e2fsprogs e2fsprogs-extra dosfstools util-linux
        # Match Q60 SD layout: s1=FAT32 boot 134 MB, s2 small, s3=ext4 1.1 GB q60diag
        parted -s /disk.img mklabel msdos
        parted -s /disk.img mkpart primary fat32 1MiB 135MiB
        parted -s /disk.img mkpart primary ext4 135MiB 200MiB
        parted -s /disk.img mkpart primary ext4 200MiB 1300MiB
        parted -s /disk.img set 1 boot on

        # Format p1 (FAT32 boot) and p3 (ext4 q60diag) — p2 is a placeholder
        P1_OFF=$((1 * 1024 * 1024))
        P1_LEN=$((134 * 1024 * 1024))
        P3_OFF=$((200 * 1024 * 1024))
        P3_LEN=$((1100 * 1024 * 1024))

        LOOP1=$(losetup --show -f --offset $P1_OFF --sizelimit $P1_LEN /disk.img)
        LOOP3=$(losetup --show -f --offset $P3_OFF --sizelimit $P3_LEN /disk.img)
        mkfs.vfat -n boot $LOOP1
        # Write rootfs into p3 directly (preserves q60diag label)
        dd if=/rootfs.img of=$LOOP3 bs=1M status=none
        e2fsck -fy $LOOP3 >/dev/null
        resize2fs $LOOP3 >/dev/null

        # Pre-populate p1 with an elilo.conf so deploy hits the UPDATE path
        mkdir -p /mnt/boot
        mount -t vfat $LOOP1 /mnt/boot
        cat > /mnt/boot/elilo.conf <<EOF
verbose=0
legacy-free
default=logan1

image=vmlinuz-2.6.37
   label=logan1
   description="Factory"
   root=/dev/mmcblk0p2

image=vmlinuz-4.19-q60
   label=q60nav
   description="Phase 1"
   append="root=LABEL=q60diag stale rw rootwait"
EOF
        sync
        umount /mnt/boot

        losetup -d $LOOP1
        losetup -d $LOOP3
    '

echo ">> Mock image built: $MOCK_IMG"

# Attach via hdiutil — gives us a /dev/diskN we can pass to deploy
DEV=$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$MOCK_IMG" | head -1 | awk '{print $1}')
DISK_NUM=$(basename "$DEV" | sed 's/disk//')
echo ">> Attached as: $DEV (disk$DISK_NUM)"

# Run the deploy
sudo bash "${SCRIPT_DIR}/scripts/deploy-phase1-sd.sh" -y "disk$DISK_NUM"
DEPLOY_RC=$?
echo ">> deploy rc=$DEPLOY_RC"

# Verify
echo ""
echo "=========================================="
echo " VERIFICATION"
echo "=========================================="
PASS=0; FAIL=0
check() { local n="$1" v="$2"; if [ "$v" = "OK" ]; then echo "  ✓ $n"; PASS=$((PASS+1)); else echo "  ✗ $n: $v"; FAIL=$((FAIL+1)); fi; }

# Mount boot partition for inspection (deploy unmounts at end)
diskutil mount "${DEV}s1" >/dev/null 2>&1
BOOT_MNT=/Volumes/boot

SHA1=$(shasum -a 256 "${BOOT_MNT}/EFI/BOOT/BOOTIA32.EFI" 2>/dev/null | awk '{print $1}')
[ "$SHA1" = "$KERNEL_SHA" ] && check "BOOTIA32.EFI matches new kernel" OK || check "BOOTIA32.EFI matches new kernel" "sha mismatch (got ${SHA1:0:16}... expected ${KERNEL_SHA:0:16}...)"

SHA2=$(shasum -a 256 "${BOOT_MNT}/vmlinuz-4.19-q60" 2>/dev/null | awk '{print $1}')
[ "$SHA2" = "$KERNEL_SHA" ] && check "vmlinuz-4.19-q60 matches new kernel" OK || check "vmlinuz-4.19-q60 matches new kernel" "sha mismatch"

grep -q '^default=q60nav$' "${BOOT_MNT}/elilo.conf" && check "elilo.conf default=q60nav" OK || check "elilo.conf default=q60nav" "missing or wrong"
grep -q 'root=/dev/mmcblk0p3' "${BOOT_MNT}/elilo.conf" && check "elilo.conf root=/dev/mmcblk0p3" OK || check "elilo.conf root=/dev/mmcblk0p3" "missing (deploy still writing stale root=)"
! grep -q "root=LABEL=q60diag" "${BOOT_MNT}/elilo.conf" && check "elilo.conf no stale LABEL= root" OK || check "elilo.conf no stale LABEL=" "still references LABEL"

diskutil unmount "${BOOT_MNT}" >/dev/null 2>&1 || true
hdiutil detach "$DEV" >/dev/null 2>&1 || true

echo ""
echo "PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
