#!/bin/bash
# deploy-phase1-sd.sh — Write Phase 1 diagnostic image to SD card
# Usage: sudo bash scripts/deploy-phase1-sd.sh [-y] [disk6]
# Default target: /dev/disk6 (physical SD card)
#
# Writes ONLY two partitions — boot (p1) and Slot B (p3).
# Slot A (factory) and all other partitions are untouched.

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
AUTO_YES=0
TARGET=""
for arg in "$@"; do
    case "$arg" in
        -y|--yes) AUTO_YES=1 ;;
        disk*) TARGET="$arg" ;;
    esac
done

if [ -z "$TARGET" ]; then
    echo "  ✗ ERROR: target disk not specified" >&2
    echo "  Usage: sudo bash $0 [-y] diskN" >&2
    echo "  Run 'diskutil list' first to identify the SD card." >&2
    exit 1
fi

TARGET_DEV="/dev/${TARGET}"
RAW_DEV="/dev/r${TARGET}"
BOOT_PART="${TARGET_DEV}s1"
SLOTB_PART="${TARGET_DEV}s3"
RAW_SLOTB="/dev/r${TARGET}s3"
KERNEL_SRC="${SCRIPT_DIR}/output/bzImage-4.19-q60"
ROOTFS_SRC="${SCRIPT_DIR}/output/q60-diag-rootfs-phase1.img"

hr()   { echo "────────────────────────────────────────────────────────────"; }
step() { echo ""; hr; echo "  STEP $1: $2"; hr; }
ok()   { echo "  ✓ $*"; }
fail() { echo "  ✗ ERROR: $*" >&2; exit 1; }
info() { echo "    $*"; }

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  Q60 Phase 1 — SD Card Deploy"
echo "  $(date)"
echo "════════════════════════════════════════════════════════════"

# ── Step 1: Pre-flight checks ─────────────────────────────────────────────────
step 1 "Pre-flight checks"

[ "$(id -u)" -eq 0 ] || fail "Not running as root. Use: sudo bash scripts/deploy-phase1-sd.sh -y"
ok "Running as root"

[ -b "${TARGET_DEV}" ] || fail "${TARGET_DEV} not found — is the SD card plugged in?"
ok "Target device: ${TARGET_DEV}"

DISK_INFO=$(diskutil info "${TARGET_DEV}" 2>/dev/null)
DISK_SIZE=$(echo "$DISK_INFO" | grep "Disk Size" | head -1 | awk '{print $3, $4}')
info "Disk size: ${DISK_SIZE}"

[ -b "${BOOT_PART}" ] || fail "Boot partition ${BOOT_PART} not found"
ok "Boot partition: ${BOOT_PART}"

[ -b "${SLOTB_PART}" ] || fail "Slot B partition ${SLOTB_PART} not found"
ok "Slot B partition: ${SLOTB_PART}"

[ -f "${KERNEL_SRC}" ] || fail "Kernel not found: ${KERNEL_SRC}"
KERNEL_SIZE=$(stat -f%z "${KERNEL_SRC}")
ok "Kernel: ${KERNEL_SRC} (${KERNEL_SIZE} bytes)"

[ -f "${ROOTFS_SRC}" ] || fail "Rootfs not found: ${ROOTFS_SRC}"
ROOTFS_SIZE=$(stat -f%z "${ROOTFS_SRC}")
ROOTFS_MB=$((ROOTFS_SIZE / 1048576))
ok "Rootfs: ${ROOTFS_SRC} (${ROOTFS_MB} MB)"

echo ""
echo "  What will be written:"
echo "    ${SLOTB_PART}  ← ${ROOTFS_MB} MB diagnostic rootfs (q60diag)"
echo "    ${BOOT_PART}   ← kernel vmlinuz-4.19-q60 + elilo.conf updated"
echo "    All other partitions: UNTOUCHED"
echo ""

if [ "$AUTO_YES" -eq 0 ]; then
    read -rp "  Type 'yes' to continue: " confirm
    [ "$confirm" = "yes" ] || { echo "  Aborted."; exit 0; }
