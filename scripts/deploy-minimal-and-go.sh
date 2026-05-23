#!/bin/bash
# deploy-minimal-and-go.sh — Test C deploy: bare-bones kernel at multiple
# file paths on BOTH the SD card AND the USB stick. Belt-and-suspenders:
# if the DCU's UEFI looks at any non-standard boot path, we have it covered.
#
# Usage: sudo bash /Users/dpitek/Developer/q60-rebuild/scripts/deploy-minimal-and-go.sh

set -uo pipefail

SCRIPT_DIR="/Users/dpitek/Developer/q60-rebuild"
KERNEL="${SCRIPT_DIR}/output/bzImage-4.19-q60-minimal"
KSHA=$(shasum -a 256 "${KERNEL}" | awk '{print $1}')

hr()  { echo "════════════════════════════════════════════════════════════"; }
step(){ echo ""; hr; echo "  $*"; hr; }
ok()  { echo "  ✓ $*"; }
fail(){ echo "  ✗ FAIL: $*" >&2; exit 1; }
info(){ echo "    $*"; }

# No sudo needed — we only cp to mounted FAT32 partitions, not raw block writes.
[ -f "${KERNEL}" ]   || fail "minimal kernel not built — run scripts/build-kernel-minimal.sh"
KSIZE=$(stat -f%z "${KERNEL}")

step "Test C deploy — bare-bones kernel at multiple paths"
info "Kernel:  ${KERNEL}  ($((KSIZE/1024)) KB, sha=${KSHA:0:16}...)"

# ── Auto-detect SD card + USB stick ─────────────────────────────────
SD_DISK=""
USB_DISK=""
for d in /dev/disk[0-9] /dev/disk[0-9][0-9]; do
    [ -b "$d" ] || continue
    DN=$(basename "$d")
    case "$DN" in disk0|disk1|disk2|disk3) continue ;; esac
    INFO=$(diskutil info "$d" 2>/dev/null)
    if [ -b "/dev/${DN}s1" ] && [ -b "/dev/${DN}s3" ]; then
        # 9-partition SD card layout
        SD_DISK="$DN"
        ok "Auto-detected SD card: /dev/${SD_DISK}"
    elif [ -b "/dev/${DN}s1" ] && echo "${INFO}" | grep -qi "Flash"; then
        USB_DISK="$DN"
        ok "Auto-detected USB stick: /dev/${USB_DISK}"
    fi
done
[ -n "$SD_DISK" ]  || fail "no SD card found"
[ -n "$USB_DISK" ] || info "(no USB stick — will deploy SD only)"

# ── Deploy to SD card boot partition ─────────────────────────────────
step "STEP 1: SD card boot partition (s1, FAT32)"
diskutil mount "/dev/${SD_DISK}s1" >/dev/null 2>&1 || true
SD_MNT="/Volumes/boot"
[ -d "${SD_MNT}" ] || fail "${SD_MNT} not mounted"

# Drop kernel at MANY possible UEFI/bootloader-looked-up paths
PATHS=(
    "/EFI/BOOT/BOOTIA32.EFI"          # standard UEFI removable-media fallback (i386)
    "/EFI/BOOT/BOOTX64.EFI"           # 64-bit fallback (Tunnel Creek is i386 but worth a shot)
    "/EFI/INFINITI/BOOTIA32.EFI"
    "/EFI/CLARION/BOOTIA32.EFI"
    "/EFI/QY5092/BOOTIA32.EFI"
    "/EFI/Q60/BOOTIA32.EFI"
    "/bzImage"
    "/vmlinuz"
    "/vmlinuz-4.19-q60"
    "/vmlinuz-minimal"
    "/Image"
)
for p in "${PATHS[@]}"; do
    target="${SD_MNT}${p}"
    mkdir -p "$(dirname "${target}")" 2>/dev/null
    cp "${KERNEL}" "${target}" 2>/dev/null && ok "  wrote ${p}" || info "  skip ${p} (permission/error)"
done

# Update elilo.conf so the elilo path also points to the new kernel
if [ -f "${SD_MNT}/elilo.conf" ]; then
    python3 - "${SD_MNT}/elilo.conf" <<'PYEOF'
import sys, re
p = sys.argv[1]
new_append = '\tappend="init=/init console=ttyPCH0,115200n8 console=tty0 loglevel=8 ignore_loglevel debug printk.time=1 nokaslr idle=halt ehci_hcd.log2_irq_thresh=2 memmap=2M$52M memmap=10M$54M mem=1G panic=10 dram=on video=efifb:off acpi_backlight=native nomodeset initcall_debug ramoops.mem_address=0x3400000 ramoops.mem_size=0x100000 printk.devkmsg=on pause_on_oops=10"'
with open(p) as f: lines = f.readlines()
in_q60nav = False
out = []
for line in lines:
    if re.search(r'label=q60nav', line):
        in_q60nav = True
    elif in_q60nav and re.match(r'^[^ \t]', line) and not re.search(r'label=q60nav', line):
        in_q60nav = False
    if in_q60nav and re.match(r'[ \t]*append=', line):
        out.append(new_append + '\n')
    else:
        out.append(line)
with open(p, 'w') as f: f.writelines(out)
PYEOF
    # set default=q60nav
    sed -i '' 's/^default=.*/default=q60nav/' "${SD_MNT}/elilo.conf"
    ok "  elilo.conf updated (default=q60nav, max-debug cmdline)"
fi

sync
diskutil unmount "${SD_MNT}" >/dev/null 2>&1 || true

# ── Deploy to USB stick ──────────────────────────────────────────────
if [ -n "$USB_DISK" ]; then
    step "STEP 2: USB stick (FAT32)"
    diskutil mount "/dev/${USB_DISK}s1" >/dev/null 2>&1 || true
    # USB stick may be mounted at /Volumes/<name>; find it
    USB_MNT=""
    for V in /Volumes/*; do
        [ -d "$V" ] || continue
        MOUNT_DEV=$(diskutil info "$V" 2>/dev/null | grep "Device Identifier" | awk '{print $NF}')
        [ "${MOUNT_DEV}" = "${USB_DISK}s1" ] && { USB_MNT="$V"; break; }
    done
    if [ -n "$USB_MNT" ]; then
        for p in "${PATHS[@]}"; do
            target="${USB_MNT}${p}"
            mkdir -p "$(dirname "${target}")" 2>/dev/null
            cp "${KERNEL}" "${target}" 2>/dev/null && ok "  wrote USB${p}" || true
        done
        sync
        diskutil unmount "${USB_MNT}" >/dev/null 2>&1 || true
    else
        info "USB stick mount path not found — skipping USB deploy"
    fi
fi

# ── Eject ──
step "STEP 3: Eject"
diskutil eject "${SD_DISK}" 2>&1 | sed 's/^/    /' || fail "SD eject failed"
[ -n "$USB_DISK" ] && diskutil eject "${USB_DISK}" 2>&1 | sed 's/^/    /' || true

echo ""
hr
echo "  READY"
hr
cat <<EOF

  Both SD card and USB stick ejected.
  Insert BOTH into the car (SD in slot, USB stick in USB port).
  Power up — wait for power-down or ~3 min timeout.
  Pull SD + USB, insert in Mac.
  Run: sudo bash ${SCRIPT_DIR}/scripts/inspect-boot-result.sh

  This time the inspector looks at /Volumes/* for V17_SUMMARY.txt —
  so it'll find diagnostic output regardless of which device the DCU
  actually managed to boot from.

EOF
