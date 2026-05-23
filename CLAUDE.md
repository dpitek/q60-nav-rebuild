# Q60 Nav Rebuild — Claude Session Instructions

## Project in one sentence
Ground-up replacement navigation system for a 2017 Infiniti Q60 (Clarion QY5092 DCU),
running Linux 4.19 + Qt6 + Weston on the factory hardware, replacing the factory Wind River
nav entirely. Phase 1 (current) validates the gma500 display driver on real hardware.

## Hardware context (critical for every decision)
- **SoC:** Intel Atom E6xx "Crossville Lapis" — i386, no SSE4, no AVX
- **GPU:** Intel EMGD 1.5.15.3226 on Tunnel Creek IGD + LAPIS ML7213 IOH
- **OS:** Wind River Linux 2.6.37.6-35.1_DLK0040-android-intel-crossville_lapis-fastboot
- **Init:** `/sbin/init android` (Android init, uses init.rc — NOT systemd, NOT SysV init.d)
- **RAM:** 2 GB DDR2 (confirmed via runtime probe)
- **Displays:** 800×480 LVDS upper (nav), 800×420 LVDS lower (control hub)
- **eMMC:** 9 partitions — Slot A (factory, NEVER written), Slot B (our system)
- **SD card (test):** 64 GB. Disk number varies by session — check `diskutil list` (currently `/dev/disk4`). Boot = `s1` (FAT32), Slot B = `s3` (Linux ext4, q60diag label).

## R1 Overlay Research (superseded 2026-05-22 — kept as hardware reference)
The R1 approach intercepted the factory EMGD Sprite C overlay plane (`/dev/v2gbridge`).
Superseded by the Phase 1 full-replacement approach. All findings below remain valid hardware facts.

### Infrastructure (confirmed working)
- **Boot hook:** `android-mount.sh` on Slot A (patched via `debugfs`) runs our test binary
  at every boot, root, before any factory process. Pipeline: `android-mount.sh` →
  `run.sh` → `/opt/q60r1/v4l2_test`. Confirmed rc=0 every boot.
- **Build:** `docker run --platform linux/386 alpine gcc -static -no-pie -O2`
  + `objcopy --remove-section=.note.ABI-tag --strip-all`
- **Deploy:** `sudo bash app/src/r1_overlay/deploy-thorough.sh /dev/disk12s2`
  (reads Slot B as clean base, injects hook, writes binary via `debugfs`)
- **Binary:** `app/src/r1_overlay/q60nav_v4l2_test.c` → `/tmp/q60-overnight/r1-build/q60nav_v4l2_test.static`
- **Logs after boot:** `/Volumes/boot/Q60_R1_V4L2.LOG`, `Q60_KMSG.LOG`, `Q60_HOOK_RAN.TXT`

### Confirmed hardware facts (from live boot logs)
| Fact | Value |
|------|-------|
| V4L2 buffers | 3 × 953,472 B at GTT offsets 0x000000 / 0x0e9000 / 0x1d2000 |
| V4L2 format | 800×480 YUYV pitch=1600 |
| V2G_ENABLE_BRIDGE cmd | `0xc0047600` = `_IOWR('v',0,4)` |
| V2G_DISABLE_BRIDGE cmd | `0xc0047601` — always r=0 |
| V2G_DISPLAY_FRAME cmd | `0xc0047602` = `_IOWR('v',2,4)` — takes buf index 0/1/2 |
| V2G struct layout | `{uint32_t plane, uint32_t screen}` — 8 bytes; driver reads past cmd size |
| Valid overlay planes | 3 (primary overlay), 5 (Sprite C) |
| EMGD portorder | `2,4,0,0,0` → port 2=LVDS, port 4=SDVO |
| IGD_ALTER_OVL2 | `0xc0c8646f` — requires DRM_AUTH only (not master); r=0 for planes 3 and 5 |
| DRM_SET_MASTER | Succeeds as root without killing any factory process |
| emgdhmid | pid varies, holds DRM master — **DO NOT KILL** (crashes nav) |
| camera_ps | The actual V2G bridge manager (not emgdhmid). Manages rearview camera path. |
| 75s boot delay | `/bin/usleep 75000000` spawned directly by init (ppid=1). Source: Android init.rc, NOT init.d. Suspect: `/init.rc` or `/system/init.rc`. |

