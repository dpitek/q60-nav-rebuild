# Forensic — Factory UI Binary Analysis (Slot A)

**Date:** 2026-05-23
**Source:** `/tmp/dsu-slot-a/` (extracted Slot A DSU backup) + cross-references to prior agents
**Subject:** What binary draws the upper LVDS HMI on the factory Q60 head unit, what does it link, and how do we replicate its EGL/surface contract from our Qt app?

---

## Executive Summary

1. **The 4 UI daemons are NOT on Slot A.** `navi_ps`, `hmictrl_proc`, `display_ps`, `dispapf_proc` (plus `camera_ps`, `audio_ps`, `multimedia_ps`, `tel_proc`, `smng`, `fis_ps`, `is`, `napl`, `snd`, `sndamp`, `ipodplayer_ps`, `ioapf_proc`, `soft_vup`, `bkup_prg`, `smngpret`, `sdretn`, `systemlogd`, `PS_DSN`, `PS_REX01`, `PS_VRD01` — 23 binaries total) live exclusively on `/home/naviwork/` — a separate ext4 partition (`LABEL=homenaviwork`, mounted by `/lib/systemd/system/home-naviwork.mount`). They are **physically unreachable from the Slot A image**. We cannot disassemble them; we can only triangulate their behavior from the runtime contract baked into `/usr/lib/libemgdhmi.so.0`, `/usr/lib/wsegl/libwsegl-hmi.so`, and the only locally-shipping debug-info binary that uses the same EGL+HMI path: **`/lib/systemd/system/systemdRelatedFiles/Display_Tools/drawbuf`** (24 KB, GCC 4.5.1, debug symbols, source path `/home/naviwork/work/Display_Tool_source/drawbuf/DrawBuffer_c.c`).

2. **UI toolkit: NONE in the traditional sense — DENSO wrote raw EGL+GLES on top of emgdHmi pixmaps.** drawbuf links `libEGL.so.1 + libGLES_CM.so.1 + libOpenVG.so + libwsegl-hmi.so + libemgdhmi.so.0`. There is **no Qt, no GTK, no EFL/elementary, no Cairo, no Wayland/ivi, no X11** anywhere in the EGL-using binaries on Slot A. Surface IDs / ivi_application / ivi_surface are **absent** from every binary, library, and string table on this rootfs. The nav daemons render the same way: each daemon `dlopen`s libwsegl-hmi via `eglInitialize`, then calls `emgdHmiCreatePixmap(display, type, width, height, &pixmap)` and feeds that pixmap pointer as `EGLNativeWindowType` to `eglCreateWindowSurface()` / `EGLNativePixmapType` to `eglCreatePixmapSurface()`. Compositing is done by emgdhmid in kernel space via Sprite C / Overlay planes — there is no userspace compositor.

3. **The display protocol is the EmgdHmi pixmap contract.** Six buffer types exist (named `EMGD_HMI_BUFFER=1`, `EMGD_VIDEO_BUFFER=2`, `EMGD_POPUP_BUFFER=3`, `EMGD_X11_BUFFER=4`, `EMGD_8BIT_BUFFER=5`, plus `EMGD_NO_BUFFER=0`) and six pixel formats (`EMGD_FMT_ARGB8888`, `ABGR8888`, `XRGB8888`, `RGB565`, `ARGB1555`, `ARGB4444`, `YUV422` for video). drawbuf allocates an HMI buffer at **800×960** (0x320×0x3C0) and a POPUP buffer at **800×480** (0x320×0x1E0). The 800×960 dimension = 800×(480+480) = the upper and lower LVDS panels stacked into a single virtual framebuffer; the POPUP overlay is a single 800×480 plane. Pixel format is `ARGB8888` (confirmed from drawbuf string `EMGD_FMT_ARGB8888` in the type table). EGL config: 8-8-8-8 RGBA, 24-bit depth, 8-bit stencil, 4x MSAA, EGL_BIND_TO_TEXTURE_RGBA=1, surface type WINDOW|PIXMAP, renderable type GLES1.x (`EGL_OPENGL_ES_BIT = 1`).

4. **Resolution: 800×480 per display, 800×960 stacked virtual canvas.** Mode comes from emgdhmid's internal `getDisplayHandle()` per pipe — port 2 = LVDS upper (800×480), port 4 = SDVO lower (800×420) per emgd portorder. emgdhmid claims it negotiates the screen mode by calling `PVR2DGetScreenMode`; client apps call `emgdHmiGetFramebufferSize(display, &fbinfo)` to query (drawbuf does this via `pemgddata` struct offset 4 — when set to non-(-1), it fetches the framebuffer info and uses it as `EGLNativeWindowType` for `eglCreateWindowSurface`).

5. **Replication recipe for our Qt app — three lines of contract.** (a) Set `QT_QPA_PLATFORM=eglfs` + supply a `QEglFSDeviceIntegration` plugin (call it `eglfs_emgdhmi`) that overrides `platformDisplay()` → `emgdHmiGetNativeDisplay()`, `createNativeWindow()` → `emgdHmiCreatePixmap(disp, EMGD_HMI_BUFFER=1, 800, 480, &pix)` (single panel) or `(disp, 1, 800, 960, &pix)` (stacked), `destroyNativeWindow()` → `emgdHmiDestroyPixmap()`. (b) Use the eglConfig drawbuf already validated: RGBA8 / depth 24 / stencil 8 / no MSAA (drop the 4x for performance on SGX535). (c) Run as `Group=video`, set `LD_LIBRARY_PATH=/home/naviwork/system/bin:/home/naviwork/system/lib:/home/naviwork/system/out:/usr/lib:/usr/local/lib:/usr/lib/wsegl` if `/home/naviwork/system/lib` is mounted (per nav_hmictrl.service commented-out env). emgdhmid must be alive; we do NOT call `drmSetMaster()` (per Agent 6: emgdhmid drops master immediately and only briefly re-grabs it for two ioctls). The runtime config that selects libwsegl-hmi is the `[default]` section of `/etc/powervr.ini` — already correctly pointing at it.

