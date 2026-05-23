# Forensic — EMGD init sequence + DRM master lifecycle

Date: 2026-05-23
Source: extracted Slot A rootfs at `/tmp/dsu-slot-a/` + captured kernel logs at `/Volumes/boot/Q60_KMSG.LOG` + emgdhmid binary disassembly.

---

## Executive summary — what our app needs to land in

1. **Environment.** No `XDG_RUNTIME_DIR`, `XAUTHORITY`, or `DISPLAY` are required. emgdhmid runs as a plain daemon. The only env knob that matters for our EGL stack is **`LD_LIBRARY_PATH=/home/naviwork/system/bin:/home/naviwork/system/lib:/home/naviwork/system/out:/usr/lib:/usr/local/lib:/usr/`** (copy from `/lib/systemd/system/abs_clock.service`). Ld.so already adds `/usr/lib/wsegl` via `/etc/ld.so.conf.d/emgdhmi.conf`. No `EMGD_*` / `PVR_*` env vars are required at runtime; the only ones emgdhmid reads are `EMGDHMI_FAKE_NAVI_VIDEO`, `EMGDHMI_USE_CONSTANT_BUFFERS`, `EMGDHMI_DUMP_CONSTANT_BUFFERS` (all debug knobs, leave unset).

2. **File paths to know.** `/dev/dri/card0` (DRM node, minor 0), `/dev/video0` (IOH VIN — V4L2 capture path), `/dev/v2gbridge` (V2G ioctl interface), `/tmp/.emgdhmid_socket` (broker AF_UNIX socket — clients talk here). EMGD libs at `/usr/lib/libemgd*` + WSEGL backend at `/usr/lib/wsegl/libwsegl-hmi.so` (factory) and `/usr/lib/wsegl/libemgdPVR2D_DRIWSEGL.so` (X11 client — not used by nav daemons).

3. **DRM master is FREE for the taking after Sprite C enable.** **emgdhmid is NOT a persistent DRM master.** Disassembly proves it calls `drmDropMaster(fd)` IMMEDIATELY after `drmOpen("emgd","PCI:00:02:00")`, then only briefly re-grabs master (`SetMaster → ioctl → DropMaster`) for individual privileged ioctls (`CONFIG_BUFFS` cmd=0x2c, `SWITCH_HZ` cmd=0x25). Master is unowned almost all the time. Confirmed by `Q60_DRM.LOG`: `DRM_SET_MASTER → r=0` succeeded with hmictrl_proc/navi_ps/display_ps/dispapf_proc SIGSTOP'd. Our app's `drmSetMaster()` will succeed if no other process is currently mid-ioctl.

4. **Boot timing window.** Kernel emgd init at **t=0.48s**. emgdhmid Overlay bridge enable at **t≈7.0s**. emgdhmid Sprite C bridge enable at **t≈16.3s**. Our hook (`( sleep 3; sh /opt/q60r1/run.sh ) &` from `late-services.timer` at `OnStartupSec=13s`) fires at **t≈16s — right in the middle of Sprite C bringup**. Recommend bumping our sleep to 5–7s so we land at t≈18–20s, AFTER emgdhmid's last configure-master cycle.

5. **Kernel cmdline.** Factory append (from `/etc/ivi.versions`): `ro quiet rootwait lpj=1296800 android androidboot.console=tty1 androidroot=/dev/mmcblk0p5 pmemdisk=/dev/mmcblk0p7 memmap=2M$52M memmap=10M$54M panic=1 priority_khubd=98 priority_ehciwork=44,R idle=halt ehci_hcd.log2_irq_thresh=2 mem=1G`. **No `emgd.configid=`, no `emgd.dc=`, no `video=`, no `nomodeset`.** EMGD config is hard-baked into Wind River's emgd.ko build (compile-time defaults). We never need to set those values — emgd.ko picks them up itself.

---

## 1. EMGD modprobe config — there is none

**Files searched:** `/tmp/dsu-slot-a/etc/modprobe.d/` contains only `blacklist.conf` and `dist.conf`. **No `emgd.conf` exists.** No `xorg.conf*`, no PCF files, no `options emgd ...` lines anywhere in `/etc`.