## Phase 1: Display Gate Test (current focus, 2026-05-22)

**Goal:** Does gma500 (mainline Linux 4.19 driver) claim the LVDS upper display on Crossville Lapis?
This is the critical gate for the full replacement approach.

### Architecture pivot (2026-05-22)
Moved from R1 overlay approach (V2G/Sprite C) to **full factory nav replacement** (Phase 1–4):
- Phase 1: gma500 display gate + diagnostic boot
- Phase 2: Qt6 + Weston rendering on real hardware  
- Phase 3: Navigation services (Valhalla, geocoder, tiles)
- Phase 4: CAN integration + production polish

### Image workflow (mandatory — never skip emulator)
1. Develop → 2. Emulator validate → 3. SD card deploy → 4. Car test

| Image | Role | Touch? |
|-------|------|--------|
| `images/DSU backup.img` | Factory system backup | NEVER — read-only |
| `images/q60-nav-rebuild.img` | Working development image (disk7) | Source of truth |
| `images/infiniti-q60-nav-original.img` | Factory nav map | NEVER — read-only |
| `images/infiniti-q60-nav-working.img` | Working nav map copy | Read-write |
| SD card (disk number varies) | Physical SD card → car | Deployed via script |

### Deploy (ONE command — no manual dd)
```bash
# Check disk number first: diskutil list
# Then deploy (currently disk4):
sudo bash scripts/deploy-phase1-sd.sh -y disk4
```
Writes boot partition + Slot B. Sets `default=q60nav` for test boot.
rcS restores `default=logan1` as first action — car always recovers.

### Read logs after car boot
```bash
cat /Volumes/boot/Q60_DISPLAY_GATE.TXT    # PASS or FAIL — the gate
cat /Volumes/boot/Q60_DRM_STATE.LOG       # gma500 binding, /dev/fb0 state
cat /Volumes/boot/Q60_DMESG_POST_GFX.LOG # kernel output from gma500 init
cat /Volumes/boot/Q60_INVENTORY.LOG       # full hardware inventory pre-probe
cat /Volumes/boot/Q60_DIAG_STAGES.LOG    # boot stage timestamps
```

### Failsafes (all active)
- **elilo.conf default=logan1 restore**: rcS does this FIRST after /boot mount
- **ie6xx_wdt NOT loaded** in diagnostic: no watchdog arm without keeper
- **Watchdog pre-arm detection**: if BIOS pre-arms /dev/watchdog, rcS tries magic-close ('V')
- **Boot counter cleared**: rcS removes `/boot/q60_boot_attempts` so start.sh counter doesn't accumulate
- **idle=halt** in q60nav cmdline: prevents Atom E6xx C-state issues
- **panic=1** + constant sync: every log write synced before kernel can panic-reboot

### Phase 1 artifacts
| File | Role |
|------|------|
| `output/bzImage-4.19-q60` | Linux 4.19 kernel (i386, gma500/GMA600 built-in, 3.1 MB XZ) |
| `output/q60-diag-rootfs-phase1.img` | 512 MB ext4 diagnostic rootfs (label: q60diag) |
| `scripts/deploy-phase1-sd.sh` | One-command SD card deploy |
| `configs/q60_kernel.config` | Canonical kernel config (source of truth — never edit kernel/.config directly) |
| `rootfs/etc/init.d/rcS` | Diagnostic init script |
| `rootfs/opt/nav/watchdog-pet.sh` | Sole watchdog keeper (production) |