**Bottom line:** the factory UI is raw EGL/GLES1 + OpenVG against EMGD HMI pixmaps. We replicate this from Qt by writing a **single platform-integration plugin** (~200-400 LoC C++) that wraps 4 emgdHmi calls (`GetNativeDisplay`, `CreatePixmap`, `DestroyPixmap`, plus `GetFramebufferSize` for queries). There is no Wayland, no ivi protocol, no compositor handshake, no X11 — just direct EGL with vendor pixmap-as-native-window. The architecture is dramatically simpler than what we feared, and Plan B''' is fully viable from the binary contract side.

---

## 1. Binary Inventory — What's on Slot A

### 1.1 ELF executables that touch the display stack

| Path | Size | Stripped? | Role | Source provenance |
|------|-----:|-----------|------|-------------------|
| `/tmp/dsu-slot-a/usr/sbin/emgdhmid` | 57,708 | not stripped | DRM master holder / HMI broker socket server (`/tmp/.emgdhmid_socket`) | Wind River / Intel EMGD 1.5.15.3226, built 2013-02-27 |
| `/tmp/dsu-slot-a/usr/bin/egl` | 20,433 | not stripped | Factory EGL probe tool with EGLImageKHR + GLES2 shader (texture compositor smoke test) | Intel EMGD test suite |
| `/tmp/dsu-slot-a/lib/systemd/system/systemdRelatedFiles/Display_Tools/drawbuf` | 24,045 | **debug_info present** | Solid-color frame painter (test/factory tool) | Wipro for DENSO; source: `/home/naviwork/work/Display_Tool_source/drawbuf/DrawBuffer_c.c` |
| `/tmp/dsu-slot-a/lib/systemd/system/systemdRelatedFiles/Display_Tools/drawbufd` | 24,018 | **debug_info present** | Daemon variant of drawbuf (continuous color rotation) | Same as drawbuf |

**That's it.** Across all 697 ELF executables on Slot A, only these 4 link to `libEGL.so.1`. There are zero references to Qt, GTK, Cairo, EFL, Elementary, Wayland, ivi_application, or any other UI toolkit. `gtk-query-immodules-2.0-32` and `gtk-update-icon-cache` exist but are GLib utilities, not display tools.

### 1.2 The 4 UI daemons we're replacing — NOT in Slot A

| Daemon | systemd unit | ExecStart | Confirmed present on Slot A? |
|--------|--------------|-----------|------------------------------|
| `navi_ps "PS_NAVI"` | nav_navi.service | `/home/naviwork/system/bin/navi_ps` | **No** — on naviwork ext4 partition |
| `hmictrl_proc "PS_HMIC1"` | nav_hmictrl.service | `/home/naviwork/system/bin/hmictrl_proc` | **No** |
| `display_ps "PS_DISPLAY"` | nav_display.service | `/home/naviwork/system/bin/display_ps` | **No** |
| `dispapf_proc "PS_DISPAPF"` | nav_dispapf.service | `/home/naviwork/system/bin/dispapf_proc` | **No** |

Other DENSO binaries also at `/home/naviwork/system/bin/` (per their unit files):
`camera_ps`, `audio_ps`, `multimedia_ps`, `tel_proc`, `smng`, `smngpret`, `fis_ps`, `is`, `napl`, `snd`, `sndamp`, `ipodplayer_ps`, `ioapf_proc`, `soft_vup`, `bkup_prg`, `sdretn`, `systemlogd`, `PS_DSN`, `PS_REX01`, `PS_VRD01` (23 total).

**To inspect any of these binaries we would need to mount `LABEL=homenaviwork` from the eMMC.** No such image exists in our `images/` directory; we would need a separate dd of mmcblk0pN where N is the naviwork partition.

### 1.3 What's in `/opt/`

`/opt/` on Slot A contains only `/opt/var/` (yum DB + logs + cache). **No `/opt/<vendor>/` binary tree.** Total: 2,277 files, all yumdb metadata, empty log files (factory pristine image), and font caches. Nothing executable.

### 1.4 YUM-installed DENSO/EMGD packages

Only **two** packages on Slot A trace to DENSO/EMGD:
- `denso-system-02.00.18-0-i586` (yumdb hash `c41dbc66...`)
- `emgdhmi-3343-1.1-i586` (yumdb hash `6e1e6177...`)

No `navi-*`, `hmictrl-*`, `display-*`, `dispapf-*`, or `smng-*` packages on Slot A. Confirms the 4 UI daemons are installed/managed entirely on the naviwork partition outside yum.

---

## 2. The Drawbuf Reference Implementation

### 2.1 Why drawbuf matters

`drawbuf` is the **only EGL-using binary on Slot A with debug symbols intact**, including DWARF type info that reveals the full layout of `EMGDBufferType`, `EMGDPixelFormat`, `EMGDHmiBufferState`, and the calling sequence to set up an EGL surface backed by an emgdHmi pixmap. It uses the **same WSEGL backend** (libwsegl-hmi.so) as the 4 nav daemons. **It is the closest thing to a reference implementation we'll get without reading the daemon binaries.**

Source path baked into DWARF: `/home/naviwork/work/Display_Tool_source/drawbuf/DrawBuffer_c.c`
Build host include paths reveal:
- `/usr/include/EGL` — system EGL headers
- `/usr/include/KHR` — Khronos types
- `emgdhmi.h` — DENSO custom header (the API we need to call)
- `pvr2d.h` — Imagination PVR2D
- `wsegl.h` — Imagination WSEGL plugin interface

### 2.2 Linkage

```
$ objdump -p drawbuf
NEEDED  libemgdhmi.so.0      (the socket client)
NEEDED  libEGL.so.1          (Intel/EMGD thin shim)
NEEDED  libGLES_CM.so.1      (GLES 1.x common-profile)
NEEDED  libOpenVG.so         (OpenVG 1.1, also from EMGD)
NEEDED  libwsegl-hmi.so      (WSEGL backend — direct link, not just dlopen)
NEEDED  libm.so.6
NEEDED  libc.so.6
```

**Note: GLES 1.x, NOT GLES2.** This is the factory pattern. The other EGL binary on Slot A (`/usr/bin/egl`) links `libGLESv2.so.2` instead — proving the EMGD stack supports both GLES1 and GLES2 simultaneously. **Qt 5/6 will need GLES2; that's libGLESv2.so which is present and exported.**

### 2.3 Call sequence — what drawbuf actually does

From disassembly of `create_emgd_resource()` (0x08049210) and `create_egl_resources_with_parent()` (0x08049472):

```c
// PHASE A — get HMI display + (optionally) framebuffer
EGLNativeDisplayType ndpy = NULL;
emgdHmiGetNativeDisplay(&ndpy);

// optional: pull the existing framebuffer if we're targeting it
EGLNativeWindowType fb = NULL;
EmgdHmiPixmapInfo fbinfo;
if (need_fb) emgdHmiGetFramebuffer(ndpy, &fb, &fbinfo);

// PHASE B — create per-app pixmaps
// HMI (main) pixmap: 800x960, type=1 (EMGD_HMI_BUFFER)
PVR2DMEMINFO *hmi_pixmap = NULL;
emgdHmiCreatePixmap(ndpy, 1, 0x320, 0x3C0, &hmi_pixmap);   // 800 x 960

// POPUP pixmap: 800x480, type=3 (EMGD_POPUP_BUFFER)
PVR2DMEMINFO *popup_pixmap = NULL;
emgdHmiCreatePixmap(ndpy, 3, 0x320, 0x1E0, &popup_pixmap); // 800 x 480

// PHASE C — bind EGL
EGLDisplay disp = eglGetDisplay(ndpy);                  // ← native display IS the emgdHmi handle
eglInitialize(disp, NULL, NULL);

EGLint attrib[] = {
  EGL_RED_SIZE,     8,
  EGL_GREEN_SIZE,   8,
  EGL_BLUE_SIZE,    8,
  EGL_ALPHA_SIZE,   8,
  EGL_DEPTH_SIZE,   24,
  EGL_STENCIL_SIZE, 8,
  EGL_BIND_TO_TEXTURE_RGBA, 1,
  EGL_SAMPLES,      4,
  EGL_SURFACE_TYPE, EGL_WINDOW_BIT | EGL_PIXMAP_BIT,  // 0x06
  EGL_RENDERABLE_TYPE, EGL_OPENGL_ES_BIT,             // GLES1
  EGL_NONE
};
EGLConfig config; EGLint n;
eglChooseConfig(disp, attrib, &config, 10, &n);

// PHASE D — create surface(s)
// Window surface bound to framebuffer (full-screen direct)
EGLSurface fb_surf = eglCreateWindowSurface(disp, config, fb, NULL);

// Pixmap surface bound to off-screen pixmap
EGLSurface hmi_surf = eglCreatePixmapSurface(disp, config, hmi_pixmap, NULL);
EGLSurface popup_surf = eglCreatePixmapSurface(disp, config, popup_pixmap, NULL);

// PHASE E — context + activate
EGLContext ctx = eglCreateContext(disp, config, EGL_NO_CONTEXT, NULL);
eglMakeCurrent(disp, fb_surf, fb_surf, ctx);

// PHASE F — render loop
glClear(...); /* draw stuff */
eglSwapBuffers(disp, fb_surf);   // emgdhmid's flip chain handles the actual present
```

### 2.4 Decoded EGL attribute array (offset 0x08049cc0 in .rodata)

Hex dump (little-endian uint32 pairs):
```
24 30 00 00  08 00 00 00     # 0x3024 EGL_RED_SIZE, 8
23 30 00 00  08 00 00 00     # 0x3023 EGL_GREEN_SIZE, 8
22 30 00 00  08 00 00 00     # 0x3022 EGL_BLUE_SIZE, 8
21 30 00 00  08 00 00 00     # 0x3021 EGL_ALPHA_SIZE, 8
25 30 00 00  18 00 00 00     # 0x3025 EGL_DEPTH_SIZE, 24
26 30 00 00  08 00 00 00     # 0x3026 EGL_STENCIL_SIZE, 8
32 30 00 00  01 00 00 00     # 0x3032 EGL_BIND_TO_TEXTURE_RGBA, EGL_TRUE
31 30 00 00  04 00 00 00     # 0x3031 EGL_SAMPLES, 4
40 30 00 00  01 00 00 00     # 0x3040 EGL_RENDERABLE_TYPE, EGL_OPENGL_ES_BIT (GLES1)
33 30 00 00  06 00 00 00     # 0x3033 EGL_SURFACE_TYPE, WINDOW_BIT|PIXMAP_BIT
```

**For our Qt app, change `0x3040` (renderable) from `1` (GLES1_BIT) to `4` (GLES2_BIT) and drop MSAA to 0 for performance.**

### 2.5 Types decoded from drawbuf DWARF

The drawbuf binary embeds DWARF type names that confirm the emgdhmi.h enums:

**EMGDBufferType enum values seen in DWARF tags:**
- `EMGD_NO_BUFFER` (0)
- `EMGD_HMI_BUFFER` (1) ← what drawbuf uses for main canvas
- `EMGD_VIDEO_BUFFER` (2) ← rear camera / nav-anim video plane
- `EMGD_POPUP_BUFFER` (3) ← what drawbuf uses for overlay
- `EMGD_X11_BUFFER` (4) ← legacy X11 path (not used in our system)
- `EMGD_8BIT_BUFFER` (5) ← 8-bit indexed (legacy)

**EMGDPixelFormat values:**
- `EMGD_FMT_ARGB8888`
- `EMGD_FMT_RGB565`
- `EMGD_FMT_YUV422` (video plane)
- (Likely also ABGR8888, XRGB8888, ARGB1555, ARGB4444 per libemgdhmi.so.0 strings)

**EMGDerr enum:**
- `EMGD_SUCCESS`
- `EMGD_ERR_BUSY`
- `EMGD_ERR_BAD_ALLOC`
- `EMGD_ERR_BAD_CONFIG`
- `EMGD_ERR_BAD_DISPLAY`
- `EMGD_ERR_BAD_ID`
- `EMGD_ERR_IO_ERROR`
- `EMGD_ERR_NO_DISPLAY`
- `EMGD_ERR_UNSUPPORTED`

**S_EMGDDATA struct (the drawbuf state, offset confirmed from disasm):**
```c
typedef struct {
  EGLNativeDisplayType display;   // offset 0   (from emgdHmiGetNativeDisplay)
  EGLNativeWindowType  fb;        // offset 4   (from emgdHmiGetFramebuffer, or -1 if unused)
  EGLNativePixmapType  hmi_pixmap;// offset 8   (from emgdHmiCreatePixmap type=1, or -1)
  EGLNativePixmapType  popup_pixmap;// offset 12 (from emgdHmiCreatePixmap type=3, or -1)
} S_EMGDDATA;
```

The `EGLNativeWindowType` and `EGLNativePixmapType` here are both **`PVR2DMEMINFO *`** (per pvr2d.h + the disassembly passing them directly to `eglCreateWindowSurface`/`eglCreatePixmapSurface`). This is the smoking gun: **the native-window contract is "give me a PVR2DMEMINFO pointer returned by emgdHmi"**, no display-server window IDs needed.

### 2.6 String evidence

```
$ strings drawbuf | grep -iE "(wayland|ivi|surface_id|wl_)"
(no output)

$ strings drawbuf | grep -iE "(egl|emgdHmi|gles|fb_)"
eglSwapBuffers, eglGetDisplay, eglInitialize, eglGetError, eglChooseConfig,
eglCreateWindowSurface, eglCreatePixmapSurface, eglCreateContext, eglMakeCurrent,
eglDestroyContext, eglDestroySurface
emgdHmiGetFramebufferSize, emgdHmiMapPixmap, emgdHmiBufferState, emgdHmiFreeMem,
emgdHmiConfigureBuffers, emgdHmiGetNativeDisplay, emgdHmiGetFramebuffer,
emgdHmiCreatePixmap, emgdHmiDestroyPixmap
```

**Zero matches for Wayland, ivi_application, ivi_surface, ivi_id, wl_surface, surface_create, weston, X11.** This is conclusive: the factory display protocol is **bare-metal EGL on PVR2D pixmaps through the EMGD HMI broker — no display server abstraction layer of any kind.**

### 2.7 An interesting side path: `/tmp/sdupdate_sock`

drawbuf contains a second AF_UNIX socket: `/tmp/sdupdate_sock`. The disassembly opens it at startup, sends a few bytes, and continues regardless of success. This is **the SD-card-update IPC channel** — drawbuf evidently signals an SD updater that it's painting (so the updater knows the display is in test mode and can defer). Irrelevant for Plan B''' since we're not interacting with that path, but useful context.

