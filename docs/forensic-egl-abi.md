# Forensic EGL/GLES ABI Analysis — Factory Slot A Rootfs

**Date:** 2026-05-23
**Source:** `/tmp/dsu-slot-a/` (extracted factory Slot A rootfs)
**Target stack:** EMGD 1.5.15.3226 / PowerVR SGX 535 / MeeGo 1.2.0 / kernel 2.6.37
**Question:** Can we run Qt 6 `eglfs` against the factory EGL libs with the 4 nav UI daemons disabled?

---

## Executive Summary

1. **libwsegl-hmi.so has a HARD dependency on `emgdhmid` — but NOT on hmictrl_proc / navi_ps / display_ps / dispapf_proc.** Evidence: libwsegl-hmi.so links only `libemgdhmi.so.0 + libEMGD2d.so + libpthread + libc` (no other IPC), and `libemgdhmi.so.0` opens exactly **one** AF_UNIX SOCK_STREAM connection to `/tmp/.emgdhmid_socket`. The 4 nav daemons (hmictrl_proc, navi_ps, display_ps, dispapf_proc) live at `/home/naviwork/system/bin/` (not in Slot A), use POSIX message queues (`LimitMSGQUEUE=8192000` + channel names `PS_HMIC1`, `PS_NAVI`, `PS_DISPLAY`, `PS_DISPAPF`), and **neither the WSEGL backend nor emgdhmid links to them or references their channel names.**
2. **Plan B''' EGL viability: CONDITIONAL GO.** We can kill the 4 nav daemons and still get EGL working, **provided `emgdhmid` (`/usr/sbin/emgdhmid`) keeps running and we let it hold DRM master.** Killing emgdhmid breaks the EGL stack — `eglInitialize` will fail with the literal error string baked into `/usr/bin/egl`: *"Could not get native display. Is emgdhmid running?"*
3. **Required env vars for our app: NONE strictly required**, but we MAY want `EMGDPVR_<procname>_WindowSystem=...` if we ever ship an alternative WSEGL. Default behavior reads `[default]` section of `/etc/powervr.ini` which already sets `WindowSystem=/usr/lib/wsegl/libwsegl-hmi.so`. The selector is the **process name** (basename of `/proc/self/cmdline`) — INI section lookup pattern is `[<procname>]` falling back to `[default]`.
4. **Required device files:** `/dev/dri/card0` (DRM, EMGD driver, module name `"emgd"` passed to `drmOpen`) + `/tmp/.emgdhmid_socket` (AF_UNIX, emgdhmid IPC) + whatever framebuffer plane emgdhmid hands back via its `EMGDHMIAPI_GETFRAMEBUFFERSIZE` / `EMGDHMIAPI_REQUESTFLIP` protocol. **No `/dev/fb*` needed** by the EMGD WSEGL path; **no `/dev/pvrsrvkm`** (PVR services tunneled through DRM via `-DSUPPORT_DRI_DRM`).
5. **DRM master: emgdhmid holds it, our app must NOT request it.** emgdhmid links `drmSetMaster` / `drmDropMaster` directly; the only ELF in this rootfs that does. The EMGD-PVR stack does `DRM_AUTH` (cookie via `drmGetMagic`) from inside `libemgdPVR2D_DRIWSEGL.so` (the X11 backend; not ours), and via PVR-services for the HMI backend. **Conclusion: our Qt app calls `eglInitialize` and the WSEGL backend gets authed under emgdhmid's master — we never call SetMaster ourselves.**

**Bottom line for Plan B''':** Stop the 4 nav daemons. Leave `emgdhmid.service` running. Patch `/etc/powervr.ini` (or just leave the default) so `[default]` WindowSystem points at libwsegl-hmi.so. Launch Qt with `QT_QPA_PLATFORM=eglfs`. The EGL stack should come up. **This is a GO with one named external dependency: `/usr/sbin/emgdhmid` must be running.** The questions of whether disabling nav_hmictrl / nav_display / nav_navi / nav_dispapf breaks emgdhmid itself, or starves the GTT of buffers, can only be answered with an on-device probe — see "Open questions for on-device probe" below.

