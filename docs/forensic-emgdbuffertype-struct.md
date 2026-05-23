# Forensic — EMGDHmiBufferState (the "56-byte EMGDBufferType") struct layout

**Date:** 2026-05-23
**Mission:** Recover the exact field layout of the 56-byte buffer descriptor used by `emgdHmiConfigureBuffers(ndpy, state)` so we can construct a valid 384-byte opcode-9 IPC payload from our Qt eglfs replacement and finally make a Qt-rendered pixmap visible on the LVDS upper screen.
**Confidence:** **HIGH** for field offsets and types, **MEDIUM** for the last 4 dword field semantics (flags/format passthrough), **HIGH** for the per-screen / per-buffer ring layout.

---

## Headline correction to D2

D2 named the descriptor `EMGDBufferType`. **The actual C++ type name is `EMGDHmiBufferState`** — recovered from the demangled emgdhmid symbols (`EmgdHmiDaemon::ConfigureBuffers(int, EMGDHmiBufferState**)` and `EmgdHmiDaemon::bindSurfaces(EMGDHmiBufferState**)`). `EMGDBufferType` is actually just the 4-byte **enum** of buffer-usage values (NO/HMI/X11/POPUP/VIDEO/8BIT), which lives at offset 0 of the descriptor and is shared with `emgdHmiCreatePixmap`'s `usage` parameter. Both libraries (libwsegl-hmi.so DWARF + libemgdhmi.so DWARF) confirm the enum spelling.

---

## 1. The struct (C declaration)

```c
/*
 * EMGDHmiBufferState — 56 bytes, packed, 4-byte aligned.
 *
 * Caller supplies an array of THREE of these per screen, contiguous in memory.
 * state[screen_idx] points to the first element of that 3-entry array.
 * state itself is therefore (EMGDHmiBufferState **) of length NUM_SCREENS (= 2).
 *
 * Sentinel "end of list" for a screen: set entry's `plane_type` (offset 0) to 0
 * (EMGD_NO_BUFFER) — both daemon-side bindSurfaces and library-side packer
 * stop the inner loop when they see plane_type == 0.
 */
typedef struct {
    /* +0x00 */ uint32_t  plane_type;        /* EMGDBufferType: 0=NO 1=HMI 2=X11 3=POPUP 4=VIDEO (5=8BIT not accepted by ConfigureBuffers; daemon errors on >4 with "Invalid plane type") */
    /* +0x04 */ uint32_t  pixmap_handle;     /* low 32 bits of the opaque EGLNativePixmapType returned by emgdHmiCreatePixmap. Used as key into the daemon's Pixmap RB-tree to recover the GTT-mapped PVR2DMEMINFO* */
    /* +0x08 */ uint32_t  pixmap_handle_hi;  /* high 32 bits — set to 0 (the lib zeros the message and the WSEGL pixmap handle is a 32-bit khronos_uint32_t) */
    /* +0x0c */ int32_t   screen_x;          /* X position of the buffer's destination rect on the screen.   MUST be >= 0 */
    /* +0x10 */ int32_t   screen_y;          /* Y position on the screen.                                    MUST be >= 0 */
    /* +0x14 */ int32_t   src_x;             /* X within the source pixmap (sub-rect origin). 0 for full-pixmap blit */
    /* +0x18 */ int32_t   src_y;             /* Y within the source pixmap. 0 for full-pixmap blit */
    /* +0x1c */ int32_t   width;             /* Rect width in pixels. MUST be > 0. MUST satisfy screen_x + width <= screen_width (default 800).  Used as both src and dst width — no scaling. */
    /* +0x20 */ int32_t   height;            /* Rect height. MUST be > 0. MUST satisfy screen_y + height <= per_screen_height (fb_total_h / num_screens — typically 480 for upper or 420 for lower). */
    /* +0x24 */ uint32_t  stride;            /* Pitch of the pixmap in bytes (or pixels — see §6). MUST be >= width. */
    /* +0x28 */ uint32_t  flags0;            /* OPAQUE — passthrough into daemon's per-buffer output slot (offset +0x30). Best guess: pixel format / EMGD_FMT_* */
    /* +0x2c */ uint32_t  flags1;            /* OPAQUE — passthrough (output offset +0x34). Best guess: color-key value or alpha */
    /* +0x30 */ uint32_t  flags2;            /* OPAQUE — passthrough (output offset +0x38). Best guess: rotation/transform */
    /* +0x34 */ uint32_t  flags3;            /* OPAQUE — passthrough (output offset +0x3c). Best guess: z-order or per-plane flags */
} EMGDHmiBufferState;                        /* sizeof == 56 == 0x38 */
```

