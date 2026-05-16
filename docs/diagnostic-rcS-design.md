# Diagnostic rcS Design — Boot Visibility Without a Serial Cable

When the LVDS is black on first boot and no serial cable is connected, the only way to know what happened is **what rcS wrote to disk before things stopped**. This document records the design of the minimal diagnostic rcS used during boot bring-up, so any future failures can be triaged without hardware probes.

## Storage target — FAT32 boot partition, not ext4 /data

The factory eMMC's `/dev/mmcblk0p9` is the Android `/data` partition (factory user data — SXM presets, app caches). Mounting it as Linux `/data` works (it's ext4) but mixing factory and our diagnostic files there is a poor signal. Worse: macOS cannot read ext4 natively — log retrieval requires Docker.

The FAT32 `/boot` partition (`/dev/mmcblk0p1`) is:
- Already mounted by elilo at boot
- Mac-readable without any drivers
- Small (134 MB) so easy to inventory
- Already the boot-counter location per [boot-safety.md](boot-safety.md)

**Rule:** all diagnostic output from minimal rcS goes to FAT32 `/boot/`. Production rcS may mount p9 for app data later, but boot-visibility logs stay on FAT32.

## Incremental milestone markers

Instead of one log file at the end of rcS, write a tiny marker file at each milestone:

```
/boot/BOOT_STAGE_01.TXT  rcS started, pseudo-fs mounted, /boot mounted
/boot/BOOT_STAGE_02.TXT  /run mounted
/boot/BOOT_STAGE_03.TXT  /dev/pts mounted
/boot/BOOT_STAGE_04.TXT  hostname=q60-nav
/boot/BOOT_STAGE_05.TXT  early dmesg captured (NN lines)
/boot/BOOT_STAGE_06.TXT  hardware audit captured
/boot/BOOT_STAGE_07.TXT  attempting tty0 banner
/boot/BOOT_STAGE_08.TXT  tty0 banner echo'd
/boot/BOOT_STAGE_09.TXT  fb0 exists / fb0 MISSING
/boot/BOOT_STAGE_10.TXT  fb0 painted
/boot/BOOT_STAGE_99.TXT  rcS complete entering heartbeat loop
/boot/BOOT_STAGE_100.TXT 60s heartbeat done, poweroff
```

After power-off, pull SD, insert in Mac, run:

```bash
ls /Volumes/boot/BOOT_STAGE_*.TXT
```

**Highest-numbered file = how far rcS got.** Missing stages indicate exactly where boot stopped. No guesswork.

## Companion log files

```
/boot/BOOT_DMESG_EARLY.LOG   Full dmesg captured at STAGE_05
/boot/BOOT_AUDIT.LOG         Hardware audit (meminfo, cpuinfo, partitions, mounts, modules, drm, tty, mmc, net, fb)
/boot/BOOT_HEARTBEAT.LOG     One line per 5-second heartbeat (proves system stayed alive)
```

## tty0 + fb0 banner attempt

Two independent attempts at visible output:

1. `clear > /dev/tty0 ; echo BANNER > /dev/tty0` — text on the framebuffer console
2. `dd if=/dev/zero bs=1024 count=64 | tr '\0' '\377' > /dev/fb0` — write 64 KB of `0xFF` to the framebuffer directly; if a panel is initialized but `fbcon` isn't attached, this still shows visible pixels

If either works, the upper LVDS shows *something*. If neither works, the panel isn't initialized at all.

## Heartbeat + auto-poweroff

A loop runs 12 iterations of 5-second sleep + sync + heartbeat-line-append. After 60 seconds, `poweroff -f` runs. This:

- Proves the system survived 60 seconds (not a watchdog-induced loop)
- Forces a clean filesystem flush before power-down
- Avoids the need to physically yank power (which can corrupt FAT32 in flight)

## What this is NOT

- Not a production rcS. The real q60nav rcS will be much richer (start Weston, launch the app, etc.).
- Not a replacement for serial console. When a TTL cable is available, use it — incremental files are slow compared to live serial.
- Not a substitute for a working watchdog. The diagnostic rcS deliberately does *not* feed `/dev/watchdog`, so if the kernel hangs the watchdog fires and we see a reboot loop (also a signal).

## Recovery procedure when boot fails

1. Power off DCU
2. Pull eMMC (or SD if testing on adapter)
3. Insert in Mac. FAT32 `boot` volume auto-mounts.
4. `ls /Volumes/boot/BOOT_STAGE_*.TXT`
5. Read the highest-numbered file's content for timestamp
6. `cat /Volumes/boot/BOOT_DMESG_EARLY.LOG | tail -100` for kernel boot trace if STAGE_05 ran
7. `cat /Volumes/boot/BOOT_AUDIT.LOG` for hardware state if STAGE_06 ran
8. If no BOOT_STAGE_*.TXT exists → kernel never reached init. Bootloader or kernel-level failure. See [boot-failure-rca.md](boot-failure-rca.md) for known causes.

## Reference implementation

The diagnostic rcS lives at `rootfs/etc/init.d/rcS` (replacing the previous version which did not write incremental status). It's intentionally short (~80 lines) and uses only busybox built-ins so it works on the minimal i386 rootfs.

## When to deprecate

Once Stage 1 (minimal boot) succeeds on hardware and Stage 2 (full q60nav rootfs) is in place, the production rcS will take over. The diagnostic version stays as `rootfs/etc/init.d/rcS.diag` for re-use whenever a future change blackens the screen.
