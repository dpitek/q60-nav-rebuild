# Kernel Config — Required Fixes for Q60 Boot

This document lists kernel `.config` items that **must** be set for the q60nav kernel to boot on Clarion QY5092 / Atom E6xx hardware. Originally identified after the first hardware boot attempt produced a complete black screen — five research agents converged on the same root causes. Significantly refined 2026-05-16 after a live probe inside the factory environment captured ground-truth hardware data (see [hardware-ground-truth-2026-05-16.md](hardware-ground-truth-2026-05-16.md)).

Apply these on top of `configs/q60_kernel.config` and rebuild.

## 2026-05-16 update — what changed after the in-factory probe

- ✅ **RAM is 2 GB, not 1 GB.** Drop `mem=1G` from cmdline. Drop zram. Raise Valhalla cache to 256 MB.
- ✅ **Factory cmdline has `dram=on`** (memory controller init param). Add it.
- ⚠️ **Factory display driver is Intel EMGD (proprietary), NOT mainline gma500.** The `CONFIG_DRM_GMA500=y` build is now KNOWN to be unverified on this hardware — gma500 may not even claim PCI 0:0:2.0 cleanly. Keeping the config items because gma500 is our only legal/open option, but this is a path-dependent risk: if gma500 doesn't claim the device, the kernel has NO display driver and there is NO efifb fallback (factory EFI provides no GOP/UGA framebuffer).
- ⚠️ **Factory uses custom `v2g`/`v2gbridge` overlay driver** layered on top of EMGD for the LVDS panels. We can't reproduce this. The closest equivalent open path is gma500 + Mesa swrast for userland.
- ✅ **Kernel hardware watchdog runs from factory boot.** Our rootfs must open `/dev/watchdog` and pet it within ~30 sec or risk reboot loop. STATUS already covers this.
- ✅ **CAN access**: factory uses DENSO proprietary IPC, NOT SocketCAN. Our path via `CONFIG_PCH_CAN=y` is independent and the PCH controller is at PCI 0000:02:* — should work but unverified live.

## Critical — boot will fail silently without these

### Kernel size — fit under elilo's 4 MB ia32 limit

elilo's ia32 build silently truncates bzImages over 4 MB. Our kernel was 4.19 MB. Switching to XZ compression and stripping bloat brought it to 3.03 MB.

```
# Compression
# CONFIG_KERNEL_GZIP is not set
CONFIG_KERNEL_XZ=y

# Strip bloat not needed at boot (re-enable later if needed in userland)
# CONFIG_BT is not set
# CONFIG_SOUND is not set
# CONFIG_BTRFS_FS is not set
# CONFIG_XFS_FS is not set
# CONFIG_F2FS_FS is not set
```

### Display driver — without these the LVDS stays black even on successful boot

```
CONFIG_DRM=y
CONFIG_DRM_KMS_HELPER=y
CONFIG_DRM_TTM=y
CONFIG_DRM_GMA500=y
CONFIG_DRM_GMA600=y      # Oaktrail variant; claims PCI 8086:4108
```

### Intel MID platform — required by gma500's LVDS init

`oaktrail_lvds_i2c.c` reads panel modes from the SCU IPC + SFI tables. Without these, `oaktrail_lvds_init()` logs "Found no modes on the lvds, ignoring the LVDS" and bails.

```
CONFIG_X86_INTEL_MID=y
CONFIG_SFI=y
CONFIG_INTEL_SCU_IPC=y
CONFIG_MFD_INTEL_MSIC=y
CONFIG_BACKLIGHT_LCD_SUPPORT=y
CONFIG_BACKLIGHT_CLASS_DEVICE=y
```

### Framebuffer fallback

```
CONFIG_FB_SIMPLE=y
CONFIG_X86_SYSFB=y
CONFIG_FB_EFI=y                    # already on
CONFIG_FRAMEBUFFER_CONSOLE=y       # already on
```

### Embedded cmdline — survive bootloader cmdline-stripping

If the bootloader truncates or drops the cmdline (some EFI handoff paths do this), bake it into the kernel. `CONFIG_CMDLINE_OVERRIDE=y` means we ignore whatever the bootloader passes and use ours.

```
CONFIG_CMDLINE_BOOL=y
CONFIG_CMDLINE_OVERRIDE=y
CONFIG_CMDLINE="root=/dev/mmcblk0p3 rw rootwait console=ttyPCH0,115200n8 console=tty0 earlyprintk=serial,ttyPCH0,115200n8 loglevel=8 ignore_loglevel debug video=LVDS-1:800x480@60 video=LVDS-2:800x420@60 lpj=1296800 priority_khubd=98 priority_ehciwork=44,R idle=halt ehci_hcd.log2_irq_thresh=2 pmemdisk=/dev/mmcblk0p7 memmap=2M$52M memmap=10M$54M panic=10 dram=on"
```

**Changes from prior cmdline (2026-05-16):**

- Dropped `mem=1G` — system has 2 GB (verified live).
- Added `dram=on` — factory uses it; memory controller init.
- Added `lpj=1296800` — factory's pre-calibrated loops-per-jiffy. Saves ~250 ms of boot calibration.
- Added `ehci_hcd.log2_irq_thresh=2` — factory uses; USB EHCI IRQ coalescing tuning.
- Added `memmap=2M$52M memmap=10M$54M` — reserves the v2g/EMGD framebuffer region (52-64 MB).
- Changed `console=ttyS0` → `console=ttyPCH0` — the real UART device name on this PCH chipset. (`ttyS0` is the legacy 8250 path which doesn't exist on EG20T; `pch_uart` driver creates `ttyPCH0..2`.)

## Secondary — bugs surfaced by overnight research

### CAN controller — config conflict with rcS

`rootfs/etc/init.d/rcS` modprobes `pch_can` but the config has `# CONFIG_PCH_CAN is not set`. Set it on so the modprobe succeeds.

```
CONFIG_PCH_CAN=y
```

### EG20T GPIO — required for any LED diagnostic

```
CONFIG_GPIO_PCH=y
```

### PC speaker BEL — cheap blind-boot diagnostic

```
CONFIG_INPUT_PCSPKR=y
```

## Forbidden — must NOT be enabled

These were considered but rejected after research:

```
# CONFIG_DRM_I915 is not set     # wrong hardware; not Intel HD Graphics
# CONFIG_DRM_PSB_VIRTUAL          # only relevant if running as KVM guest
```

## Verification after rebuild

```bash
# Size check
ls -lh arch/x86/boot/bzImage
# MUST be < 4194304 bytes for elilo ia32

# Config sanity
grep -E "^CONFIG_(DRM_GMA500|DRM_GMA600|FB_SIMPLE|X86_INTEL_MID|SFI|INTEL_SCU_IPC|MFD_INTEL_MSIC|X86_SYSFB|KERNEL_XZ|CMDLINE_BOOL|PCH_CAN|GPIO_PCH|INPUT_PCSPKR)=" .config

# All 13 should print
```

## Linux 4.19 — keep it

`CONFIG_DRM_GMA600` was removed from mainline after Linux 5.7. **4.19 is the last LTS with first-class Oaktrail (Atom E6xx) display support.** Do not casually bump the kernel version.

## Related docs

- [docs/boot-failure-rca.md](boot-failure-rca.md) — full root-cause analysis
- [docs/boot-safety.md](boot-safety.md) — elilo + boot counter design
- [docs/powervr-sgx-driver-analysis.md](powervr-sgx-driver-analysis.md) — why we stay on Mesa swrast for userland rendering
