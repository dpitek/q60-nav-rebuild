#!/bin/sh
# /init — v17 diagnostic initramfs PID 1.
#
# Runs from RAM. Kernel doesn't need any block device to get here.
# Goal: probe hardware, try to mount /dev/mmcblk0p1 (FAT32 boot) for
# persistent writes. If LAPIS SDHCI works, we get full diagnostics on the
# SD card. If LAPIS SDHCI is broken, we know — and we still tried.

# First action: tag in ramoops via dmesg so any next-boot pstore read shows
# we got here. (Lost on power cycle but useful within a session.)
echo "v17 initramfs /init PID=$$ reached at boot" > /dev/kmsg 2>/dev/null

# Step 1: essential virtual filesystems
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mountpoint -q /dev 2>/dev/null || mount -t devtmpfs devtmpfs /dev 2>/dev/null
mount -t tmpfs -o size=32M tmpfs /tmp 2>/dev/null
echo "v17 initramfs: virtual filesystems mounted" > /dev/kmsg 2>/dev/null

# ── CAPTURE CHANNEL #1: EFI variable (persistent NVRAM) ─────────────
# Survives power cycles. Mount efivarfs and write a "Q60InitReached" var.
# Format: 32-bit attribute prefix (0x07 = NV+BS+RT) + ASCII payload.
mount -t efivarfs efivarfs /sys/firmware/efi/efivars 2>/dev/null || true
EFIVAR_FILE="/sys/firmware/efi/efivars/Q60InitReached-12345678-1234-1234-1234-1234567890ab"
if [ -d /sys/firmware/efi/efivars ]; then
    # Build payload: 4-byte attrs (NV|BS|RT little-endian) + 64-byte data
    {
        printf '\x07\x00\x00\x00'
        printf 'Q60_INIT_REACHED %s' "$(date 2>/dev/null || echo no-date)"
        printf '%0.s\x00' $(seq 1 64)
    } > "$EFIVAR_FILE" 2>/dev/null && \
        echo "v17 initramfs: EFI variable written (Q60InitReached)" > /dev/kmsg 2>/dev/null || \
        echo "v17 initramfs: EFI var write FAILED (UEFI runtime may not be exposed)" > /dev/kmsg 2>/dev/null
fi

# ── CAPTURE CHANNEL #2: CMOS NVRAM (battery-backed RTC RAM) ────────
# 114 bytes, survives ignition cycle. Write a 16-byte marker at offset 50
# (the upper half of CMOS — typically unused by BIOS for time-of-day).
if [ -c /dev/nvram ] || mknod /dev/nvram c 10 144 2>/dev/null; then
    # Write marker bytes "Q60TESTC" + timestamp bytes
    {
        printf 'Q60TESTC'
        # 8 bytes of timestamp seconds (uptime in hex)
        printf '%08x' $(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0)
    } | dd of=/dev/nvram bs=1 count=16 seek=50 conv=notrunc 2>/dev/null && \
        echo "v17 initramfs: CMOS NVRAM marker written at offset 50" > /dev/kmsg 2>/dev/null || \
        echo "v17 initramfs: CMOS NVRAM write FAILED" > /dev/kmsg 2>/dev/null
fi

# ── CAPTURE CHANNEL #3: trigger pstore_efi by writing kmsg ────────
# CONFIG_PSTORE_EFI=y registers EFI as a pstore backend. Anything that hits
# the kernel ringbuffer with appropriate severity gets persisted on shutdown
# via printk.always_kmsg_dump=1. The /dev/kmsg writes throughout this script
# already feed that channel.
echo "v17 initramfs: pstore_efi will capture this on shutdown" > /dev/kmsg 2>/dev/null
# Force pstore_efi backend to register if not already
[ -d /sys/fs/pstore ] || mkdir -p /sys/fs/pstore 2>/dev/null
mount -t pstore pstore /sys/fs/pstore 2>/dev/null || true

# Step 2: kick mdev to populate /dev (in case devtmpfs missed anything)
echo /bin/mdev > /proc/sys/kernel/hotplug 2>/dev/null
mdev -s 2>/dev/null