else
    echo "  Auto-confirmed (-y)"
fi

# ── Step 2: Unmount all partitions on this disk ───────────────────────────────
step 2 "Unmounting all partitions on ${TARGET_DEV}"

info "Running: diskutil unmountDisk force ${TARGET_DEV}"
if diskutil unmountDisk force "${TARGET_DEV}" 2>&1; then
    ok "All partitions unmounted"
else
    fail "Failed to unmount ${TARGET_DEV} — close any Finder windows using it and retry"
fi

# ── Step 3: Write Slot B (diagnostic rootfs) ──────────────────────────────────
step 3 "Writing Slot B (diagnostic rootfs → ${SLOTB_PART})"

info "Source: ${ROOTFS_SRC}"
info "Dest:   ${RAW_SLOTB}"
info "Size:   ${ROOTFS_MB} MB — this will take ~30–60 seconds on a real SD card"
echo ""

dd if="${ROOTFS_SRC}" of="${RAW_SLOTB}" bs=4m 2>&1
DD_RC=$?
[ "$DD_RC" -eq 0 ] || fail "dd failed writing Slot B (exit code ${DD_RC})"
sync
ok "Slot B written successfully"

# ── Step 4: Mount boot partition and update it ────────────────────────────────
step 4 "Updating boot partition (${BOOT_PART})"

BOOT_MNT=$(mktemp -d /tmp/q60-boot-XXXXXX)
info "Mounting ${BOOT_PART} at ${BOOT_MNT}"

mount -t msdos "${BOOT_PART}" "${BOOT_MNT}"
MNT_RC=$?
[ "$MNT_RC" -eq 0 ] || fail "Failed to mount ${BOOT_PART} (exit code ${MNT_RC})"
ok "Boot partition mounted at ${BOOT_MNT}"

# Write kernel
info "Copying kernel: vmlinuz-4.19-q60 (${KERNEL_SIZE} bytes)"
cp "${KERNEL_SRC}" "${BOOT_MNT}/vmlinuz-4.19-q60"
ok "Kernel written to vmlinuz-4.19-q60"

# Verify kernel landed
WRITTEN_SIZE=$(stat -f%z "${BOOT_MNT}/vmlinuz-4.19-q60" 2>/dev/null || echo 0)
info "Kernel on disk: ${WRITTEN_SIZE} bytes"
[ "${WRITTEN_SIZE}" -eq "${KERNEL_SIZE}" ] || fail "Kernel size mismatch (expected ${KERNEL_SIZE}, got ${WRITTEN_SIZE})"
ok "Kernel size verified"

# CRITICAL: also write kernel to EFI/BOOT/BOOTIA32.EFI — this is what UEFI
# actually loads via the removable-media default fallback path. elilo is never
# invoked because UEFI loads BOOTIA32.EFI directly via the EFI stub.
# Without this step, deploying a new kernel is a no-op for the actual boot.
mkdir -p "${BOOT_MNT}/EFI/BOOT"
info "Copying kernel to UEFI default fallback: EFI/BOOT/BOOTIA32.EFI"
cp "${KERNEL_SRC}" "${BOOT_MNT}/EFI/BOOT/BOOTIA32.EFI"
WRITTEN_BIA=$(stat -f%z "${BOOT_MNT}/EFI/BOOT/BOOTIA32.EFI" 2>/dev/null || echo 0)
[ "${WRITTEN_BIA}" -eq "${KERNEL_SIZE}" ] || fail "BOOTIA32.EFI size mismatch (expected ${KERNEL_SIZE}, got ${WRITTEN_BIA})"
ok "BOOTIA32.EFI written — UEFI will now load v14 kernel directly"

# ── Step 5: elilo.conf ────────────────────────────────────────────────────────
step 5 "Updating elilo.conf"

