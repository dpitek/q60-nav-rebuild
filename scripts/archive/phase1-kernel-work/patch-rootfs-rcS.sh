#!/bin/bash
# patch-rootfs-rcS.sh — Update /etc/init.d/rcS inside the diagnostic rootfs image.
#
# The Phase 1 rootfs image is the deployable artifact (output/q60-diag-rootfs-phase1.img).
# When rcS in the source tree changes, this script patches the rootfs image in-place
# so QEMU validation and SD card deploy use the same code.
#
# Usage: bash scripts/patch-rootfs-rcS.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOTFS_IMG="${SCRIPT_DIR}/output/q60-diag-rootfs-phase1.img"
RCS_SRC="${SCRIPT_DIR}/rootfs/etc/init.d/rcS"

[ -f "${ROOTFS_IMG}" ] || { echo "rootfs not found: ${ROOTFS_IMG}" >&2; exit 1; }
[ -f "${RCS_SRC}" ]    || { echo "rcS source not found: ${RCS_SRC}" >&2; exit 1; }

NEW_SHA=$(shasum -a 256 "${RCS_SRC}" | awk '{print $1}')
echo ">> patching ${ROOTFS_IMG}"
echo ">> new rcS sha: ${NEW_SHA:0:16}..."

# Use Docker (alpine) for ext4 mount-and-copy — preserves mode bits properly.
docker run --rm \
    --privileged \
    --platform linux/amd64 \
    -v "${ROOTFS_IMG}:/disk.img" \
    -v "${RCS_SRC}:/rcS.new:ro" \
    alpine sh -ec '
        apk add -q util-linux e2fsprogs >/dev/null
        LOOP=$(losetup --show -f /disk.img)
        sleep 0.3
        mkdir -p /mnt
        mount -t ext4 ${LOOP} /mnt

        OLD_SHA=$(sha256sum /mnt/etc/init.d/rcS 2>/dev/null | awk "{print \$1}")
        NEW_SHA=$(sha256sum /rcS.new | awk "{print \$1}")
        echo ">> old rcS sha: ${OLD_SHA:0:16}..."
        echo ">> new rcS sha: ${NEW_SHA:0:16}..."

        if [ "$OLD_SHA" = "$NEW_SHA" ]; then
            echo ">> already up-to-date"
        else
            cp /rcS.new /mnt/etc/init.d/rcS
            chmod 755 /mnt/etc/init.d/rcS
            sync
            VERIFY_SHA=$(sha256sum /mnt/etc/init.d/rcS | awk "{print \$1}")
            [ "$VERIFY_SHA" = "$NEW_SHA" ] || { echo "sha mismatch after write"; exit 1; }
            echo ">> ✓ rcS updated"
            ls -la /mnt/etc/init.d/rcS
        fi

        umount /mnt
        losetup -d ${LOOP}
    '
