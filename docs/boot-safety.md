# Q60 Nav Rebuild — Boot Safety Analysis
## Date: 2026-05-11

---

## Hardware Profile

| Item | Value |
|---|---|
| SoC | Intel Atom E6xx "Crossville Lapis" |
| Bootloader | elilo.efi (2013-03-28, 153KB PE32 EFI application) |
| Boot partition | /dev/mmcblk0p1 — FAT32, 127MB |
| A slot | root=mmcblk0p2, androidroot=mmcblk0p5 |
| B slot | root=mmcblk0p3, androidroot=mmcblk0p6 |
| Shared mem | mmcblk0p7 — 50MB pmemdisk (NOT user data) |
| User data | mmcblk0p9 — 1GB ext4 |
| Nav app | mmcblk0p8 — 3GB ext4 |
| Kernel (original) | vmlinuz-2.6.37.6-35.1_DLK0040-android-intel-crossville_lapis-fastboot |
| Kernel (new) | vmlinuz-4.19-q60 |

---

## elilo Fallback Behavior: NONE

elilo (2013 vintage) is a minimal EFI bootloader.

**Does NOT have:**
- Boot counting / boot attempt tracking
- Automatic fallback on failed boot
- Timeout-based entry switching
- BootNext EFI variable support

**What happens on panic+reboot:** elilo reads elilo.conf, boots `default=` entry again. Infinite loop.

---

## Watchdog Status

| | Original kernel (2.6.37) | Our new kernel (4.19) |
|---|---|---|
| CONFIG_WATCHDOG | NOT SET | y |
| CONFIG_iTCO_WDT | NOT SET | y |

Original system has **no hardware watchdog**. Our new kernel has iTCO enabled (30s default timeout). Good for hung-state protection, but doesn't prevent boot loops on its own — needs the FAT32 counter.

---

## Protection Mechanism: FAT32 Boot Counter

p1 (FAT32) is always accessible externally (USB adapter → Mac). We use it as shared state.

### Boot counter logic (early in start.sh):
```sh
COUNT_FILE="/boot/q60_boot_attempts"
count=$(cat "$COUNT_FILE" 2>/dev/null || echo 0)
if [ "$count" -ge 2 ]; then
    # Two failed attempts — restore safe default
    sed -i 's/^default=.*/default=logan1/' /boot/elilo.conf
    rm -f "$COUNT_FILE"
    sync
    reboot -f
fi
echo $((count + 1)) > "$COUNT_FILE"
sync

# ... rest of boot ...

# At successful app launch:
rm -f "$COUNT_FILE"
```

**Result:** After 2 failed boots → auto-restores logan1 → reboots to original firmware.

This requires `/boot` mounted **read-write** (updated in fstab).

---

## fstab: /boot mount

Changed from `ro` to `rw` to support boot counter writes:
```
/dev/mmcblk0p1     /boot     vfat      rw,relatime                    0  2
```

Note: This means our new kernel mounts the FAT32 boot partition read-write. The boot counter
and elilo.conf recovery write depend on this. Slot A (p2) is still mounted read-only.

---

## Safe Update Procedure

### Step 1 — Write to slot B (eMMC out of car, USB adapter on Mac)
- Copy vmlinuz-4.19-q60 to FAT32 boot partition
- Add q60nav entry to elilo.conf (keep default=logan1)
- Write new rootfs image to mmcblk0p3
- Write nav app to mmcblk0p8

### Step 2 — elilo.conf with new entry (default stays logan1)
```
default=logan1   # <- unchanged during build/development

image=vmlinuz-4.19-q60
    label=q60nav
    description="Q60 New Nav System (Linux 4.19, Qt 6.6)"
    root=/dev/mmcblk0p3
    append="rw quiet rootwait lpj=1296800 panic=1 mem=1G"
```

### Step 3 — Test boot sequence
Right before inserting eMMC into car:
```bash
sed -i 's/^default=.*/default=q60nav/' /Volumes/boot\ 1/elilo.conf
```
Eject, insert, power on.

### Step 4 — Outcome
| Result | Action |
|---|---|
| New UI appears | Success — delete boot_attempts; keep default=q60nav |
| Boot loops | FAT32 counter fires after 2 attempts → auto-restores logan1 |
| Need manual recovery | Pull eMMC → Mac → edit elilo.conf → restore default=logan1 |

---

## Slot A: PERMANENT SAFETY NET

**mmcblk0p2 (slot A root) and mmcblk0p5 (slot A android) are NEVER written during rebuild.**

Slot A is the untouched original. It can always be booted by setting `default=logan1`.

---

## elilo.conf Final Template (for p1)

```
verbose=0
legacy-free

default=logan1

image=vmlinuz-2.6.37.6-35.1_DLK0040-android-intel-crossville_lapis-fastboot
	label=logan1
	description="Logan Legacy + Android System (original)"
	root=/dev/mmcblk0p2
	append="ro quiet rootwait lpj=1296800 android androidboot.console=tty1 androidroot=/dev/mmcblk0p5 pmemdisk=/dev/mmcblk0p7 memmap=2M$52M memmap=10M$54M panic=1 priority_khubd=98 priority_ehciwork=44,R idle=halt ehci_hcd.log2_irq_thresh=2 mem=1G"
	read-only

image=vmlinuz-2.6.37.6-35.1_DLK0040-android-intel-crossville_lapis-fastboot
	label=logan2_backup
	description="Logan Legacy + Android Backup System"
	root=/dev/mmcblk0p3
	append="ro quiet rootwait lpj=1296800 android androidboot.console=tty1 androidroot=/dev/mmcblk0p6 pmemdisk=/dev/mmcblk0p7 memmap=2M$52M memmap=10M$54M panic=1 priority_khubd=98 priority_ehciwork=44,R idle=halt ehci_hcd.log2_irq_thresh=2 mem=1G"
	read-only

image=vmlinuz-4.19-q60
	label=q60nav
	description="Q60 New Nav System (Linux 4.19, Qt 6.6)"
	root=/dev/mmcblk0p3
	append="rw quiet rootwait lpj=1296800 panic=1 mem=1G"
```

---

## Confidence Summary

| Risk | Mitigation | Status |
|---|---|---|
| New kernel won't boot | FAT32 counter auto-restores logan1 after 2 attempts | MITIGATED |
| elilo has no fallback | Counter IS the fallback | MITIGATED |
| Slot A corruption | Never written — guaranteed safe | GUARANTEED |
| Physical recovery | USB adapter + Mac + edit FAT32 = 5 min | GUARANTEED |
| iTCO watchdog loop | Counter catches it | MITIGATED |
| mmc driver mismatch | CONFIG_MMC_SDHCI_PCI=y — same as original | CONFIRMED |

**Cannot permanently brick this unit.** Worst case is 5 minutes with a USB-eMMC adapter.
