#!/bin/bash
# build-kernel-3.4.sh — Build Linux 3.4.113 minimal for Q60 nav rebuild.
#
# Uses Ubuntu 18.04 + gcc-7 to avoid modern-gcc-11 incompatibilities that
# would force patching old kernel source.
# Embeds the same diagnostic initramfs as Test C (Linux 4.19) so /init
# script and capture channels are identical.
#
# Output: output/bzImage-3.4-q60 + sha256
# Doesn't touch v17 or Test C kernels — all three coexist.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL_DIR="${SCRIPT_DIR}/kernel-3.4"
OUTPUT_DIR="${SCRIPT_DIR}/output"
OUTPUT_BZ="${OUTPUT_DIR}/bzImage-3.4-q60"
OUTPUT_SHA="${OUTPUT_BZ}.sha256"

[ -d "${KERNEL_DIR}" ] || { echo "kernel-3.4 source not found at ${KERNEL_DIR}"; exit 1; }
[ -f "${OUTPUT_DIR}/initramfs.cpio.gz" ] || {
    echo "initramfs.cpio.gz not found — run scripts/build-initramfs.sh first"; exit 1; }
docker info >/dev/null 2>&1 || { echo "Docker not reachable"; exit 1; }

echo "════════════════════════════════════════════════════════════"
echo "  Linux 3.4.113 minimal build for Q60"
echo "  $(date)"
echo "════════════════════════════════════════════════════════════"

docker run --rm \
    --platform linux/amd64 \
    -v "${KERNEL_DIR}:/k" \
    -v "${OUTPUT_DIR}:/k-output" \
    ubuntu:16.04 \
    bash -c '
        set -euo pipefail
        export DEBIAN_FRONTEND=noninteractive

        echo ">> apt install: build-essential, gcc-multilib, bc, bison, flex, ssl, etc."
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq --no-install-recommends \
            build-essential gcc-multilib bc bison flex \
            libssl-dev libelf-dev xz-utils kmod cpio binutils \
            ncurses-dev perl python3 \
            >/dev/null 2>&1 || true

        echo ">> gcc version:"
        gcc --version | head -1

        cd /k

        # ── Step 1: i386 defconfig as baseline ─────────────────────────
        echo ">> make ARCH=i386 i386_defconfig"
        make ARCH=i386 i386_defconfig 2>&1 | tail -3

        # ── Step 2: apply Q60-specific config overrides ─────────────────
        echo ">> applying Q60 config overrides"
        cat > /tmp/q60.config <<EOF
# CPU — Bonnell baseline (no MOVBE)
CONFIG_M686=y
# CONFIG_MATOM is not set
CONFIG_X86_GENERIC=y

# Memory
CONFIG_HIGHMEM64G=y
CONFIG_X86_PAE=y

# EFI stub for direct UEFI load (Tunnel Creek is i386)
CONFIG_EFI=y
CONFIG_EFI_STUB=y
CONFIG_RELOCATABLE=y

# XZ compression for small bzImage
CONFIG_KERNEL_XZ=y
# CONFIG_KERNEL_GZIP is not set

# Embedded initramfs
CONFIG_BLK_DEV_INITRD=y
CONFIG_INITRAMFS_SOURCE="/k-output/initramfs.cpio.gz"
CONFIG_INITRAMFS_ROOT_UID=0
CONFIG_INITRAMFS_ROOT_GID=0
CONFIG_INITRAMFS_COMPRESSION_GZIP=y
CONFIG_RD_GZIP=y

# Embedded cmdline (defense if loader passes nothing)
CONFIG_CMDLINE_BOOL=y
CONFIG_CMDLINE="init=/init console=ttyPCH0,115200n8 console=ttyS0,115200n8 loglevel=8 ignore_loglevel debug printk.time=1 idle=halt panic=10 mem=1G nokaslr ramoops.mem_address=0x3400000 ramoops.mem_size=0x100000 printk.devkmsg=on"

# Capture channels
CONFIG_PSTORE=y
CONFIG_PSTORE_RAM=y
CONFIG_EFI_VARS=y
CONFIG_NVRAM=y
CONFIG_RTC_CLASS=y
CONFIG_RTC_DRV_CMOS=y

# PCH UART for diagnostic console (matches factory ttyPCH0)
CONFIG_SERIAL_PCH_UART=y
CONFIG_SERIAL_PCH_UART_CONSOLE=y

# Basics
CONFIG_BINFMT_ELF=y
CONFIG_PROC_FS=y
CONFIG_SYSFS=y
CONFIG_DEVTMPFS=y
CONFIG_DEVTMPFS_MOUNT=y
CONFIG_TMPFS=y
CONFIG_TTY=y
CONFIG_ACPI=y
CONFIG_X86_LOCAL_APIC=y
CONFIG_X86_IO_APIC=y
CONFIG_PCI=y
CONFIG_PCI_MMCONFIG=y