# Step 3: capture hardware state to /tmp (volatile but we'll persist next)
mkdir -p /tmp/diag/{proc,pci,block,mmc,dmesg}
cat /proc/cmdline      > /tmp/diag/proc/cmdline.txt    2>/dev/null
cat /proc/cpuinfo      > /tmp/diag/proc/cpuinfo.txt    2>/dev/null
cat /proc/iomem        > /tmp/diag/proc/iomem.txt      2>/dev/null
cat /proc/ioports      > /tmp/diag/proc/ioports.txt    2>/dev/null
cat /proc/interrupts   > /tmp/diag/proc/interrupts.txt 2>/dev/null
cat /proc/modules      > /tmp/diag/proc/modules.txt    2>/dev/null
cat /proc/devices      > /tmp/diag/proc/devices.txt    2>/dev/null
cat /proc/partitions   > /tmp/diag/proc/partitions.txt 2>/dev/null
cat /proc/filesystems  > /tmp/diag/proc/filesystems.txt 2>/dev/null
cat /proc/meminfo      > /tmp/diag/proc/meminfo.txt    2>/dev/null
cat /proc/version      > /tmp/diag/proc/version.txt    2>/dev/null
cat /proc/mounts       > /tmp/diag/proc/mounts.txt     2>/dev/null
ls -la /dev            > /tmp/diag/dev_listing.txt     2>/dev/null
dmesg                  > /tmp/diag/dmesg/01-pre-probe.txt 2>/dev/null

# Snapshot of CURRENT EFI variables + CMOS NVRAM (might contain prior-boot markers)
mkdir -p /tmp/diag/efivars /tmp/diag/nvram
if [ -d /sys/firmware/efi/efivars ]; then
    # List all vars (don't read content — some are huge); look for Q60* specifically
    ls -la /sys/firmware/efi/efivars/ > /tmp/diag/efivars/_listing.txt 2>/dev/null
    for v in /sys/firmware/efi/efivars/Q60*; do
        [ -f "$v" ] || continue
        cp "$v" /tmp/diag/efivars/ 2>/dev/null
    done
fi
if [ -c /dev/nvram ]; then
    dd if=/dev/nvram of=/tmp/diag/nvram/cmos.bin bs=1 count=128 2>/dev/null
    od -An -tx1 /tmp/diag/nvram/cmos.bin > /tmp/diag/nvram/cmos.hex 2>/dev/null
fi

# PCI deep dump
PCI_COUNT=0
for d in /sys/bus/pci/devices/*/; do
    [ -d "$d" ] || continue
    BDF=$(basename "$d")
    mkdir -p /tmp/diag/pci/${BDF}
    for f in vendor device class subsystem_vendor subsystem_device resource irq enable modalias uevent; do
        cat "$d/$f" > /tmp/diag/pci/${BDF}/${f}.txt 2>/dev/null
    done
    if [ -L "$d/driver" ]; then
        readlink "$d/driver" > /tmp/diag/pci/${BDF}/driver.txt 2>/dev/null
    else
        echo "(unbound)" > /tmp/diag/pci/${BDF}/driver.txt
    fi
    if [ -r "$d/config" ]; then
        od -An -tx1 -v "$d/config" > /tmp/diag/pci/${BDF}/config.hex 2>/dev/null
    fi
    PCI_COUNT=$((PCI_COUNT+1))
done

# Compact PCI summary in lspci-style format
{
    echo "# BDF  vendor:device  class       driver"
    for d in /sys/bus/pci/devices/*/; do
        [ -d "$d" ] || continue
        BDF=$(basename "$d")
        V=$(cat "$d/vendor" 2>/dev/null | sed 's/^0x//')
        D=$(cat "$d/device" 2>/dev/null | sed 's/^0x//')
        C=$(cat "$d/class"  2>/dev/null)
        DRV="(none)"
        [ -L "$d/driver" ] && DRV=$(basename "$(readlink "$d/driver")" 2>/dev/null)
        printf "%s  %s:%s  %s  %s\n" "$BDF" "$V" "$D" "$C" "$DRV"
    done
} > /tmp/diag/pci/_SUMMARY.txt

# Block + MMC enumeration
ls -la /dev/mmcblk* /dev/sd* /dev/vd* 2>/dev/null > /tmp/diag/block/_dev_listing.txt
for b in /sys/block/*/; do
    [ -d "$b" ] || continue
    NAME=$(basename "$b")
    mkdir -p /tmp/diag/block/${NAME}
    for f in size ro removable uevent stat; do
        cat "$b/$f" > /tmp/diag/block/${NAME}/${f}.txt 2>/dev/null
    done
done
for h in /sys/class/mmc_host/*/; do
    [ -d "$h" ] || continue
    HNAME=$(basename "$h")
    mkdir -p /tmp/diag/mmc/${HNAME}
    for f in "$h"*; do
        [ -f "$f" ] || continue
        cat "$f" > /tmp/diag/mmc/${HNAME}/$(basename "$f").txt 2>/dev/null
    done