---

## 1. libwsegl-hmi.so — Deep Dive

### Linkage
```
NEEDED libemgdhmi.so.0
NEEDED libEMGD2d.so
NEEDED libpthread.so.0
NEEDED libc.so.6
```

### Defined symbols (exports)
- `WSEGL_GetFunctionTablePointer` (the entry point libEMGDegl dlsyms)
- `EmgdHmiFlipChainState`, `EmgdHmiDestroyPixmap`, `EmgdHmiSetUsage` (helpers)

### Undefined symbols (imports)
PVR2D family (resolved to `libEMGD2d.so`):
- `PVR2DCreateDeviceContext`, `PVR2DDestroyDeviceContext`, `PVR2DEnumerateDevices`
- `PVR2DCreateFlipChain`, `PVR2DGetFlipChainBuffers`, `PVR2DPresentFlip`
- `PVR2DMemMap`, `PVR2DMemFree`, `PVR2DGetScreenMode`

EmgdHmi family (resolved to `libemgdhmi.so.0`):
- `emgdHmiQueryPixmap` (only one — most usage is via PVR2D)

libc:
- `malloc`, `free`, `realloc`, `memmove` only.

### IPC strings inventory
**`strings libwsegl-hmi.so` produces ZERO matches for:**
- mqueue paths (`/PS_*`, `/SVC_*`)
- abstract sockets (`@/EM*`, `@/...`)
- shm names (`shm_*`, `/dev/shm/*`)
- process names (`hmictrl`, `navi_ps`, `display_ps`, `dispapf`, `camera_ps`)
- env var checks (no `getenv` undefined symbol)

**libwsegl-hmi.so does NOT speak any IPC directly. All IPC is delegated to libemgdhmi.so.0.**