# MMC + LAPIS SDHCI patch (added in source tree above)
CONFIG_MMC=y
CONFIG_MMC_BLOCK=y
CONFIG_MMC_SDHCI=y
CONFIG_MMC_SDHCI_PCI=y
CONFIG_PCH_PHUB=y
CONFIG_VFAT_FS=y
CONFIG_FAT_FS=y
CONFIG_NLS_CODEPAGE_437=y
CONFIG_NLS_ISO8859_1=y
CONFIG_NLS=y
CONFIG_MSDOS_PARTITION=y
CONFIG_EFI_PARTITION=y
CONFIG_PARTITION_ADVANCED=y
CONFIG_EXT4_FS=y
CONFIG_BLOCK=y
CONFIG_BLK_DEV=y

# Disable everything that could hang at probe
# CONFIG_DRM is not set
# CONFIG_FB is not set
# CONFIG_VT is not set
# CONFIG_USB_SUPPORT is not set
# CONFIG_HID is not set
# CONFIG_INPUT is not set
# CONFIG_INTEL_IDLE is not set
# CONFIG_X86_INTEL_MID is not set
# CONFIG_SCSI is not set
# CONFIG_ATA is not set
# CONFIG_MD is not set
# CONFIG_NETFILTER is not set
# CONFIG_NET is not set
# CONFIG_SOUND is not set
# CONFIG_VGA_CONSOLE is not set
EOF

        # Merge — 3.4 uses merge_config.sh same as 4.19
        if [ -x scripts/kconfig/merge_config.sh ]; then
            bash scripts/kconfig/merge_config.sh -m .config /tmp/q60.config
        else
            cat /tmp/q60.config >> .config
        fi

        # Linux 3.4 doesn'\''t have `olddefconfig` (added in 3.7). Use `yes "" | oldconfig`
        # to accept defaults for any new symbols added by the merge.
        # SIGPIPE from `yes` is benign (make closes stdin first) — disable
        # pipefail just for this line so set -e doesn'\''t kill the script.
        echo ">> yes \"\" | make ARCH=i386 oldconfig"
        set +o pipefail
        yes "" | make ARCH=i386 oldconfig 2>&1 | tail -5
        set -o pipefail

        # Critical-symbol gate
        for SYM in M686 EFI_STUB KERNEL_XZ BLK_DEV_INITRD CMDLINE_BOOL \
                   PSTORE MMC_SDHCI_PCI ACPI PCI PCH_PHUB SERIAL_PCH_UART \
                   NVRAM EFI_VARS; do
            if ! grep -q "^CONFIG_${SYM}=y$" .config; then
                echo "!! ${SYM} silent-stripped — abort"
                grep "CONFIG_${SYM}" .config || echo "  (symbol fully missing)"
                exit 1
            fi
        done
        grep -q "^# CONFIG_MATOM is not set$" .config || {
            echo "!! MATOM still set"; exit 1; }
        echo ">> all critical symbols intact"

        # ── Step 3: Build with KCFLAGS=-mno-movbe (Bonnell has no MOVBE) ─
        export KCFLAGS="-mno-movbe -march=i686 -mtune=i686"
        echo ">> make ARCH=i386 -j$(nproc) bzImage  KCFLAGS=${KCFLAGS}"
        make ARCH=i386 -j"$(nproc)" KCFLAGS="${KCFLAGS}" bzImage 2>&1 | tail -15

        # MOVBE sanity gate
        MOVBE_COUNT=$(objdump -d vmlinux 2>/dev/null | awk -F"\t" "\$3 ~ /^movbe([ \\t]|\$)/ {n++} END{print n+0}")
        CMOVBE_COUNT=$(objdump -d vmlinux 2>/dev/null | awk -F"\t" "\$3 ~ /^cmovbe([ \\t]|\$)/ {n++} END{print n+0}")
        echo ">> MOVBE:  ${MOVBE_COUNT}  (must be 0)"
        echo ">> CMOVBE: ${CMOVBE_COUNT}  (safe Pentium Pro instruction)"
        [ "${MOVBE_COUNT}" -eq 0 ] || { echo "!! MOVBE present — abort"; exit 1; }

        # Verify LAPIS patch landed
        grep -q "0x10db" drivers/mmc/host/sdhci-pci.c || { echo "!! LAPIS patch missing"; exit 1; }
        echo ">> LAPIS SDHCI patch present"

        cp arch/x86/boot/bzImage /k-output/bzImage-3.4-q60
        echo ">> wrote /k-output/bzImage-3.4-q60 ($(stat -c%s arch/x86/boot/bzImage) bytes)"
        ls -la /k-output/bzImage-3.4-q60
    '

[ -f "${OUTPUT_BZ}" ] || { echo "build failed — output file missing"; exit 1; }
SIZE=$(stat -f%z "${OUTPUT_BZ}")
shasum -a 256 "${OUTPUT_BZ}" | tee "${OUTPUT_SHA}"

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  Linux 3.4 BUILD COMPLETE"
echo "  Size: ${SIZE} bytes ($((SIZE / 1024)) KB)"
echo "  4.19 Test C size: $(stat -f%z ${OUTPUT_DIR}/bzImage-4.19-q60-minimal) bytes"
echo "  Output: ${OUTPUT_BZ}"
echo "════════════════════════════════════════════════════════════"
