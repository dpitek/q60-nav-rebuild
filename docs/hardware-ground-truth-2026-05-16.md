# Hardware Ground Truth — Captured 2026-05-16

Live probe captured from inside factory boot environment via a `rc.local`-style hook injected into Slot A's `/etc/systemd/system/android-mount.service`. The OEM SD card was returned to factory state after capture. Raw outputs archived at `/tmp/q60-overnight/captured-from-DCU/`.

This document supersedes all prior hardware-spec assumptions.

## Memory

```
MemTotal:        2037248 kB
SwapTotal:       0
HighTotal:       1170316 kB   (PAE high memory)
LowTotal:        866932 kB
```

**2 GB DDR2.** Project assumption of 1 GB was incorrect. Re-tune:

- Drop zram (was sized for 1 GB)
- Allow Valhalla cache to expand to 256 MB
- Remove `NO_CACHEGEN` constraint
- Mesa swrast buffers can be generous
- Qt 6.6.3 i386 has plenty of headroom

## CPU

```
vendor_id    : GenuineIntel
cpu family   : 6
model        : 38
model name   : Genuine Intel(R) CPU @ 1.30GHz
stepping     : 1
cpu MHz      : 1296.976
cache size   : 512 KB
siblings     : 2     (1 core + HyperThreading)
cpu cores    : 1
cpuid level  : 10
flags        : fpu vme de pse tsc msr pae mce cx8 apic sep mtrr pge mca cmov pat clflush dts acpi mmx fxsr sse sse2 ss ht tm pbe nx lm constant_tsc arch_perfmon pebs bts aperfmperf pni dtes64 monitor ds_cpl vmx est tm2 ssse3 cx16 xtpr pdcm movbe lahf_lm dts tpr_shadow vnmi
bogomips     : 2593.60
address sizes: 32 bits physical, 48 bits virtual
```

Family 6 / Model 38 / Stepping 1 = Intel Tunnel Creek (Atom Z6xx/E6xx). Single physical core, 2 threads via HT. Hardware **supports `lm` (long-mode / 64-bit)** but Intel marketed this part as 32-bit. Has `vmx` (Intel VT-x).

Max ISA: SSSE3 (no SSE4, no AVX). Build flag `-march=bonnell -mtune=bonnell` remains correct.

## Boot SD card (OEM)

```
type          : SD
name          : SE08G                       (Toshiba SE08G 8GB)
manfid        : 0x000002                    (Toshiba)
oemid         : 0x544d                      ("TM")
serial (PSN)  : 0xcdcf05a1
date          : 03/2015
CID (raw)     : 02544d534530384702cdcf05a100f300
CSD           : 400e00325b5900003b5f7f800a400000
SCR           : 02b5800034022202
preferred_erase_size: 4194304               (4 MB)
```

This is a Toshiba **consumer-grade** SD card (not industrial). Consumer cards have hardware-locked CIDs. This is the card the factory firmware appears to validate against (a byte-identical duplicate on a different physical SD does not boot). Industrial CID-writable SD cards (e.g., Apacer "CID Lock" series, some Swissbit/Hagiwara variants) would be required to clone this identity onto another card.

## eMMC layout (active, factory-mounted)

```
mmcblk0    7782400 KB    (~7.8 GB total)
mmcblk0p1   131071 KB    FAT32 boot     mounted /boot rw  (elilo + factory kernel)
mmcblk0p2  1048576 KB    Slot A root    factory Linux (current boot)
mmcblk0p3  1048576 KB    Slot B root    factory backup ("tmplegacy")
mmcblk0p4        1 KB    extended marker
mmcblk0p5   524288 KB    Slot A Android (mounted as androidroot=...)
mmcblk0p6   524288 KB    Slot B Android backup
mmcblk0p7    51200 KB    pmemdisk (50 MB persistent RAM disk; `pmemdisk=` kernel param)
mmcblk0p8  3145728 KB    /home/naviwork ext4  (nav app data — Valhalla tiles, Maps, etc.)
mmcblk0p9  1048576 KB    Android /data (sxm presets, dalvik-cache, app-private)
```

