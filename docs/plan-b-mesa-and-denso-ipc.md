# Plan B Research: Mesa Stack & DENSO IPC

**Date:** 2026-05-16
**Context:** Pivot to factory kernel 2.6.37, EMGD-driven framebuffer, Qt 5.15 i386 Bonnell.
**Budget:** ~30 min. Sources: kernel.org Mesa docs, Bosch/DENSO OSS portals, infinitiq50 forums, Qt embedded docs.

---

## TL;DR — verdict first

**(A) Mesa: don't build it. Use Qt 5.15 `linuxfb` + `QT_QUICK_BACKEND=software`. Zero Mesa, zero EGL, zero GL.**
The linuxfb QPA plugin is *explicitly* a software-only backend that writes raster pixels via `mmap()` to `/dev/fbN`. Qt Quick's software renderer (added Qt 5.8, stable in 5.15) replaces the scene-graph GL renderer with a `QPainter`/raster path. Together they form a complete pipeline that does not link, dlopen, or call into Mesa, libGL, libEGL, libGLESv2, libgbm, or libdrm at all. This is the simplest answer and it is viable — with one caveat about EMGD framebuffer ownership covered below.

**(B) DENSO IPC: protocol is undocumented publicly. Reverse it on the live unit.**
No public RE write-up exists for `sxmcgs.out`, `radiofc.out`, `sound.out`, `vcan.out`. The forum community has rooted the InTouch DCU (USB-TTL + systemd patch) but has not published daemon-level wire formats. The Bosch/Nissan OSS bundles publish *GPL/MIT components* only — the DENSO-proprietary daemons are **not** in those bundles. Best path: capture the named-pipe traffic on a rooted DCU while the factory app exercises each function, then synthesize a Python prober. Probable format: short ASCII commands, newline-terminated (consistent with DENSO's tracing patterns in their published `tmot` and `aivi` source drops).

---

## Part A — Mesa swrast / softpipe build (or rather: skip it)

### A1. Mesa kernel-version requirements over time

The Mesa project does not document a hard "minimum kernel" the way the kernel team does — what matters is **libdrm uAPI** and **DRM ioctl** versions. Software-only rasterizers (swrast, softpipe, llvmpipe) **do not require any kernel DRM at all** — they're pure CPU paths. The "minimum kernel" question only bites when you enable DRI/DRM drivers.

Rough mapping (from Mesa release notes + LFS BLFS build docs):

| Mesa era | Practical kernel floor | Notes |
|---|---|---|
| 7.x–10.x (2009–2014) | 2.6.18+ | DRI1 era, easy on 2.6.37 |
| 11.x–13.x (2015–2016) | 2.6.32+ | DRI2/3 splits begin |
| 17.x (2017) | 3.10+ recommended, 2.6.x still buildable for software-only | Last era practical for legacy kernels |
| 18.x–19.x (2018–2019) | 3.10+ for DRI; meson build appears | Software-only paths still kernel-agnostic |
| 20.x+ (2020) | 4.x+ for hw drivers | Software paths still kernel-agnostic, but build deps (meson, modern libdrm) start hurting |
| 21+ | libdrm 2.4.110+, modern meson, modern compiler | Painful on a 2.6.37 toolchain |

**For Plan B target (Linux 2.6.37 + Qt 5.15 i386 Bonnell):** if you needed Mesa, **Mesa 17.3.x** is the sweet spot — it still supports the autotools build, has llvmpipe + softpipe + swrast classic, builds for i386, and works fine with old libdrm. But — see below — you don't need it.

### A2. The "no Mesa at all" path (recommended)

Qt 5.15 ships two independent layers that together replace the entire GL stack:

1. **`linuxfb` QPA plugin** (Qt Platform Abstraction)
   - Writes pixels directly to `/dev/fb0` via `mmap()`.
   - "The linuxfb plugin is meant for software-based rendering only." — Qt 5.15 docs.
   - Configure with `QT_QPA_PLATFORM=linuxfb` (optionally `:fb=/dev/fb0:size=800x480:offset=0x0`).
   - Available since Qt 5.0. Stable, low risk.

2. **Qt Quick software renderer** (`QT_QUICK_BACKEND=software`)
   - Replaces the scene-graph OpenGL renderer with `QPainter` on raster surfaces.
   - "Only renders what changed between two frames" — efficient on slow hardware.
   - Supports the entire `QtQuick.Controls 2` and `QtLocation` UI surface, minus `Quick3D`/effects that require shaders.
   - Added Qt 5.8, mature by 5.15.

### A3. Build flags for Qt 5.15 — the bare-minimum config

When configuring Qt 5.15 i386 for Plan B, the goal is to omit every GL/EGL dep so the build doesn't even try to find Mesa:

```sh
./configure \
  -prefix /opt/qt5 \
  -release \
  -opensource -confirm-license \
  -platform linux-g++-32 \
  -xplatform linux-g++-32 \
  -no-opengl \
  -no-egl \
  -no-eglfs \
  -no-glib \
  -no-xcb \
  -no-xkbcommon \
  -no-libinput \
  -qpa linuxfb \
  -linuxfb \
  -no-feature-vulkan \
  -no-feature-d3d12 \
  -system-freetype \
  -fontconfig \
  -qt-zlib -qt-libpng -qt-libjpeg \
  -nomake examples -nomake tests \
  -skip qtwebengine -skip qt3d -skip qtquick3d -skip qtcanvas3d \
  -skip qtwayland
```

Then at runtime:

```sh
export QT_QPA_PLATFORM=linuxfb:fb=/dev/fb0:size=1280x480
export QT_QUICK_BACKEND=software
export QT_LOGGING_RULES='qt.qpa.*=true'   # for first-boot debugging only
exec /opt/nav/bin/q60nav
```

No Mesa, no llvmpipe, no swrast — Qt's own raster engine carries the load.

### A4. The EMGD-framebuffer-ownership caveat

EMGD (Intel's proprietary 2010-era GMA driver) wants exclusive ownership of the framebuffer to coordinate CPU + GPU memory access. There are two scenarios:

**Scenario 1 — EMGD kernel module is loaded but no EMGD X server is running.**
Then `/dev/fb0` is a normal fbdev device exposed by EMGD's KMS-free framebuffer attachment. Userspace `mmap()` works. Qt linuxfb will paint and the pixels will appear on screen. This is the expected Plan B configuration (no X11, no Weston, just bare framebuffer).

**Scenario 2 — EMGD X server is also running.**
Then EMGD claims exclusive access and Qt's `mmap()` writes will either be ignored, corrupted, or cause undefined behavior. Don't do this. Kill X (or, for Plan B, just never start it — `S30-weston` from the current init becomes `S30-q60nav` directly).

**Verify on hardware (one-shot test on rooted factory DCU):**
```sh
# After factory boot, drop to serial console
fbset                       # confirms /dev/fb0 exists, shows resolution
cat /proc/fb                # shows "0 EMGD" or similar
fuser /dev/fb0              # who owns it? if empty, free to mmap
# Test pattern:
dd if=/dev/urandom of=/dev/fb0 bs=1M count=4
# If screen turns to noise — you own the framebuffer. Linuxfb will work.
```

If Scenario 1 isn't true (EMGD refuses to release), fallback is `linuxfb:fb=/dev/fb1` if EMGD provides a secondary fb, or kernel-mode-set the i915 driver instead of EMGD (i915 in 2.6.37 supports KMS for GMA600 — slower but standard).

### A5. Headless OSMesa bridge (alternative, not recommended)

If linuxfb somehow doesn't work, the fallback would be:

1. Build Mesa 17.3.4 with `--enable-osmesa --enable-gallium-osmesa --with-gallium-drivers=swrast --disable-dri --disable-egl --disable-gbm --disable-glx`.
2. Write a custom Qt QPA plugin that renders into an OSMesa buffer (`OSMesaMakeCurrent` + `OSMesaCreateContextExt`), then `memcpy`s the result into `/dev/fb0`.
3. Result is functionally identical to linuxfb + software-backend but with an extra copy and a 30MB libGL chained in.

**Don't do this.** It's strictly worse than A2 unless someone wants GL for a specific component (e.g., MapLibre — and Plan A already handles MapLibre via EGL on EMGD, separately from Qt's rendering).

### A6. Decision

Use **Qt 5.15 linuxfb + `QT_QUICK_BACKEND=software`**. No Mesa build needed. One on-hardware verification (the `fuser /dev/fb0` test above) confirms the EMGD ownership question. If it fails, fall back to i915 KMS in the kernel, not OSMesa.

---

## Part B — DENSO IPC reverse-engineering plan

### B1. What we know from public sources

Confirmed by community RE (infinitiq50.org "InTouch Reverse Engineering Findings" thread, 2019–2024):

- DCU OS: **DENSO's GENIVI Linux fork**, kernel 2.6.37, GCC 4.5.1.
- SoC: **Intel Atom E6xx ("Crossville Lapis" — actually Tunnel Creek + Topcliff PCH)**.
- Root access: USB-TTL via patched systemd config.
- Window manager: Wayland-based (factory app on `weston`).
- AV CAN runs at 500 kbps, separate from powertrain CAN.
- The DCU bundles a multi-CAN architecture (`can0`/`can1`/`can2` confirmed by project's own findings).

**Not in any public source:**
- Wire protocol of `sxmcgs.cmd`, `radiofc.cmd`, `sound.cmd`, `vcan.cmd` pipes.
- Daemon source code (DENSO closed-source — not in Bosch/Nissan OSS disclosures).
- Any reverse-engineering of these specific daemons.

### B2. What the OSS bundles actually contain (verified)

The Bosch-hosted Nissan OSS portal (`oss.bosch-cm.com/list/nissan`) ships:
- D-series bundles (D2xx–D50x) — the older AIVI generation, includes 2014–2019 DCU vintage.
- F-series (F00x–F10x) — newer.
- A-IVI2 / P-IVI3 — current platforms (Gen4).

**They include:** GPL/MIT/BSD packages from the BSP — kernel source, glibc, busybox, GENIVI components (`node-startup-controller`, `dlt-daemon`, `weston`), DENSO-modified upstream packages.

**They do NOT include:** DENSO-proprietary daemons (`sxmcgs.out`, `radiofc.out`, `sound.out`, `vcan.out`, the factory navigation app, the Android compatibility layer). These are deliberately excluded — they're DENSO's IP.

Action: Download the D-series bundle that matches the project's `97.4002` firmware version anyway. It will provide kernel `.config` (useful for matching factory CAN driver options) and any open GENIVI IPC patterns DENSO inherited (DLT, common-api, persistence-client-library) that the proprietary daemons likely reuse.

### B3. Probable protocol shape (informed guess)

Based on DENSO's published `tmot` (Toyota Multi Operation Touch) and `aivi` bundles — same engineering org, same era — DENSO's house style for IPC over named pipes is:

- **Transport:** FIFO (`mkfifo /tmp/<name>.cmd`), one-way command pipe + matching `/tmp/<name>.rsp` response pipe.
- **Framing:** Newline-terminated ASCII strings. Some daemons use length-prefixed binary for media data, but control plane is text.
- **Format:** Space-separated tokens. First token = verb. Examples likely to work as probe inputs:
  - `radiofc`: `TUNE 89.7`, `MODE FM`, `MUTE 1`, `STATUS`
  - `sxmcgs`: `CHANNEL 8`, `STATUS`, `SIGNAL`, `SUBSCRIPTION`
  - `sound`: `SOURCE FM`, `VOL 18`, `MUTE 1`, `BALANCE 0 0`
  - `vcan`: `SEND can0 002 02 00 00 00 00 00 00 00`, `RECV can0`, `FILTER ADD 0x510`
- **Response:** `OK` / `ERR <code>` / data line, newline-terminated.

This is a **guess** based on patterns from DENSO's published code. It must be verified on hardware before any q60nav code is written against it.

### B4. The on-hardware capture plan (the actual deliverable for Plan B)

Once the project has UART/USB-TTL root on a factory DCU (Section 6 of `hardware-prep.md`), run this protocol-discovery script:

```sh
#!/bin/sh
# /tmp/denso-ipc-sniff.sh — capture DENSO IPC during normal use
set -e
mkdir -p /tmp/ipc-cap

# 1. Identify all named pipes and Unix sockets
ls -la /tmp/*.cmd /tmp/*.rsp /tmp/*.sock 2>/dev/null > /tmp/ipc-cap/00-inventory.txt

# 2. Identify each daemon's binary + open files
for d in sxmcgs radiofc sound vcan; do
  pid=$(pidof ${d}.out 2>/dev/null) || continue
  echo "=== $d (pid $pid) ===" >> /tmp/ipc-cap/01-daemons.txt
  ls -la /proc/$pid/exe >> /tmp/ipc-cap/01-daemons.txt
  cat  /proc/$pid/maps  > /tmp/ipc-cap/02-${d}-maps.txt
  ls -la /proc/$pid/fd  > /tmp/ipc-cap/03-${d}-fds.txt
  cat /proc/$pid/cmdline | tr '\0' ' ' >> /tmp/ipc-cap/01-daemons.txt
  echo "" >> /tmp/ipc-cap/01-daemons.txt
done

# 3. strace each daemon for 60s while operator exercises each function
#    (radio tune, SXM channel, volume change, source select, CAN read)
for d in sxmcgs radiofc sound vcan; do
  pid=$(pidof ${d}.out 2>/dev/null) || continue
  strace -ttf -s 512 -e trace=read,write,open,openat,connect \
    -p $pid -o /tmp/ipc-cap/strace-${d}.log &
done
echo "strace running for 5 minutes — exercise each function now"
sleep 300
killall strace

# 4. Tee the named pipes in parallel (so we get a clean wire log)
#    Note: tee'ing a FIFO can break the daemon — do this only if strace
#    fails to capture the data.
# for p in /tmp/*.cmd /tmp/*.rsp; do
#   cat "$p" | tee /tmp/ipc-cap/pipe-$(basename $p).log &
# done

tar czf /tmp/ipc-cap.tgz /tmp/ipc-cap/
echo "DONE — pull /tmp/ipc-cap.tgz off the unit"
```

What this produces:
- Inventory of all IPC endpoints (named pipes + Unix sockets the project may have missed).
- Daemon binaries, memory maps (for later objdump/Ghidra), open FDs (confirms which pipes each daemon reads/writes).
- strace logs showing the actual bytes written to/read from each pipe during real factory-app interaction. This is the wire protocol, full stop.

From the strace logs, a Python prober becomes trivial:

```python
import os, time
fifo = open('/tmp/radiofc.cmd', 'w', buffering=1)
resp = open('/tmp/radiofc.rsp', 'r', buffering=1)
fifo.write('STATUS\n'); fifo.flush()
print(resp.readline().strip())
```

### B5. Per-daemon expected scope

| Daemon | Pipe | Suspected commands | q60nav usage |
|---|---|---|---|
| `sxmcgs.out` | `/tmp/sxmcgs.cmd` + `.rsp` | `CHANNEL n`, `STATUS`, `SIGNAL`, `META`, `MUTE 0\|1`, `PRESET ADD n` | Replace XM tile in audio source view |
| `radiofc.out` | `/tmp/radiofc.cmd` + `.rsp` | `TUNE 89.7`, `BAND FM\|AM`, `SEEK UP\|DOWN`, `RDS`, `MUTE 0\|1`, `STATUS` | Replace FM/AM tile |
| `sound.out` | `/tmp/sound.cmd` + `.rsp` | `SOURCE FM\|AM\|SXM\|BT\|AUX\|NAV`, `VOL n` (0-30), `MUTE 0\|1`, `BALANCE l r`, `FADE f r`, `EQ BASS n` | Audio routing + volume |
| `vcan.out` | `/tmp/vcan.cmd` + `.rsp` | `SEND <bus> <id> <hex...>`, `RECV <bus>`, `FILTER ADD <id>`, `FILTER CLR`, `STATUS` | Main CAN access path (multi-bus) |

For `vcan.out` specifically: the daemon is a userspace abstraction over the kernel SocketCAN driver — its job is to multiplex the three buses (`can0` = powertrain, `can1` = chassis, `can2` = body/AV) and arbitrate ID-level write permissions so multiple apps don't collide on the same bus. Question to answer on hardware: does it accept raw frame writes, or only "high-level" commands like `HVAC_TEMP_SET 72`? If the former, q60nav can use it directly. If the latter, q60nav should bind SocketCAN raw and bypass `vcan.out` entirely (and pay the coordination tax of being the sole CAN writer).

### B6. Open questions for hardware day

1. Does `fuser /dev/fb0` come back empty under factory boot (Plan B linuxfb prerequisite)?
2. Do the named pipes exist at `/tmp/*.cmd` exactly, or under `/var/run/`?
3. Are there matching `.rsp` pipes, or is it a single bidirectional Unix socket per daemon?
4. Does the factory app have any "log" or "trace" runtime flag that prints the IPC traffic to stderr? (Look for `DLT_REGISTER_APP` in strace — DENSO uses DLT extensively.)
5. Does `vcan.out` accept raw frame writes, or only abstracted commands?

These are the five things to verify on the rooted DCU before Plan B coding starts.

---

## Sources

- [Mesa Off-screen Rendering / OSMesa](https://manu.pages.freedesktop.org/mesa/osmesa.html)
- [Mesa LLVMpipe driver](https://docs.mesa3d.org/drivers/llvmpipe.html)
- [Mesa 17.3.4 BLFS build guide](https://www.linuxfromscratch.org/blfs/view/8.2/x/mesa.html)
- [Qt 5.15 Embedded Linux (linuxfb)](https://doc.qt.io/archives/qt-5.15/embedded-linux.html)
- [Qt Quick Software adaptation](https://doc.qt.io/qt-6/qtquick-visualcanvas-adaptations.html)
- [Qt Quick 5.8 Graphics Stack blog (software renderer intro)](https://www.qt.io/blog/2016/08/15/the-qt-quick-graphics-stack-in-qt-5-8)
- [Intel EMGD framebuffer ownership discussion](https://community.intel.com/t5/Embedded-Intel-Atom-Processors/Access-to-Framebuffer-Device-on-EMGD/td-p/256984)
- [Bosch Nissan OSS portal](http://oss.bosch-cm.com/list/nissan)
- [DENSO Nissan OSS portal](https://www.denso.com/global/en/opensource/ivi/nissan/)
- [DENSO Toyota TMOT OSS portal](https://www.denso.com/global/en/opensource/ivi/tmot/)
- [InTouch Reverse Engineering thread (Q50 forum, root access)](https://www.infinitiq50.org/threads/intouch-reverse-engineering-findings-more-to-come.137236/)
- [SocketCAN kernel docs](https://docs.kernel.org/networking/can.html)
- [GENIVI Architecture overview](https://at.projects.genivi.org/wiki/display/GRK/Appendix+3+:+A+Look+at+GENIVI+Architecture)