done
ls /sys/bus/pci/drivers/sdhci-pci/ 2>/dev/null > /tmp/diag/mmc/_sdhci_pci_bound.txt
ls /sys/bus/pci/drivers/sdhci/     2>/dev/null > /tmp/diag/mmc/_sdhci_bound.txt
dmesg | grep -iE "sdhci|mmc|10db|LAPIS" > /tmp/diag/mmc/_dmesg_filtered.txt 2>/dev/null
dmesg                  > /tmp/diag/dmesg/02-post-probe.txt 2>/dev/null

echo "v17 initramfs: hardware probe complete (${PCI_COUNT} PCI devs)" > /dev/kmsg 2>/dev/null

# Step 4: mount EVERY writable FAT32 we can find (SD AND USB simultaneously).
# Belt-and-suspenders: write diagnostics to ALL of them so Doug gets data
# from whichever one survives. Also retry the loop several times in case
# USB enumeration takes a moment.
echo "v17 initramfs: scanning for writable FAT32 (will retry up to 10s)" > /dev/kmsg 2>/dev/null
MOUNTED_LIST=""
for try in 1 2 3 4 5 6 7 8 9 10; do
    for dev in /dev/mmcblk0p1 /dev/mmcblk1p1 /dev/mmcblk2p1 \
               /dev/sda1 /dev/sdb1 /dev/sdc1 /dev/sdd1 \
               /dev/vda1 /dev/vdb1; do
        [ -b "$dev" ] || continue
        SHORT=$(basename "$dev")
        MNT="/mnt/${SHORT}"
        # Skip if already mounted
        grep -q " ${MNT} " /proc/mounts 2>/dev/null && continue
        mkdir -p "$MNT"
        if mount -t vfat "$dev" "$MNT" 2>/dev/null; then
            MOUNTED_LIST="${MOUNTED_LIST} ${dev}=${MNT}"
            echo "v17 initramfs: mounted $dev → $MNT" > /dev/kmsg 2>/dev/null
        fi
    done
    [ -n "$MOUNTED_LIST" ] && [ $try -ge 3 ] && break
    sleep 1
done

# For backward compat with the rest of the script, point MOUNTED at the
# first one found, but we'll loop over MOUNTED_LIST for actual writes.
MOUNTED=$(echo "$MOUNTED_LIST" | awk '{print $1}' | cut -d= -f2)

