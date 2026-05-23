#!/bin/bash
# deploy-and-go.sh — One-shot: deploy v15 → verify → eject SD card.
#
# Usage:
#   sudo bash /Users/dpitek/Developer/q60-rebuild/scripts/deploy-and-go.sh [diskN]
#
# If diskN is omitted, auto-detects the SD card by looking for a disk with
# a FAT32 partition named "boot" AND a partition typed Linux at s3.
#
# Sequence:
#   1. Confirm target disk
#   2. Verify build artifacts are fresh + kernel is MOVBE-clean (sha256 + size)
#   3. Run deploy-phase1-sd.sh
#   4. Verify deployed BOOTIA32.EFI sha == bzImage sha
#   5. Run verify-slotb.sh
#   6. Eject
#   7. Print car-boot procedure + log-reading commands

set -uo pipefail

SCRIPT_DIR="/Users/dpitek/Developer/q60-rebuild"
KERNEL="${SCRIPT_DIR}/output/bzImage-4.19-q60"
KERNEL_SHA_FILE="${SCRIPT_DIR}/output/bzImage-4.19-q60.sha256"
ROOTFS="${SCRIPT_DIR}/output/q60-diag-rootfs-phase1.img"
RCS_SRC="${SCRIPT_DIR}/rootfs/etc/init.d/rcS"

hr()    { echo "════════════════════════════════════════════════════════════"; }
step()  { echo ""; hr; echo "  $*"; hr; }
ok()    { echo "  ✓ $*"; }
fail()  { echo "  ✗ FAIL: $*" >&2; exit 1; }
info()  { echo "    $*"; }

# ── Sanity: must run as root ─────────────────────────────────────────────
[ "$(id -u)" -eq 0 ] || { echo "Run as root: sudo bash $0 [diskN]" >&2; exit 1; }

step "Q60 v15 deploy-and-go — $(date)"

# ── Step 1: target disk ──────────────────────────────────────────────────
step "STEP 1: target disk"
TARGET="${1:-}"

if [ -z "${TARGET}" ]; then
    # Auto-detect: find a removable disk with a FAT32 "boot" partition at s1
    info "No disk specified — auto-detecting SD card..."
    for d in /dev/disk[0-9] /dev/disk[0-9][0-9]; do
        [ -b "$d" ] || continue
        DN=$(basename "$d")
        # Skip internal disks (disk0, disk1, disk2, disk3 are typical macOS internal/APFS)
        case "$DN" in disk0|disk1|disk2|disk3) continue ;; esac
        # Must have s1 + s3 partitions
        [ -b "/dev/${DN}s1" ] && [ -b "/dev/${DN}s3" ] || continue
        # s1 must be FAT32 named "boot"
        BOOT_INFO=$(diskutil info "/dev/${DN}s1" 2>/dev/null)
        echo "${BOOT_INFO}" | grep -q "Volume Name:.*boot" && \
        echo "${BOOT_INFO}" | grep -qiE "MS-DOS|FAT" && {
            TARGET="${DN}"
            ok "Auto-detected: ${TARGET}"
            break
        }
    done
    [ -n "${TARGET}" ] || fail "No SD card found. Insert card and rerun, or pass diskN explicitly."
fi

[ -b "/dev/${TARGET}" ]      || fail "/dev/${TARGET} not found"
[ -b "/dev/${TARGET}s1" ]    || fail "/dev/${TARGET}s1 (boot partition) not found"
[ -b "/dev/${TARGET}s3" ]    || fail "/dev/${TARGET}s3 (Slot B) not found"
ok "Target: /dev/${TARGET}  (s1=boot, s3=Slot B)"
diskutil info "/dev/${TARGET}" 2>/dev/null | grep -E "Device.*Identifier|Size|Removable|Volume Name" | sed 's/^/    /' | head -5

# ── Step 2: build-artifact sanity ────────────────────────────────────────
step "STEP 2: build-artifact sanity (kernel + rootfs + rcS)"

[ -f "${KERNEL}" ]          || fail "kernel not found: ${KERNEL}"
[ -f "${KERNEL_SHA_FILE}" ] || fail "sha file not found: ${KERNEL_SHA_FILE}"
[ -f "${ROOTFS}" ]          || fail "rootfs not found: ${ROOTFS}"
[ -f "${RCS_SRC}" ]         || fail "rcS source not found: ${RCS_SRC}"

KSIZE=$(stat -f%z "${KERNEL}")
RSIZE=$(stat -f%z "${ROOTFS}")
KSHA=$(shasum -a 256 "${KERNEL}" | awk '{print $1}')
SHA_RECORD=$(awk '{print $1}' "${KERNEL_SHA_FILE}")
RCS_SHA=$(shasum -a 256 "${RCS_SRC}" | awk '{print $1}')

info "Kernel: ${KSIZE} bytes  sha=${KSHA:0:16}..."
info "Rootfs: $((RSIZE / 1048576)) MB"
info "rcS:    sha=${RCS_SHA:0:16}..."