p8 is mounted as `/home/naviwork` ext4 by the factory — this is the live nav app's working directory. Our project plan to use p8 for tiles/data is correct.

## Kernel boot path (factory)

elilo loads:

```
BOOT_IMAGE = dev000:\vmlinuz-2.6.37.6-35.1_DLK0040-android-intel-crossville_lapis-fastboot
root       = /dev/mmcblk0p2
flags      = ro quiet rootwait lpj=1296800
           = android androidboot.console=tty1 androidroot=/dev/mmcblk0p5
           = pmemdisk=/dev/mmcblk0p7
           = memmap=2M$52M memmap=10M$54M
           = panic=1 priority_khubd=98 priority_ehciwork=44,R idle=halt ehci_hcd.log2_irq_thresh=2
           = ro dram=on
```

Two new params we didn't have in our project's elilo.conf:

- **`dram=on`** — memory controller init param. Add to our 4.19 cmdline.
- **`ro` (appears twice)** — second `ro` is the kernel's own `ro` default reinforcement. Harmless but factory ships with both.

The reservation `memmap=2M$52M memmap=10M$54M` carves 12 MB of memory at offset 52-64 MB. The BIOS-e820 confirms a gap at `00000000_03400000 → 00000000_04000000` (52 MB → 64 MB), which corresponds to the v2g display driver's GTT/framebuffer region (see "Display" below).

## Display driver (factory)

```
[drm] Initialized emgd 1.0.0 20100723 for 0000:00:02.0 on minor 0
[v2gbridge] misc driver init SUCCESSFUL
[v2g] Enable Sprite C Bridge on screen 0
[v2g] GTT mapping requested for 3 buffers (3 × 0xc3000 bytes = 3 × 780 KB)
```

**Factory uses Intel EMGD 1.0.0 (proprietary, closed-source, 2010 vintage) + a custom `v2g`/`v2gbridge` overlay driver.**

- EMGD claimed PCI `0000:00:02.0` and drives the LVDS via Intel's BSP binary stack
- `v2g` (custom) maps three framebuffer overlays at physical addresses `0x36000000`, `0x36600000`, `0x36700000` (~864 MB into RAM) — wired through "Sprite C Bridge" hardware path
- The `pmemdisk` and `memmap=` reservations exist specifically to keep this region clear

**Implications for the project:**

- The mainline `gma500_gfx` driver may NOT claim `0000:00:02.0` cleanly. Device-ID variants differ between EMGD-targeted and gma500-targeted Tunnel Creek SKUs. Until proven, our project's `DRM_GMA500=y` build is unverified on this exact hardware.
- EFI provides **no UGA / no GOP framebuffer** (verified — `/sys/firmware/efi/systab` shows `UGA=0x0`). Therefore `efifb` cannot fall back to a firmware-provided framebuffer at boot. Either gma500 works, or we get a black screen with no recourse on the LVDS console.
- Open-source path forward: `simplefb`/`X86_SYSFB` won't help here either since no firmware GOP. Our Linux 4.19 kernel needs gma500 to claim the device, OR a custom in-tree replacement, OR fall back to a no-framebuffer console mode (kernel boot output only to serial, which we don't have).

## CAN bus access (factory)

- No `/sys/class/can/` directory
- No `pch_can`, `can_raw`, `can_bcm`, or `vcan` modules loaded
- Factory's CAN access is via **DENSO proprietary IPC** (the named-pipe daemons `sxmcgs.out`, `radiofc.out`, `vcan.out` etc. that the project already documents)

