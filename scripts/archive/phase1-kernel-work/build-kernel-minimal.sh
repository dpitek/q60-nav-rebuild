#!/bin/bash
# build-kernel-minimal.sh — Test C: bare-bones kernel.
#
# Method: start from v17's working config, then aggressively disable everything
# we don't need (DRM, USB, network, audio, etc.) Keeps the proven essentials
# intact (PSTORE, EFI_STUB, MMC_SDHCI, etc.) — more reliable than tinyconfig
# which strips things olddefconfig can't always recover.
#
# Output: output/bzImage-4.19-q60-minimal + sha256
# Doesn't touch the v17 build. Both artifacts coexist.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL_DIR="${SCRIPT_DIR}/kernel"
V17_CONFIG="${SCRIPT_DIR}/configs/q60_kernel.config"
OUTPUT_DIR="${SCRIPT_DIR}/output"
OUTPUT_BZ="${OUTPUT_DIR}/bzImage-4.19-q60-minimal"
OUTPUT_SHA="${OUTPUT_BZ}.sha256"

[ -d "${KERNEL_DIR}" ]  || { echo "kernel source not found"; exit 1; }
[ -f "${V17_CONFIG}" ]  || { echo "v17 config not found"; exit 1; }
[ -f "${OUTPUT_DIR}/initramfs.cpio.gz" ] || {
    echo "initramfs.cpio.gz not found — run scripts/build-initramfs.sh first"; exit 1; }
docker info >/dev/null 2>&1 || { echo "Docker not reachable"; exit 1; }

echo "════════════════════════════════════════════════════════════"
echo "  Test C: bare-bones kernel build (v17 base, aggressive strip)"
echo "  $(date)"
echo "════════════════════════════════════════════════════════════"

docker run --rm \
    --platform linux/amd64 \
    -v "${KERNEL_DIR}:/k" \
    -v "${OUTPUT_DIR}:/k-output" \
    -v "${V17_CONFIG}:/tmp/v17.config:ro" \
    ubuntu:22.04 \
    bash -c '
        set -euo pipefail
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq >/dev/null
        apt-get install -y -qq --no-install-recommends \
            build-essential gcc-multilib bc bison flex \
            libssl-dev libelf-dev xz-utils kmod cpio binutils \
            >/dev/null

        cd /k
        cp /tmp/v17.config .config

        # ── Strip every feature not strictly needed for: EFI stub load,
        # ── decompress, initramfs unpack, /init run, ramoops write, poweroff
        echo ">> stripping non-essential features from v17 config"

        # List of CONFIG_* to force-disable. These are the heavy hitters that
        # add code/data without contributing to bare-boot diagnostic.
        cat > /tmp/strip.list <<EOF
