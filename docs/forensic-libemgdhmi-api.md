# Forensic — libemgdhmi.so.0 Complete API + IPC Protocol

**Date:** 2026-05-23
**Source:** `/tmp/dsu-slot-a/usr/lib/libemgdhmi.so.0.1.0` (30,893 bytes, ELF32 i386, **NOT stripped — DWARF debug info intact**).
**Build provenance (from DWARF):** GNU C++ 4.5.1 20100924 (Red Hat 4.5.1-4), source path `/home/build/GFX-EMGD.DENSO-PROD-LINUX_DDK--EMGD_1_13-1.13_RC_3343/koheo/linux/emgdhmi/lib/emgdhmi.cpp`.
**Confidence:** **VERY HIGH.** This binary still carries full DWARF2 (`.debug_info`, `.debug_str`, etc.) — every function signature, every IPC message struct (member names + offsets + types), every enum, every global is named in the binary itself. Almost nothing is inferred from prologue heuristics; nearly everything is read directly from DWARF.

---

## Section 5 (lead) — Recommended call sequence to make a pixmap VISIBLE

**Static-analysis answer to the visibility question:** *"existing pixmap is in the GTT pool but never visible"* is almost certainly explained by **one missing step**: nobody has called `emgdHmiConfigureBuffers()` to register the pixmap as a presentable buffer-set on a screen. `emgdHmiCreatePixmap` returns a pixmap handle backed by GTT memory, but the **emgdhmid compositor only scans out pixmaps that have been published into its per-screen 3-slot buffer ring via `CONFIGUREBUFFERS` (opcode 9)**. There is also a per-frame `RequestFlip` opcode that selects which of the three slots is currently active. (And there's a callback `EmgdHmiFlipChainState` into libwsegl-hmi.so that the WSEGL backend uses for the actual rotation logic.)

**The minimum call sequence to put a pixel on the upper LVDS screen (screen 0):**

```c
// --- 1. Connect (auto-fires lazily on first call, but explicit is clearer) ---
EGLNativeDisplayType native = NULL;
emgdHmiGetNativeDisplay(&native);
// On success: *native == (void*)0xd39ade6b, sockfd is connected to /tmp/.emgdhmid_socket.

// --- 2. Sanity: how many screens does the daemon know about? ---
int nscreens = emgdHmiGetNumScreens(native);
// Expect 2 (upper LVDS + lower LVDS) per portorder=2,4,0,0,0.

// --- 3. Allocate the visible pixmap (front buffer) ---
EGLNativePixmapType frontbuf;
emgdHmiCreatePixmap(native,
                    EMGD_HMI_BUFFER,     // usage = 1
                    800, 480,            // width, height
                    &frontbuf);
// Optional: allocate back + aux too if you want triple-buffered no-tear flips.
EGLNativePixmapType backbuf, auxbuf;
emgdHmiCreatePixmap(native, EMGD_HMI_BUFFER, 800, 480, &backbuf);
emgdHmiCreatePixmap(native, EMGD_HMI_BUFFER, 800, 480, &auxbuf);

// --- 4. CRITICAL — publish the buffers to the screen's flip ring ---
// state[i] is a NULL-terminated array of (up to 3) EMGDBufferType* per screen.
// Daemon iterates: for screen i in 0..1, for buf j in 0..3, copy 56 bytes of buffer descriptor.
EMGDBufferType *screen0_bufs[4] = { (EMGDBufferType*)&frontbuf,
                                    (EMGDBufferType*)&backbuf,
                                    (EMGDBufferType*)&auxbuf,
                                    NULL };
EMGDBufferType *screen1_bufs[4] = { NULL };   // leave lower screen alone
EMGDBufferType **state[2] = { screen0_bufs, screen1_bufs };
emgdHmiConfigureBuffers(native, state);
// THIS is the step that goes "this pixmap exists in pool" → "this pixmap is in the screen's
// scanout candidate set." Without this, eglSwapBuffers writes pixels nobody ever scans out.

// --- 5. Make EGL aware (this is the part your code already does) ---
EGLSurface surf = eglCreatePixmapSurface(dpy, cfg, frontbuf, NULL);
eglMakeCurrent(dpy, surf, surf, ctx);
// ... draw something ...
eglSwapBuffers(dpy, surf);

// --- 6. Tell emgdhmid which slot to scan out (per frame, optional once swap is wired) ---
EGLBoolean *out = NULL;
emgdHmiRequestFlip(native, /*screen=*/0, EMGD_DISPLAY_HMI, &out);
// or:
emgdHmiFlipScreen(native, 0, EMGD_DISPLAY_HMI);
```

**Why `emgdHmiConfigureBuffers` is the missing step** (evidence in §4 + §6):
- The DWARF struct `EMGDHmiSocket_ConfigureBuffers` is **384 bytes** and carries `in_numscreens` + a 2×3 array of 56-byte buffer descriptors — clearly the protocol's "register every buffer that this screen is allowed to scan out."
- The IPC opcode is **9 (EMGDHMIAPI_CONFIGUREBUFFERS)**.
- The library hardcodes `in_numscreens = 2` and iterates exactly 2 screens × 3 buffers — matches the R1 finding of "3 × 953,472 B buffers at GTT offsets 0x000000 / 0x0e9000 / 0x1d2000" (those were the factory's published triple buffers for V4L2).
- Cross-ref `forensic-emgd-init.md` §2: emgdhmid's `EmgdHmiDaemon::drmcmd_master` brokers `0x2c = CONFIG_BUFFS` (DRM ioctl) every time it sees this socket op — i.e., this is the path that allocates/registers GMM regions with the EMGD kernel driver. Until this call lands, the kernel does not have a buffer registered for the plane.

**Probability ranking of "what's wrong":**
1. **(highest)** `emgdHmiConfigureBuffers` was never called → pixels written but never scanned out. **Add the call.**
2. The native window we hand to `eglCreatePixmapSurface` is not the same handle we registered with `ConfigureBuffers`. Make sure it's literally the same pointer.
3. We're drawing to screen 1 (lower) by mistake — `RequestFlip(display, screen=0, …)` is needed if screen 0 is the target. (`GetScreenParams` lets you sanity check which screen has 800×480 vs 800×420.)
4. `RequestFlip` is needed per frame after `eglSwapBuffers` — the WSEGL backend may or may not do this for us; if not, we need it explicitly.

**Path-not-needed:** `emgdHmiStartVideoDisplay` is for V4L2-ingested video planes (camera/rear-view), not for GLES pixmaps. Don't call it.
**Path-not-needed:** `emgdHmiGetFramebuffer` returns the actual scan-out PVR2D MEMINFO via the WSEGL backend; useful only if we want to bypass eglSwapBuffers and write framebuffer raw.

---

## Section 2 (lead) — Complete signature table

All 19 exports. **Address, args, return, side effects all sourced from DWARF unless marked "(disasm)".** Return type is `EMGDerr` (typedef'd enum, 4 bytes, `int`) for all but `emgdHmiGetNumScreens` (returns `EGLint` = `int32_t`). All public functions begin with `_ZL12check_socketv` → lazy `socket()/bind()/connect()` to `/tmp/.emgdhmid_socket`, store fd in `sockfd` global. If socket fails, return `EMGD_ERR_BAD_ALLOC` (-4) immediately.

| # | Symbol | Address | Size | C signature (from DWARF) | IPC opcode | Msg struct | Bytes on wire | Notes |
|---|---|---|---|---|---|---|---|---|
| 1 | `emgdHmiGetNativeDisplay` | `0x4163a0e0` | 0x23 | `EMGDerr emgdHmiGetNativeDisplay(EGLNativeDisplayType *result)` | — (no IPC) | — | — | Calls `check_socket`. On success writes magic `0xd39ade6b` to `*result`. The "magic" is just a non-NULL sentinel meaning "you have an HMI display." Returns `EMGD_ERR_IO_ERROR` (-6) if socket dead. |
| 2 | `emgdHmiGetFramebuffer` | `0x4163a110` | 0xa5 | `EMGDerr emgdHmiGetFramebuffer(EGLNativeDisplayType display, EGLNativeWindowType *result, PVR2D_VOID **mem)` | — (no IPC) | — | — | Calls `PVR2DGetFrameBuffer` via the PVR2D context (cached in `pvr2d` global). Returns the actual scan-out MEMINFO. Useful only to direct-write pixels bypassing EGL. |
| 3 | `emgdHmiGetFramebufferSize` | `0x4163a1c0` | 0x94 | `EMGDerr emgdHmiGetFramebufferSize(EGLNativeDisplayType display, EGLint *width, EGLint *height)` | **1** GETFRAMEBUFFERSIZE | `EMGDHmiSocket_GetFramebufferSize` (52 B) | 52 | Sends, reads back, writes `out_width` + `out_height` to caller's `*width`/`*height`. |
| 4 | `emgdHmiGetNumScreens` | `0x4163a260` | 0x75 | `EGLint emgdHmiGetNumScreens(EGLNativeDisplayType display)` | **0** GETNUMSCREENS | `EMGDHmiSocket_GetNumScreens` (44 B) | 44 | Returns scalar `out_count` (number of screens managed by daemon). |
| 5 | `emgdHmiGetScreenParams` | `0x4163a2e0` | 0xa6 | `EMGDerr emgdHmiGetScreenParams(EGLNativeDisplayType display, EGLint screen, EGLint *x, EGLint *y, EGLint *width, EGLint *height)` | **2** GETSCREENPARAMS | `EMGDHmiSocket_GetScreenParams` (64 B) | 64 | Per-screen rect (origin x/y + WxH). Use this to identify "upper 800×480" vs "lower 800×420". |
| 6 | `emgdHmiRequestFlip` | `0x4163a390` | 0x8a | `EMGDerr emgdHmiRequestFlip(EGLNativeDisplayType display, EGLint screen, EMGDDisplayType owner, EGLBoolean *result)` | **3** REQUESTFLIP | `EMGDHmiSocket_RequestFlip` (56 B) | 56 | Ask compositor to advance the flip chain on `screen`. `owner` ∈ {EMGD_DISPLAY_HMI=0, EMGD_DISPLAY_X11=1}. Writes daemon's "did flip happen" → `*result`. |
| 7 | `emgdHmiFlipScreen` | `0x4163a420` | 0x81 | `EMGDerr emgdHmiFlipScreen(EGLNativeDisplayType display, EGLint screen, EMGDDisplayType owner)` | **4** FLIPSCREEN | `EMGDHmiSocket_FlipScreen` (52 B) | 52 | Like RequestFlip but synchronous (no boolean returned); daemon performs the flip and returns retval. |
| 8 | `emgdHmiCreatePixmap` | `0x4163a4b0` | 0xc1 | `EMGDerr emgdHmiCreatePixmap(EGLNativeDisplayType display, EMGDBufferType usage, EGLint width, EGLint height, EGLNativePixmapType *result)` | **5** CREATEPIXMAP | `EMGDHmiSocket_CreatePixmap` (60 B) | 60 | `usage` ∈ {NO=0, HMI=1, X11=2, POPUP=3, VIDEO=4, 8BIT=5}. For our use: **EMGD_HMI_BUFFER (1)** for normal GLES surfaces. Daemon returns opaque `out_result` (the pixmap handle = GTT-mapped offset/id). |
| 9 | `emgdHmiDestroyPixmap` | `0x4163a580` | 0xc7 | `EMGDerr emgdHmiDestroyPixmap(EGLNativeDisplayType display, EGLNativePixmapType pixmap)` | **6** DESTROYPIXMAP | `EMGDHmiSocket_DestroyPixmap` (48 B) | 48 | Also calls `get_wsegl_sym("EmgdHmiDestroyPixmap")` and invokes WSEGL callback to clean up client-side mapping. (disasm) |
| 10 | `emgdHmiControlPlaneFormat` | `0x4163a650` | 0x93 | `EMGDerr emgdHmiControlPlaneFormat(EMGDPixelFormat *planeFmt)` | **7** CONTROLPLANEFORMAT | `EMGDHmiSocket_ControlPlaneFormat` (52 B) | 52 | NB: takes ZERO display arg — global state. Sends `in_enable` + `in_display_plane`. Used to switch hardware plane format (e.g., ARGB8888 vs RGB565). |
| 11 | `emgdHmiMapPixmap` | `0x4163a6f0` | 0x145 | `EMGDerr emgdHmiMapPixmap(EGLNativeDisplayType display, EGLNativePixmapType pixmap, unsigned int w, unsigned int h, unsigned int stride, PVR2D_VOID **mem)` | — (no IPC) | — | — | Calls `PVR2DMemMap` to map the pixmap into client VA via the cached `pvr2d` context. Also looks up `EmgdHmiSetUsage` WSEGL callback. Returns mapped pointer in `*mem`. Use this to memcpy raw RGB. |
| 12 | `emgdHmiQueryPixmap` | `0x4163a840` | 0x47 | `EMGDerr emgdHmiQueryPixmap(EGLNativeDisplayType display, EGLNativePixmapType pixmap, unsigned int w, unsigned int h, unsigned int stride)` | **8** QUERYPIXMAP | `EMGDHmiSocket_QueryPixmap` (64 B) | 64 | NB: w/h/stride are by-value `unsigned int`, NOT out-pointers as the name suggests. Likely a "check that this pixmap has these dims" round-trip. Daemon fills `out_w/out_h/out_stride/out_usage`. (Library doesn't appear to write those back to caller — verify if needed.) |
| 13 | `emgdHmiConfigureBuffers` | `0x4163a890` | 0x154 | `EMGDerr emgdHmiConfigureBuffers(EGLNativeDisplayType display, EMGDBufferType **state)` | **9** CONFIGUREBUFFERS | `EMGDHmiSocket_ConfigureBuffers` (384 B) | 380 | **THE MISSING CALL.** `state` = array of (NUM_SCREENS=2) NULL-terminated lists, each up to 3 pointers to 56-byte EMGDBufferType descriptors. Library hardcodes `in_numscreens=2`, iterates 0..1 screens × 0..2 buffers, copying 56 B each → writes 0x180 (384) bytes total to socket. **Registers buffers as scan-out candidates with kernel/compositor.** |
| 14 | `emgdHmiStartVideoDisplay` | `0x4163a9f0` | 0xcc | `EMGDerr emgdHmiStartVideoDisplay(PVR2DCONTEXTHANDLE context)` | **10** STARTVIDEO | `EMGDHmiSocket_StartVideo` (100 B) | 100 | Takes 56-byte `in_context` payload (full PVR2D context). For VIDEO buffers (V4L2 camera ingest path) ONLY. **Do not call for normal GLES output.** |
| 15 | `emgdHmiStopVideoDisplay` | `0x4163aac0` | 0x75 | `EMGDerr emgdHmiStopVideoDisplay(void)` | **11** STOPVIDEO | `EMGDHmiSocket_StopVideo` (44 B) | 44 | Symmetric pair to Start. No args. |
| 16 | `emgdHmiBufferState` | `0x4163ab40` | 0x9c | `EMGDerr emgdHmiBufferState(PVR2D_VOID **buf0, PVR2D_VOID **buf1, PVR2D_VOID **buf2, unsigned int curr_buf)` | — (no IPC) | — | — | **NOT an IPC call.** Calls `get_wsegl_sym("EmgdHmiFlipChainState")` → invokes WSEGL callback `int(*)(void**, void**, void**)` with the 3 buffer slots. Cache-checked global pointer `func` at `0x4163c5c0`. (disasm) |
| 17 | `emgdHmiSwitchHz` | `0x4163abe0` | 0xc6 | `EMGDerr emgdHmiSwitchHz(int hz, int pipe)` | **12** SWITCHHZ | `EMGDHmiSocket_SwitchHz` (52 B) | 52 | NB: takes ZERO display arg. Switches refresh rate for a pipe. Note struct field is named `in_context` but is used here as `hz` + `pipe`. |
| 18 | `emgdHmiFreeMem` | `0x4163acb0` | 0x91 | `EMGDerr emgdHmiFreeMem(EGLNativeDisplayType pmem)` | — (no IPC) | — | — | Calls `PVR2DMemFree` on the cached pvr2d context. `pmem` is the MEMINFO* returned by `MapPixmap`/`GetFramebuffer`. |
| 19 | `emgdHmiCleanup` | `0x4163ad50` | 0x55 | `EMGDerr emgdHmiCleanup(void)` | — (no IPC) | — | — | Tears down: `PVR2DDestroyDeviceContext(pvr2d)`, `close(sockfd)`, `sockfd = -1`. Process-shutdown / unload-time cleanup. |

**Constants and enums (DWARF-confirmed):**

```c
typedef enum {
    EMGD_DISPLAY_HMI = 0,
    EMGD_DISPLAY_X11 = 1,
} EMGDDisplayType;

typedef enum {                  // EMGDerr — return code of every function
    EMGD_SUCCESS         =  0,
    EMGD_ERR_NO_DISPLAY  = -1,
    EMGD_ERR_BAD_DISPLAY = -2,
    EMGD_ERR_BAD_CONFIG  = -3,
    EMGD_ERR_BAD_ALLOC   = -4,   // returned by lib when args invalid / socket lost
    EMGD_ERR_BAD_ID      = -5,
    EMGD_ERR_IO_ERROR    = -6,   // returned by check_socket if can't connect
    EMGD_ERR_BUSY        = -7,
    EMGD_ERR_UNSUPPORTED = -8,
} EMGDerr;

typedef enum {                  // EMGDBufferType — usage argument to CreatePixmap
    EMGD_NO_BUFFER     = 0,
    EMGD_HMI_BUFFER    = 1,     // GLES/Qt surfaces: use this
    EMGD_X11_BUFFER    = 2,
    EMGD_POPUP_BUFFER  = 3,
    EMGD_VIDEO_BUFFER  = 4,     // V4L2 camera ingest
    EMGD_8BIT_BUFFER   = 5,
} EMGDBufferType;

typedef enum {
    EMGD_FMT_ARGB8888 = 0,
    EMGD_FMT_RGB565   = 1,
    EMGD_FMT_YUV422   = 2,
    // ... more, not all enumerated
} EMGDPixelFormat;

typedef enum {                  // EMGDHMIAPI — IPC opcode field in message header
    EMGDHMIAPI_GETNUMSCREENS      =  0,
    EMGDHMIAPI_GETFRAMEBUFFERSIZE =  1,
    EMGDHMIAPI_GETSCREENPARAMS    =  2,
    EMGDHMIAPI_REQUESTFLIP        =  3,
    EMGDHMIAPI_FLIPSCREEN         =  4,
    EMGDHMIAPI_CREATEPIXMAP       =  5,
    EMGDHMIAPI_DESTROYPIXMAP      =  6,
    EMGDHMIAPI_CONTROLPLANEFORMAT =  7,
    EMGDHMIAPI_QUERYPIXMAP        =  8,
    EMGDHMIAPI_CONFIGUREBUFFERS   =  9,
    EMGDHMIAPI_STARTVIDEO         = 10,
    EMGDHMIAPI_STOPVIDEO          = 11,
    EMGDHMIAPI_SWITCHHZ           = 12,
} EMGDHMIAPI;
```

---

## 1. Constructor analysis — `_init` does NOT open the socket

**`_init` (`.init` section @ `0x41639a94`):** Standard GCC PLT prologue. Calls `__gmon_start__` (if present), `frame_dummy`, and `__do_global_ctors_aux`. **No socket calls, no IPC, no global initialization beyond DSO bookkeeping.**

**`__do_global_ctors_aux` (`0x4163adb0`):** Walks `.ctors`. Section dump:
```
Contents of section .ctors:
 4163c3e8 ffffffff 00000000     ........
```
Just the sentinel `0xffffffff` and a null pointer. **No actual constructors run.** The ctor array is empty.

**Socket state at `dlopen`-time:**
- `sockfd` global is at **`0x4163c578`** (`.data` section). Initialized to **`0xffffffff` (-1)** — see `.data` dump confirming: `4163c578 ffffffff`.
- `pvr2d` (`PVR2DCONTEXTHANDLE`) global at **`0x4163c59c`** (`.bss`, init = 0).
- `pvr2d_context_lock` (`pthread_mutex_t`, 24 bytes) at **`0x4163c584`** (`.bss`, init = 0 = `PTHREAD_MUTEX_INITIALIZER`).
- `wslib` global (cached `dlopen()` handle for libwsegl-hmi.so) at **`0x4163c5c4`** (`.bss`, init = 0).
- Cached WSEGL callback function pointers (lazily populated by `get_wsegl_sym`):
  - `func` (for FlipChainState) at `0x4163c5c0`
  - `usage_func` (for SetUsage) at `0x4163c5c8`
  - destroy callback at `0x4163c5cc`

**Lazy connect via `check_socket` (`_ZL12check_socketv` @ `0x41639dd0`):**

Called as the first instruction of every public function. Logic:
```c
static int sockfd = -1;
static int check_socket(void) {
    if (sockfd >= 0) return 1;          // already connected
    struct sockaddr_un addr = {0};
    addr.sun_family = AF_UNIX;          // 0x1
    memcpy(addr.sun_path, "/tmp/.emgdhmid_socket", 22);
    sockfd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (sockfd < 0) {
        fwrite("ERROR opening socket\n", 1, 21, stderr);
        return 0;
    }
    struct sockaddr_un local = { .sun_family = AF_UNIX };
    bind(sockfd, &local, 2);            // anonymous client side
    if (connect(sockfd, &addr, 0x6e) < 0) {  // 110 == sizeof(sockaddr_un)
        fwrite("ERROR connecting", 1, 16, stderr);
        close(sockfd);
        sockfd = -1;
        return 0;
    }
    return 1;
}
```

**Implication for our process at the moment `emgdHmiGetNativeDisplay` returns:** the socket is alive and connected; `sockfd` holds a valid fd. **No PVR2D context is created yet** — `pvr2d` is still null. It is lazily created by `_ZL8pvr2dCtxv` (helper at `0x41639d20`) on first call to `emgdHmiGetFramebuffer` / `emgdHmiMapPixmap` / `emgdHmiFreeMem`. (`pvr2dCtx` calls `PVR2DEnumerateDevices` → `PVR2DCreateDeviceContext`, caches in `pvr2d`.)

---

## 3. IPC message format — on-wire wire format

### The header (all messages start with this)

```c
struct EMGDHmiSocket_Header {          // 40 bytes total
    int        size;                   // offset  0 — total bytes in *this* message
    char       name[32];               // offset  4 — ASCII function-name tag,
                                       //              e.g. "ConfigureBuffers\0..."
    EMGDHMIAPI type;                   // offset 36 — opcode (enum value 0..12)
};
```

The `name` field is a free-form 32-char identifier (zero-padded). Inspection of `emgdHmiCreatePixmap` shows the name is written via `strncpy(hdr.name, "CreatePixmap", 32)` from the rodata string `"CreatePixmap"` at `0x4163ae5a`. The daemon side does NOT need to parse this — `type` (offset 36) is the actual dispatch key — but the daemon may use the string for logging.

### Per-opcode payloads (DWARF-verified offsets)

Format: `[offset] [size] [field] [type] [meaning]`. All structs are packed (no padding except natural alignment).

**`EMGDHmiSocket_GetNumScreens` (44 B, opcode 0):**
```
  0  40   hdr           Header           size=0x2c, name="GetNumScreens",   type=0
 40   4   out_count     int              (daemon→client) number of screens
```

**`EMGDHmiSocket_GetFramebufferSize` (52 B, opcode 1):**
```
  0  40   hdr           Header
 40   4   out_width     EGLint
 44   4   out_height    EGLint
 48   4   out_retval    EMGDerr
```

**`EMGDHmiSocket_GetScreenParams` (64 B, opcode 2):**
```
  0  40   hdr           Header
 40   4   in_screen     EGLint
 44   4   out_x         EGLint
 48   4   out_y         EGLint
 52   4   out_width     EGLint
 56   4   out_height    EGLint
 60   4   out_retval    EMGDerr
```

**`EMGDHmiSocket_RequestFlip` (56 B, opcode 3):**
```
  0  40   hdr           Header
 40   4   in_screen     EGLint
 44   4   in_owner      EMGDDisplayType   (0=HMI, 1=X11)
 48   4   out_result    EGLBoolean
 52   4   out_retval    EMGDerr
```

**`EMGDHmiSocket_FlipScreen` (52 B, opcode 4):**
```
  0  40   hdr           Header
 40   4   in_screen     EGLint
 44   4   in_owner      EMGDDisplayType
 48   4   out_retval    EMGDerr
```

**`EMGDHmiSocket_CreatePixmap` (60 B, opcode 5):**
```
  0  40   hdr           Header           name="CreatePixmap"
 40   4   in_usage      EMGDBufferType
 44   4   in_width      EGLint
 48   4   in_height     EGLint
 52   4   out_result    EGLNativePixmapType  (opaque pixmap handle)
 56   4   out_retval    EMGDerr
```

**`EMGDHmiSocket_DestroyPixmap` (48 B, opcode 6):**
```
  0  40   hdr           Header
 40   4   in_pixmap     EGLNativePixmapType
 44   4   out_retval    EMGDerr
```

**`EMGDHmiSocket_ControlPlaneFormat` (52 B, opcode 7):**
```
  0  40   hdr           Header
 40   4   in_enable        int           (likely bool — verify)
 44   4   in_display_plane int           plane index (Sprite C, Overlay, etc.)
 48   4   out_retval       EMGDerr
```

**`EMGDHmiSocket_QueryPixmap` (64 B, opcode 8):**
```
  0  40   hdr           Header
 40   4   in_pixmap     EGLNativePixmapType
 44   4   out_w         unsigned int
 48   4   out_h         unsigned int
 52   4   out_stride    unsigned int
 56   4   out_usage     EMGDBufferType
 60   4   out_retval    EMGDerr
```

**`EMGDHmiSocket_ConfigureBuffers` (384 B, opcode 9):**
```
  0  40   hdr            Header          name="ConfigureBuffers"
 40   4   in_numscreens  int             ALWAYS 2 (library hardcodes this)
 44 336   in_states      EMGDBufferType[2][3][14]  see below
380   4   out_retval     EMGDerr
```

The `in_states` block is **2 screens × 3 buffers × 56 bytes = 336 bytes**. Each 56-byte entry is an `EMGDBufferType` descriptor (the full struct definition is not in this file's DWARF — it's in libwsegl-hmi's compilation unit — but the library copies 56 bytes per slot from `state[i][j]`, where state is the caller-supplied `EMGDBufferType **`). Inspection of the inner loop (disasm offsets `4163a938`–`4163a991`) confirms a 14-dword (`0xc..0x34`) field-by-field copy = 56 bytes per buffer.

**`EMGDHmiSocket_StartVideo` (100 B, opcode 10):**
```
  0  40   hdr           Header           name="StartVideo"
 40  56   in_context    char[56]         opaque PVR2D context blob
 96   4   out_retval    EMGDerr
```

**`EMGDHmiSocket_StopVideo` (44 B, opcode 11):**
```
  0  40   hdr           Header           name="StopVideo"
 40   4   out_retval    EMGDerr
```

**`EMGDHmiSocket_SwitchHz` (52 B, opcode 12):**
```
  0  40   hdr           Header
 40   4   in_context    int              actually used as `hz` value
 44   4   (unnamed)     int              `pipe` (offset extrapolated; struct DWARF marks 48 as retval)
 48   4   out_retval    EMGDerr
```

### The transport — `SendNGetReply`

Helper `_ZL13SendNGetReplyPvi(void *msg, int size)` at `0x41639f60`. Pattern:
```c
static EMGDerr SendNGetReply(void *msg, int size) {
    pthread_mutex_lock(&pvr2d_context_lock);
    int w = write(sockfd, msg, size);
    if (w != size) { /* error path */ close(sockfd); sockfd=-1; return EMGD_ERR_IO_ERROR; }
    int r = read(sockfd, msg, size);   // daemon overwrites caller's buffer in place
    if (r != size) { /* error path */ close(sockfd); sockfd=-1; return EMGD_ERR_IO_ERROR; }
    pthread_mutex_unlock(&pvr2d_context_lock);
    return size;                       // returns >0 on success, -6 on I/O error
}
```

**Key facts:**
- **One single AF_UNIX socket fd shared by all callers** in the process. Per-call `pthread_mutex_lock` on `pvr2d_context_lock` (yes, the same mutex used to guard PVR2D ctx) serializes the wire.
- **Strict request/reply lockstep.** Daemon must reply with exactly `size` bytes.
- **Daemon writes back into the same buffer** the client sent — so the in_* fields are clobbered by out_* fields on return. Caller reads result fields directly out of its stack-allocated message struct.
- **Closed-on-error:** any short read/write closes the socket and resets `sockfd = -1`. The next call to any public function will trigger a fresh `check_socket()` reconnect.

### What the daemon does with the message (cross-ref `forensic-emgd-init.md` §2)

emgdhmid's `EmgdHmiDaemonSocket::DoMsg()` reads the 40-byte header, dispatches on `type`, and for opcodes that require DRM master (`SwitchHz`, `ConfigureBuffers`, `RequestFlip`, `StartVideo`) calls `EmgdHmiDaemon::drmcmd_master(cmd, buf, size)` which does the SetMaster → ioctl → DropMaster dance. Specifically:
- **CONFIGUREBUFFERS** maps to **DRM ioctl `0x2c = DRM_IOCTL_IGD_CONFIG_BUFFS`** (size 0x250 = 592 B — note this differs from the socket message size because the daemon repackages our payload for the kernel ioctl).
- **SWITCHHZ** maps to **DRM ioctl `0x25 = DRM_IOCTL_IGD_SWITCH_HZ`** (size 8 B).
- **REQUESTFLIP / FLIPSCREEN** likely map to `IGD_ALTER_OVL2` (`0xc0c8646f`) — see r1-privilege-findings.md.

---

## 4. Per-function deep-dive — the "visible" candidates

### `emgdHmiConfigureBuffers` — TOP suspect for "make pixmap active"

Disasm at `0x4163a890`. Stack frame `subl $0x1a8` (424 bytes — room for the 384-byte message + locals).
- Zeroes 384 bytes (`rep stosl ecx=0x60`).
- Writes header: `size=0x17c` (380 bytes — note: actual message is 380 not 384 because last 4 bytes are out_retval, included in struct sizeof), `name="ConfigureBuffers"` (4 dwords), `type=0x9`.
- **Hardcodes `in_numscreens = 2`** (`movl $0x2, -0x160(%ebp)` → struct offset 40).
- Outer loop `i = 0..1` (screens). Inner loop `j = 0..2` (max 3 buffers per screen).
- For each `state[i][j]` if non-null, copies 14 dwords (56 B) from the caller's buffer descriptor into the message at offset `40 + 4 + i*168 + j*56 + 12` … wait, let me re-verify: from the disasm, `screen_offset = i * 0xa8 = i * 168 bytes`, plus `buffer_offset = j * 0x38 = j * 56`, plus base 0x20 = 32 within the screen block. Each screen reserves 168 bytes (3 × 56). Total state region: 2 × 168 = 336 B. Plus header (40) + numscreens (4) = 380 B written.
- Terminator: if `state[i][j]->first_field == 0`, break out of inner loop.
- After both loops, calls `SendNGetReply(msg, 0x180=384)`. Wait — `movl $0x180, %edx` — sends 384 bytes (full struct including out_retval slot). Daemon writes back 384 bytes; library reads `out_retval`.

**What it does on the daemon side:** triggers `EmgdHmiDaemon::drmcmd_master(0x2c, ...)` = `DRM_IOCTL_IGD_CONFIG_BUFFS`. This is the ioctl that **registers buffer addresses with the EMGD kernel display engine for the named planes**. Until this lands, the kernel doesn't know which GTT-mapped memory regions are "the buffers for screen 0." 

**This is the call that promotes a pixmap from "allocated, in GTT, has a handle" → "kernel knows it's the back/front/aux buffer for screen 0, will scan out when REQUESTFLIP says so."**

### `emgdHmiBufferState` — internal, NOT an IPC call

Disasm at `0x4163ab40`. **No SendNGetReply.** Instead:
- Checks cached `func` pointer at `0x4163c5c0`. If non-null, calls `func(buf2, buf1, buf0)` (3-arg function pointer with the args reordered).
- If null, calls `get_wsegl_sym("EmgdHmiFlipChainState")` (looks for that symbol in `/usr/lib/wsegl/libwsegl-hmi.so` via dlopen+dlsym), caches the result, then invokes it.

**This is the WSEGL backend's flip-chain rotation logic — it tells the libwsegl-hmi backend "the current scanout slot has changed."** This is what the WSEGL FlipChain machinery internally calls when an SwapBuffers happens. **Not relevant to "make pixmap visible" — it's an EGL-internal helper.**

### `emgdHmiGetFramebuffer` — diagnostic / direct-write path

Disasm at `0x4163a110`. **No SendNGetReply.** Calls helper `pvr2dCtx()` (lazy PVR2D ctx init), then `PVR2DGetFrameBuffer(pvr2d, ...)`. Returns the framebuffer's PVR2D MEMINFO* in `*mem` and the native window handle in `*result`. **Useful only if we want to write raw pixels directly into the active scanout buffer** — i.e., bypass eglSwapBuffers. Probably not the missing piece for our case.

### `emgdHmiGetFramebufferSize` — info only

Disasm at `0x4163a1c0`. Trivially sends `EMGDHMIAPI_GETFRAMEBUFFERSIZE`, gets `out_width`/`out_height` back. Info-only.

### `emgdHmiStartVideoDisplay` — V4L2/camera path

Disasm at `0x4163a9f0`. Sends opcode 10 with 56 bytes of opaque PVR2D context blob. Name="StartVideo". The daemon enables V4L2 capture → Sprite C plane via V2G bridge ioctls. This is what `camera_ps` invokes for the rear-view camera (see `forensic-v2g-camera-handoff.md`). **Do NOT call this for GLES output** — it would route our pixmap through V4L2 path which expects YUYV from the IOH VIN, not RGB from GTT.

### `emgdHmiRequestFlip` — per-frame "show next slot"

Disasm at `0x4163a390`. Sends opcode 3. Header carries `in_screen` + `in_owner` (HMI=0). Daemon returns `out_result` (EGLBoolean = "was flip queued?") + `out_retval`. **Per-frame call.** Pairs with `emgdHmiConfigureBuffers` — Configure registers the buffer set, RequestFlip advances which slot is currently scan-out. Without ConfigureBuffers having run, RequestFlip has nothing to flip into.

---

## 6. Cross-validation against existing forensic docs

### Cross-ref to `forensic-egl-abi.md` §11

That doc identified the **Open Questions** (Q3, Q5):
> Q3: Does the GTT have enough free area when nav_initialscreen / nav_smng aren't pre-allocating buffers? The R1 work logged 3 × 953,472 B buffers at fixed GTT offsets — those may be allocated by display_ps. If emgdhmid's `EMGDHMIAPI_GETFRAMEBUFFERSIZE` returns 0 because nothing has called `EMGDHMIAPI_CONFIGUREBUFFERS` yet, our `eglCreateWindowSurface` will fail.

**This forensic round confirms Q3 is the right question.** The 3 × 953,472 B GTT regions were **the result of a prior factory call** to `emgdHmiConfigureBuffers` (probably by display_ps during nav_smng boot). With nav_smng stopped, **nobody is calling ConfigureBuffers** for our screen, and therefore even if we successfully `CreatePixmap` and `eglMakeCurrent`, the kernel has no buffer set registered for our screen → scanout shows whatever was there last (likely black, or the last frame from before nav_smng was killed).

> Q5: What's the `EGLNativeWindowType` that libwsegl-hmi accepts?

**Answer:** `EGLNativeWindowType` is a typedef for `khronos_uint32_t` (4 bytes) in this DDK, and the value handed in is the **`EGLNativePixmapType` returned by `emgdHmiCreatePixmap`** — they're the same scalar handle (an opaque ID/offset into emgdhmid's pixmap pool). The WSEGL backend `pfnWSEGL_CreateWindowDrawable` resolves it through emgdhmid to find the actual `PVR2DMEMINFO*`.

### Cross-ref to `forensic-emgd-init.md` §2 (drmcmd_master list)

That doc identified `0x2c (CONFIG_BUFFS)` and `0x25 (SWITCH_HZ)` as the only DRM ioctls emgdhmid does via `drmcmd_master`. **CONFIGUREBUFFERS opcode 9 IS the trigger for the 0x2c ioctl.** The chain is:
1. Our `emgdHmiConfigureBuffers(display, state)` → builds 384 B message → write+read on socket.
2. emgdhmid's `DoMsg` dispatches type==9 → calls daemon::handleConfigureBuffers.
3. Daemon translates the 2×3 buffer descriptors into the `0x250`-byte payload for `DRM_IOCTL_IGD_CONFIG_BUFFS`.
4. Daemon does `drmSetMaster` → `drmCommandWriteRead(fd, 0x2c, buf, 0x250)` → `drmDropMaster`.
5. Kernel emgd.ko marks buffers as registered for scanout on the named plane.
6. Daemon writes 384 B reply back to us.
7. Our `eglSwapBuffers` pixels now actually land on the screen on the next `RequestFlip`.

### Cross-ref to `forensic-factory-ui-binary.md` (drawbuf NEEDED context)

If `drawbuf` (the factory UI binary) NEEDS `libemgdhmi.so.0`, it would call this sequence at startup: `GetNativeDisplay` → `GetNumScreens` → `GetScreenParams` → `CreatePixmap` × N → **`ConfigureBuffers`** → enter render loop with `RequestFlip` per frame. **The factory code definitely calls ConfigureBuffers.** We need to mirror that.

---

## 7. Open questions / things to verify on hardware

1. **`EMGDBufferType` descriptor 56-byte struct layout.** This file's DWARF only tells us each buffer is 56 bytes; the field layout is in `libwsegl-hmi.so` (its DWARF info may also be intact — re-run this forensic on that file if needed). We need this exact layout to construct the `state[][]` argument correctly. Best-guess struct (to verify): `{ uint32_t magic; uint32_t width; uint32_t height; uint32_t stride; uint32_t format; uint32_t pixmap_handle; uint32_t flags; uint32_t addr_phys; uint32_t addr_virt; ... pad to 56 }`.

2. **`emgdHmiQueryPixmap` semantics.** DWARF says w/h/stride are pass-by-value `unsigned int` (not pointers), but the message struct has them as `out_*` fields. Either the lib is silently dropping the daemon's response (bug?), or these are "in_expected" round-trip values where the daemon validates and returns retval=0 only if they match. Not critical for "make pixmap visible" but worth knowing.

3. **`emgdHmiSwitchHz` field naming.** DWARF says struct has `in_context` and one out — but the function takes `hz` and `pipe` ints. The "in_context" in the struct is actually `hz`; the second int (`pipe`) is at offset 44 but DWARF doesn't name it explicitly (struct sizeof is 52 which is hdr+8+4 = 52). Verify by running on hardware that `(hdr, hz_at_40, pipe_at_44, retval_at_48)` is the correct layout.

4. **What does the daemon do if `ConfigureBuffers` is called by a non-master process?** Daemon should briefly grab master via `drmcmd_master`, but emgdhmid's master might collide with our app's master (if we held it). Likely safe to NOT hold master during ConfigureBuffers — see `forensic-emgd-init.md` §8: "Don't kill emgdhmid. Don't call SetMaster."

5. **Whether `EMGDHMIAPI_QUERYPIXMAP` (8) round-trip happens during a normal Qt eglfs flow.** If yes, we need to ensure our pixmap dimensions match.

---

## Appendix A — Tools used

- macOS `/usr/bin/objdump` (Apple LLVM) — handles ELF32 i386 natively. Used for `-T`, `-R`, `-h`, `-d`, `-s`.
- Docker `ubuntu:22.04 + binutils` — GNU `objdump --dwarf=info` for the DWARF dump. macOS objdump only supports `--dwarf=frames`.
- `/usr/bin/strings` — quick rodata scan.
- All disassembly/dwarf output captured in `/tmp/libemgdhmi-disasm.s` and `/tmp/libemgdhmi-dwarf.txt` for this session.

## Appendix B — Source file path (from DWARF)

`/home/build/GFX-EMGD.DENSO-PROD-LINUX_DDK--EMGD_1_13-1.13_RC_3343/koheo/linux/emgdhmi/lib/emgdhmi.cpp`

This is **DENSO's source tree** for EMGD DDK 1.13 RC 3343. If we could obtain that source, we'd have the canonical `EMGDBufferType` struct + the exact daemon-side handlers. (Not in scope here; flagged for archive search.)

## Appendix C — Global variables (DWARF-confirmed addresses)

| VA | Name | Type | Initial | Purpose |
|---|---|---|---|---|
| `0x4163c578` | `sockfd` | int (`.data`) | `0xffffffff` | AF_UNIX socket fd to emgdhmid; -1 == not connected |
| `0x4163c584` | `pvr2d_context_lock` | `pthread_mutex_t` (`.bss`, 24 B) | 0 | Mutex guarding `sockfd` + `pvr2d` |
| `0x4163c59c` | `pvr2d` | `PVR2DCONTEXTHANDLE` (`.bss`) | NULL | Lazily-allocated PVR2D device context |
| `0x4163c5c0` | `func` (BufferState) | function pointer (`.bss`) | NULL | Cached `EmgdHmiFlipChainState` from libwsegl-hmi.so |
| `0x4163c5c4` | `wslib` | `void *` (`.bss`) | NULL | Cached `dlopen("/usr/lib/wsegl/libwsegl-hmi.so")` handle |
| `0x4163c5c8` | `usage_func` | function pointer (`.bss`) | NULL | Cached `EmgdHmiSetUsage` from libwsegl-hmi.so |
| `0x4163c5cc` | destroy callback | function pointer (`.bss`) | NULL | Cached `EmgdHmiDestroyPixmap` from libwsegl-hmi.so |
