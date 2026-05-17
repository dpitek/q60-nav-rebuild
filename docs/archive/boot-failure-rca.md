# Boot Failure Root-Cause Analysis
**Date:** 2026-05-16 (overnight investigation following first failed boot attempt)
**Status:** Two root causes identified, fix shipped (Variant M2 image)

## Symptom

First boot attempt of the q60nav rootfs on real DCU hardware: **complete black screen**, no output on either LVDS panel, no boot counter increment, no log files written to FAT32 `/boot`, no recovery — neither the new system nor the factory `logan1` fallback came up. Power-off cycle had no effect.

Five independent research agents (boot chain forensics, elilo deep-dive, LVDS panel research, factory firmware comparison, alternative diagnostic channels, community knowledge sweep) ran in parallel against the codebase, kernel config, and external sources. Findings converged on **two simultaneous failures**.

## Root cause #1 — elilo silently truncates kernels >4 MB

The elilo bootloader's ia32 build hard-codes a **4,194,304-byte (4 MB) limit** on bzImage size at `ia32/bzimage.c`. Anything larger is silently truncated to 4 MB. The truncated image has a corrupt setup header → CPU jumps into garbage data → silent hang before any `printk()` can fire.

Our kernel size: **4,388,896 bytes (4.19 MB)** — over the limit by 194,592 bytes (4.6 %).

The factory `vmlinuz-2.6.37.6` is 2.85 MB and fits, which is why factory boot works through the same elilo binary. Matches every observed symptom: no kernel output, no fallback, complete silence.

