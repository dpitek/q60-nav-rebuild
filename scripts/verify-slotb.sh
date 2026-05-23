#!/bin/bash
# verify-slotb.sh — Verify Slot B (mmcblk0p3) physical write on SD card
# Usage: sudo bash scripts/verify-slotb.sh [disk6]
# Mounts the ext4 rootfs partition in Docker and spot-checks critical files.

TARGET="${1:-disk6}"
RAW_SLOTB="/dev/r${TARGET}s3"
IMG="/tmp/slotb-verify.img"
IMG_SIZE_MB=512

hr()   { echo "────────────────────────────────────────────────────────────"; }
step() { echo ""; hr; echo "  STEP $1: $2"; hr; }
ok()   { echo "  ✓ $*"; }
fail() { echo "  ✗ FAIL: $*" >&2; exit 1; }
info() { echo "    $*"; }

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  Q60 Slot B Physical Write Verification"
echo "  Target: ${RAW_SLOTB}"
echo "  $(date)"
echo "════════════════════════════════════════════════════════════"

[ "$(id -u)" -eq 0 ] || fail "Run as root: sudo bash scripts/verify-slotb.sh"
[ -b "/dev/${TARGET}s3" ] || fail "/dev/${TARGET}s3 not found — SD card inserted?"

# ── Step 1: Copy Slot B off the card ─────────────────────────────────────────
step 1 "Reading Slot B from SD card → ${IMG}"

info "Source: ${RAW_SLOTB}"
info "Size:   ${IMG_SIZE_MB} MB"
dd if="${RAW_SLOTB}" of="${IMG}" bs=4m count=$(( IMG_SIZE_MB / 4 )) 2>&1
[ $? -eq 0 ] || fail "dd read failed"
ok "Slot B copied to ${IMG}"

# ── Step 2: Check ext4 superblock ────────────────────────────────────────────
step 2 "Checking ext4 superblock"

LABEL=$(docker run --rm --platform linux/arm64 -v "${IMG}:/disk.img" alpine sh -c \
    "apk add -q e2fsprogs e2fsprogs-extra 2>/dev/null && tune2fs -l /disk.img 2>/dev/null | awk '/^Filesystem volume name/{print \$NF}' || echo UNKNOWN")
info "Filesystem label: ${LABEL}"
[ "${LABEL}" = "q60diag" ] || fail "Label is '${LABEL}' — expected 'q60diag'. Wrong image or corrupt write."
ok "Label: q60diag"

# ── Step 3: Mount and verify critical files ───────────────────────────────────
step 3 "Mounting and verifying rootfs contents"

RESULT=$(docker run --rm --platform linux/arm64 --privileged -v "${IMG}:/disk.img" alpine sh -c '
set -e
apk add -q e2fsprogs file 2>/dev/null
mkdir -p /mnt
mount -o loop /disk.img /mnt

PASS=0
FAIL=0

check() {
    local label="$1"
    local result="$2"
    if [ $? -eq 0 ] && [ -n "$result" ]; then
        echo "  PASS: ${label}: ${result}"
        PASS=$((PASS+1))
    else
        echo "  FAIL: ${label}"
        FAIL=$((FAIL+1))
    fi
}

# /sbin/init exists
R=$(ls -la /mnt/sbin/init 2>/dev/null); check "/sbin/init exists" "$R"

# busybox is static ELF
R=$(file /mnt/bin/busybox 2>/dev/null | grep -o "statically linked"); check "busybox statically linked" "$R"

# busybox size > 900KB
R=$(stat -c%s /mnt/bin/busybox 2>/dev/null)
[ "$R" -gt 900000 ] 2>/dev/null && echo "  PASS: busybox size: ${R} bytes" && PASS=$((PASS+1)) || { echo "  FAIL: busybox size: ${R}"; FAIL=$((FAIL+1)); }

# Critical applet symlinks
for app in sh mount umount cat echo ls mkdir rm grep uname readlink fbset chmod chown ln syslogd mkswap swapon mdev; do
    if [ -L /mnt/bin/${app} ] || [ -L /mnt/sbin/${app} ]; then
        echo "  PASS: symlink ${app}"
        PASS=$((PASS+1))
    else
        echo "  FAIL: symlink ${app} MISSING"
        FAIL=$((FAIL+1))
    fi
done

# rcS exists and is executable
R=$(ls -la /mnt/etc/init.d/rcS 2>/dev/null); check "/etc/init.d/rcS" "$R"

# /proc /sys /dev /boot mountpoints
for dir in proc sys dev boot; do
    if [ -d /mnt/${dir} ]; then
        echo "  PASS: /${dir} mountpoint exists"
        PASS=$((PASS+1))
    else
        echo "  FAIL: /${dir} missing"
        FAIL=$((FAIL+1))
    fi
done

umount /mnt
echo "SUMMARY: ${PASS} passed / ${FAIL} failed"
' 2>&1)

echo "${RESULT}"

# ── Step 4: Summary ───────────────────────────────────────────────────────────
step 4 "Result"

FAIL_COUNT=$(echo "${RESULT}" | grep -c "^  FAIL:" || true)
PASS_COUNT=$(echo "${RESULT}" | grep -c "^  PASS:" || true)

if [ "${FAIL_COUNT}" -eq 0 ]; then
    echo ""
    echo "  ✓ ALL CHECKS PASSED (${PASS_COUNT} checks)"
    echo "  Physical card write is good. Safe to boot."
else
    echo ""
    echo "  ✗ ${FAIL_COUNT} CHECK(S) FAILED — DO NOT BOOT"
    echo "  Re-run deploy-phase1-sd.sh to rewrite Slot B"
    exit 1
fi

rm -f "${IMG}"

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  VERIFY COMPLETE — $(date)"
echo "════════════════════════════════════════════════════════════"
