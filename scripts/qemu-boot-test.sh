#!/bin/bash
# qemu-boot-test.sh — Boot v14 kernel + Phase 1 rootfs in QEMU.
#
# Usage:
#   bash scripts/qemu-boot-test.sh                          # happy path
#   bash scripts/qemu-boot-test.sh --no-root                # negative: hide root device
#   bash scripts/qemu-boot-test.sh --bad-label              # negative: label mismatch
#
# Output:
#   /tmp/q60-qemu-serial.log    — full serial console capture
#   /tmp/q60-qemu-boot-mount/   — contents of the FAT32 /boot partition after halt
#
# Exit codes:
#   0 = boot reached halt cleanly (rcS Stage 11 marker present)
#   1 = boot hung (timeout) or rcS did not complete

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="${SCRIPT_DIR}/output/bzImage-4.19-q60"
DISK="/tmp/q60-qemu.img"
SERIAL_LOG="/tmp/q60-qemu-serial.log"
BOOT_EXTRACT="/tmp/q60-qemu-boot-mount"

# Mode flags
MODE="happy"
case "${1:-}" in
    --no-root)   MODE="no-root" ;;
    --bad-label) MODE="bad-label" ;;
    --failsafe)  MODE="failsafe" ;;
esac

# CMDLINE — override based on test mode
case "$MODE" in
    happy)
        # ttyS0 LAST → becomes /dev/console → userspace stdout goes there (capturable in QEMU)
        APPEND="root=/dev/vda2 rw rootwait console=tty0 console=ttyS0,115200 loglevel=8 ignore_loglevel idle=halt panic=10 initcall_debug nokaslr"
        ;;
    no-root)
        APPEND="root=/dev/vda9 rw rootwait console=tty0 console=ttyS0,115200 loglevel=8 idle=halt panic=10 nokaslr"
        ;;
    bad-label)
        APPEND="root=/dev/null rw rootwait console=tty0 console=ttyS0,115200 loglevel=8 idle=halt panic=10 nokaslr"
        ;;
    failsafe)
        APPEND="root=/dev/vda2 rw rootwait console=tty0 console=ttyS0,115200 loglevel=8 idle=halt panic=10 nokaslr"
        ;;
esac

[ -f "$KERNEL" ] || { echo "kernel not found: $KERNEL — run scripts/build-kernel.sh first" >&2; exit 2; }
[ -f "$DISK" ]   || { echo "disk not found: $DISK — run scripts/qemu-prep-disk.sh first" >&2; exit 2; }

echo ">> mode: $MODE"
echo ">> kernel: $KERNEL"
echo ">> disk: $DISK"
echo ">> cmdline: $APPEND"
echo ">> serial log: $SERIAL_LOG"

rm -f "$SERIAL_LOG"

# Boot with 90s ceiling. Use -no-reboot so panic doesn't trigger a loop in QEMU.
# Use -display none to keep QEMU headless. Serial goes to file.
# macOS has no `timeout` — background QEMU and kill after the ceiling.
qemu-system-i386 \
    -m 2048 \
    -smp 1 \
    -cpu n270 \
    -machine pc \
    -kernel "$KERNEL" \
    -append "$APPEND" \
    -drive file="$DISK",if=virtio,format=raw \
    -serial file:"$SERIAL_LOG" \
    -display none \
    -no-reboot \
    -d guest_errors -D /tmp/q60-qemu-guest-errors.log \
    >/tmp/q60-qemu-stdout.log 2>&1 &
QEMU_PID=$!

# Wait up to 90s for QEMU to exit (kernel will halt cleanly on success)
for i in $(seq 1 90); do
    if ! kill -0 $QEMU_PID 2>/dev/null; then
        break
    fi
    sleep 1
done

if kill -0 $QEMU_PID 2>/dev/null; then
    echo ">> QEMU still running after 90s — killing"
    kill -KILL $QEMU_PID 2>/dev/null || true
    wait $QEMU_PID 2>/dev/null || true
    QEMU_RC=124
else
    wait $QEMU_PID 2>/dev/null || true
    QEMU_RC=$?
fi

echo ""
echo ">> QEMU exited with rc=$QEMU_RC"

# Extract the FAT32 /boot partition contents — needed for marker analysis.
# Use Docker because macOS lacks ext4 read-write tooling.
rm -rf "$BOOT_EXTRACT"
mkdir -p "$BOOT_EXTRACT"
docker run --rm \
    --privileged \
    --platform linux/amd64 \
    -v "$DISK:/disk.img" \
    -v "$BOOT_EXTRACT:/extract" \
    alpine sh -ec '
        apk add -q util-linux dosfstools
        P1_OFF=$((1   * 1024 * 1024))
        P1_LEN=$((128 * 1024 * 1024))
        LOOP_P1=$(losetup --show -f --offset $P1_OFF --sizelimit $P1_LEN -r /disk.img)
        mkdir -p /mnt/boot
        mount -t vfat -r ${LOOP_P1} /mnt/boot
        cp -r /mnt/boot/. /extract/ 2>/dev/null || true
        umount /mnt/boot
        losetup -d ${LOOP_P1}
    ' 2>&1 | grep -vE "WARNING|hint:" || true

echo ""
echo ">> /boot partition contents after boot:"
ls -la "$BOOT_EXTRACT" | sed 's/^/    /'

echo ""
echo ">> serial tail (last 40 lines):"
tail -40 "$SERIAL_LOG" 2>/dev/null | sed 's/^/    /'

# Validation gate
if [ -f "$BOOT_EXTRACT/BOOT_STAGE_S11.TXT" ]; then
    echo ""
    echo ">> ✓ PASS — Stage 11 marker present, rcS completed all stages"
    cat "$BOOT_EXTRACT/Q60_DISPLAY_GATE.TXT" 2>/dev/null | sed 's/^/    /'
    exit 0
else
    echo ""
    echo ">> ✗ FAIL — Stage 11 marker absent. rcS did not complete."
    echo "   Markers found:"
    ls "$BOOT_EXTRACT" 2>/dev/null | grep BOOT_STAGE | sed 's/^/     /' || echo "     (none)"
    exit 1
fi