# Step 5: write everything we know to EVERY mountable target we found
# (not just the first) — guarantees diagnostic data lands somewhere even
# if one of the partitions is corrupt or unwritable.
if [ -n "$MOUNTED_LIST" ]; then
    # Per-target write loop
    for ENTRY in $MOUNTED_LIST; do
        TARGET_DEV=$(echo "$ENTRY" | cut -d= -f1)
        TARGET_MNT=$(echo "$ENTRY" | cut -d= -f2)
        DST="${TARGET_MNT}/v17-diag"
        mkdir -p "$DST" 2>/dev/null
        echo "INITRAMFS_REACHED via $TARGET_DEV at $(date 2>/dev/null)" > "$DST/INITRAMFS_REACHED.txt"
        echo "kernel: $(uname -a 2>/dev/null)" >> "$DST/INITRAMFS_REACHED.txt"
        echo "PCI device count: $PCI_COUNT" >> "$DST/INITRAMFS_REACHED.txt"
        echo "all mounted: $MOUNTED_LIST" >> "$DST/INITRAMFS_REACHED.txt"
        echo "uptime: $(cat /proc/uptime 2>/dev/null)" >> "$DST/INITRAMFS_REACHED.txt"
        # Copy the entire /tmp/diag tree (do this per-target — small enough)
        cp -r /tmp/diag/* "$DST/" 2>/dev/null
        sync
        echo "v17 initramfs: dumped diagnostics to $TARGET_DEV" > /dev/kmsg 2>/dev/null
    done

    # Keep $DST pointing at first target for the rest of the legacy script
    DST=$(echo "$MOUNTED_LIST" | awk '{print $1}' | cut -d= -f2)/v17-diag

    # R1 baseline check — expected PCI devices vs what we saw
    {
        echo "=== R1 baseline PCI presence check (v17 initramfs) ==="
        echo "Mounted via: $MOUNTED"
        echo ""
        echo "Expected (from factory 2.6.37 boot logs):"
        echo "  00:00.0 8086:4114  Tunnel Creek host bridge"
        echo "  00:02.0 8086:4108  GMA 600 graphics (Tunnel Creek IGD)"
        echo "  02:04.0 10db:801e  LAPIS SDHCI #0 (SD card)"
        echo "  02:04.1 10db:801f  LAPIS SDHCI #1"
        echo "  02:04.2 10db:8020  LAPIS SDHCI #2 (eMMC)"
        echo "  02:0a.1 10db:8027  LAPIS PCH UART"
        echo ""
        echo "Actual seen:"
        cat "$DST/pci/_SUMMARY.txt"
        echo ""
        echo "Presence check:"
        for combo in "00:00.0 8086 4114 host-bridge" \
                     "00:02.0 8086 4108 gma600-graphics" \
                     "02:04.0 10db 801e lapis-sdhci-0" \
                     "02:04.1 10db 801f lapis-sdhci-1" \
                     "02:04.2 10db 8020 lapis-sdhci-2" \
                     "02:0a.1 10db 8027 lapis-uart"; do
            set -- $combo
            BDF=$1; VID=$2; DID=$3; DESC=$4
            DEV=/sys/bus/pci/devices/0000:$BDF
            if [ -d "$DEV" ]; then
                V=$(cat "$DEV/vendor" 2>/dev/null | sed 's/^0x//')
                D=$(cat "$DEV/device" 2>/dev/null | sed 's/^0x//')
                if [ "$V" = "$VID" ] && [ "$D" = "$DID" ]; then
                    DRV="(unbound)"
                    [ -L "$DEV/driver" ] && DRV=$(basename "$(readlink "$DEV/driver")" 2>/dev/null)
                    echo "  ✓ $BDF ($VID:$DID, $DESC) driver=$DRV"
                else
                    echo "  ? $BDF: present but ids $V:$D ≠ expected $VID:$DID"
                fi
            else
                echo "  ✗ $BDF ($VID:$DID, $DESC) MISSING"
            fi
        done
    } > "$DST/_R1_BASELINE_CHECK.txt" 2>&1

    # Final dmesg
    dmesg > "$DST/dmesg/03-final.txt" 2>/dev/null

    # Summary at top level for easy macOS reading — write to FIRST target;
    # copied to all targets below.
    FIRST_MNT=$(echo "$MOUNTED_LIST" | awk '{print $1}' | cut -d= -f2)
    {
        echo "v17 Test C Initramfs Diagnostic Boot Summary"
        echo "============================================"
        echo "Date:        $(date 2>/dev/null)"
        echo "All mounted: $MOUNTED_LIST"
        echo "PCI count:   $PCI_COUNT"
        echo "Uptime:      $(cat /proc/uptime 2>/dev/null)"
        echo "Kernel:      $(uname -a 2>/dev/null)"
        echo ""
        echo "Key question (CHECK _R1_BASELINE_CHECK.txt):"
        echo "  Is LAPIS SDHCI 10db:801e present and bound to sdhci-pci?"
        echo "    YES → root cause was rootfs path; rcS-based v16 has another bug"
        echo "    NO  → LAPIS patch isn't binding on real hardware; need different approach"
        echo ""
        echo "Diagnostic dumps in v17-diag/ subdirectories: proc/, pci/, block/, mmc/, dmesg/"
    } > "${FIRST_MNT}/V17_SUMMARY.txt"

    sync
    echo "v17 initramfs: diagnostics written to ALL targets ($MOUNTED_LIST)" > /dev/kmsg 2>/dev/null
    # Also copy V17_SUMMARY.txt to root of every OTHER target
    for ENTRY in $MOUNTED_LIST; do
        TARGET_MNT=$(echo "$ENTRY" | cut -d= -f2)
        [ "$TARGET_MNT" = "$FIRST_MNT" ] && continue
        cp "${FIRST_MNT}/V17_SUMMARY.txt" "$TARGET_MNT/V17_SUMMARY.txt" 2>/dev/null
    done
    sync
    # Unmount everything
    for ENTRY in $MOUNTED_LIST; do
        TARGET_MNT=$(echo "$ENTRY" | cut -d= -f2)
        umount "$TARGET_MNT" 2>/dev/null
    done
else
    echo "v17 initramfs: NO writable FAT32 found anywhere — LAPIS SDHCI binding failed AND no USB mounted" > /dev/kmsg 2>/dev/null
    echo "v17 initramfs: /dev contents at this moment:" > /dev/kmsg 2>/dev/null
    ls /dev > /dev/kmsg 2>/dev/null
    # Try ramoops as a last-ditch signal (volatile but worth trying)
    echo c > /proc/sysrq-trigger 2>/dev/null  # forces a crash → ramoops captures dmesg
fi

# Power off — car returns to factory boot
sync 2>/dev/null
sleep 1
echo "v17 initramfs: powering off (done)" > /dev/kmsg 2>/dev/null
poweroff -f 2>/dev/null
halt -f 2>/dev/null
# If neither worked, sit in a loop so the watchdog can reset us
while true; do sleep 60; done