The last four `flags0..flags3` fields are written through to the daemon's internal `frame_buffers` slot but not validated. They are then handed to `DRM_IOCTL_IGD_CONFIG_BUFFS` (drmcmd 0x32, size 0x10) and `DRM_IOCTL_IGD_CONFIG_BUFFS`-followup ioctls; their meaning lives in the EMGD kernel driver `emgd.ko`, not in user-space. **Setting them all to zero is the safe starting point** — the factory-known-good `nav_smng` path almost certainly does the same for the HMI plane on screen 0.

---

## 2. "Construct from scratch" recipe — make our Qt pixmap visible

Given a pixmap handle returned by `emgdHmiCreatePixmap(ndpy, EMGD_HMI_BUFFER, 800, 480, &px)`:

```c
/* Three buffers per screen — the daemon iterates [0..2] looking for a non-zero
 * plane_type. To register ONE pixmap as a single front-buffer, fill slot 0 and
 * leave slots 1 & 2 zeroed; the loop will exit at slot 1 when it sees type=0. */
EMGDHmiBufferState screen0_bufs[3] = {{0}};
screen0_bufs[0].plane_type     = 1;          /* EMGD_HMI_BUFFER */
screen0_bufs[0].pixmap_handle  = (uint32_t)px;
screen0_bufs[0].pixmap_handle_hi = 0;
screen0_bufs[0].screen_x       = 0;
screen0_bufs[0].screen_y       = 0;
screen0_bufs[0].src_x          = 0;
screen0_bufs[0].src_y          = 0;
screen0_bufs[0].width          = 800;
screen0_bufs[0].height         = 480;
screen0_bufs[0].stride         = 800 * 4;    /* assume ARGB8888; for RGB565 use 800*2 */
/* screen0_bufs[0].flags0..3 left at 0 — see §1 */

/* Leave screen 1 (lower LVDS) untouched: an array of 3 zeroed entries acts as
 * an empty list (first entry plane_type==0 → daemon's inner loop exits immediately). */
EMGDHmiBufferState screen1_bufs[3] = {{0}};

EMGDHmiBufferState *state[2];
state[0] = &screen0_bufs[0];    /* pointer to contiguous [3] array */
state[1] = &screen1_bufs[0];

EMGDerr rc = emgdHmiConfigureBuffers(ndpy, state);
/* On success: kernel emgd.ko now knows our pixmap as the HMI plane's scanout
 * buffer for screen 0. Next eglSwapBuffers (followed by emgdHmiRequestFlip or
 * emgdHmiFlipScreen) actually puts pixels on the panel. */
```

**Where the GTT offset comes from** (Q: brief item 6):
- The 28-byte `PVR2DMEMINFO` struct carrying `ui32DevAddr` (the GTT offset) is **NEVER part of the wire format**. It is resolved server-side by the daemon: `bindSurfaces` does an RB-tree `find(pixmap_handle)` → gets `EmgdHmiDaemon::Pixmap*` → dereferences `pix->meminfo[0x10]->ui32DevAddr[0x18]` (chain `[+0x18] -> [+0x10] -> [+0x18]` in the disasm at lines 4196–4198).
- **Therefore client code must NOT try to fill in GTT addresses.** Just send the pixmap handle from `emgdHmiCreatePixmap`; the daemon does the lookup.
- `emgdHmiMapPixmap` / `emgdHmiGetFramebuffer` exist for direct CPU memcpy paths and return their own MEMINFO pointers; they are NOT needed for `ConfigureBuffers`.

---

## 3. Wire-format mapping (library-side packing)

The library's `emgdHmiConfigureBuffers` at `0x4163a890` does (verified field-by-field from disassembly at `0x4163a92b`–`0x4163a991`):

