#!/bin/bash
# inspect-boot-result.sh — After car boot, pull the SD card and run this.
# Reports what happened with the v16 boot in ONE shot.
#
# Usage: sudo bash /Users/dpitek/Developer/q60-rebuild/scripts/inspect-boot-result.sh [diskN]

set -uo pipefail

TARGET="${1:-disk4}"
BOOT_PART="/dev/${TARGET}s1"
BOOT_MNT="/Volumes/boot"
SLOT_B_TMP="/tmp/slotb-read.img"
SLOT_B_OUT="/tmp/slotb-diag"

hr()  { echo "════════════════════════════════════════════════════════════"; }
hdr() { echo ""; hr; echo "  $*"; hr; }
ok()  { echo "  ✓ $*"; }
miss(){ echo "  ✗ $*"; }
info(){ echo "    $*"; }

[ "$(id -u)" -eq 0 ] || { echo "Run as root: sudo bash $0 [diskN]" >&2; exit 1; }

# ── Also scan any FAT32 partition that might be a USB stick the v17 init
# ── wrote to (in case LAPIS SDHCI failed and /init used the USB fallback)
hdr "Scanning all attached FAT32 volumes for v17 diagnostic output"
for vol in /Volumes/*/V17_SUMMARY.txt; do
    [ -f "$vol" ] || continue
    VDIR=$(dirname "$vol")
    ok "Found v17 diagnostic output at: ${VDIR}"
    echo ""
    echo "  ── V17_SUMMARY.txt ──"
    sed 's/^/    /' "$vol"
    echo ""
    if [ -f "${VDIR}/v17-diag/_R1_BASELINE_CHECK.txt" ]; then
        echo "  ── _R1_BASELINE_CHECK.txt (LAPIS SDHCI answer) ──"
        sed 's/^/    /' "${VDIR}/v17-diag/_R1_BASELINE_CHECK.txt" | head -25
    fi
done

# ── Mount /boot ──────────────────────────────────────────────────────────
hdr "Mounting /boot (${BOOT_PART})"
if ! mount | grep -q " ${BOOT_MNT} "; then
    diskutil mount "${BOOT_PART}" 2>&1
fi
[ -d "${BOOT_MNT}" ] || { echo "  Could not mount ${BOOT_PART}"; exit 1; }

# ── FAT32 markers ────────────────────────────────────────────────────────
hdr "FAT32 /boot diagnostic state"

STAGE_COUNT=$(ls "${BOOT_MNT}"/BOOT_STAGE_*.TXT 2>/dev/null | wc -l | tr -d ' ')
V17_REACHED="no"
[ -f "${BOOT_MNT}/V17_SUMMARY.txt" ] && V17_REACHED="yes"
[ -d "${BOOT_MNT}/v17-diag" ] && V17_REACHED="yes"
DIAG_DIR_EXISTS="no"
[ -d "${BOOT_MNT}/diag" ] && DIAG_DIR_EXISTS="yes"

# Check for v17 initramfs markers FIRST (newest scheme)
if [ "${V17_REACHED}" = "yes" ]; then
    ok "v17 initramfs reached userspace — V17_SUMMARY.txt + v17-diag/ present"
    echo ""
    echo "  ── V17_SUMMARY.txt ──"
    sed 's/^/    /' "${BOOT_MNT}/V17_SUMMARY.txt" 2>/dev/null | head -20
    echo ""
    echo "  ── v17-diag/_R1_BASELINE_CHECK.txt (THE answer for LAPIS SDHCI question) ──"
    sed 's/^/    /' "${BOOT_MNT}/v17-diag/_R1_BASELINE_CHECK.txt" 2>/dev/null | head -25
fi

# Check for v16 BOOT_STAGE markers
if [ "${STAGE_COUNT}" -gt 0 ]; then
    ok "v16 BOOT_STAGE markers: ${STAGE_COUNT} found"
    info "Last stage reached:"
    ls "${BOOT_MNT}"/BOOT_STAGE_*.TXT 2>/dev/null | sort -V | tail -1 | sed 's/^/      /'
    LAST_STAGE_FILE=$(ls "${BOOT_MNT}"/BOOT_STAGE_*.TXT 2>/dev/null | sort -V | tail -1)
    [ -f "${LAST_STAGE_FILE}" ] && info "  Content: $(cat "${LAST_STAGE_FILE}")"
fi

if [ "${STAGE_COUNT}" = "0" ] && [ "${V17_REACHED}" = "no" ]; then
    miss "No v16 markers AND no v17 initramfs markers — kernel didn't reach userspace"
fi

if [ "${DIAG_DIR_EXISTS}" = "yes" ]; then
    ok "/boot/diag/ exists ($(find "${BOOT_MNT}/diag" -type f 2>/dev/null | wc -l | tr -d ' ') files)"
fi

echo ""
echo "  ── Q60_SUMMARY.txt ──"
if [ -f "${BOOT_MNT}/Q60_SUMMARY.txt" ]; then
    sed 's/^/    /' "${BOOT_MNT}/Q60_SUMMARY.txt" | head -30
else
    miss "(absent)"
fi

echo ""
echo "  ── Q60_DISPLAY_GATE.TXT ──"
[ -f "${BOOT_MNT}/Q60_DISPLAY_GATE.TXT" ] && sed 's/^/    /' "${BOOT_MNT}/Q60_DISPLAY_GATE.TXT" || miss "(absent)"

echo ""
echo "  ── elilo.conf default= ──"
if [ -f "${BOOT_MNT}/elilo.conf" ]; then
    DEFAULT_LINE=$(grep '^default=' "${BOOT_MNT}/elilo.conf")
    info "${DEFAULT_LINE}"
    case "${DEFAULT_LINE}" in
        *logan1*) ok "rcS reached Stage 3 (failsafe restore happened)" ;;
        *q60nav*) miss "Still q60nav — rcS never reached Stage 3" ;;
    esac
fi

# Try unmount cleanly
diskutil unmount "${BOOT_MNT}" 2>/dev/null || true

# ── Slot B (rootfs ext4) markers ─────────────────────────────────────────
hdr "Slot B (rootfs ext4) diagnostic state"

[ -b "/dev/${TARGET}s3" ] || { miss "/dev/${TARGET}s3 not found — cannot read Slot B"; exit 0; }

info "Reading Slot B (1.1 GB) to ${SLOT_B_TMP} ..."
dd if="/dev/${TARGET}s3" of="${SLOT_B_TMP}" bs=4m count=275 2>&1 | tail -1

rm -rf "${SLOT_B_OUT}"; mkdir -p "${SLOT_B_OUT}"

docker run --rm --privileged --platform linux/amd64 \
    -v "${SLOT_B_TMP}:/disk.img:ro" \
    -v "${SLOT_B_OUT}:/extract" \
    alpine sh -ec '
        apk add -q util-linux e2fsprogs >/dev/null
        LOOP=$(losetup --show -f -r /disk.img)
        mkdir -p /mnt
        mount -r ${LOOP} /mnt 2>&1

        echo ""
        echo "  ── /RCS_REACHED.MARKER (CRITICAL: proves rcS ran) ──"
        if [ -f /mnt/RCS_REACHED.MARKER ]; then
            sed "s/^/    /" /mnt/RCS_REACHED.MARKER
            cp /mnt/RCS_REACHED.MARKER /extract/RCS_REACHED.MARKER
        else
            echo "    (absent — RCS DID NOT REACH USERSPACE)"
        fi

        echo ""
        echo "  ── /diag-rootfs/ stage markers ──"
        if [ -d /mnt/diag-rootfs ]; then
            ls /mnt/diag-rootfs/STAGE_*.txt 2>/dev/null | sed "s/^/      /" | head -20
            cp -r /mnt/diag-rootfs /extract/ 2>/dev/null
            echo ""
            echo "  ── /diag-rootfs/_stages.log (full sequence) ──"
            sed "s/^/      /" /mnt/diag-rootfs/_stages.log 2>/dev/null || echo "    (no stages log)"
        else
            echo "    (absent)"
        fi

        umount /mnt 2>/dev/null || true
        losetup -d ${LOOP} 2>/dev/null || true
    '

# ── Verdict ──────────────────────────────────────────────────────────────
hdr "VERDICT"

RCS_REACHED="no"
FAT_MARKERS="no"
[ -f "${SLOT_B_OUT}/RCS_REACHED.MARKER" ] && RCS_REACHED="yes"
[ "${STAGE_COUNT}" -gt 0 ] && FAT_MARKERS="yes"

if [ "${V17_REACHED}" = "yes" ]; then
    ok "v17 INITRAMFS REACHED USERSPACE — Phase 1 question answered"
    info "→ Kernel boots through decompress/EFI/early-init successfully"
    info "→ Read v17-diag/_R1_BASELINE_CHECK.txt above to see if LAPIS SDHCI bound"
    info "→ If LAPIS is ✓ bound: v16 rcS-based path was wrong somewhere else"
    info "→ If LAPIS is ✗ unbound: that's the v8-v16 root cause; need different approach"
elif [ "${RCS_REACHED}" = "yes" ] && [ "${FAT_MARKERS}" = "yes" ]; then
    ok "rcS ran AND /boot mount succeeded — read /boot/Q60_SUMMARY.txt for full result"
elif [ "${RCS_REACHED}" = "yes" ] && [ "${FAT_MARKERS}" = "no" ]; then
    echo "  ⚠ rcS ran (rootfs marker exists) but NO /boot markers"
    echo "    → /boot (FAT32) mount failed somehow. LAPIS SDHCI is working (root mount worked)."
    echo "    → check /diag-rootfs/_stages.log to see which stage rcS reached"
elif [ "${RCS_REACHED}" = "no" ] && [ "${FAT_MARKERS}" = "no" ] && [ "${V17_REACHED}" = "no" ]; then
    miss "NOTHING anywhere — kernel never reached userspace"
    info "→ Bug is VERY early: decompress, EFI stub, or driver probe (LAPIS-independent)"
    info "→ Initramfs would have bypassed any block-device dependency — and still nothing"
    info "→ Next: try elilo loader instead of direct UEFI; or stripped-minimal kernel; or factory kernel test"
else
    miss "Inconsistent state — investigate"
fi