**Reason:** emgd.ko and v2g_bridge.ko are **kernel-built-in** (in `/tmp/dsu-slot-a/lib/modules/2.6.37.6-35.1_DLK0040-android-intel-crossville_lapis-fastboot/modules.builtin`):
```
kernel/drivers/misc/v2g_bridge.ko
kernel/drivers/staging/emgd/emgd.ko
```
Built-in modules can only take parameters via the kernel command line as `emgd.configid=N emgd.dc=M`. The factory cmdline carries **neither**. Therefore `configid` and `dc` come from Wind River's compiled-in defaults baked into emgd.ko at build time.

**Implication for Plan B'''.** Prior plans assumed we'd parse `/etc/modprobe.d/emgd.conf` to feed the same configid/dc into Weston. That doc doesn't exist. The right pattern is: **leave emgd.ko built into the factory kernel as-is**, our Linux 4.19 + gma500 path supersedes it entirely. We do **not** need to replicate EMGD configid for our own kernel.

Documented runtime portorder (from prior R1 probe): `portorder = 2,4,0,0,0` → port 2 = LVDS (upper 7" 800×480), port 4 = SDVO (lower 800×420). This is compiled into emgd.ko, not from a config file.

---

## 2. emgdhmid forensic

- **Path:** `/tmp/dsu-slot-a/usr/sbin/emgdhmid`
- **Size:** 57,708 bytes
- **Type:** ELF 32-bit LSB i386, dynamic, not stripped, BuildID `55ca175f...562f`, built `Mar 21 2013` with GCC 4.5.1
- **NEEDED libs:** `libEMGD2d.so`, `libemgdsrv_init.so`, `libemgdsrv_um.so`, `libdrm.so.2`, libpthread, libstdc++, libm, libgcc_s, libc
- **Symbols of interest:** `drmOpen`, `drmSetMaster`, `drmDropMaster`, `drmCommandWriteRead`, `drmClose`, `PVR2D*`, `SrvInit` (from libemgdsrv_init)

**What it actually does — main() lifecycle:**
1. `pipe()` → `fork()` → child path: `chdir("/")`, `setsid()` (daemonize)
2. Construct `EmgdHmiDaemon` — calls `initDRM()`:
   - `drmOpen("emgd", "PCI:00:02:00")` → returns fd
   - **`drmDropMaster(fd)` immediately** (releases master inherited from first-open)
   - `drmcmd_master(0x2c, ...)` → CONFIG_BUFFS (size 0x250) — does `SetMaster → drmCommandWriteRead → DropMaster`
   - `drmcmd_master(0x25, ...)` → SWITCH_HZ — same pattern
   - `SrvInit()` (PVR services init)
   - `getDisplayHandle()` per pipe
3. Construct `EmgdHmiDaemonSocket` → `Init()` (creates `/tmp/.emgdhmid_socket`)
4. Loop: `DoMsg()` — read client requests, dispatch (`SwitchHz`, `QueryPixmap`, `GetNumScreens`, `CreatePixmap`, `DestroyPixmap`, `RequestFlip`, `StartVideo`, `StopVideo`, etc.)

**Master usage count in the binary:**
- `drmSetMaster@plt` — called **1 site** inside `drmcmd_master` helper
- `drmDropMaster@plt` — called **2 sites**: once in `initDRM` immediately after drmOpen, once in `drmcmd_master` after the ioctl
- `drmOpen@plt` — called **1 site**, in `initDRM`
- `drmGetMagic` / `drmAuthMagic` — **not present**. emgdhmid does not perform AUTH-token handshaking on behalf of clients.

**Disassembly of `EmgdHmiDaemon::drmcmd_master` (offset 0x0804aa90):**
```
drmSetMaster(fd)            ; if r != 0 → log + return
drmCommandWriteRead(fd, ...) ; do the ioctl
drmDropMaster(fd)            ; if r != 0 → log + return
return r=0
```

**Disassembly of `EmgdHmiDaemon::initDRM` (offset 0x0804ac70):**
```
drmOpen("emgd","PCI:00:02:00") → edi (fd)
drmDropMaster(edi)            ; first thing after open
drmcmd_master(this, 0x2c, &buf, 0x250)   ; CONFIG_BUFFS
drmcmd_master(this, 0x25, &buf2, 0x8)    ; SWITCH_HZ
SrvInit()
getDisplayHandle(0) → this->screen[0].handle
if (dc != 1) getDisplayHandle(1) → this->screen[1].handle
```

**Strings worth noting:**
- `"/etc/emgdhmid-screens"` — config file path that emgdhmid reads at startup. **The file is NOT present in slot A** — likely written at runtime by `nav_init` or pulled from `/home/naviwork`. If our app needs to emulate emgdhmid, we'd need to know this format. Recommend deferring.
- `"EMGDHMI_FAKE_NAVI_VIDEO"`, `"EMGDHMI_USE_CONSTANT_BUFFERS"`, `"EMGDHMI_DUMP_CONSTANT_BUFFERS"` — debug env knobs
- `"DRM cmd %d failure: %d"`, `"drmcmd %d returned %d"`, `"DRM_IOCTL_IGD_CONFIG_BUFFS ioctl() failed"`, `"DRM_IOCTL_IGD_SWITCH_HZ ioctl() failed"` — error format strings
- `"V2G_DISABLE_BRIDGE ioctl failure"`, `"Enable Bridge ioctl returned error"`, `"/dev/v2gbridge"`, `"/dev/video0"`

---

## 3. Init sequence — who touches /dev/dri/card0 in what order

### Kernel-level
- **t=0.000**: kernel boot
- **t=0.165**: `[drm] Initialized drm 1.1.0 20060810` — DRM core
- **t=0.478**: `[drm] Initialized emgd 1.0.0 20100723 for 0000:00:02.0 on minor 0` — emgd registered, `/dev/dri/card0` created (built-in emgd.ko)
- **t=0.478**: `[EMGD] drm_init() returning 0` — driver init complete

### Systemd-level (from log timestamps + unit ordering)
- **t≈0.75s**: systemd-modules-load runs (loads `ohci_hcd`, `setgpio`, `watchdog`, `bt_hci`, `cdc_tcu`, `capture_ctl`, `net_adp` from `/etc/modules-load.d/modules.conf`)
- **t≈3-5s**: `basic.target` reached → `emgdhmid.service` (in `basic.target.wants/`) starts
- **t=6.995**: `v2g: Enable Overlay Bridge on screen 1779026867` — emgdhmid's first overlay configure (looks like a screen-id encoded as YUYV or similar fourcc)
- **t≈13s**: `late-services.timer` fires → `late-services.target` activates → `android-mount.service`, `sud-change-elilo.service`
- **t≈16s**: `android-mount.sh` runs (patched on hardware to fire our hook 3 seconds later)
- **t=16.303**: `v2g: Enable Sprite C Bridge on screen 0` — emgdhmid configures real factory render path
- **graphical.target** reached → `nav_smng.service` starts (the supervisor process at `/home/naviwork/system/bin/smng "PS_OS01"`)
- smng forks/execs the 4 UI daemons (`display_ps`, `hmictrl_proc`, `navi_ps`, `camera_ps`, `dispapf_proc`) — they're not direct systemd units but managed by smng. nav_pre.target activates as a dep when those units are requested.

### Who actually opens /dev/dri/card0
1. **emgdhmid** (first open → inherits master implicitly → immediately drops it via `drmDropMaster`)
2. **display_ps / hmictrl_proc / navi_ps** — open card0 as authenticated clients via libemgdhmi.so (the daemon proxies privileged ops, clients themselves don't hold master)
3. Anyone else (our R1 probe) opens normally → eligible to call `drmSetMaster` if master slot is free

### What grants DRM_AUTH
From `r1-privilege-findings.md`: `DRM_IOCTL_IGD_ALTER_OVL2` and `DRM_IOCTL_IGD_APPCTX_ALLOC` need `DRM_AUTH` (not MASTER). The factory clients become AUTH via:
- A client opens /dev/dri/card0
- Calls `drmGetMagic(fd)` → kernel returns a per-fd cookie
- IPCs the cookie to whoever holds master (probably emgdhmid? **or maybe X server — but there's no X server here**)
- Master calls `drmAuthMagic(masterfd, cookie)` → cookie is now authenticated

**However:** emgdhmid has NO `drmGetMagic` / `drmAuthMagic` symbols. So how do the factory clients get AUTH?

Hypothesis: emgdhmid briefly re-grabs master for any single client-requested ioctl that needs MASTER (via `drmcmd_master`), and **clients route those ioctls through emgdhmid via the socket** rather than running them directly. The `EmgdHmiDaemonSocket::*` methods (SwitchHz, ConfigureBuffers, RequestFlip, StartVideo) are exactly that proxy. Clients never need AUTH for AUTH-only ioctls because **they don't call those ioctls directly either** — they go through emgdhmid socket, which is master at the moment of the call.

**Confirmed via our Q60_DRM_PROBE.LOG:** With factory UI daemons SIGSTOP'd, we successfully called `DRM_GET_MAGIC` (got magic=0x2) and `DRM_IGD_GMM_ALLOC_REGION` (r=0) — both as root after `DRM_SET_MASTER` succeeded. So the AUTH dance is irrelevant if WE become master.

---

## 4. Required environment variables

**From the rootfs:**
- `/etc/ld.so.conf.d/emgdhmi.conf` adds **`/usr/lib/wsegl`** to default search paths — EGL clients find `libwsegl-hmi.so` automatically.
- `emgdhmid.service` `Environment=` section is **empty** (just `Group=video`, `UMask=0002`). No env exports.
- `abs_clock.service` sets the canonical naviwork search path:
  ```
  LD_LIBRARY_PATH=/home/naviwork/system/bin:/home/naviwork/system/lib:/home/naviwork/system/out:/usr/lib:/usr/local/lib:/usr/
  ```
  Other nav daemons (display_ps, hmictrl_proc, navi_ps, etc.) get this via smng-supervised inheritance.

**From `libemgdsrv_um.so` strings:** the only env var read is `EMGDPVR_%s_%s` — formatted at runtime for per-app debug overrides. Safe to leave unset.

**No XDG_RUNTIME_DIR, no XAUTHORITY, no DISPLAY.** This system is not running X. The factory render path is:
```
client app → libGLES* → libEGL → libEMGDegl → libemgdsrv_um → /dev/pvrsrvkm (PVRSRV ioctl)
client app → wsegl-hmi → libemgdhmi → socket(/tmp/.emgdhmid_socket) → emgdhmid → DRM/V2G
```

For **our** Qt6/Weston/eglfs stack against the **factory** EMGD libs (Plan B'''):
- Required: `LD_LIBRARY_PATH=/usr/lib:/usr/lib/wsegl` plus any naviwork dirs if we want compatibility with shared dynamic libs.
- Required (for eglfs): `QT_QPA_PLATFORM=eglfs`, `QT_QPA_EGLFS_INTEGRATION=eglfs_emu` (or a custom plugin). EGLFS reads `/dev/dri/card0` directly via libgbm or libdrm.
- Not required: X env vars, weston_socket env, ivi_application id.