```
msg[0x00 .. 0x27]  = 40-byte EMGDHmiSocket_Header { size=0x17c, name="ConfigureBuffers", type=9 }
msg[0x28 .. 0x2b]  = in_numscreens (uint32) — hardcoded to 2 by the library
msg[0x2c .. 0x63]  = state[0][0]  ← 56 bytes copied from caller's EMGDHmiBufferState
msg[0x64 .. 0x9b]  = state[0][1]
msg[0x9c .. 0xd3]  = state[0][2]
msg[0xd4 .. 0x10b] = state[1][0]
msg[0x10c .. 0x143] = state[1][1]
msg[0x144 .. 0x17b] = state[1][2]
msg[0x17c .. 0x17f] = out_retval (uint32) — daemon writes back on reply
                                       total: 384 bytes (0x180) sent and received
```

Per-screen stride is `0xa8` (168 bytes); per-buffer stride within a screen is `0x38` (56 bytes). The library zeros the entire 384-byte buffer first, so unwritten slots are NULL-equivalent (plane_type=0 → end-of-list sentinel). The library terminates the inner loop early at the first slot whose first dword (the input pointer's `*eax`) is zero:

```
4163a994:  mov esi, DWORD PTR [eax]    ; re-read the plane_type field
4163a996:  test esi, esi
4163a998:  je   <exit inner loop>      ; if 0 → stop copying for this screen
4163a99a:  add ecx, 1                   ; else: next buffer
4163a99d:  add eax, 0x38                ; advance source pointer by 56
4163a9a0:  cmp ecx, 3
4163a9a3:  jne  <copy next>             ; max 3 slots per screen
```

This means **the library treats `state[i]` as a pointer to a contiguous `EMGDHmiBufferState[3]` array, NOT a NULL-terminated list of pointers**. D2's documentation showed it as `EMGDBufferType *screen0_bufs[4] = {...}` (array of pointers); that interpretation will produce wrong wire bytes — it would dereference and copy 56 bytes starting from pointer values rather than from the actual descriptors.

**Corrected calling convention:**

```c
/* CORRECT (matches what the lib actually reads): */
EMGDHmiBufferState screen0_bufs[3] = { {.plane_type=1, ...}, {0}, {0} };
EMGDHmiBufferState screen1_bufs[3] = { {0}, {0}, {0} };
EMGDHmiBufferState *state[2] = { screen0_bufs, screen1_bufs };
emgdHmiConfigureBuffers(ndpy, state);

/* WRONG (D2's example — would read 56 bytes from each pointer value as if it
 * were a struct, almost certainly faulting or sending garbage): */
/* EMGDBufferType *screen0_bufs[4] = { &frontbuf, &backbuf, &auxbuf, NULL }; */
```

---

## 4. Daemon-side validation (what your input must pass)

`EmgdHmiDaemon::bindSurfaces` at `0x804ce40` validates each non-empty slot. Failures return `-3` (EMGD_ERR_BAD_CONFIG) and emit `"Invalid plane type (%d) in new state[%d][%d] !"` to stderr. The validation chain:

| Check | Source line | Failure semantics |
|---|---|---|
| `plane_type <= 4` | `804cf12` | `jbe 804cf50` — else jumps to fprintf+ret -3 |
| `screen_x >= 0` | `804cf65` | js → fail |
| `width > 0` | `804cf73` | jle → fail |
| `screen_x + width <= this->screen_width (+0x44)` | `804cf81` | jg → fail |
| `screen_y >= 0` | `804cf8c` | js → fail |
| `height > 0` | `804cf9a` | jle → fail |
| `screen_y + height <= total_fb_height (+0x40) / num_screens` | `804cfc9` | jg → fail |
| `width <= stride` | `804cfe7` | jg → fail |

Note the per-screen height constraint uses **total framebuffer height / num_screens**. On Q60 (`portorder=2,4,0,0,0`, two LVDS panels stacked into a single 800×900 mode), num_screens=2 so per_screen_h = 450. The upper panel is 800×480 but only the top 450 rows are addressable from this code path → effectively a constraint of `screen_y + height <= 450` for screen 0. **Use height=450 if you hit a "BAD_CONFIG" failure on a full 480-row request.** (This deserves hardware verification; the factory may set `total_fb_h = 900` and rely on the panel timing to actually drive 480+420.)

Per-screen plane availability (the "No plane available for HMI buffer on pipe %d" string) is checked AFTER validation, during `bindSurfaces`'s output-rect emission. If our HMI plane is already taken by another client, we get -3 with a different log line. With `nav_smng` killed, planes should be free for our claim.

---

## 5. Per-screen / per-buffer ring layout — confirmed

```
state ─→ ┌───────────┐
         │ state[0]  │──→ EMGDHmiBufferState screen0[3];   // 168 bytes contiguous
         ├───────────┤        [0] = front buffer
         │ state[1]  │──→ EMGDHmiBufferState screen1[3];   // 168 bytes contiguous
         └───────────┘        [0] = (typically zero on Q60, lower LVDS unused by us)
```

Indexing: `state[i][j]` where `i ∈ {0=upper LVDS, 1=lower LVDS}`, `j ∈ {0=front, 1=back, 2=aux}`.
**NUM_SCREENS is hardcoded to 2 in the library** — there is no way for the client to declare 1 screen via this API. If you only care about one screen, zero the other one's array entirely.

**Triple-buffering on Q60:** the prior R1 work observed 3 × 953,472-byte buffers at GTT offsets 0x000000 / 0x0e9000 / 0x1d2000 — those were almost certainly the factory's `state[0][0..2]` after `nav_smng` ran ConfigureBuffers. The triple-buffer pattern is the EMGD-native scheme; the daemon's per-frame `RequestFlip(screen, owner)` advances the active slot. For initial Qt bring-up we can ship just ONE buffer (the front) and not flip — picture will be static but visible, which is sufficient to prove the path works. Triple-buffering is then an ergonomic upgrade, not a correctness requirement.

---

## 6. Stride unit — verify

DWARF in the WSEGL drawable struct (`_WSHMIDrawable.stride` at file `wsegl/wsegl-hmi.c:52`) does NOT label units. PVR2D conventions vary (some platforms count bytes, some count pixels). The daemon-side validation only checks `stride >= width`, which is consistent with both. **Empirically test by sending 800 (pixel-pitch interpretation) and then 800*4 (byte-pitch for ARGB8888) and see which one renders without horizontal smearing.** Bias the first try toward **bytes**: PVR2DMEMINFO's allocator works in bytes, the typical EMGD scanout pitch is bytes-aligned, and the analogous WSEGLDrawableParams field `ui32Stride` in the WSEGL ABI is documented as bytes.

---

## 7. EMGD_DISPLAY_HMI and friends — confirmed values

DWARF from libemgdhmi.so (per D2 §Section 2 constants):

```c
typedef enum { EMGD_DISPLAY_HMI = 0, EMGD_DISPLAY_X11 = 1 } EMGDDisplayType;
```

Used as the `owner` argument to `emgdHmiRequestFlip(display, screen, owner, &result)` and `emgdHmiFlipScreen(display, screen, owner)`. **For our Qt eglfs use case the value is `0` (EMGD_DISPLAY_HMI).**

The plane-type enum at descriptor offset 0 is a different but related thing:

```c
typedef enum {                /* this is the offset-0 plane_type field */
    EMGD_NO_BUFFER    = 0,    /* sentinel: end of per-screen list */
    EMGD_HMI_BUFFER   = 1,    /* GLES / Qt surface — use this */
    EMGD_X11_BUFFER   = 2,
    EMGD_POPUP_BUFFER = 3,
    EMGD_VIDEO_BUFFER = 4,    /* V4L2 / camera */
    EMGD_8BIT_BUFFER  = 5,    /* allowed by CreatePixmap but rejected by ConfigureBuffers */
} EMGDBufferType;
```

The relation: `EMGD_DISPLAY_HMI=0` is the *owner identity* (used for flip arbitration between the HMI compositor and an optional X11 server). `EMGD_HMI_BUFFER=1` is the *plane category* the buffer goes on (an HMI plane vs an X11 plane vs a popup vs a video). The R1 forensic identified Sprite C as the camera/V2G plane (matches EMGD_VIDEO_BUFFER=4 + `STARTVIDEO` opcode 10). The HMI plane is most likely the **primary overlay** (DRM plane index 3 per R1's `IGD_ALTER_OVL2` probe).

---

## 8. EmgdHmiFlipChainState — the WSEGL→daemon callback

libwsegl-hmi.so exports three symbols that libemgdhmi resolves at runtime via `dlsym("/usr/lib/wsegl/libwsegl-hmi.so", "...")`:

| Symbol | Address | Size | Purpose (from disasm of libwsegl-hmi at the symbol address) |
|---|---|---|---|
| `EmgdHmiFlipChainState` | `0x1140` | 0x65 | Called by `emgdHmiBufferState(buf0, buf1, buf2, curr_buf)`. Probably updates the WSEGL flip-chain client-side bookkeeping so the next `eglSwapBuffers` writes to the buffer the daemon just rotated AWAY from. **Signature:** `int (*)(PVR2D_VOID **buf0, PVR2D_VOID **buf1, PVR2D_VOID **buf2)` per libemgdhmi's call site (args reordered as buf2, buf1, buf0 on the stack). |
| `EmgdHmiDestroyPixmap` | `0x11b0` | 0xa0 | Calls `PVR2DMemFree` on the WSEGL-side mapping when a pixmap is torn down. Hooked into `emgdHmiDestroyPixmap` (libemgdhmi → WSEGL cleanup). |
| `EmgdHmiSetUsage`       | `0x1250` | 0x19 | 25-byte stub — likely stores the `usage` (EMGD_HMI_BUFFER vs X11 vs ...) into the WSEGLDrawableHandle so the backend knows which plane to target on swap. Called from `emgdHmiMapPixmap`. |

**For our Qt eglfs use case, the WSEGL backend (libwsegl-hmi.so) handles all of this internally** once the EGL surface is wired up. We don't need to call any of these symbols directly. The `EmgdHmiFlipChainState` callback only matters if we bypass eglSwapBuffers and drive the flip chain ourselves — which we won't.

---

## 9. Why D2's "56-byte struct is in libwsegl-hmi.so DWARF" was wrong

I dumped libwsegl-hmi.so's complete DWARF (`/tmp/wsegl-dwarf-info.txt`, 95KB). Every structure with `DW_TAG_structure_type` was enumerated:

| Struct | Byte size | Notes |
|---|---|---|
| `_PVR2DMEMINFO` | 28 | Standard PVR2D memory handle |
| `_PVR2DDEVICEINFO` | 24 | Device enum entry |
| `WSEGLCaps_TAG` | 8 | Cap key+value pair |
| `WSEGLConfig_TAG` | 24 | EGL config descriptor |
| `WSEGLDrawableParams_TAG` | 28 | The "blit params" struct — width, height, stride, pixelformat, linear_addr, hw_addr, hPrivateData |
| `WSEGL_FunctionTable_TAG` | 52 | WSEGL backend vtable |
| `WSHMIDisplay` (private) | 696 | Big internal struct with `flipBufs[3]` (3 PVR2DMEMINFO*), refresh, w, h, stride, ctx, currBuf, numBufs, etc. |
| `_WSHMIDrawable` | 24 | Per-pixmap: dpy, w, h, stride, fmt, mem (PVR2DMEMINFO*) |
| `pixmem_t` (anon) | 12 | Pixmap-cache entry: npix, dpy, mem |

**No 56-byte struct exists in this binary's DWARF.** The 56-byte struct is private to the EMGD HMI IPC protocol; it never appears in WSEGL because WSEGL doesn't speak that protocol. (WSEGL communicates with the WSEGL backend's own state machine — DrawableParams, FlipChain, etc.)

The 56-byte layout had to be recovered from the **daemon-side validator** (`EmgdHmiDaemon::bindSurfaces` in emgdhmid, which is unstripped and retains C++ mangled symbols revealing the type name `EMGDHmiBufferState`) plus the library-side packer (`emgdHmiConfigureBuffers` in libemgdhmi, where DWARF only confirms "56 bytes copied per slot, 14 dwords").

---

## 10. End-to-end sanity sequence

Drop-in pseudocode for adding the missing call into our Plan B''' Qt eglfs replacement:

```c
#include <stdint.h>

typedef enum { EMGD_HMI_BUFFER = 1 } EMGDBufferType;
typedef int   EMGDerr;
typedef void *EGLNativeDisplayType;
typedef uint32_t EGLNativePixmapType;

typedef struct {
    uint32_t plane_type;
    uint32_t pixmap_handle;
    uint32_t pixmap_handle_hi;
    int32_t  screen_x, screen_y;
    int32_t  src_x, src_y;
    int32_t  width, height;
    uint32_t stride;
    uint32_t flags0, flags1, flags2, flags3;
} EMGDHmiBufferState;

extern EMGDerr emgdHmiGetNativeDisplay(EGLNativeDisplayType *);
extern int     emgdHmiGetNumScreens(EGLNativeDisplayType);
extern EMGDerr emgdHmiCreatePixmap(EGLNativeDisplayType, EMGDBufferType,
                                   int width, int height, EGLNativePixmapType *);
extern EMGDerr emgdHmiConfigureBuffers(EGLNativeDisplayType,
                                       EMGDHmiBufferState **state);
extern EMGDerr emgdHmiRequestFlip(EGLNativeDisplayType, int screen,
                                  int owner /*=EMGD_DISPLAY_HMI=0*/,
                                  int *result);

void q60_publish_qt_surface(void)
{
    EGLNativeDisplayType ndpy = 0;
    emgdHmiGetNativeDisplay(&ndpy);                       /* magic 0xd39ade6b */
    int nscreens = emgdHmiGetNumScreens(ndpy);            /* expect 2 */

    EGLNativePixmapType px = 0;
    emgdHmiCreatePixmap(ndpy, EMGD_HMI_BUFFER, 800, 480, &px);

    EMGDHmiBufferState screen0[3] = {{0}};
    screen0[0].plane_type    = EMGD_HMI_BUFFER;
    screen0[0].pixmap_handle = (uint32_t)px;
    screen0[0].width         = 800;
    screen0[0].height        = 480;       /* try 450 if daemon returns -3 */
    screen0[0].stride        = 800 * 4;   /* ARGB8888 byte-pitch */

    EMGDHmiBufferState screen1[3] = {{0}};

    EMGDHmiBufferState *state[2] = { screen0, screen1 };
    EMGDerr rc = emgdHmiConfigureBuffers(ndpy, state);
    /* rc == 0 (EMGD_SUCCESS): kernel emgd.ko now knows this pixmap as the
     * scanout buffer for the HMI plane on screen 0. */

    /* From here: eglCreatePixmapSurface(dpy, cfg, px, NULL) → eglMakeCurrent →
     * draw → eglSwapBuffers → emgdHmiRequestFlip(ndpy, 0, 0, &did_flip).
     * The pixels are now on the upper LVDS. */
}
```

---

## Evidence trail

| Claim | Source |
|---|---|
| Struct type name is `EMGDHmiBufferState` | C++ mangled symbol `_ZN13EmgdHmiDaemon16ConfigureBuffersEiPP18EMGDHmiBufferState` in `/tmp/dsu-slot-a/usr/sbin/emgdhmid` symtab — demangles to `EmgdHmiDaemon::ConfigureBuffers(int, EMGDHmiBufferState**)` |
| Struct is 56 bytes | Both libemgdhmi packer (slot stride 0x38 at `0x4163a99d`) and emgdhmid bindSurfaces (input stride 0x38 at `0x804d1e3`) iterate 56 bytes per buffer |
| 14 dwords (fields at offsets 0,4,8,0xc,0x10,0x14,0x18,0x1c,0x20,0x24,0x28,0x2c,0x30,0x34) | libemgdhmi disasm `0x4163a938`–`0x4163a991`, plus emgdhmid bindSurfaces field-access pattern |
| state[i] is `EMGDHmiBufferState *` (NOT array-of-pointers) | libemgdhmi `0x4163a944`: `mov eax, [edx+edi*4]` (state[i] = base pointer), then `add eax, 0x38` per inner iteration (line `0x4163a99d`) — single dereference, then contiguous 56-byte strides |
| plane_type ≤ 4 enforced | emgdhmid `0x804cf12`: `cmp edx, 0x4; jbe ok` else fall through to `fprintf(stderr, "Invalid plane type ...")` |
| Validation rules (≥0, >0, fits-screen, stride≥width) | emgdhmid `0x804cf65`–`0x804cfe7` (js/jle/jg sequence) |
| num_screens hardcoded to 2 | libemgdhmi `0x4163a9c2`: `mov [ebp-0x160], 0x2` (msg offset 0x28 = field `in_numscreens`) AND outer loop `cmp edi, 0x2; jne` at `0x4163a9ae` |
| 3 buffers per screen | libemgdhmi inner loop `cmp ecx, 0x3; jne` at `0x4163a9a0`; emgdhmid bindSurfaces `cmp edi, 0x3; jne` at `0x804d1ea` |
| 384 bytes on wire (`0x180`) | libemgdhmi `mov edx, 0x180` at `0x4163a9bd` (size arg to SendNGetReply) |
| Per-screen msg stride = 0xa8 (168 bytes) | libemgdhmi `imul edx, edi, 0xa8` at `0x4163a919` |
| Per-buffer msg stride = 0x38 (56 bytes) | libemgdhmi `imul edx, ecx, 0x38` at `0x4163a92b` |
| 0xc-byte preamble per slot in msg layout | libemgdhmi destination offsets: input[0] → msg[esi+0xc], input[0x34] → msg[esi+0x40] |
| Daemon GTT-offset lookup chain | emgdhmid `0x804d0ee`: `mov eax, [pixmap_obj+0x18]; mov eax, [eax+0x10]; mov eax, [eax+0x18]` — pixmap→meminfo→ui32DevAddr |
| Daemon RB-tree key is unsigned long long | Mangled type `_Rb_tree<y, pair<Ky, Pixmap*>>` where `y` = `unsigned long long` |
| EMGDDisplayType {HMI=0, X11=1} | libemgdhmi DWARF (per D2 §Section 2) |
| EMGDBufferType enum values | libwsegl-hmi.so DWARF `_zb_*` at lines 376-391 of `/tmp/wsegl-dwarf-info.txt` |
| DRM ioctl 0x32 = CONFIG_BUFFS | emgdhmid `0x804d4a8`: `mov [esp+4], 0x32` to drmcmd_master AND strings dump: `"DRM_IOCTL_IGD_CONFIG_BUFFS ioctl() failed with error %d !"` |
| EmgdHmiFlipChainState signature | libwsegl-hmi.so exports it at `0x1140` (0x65 bytes); libemgdhmi `emgdHmiBufferState` resolves and calls it with 3 args reordered |

## Tools used

- `docker run --platform linux/amd64 ubuntu:22.04` with `binutils` for ELF32 i386 `objdump --dwarf=info`, `objdump -d -M intel`, `objdump --syms`, `objdump --dynamic-syms`
- macOS `/usr/bin/strings` for emgdhmid string-table inspection
- All raw artifacts in `/tmp/`:
  - `wsegl-dwarf-info.txt` (95KB) — full DWARF of libwsegl-hmi.so
  - `emgdhmid-syms.txt` (≈340 lines) — C++ mangled symbols
  - `emgdhmid-disasm.txt` (≈8KB) — full disasm
  - `libemgdhmi-disasm.txt` — full disasm of libemgdhmi.so.0.1.0

## Open questions for hardware

1. **Stride units (bytes vs pixels).** §6. Try byte-pitch (`width * bpp`) first; fall back to pixel-pitch (`width`) if scanout shows horizontal smearing.
2. **per_screen_height = total_h / num_screens — is this actually 450 on Q60 or 480?** §4. The 800+800/450+450 interpretation gives 800×900 fb with two 450-line viewports; the 800+800/480+420 interpretation requires custom per-screen heights and would mean the `total_h/num_screens` validator is buggy or works in a different unit. If `height=480` returns BAD_CONFIG, fall back to 450 and accept the 30-row letterbox at the bottom — Qt will adapt.
3. **flags0..3 semantics.** §1. Zero should be fine but worth dumping the bytes the factory `nav_smng` sends via an LD_PRELOAD shim that snoops the ConfigureBuffers payload, when we get a chance to run that experiment.
4. **Does `nav_smng` keep state[1] (lower LVDS) populated, or does another daemon publish that screen?** If our zeroed `state[1]` clobbers the lower-screen control hub UI, we need to leave that screen's buffers intact (probably by calling `GetCurrentBuffers` first — which doesn't exist as an API — or by reading what the daemon has cached and re-publishing it). For Plan B''' bring-up we only care about the upper screen anyway, but this matters for the production architecture.