ELILO="${BOOT_MNT}/elilo.conf"
[ -f "${ELILO}" ] || fail "elilo.conf not found at ${ELILO}"
info "Current elilo.conf:"
sed 's/^/    /' "${ELILO}"
echo ""

# Add q60nav entry if missing
if ! grep -q "label=q60nav" "${ELILO}"; then
    info "q60nav entry missing — adding it"
    printf '\nimage=vmlinuz-4.19-q60\n\tlabel=q60nav\n\tdescription="Q60 Phase 1 Diagnostic (Linux 4.19)"\n\troot=/dev/mmcblk0p3\n\tappend="rw rootwait console=ttyPCH0,115200n8 console=tty0 loglevel=8 ignore_loglevel nokaslr idle=halt ehci_hcd.log2_irq_thresh=2 memmap=2M$52M memmap=10M$54M panic=10 dram=on video=efifb:off acpi_backlight=native video=LVDS-1:800x480@60 video=LVDS-2:800x420@60"\n' >> "${ELILO}"
    ok "q60nav entry added"
else
    # Update append line in existing entry to fix cmdline (in-place)
    # Use Python — BSD sed can't handle range+substitution blocks with special chars like $52M
    info "q60nav entry present — updating append cmdline"
    python3 - "${ELILO}" <<'PYEOF'
import sys, re

path = sys.argv[1]
new_append = '\tappend="root=/dev/mmcblk0p3 rw rootwait console=ttyPCH0,115200n8 console=tty0 loglevel=8 ignore_loglevel nokaslr idle=halt ehci_hcd.log2_irq_thresh=2 memmap=2M$52M memmap=10M$54M panic=10 dram=on video=efifb:off acpi_backlight=native video=LVDS-1:800x480@60 video=LVDS-2:800x420@60"'

with open(path, 'r') as f:
    lines = f.readlines()

in_q60nav = False
out = []
for line in lines:
    if re.search(r'label=q60nav', line):
        in_q60nav = True
    elif in_q60nav and re.match(r'^[^ \t]', line) and not re.search(r'label=q60nav', line):
        # Next top-level key — we left the q60nav stanza
        in_q60nav = False
    if in_q60nav and re.match(r'[ \t]*append=', line):
        out.append(new_append + '\n')
    else:
        out.append(line)

with open(path, 'w') as f:
    f.writelines(out)
print("  append line updated")
PYEOF
    ok "q60nav append cmdline updated"
fi

# Set default=q60nav — rcS restores logan1 on first boot automatically
sed -i '' 's/^default=.*/default=q60nav/' "${ELILO}"
ok "Set default=q60nav (rcS will restore to logan1 on boot)"

echo ""
info "Updated elilo.conf:"
sed 's/^/    /' "${ELILO}"

# ── Step 6: Sync and unmount ──────────────────────────────────────────────────
step 6 "Syncing and unmounting"

sync
ok "Sync complete"

umount "${BOOT_MNT}" 2>/dev/null && ok "Boot partition unmounted" || {
    diskutil unmount force "${BOOT_PART}" 2>/dev/null && ok "Boot partition force-unmounted" || \
    echo "  Warning: unmount returned non-zero (usually harmless on macOS)"
}
rmdir "${BOOT_MNT}" 2>/dev/null || true

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════"
echo "  DEPLOY COMPLETE"
echo "  $(date)"
echo ""
echo "  SD card is ready. Eject and put in the car."
echo "  Car will boot q60nav diagnostic, run ~2 minutes, power off."
echo ""
echo "  After car powers off, re-insert SD card and read logs:"
echo "    cat /Volumes/boot/Q60_DISPLAY_GATE.TXT   ← PASS or FAIL"
echo "    cat /Volumes/boot/Q60_DRM_STATE.LOG       ← gma500 details"
echo "    cat /Volumes/boot/Q60_DMESG_POST_GFX.LOG ← kernel output"
echo "    cat /Volumes/boot/Q60_DIAG_STAGES.LOG    ← boot timeline"
echo "════════════════════════════════════════════════════════════"