---

## 5. DRM master lifecycle — verified

| Process | drmOpen | drmSetMaster (calls/sites) | drmDropMaster | drmGetMagic | drmAuthMagic | Holds master persistently? |
|---|---|---|---|---|---|---|
| emgdhmid | 1× | 1× (per drmcmd_master invocation) | 2× (once in initDRM, once in drmcmd_master after every ioctl) | NO | NO | **NO — drops immediately after open and after every ioctl** |
| display_ps / hmictrl_proc / navi_ps | unknown (not extractable from slot A) | likely 0× (use proxy via libemgdhmi → socket) | n/a | likely yes | likely no | unknown |
| camera_ps | uses `/dev/v2gbridge` not master | n/a | n/a | n/a | n/a | NO |

**Race window:** Master is granted on first-open semantics in DRM — whichever process first opens `/dev/dri/card0` becomes master implicitly. emgdhmid is first to open (it's in `basic.target.wants/`), so it briefly held master at t≈5-7s, then dropped it. After that, master is **unowned**. Any subsequent `drmSetMaster()` call by root succeeds.

**Risk: emgdhmid's transient SetMaster windows.** If our code is mid-`drmSetMaster` at the exact instant emgdhmid is also doing `drmSetMaster` (during a configure ioctl), one of us gets EACCES. emgdhmid does this on every `SwitchHz` and `ConfigureBuffers` ioctl from clients. After initial bringup (~t=16.3s), these calls are rare. **Mitigation:** retry `drmSetMaster` 3 times with 50ms backoff before giving up.

**Confirmed from `Q60_DRM_PROBE.LOG`** (when we SIGSTOP'd the 4 nav daemons):
```
open /dev/dri/card0 → fd=5
DRM_SET_MASTER → r=0 errno=0
DRM_IGD_GMM_ALLOC_REGION: OK (r=0) — offset=0x0 size=1536000
DRM_GET_MAGIC: OK (r=0) — magic=0x2
```

This proves the chain works end-to-end. With factory daemons SIGSTOP'd, we get master, can alloc GMM regions, and the kernel grants us a magic cookie. **Plan B''' is on solid ground.**

---

## 6. Boot-time delay sources

### Confirmed
- **`/lib/systemd/system/nav_dmsg_start.service`** — `ExecStartPre=/bin/usleep 75000000` (75s sleep). Service runs in nav_pre.target.wants, no After= chain on display, so it does NOT gate display bringup. It's just a dmesg-capture script that delays its own capture window by 75 seconds. Other nav services proceed in parallel.

### Other delays
- **`late-services.timer`** — `OnStartupSec=13s` gates android-mount and sud-change-elilo. This **is the timing anchor for our hook**.
- **`emgdhmi-test.service`** — `ExecStartPre=/bin/usleep 20000` (20 ms — trivial).
- No other `usleep`/`sleep` in any systemd unit that gates display.

### Display-affecting After= chains
- `emgdhmid.service`: `DefaultDependencies=yes` → After=sysinit.target, basic.target. Starts very early.
- `nav_smng.service`: `After=home-naviwork-tmp.mount nav_init.service emgdhmid.service home-naviwork-data-pdm-ram.automount nav_before.service`. Waits for emgdhmid + naviwork mount + nav_before + nav_init.
- `nav_initialscreen.service` (fis_ps): `After=emgdhmid.service Wants=emgdhmid.service Requires=nav_pre.target`.
- `nav_display.service`, `nav_hmictrl.service`, etc.: `Requires=nav_pre.target` (no explicit After=emgdhmid, but nav_pre depends on emgdhmid indirectly).

No watchdog ramp delays in the diagnostic init. Factory: `/etc/modules-load.d/modules.conf` loads `watchdog` (LAPIS bsp module) very early; it doesn't introduce delays.

---

## 7. Our hook timing at t=3s after late-services.timer

`/sbin/android-mount.sh` is patched on hardware to fire `( sleep 3; sh /opt/q60r1/run.sh ) &`. `late-services.timer` is `OnStartupSec=13s`. So our hook executes at **~t=13s + epsilon + 3s ≈ t=16-17s** after systemd start.

State at t=16s (extracted from `Q60_KMSG.LOG`):

| Component | State at t=16s |
|---|---|
| emgd.ko | Loaded since t=0.478s |
| `/dev/dri/card0` | Exists since t=0.478s, accessible (mode 660, group=video via udev rule) |
| emgdhmid | Running since ~t=5-7s (basic.target.wants). Has done initDRM + Overlay bridge enable. Is right now in `DoMsg` socket loop or about to enable Sprite C bridge (t=16.303s log entry). |
| display_ps / hmictrl_proc / navi_ps | **Likely starting — smng spawns them after nav_pre.target activates.** Not yet attached to displays. |
| dispapf_proc / camera_ps | Same as above. |
| Master holder | **None — emgdhmid dropped it. No one holds master.** |

**Recommendation:** Bump our `sleep 3` to `sleep 7` so we fire at **t≈20s** — AFTER emgdhmid completes its Sprite C configure, and AFTER the nav daemons have done their initial setup. At t=20s the system is settled and master is reliably available.

---

## 8. DRM master takeover plan — exact sequence

For our app to take master cleanly and bring up EGL via the factory EMGD path:

```c
// 1. Open card with read/write
int fd = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
if (fd < 0) { perror("open card0"); exit(1); }

// 2. Become master — retry on EACCES (transient if emgdhmid is mid-ioctl)
for (int i = 0; i < 5; ++i) {
    int r = ioctl(fd, DRM_IOCTL_SET_MASTER, 0);
    if (r == 0) break;
    if (errno != EACCES && errno != EBUSY) { perror("set master"); exit(1); }
    usleep(50000); // 50ms backoff
}

// 3. (Optional) drmDropMaster() if we only need master for setup, not steady-state.
//    emgdhmid does this pattern; we don't have to copy it. Keeping master is fine
//    if no other process needs to configure modes.

// 4. EGL init — via factory libs
EGLDisplay dpy = eglGetDisplay(EGL_DEFAULT_DISPLAY);
// EGL_DEFAULT_DISPLAY routes through libEMGDegl → libemgdsrv_um → PVR services.
// PVR services open /dev/pvrsrvkm independently — no DRM master required for that path.
eglInitialize(dpy, NULL, NULL);
// ... rest of EGL setup
```

**Will `drmSetMaster` fail because emgdhmid is master?** No — emgdhmid drops master immediately after opening and after each privileged ioctl. The only EACCES window is the ~milliseconds during a `drmcmd_master` re-grab. Retry handles it.

**Cross-ref against R1 findings:**
- `r1-privilege-findings.md` lists DRM_MASTER-gated ioctls: `GMM_ALLOC_REGION`, `GMM_ALLOC_SURFACE`, `ALTER_OVL`. These all need master. Our `drmSetMaster` lets us call all of them.
- `v2gbridge-hardware-findings-2026-05-17.md` notes `ALTER_OVL2` was downgraded to AUTH-only. With master held we satisfy both gates.

**Should we coexist with emgdhmid or replace it?**
- **Plan B''' (current direction):** Replace it. Disable `emgdhmid.service` + the 4 UI daemons. Our app + Weston run instead. We take master and keep it. No socket-based AUTH negotiation needed. **Recommended.**
- **Coexist (alternative):** Leave emgdhmid running. Our app takes master only when needed (for GMM alloc), then drops. Risk: emgdhmid's parallel attempts at `drmcmd_master` can EACCES. More complex.

---

## 9. fbdev fallback availability

Kernel log: `Console: colour dummy device 80x25` + `console [tty0] enabled`. **No fbdev console.** Factory kernel boot does NOT register a `/dev/fb0` — emgd.ko is built without `CONFIG_DRM_FBDEV_EMULATION`, and `fbcon.ko` is a separate module that isn't auto-loaded.

`fbset` utility is **not present** in `/tmp/dsu-slot-a/usr/bin` or `/usr/sbin`. No `/etc/fb.modes` exists.

`fbcon.ko` IS available at `/tmp/dsu-slot-a/lib/modules/.../kernel/drivers/video/console/fbcon.ko` but is not loaded by default.

**Implication:** Under the **factory 2.6.37 kernel**, there is NO /dev/fb0 to fall back to. DRM is the only graphics path.

Under our **Linux 4.19 kernel** (`output/bzImage-4.19-q60`), we have `CONFIG_DRM_GMA500=y` + GMA600. gma500 in 4.19 supports both DRM modeset AND fbdev emulation (CONFIG_DRM_FBDEV_EMULATION=y if set in our config). This needs to be verified separately in the Phase 1 boot — out of scope here.

---

## 10. EFI / kernel cmdline that affects display

From `/Volumes/boot/elilo.conf` (factory `logan1` entry) and `/tmp/dsu-slot-a/etc/ivi.versions`:

```
ro quiet rootwait lpj=1296800 android androidboot.console=tty1
androidroot=/dev/mmcblk0p5 pmemdisk=/dev/mmcblk0p7
memmap=2M$52M memmap=10M$54M
panic=1 priority_khubd=98 priority_ehciwork=44,R
idle=halt ehci_hcd.log2_irq_thresh=2 mem=1G
```

Display-relevant parameters present:
- `quiet` — suppresses kernel printk (no console spam on attached console)
- `androidboot.console=tty1` — Android logd uses tty1, not display-affecting
- `memmap=2M$52M memmap=10M$54M` — reserves 2 MB at 52 MB offset, 10 MB at 54 MB offset. Likely SGX firmware / GTT scratch reservation, NOT shared with EMGD framebuffer (which uses GTT at higher addresses).
- `mem=1G` — caps RAM at 1 GB (physical is 2 GB; the other 1 GB is used by EMGD GTT pool + Android system partition layout)

Display-relevant parameters **NOT present** (which would be problematic if they were):
- `nomodeset` — absent ✓ (modeset enabled)
- `video=` — absent ✓ (no override)
- `vga=` — absent ✓
- `consoleblank=` — absent ✓ (default ~10 min screen blank)
- `i915.*` — absent ✓ (i915 not loaded)
- `fbcon=` — absent ✓

**Our app inherits this cmdline if we run under the factory kernel.** Nothing in it blocks our DRM master takeover.

---

## Appendix A — Recommended deploy timing tuning

Current hook in `android-mount.sh`:
```bash
( sleep 3; sh /opt/q60r1/run.sh ) &
```

Recommend changing to:
```bash
( sleep 7; sh /opt/q60r1/run.sh ) &
```

This shifts our fire time from t≈16-17s (during Sprite C configure) to t≈20-21s (after configure completes, before factory app fully attaches). Reduces EACCES retry pressure.

If even that's not enough, gate on actual hardware state instead:
```bash
( while ! grep -q "Sprite C Bridge" /var/log/dmesg 2>/dev/null && ! dmesg | grep -q "Sprite C Bridge"; do
    sleep 0.5
  done
  sleep 1
  sh /opt/q60r1/run.sh ) &
```

But the simple `sleep 7` is probably good enough.

---

## Appendix B — Files inventoried under /tmp/dsu-slot-a relevant to EMGD

| Path | Size | Role |
|---|---|---|
| `/usr/sbin/emgdhmid` | 57708 | DRM master broker daemon |
| `/usr/lib/libemgdhmi.so.0.1.0` | n/a | Client-side IPC lib (talks to emgdhmid socket) |
| `/usr/lib/libEGL.so.1.5.15.3226` | n/a | EMGD's EGL implementation (calls libEMGDegl) |
| `/usr/lib/libEMGDegl.so.1.5.15.3226` | n/a | EGL backend |
| `/usr/lib/libEMGD2d.so.1.5.15.3226` | n/a | 2D blit helper |
| `/usr/lib/libemgdsrv_init.so.1.5.15.3226` | n/a | PVRSRV bringup |
| `/usr/lib/libemgdsrv_um.so.1.5.15.3226` | n/a | PVR services userland |
| `/usr/lib/libemgdPVR2D_DRIWSEGL.so.1.5.15.3226` | n/a | X11/DRI2 WSEGL (NOT used in factory) |
| `/usr/lib/libemgdglslcompiler.so.1.5.15.3226` | n/a | GLSL compiler |
| `/usr/lib/libGLES_CM.so.1.5.15.3226` | n/a | OpenGL ES 1.1 |
| `/usr/lib/libGLESv2.so.1.5.15.3226` | n/a | OpenGL ES 2.0 |
| `/usr/lib/wsegl/libwsegl-hmi.so` | n/a | **HMI WSEGL — factory's actual EGL backend.** Talks to emgdhmid. |
| `/etc/ld.so.conf.d/emgdhmi.conf` | 13 | Adds `/usr/lib/wsegl` to default ld.so path |
| `/lib/systemd/system/emgdhmid.service` | n/a | systemd unit (basic.target.wants) |
| `/lib/systemd/system/emgdhmi-test.service` | n/a | optional emgdhmitest (used during bringup tests, requires emgdhmid) |
| `/etc/modules-load.d/modules.conf` | n/a | Lists early-load modules (emgd is built-in, not here) |
| `/lib/modules/.../modules.builtin` | n/a | Confirms emgd.ko + v2g_bridge.ko are built-in |
| `/etc/ivi.versions` | n/a | Contains the elilo append= line for reference |
| `/sbin/android-mount.sh` | n/a | Our hook injection point (after rcS patch via debugfs) |

---

## Appendix C — Open questions for next probe

1. **What is `/etc/emgdhmid-screens` format?** emgdhmid reads it via `getline()` (basic_ifstream) on startup. Not present in slot A — likely written at runtime by `nav_init` or mounted from `/home/naviwork`. We'd need to capture this on running hardware via `find / -name emgdhmid-screens` or `lsof -p $(pgrep emgdhmid)` to see what files it has open. Format string `"screen %d %d x %d @ %d, %d"` suggests `screen <idx> <w> x <h> @ <pipe>, <port>` lines.
2. **Does `drmGetMagic` returning `magic=0x2` (low number) indicate the kernel is fresh and we are only the 2nd authentication request?** If yes, this confirms emgdhmid did not consume an auth slot (its DropMaster immediately means it never called GetMagic on itself).
3. **What does `nav_initialscreen.service` (fis_ps) actually do?** It's listed first in `nav_pre.target.wants` and `After=emgdhmid.service` — possibly the actual first-frame painter. Binary is at `/home/naviwork/system/bin/fis_ps` (not in slot A).