**Sources:**
- LinuxQuestions thread [#4175617952](https://www.linuxquestions.org/questions/slackware-14/elilo-does-not-boot-4-14-0-huge-size-8mb-4175617952/) (elilo + 4.14 kernel same failure mode)
- xCAT issue [#6742](https://github.com/xcat2/xcat-core/issues/6742) (elilo >8 MB issue)
- elilo 3.12 release notes (size-cap documentation)
- Source confirmation: `elilo-3.16/ia32/bzimage.c`

## Root cause #2 — no display driver compiled in

The kernel config has `# CONFIG_DRM_GMA500 is not set` and `# CONFIG_DRM_GMA600 is not set`. The Atom E6xx Tunnel Creek SoC's PowerVR SGX 535 GPU is handled by the mainline `gma500_gfx` driver — but only when `CONFIG_DRM_GMA600=y` claims PCI device `8086:4108` (the Oaktrail variant). Without these, the kernel has **no display driver**. The `efifb` framebuffer alone is not enough; the panel needs `oaktrail_lvds_i2c.c` to set timings, and that driver requires `CONFIG_X86_INTEL_MID`, `CONFIG_SFI`, `CONFIG_INTEL_SCU_IPC`, `CONFIG_MFD_INTEL_MSIC` — **all currently `=n`**.

Even if cause #1 were fixed, the kernel would boot but produce no LVDS output. The `modprobe.blacklist=gma500_gfx,psb_gfx,cdv_psb` we had on the cmdline was redundant (none of those drivers are compiled in) and misleading.

**Sources:**
- `kernel/drivers/gpu/drm/gma500/psb_drv.c` line 70 — PCI ID table mapping `8086:4108` → Oaktrail chip ops
- `kernel/drivers/gpu/drm/gma500/oaktrail_lvds_i2c.c` (added by ATRON Electronic GmbH, commit `5a52b1f2f65a`, 2014-12-02)
- `kernel/drivers/gpu/drm/gma500/Kconfig` (CONFIG_DRM_GMA600 dependency)

**Critical hardware-history fact:** `CONFIG_DRM_GMA600` was **removed from mainline after kernel 5.7**. Linux 4.19 is the **last LTS with first-class Oaktrail support**. We are on the right kernel version — just had the wrong config.

## Tertiary issues identified

| # | Issue | Severity | Fix |
|---|---|---|---|
| 3 | Missing factory cmdline params: `priority_khubd=98 priority_ehciwork=44,R idle=halt ehci_hcd.log2_irq_thresh=2 memmap=2M$52M memmap=10M$54M pmemdisk=/dev/mmcblk0p7` | HIGH | Apply to elilo append OR embed via CONFIG_CMDLINE |
| 4 | `console=tty0` can spin in fbcon init if framebuffer driver doesn't claim `/dev/fb0` | MEDIUM | `nomodeset` or serial-only console for first boot |
| 5 | `earlyprintk=efi,keep` is a documented Linux 4.x hang trigger | MEDIUM | Use `earlyprintk=serial,ttyS0,115200` instead |
| 6 | `CONFIG_PCH_CAN=n` but rcS modprobes pch_can; CAN buses silently fail | LOW (post-boot) | Set `=y` |
| 7 | `CONFIG_GPIO_PCH=n` blocks EG20T GPIO access for any LED diagnostic | LOW | Set `=y` |
| 8 | `CONFIG_INPUT_PCSPKR=n` disables PC speaker BEL diagnostic | LOW | Set `=y` |
| 9 | rcS mounts `/data` (eMMC p9) for logs — but p9 contains factory Android user data; mount works but adds files alongside factory dirs | INFO | Switch primary log target to FAT32 `/boot` (Mac-readable) |
| 10 | rcS lacks incremental milestone writes — when boot fails partway, no breadcrumbs | INFO | Write `BOOT_STAGE_NN.TXT` to FAT32 at each milestone |

## Wildcard (not addressed)

Intel's `QUEENSBAY_FSP_GOLD_001` firmware (the only public FSP for Atom E6xx) has a documented **infinite-loop bug in `FspInit`**. Community-published hex patch at offset `0x1fcd8`: change `E8 42 FF FF FF` → `B8 00 80 0B 00`. Symptom matches our silent failure exactly. Fixing this is a firmware-flash operation outside Linux's reach — flagged here for awareness, not addressed by the boot fix.

## Fix path

A new kernel was built overnight (variant `M2`) with all of the following applied:

```
CONFIG_KERNEL_XZ=y                  # ~25% smaller, fits under 4 MB
CONFIG_DRM_GMA500=y
CONFIG_DRM_GMA600=y                 # Oaktrail chip
CONFIG_X86_INTEL_MID=y
CONFIG_SFI=y
CONFIG_INTEL_SCU_IPC=y
CONFIG_MFD_INTEL_MSIC=y
CONFIG_BACKLIGHT_CLASS_DEVICE=y
CONFIG_X86_SYSFB=y
CONFIG_FB_SIMPLE=y
CONFIG_PCH_CAN=y
CONFIG_GPIO_PCH=y
CONFIG_INPUT_PCSPKR=y
CONFIG_CMDLINE_BOOL=y
CONFIG_CMDLINE_OVERRIDE=y
CONFIG_CMDLINE="root=/dev/mmcblk0p3 rw rootwait console=ttyS0,115200n8 console=tty0 earlyprintk=serial,ttyS0,115200n8 loglevel=8 ignore_loglevel debug video=LVDS-1:800x480@60 video=LVDS-2:800x420@60 priority_khubd=98 priority_ehciwork=44,R idle=halt pmemdisk=/dev/mmcblk0p7 panic=10 mem=1G"
# Bloat strip
# CONFIG_BT is not set
# CONFIG_SOUND is not set
# CONFIG_BTRFS_FS is not set
# CONFIG_XFS_FS is not set
# CONFIG_F2FS_FS is not set
```

Resulting kernel: **3,181,776 bytes (3.03 MB)** — well under elilo's 4 MB limit.

Image deployed:
- `/elilo.efi` ← replaced by the new bzImage (firmware boots kernel directly via `CONFIG_EFI_STUB=y` path)
- `/EFI/BOOT/BOOTIA32.EFI` ← also the new bzImage (EFI fallback path)
- `/vmlinuz-4.19-q60` ← also the new bzImage (referenced by elilo.conf for legacy compatibility)

## Test result

**Pending — to be filled in after morning hardware test.**

## Lessons for the project

1. **Kernel size budget matters** for bootloader compatibility. Track `bzImage` size as a CI gate (`< 4 MB` for elilo ia32).
2. **`q60_kernel.config` should be a regression test artifact** — diff against last-known-good after every modification. Several config items had been silently dropped.
3. **Diagnostic-first rootfs** — every rcS milestone should write to FAT32 (Mac-readable without ext4 driver). The minimal rcS now does this; production rcS should follow the same pattern.
4. **"No DRM driver" is silent.** `efifb` works opportunistically; without it, you get a black screen with no error. Always verify `/sys/class/drm/card*` is populated as a boot smoke test.
5. **Linux 4.19 is the right LTS for this hardware**, since `DRM_GMA600` was removed after 5.7. Don't upgrade the kernel without re-verifying Oaktrail support.