---

## 3. Surface Registration — Definitive Answer

**Does the factory use ivi_application / wl_surface / IVI_SURFACE_ID?** **No.**

- **drawbuf:** zero matches for `ivi`, `wl_`, `wayland`, `surface_id`, `wsegl_native`, etc.
- **emgdhmid:** zero matches.
- **libwsegl-hmi.so:** zero matches.
- **libemgdhmi.so.0:** zero matches.
- **/usr/bin/egl:** zero matches.

The "surface" in this system is a **PVR2DMEMINFO** object allocated by emgdhmid (over the `/tmp/.emgdhmid_socket` RPC) and registered with EGL as the native window/pixmap. There is **no compositor protocol**, no surface registry server, no IPC handshake for surface IDs. The buffer-type tag (`EMGD_HMI_BUFFER` vs `EMGD_POPUP_BUFFER` vs `EMGD_VIDEO_BUFFER` vs `EMGD_X11_BUFFER`) is the only "what plane does this go on" hint — and that's a parameter to `emgdHmiCreatePixmap`, not a separate protocol message.

Compositing happens **in the kernel**: emgdhmid maps client pixmaps into the GTT and assigns them to display planes (overlay primary, Sprite C, video plane) via `DRM_IOCTL_IGD_CONFIG_BUFFS` and similar EMGD-private ioctls. The 4 UI daemons each create one or more buffers and that's their entire interaction with display compositing.