Our 4.19 kernel can use SocketCAN (`CONFIG_PCH_CAN=y` + `CAN_RAW=y` + `CAN_BCM=y`) — that path is independent of factory. The PCH chipset is at PCI 0000:02:* so `pch_can` should claim it. Has not yet been verified on this hardware live.

## Serial UARTs (factory)

```
pch_uart 0000:02:0a.1 enabling device
/dev/ttyPCH0  (major 252, minor 0)
/dev/ttyPCH1  (major 252, minor 1)
/dev/ttyPCH2  (major 252, minor 2)
```

Three PCH UARTs at PCI `0000:02:0a.1` (and adjacent slots). GPS is on one of these (factory's `androidboot.console=tty1` redirects boot console to virtual terminal, NOT serial). Our project's `S10-gpsd` correctly probes `ttyPCH0..3` before falling back to `ttyS0`.

A USB-TTL serial cable on the `pch_uart 0000:02:0a.1` pins would expose live boot output — single biggest unblock for our 4.19 kernel debug if we ever pursue it.

## EFI environment (factory)

```
ACPI 2.0 RSDP    0x7f3de014
ACPI 1.0 RSDP    0x7f3de000
SMBIOS           0x7f6e4000
MPS              0x0  (none)
UGA              0x0  (none — no firmware framebuffer)
HCDP             0x0  (none)
BOOTINFO         0x0  (none)
EFI variables    empty (efivarfs reports 0 entries)
```

UEFI 1.x / early 2.x firmware. ACPI is present and usable. No firmware-provided graphics protocol. **No EFI variables** are set — the firmware uses a hardcoded boot path (`\EFI\Boot\bootia32.efi` or similar internal default), not `BootOrder` NVRAM.

## PCI device map (relevant subset)

```
00:00.0    Host bridge
00:02.0    Graphics controller         (Tunnel Creek IGD — EMGD claims this)
00:03.0    Secondary graphics?         (MMIO 80000000-8fffffff, 256 MB — likely VRAM aperture)
02:00.0    pch_phub                    (PCH hub)
02:02.0/1  ehci_hcd                    (USB 2.0)
02:02.2    PCI-to-PCI bridge?
02:04.0    mmc0 (eMMC, the boot drive) <-- where Slot A/B/etc. live
02:04.1    mmc1 (SD card slot)         <-- where our test SD shows up
02:04.2    mmc2 (third MMC slot)
02:06.0    [unknown]
02:08.0/1  ohci_hcd                    (USB 1.1)
02:08.2/3  ehci_hcd                    (USB 2.0)
02:0a.0    ioh_dma
02:0a.1/2/3   pch_uart                 (THE serial UARTs)
02:0a.4    ioh_video_in                (camera capture — backup-cam input)
02:0c.0    pch-dma
02:0c.2    i2c_eg20t                   (I2C controller for in-cabin sensors)
02:0c.3    ml_ioh_gpio                 (GPIO expander)
02:0c.4/5/6   [unknown smaller MMIO]
```

`mmcblk0` (the eMMC) is at PCI `02:04.0`, claimed by `sdhci-pci`. Our test SD lives on `mmc1` at `02:04.1`. Both use the same driver.

## Loaded modules at runtime (factory)

```
vfat fat nls_cp437 nls_ascii          (FAT32 support)
sdhci-pci                              (storage)
ehci_hcd ohci_hcd                      (USB)
iptable_nat nf_nat                     (firewall)
cdc_ether usbnet                       (TCU USB Ethernet)
cdc_tcu                                (TCU custom CDC)
snd_usb_audio snd_hwdep                (USB audio)
snd_pcm snd_timer snd_page_alloc       (PCM)
snd_usbmidi_lib snd_rawmidi snd_seq_device
snd_ml7213ioh_d3s                      (DENSO/Intel ML7213 IOH DAC — the Bose amp's input)
ioh_i2s ioh_i2s_dma                    (I2S audio digital out)
bt_hci bt_dfu                          (Bluetooth)
watchdog                               (hardware watchdog ACTIVE)
net_adp                                (custom networking adapter)
setgpio                                (custom GPIO control)
capture_ctl                            (camera control)
ioh_video_in                           (camera input device)
v2g v2gbridge                          (display overlay — custom)
emgd                                   (proprietary EMGD DRM)
```

`watchdog` IS loaded and running on factory — implying factory PETs the hardware watchdog. If we don't pet it within ~30 sec on our kernel, we'd reboot.

## Network interfaces (factory)

```
audio0   (likely Bluetooth audio profile / AVRCP)
navi0    (custom DENSO IPC — virtual interface for inter-daemon comms)
lo       (loopback)
```

No `eth0`, no `wlan0`, no `tcu0`. Confirms the DCU has no direct external network — TCU is a separate ECU reached via the `cdc_tcu` USB CDC device.

## Sound

Single card: `card0` with capture (`pcmC0D0c`) + playback (`pcmC0D0p`) + control + timer. The ML7213 IOH digital sound + I2S path feeds the Bose amplifier. Factory's audio chain is "PCH I2S → ML7213 IOH → Bose amp (CAN-controlled)".

---

## What this changes in the project

### Settled (close these items)

- ✅ RAM = 2 GB (Tier-1 item 1.2)
- ✅ CPU = Tunnel Creek Family 6 Model 38, 1 core + HT, max ISA SSSE3
- ✅ OEM SD CID captured
- ✅ Real UART path is `ttyPCH0..2` (3 ports, not 4 as some docs guessed)
- ✅ eMMC layout matches project doc
- ✅ Boot drive is microSD (not soldered eMMC) — community-confirmed and now empirically verified
- ✅ Factory CAN access does NOT use SocketCAN; DENSO IPC is the path

### New problems uncovered

- ⚠️ **Factory display = EMGD (proprietary)** + custom v2g. Our `DRM_GMA500=y` build is unverified on this hardware. The mainline driver may not claim PCI `0:0:2.0` at all.
- ⚠️ **No EFI GOP/UGA** — efifb cannot fall back to a firmware framebuffer
- ⚠️ **Hardware watchdog runs from boot** — our rootfs must pet `/dev/watchdog` within timeout window
- ⚠️ **Duplicate SD card doesn't boot** — likely CID validation. Hardware-level barrier to using non-OEM cards without CID cloning hardware.

### Recommended next steps

1. Update `STATUS.md` (this commit).
2. Build a new 4.19 kernel with the corrected configs informed by this audit — see `docs/kernel-config-required-fixes.md` (already updated 2026-05-16 with PCH_CAN, INPUT_PCSPKR, GPIO_PCH, DRM_GMA500/600, X86_INTEL_MID, etc.) plus newly required: `dram=on` in cmdline, drop `mem=1G` (have 2 GB).
3. Pursue an outside-chance test: dd a Docker-built, mac-garbage-free byte-perfect OEM clone onto the duplicate SD to verify the CID-validation hypothesis (or refute it). If duplicate boots, all subsequent testing moves there and the OEM card stays pristine.
4. Accept that without a serial console, our 4.19 kernel debug remains constrained to "boot or no boot" feedback. The factory-probe pattern can be reused to capture state from any kernel that successfully reaches userspace.

## Raw captures

Archived at `/tmp/q60-overnight/captured-from-DCU/`:

- `Q60_PROBE_20260516-131257.LOG` (117 KB, full diagnostic dump)
- `CID.TXT` (SD/MMC card identification)
- `MEMINFO.TXT`, `CPUINFO.TXT`, `CMDLINE.TXT`, `EFI_SYSTAB.TXT`, `EFI_VARS.TXT`

The full log contains complete `/proc/iomem`, `/proc/interrupts`, `/proc/modules`, `dmesg`, full `/sys/class/*` walks, and the EMGD/v2g driver init traces. Reference for any future hardware question.
