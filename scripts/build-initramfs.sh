#!/bin/bash
# build-initramfs.sh — Build a minimal diagnostic initramfs for v17.
#
# Output: output/initramfs.cpio.gz — a cpio.gz archive containing:
#   busybox (static i386), symlinks for needed applets, /init diagnostic script,
#   minimal /dev nodes. Designed to be embedded in the kernel via
#   CONFIG_INITRAMFS_SOURCE so the kernel doesn't need any block device to
#   reach userspace — proves LAPIS SDHCI hypothesis one way or the other.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOTFS_IMG="${SCRIPT_DIR}/output/q60-diag-rootfs-phase1.img"
INIT_SCRIPT="${SCRIPT_DIR}/rootfs/init-diag.sh"
OUT_CPIO="${SCRIPT_DIR}/output/initramfs.cpio.gz"

[ -f "${ROOTFS_IMG}" ]  || { echo "rootfs image not found: ${ROOTFS_IMG}" >&2; exit 1; }
[ -f "${INIT_SCRIPT}" ] || { echo "/init script not found: ${INIT_SCRIPT}" >&2; exit 1; }

echo ">> Building diagnostic initramfs"
echo ">>   rootfs source: ${ROOTFS_IMG} (extracting busybox)"
echo ">>   /init source:  ${INIT_SCRIPT}"
echo ">>   output:        ${OUT_CPIO}"

# Build inside Docker (Linux tools needed for cpio + ext4 mount + chmod preservation)
docker run --rm --privileged --platform linux/amd64 \
    -v "${ROOTFS_IMG}:/rootfs.img:ro" \
    -v "${INIT_SCRIPT}:/init.new:ro" \
    -v "${SCRIPT_DIR}/output:/out" \
    alpine sh -ec '
        apk add -q util-linux e2fsprogs cpio gzip >/dev/null

        # Mount source rootfs (read-only) to grab busybox + applets
        LOOP=$(losetup --show -f /rootfs.img)
        e2fsck -p ${LOOP} >/dev/null 2>&1 || true
        mkdir -p /src; mount -r ${LOOP} /src

        # Assemble initramfs in a staging dir (no brace expansion in ash)
        mkdir -p /irfs /irfs/bin /irfs/sbin /irfs/dev /irfs/proc /irfs/sys /irfs/tmp /irfs/mnt /irfs/etc /irfs/run

        # Copy busybox (static i386 ELF, no .so deps)
        cp /src/bin/busybox /irfs/bin/busybox
        chmod 755 /irfs/bin/busybox

        # Build applet symlinks — every applet busybox provides
        cd /irfs/bin
        for applet in sh ash mount umount mkdir cat echo ls cp mv rm sync \
                      sleep dmesg poweroff halt mdev printf head tail grep \
                      find stat date sed awk tr basename dirname which \
                      mountpoint touch chmod chown ln readlink ps top kill \
                      hexdump od strings uname uptime free df mknod test \
                      wc cut sort uniq xargs; do
            ln -sf busybox ${applet} 2>/dev/null
        done
        cd /irfs/sbin
        ln -sf ../bin/busybox init
        ln -sf ../bin/busybox poweroff
        ln -sf ../bin/busybox halt
        ln -sf ../bin/busybox mdev
        ln -sf ../bin/busybox swapon
        ln -sf ../bin/busybox swapoff

        # /init script (PID 1)
        cp /init.new /irfs/init
        chmod 755 /irfs/init

        # Essential device nodes (kernel autopopulates devtmpfs but having
        # these means /init can run even if devtmpfs mount fails)
        mknod /irfs/dev/console c 5 1 || true
        mknod /irfs/dev/null    c 1 3 || true
        mknod /irfs/dev/zero    c 1 5 || true
        mknod /irfs/dev/tty     c 5 0 || true

        # /etc/inittab — used by busybox init as fallback if /init isnt exec
        cat > /irfs/etc/inittab <<INITTAB
::sysinit:/init
::shutdown:/bin/sync
INITTAB

        # Build the cpio archive (newc format, what kernel expects)
        cd /irfs
        find . | cpio -o -H newc 2>/dev/null | gzip -9 > /out/initramfs.cpio.gz

        echo ">> initramfs.cpio.gz built ($(stat -c%s /out/initramfs.cpio.gz) bytes)"
        echo ">> contents:"
        find /irfs -type f -o -type l | sed "s|/irfs/|    |"

        umount /src
        losetup -d ${LOOP}
    '

echo ""
echo ">> Done: ${OUT_CPIO} ($(stat -f%z "${OUT_CPIO}") bytes)"