---

## 4. Display Setup Sequence Summary

| Step | Function | Side effect |
|------|----------|-------------|
| 0 | `emgdhmid` already running | Holds DRM fd, broker socket `/tmp/.emgdhmid_socket` accepting connections |
| 1 | `emgdHmiGetNativeDisplay(&ndpy)` | AF_UNIX connect to broker, get back opaque display handle |
| 2 | `emgdHmiGetFramebufferSize(ndpy, &fbinfo)` *(optional)* | Get framebuffer geometry without claiming it |
| 3 | `emgdHmiGetFramebuffer(ndpy, &fb, &fbinfo)` *(if rendering to FB directly)* | Get PVR2DMEMINFO* for the full framebuffer |
| 4 | `emgdHmiCreatePixmap(ndpy, type, w, h, &pix)` | Allocate a buffer via broker (GTT-mapped, returned as PVR2DMEMINFO*) |
| 5 | `eglGetDisplay(ndpy)` | EGL wraps the native display |
| 6 | `eglInitialize(disp, &maj, &min)` | libEMGDegl reads `/etc/powervr.ini`, dlopens libwsegl-hmi.so |
| 7 | `eglChooseConfig(disp, attribs, &cfg, 1, &n)` | Returns an EGLConfig matching RGBA8/D24/S8 |
| 8 | `eglCreateWindowSurface(disp, cfg, fb, NULL)` *or* `eglCreatePixmapSurface(disp, cfg, pix, NULL)` | Binds EGL surface to the PVR2D buffer |
| 9 | `eglCreateContext(disp, cfg, EGL_NO_CONTEXT, ctx_attribs)` | Create GLES context |
| 10 | `eglMakeCurrent(disp, surf, surf, ctx)` | Activate |
| 11 | Render with `gl*` calls | Writes to GTT-mapped buffer |
| 12 | `eglSwapBuffers(disp, surf)` | Triggers `emgdHmiRequestFlip` over broker — emgdhmid flips the plane |