### Build provenance
- Source: `/home/jk/workspace/GFX-EMGD.DENSO-LINUX_DDK-EMGD_1_13--PROD/koheo/linux/eurasia/...`
- Vendor: DENSO (Japan; "koheo" = Clarion's DENSO BU)
- Compiler: GCC 4.5.1 (Red Hat 4.5.1-4)
- Build date matches the EMGD 1.5.15.3226 stack: 2013-02-27.

---

## 2. libemgdhmi.so.0 — The Socket Client

This is where the IPC actually happens. Smoking gun decoded from disassembly of `_ZL12check_socketv` at `0x41639dd0`:

```asm
movw   $0x1, sun_family            ; AF_UNIX
movl   $0x706d742f, sun_path+0     ; "/tmp"
movl   $0x6d652e2f, sun_path+4     ; "/.em"
movl   $0x6d686467, sun_path+8     ; "gdhm"
movl   $0x735f6469, sun_path+12    ; "id_s"
movl   $0x656b636f, sun_path+16    ; "ocke"
movw   $0x74,       sun_path+20    ; "t\0"
movl   $0x1,        type           ; SOCK_STREAM
movl   $0x2,        domain         ; AF_UNIX
call   socket@plt
call   bind@plt                    ; binds an anonymous local side
call   connect@plt                 ; connects to /tmp/.emgdhmid_socket
```

**Socket path: `/tmp/.emgdhmid_socket`** — AF_UNIX, SOCK_STREAM. If `connect()` fails, the lib sets `sockfd = -1` and the wsegl backend's `pfnWSEGL_InitialiseDisplay` returns failure → `eglInitialize` fails.

### Wire protocol (function names indicate RPC ops)
```
EMGDHMIAPI_CREATEPIXMAP / DESTROYPIXMAP / QUERYPIXMAP
EMGDHMIAPI_GETNUMSCREENS / GETSCREENPARAMS / GETFRAMEBUFFERSIZE
EMGDHMIAPI_REQUESTFLIP / FLIPSCREEN / CONFIGUREBUFFERS
EMGDHMIAPI_CONTROLPLANEFORMAT / SWITCHHZ
EMGDHMIAPI_STARTVIDEO / STOPVIDEO
```
Helper: `SendNGetReply` (pthread-mutex protected → one socket connection is shared across the client process).

### NO references to nav daemons
`strings libemgdhmi.so.0.1.0 | grep -iE "hmictrl|navi_ps|display_ps|dispapf|camera_ps"` → **0 matches**.

---

## 3. Inventory — All EGL/GLES/EMGD/PowerVR Libraries

All under `/tmp/dsu-slot-a/usr/lib/`. All ELF32 i386, EMGD build 1.5.15.3226, dated 2013-03-21. Compiled `-march=atom -O2 -fPIC` with `-DSUPPORT_DRI_DRM -DSUPPORT_SGX535`.

| File | Size | SONAME | Role |
|---|---:|---|---|
| `libEGL.so.1.5.15.3226` | 10788 | `libEGL.so.1` | Thin shim → `IMGegl*` symbols in libEMGDegl |
| `libEMGDegl.so.1.5.15.3226` | 62408 | `libEMGDegl.so` | Real EGL impl; reads `/etc/powervr.ini` `WindowSystem` and dlopens WSEGL backend |
| `libGLESv2.so.1.5.15.3226` | 370640 | `libGLESv2.so.2` | 142 GLES2 entry points |
| `libGLES_CM.so.1.5.15.3226` | 548040 | `libGLES_CM.so.1` | 145 GLES1.x entry points |
| `libEMGDOGL.so.1.5.15.3226` | 2791664 | `libEMGDOGL.so` | Desktop OpenGL (unused by us) |
| `libEMGD2d.so.1.5.15.3226` | 32684 | `libEMGD2d.so` | PVR2D API (blit / flipchain / mem) |
| `libemgdsrv_init.so.1.5.15.3226` | 122500 | (no soname) | PVR services init |
| `libemgdsrv_um.so.1.5.15.3226` | 138800 | (no soname) | PVR services user-mode; reads powervr.ini, dispatches DRM ioctls |
| `libemgdglslcompiler.so.1.5.15.3226` | 1168364 | `libemgdglslcompiler.so` | Online GLSL compiler |
| `libemgdhmi.so.0.1.0` | 30893 | `libemgdhmi.so.0` | Client lib for `/tmp/.emgdhmid_socket` |
| `libemgdPVR2D_DRIWSEGL.so.1.5.15.3226` | 22224 | `libemgdPVR2D_DRIWSEGL.so` | **X11/DRI2 WSEGL backend (not for us)** |
| `libemgdPVR2D_BLITWSEGL.so` | — | — | **NOT PRESENT** (was OPK_FALLBACK in build flags) |
| `wsegl/libwsegl-hmi.so` | 23079 | (none) | HMI WSEGL backend (the only one for our eglfs path) |
| `libdrm.so.2.4.0` | 45168 | `libdrm.so.2` | Generic libdrm 2.4.0 (Jan 2011) |
| `libdrm_intel.so.1.0.0` | 42944 | `libdrm_intel.so.1` | Intel libdrm helpers (unused) |

### Symlink chains
```
libEGL.so.1                  → libEGL.so.1.5.15.3226
libEMGDegl.so                → libEMGDegl.so.1.5.15.3226
libGLESv2.so.2               → libGLESv2.so.1.5.15.3226
libGLES_CM.so.1              → libGLES_CM.so.1.5.15.3226
libemgdhmi.so.0              → libemgdhmi.so.0.1.0
libemgdPVR2D_DRIWSEGL.so     → libemgdPVR2D_DRIWSEGL.so.1.5.15.3226
libdrm.so.2                  → libdrm.so.2.4.0
```

### ld.so.conf addition
`/etc/ld.so.conf.d/emgdhmi.conf` adds `/usr/lib/wsegl` to the loader search path. (Not strictly necessary; libEMGDegl dlopens by absolute path from powervr.ini.)

---

## 4. Symbol Surface — libEGL / libGLESv2 / libGLES_CM

### libEGL.so.1.5.15.3226 — 10.5 KB thin shim
- NEEDED: `libEMGDegl.so`, `libdl.so.2`, `libc.so.6`
- RPATH: `/lib:/usr/lib`
- Exports (`nm -D --defined-only`): all 40 standard `egl*` functions (eglGetDisplay, eglInitialize, eglChooseConfig, eglCreateContext, eglMakeCurrent, eglSwapBuffers, etc.)
- Imports: 40× `IMGegl*` counterparts (the real implementations live in libEMGDegl). The shim is literally `eglFoo() { return IMGeglFoo(...); }`.

### libGLESv2.so.1.5.15.3226 — 370 KB real implementation
- NEEDED: `libEMGDegl.so`, `libemgdsrv_um.so`, `libm`, `libpthread`, `libdl`, `libc`
- 142 `gl*` exported functions
- Imports `KEGL*` and `PVRSRV*` from EMGDegl/srv_um (internal handoff API for context/surface/render-state)

### libGLES_CM.so.1.5.15.3226 — 548 KB real implementation
- Same NEEDED set as GLESv2
- 145 `gl*` + the EGL shim symbols (legacy GLES1.x with embedded eglFoo dispatch)

**All three are usable as-is for Qt6 against EGL/GLES2.**

---

## 5. EGL Platform Expectations — How `eglGetDisplay` Picks the Backend

### The mechanism
1. App calls `eglGetDisplay(EGL_DEFAULT_DISPLAY)` → `eglInitialize`.
2. `libEMGDegl.so` calls `PVRSRVCreateAppHintState()` + `PVRSRVGetAppHint("WindowSystem", ...)`.
3. `libemgdsrv_um.so` reads `/etc/powervr.ini` and the `EMGDPVR_<procname>_<key>` env var.
4. INI lookup order, derived from `.rodata` of libemgdsrv_um:
   - Read `/proc/self/cmdline` → take basename → use as INI section header `[<procname>]`.
   - If key not found in `[<procname>]`, fall back to `[default]`.
   - Per-process env var `EMGDPVR_<procname>_<key>` overrides INI.
5. Returned WindowSystem string is `dlopen`ed by libEMGDegl.
6. `dlsym(h, "WSEGL_GetFunctionTablePointer")` grabs the function table → drives display init.

### Strings confirming the mechanism (in libemgdsrv_um.rodata at 0x415e2ff0)
```
r./proc/self/cmdline\0
[default]\0
[%s]\0
default\0
EMGDPVR_%s_%s\0
/etc/powervr.ini\0
```

### Current `/etc/powervr.ini` (verbatim)
```ini
[conform]
ExternalZBufferMode=2
[GTF]
ExternalZBufferMode=2
[oglconform]
ExternalZBufferMode=2
[default]
WindowSystem=/usr/lib/wsegl/libwsegl-hmi.so
```

### Implications for Plan B'''
- Default backend is libwsegl-hmi.so. Confirmed.
- We can add a `[q60nav]` (or whatever our binary is named) section to override.
- We can also use `EMGDPVR_q60nav_WindowSystem=...` env var.
- **But there is nothing useful to override TO** — see Section 8.

### No fbdev / drm direct path
- libEMGDegl strings do NOT mention `EGL_PLATFORM_FBDEV`, `EGL_PLATFORM_GBM`, `EGL_PLATFORM_DRM`, or `EGL_PLATFORM_SURFACELESS_MESA`. This is a pre-EGL-1.5 stack — only the implicit X11/native-window split through WindowSystem dlopen exists.
- No `/dev/fb*` references anywhere in the EGL stack (HMI path uses GTT-mapped buffers managed by emgdhmid).

---

## 6. EMGD-specific Env Vars

`libemgdsrv_um` does exactly one direct `getenv()`-like operation: synthesizing `EMGDPVR_<procname>_<key>` and calling `getenv` on it. There is no static env var name baked in. **Every config option is a powervr.ini key that can also be set as `EMGDPVR_<proc>_<key>` in the environment.**

INI keys identified in `.rodata` of libemgdsrv_um (the SGX tunables; these matter for performance, not correctness):
```
EDMProtectTATest    NumPixelPartitions   NumVertexPartitions
PBSize              GlobalThreshold      PDSThreshold
ZLSThreshold        TAThreshold          MTModePixelThreshold
```

INI key identified in `libEMGDegl`:
```
WindowSystem    (the only one that matters for our purpose)
ExternalZBufferMode / XSize / YSize
```

### "What env vars must I set" answer
**None are required for correctness.** The default INI section gets us through `eglInitialize` provided emgdhmid is running. Recommended (non-required) for cleanliness:
- `EMGDPVR_<myapp>_WindowSystem=/usr/lib/wsegl/libwsegl-hmi.so` — explicit, in case we ever rename the binary or someone edits powervr.ini.

Also relevant for Qt6 eglfs (not from EMGD; these are Qt's):
- `QT_QPA_PLATFORM=eglfs`
- `QT_QPA_EGLFS_INTEGRATION=eglfs_emu`  ← (would have to be a custom backend; the canned eglfs backends are kms, x11, brcm, mali — none fit HMI)
- This is the **deeper architectural risk** of Plan B''' that's not visible in static analysis: Qt's eglfs assumes it can create the native window from a DRM/KMS plane, fbdev framebuffer, or vendor extension (Broadcom/Mali). None of those map cleanly to the HMI socket protocol. **We will likely need a custom Qt eglfs platform backend (a QEglFSDeviceIntegration plugin) that calls into emgdHmiGetNativeDisplay / emgdHmiCreatePixmap rather than KMS.** This is a real piece of code, not a config knob.

---

## 7. DRI/DRM Backend — `libemgdPVR2D_DRIWSEGL.so`

Quick survey — this is the WSEGL we'd want if we had an X server (we don't):

```
NEEDED libEMGD2d, libXfixes, libXau, libXdmcp, libX11, libXext, libdrm, libm, libdl, libc
```

Undefined symbols include `XOpenDisplay`, `XCreateGC`, `DRI2*` proxy calls, `drmOpen`/`drmClose`/`drmGetMagic`. **This backend hard-requires X11 + DRI2.** No X server exists or will exist on our target.

The `/dev/dri/card0`-touching path is exactly `drmOpen("emgd", NULL)` → `drmGetMagic` → call into X server's DRI2Authenticate via the X protocol. Without X, this backend cannot init.

### What we'd need to build to escape the HMI backend
A bare WSEGL plugin that:
1. Opens `/dev/dri/card0` directly (`drmOpen("emgd", NULL)`).
2. Becomes DRM master (or stays auth'd via someone else's master).
3. Allocates a flip chain through PVR2D + `pvrlfb` display controller.
4. Implements the 16-function `WSEGL_FunctionTable`.

This is **doable but non-trivial** (estimated 500–1500 LoC against the Imagination DDK 1.13 PVR2D API). It would require us to either:
- Become DRM master ourselves (means killing emgdhmid → cascade), or
- Get authed by emgdhmid via `drmGetMagic` → `drmAuthMagic` (means cooperating, not bypassing).

**Conclusion: there's no easy escape from the HMI path on this hardware.** We either coexist with emgdhmid, or we write substantial new code.

---

## 8. Alternative WSEGL Backends — What's Available

### Inventory of WSEGL implementations on this rootfs
```
/usr/lib/wsegl/libwsegl-hmi.so       ← HMI socket backend (requires emgdhmid)
/usr/lib/libemgdPVR2D_DRIWSEGL.so    ← X11/DRI2 backend (requires X server)
```

That's it. **Two backends. Both have external dependencies we cannot remove.**

### What's NOT present
- `libemgdPVR2D_BLITWSEGL.so` — referenced as `OPK_FALLBACK` in the build flags but **not shipped**. Would have been a pure-blit (no flip chain) fallback for X-less environments. Its absence is the biggest single forensic finding here. If it existed, Plan B''' would be trivial.
- Any `.bak` / archived / `/opt/*` variant of either backend. We grepped: zero results.
- Any generic PowerVR `libpvrws_FBDEV.so` or `libpvrws_NULL.so`. The Imagination DDK ships these; DENSO removed them.

### Could we substitute a generic PowerVR wsegl-linuxfb?
- **Mainline / stock Imagination PowerVR DDK 1.13** for SGX535 / pc_i686_poulsbo_d0 was an Intel-distributed binary blob with corresponding source for the wsegl backend. Both the stock binaries and the WSEGL source were historically available from Intel's EMGD release archive. If we can locate either:
  - A stock `libemgdPVR2D_BLITWSEGL.so` of the **exact same build version (1.5.15.3226, Feb 27 2013)**, we could drop it in and edit powervr.ini.
  - The WSEGL source from the matching DDK release, we can compile our own against the existing libEMGD2d + libemgdsrv_um.
- Cross-version mixing is **highly unlikely to work**: the PVR services API has versioned ABI between releases. Same build hash is essentially mandatory.
- **Action item:** archive search for "EMGD_1_13" / "EMGD-LINUX-1.13" / "Intel EMGD DDK 1.13" source release. Marketing name was "Crossville Lapis Beta" or "DEH" (DENSO Embedded Host) per the Build-host strings.

---

## 9. Qt eglfs Feasibility — Concrete Assessment

### Path A: Use libwsegl-hmi.so (the GO path)

**Sequence of events when our Qt app calls `eglGetDisplay` + `eglInitialize`:**
1. `libEGL` → `IMGeglInitialize` in libEMGDegl.
2. libEMGDegl reads `/etc/powervr.ini`, finds `WindowSystem=/usr/lib/wsegl/libwsegl-hmi.so`.
3. `dlopen("/usr/lib/wsegl/libwsegl-hmi.so")` → resolves `WSEGL_GetFunctionTablePointer`.
4. libwsegl-hmi's `pfnWSEGL_InitialiseDisplay` is called.
5. It calls `emgdHmiGetNativeDisplay` (in libemgdhmi.so.0) which calls `check_socket()` → `connect("/tmp/.emgdhmid_socket")`.
6. **If emgdhmid is running and accepts:** `WSEGL_SUCCESS`. EGL is initialized. PVR2D context is created via emgdhmid's PVR2D handle. The Qt app can `eglChooseConfig`, `eglCreateContext`, `eglMakeCurrent`, and start drawing.
7. **If emgdhmid is NOT running:** `connect()` fails → wsegl returns `WSEGL_CANNOT_INITIALISE` → `eglInitialize` returns `EGL_FALSE`. App dies.

### Path B: Write a custom Qt eglfs platform backend ("hmi" integration)

Qt's eglfs has `QEglFSDeviceIntegration` plugins (kms-gbm, x11, brcm, mali, etc.). For HMI we'd need:
```cpp
class QEglFSHmiIntegration : public QEglFSDeviceIntegration {
  EGLNativeDisplayType platformDisplay() const override;     // calls emgdHmiGetNativeDisplay
  EGLNativeWindowType  createNativeWindow(...) override;     // calls emgdHmiCreatePixmap
  void destroyNativeWindow(EGLNativeWindowType) override;    // calls emgdHmiDestroyPixmap
  ...
};
```
This **must exist** for Qt6 to drive the HMI WSEGL. There's no built-in eglfs backend that matches the EMGD HMI native-window contract.

**Estimate: 1–2 days of Qt platform plugin work, including build system + cross-compile against MeeGo headers (or emulating them).**

### Path C: Bypass EGL entirely — use raw GLES via emgdhmid's video plane

Not realistic — Qt RHI requires a real EGL context.

### Will `eglGetDisplay(EGL_DEFAULT_DISPLAY) + eglInitialize` "just work"?

**Static-analysis answer: yes, on the following ALL-of conditions:**
- emgdhmid running.
- `/etc/powervr.ini` `[default] WindowSystem` either unchanged or set to `/usr/lib/wsegl/libwsegl-hmi.so`.
- `/dev/dri/card0` exists and is readable by our app's UID (or our app is root).
- The emgd kernel module is loaded (`drmOpen("emgd", NULL)` succeeds).
- A native window can be created — **this is the open question**. The Qt app must construct an `EGLNativeDisplayType` and `EGLNativeWindowType` that the WSEGL backend recognizes. From libwsegl-hmi strings: it expects WSEGLDrawableParams with `ePixelFormat ∈ {ARGB8888, ABGR8888, XRGB8888, RGB565, ARGB1555, ARGB4444}` and an `EMGD_HMI_BUFFER` / `EMGD_VIDEO_BUFFER` / `EMGD_POPUP_BUFFER` / `EMGD_X11_BUFFER` / `EMGD_8BIT_BUFFER` buffer type. The native window construction has to come from `emgdHmiGetNativeDisplay` + `emgdHmiCreatePixmap` — **this is what Path B's plugin wraps.**

**Net: Path A + Path B together = GO. Path A alone (without the platform plugin) is `eglInitialize` succeeds but `eglCreateWindowSurface` fails because Qt can't construct the right native window.**

### DRM master timing

- emgdhmid grabs master at its `main()` (early systemd boot). Confirmed: `drmSetMaster` undefined in emgdhmid.
- Our Qt app **does not** need to be master. The PVR services layer uses `DRM_AUTH` (cookie-based) — `drmGetMagic` is undefined in libemgdsrv_um, meaning srv_um asks the kernel for a magic, then the WSEGL plumbing (via libemgdhmi → emgdhmid socket) gets it auth'd against emgdhmid's master cookie.
- **Don't kill emgdhmid. Don't call SetMaster.** Two simple rules.

---

## 10. Daemon Dependency Graph — Definitive

Discovered nav services in `/lib/systemd/system/` (executables live at `/home/naviwork/system/bin/` which is NOT in this rootfs — it's on a separate partition we haven't extracted):

| Service | ExecStart | After/Requires emgdhmid? |
|---|---|---|
| `nav_hmictrl.service` | `hmictrl_proc "PS_HMIC1"` | **No** — only `nav_pre.target` |
| `nav_display.service` | `display_ps "PS_DISPLAY"` | **No** |
| `nav_navi.service` | `navi_ps "PS_NAVI"` | **No** |
| `nav_dispapf.service` | `dispapf_proc "PS_DISPAPF"` | **No** |
| `nav_camera.service` | `camera_ps "PS_CAMERA"` | **No** |
| `nav_initialscreen.service` | `fis_ps "PS_FIS"` | **Yes** — `After=` + `Wants=` |
| `nav_smng.service` | `smng "PS_OS01"` | **Yes** — `After=emgdhmid.service` |
| `android-start.service` | `/sbin/android.sh` | **Yes** — `Requires=emgdhmid.service` |
| `emgdhmi-test.service` | (test harness) | **Yes** |

**Only `nav_initialscreen`, `nav_smng`, `android-start` depend on emgdhmid.** The 4 daemons we want to kill (hmictrl_proc, navi_ps, display_ps, dispapf_proc) all gate on `nav_pre.target` only. No coupling to emgdhmid.

**emgdhmid itself depends on:** nothing inside this slice (its only `After=` is implicit `DefaultDependencies=yes` which gives `basic.target`).

**Inferred IPC topology for nav daemons:** POSIX message queues (`LimitMSGQUEUE=8192000` on every nav_* service) with channel names PS_HMIC1, PS_NAVI, PS_DISPLAY, PS_DISPAPF, PS_FIS, PS_OS01. These are the DENSO process IDs — totally separate IPC channel from the EGL/HMI stack which uses Unix sockets.

---

## 11. Open Questions for On-device Probe

Static analysis cannot answer these — list for the next hardware boot:

1. **Does emgdhmid run cleanly when nav_smng / nav_initialscreen are not running?** It doesn't depend on them, but it might wait on a handshake. Check with: `systemctl stop nav_smng nav_initialscreen; systemctl status emgdhmid; ls -la /tmp/.emgdhmid_socket; nc -U /tmp/.emgdhmid_socket < /dev/null` and watch behavior.
2. **Does emgdhmid hold DRM master cleanly through a stop-of-all-nav-services event?** Or does it drop master and re-grab it on some signal from smng? Check by `ls /sys/class/drm/card0/master` before/after stopping nav daemons.
3. **Does the GTT have enough free area when nav_initialscreen / nav_smng aren't pre-allocating buffers?** The R1 work logged 3× 953,472 B buffers at fixed GTT offsets — those may be allocated by display_ps. If emgdhmid's `EMGDHMIAPI_GETFRAMEBUFFERSIZE` returns 0 because nothing has called `EMGDHMIAPI_CONFIGUREBUFFERS` yet, our `eglCreateWindowSurface` will fail.
4. **Does our app get auth'd against the emgd DRM master via `drmGetMagic` → `drmAuthMagic` automatically, or do we need emgdhmid to mediate?** Probe by running a minimal `eglGetDisplay`/`eglInitialize`/`eglChooseConfig` test binary as root, then as group `video`, with all nav daemons stopped but emgdhmid running.
5. **What's the `EGLNativeWindowType` that libwsegl-hmi accepts?** The struct layout has slots for `EMGD_HMI_BUFFER` etc., but the actual creation path goes through `emgdHmiCreatePixmap`. We need to log what Qt eglfs would otherwise hand in vs. what the HMI backend dereferences.
6. **Is `/usr/sbin/emgdhmid` started by systemd or by Android init?** `emgdhmid.service` is the unit, but `android-start.service` `Requires=emgdhmid.service` and runs after. Real-world ordering on hardware may differ from the manifest if `/sbin/init android` (Android init) is intercepting.

These map cleanly to a 30-minute on-device probe with the diagnostic rootfs.

---

## 12. Verdict — Plan B''' EGL Stack Viability

| Question | Answer | Confidence |
|---|---|---|
| Can we kill nav_hmictrl / nav_display / nav_navi / nav_dispapf and still init EGL? | **Yes, IF emgdhmid stays alive.** | High (static) |
| Can we run EGL with emgdhmid dead? | **No, not without writing a new WSEGL backend (1–3 weeks of work) or finding the stock libemgdPVR2D_BLITWSEGL.so.** | High (static) |
| Will `QT_QPA_PLATFORM=eglfs` work out of the box? | **No — needs a custom QEglFSDeviceIntegration plugin (1–2 days).** | High (static) |
| Does our app need to be DRM master? | **No — emgdhmid holds master; we get auth'd via PVR services magic.** | High (static) |
| Will emgdhmid survive the nav daemons being killed? | **Probably yes, but unverified.** | Medium (needs probe) |
| Will the GTT have buffers ready, or do we need to drive `EMGDHMIAPI_CONFIGUREBUFFERS`? | **Unverified — likely we need to call it.** | Low (needs probe) |

**Bottom line for the decision:** Plan B''' is alive. Estimated incremental effort vs. the original plan:
- +0 days for the EGL ABI itself — it works as-is.
- +1–2 days for a Qt HMI eglfs platform plugin.
- +0.5 days for the on-device probe to answer the open questions above.

**Recommendation:** Proceed to write the Qt HMI eglfs platform plugin, but **gate the implementation on the on-device probe** that verifies emgdhmid survives the nav daemon kill and provides usable framebuffers. Spending 1–2 days of plugin code before the probe answers Q1–Q3 risks the plugin being against an unusable runtime.

---

## Appendix A — Tools used
- `file` — confirmed ELF32 i386
- `/usr/bin/strings` (macOS host) — works on i386 ELF
- `/usr/bin/nm` (macOS host) — works on i386 ELF dynamic symbols
- `/usr/bin/objdump` (macOS host) — recognizes `elf32-i386` format natively; disassembly, .rodata dumps all functional. No Docker needed.

## Appendix B — Key file paths in this rootfs

- `/tmp/dsu-slot-a/etc/powervr.ini` — EGL backend selector
- `/tmp/dsu-slot-a/etc/ld.so.conf.d/emgdhmi.conf` — adds `/usr/lib/wsegl` to loader path
- `/tmp/dsu-slot-a/usr/sbin/emgdhmid` — the daemon (must run)
- `/tmp/dsu-slot-a/usr/lib/wsegl/libwsegl-hmi.so` — the only usable WSEGL
- `/tmp/dsu-slot-a/usr/lib/libemgdhmi.so.0.1.0` — the socket client
- `/tmp/dsu-slot-a/usr/bin/egl` — factory EGL probe tool; useful for sanity check on hardware (`./egl` should output framebuffer info if emgdhmid is healthy)
- `/tmp/dsu-slot-a/lib/systemd/system/{emgdhmid,nav_*}.service` — service definitions
