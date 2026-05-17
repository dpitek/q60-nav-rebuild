# Q60 Nav Rebuild — Claude Session Instructions

## Project in one sentence
Ground-up replacement navigation system for a 2017 Infiniti Q60 (Clarion QY5092 DCU),
delivered as an R1 overlay client that paints arbitrary content onto the factory
EMGD Sprite C overlay plane via `/dev/v2gbridge`, while the factory nav keeps running.

## Hardware context (critical for every decision)
- **SoC:** Intel Atom E6xx "Crossville Lapis" — i386, no SSE4, no AVX
- **GPU:** Intel EMGD 1.5.15.3226 on Tunnel Creek IGD + LAPIS ML7213 IOH
- **OS:** Wind River Linux 2.6.37.6-35.1_DLK0040-android-intel-crossville_lapis-fastboot
- **Init:** `/sbin/init android` (Android init, uses init.rc — NOT systemd, NOT SysV init.d)
- **RAM:** 2 GB DDR2 (confirmed via runtime probe)
- **Displays:** 800×480 LVDS upper (nav), 800×420 LVDS lower (control hub)
- **eMMC:** 9 partitions — Slot A (factory, NEVER written), Slot B (our system)
- **SD card (test):** 64 GB at `/dev/disk12` on Doug's Mac. Slot A = `disk12s2`, boot = `disk12s1`.

## Current active focus: R1 Overlay (v2gbridge)
The R1 client intercepts the factory EMGD Sprite C overlay plane (`/dev/v2gbridge`) to
paint arbitrary UI content on top of the factory nav without disrupting it.

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

### Current blocker
`V2G_ENABLE` always returns EINVAL because `enable_direct_display_tnc()` reports
"GTT mapping requested for 0 buffers". The IOH DMA engine has no active camera
frames even after V4L2 REQBUFS+STREAMON — requires physical camera signal OR
`V2G_DISPLAY_FRAME` to prime the buffer count.

### Next boot tests (already in binary as of 2026-05-17)
1. **V2G_DISPLAY_FRAME(0,1,2)** then V2G_ENABLE — theory: DISPLAY_FRAME increments IOH DMA count
2. **YUYV red pixel write → V4L2 buf[0] mmap → ALTER_OVL2 plane=5** — bypasses V2G entirely
3. **Android init.rc scan** — `/init.rc`, `/system/init.rc`, `/etc/init/` for 75s delay source
4. **camera_ps process inspection** — maps + fds to understand production V2G flow

## Deploy cycle (5 minutes end-to-end)
```bash
# Build
mkdir -p /tmp/q60-overnight/r1-build
cp app/src/r1_overlay/q60nav_v4l2_test.c /tmp/q60-overnight/r1-build/
docker run --rm --platform linux/386 -v /tmp/q60-overnight/r1-build:/build alpine:latest sh -c '
  apk add --no-cache gcc musl-dev binutils >/dev/null
  gcc -static -no-pie -O2 -Wall -o /build/q60nav_v4l2_test.static /build/q60nav_v4l2_test.c
  objcopy --remove-section=.note.ABI-tag --strip-all /build/q60nav_v4l2_test.static
  ls -la /build/q60nav_v4l2_test.static'

# Deploy (requires sudo terminal — cannot run headlessly)
sudo bash app/src/r1_overlay/deploy-thorough.sh /dev/disk12s2

# Read logs after boot
cat /Volumes/boot/Q60_R1_V4L2.LOG     # main test output
cat /Volumes/boot/Q60_HOOK_RAN.TXT    # hook pipeline confirmation
cat /Volumes/boot/Q60_KMSG.LOG        # kernel ring buffer
```

## Key source files
| File | Role |
|------|------|
| `app/src/r1_overlay/q60nav_v4l2_test.c` | Main test binary (phases P0-P6) |
| `app/src/r1_overlay/deploy-thorough.sh` | Full redeploy script |
| `docs/v2gbridge-hardware-findings-2026-05-17.md` | All hardware test findings |
| `ONBOARDING.md` | Live research log (always-current summary) |
| `docs/plan-r1-v2gbridge-research.md` | Architecture research |
| `docs/r1-privilege-findings.md` | DRM privilege model findings |
| `emu/README.md` | Factory daemon emulator for iteration without hardware |

## What NOT to do
- **Never kill emgdhmid** — dropping DRM master cascades to display_ps + navi_ps crash
- **Never write to Slot A** (`disk12s2`) from inside the factory system — it's the factory OS
- **Slot B** (`disk12s3`) is the factory-clean reference for android-mount.sh — read from it, never write
- **V2G_ENABLE with `_IOW` cmd** — driver rejects all non-`_IOWR` variants
- **V2G_DISPLAY_FRAME arg must be 0, 1, or 2** — not packed bit-field values

## Alt display paths to investigate (if V2G_ENABLE remains blocked)
1. **ALTER_OVL2 directly with V4L2 GTT buffer** — write YUYV pixels to mmap'd buf[0], call ALTER_OVL2 with gtt_offset=0x000000
2. **GMM_ALLOC parameter sweep** — currently rtn=-2; try different type/flags values
3. **`/proc/camera_ps_pid/mem` write** — root access, write pixels to camera_ps's existing GTT surface
4. **PVR display class via `libemgdsrv_um.so`** — loaded by emgdhmid, bypasses DRM master

## Simulator (for UI iteration without hardware)
```bash
# Web-based (browser at localhost:8080)
./scripts/run-simulator-web.sh

# VNC-based
./scripts/run-simulator.sh   # connect VNC on :5900
```
Factory daemon emulator: `emu/` directory. See `emu/README.md`.

## Project status (as of 2026-05-17)
- Qt 6 app + all services: complete, simulator-verified
- R1 overlay infrastructure: boot hook + V4L2 + DRM confirmed. V2G_ENABLE blocked (IOH DMA count=0).
- Next milestone: paint pixels to Sprite C (via V2G or ALTER_OVL2 direct path)
- After overlay works: integrate with Qt6 app, ship to Slot B

## Memory & logs
Claude project memory: `~/.claude/projects/-Users-dpitek-Developer-q60-rebuild--claude-worktrees-confident-liskov-59d5d2/memory/`
File access log: `~/.claude/file-access.log`