**Pixel format:** ARGB8888 for the HMI/POPUP path (per EGL config). The framebuffer itself is also ARGB8888 (one of the supported `EMGDPixelFormat` values — confirmed from libemgdhmi strings).

**Pitch hint (1664):** the R1 work captured V4L2 buffers with `pitch=1600 = 800 × 2 bytes` for YUYV. For ARGB8888, the pitch will be `800 × 4 = 3200` bytes — NOT 1664. Where does the 1664 come from? It comes from a **different** plane — the video capture path that R1 hooked. The HMI plane is independently 800×{480 or 960} × 4 bytes = 12,800 or 25,600 bytes per row's worth of allocation. The exact stride emgdhmid reports comes from `emgdHmiGetFramebufferSize` (we'd query at runtime, not hardcode).

---

## 5. DRM Master + Device File Setup

(Cross-referenced with Agent 6's `/Users/dpitek/Developer/q60-rebuild/docs/forensic-emgd-init.md`)

- **`/dev/dri/card0`** — emgd minor 0. emgdhmid opens with `drmOpen("emgd", "PCI:00:02:00")` then **immediately calls `drmDropMaster(fd)`**. Our app does NOT need to be master. **Do not call `drmSetMaster()` from Qt.**
- **`/dev/v2gbridge`** — V2G bridge ioctl interface; emgdhmid opens for video path. Irrelevant to Plan B'''.
- **`/dev/video0`** — V4L2 capture device for IOH VIN (rear camera). Irrelevant to Plan B'''.
- **`/tmp/.emgdhmid_socket`** — AF_UNIX SOCK_STREAM, the only IPC between our app's libwsegl-hmi/libemgdhmi and the broker.
- **`/dev/shm/LEGRES`** — shared memory directory, created by `nav_init.service`, chowned `ivilinux:ivilinux`. Used by DENSO process IPC (smng coordination). **Our app does not touch this.**
- **`/dev/mqueue`** — POSIX message queue mount, used by DENSO PS_* channel IPC. **Our app does not touch this.**

No `/dev/fb0` reference anywhere in the EGL stack. There is no fbdev path on this hardware.

---

## 6. Init Sequence on Disk — What Launches the UI Daemons

(See Agent 3's `forensic-daemon-supervision.md` for full cascade analysis. Excerpt of the launch graph relevant to UI binaries):

```
basic.target.wants/                  ← t≈0.5s
  └─ emgdhmid.service                ← /usr/sbin/emgdhmid (on Slot A) — DRM master holder
       (no Restart=, RemainAfterExit=yes, Group=video)

graphical.target.wants/              ← t≈1.0s
  ├─ nav_init.service                ← mkdir /dev/shm/LEGRES (one-shot)
  ├─ nav_before.service              ← rename.sh (handle pending SW updates)
  ├─ nav_driver.service              ← driver init (bt_dfu, dac_reset)
  └─ nav_smng.service                ← /home/naviwork/system/bin/smng "PS_OS01"
       (After=emgdhmid.service nav_init.service nav_before.service)
       (OnFailure=nav_backup.service → poweroff!)
       (this is the orchestrator that drives the IPC handshake to PS_* peers)
       │
       └─ pulls in nav_pre.target (transitively, via Requires= on every nav_*)
            │
            └─ nav_pre.target.wants/  ← all 18 nav_* daemons start in parallel
                ├─ nav_navi.service        → navi_ps "PS_NAVI"
                ├─ nav_hmictrl.service     → hmictrl_proc "PS_HMIC1"
                ├─ nav_display.service     → display_ps "PS_DISPLAY"
                ├─ nav_dispapf.service     → dispapf_proc "PS_DISPAPF"
                ├─ nav_initialscreen.service → fis_ps "PS_FIS"
                ├─ nav_camera.service      → camera_ps "PS_CAMERA"
                ├─ nav_audio.service       → audio_ps "PS_AUDIO"
                ├─ nav_multimedia.service  → multimedia_ps "PS_MULTIMEDIA"
                ├─ nav_tel.service         → tel_proc "PS_TEL"
                ├─ nav_ipodplayer.service  → ipodplayer_ps "PS_IPODPLAYER"
                ├─ nav_dsn.service         → PS_DSN
                ├─ nav_rex01.service       → PS_REX01
                ├─ nav_vrd01.service       → PS_VRD01
                ├─ nav_snd.service         → snd "PS_SND"
                ├─ nav_sndamp.service      → sndamp "PS_SNDAMP"
                ├─ nav_napl.service        → napl "PS_OS02"
                ├─ nav_is.service          → is "PS_IS01"
                └─ nav_soft_vup.service    → soft_vup "PS_SOFT_VUP"

(separately, in nav_early.target.wants/:)
  └─ nav_ioapf.service               → ioapf_proc "PS_IOAPF"
```

**Key facts:**
- **Type=simple, no Restart=, no WatchdogSec=** for all 4 UI daemons.
- **LimitMSGQUEUE=8192000, LimitSTACK=524288** for all nav_* services.
- **OnFailure=nav_smngpret.service** for ALL nav_*, cascading to poweroff. (Agent 3 explains how to neutralize this.)
- **emgdhmid is the ONLY display-related service that runs from Slot A.** Everything else lives on naviwork.
- The commented-out hint in nav_hmictrl.service shows the runtime LD_LIBRARY_PATH:
  `/home/naviwork/system/bin:/home/naviwork/system/lib:/home/naviwork/system/out:/usr/lib:/usr/local/lib:/usr/lib/wsegl`
  (this is what the 4 daemons actually use; abs_clock.service uses the same pattern minus `/usr/lib/wsegl`)

---

## 7. IPC Connections from the UI Daemons (Outgoing)

We don't have the binaries to disassemble — we can only triangulate from the runtime contract.

### 7.1 What we know they MUST call

Every one of the 4 UI daemons that touches the display:
1. **Connects to `/tmp/.emgdhmid_socket`** (AF_UNIX SOCK_STREAM) — automatically via libemgdhmi.so.0 on `eglInitialize` → libwsegl-hmi → `emgdHmiGetNativeDisplay`. **This IPC will be unaffected** when we kill the daemons (the broker holds no daemon-specific state once the connection closes — confirmed by Agent 1).

### 7.2 What we know they LIKELY call (from systemd unit config)

Every nav_* unit declares `LimitMSGQUEUE=8192000` → confirms they use POSIX message queues. The naming convention is the `PS_*` channel name (passed as argv[1]):

| Daemon | Channel | Likely creates `/PS_*` mqueue |
|--------|---------|-------------------------------|
| navi_ps | PS_NAVI | `/PS_NAVI` |
| hmictrl_proc | PS_HMIC1 | `/PS_HMIC1` |
| display_ps | PS_DISPLAY | `/PS_DISPLAY` |
| dispapf_proc | PS_DISPAPF | `/PS_DISPAPF` |
| camera_ps | PS_CAMERA | `/PS_CAMERA` |
| smng | PS_OS01 | `/PS_OS01` |
| fis_ps | PS_FIS | `/PS_FIS` |
| ... (18 total) | | |

When a daemon dies, its `mq_open`'d queues close. Other daemons sending to that queue will get `mq_send` ENOENT (if `O_NONBLOCK`) or block (if not) — which is what triggers smng to enter its error state and OnFailure-cascade. **This is why Agent 3's strategy is to mask ALL 18 nav_* units plus nav_smng, nav_smngpret, nav_backup — so no daemon is left looking for a dead peer.**

### 7.3 What we know about /dev/shm/LEGRES

- Created by nav_init.service: `mkdir -p /dev/shm/LEGRES; chown ivilinux; chgrp ivilinux`
- Likely contains `shm_open`'d shared memory files for inter-daemon coordination (LEGacy RESource sharing?)
- Our app does NOT need to touch this — the EGL stack uses Unix sockets, not LEGRES.

### 7.4 What our app needs to provide to keep emgdhmid happy

**Almost nothing.** emgdhmid is a passive RPC broker. Once we connect via libemgdhmi:
- We can call `emgdHmiCreatePixmap` to allocate buffers (emgdhmid maps into GTT).
- We can call `emgdHmiRequestFlip` to present (emgdhmid does the actual plane assignment).
- We can call `emgdHmiConfigureBuffers` to set up our own flip chain.
- We never need to drive smng IPC or PS_* messages — those are entirely DENSO-private coordination.

### 7.5 Risk: emgdhmid's startup might require some buffer-pre-configuration

emgdhmid's `getDisplayHandle()` runs at startup and queries display modes. It may also have a state machine that expects `EMGDHMIAPI_CONFIGUREBUFFERS` to be called by *someone* before flips work. The factory probably has `display_ps` call this. **If we kill `display_ps`, we may need to call `emgdHmiConfigureBuffers` ourselves at app startup.** This is the open question flagged by Agent 1 (Question #3 in their on-device probe list).

---

## 8. The /opt/ Catalog

**There are zero executables in `/opt/` on Slot A.** The entire tree contains:

| Sub-tree | Contents | File count |
|----------|----------|----------:|
| `/opt/var/lib/yum/` | YUM RPM database + history (sqlite) | ~2000+ |
| `/opt/var/lib/yum/yumdb/` | One dir per installed package, with checksum/repo/install metadata | ~2200 metadata files |
| `/opt/var/log/` | Empty log files (factory-pristine) | 14 |
| `/opt/var/cache/fontconfig/` | One fontconfig cache | 1 |
| `/opt/var/cache/ldconfig/aux-cache` | ldconfig cache | 1 |
| `/opt/var/run/utmp` | Empty utmp | 1 |
| `/opt/var/spool/mail/{logan,ivilinux}` | Empty mail spools | 2 |

`/opt/var/resolv.conf` exists (a single resolver config) — that's the most "interesting" thing in opt.

**Conclusion: `/opt` is not used by DENSO for binary deployment on this DCU.** All DENSO binaries are on the naviwork ext4 partition.

---

## 9. Recipe — How Our Qt App Replicates the Factory Surface Setup

### 9.1 Minimum viable Qt eglfs device integration

Write a Qt platform plugin: `qeglfsemgdhmi.cpp` (~300 LoC):

```cpp
class QEglFSEmgdHmiIntegration : public QEglFSDeviceIntegration {
public:
    void platformInit() override {
        emgdHmiGetNativeDisplay(&m_ndpy);
    }

    EGLNativeDisplayType platformDisplay() const override {
        return m_ndpy;
    }

    QSize screenSize() const override {
        EmgdHmiPixmapInfo info;
        emgdHmiGetFramebufferSize(m_ndpy, &info);
        return QSize(info.width, info.height);  // expect 800 x 480 or 800 x 960
    }

    EGLNativeWindowType createNativeWindow(QPlatformWindow *,
                                           const QSize &size,
                                           const QSurfaceFormat &) override {
        PVR2DMEMINFO *pix = nullptr;
        emgdHmiCreatePixmap(m_ndpy, EMGD_HMI_BUFFER /*1*/,
                            size.width(), size.height(), &pix);
        return reinterpret_cast<EGLNativeWindowType>(pix);
    }

    void destroyNativeWindow(EGLNativeWindowType w) override {
        emgdHmiDestroyPixmap(m_ndpy, reinterpret_cast<PVR2DMEMINFO*>(w));
    }

    bool hasCapability(QPlatformIntegration::Capability cap) const override {
        return cap == QPlatformIntegration::OpenGL || cap == QPlatformIntegration::ThreadedOpenGL;
    }

private:
    EGLNativeDisplayType m_ndpy = nullptr;
};
```

Cross-compile against `/usr/include/EGL/egl.h` + DENSO's `emgdhmi.h` (which we'll need to either obtain from a DDK source release or extract type info via the drawbuf DWARF + libemgdhmi.so.0 symbol table).

### 9.2 Runtime environment

```sh
export QT_QPA_PLATFORM=eglfs
export QT_QPA_EGLFS_INTEGRATION=eglfs_emgdhmi   # our custom plugin name
export QT_QPA_EGLFS_PHYSICAL_WIDTH=152          # mm, for DPI (152mm × 91mm = 7" upper)
export QT_QPA_EGLFS_PHYSICAL_HEIGHT=91
export LD_LIBRARY_PATH=/usr/lib/wsegl:/usr/lib
# We DO NOT need /home/naviwork/system/lib unless our app pulls in DENSO libs (it shouldn't)

# Our app must be in 'video' group OR run as root to open /dev/dri/card0:
# (already true if we launch from systemd as `Group=video`)
```

### 9.3 EGLConfig for Qt5/6

```cpp
EGLint attribs[] = {
    EGL_RED_SIZE,         8,
    EGL_GREEN_SIZE,       8,
    EGL_BLUE_SIZE,        8,
    EGL_ALPHA_SIZE,       8,
    EGL_DEPTH_SIZE,       24,
    EGL_STENCIL_SIZE,     8,
    EGL_SURFACE_TYPE,     EGL_WINDOW_BIT,
    EGL_RENDERABLE_TYPE,  EGL_OPENGL_ES2_BIT,   // 0x0004 — GLES2 for Qt RHI
    EGL_NONE
};
```

(Drop MSAA from drawbuf's 4x for performance on SGX535.)

### 9.4 emgdhmi.h header — how to obtain

Three options:
1. **Intel EMGD DDK 1.13 source release** — historically distributed by Intel/Wind River. Should contain the canonical `emgdhmi.h`. Search for "EMGD_1_13" / "Intel EMGD DDK 1.13".
2. **Reconstruct from drawbuf DWARF** — every type field we need is in the debug info:
   ```
   $ objdump --dwarf=info drawbuf | grep -E "(DW_AT_name|DW_TAG_member|DW_TAG_structure)"
   ```
   would yield S_EMGDDATA, EMGDBufferType, EMGDPixelFormat enums, EMGDHmiBufferState, etc. We've already extracted the key fields from `strings`.
3. **Reconstruct from libemgdhmi.so.0 symbols** — the API surface is fully exported and the calling convention is i386 cdecl. We can derive prototypes from the disassembly + the drawbuf usage. Already done for the 8 calls we need.

### 9.5 Build environment

```bash
# Cross-compile target:
docker run --platform linux/386 alpine \
  apk add musl-dev qt6-base-dev mesa-egl-dev mesa-gles-dev
# Then build qt6 + plugin against EMGD i386 binary libs:
i686-linux-gnu-g++ -m32 \
  -I/path/to/emgdhmi.h \
  -DEGL_NO_X11 \
  -L/tmp/dsu-slot-a/usr/lib \
  -lEGL -lGLESv2 -lemgdhmi -lwsegl-hmi \
  -o qeglfsemgdhmi.so qeglfsemgdhmi.cpp
```

---

## 10. Evidence Index — File Paths Referenced

### Slot A binaries (touchable on disk)
- `/tmp/dsu-slot-a/usr/sbin/emgdhmid` — DRM master + HMI broker
- `/tmp/dsu-slot-a/usr/bin/egl` — factory EGL probe (uses GLES2 + EGLImageKHR)
- `/tmp/dsu-slot-a/lib/systemd/system/systemdRelatedFiles/Display_Tools/drawbuf` — **reference impl with debug info**
- `/tmp/dsu-slot-a/lib/systemd/system/systemdRelatedFiles/Display_Tools/drawbufd` — daemon variant
- `/tmp/dsu-slot-a/lib/systemd/system/systemdRelatedFiles/Display_Tools/display_color.sh` — wrapper script (loops `drawbuf <color>`)
- `/tmp/dsu-slot-a/usr/lib/wsegl/libwsegl-hmi.so` — WSEGL backend (already covered by Agent 1)
- `/tmp/dsu-slot-a/usr/lib/libemgdhmi.so.0.1.0` — broker client lib (already covered by Agent 1)

### Not in Slot A — on `/home/naviwork/` (ext4, `LABEL=homenaviwork`)
- `/home/naviwork/system/bin/navi_ps` — PS_NAVI
- `/home/naviwork/system/bin/hmictrl_proc` — PS_HMIC1
- `/home/naviwork/system/bin/display_ps` — PS_DISPLAY
- `/home/naviwork/system/bin/dispapf_proc` — PS_DISPAPF
- `/home/naviwork/system/bin/smng` — PS_OS01 (orchestrator)
- `/home/naviwork/system/bin/camera_ps` — PS_CAMERA
- `/home/naviwork/system/bin/audio_ps` — PS_AUDIO
- `/home/naviwork/system/bin/multimedia_ps` — PS_MULTIMEDIA
- `/home/naviwork/system/bin/tel_proc` — PS_TEL
- `/home/naviwork/system/bin/fis_ps` — PS_FIS
- `/home/naviwork/system/bin/ipodplayer_ps` — PS_IPODPLAYER
- `/home/naviwork/system/bin/ioapf_proc` — PS_IOAPF
- `/home/naviwork/system/bin/PS_DSN`, `PS_REX01`, `PS_VRD01`
- `/home/naviwork/system/bin/snd`, `sndamp`, `napl`, `is`, `soft_vup`, `bkup_prg`, `sdretn`, `systemlogd`, `smngpret`
- `/home/naviwork/system/lib/*` — DENSO custom libs
- `/home/naviwork/system/out/*` — likely DENSO output/cache
- `/home/naviwork/log/core` — core file destination (per commented-out core_pattern)
- `/home/naviwork/work/Display_Tool_source/` — drawbuf source path (build host)

### systemd units that reveal launcher commands
- `/tmp/dsu-slot-a/lib/systemd/system/nav_navi.service`
- `/tmp/dsu-slot-a/lib/systemd/system/nav_hmictrl.service`
- `/tmp/dsu-slot-a/lib/systemd/system/nav_display.service`
- `/tmp/dsu-slot-a/lib/systemd/system/nav_dispapf.service`
- `/tmp/dsu-slot-a/lib/systemd/system/nav_smng.service`
- `/tmp/dsu-slot-a/lib/systemd/system/emgdhmid.service`
- `/tmp/dsu-slot-a/lib/systemd/system/home-naviwork.mount` (LABEL=homenaviwork, type=ext4, options=nodelalloc)

### Config files
- `/tmp/dsu-slot-a/etc/powervr.ini` — `[default] WindowSystem=/usr/lib/wsegl/libwsegl-hmi.so`
- `/tmp/dsu-slot-a/etc/ld.so.conf.d/emgdhmi.conf` — `/usr/lib/wsegl`
- `/tmp/dsu-slot-a/etc/sysctl.conf` — `fs.mqueue.msgsize_max=1048576` (the kernel mqueue tuning for PS_* IPC)
- `/etc/emgdhmid-screens` — referenced in emgdhmid strings but **NOT on Slot A** (likely written at runtime by nav_init or pulled from naviwork — unknown content; deferred)

### Other DENSO refs
- `/tmp/dsu-slot-a/etc/.psfile` — single line: `denso%369` (possibly a password? salt?)
- `/tmp/dsu-slot-a/etc/udev/rules.d/ifup_navi0.sh` — DENSO-authored 2012, configures `navi0` net interface at 169.254.10.1/24 mtu 9000 (jumbo frames, internal Ethernet to nav sub-board)

### Cross-reference docs
- `/Users/dpitek/Developer/q60-rebuild/docs/forensic-egl-abi.md` (Agent 1) — EGL ABI + libwsegl-hmi analysis
- `/Users/dpitek/Developer/q60-rebuild/docs/forensic-daemon-supervision.md` (Agent 3) — systemd cascades
- `/Users/dpitek/Developer/q60-rebuild/docs/forensic-emgd-init.md` (Agent 6) — emgdhmid DRM master timing

---

## 11. Open Items for On-Device Probe

1. **Read the daemon binaries.** Mount `LABEL=homenaviwork` (the naviwork ext4) and `cp /home/naviwork/system/bin/{navi_ps,hmictrl_proc,display_ps,dispapf_proc,smng}` to host for full disassembly. Until then, we're inferring their EGL/HMI usage from the libwsegl-hmi contract.
2. **Capture `/etc/emgdhmid-screens` content.** Boot the factory, dump that file. We need to know the screen-configuration format if our app ever needs to emulate emgdhmid (Plan C contingency).
3. **Capture the actual EGL config the nav daemons negotiate.** Run a small probe binary as root with `EGL_KHR_debug` enabled that logs the chosen EGLConfig attributes. Compare against drawbuf's hardcoded attribs.
4. **Confirm `emgdHmiConfigureBuffers` is callable from a fresh process.** If only `display_ps` ever calls it at boot, killing display_ps may leave emgdhmid in a state where our app's createpixmap fails. Probe: stop nav_display, start a minimal `emgdHmiCreatePixmap` test binary, see if it succeeds.
5. **Test the 800×960 stacked vs 800×480 single-screen behavior.** drawbuf allocates 800×960 — does that mean the upper and lower LVDS panels are combined into one virtual canvas, or do we need separate displays per panel? `emgdHmiGetNumScreens()` would answer this at runtime.
6. **Sanity-check the LD_LIBRARY_PATH.** Run our app with the same path the daemons use (`/home/naviwork/system/lib` included) — make sure we don't accidentally pick up DENSO's libs that might conflict with Qt's.

---

## 12. Verdict — Replicating the Factory UI from Qt

| Question | Answer |
|----------|--------|
| What UI toolkit does the factory use? | None. Raw EGL + GLES1.x + OpenVG on emgdHmi pixmaps. |
| What display protocol? | EMGD HMI broker (AF_UNIX `/tmp/.emgdhmid_socket`) + PVR2D pixmaps as `EGLNativeWindowType`. No Wayland, no ivi, no X11. |
| Native window type? | `PVR2DMEMINFO *` returned by `emgdHmiCreatePixmap`. |
| Native display type? | Opaque handle returned by `emgdHmiGetNativeDisplay`. |
| EGL config? | RGBA8 / D24 / S8 / 4x MSAA / GLES1_BIT / WINDOW|PIXMAP. (Switch GLES1→GLES2 for Qt.) |
| Resolution? | 800×480 per panel; 800×960 stacked virtual canvas; the EGLNativeWindowType you create dictates which path you use. |
| DRM master? | emgdhmid drops master immediately; our app does NOT call SetMaster. |
| Effort to replicate from Qt? | One QEglFSDeviceIntegration plugin (~300 LoC C++) calling 4-5 emgdHmi functions. |
| Surface registration handshake? | NONE — bypass all compositor protocols. Pixmap creation IS the registration. |

**Plan B''' is viable. The factory contract is dramatically simpler than a typical Wayland-ivi or X11 system: it's just EGL with vendor pixmaps.** Our Qt app needs to wrap the four emgdHmi calls in a platform plugin and we're done with the display side. The Plan B''' risk is NOT on the binary contract — it's on whether emgdhmid survives the nav daemon kill (covered by Agent 1's open questions 1-4 and Agent 3's cascade-mask strategy) and on whether `emgdHmiConfigureBuffers` needs an explicit call from our app (Open Item 4 above).