### Kernel config changes (applied 2026-05-22)
- `CONFIG_DRM_GMA500/GMA600=y` + `CONFIG_DRM_TTM=y` — gma500 driver, claims PCI 0x4108
- `CONFIG_X86_UP_APIC=y` + `CONFIG_X86_UP_IOAPIC=y` — enables APIC dep chain for X86_INTEL_MID
- `CONFIG_X86_INTEL_MID=y` + `CONFIG_SFI=y` + `CONFIG_INTEL_SCU_IPC=y` + `CONFIG_MFD_INTEL_MSIC=y` — MID platform (compile-time only; elilo sets hardware_subarch=0 so MID runtime never fires)
- `CONFIG_SERIAL_PCH_UART=y` + `CONFIG_SERIAL_PCH_UART_CONSOLE=y` — creates /dev/ttyPCH0
- `CONFIG_KERNEL_XZ=y` — XZ compression, 3.1 MB (931 KB headroom under elilo 4 MB limit)
- `CONFIG_CMDLINE_BOOL=y` (no OVERRIDE) — embedded fallback cmdline; elilo.conf is authoritative
- BT + SOUND stripped to save space
- Build: `docker run --platform linux/amd64 ubuntu:22.04 ... /tmp/q60-kernel-build.sh`

### Watchdog design (production — Phase 2+)
- `ie6xx_wdt` loaded by production rcS
- `watchdog-pet.sh` is the **sole** holder of `/dev/watchdog` — q60nav does NOT hold it
- Pet every 20s (30s timeout); SIGTERM triggers magic-close to disable cleanly
- If process crashes without 'V': fd closes → watchdog fires → reboot → boot counter check
- Boot counter ≥ 2 (in `start.sh`): edits elilo.conf to `default=logan1` → factory boot

## Key source files
| File | Role |
|------|------|
| `rootfs/etc/init.d/rcS` | Production init script |
| `rootfs/opt/nav/start.sh` | App launcher + boot counter + CAN init |
| `rootfs/opt/nav/watchdog-pet.sh` | Hardware watchdog keeper |
| `scripts/deploy-phase1-sd.sh` | Phase 1 SD card deploy |
| `output/bzImage-4.19-q60` | Linux 4.19 kernel for Q60 |
| `output/q60-diag-rootfs-phase1.img` | Phase 1 diagnostic rootfs |
| `ONBOARDING.md` | Live research log (always-current summary) |
| `emu/README.md` | Factory daemon emulator |

## What NOT to do
- **Never kill emgdhmid** — dropping DRM master cascades to display_ps + navi_ps crash
- **Never modify DSU backup.img** — EVER, even read-only is preferred
- **Never write to Slot A** (`mmcblk0p2`) from inside the factory system
- **Never test in car without emulator validation first**
- **Never use /dev/ttyS0** for rcS output — use /dev/console (always exists)
- **Never load ie6xx_wdt in diagnostic rcS** — no keeper = watchdog fires mid-capture

## Simulator (for UI iteration without hardware)
```bash
./scripts/run-simulator-web.sh   # browser at localhost:8080
./scripts/run-simulator.sh       # VNC :5900
```

## Project status (as of 2026-05-23)
- Qt 6 app + all services: complete, simulator-verified
- Phase 1 kernel: rebuilt with all required configs (gma500, ttyPCH0, MID platform) — 3.1 MB ✓
- Phase 1 diagnostic rootfs: built, emulator-validated (19/19 tests pass)
- Phase 1 first car boot (2026-05-23): **two black screens** — rootfs not deployed + deploy script bug (missing `root=LABEL=q60diag` in update path). Both fixed. See ONBOARDING.md Finding 13.
- **Next:** `sudo bash scripts/deploy-phase1-sd.sh -y disk4` → car boot → read logs
- Display gate (gma500 + LVDS): **UNTESTED on hardware** — next boot answers it

## Memory & logs
Claude project memory: `~/.claude/projects/-Users-dpitek-Developer-q60-rebuild--claude-worktrees-confident-liskov-59d5d2/memory/`
File access log: `~/.claude/file-access.log`