CONFIG_DRM
CONFIG_DRM_TTM
CONFIG_DRM_KMS_HELPER
CONFIG_FB
CONFIG_FB_EFI
CONFIG_FB_SIMPLE
CONFIG_X86_SYSFB
CONFIG_VT
CONFIG_VT_CONSOLE
CONFIG_VGA_CONSOLE
CONFIG_VGA_ARB
CONFIG_HW_CONSOLE
CONFIG_FRAMEBUFFER_CONSOLE
CONFIG_USB
CONFIG_USB_SUPPORT
CONFIG_USB_EHCI_HCD
CONFIG_USB_OHCI_HCD
CONFIG_USB_HID
CONFIG_USB_STORAGE
CONFIG_USB_ACM
CONFIG_USB_SERIAL
CONFIG_USB_PCI
CONFIG_USB_COMMON
CONFIG_HID
CONFIG_INPUT
CONFIG_INPUT_KEYBOARD
CONFIG_INPUT_MOUSE
CONFIG_SCSI
CONFIG_BLK_DEV_SD
CONFIG_ATA
CONFIG_NET
CONFIG_INET
CONFIG_IPV6
CONFIG_PACKET
CONFIG_UNIX
CONFIG_SOUND
CONFIG_SND
CONFIG_BT
CONFIG_WLAN
CONFIG_CFG80211
CONFIG_RFKILL
CONFIG_VIRTIO_MENU
CONFIG_VIRTIO
CONFIG_VIRTIO_PCI
CONFIG_VIRTIO_BLK
CONFIG_PCH_CAN
CONFIG_PCH_GBE
CONFIG_CAN
CONFIG_NET_VENDOR_INTEL
CONFIG_NET_VENDOR_REALTEK
CONFIG_GPIO_PCH
CONFIG_GPIO_ML_IOH
CONFIG_I2C
CONFIG_I2C_EG20T
CONFIG_SPI
CONFIG_SPI_TOPCLIFF_PCH
CONFIG_PCH_DMA
CONFIG_INTEL_SCU_IPC
CONFIG_MFD_INTEL_MSIC
CONFIG_PINCTRL
CONFIG_REGULATOR
CONFIG_MEDIA_SUPPORT
CONFIG_VIDEO_DEV
CONFIG_DVB_CORE
CONFIG_AGP
CONFIG_DRM_LEGACY
CONFIG_DRM_RADEON
CONFIG_DRM_NOUVEAU
CONFIG_DRM_I915
CONFIG_DRM_VMWGFX
CONFIG_DRM_GMA500
CONFIG_DRM_GMA600
CONFIG_PHONET
CONFIG_NFC
CONFIG_NFS_FS
CONFIG_NFSD
CONFIG_CIFS
CONFIG_FUSE_FS
CONFIG_AUTOFS_FS
CONFIG_AUTOFS4_FS
CONFIG_OVERLAY_FS
CONFIG_XFS_FS
CONFIG_BTRFS_FS
CONFIG_REISERFS_FS
CONFIG_JFS_FS
CONFIG_F2FS_FS
CONFIG_NILFS2_FS
CONFIG_HFS_FS
CONFIG_HFSPLUS_FS
CONFIG_NTFS_FS
CONFIG_NTFS3_FS
CONFIG_SQUASHFS
CONFIG_ECRYPT_FS
CONFIG_QUOTA
CONFIG_AUDIT
CONFIG_SECURITY
CONFIG_SECURITY_SELINUX
CONFIG_INTEGRITY
CONFIG_IMA
CONFIG_BPF_SYSCALL
CONFIG_BPF_JIT
CONFIG_KEXEC
CONFIG_HIBERNATION
CONFIG_PM_DEBUG
CONFIG_FUNCTION_TRACER
CONFIG_FTRACE
CONFIG_KGDB
CONFIG_DEBUG_INFO
CONFIG_PROFILING
CONFIG_PERF_EVENTS
CONFIG_NUMA
CONFIG_KSM
CONFIG_TRANSPARENT_HUGEPAGE
CONFIG_MEMORY_HOTPLUG
EOF

        # Apply the strip — replace any CONFIG_X=y with `# CONFIG_X is not set`
        STRIP_COUNT=0
        while read -r SYM; do
            [ -z "$SYM" ] && continue
            if grep -q "^${SYM}=" .config; then
                sed -i "s|^${SYM}=.*|# ${SYM} is not set|" .config
                STRIP_COUNT=$((STRIP_COUNT+1))
            fi
        done < /tmp/strip.list
        echo ">> stripped ${STRIP_COUNT} feature flags"

        # Force critical things to STAY enabled (in case strip cascaded)
        cat > /tmp/keep.config <<EOF
