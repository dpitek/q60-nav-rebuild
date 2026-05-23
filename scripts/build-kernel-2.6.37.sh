#!/bin/bash
# build-kernel-2.6.37.sh — Bare-bones Linux 2.6.37 build.
#
# Same kernel version Nissan/Wind River ship on the Q60 DCU (definitionally
# functional on this hardware). Built fresh from kernel.org tarball with
# the smallest config we can manage, plus our embedded initramfs.
#
# NO EFI stub (2.6.37 predates EFI stub by ~2 years) — must be loaded via
# elilo or another bootloader, not direct UEFI fallback.
#
# Output: output/bzImage-2.6.37-minimal + sha256

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL_DIR="${SCRIPT_DIR}/kernel-2.6.37/linux-2.6.37.6"
OUTPUT_DIR="${SCRIPT_DIR}/output"
OUTPUT_BZ="${OUTPUT_DIR}/bzImage-2.6.37-minimal"
OUTPUT_SHA="${OUTPUT_BZ}.sha256"

[ -d "${KERNEL_DIR}" ] || { echo "kernel source not extracted: ${KERNEL_DIR}"; exit 1; }
[ -f "${OUTPUT_DIR}/initramfs.cpio.gz" ] || {
    echo "initramfs.cpio.gz not found — run scripts/build-initramfs.sh first"; exit 1; }
docker info >/dev/null 2>&1 || { echo "Docker not reachable"; exit 1; }

echo "════════════════════════════════════════════════════════════"
echo "  Bare-bones Linux 2.6.37 build"
echo "  $(date)"
echo "════════════════════════════════════════════════════════════"

docker run --rm \
    --platform linux/amd64 \
    -v "${KERNEL_DIR}:/k" \
    -v "${OUTPUT_DIR}:/k-output" \
    ubuntu:14.04 \
    bash -c '
        set -euo pipefail
        export DEBIAN_FRONTEND=noninteractive

        # Ubuntu 14.04 EOL — switch to old-releases archive
        sed -i "s|archive.ubuntu.com|old-releases.ubuntu.com|g; s|security.ubuntu.com|old-releases.ubuntu.com|g" /etc/apt/sources.list 2>/dev/null || true
        apt-get update -qq 2>&1 | tail -3
        apt-get install -y -qq --no-install-recommends \
            build-essential gcc-multilib bc kmod cpio binutils \
            libc6-dev-i386 binutils-multiarch >/dev/null 2>&1

        echo ">> gcc: $(gcc --version | head -1)"
        echo ">> binutils: $(ld -v 2>&1 | head -1)"

        cd /k

        # Start from allnoconfig (smallest possible base)
        echo ">> make ARCH=i386 allnoconfig"
        make ARCH=i386 allnoconfig 2>&1 | tail -3

        # Layer in only what we need
        cat >> .config <<EOF
CONFIG_64BIT=n
CONFIG_X86_32=y
CONFIG_M686=y
CONFIG_X86_PAE=y
CONFIG_HIGHMEM4G=n
CONFIG_HIGHMEM64G=y
CONFIG_HIGHMEM=y
CONFIG_KERNEL_GZIP=y
CONFIG_RELOCATABLE=y
CONFIG_PHYSICAL_ALIGN=0x1000000

# Initramfs from our build
CONFIG_BLK_DEV_INITRD=y
CONFIG_INITRAMFS_SOURCE="/k-output/initramfs.cpio.gz"
CONFIG_INITRAMFS_ROOT_UID=0
CONFIG_INITRAMFS_ROOT_GID=0
CONFIG_RD_GZIP=y

# Embedded cmdline (no bootloader will be passing it to us reliably)
CONFIG_CMDLINE_BOOL=y
CONFIG_CMDLINE="init=/init console=ttyS0,115200 console=tty0 loglevel=8 ignore_loglevel debug printk.time=1 idle=halt panic=10 nokaslr mem=1G"

# Essentials
CONFIG_BINFMT_ELF=y
CONFIG_BINFMT_SCRIPT=y
CONFIG_PROC_FS=y
CONFIG_SYSFS=y
CONFIG_DEVTMPFS=y
CONFIG_DEVTMPFS_MOUNT=y
CONFIG_TMPFS=y
CONFIG_TTY=y
CONFIG_PRINTK=y
CONFIG_BUG=y