[ "${KSHA}" = "${SHA_RECORD}" ] || fail "kernel sha mismatch with recorded ${SHA_RECORD:0:16}... — rebuild via scripts/build-kernel.sh"
ok "kernel sha matches recorded value"
[ "${KSIZE}" -lt 4194304 ] || fail "kernel too large (${KSIZE} > 4 MB elilo limit)"
ok "kernel size under elilo/EFI limit"

# Verify rootfs has the latest rcS baked in (catch missed patch-rootfs-rcS step)
EMBEDDED_SHA=$(docker run --rm --privileged --platform linux/amd64 -v "${ROOTFS}:/r.img:ro" \
    alpine sh -ec '
        apk add -q util-linux e2fsprogs 2>/dev/null >/dev/null
        LOOP=$(losetup --show -f -r /r.img)
        mkdir -p /mnt; mount -r ${LOOP} /mnt
        sha256sum /mnt/etc/init.d/rcS | awk "{print \$1}"
        umount /mnt; losetup -d ${LOOP}
    ' 2>/dev/null | tail -1)

if [ "${EMBEDDED_SHA}" = "${RCS_SHA}" ]; then
    ok "rootfs contains latest rcS"
else
    info "rootfs has stale rcS (embedded=${EMBEDDED_SHA:0:16}..., source=${RCS_SHA:0:16}...)"
    info "Running patch-rootfs-rcS.sh to refresh..."
    bash "${SCRIPT_DIR}/scripts/patch-rootfs-rcS.sh" 2>&1 | tail -3 || fail "rootfs patch failed"
    ok "rootfs rcS refreshed"
fi

# ── Step 3: deploy ───────────────────────────────────────────────────────
step "STEP 3: deploy to /dev/${TARGET}"
bash "${SCRIPT_DIR}/scripts/deploy-phase1-sd.sh" -y "${TARGET}" || fail "deploy failed"

# ── Step 4: verify BOOTIA32.EFI sha == kernel sha ────────────────────────
step "STEP 4: verify BOOTIA32.EFI matches new kernel"
diskutil mount "/dev/${TARGET}s1" >/dev/null 2>&1 || true
BOOT_MNT="/Volumes/boot"
[ -d "${BOOT_MNT}" ] || fail "boot partition didn't mount at ${BOOT_MNT}"

BIA_SHA=$(shasum -a 256 "${BOOT_MNT}/EFI/BOOT/BOOTIA32.EFI" 2>/dev/null | awk '{print $1}')
VLZ_SHA=$(shasum -a 256 "${BOOT_MNT}/vmlinuz-4.19-q60" 2>/dev/null | awk '{print $1}')

[ "${BIA_SHA}" = "${KSHA}" ] || fail "BOOTIA32.EFI sha mismatch (deploy bug — UEFI will load wrong kernel)"
ok "BOOTIA32.EFI sha matches: ${BIA_SHA:0:16}..."
[ "${VLZ_SHA}" = "${KSHA}" ] || fail "vmlinuz-4.19-q60 sha mismatch"
ok "vmlinuz-4.19-q60 sha matches"

grep -q '^default=q60nav$' "${BOOT_MNT}/elilo.conf" || fail "elilo.conf default is not q60nav"
ok "elilo.conf default=q60nav (rcS will restore to logan1 after boot)"

grep -q 'root=/dev/mmcblk0p3' "${BOOT_MNT}/elilo.conf" || fail "elilo.conf missing root=/dev/mmcblk0p3"
ok "elilo.conf has correct root= path"

diskutil unmount "${BOOT_MNT}" >/dev/null 2>&1 || true

# ── Step 5: verify Slot B ─────────────────────────────────────────────────
step "STEP 5: verify-slotb (rootfs integrity)"
bash "${SCRIPT_DIR}/scripts/verify-slotb.sh" "${TARGET}" || fail "verify-slotb failed — re-run deploy"

# ── Step 6: eject ────────────────────────────────────────────────────────
step "STEP 6: eject"
diskutil eject "${TARGET}" 2>&1 | sed 's/^/    /' || fail "eject failed — close any Finder windows"
ok "SD card ejected"

# ── Done ──────────────────────────────────────────────────────────────────
echo ""
hr
echo "  READY FOR CAR BOOT"
hr
cat <<'EOF'

  In the car:
    1. Insert SD card into the dash slot
    2. Power up the head unit
    3. Wait. The unit will power off on its own in ~45-90 seconds.
       Display may stay black the entire time — that is NOT a failure signal.
    4. If still on after 3 minutes: ignition off.

  After power-off:
    1. Pull SD card, insert in Mac
    2. Run:
         diskutil mount /dev/disk4s1   # (adjust disk number if different)
         cat /Volumes/boot/Q60_SUMMARY.txt
         cat /Volumes/boot/diag/_R1_BASELINE_CHECK.txt
         ls /Volumes/boot/diag/pstore/    # if non-empty: prior-boot panic — read first

  Interpreting the gate:
    PASS              — gma500 bound + /dev/fb0 present (Phase 1 win)
    PARTIAL-NO-FB     — gma500 claimed PCI but no fb (modeset failed)
    PARTIAL-OTHER-FB  — fb from efifb/simplefb fallback (still useful)
    FAIL              — gma500 didn't bind; check _R1_BASELINE_CHECK + diag/dmesg/

EOF