CONFIG_M686=y
CONFIG_X86_PAE=y
CONFIG_HIGHMEM64G=y
CONFIG_EFI=y
CONFIG_EFI_STUB=y
CONFIG_RELOCATABLE=y
CONFIG_KERNEL_XZ=y
CONFIG_BLK_DEV_INITRD=y
CONFIG_INITRAMFS_SOURCE="/k-output/initramfs.cpio.gz"
CONFIG_CMDLINE_BOOL=y
CONFIG_PSTORE=y
CONFIG_PSTORE_RAM=y
CONFIG_PSTORE_EFI=y
CONFIG_EFI_VARS=y
CONFIG_EFIVAR_FS=y
CONFIG_NVRAM=y
CONFIG_RTC_CLASS=y
CONFIG_RTC_DRV_CMOS=y
CONFIG_SERIAL_PCH_UART=y
CONFIG_SERIAL_PCH_UART_CONSOLE=y
CONFIG_ACPI=y
CONFIG_PCI=y
CONFIG_MMC=y
CONFIG_MMC_BLOCK=y
CONFIG_MMC_SDHCI=y
CONFIG_MMC_SDHCI_PCI=y
CONFIG_PCH_PHUB=y
CONFIG_VFAT_FS=y
CONFIG_FAT_FS=y
CONFIG_NLS_CODEPAGE_437=y
CONFIG_NLS_ISO8859_1=y
CONFIG_EXT4_FS=y
CONFIG_DEVTMPFS=y
CONFIG_DEVTMPFS_MOUNT=y
CONFIG_TMPFS=y
CONFIG_PROC_FS=y
CONFIG_SYSFS=y
CONFIG_BINFMT_ELF=y
CONFIG_TTY=y
CONFIG_MSDOS_PARTITION=y
CONFIG_PARTITION_ADVANCED=y
EOF
        bash scripts/kconfig/merge_config.sh -m .config /tmp/keep.config

        echo ">> make ARCH=i386 olddefconfig (resolve unmet deps)"
        make ARCH=i386 olddefconfig 2>&1 | tail -5

        # Critical-symbol gate
        for SYM in M686 EFI_STUB KERNEL_XZ BLK_DEV_INITRD CMDLINE_BOOL \
                   PSTORE PSTORE_RAM ACPI PCI MMC_SDHCI_PCI; do
            if ! grep -q "^CONFIG_${SYM}=y$" .config; then
                echo "!! ${SYM} silent-stripped — abort"
                grep "CONFIG_${SYM}" .config || echo "(symbol fully missing)"
                exit 1
            fi
        done
        grep -q "^# CONFIG_MATOM is not set$" .config || {
            echo "!! MATOM still set — abort"; exit 1; }
        echo ">> all critical symbols intact"

        # Count =y settings (rough size proxy)
        ENABLED=$(grep -c "^CONFIG_.*=y$" .config)
        echo ">> config has ${ENABLED} =y entries (v17 was 743)"

        echo ""
        echo ">> make ARCH=i386 -j$(nproc) bzImage"
        export KCFLAGS="-mno-movbe -march=i686 -mtune=i686"
        make ARCH=i386 -j"$(nproc)" KCFLAGS="${KCFLAGS}" bzImage 2>&1 | tail -10

        # MOVBE sanity gate
        MOVBE_COUNT=$(objdump -d vmlinux 2>/dev/null | awk -F"\t" "\$3 ~ /^movbe([ \\t]|\$)/ {n++} END{print n+0}")
        echo ">> MOVBE: ${MOVBE_COUNT} (must be 0)"
        [ "${MOVBE_COUNT}" -eq 0 ] || { echo "!! abort: MOVBE present"; exit 1; }

        cp arch/x86/boot/bzImage /k-output/bzImage-4.19-q60-minimal
        echo ">> wrote /k-output/bzImage-4.19-q60-minimal ($(stat -c%s arch/x86/boot/bzImage) bytes)"
        ls -la /k-output/bzImage-4.19-q60-minimal
    '

[ -f "${OUTPUT_BZ}" ] || { echo "build failed — output file missing"; exit 1; }
SIZE=$(stat -f%z "${OUTPUT_BZ}")
shasum -a 256 "${OUTPUT_BZ}" | tee "${OUTPUT_SHA}"

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  BARE-BONES BUILD COMPLETE"
echo "  Size: ${SIZE} bytes ($((SIZE / 1024)) KB)"
echo "  v17 size: $(stat -f%z ${OUTPUT_DIR}/bzImage-4.19-q60) bytes"
echo "  Saved: $(( ($(stat -f%z ${OUTPUT_DIR}/bzImage-4.19-q60) - SIZE) / 1024 )) KB"
echo "  Output: ${OUTPUT_BZ}"
echo "════════════════════════════════════════════════════════════"