# Serial console (legacy 8250 — 2.6.37 has no LAPIS PCH UART driver, so this
# is the fallback that any standard PC ISA UART would use)
CONFIG_SERIAL_8250=y
CONFIG_SERIAL_8250_CONSOLE=y
CONFIG_SERIAL_8250_PCI=y
CONFIG_SERIAL_CORE=y
CONFIG_SERIAL_CORE_CONSOLE=y

# ACPI + PCI (Tunnel Creek is ACPI)
CONFIG_ACPI=y
CONFIG_PCI=y

# Block layer for any initramfs unpacking + ram disk fallback
CONFIG_BLOCK=y
CONFIG_BLK_DEV=y
CONFIG_BLK_DEV_RAM=y

# Filesystems we might mount in /init
CONFIG_VFAT_FS=y
CONFIG_FAT_FS=y
CONFIG_NLS=y
CONFIG_NLS_CODEPAGE_437=y
CONFIG_NLS_ISO8859_1=y
CONFIG_MSDOS_PARTITION=y
CONFIG_EXT4_FS=y

# CMOS NVRAM (battery-backed)
CONFIG_NVRAM=y
CONFIG_RTC_CLASS=y
CONFIG_RTC_DRV_CMOS=y

# EFI variables — old /sys/firmware/efi/vars/ interface
CONFIG_EFI=y
CONFIG_EFI_VARS=y

# MMC + SDHCI (best-effort — 2.6.37 mainline lacks LAPIS IDs; would need patch
# matching what we did for 4.19. For now, leave generic in case it's useful.)
CONFIG_MMC=y
CONFIG_MMC_BLOCK=y
CONFIG_MMC_SDHCI=y
CONFIG_MMC_SDHCI_PCI=y
EOF

        echo ">> make ARCH=i386 olddefconfig"
        make ARCH=i386 olddefconfig 2>&1 | tail -5 || {
            echo "olddefconfig failed — trying make oldconfig"
            yes "" | make ARCH=i386 oldconfig 2>&1 | tail -10
        }

        # Verify critical symbols (some may have been silent-stripped)
        for SYM in M686 EFI_STUB; do
            grep -q "^CONFIG_${SYM}=y$" .config && echo "  ✓ ${SYM}" || echo "  ✗ ${SYM}"
        done
        # EFI_STUB notably absent in 2.6.37 — that is by design
        for SYM in BLK_DEV_INITRD CMDLINE_BOOL PROC_FS SYSFS DEVTMPFS VFAT_FS NVRAM; do
            grep -q "^CONFIG_${SYM}=y$" .config && echo "  ✓ ${SYM}" || echo "  ✗ ${SYM}"
        done

        echo ""
        echo ">> make ARCH=i386 -j$(nproc) bzImage"
        # 2.6.37 + modern binutils sometimes needs these
        export KCFLAGS="-mno-movbe -march=i686 -mtune=i686 -Wno-error -fno-pie -no-pie"
        export KAFLAGS="-mtune=i686"
        # Disable warnings-as-errors if Makefile sets it
        make ARCH=i386 -j"$(nproc)" KCFLAGS="${KCFLAGS}" KAFLAGS="${KAFLAGS}" \
            bzImage 2>&1 | tail -40

        # MOVBE check
        MOVBE_COUNT=$(objdump -d vmlinux 2>/dev/null | awk -F"\t" "\$3 ~ /^movbe([ \\t]|\$)/ {n++} END{print n+0}")
        echo ">> MOVBE: ${MOVBE_COUNT} (must be 0)"
        [ "${MOVBE_COUNT}" -eq 0 ] || { echo "!! abort: MOVBE present"; exit 1; }

        cp arch/x86/boot/bzImage /k-output/bzImage-2.6.37-minimal
        echo ">> wrote /k-output/bzImage-2.6.37-minimal ($(stat -c%s arch/x86/boot/bzImage) bytes)"
        ls -la /k-output/bzImage-2.6.37-minimal
    '

[ -f "${OUTPUT_BZ}" ] || { echo "build failed — output missing"; exit 1; }
SIZE=$(stat -f%z "${OUTPUT_BZ}")
shasum -a 256 "${OUTPUT_BZ}" | tee "${OUTPUT_SHA}"

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  2.6.37 BUILD COMPLETE"
echo "  Size: ${SIZE} bytes ($((SIZE / 1024)) KB)"
echo "  Output: ${OUTPUT_BZ}"
echo "  No EFI stub — load via elilo or factory bootloader."
echo "════════════════════════════════════════════════════════════"
