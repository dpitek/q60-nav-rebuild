# Forensic — drawbuf Call Sequence (Why The Factory Tool Paints, And We Don't)

**Date:** 2026-05-23
**Subject:** Full disassembly trace of `/lib/systemd/system/systemdRelatedFiles/Display_Tools/drawbuf` (24,045 B, i386, DWARF intact, source `/home/naviwork/work/Display_Tool_source/drawbuf/DrawBuffer_c.c`)
**Mission:** Find the missing call(s) that make a pixmap visible on the LVDS.

---

## TL;DR — The Recipe (in order)

The factory pattern is **not what we've been doing**. The visible-pixel path is **CPU-mapped memcpy** into the pixmap, then a publish triplet. GL/eglSwap is part of the dance but is **not the thing that makes pixels appear**.

```text
ONCE:
  1.  emgdHmiGetNativeDisplay(&ndpy)
  2.  emgdHmiGetFramebuffer(ndpy, &fb_pix, &fb_info)        // -> fb (PVR2DMEMINFO*)
  3.  emgdHmiCreatePixmap(ndpy, EMGD_HMI_BUFFER=1, 800, 960, &hmi_pix)
      // (optionally also EMGD_POPUP_BUFFER=3, 800, 480 — drawbuf skips it via field=-1)
  4.  eglGetDisplay(ndpy) -> disp
  5.  eglInitialize(disp, NULL, NULL)
  6.  eglChooseConfig(disp, drawbuf_attribs[11], &cfg, 10, &n)   // GLES1, RGBA8, D24S8, 4x MSAA, WIN|PIX
  7.  eglCreateWindowSurface(disp, cfg, fb_pix, NULL)      -> fb_surf
  8.  eglCreatePixmapSurface(disp, cfg, hmi_pix, NULL)     -> hmi_surf
  9.  eglCreateContext(disp, cfg, parent_ctx=NULL, NULL)   -> ctx
  10. eglMakeCurrent(disp, fb_surf, fb_surf, ctx)
  11. eglSwapBuffers(disp, fb_surf)                        // <-- first prime swap, while empty

EVERY FRAME (set_color_and_display):
  A.  emgdHmiGetFramebufferSize(ndpy, &w, &h, &stride, &fmt_info)
  B.  emgdHmiMapPixmap(ndpy, &cpu_ptr, &pitch, &h2, &w2, &mapinfo)   // <-- CPU mapping!
  C.  for (y=0; y<h; y++) for (x=0; x<w; x++) ((u32*)cpu_ptr)[y*pitch/4 + x] = color_argb;
  D.  emgdHmiBufferState(&s0,&s1,&s2,&s3)                  // returns which slot is free
  E.  memcpy(fb_buffer_slot[next], cpu_ptr, w*h*bpp)       // copy pixmap -> framebuffer slot
  F.  emgdHmiFreeMem(cpu_ptr)                              // unmap
  G.  eglSwapBuffers(disp, fb_surf)                        // <-- mandatory but doesn't show pixels
  H.  emgdHmiConfigureBuffers(ndpy, &cfg_array[2])         // <-- THE SHOW-THE-PIXELS CALL
```

**What we've been missing in our spike:**
1. We never call `emgdHmiMapPixmap` and write pixels via CPU — we use `glClear`. Drawbuf doesn't use GL at all for the pixel data; GL is just there to keep the EGL state machine alive.
2. We never call `emgdHmiBufferState` to learn the active/free buffer slot index.
3. We never call `emgdHmiFreeMem` to commit the mapped write.
4. **We never call `emgdHmiConfigureBuffers` — this is the actual present.** `eglSwapBuffers` alone is insufficient.
5. We never call `emgdHmiGetFramebuffer` — we used a pixmap as the window-surface target. drawbuf's window-surface is bound to the **framebuffer**, and the pixmap is rendered separately and then composited via ConfigureBuffers.

---

## Section 1 — Function Map (from symbol table)

| Addr | Symbol | Size | Source line (DWARF) |
|------|--------|-----:|---------------------|
| `0x08048d44` | `main` | 0x2d3 | DrawBuffer_c.c:127 |
| `0x08049017` | `set_color_and_display` | 0x1f9 | DrawBuffer_c.c:244 (param parse 244-258; per-frame 259-355) |
| `0x08049210` | `create_emgd_resource` | 0x1c0 | DrawBuffer_c.c:375 |
| `0x080493d0` | `destroy_emgd_resource` | 0xa2 | (cleanup) |
| `0x08049472` | `create_egl_resources_with_parent` | 0x249 | (EGL setup) |
| `0x080496bb` | `create_egl_resources` | 0x13 | wrapper: calls _with_parent(0) |
| `0x080496ce` | `test_fb_status_init` | 0xa5 | DrawBuffer_c.c:~358 |
| `0x08049773` | `destroy_egl_resources` | 0x82 | |
| `0x080497f5` | `test_fb_status_finish` | 0x73 | DrawBuffer_c.c:358 |

**Global state (the `emgd_data` struct):** at `0x0804afa0` (BSS), size **0x2c = 44 bytes**.

Decoded layout from the disassembly (each field referenced by `[ebx+N]` patterns where `ebx` = `&emgd_data`):

| Offset | Type | Meaning | Set by |
|-------:|------|---------|--------|
| 0x00 | `EGLNativeDisplayType` | `ndpy` | `emgdHmiGetNativeDisplay` |
| 0x04 | `PVR2DMEMINFO*` | `fb` (framebuffer pixmap) — `-1` means skip | `emgdHmiGetFramebuffer` |
| 0x08 | `PVR2DMEMINFO*` | `hmi_pixmap` (800x960) — `-1` means skip | `emgdHmiCreatePixmap(type=1)` |
| 0x0c | `PVR2DMEMINFO*` | `popup_pixmap` (800x480) — `-1` means skip | `emgdHmiCreatePixmap(type=3)` |
| 0x10 | (unknown) | initialized to `-1` in `test_fb_status_init` | likely framebuffer pitch/info |
| 0x14 | `EGLDisplay` | `disp` (from eglGetDisplay) | `create_egl_resources_with_parent` |
| 0x18 | `EGLSurface` | `fb_surf` (window surface bound to framebuffer) | `eglCreateWindowSurface` |
| 0x1c | `EGLSurface` | `hmi_surf` (pixmap surface bound to hmi_pixmap) | `eglCreatePixmapSurface` |
| 0x20 | `EGLSurface` | `popup_surf` | `eglCreatePixmapSurface` |
| 0x24 | `EGLContext` | `ctx` | `eglCreateContext` |
| 0x28 | (unknown) | end of struct | |

`test_fb_status_init` zeros the whole struct then sets `[+0xc] = -1` and `[+0x10] = -1` → **drawbuf paints to HMI+framebuffer only, not popup.**

---

## Section 2 — main() (DrawBuffer_c.c:127)

`main(argc, argv)` does:

1. argc validation (`==2` else error).
2. `strcpy(local, argv[1])`; `printf("str = %s\n", local)`.
3. 12 cascaded `strcmp` → integer color index `0..0xb`:
   - `finish=0, white=1, red=2, yellow=3, blue=4, black=5, aqua=6, darkgray=7, darkgreen=8, navy=9, ?=0xa, ?=0xb`
4. **Socket dance (NOT the visibility path):**
   ```c
   int s = socket(AF_UNIX, SOCK_STREAM, 0);              // 0x8048f51
   struct sockaddr_un addr = { .sun_family=AF_UNIX,
                                .sun_path="/tmp/sdupdate_sock" };
   connect(s, &addr, sizeof(addr));                       // 0x8048faf
   send(s, &color_index, 4, 0);                           // 0x8048fcd  (sends the 4-byte int)
   close(s);
   exit(0 or 1);
   ```
   This is **not the display IPC**. `drawbuf` is a **CLIENT of `drawbufd`** — it sends a color code to `/tmp/sdupdate_sock` and exits. The actual painting happens inside **`drawbufd`** (the daemon), which sits in a `set_color_and_display` loop. `drawbuf` itself never touches EGL or emgdHmi.

   **This explains why drawbuf's source has all the EGL code but our usage pattern can't compare directly: `drawbuf` (the client) never executes the EGL path. It only fires the IPC. The EGL code in this binary belongs to the daemon variant `drawbufd` (same source file, conditional compilation, `main` differs).**

So: `drawbuf` and `drawbufd` share `DrawBuffer_c.c`. `drawbuf` is the trigger; `drawbufd` is the painter. The recipe in section TL;DR is **the painter's path**, which we can read directly from `drawbuf`'s `set_color_and_display`, `create_emgd_resource`, `create_egl_resources_with_parent`, `test_fb_status_init` — even though `main()` here only fires IPC.

---

## Section 3 — create_emgd_resource (the buffer allocator)

```c
int create_emgd_resource(S_EMGDDATA *p) {       // p in ebx
    pid_t pid = getpid();
    pthread_t tid = pthread_self();

    EGLNativeDisplayType ndpy = NULL;            // local [ebp-0x1c]
    if (emgdHmiGetNativeDisplay(&ndpy) != 0)     // 0x8049240
        return -1;

    if (p->fb != (PVR2DMEMINFO*)-1) {            // [ebx+0x4]
        PVR2DMEMINFO *fb_local;                   // [ebp-0x20]
        EmgdHmiInfo fb_info;                      // [ebp-0x24]
        if (emgdHmiGetFramebuffer(ndpy, &fb_local, &fb_info) != 0)   // 0x8049283
            return -2;
        printf("[%s]emgdHmiGetFramebuffer:PVR2DMEMINFO\n", ...);
    }

    if (p->hmi_pixmap != (PVR2DMEMINFO*)-1) {    // [ebx+0x8]
        PVR2DMEMINFO *hmi_local;                  // [ebp-0x28]
        if (emgdHmiCreatePixmap(ndpy, 1, 0x320, 0x3C0, &hmi_local) != 0)   // 0x80492e6
            //                          ^      ^      ^^^^^
            //                          EMGD_HMI_BUFFER  800   960
            return -3;
    }

    if (p->popup_pixmap != (PVR2DMEMINFO*)-1) {  // [ebx+0xc]
        PVR2DMEMINFO *popup_local;                // [ebp-0x2c]
        if (emgdHmiCreatePixmap(ndpy, 3, 0x320, 0x1E0, &popup_local) != 0) {  // 0x8049335
            //                          ^      ^      ^^^^^
            //                          EMGD_POPUP_BUFFER  800   480
            emgdHmiDestroyPixmap(ndpy, popup_local);  // rollback on partial fail
            return -4;
        }
    }

    p->ndpy = ndpy;
    if (p->fb != -1)            p->fb = fb_local;
    if (p->hmi_pixmap != -1)    p->hmi_pixmap = hmi_local;
    if (p->popup_pixmap != -1)  p->popup_pixmap = popup_local;
    return 0;
}
```

**Argument values decoded from `push` instructions immediately before each `call`:**

| Call site | Function | Args (cdecl: right-to-left pushed) |
|-----------|----------|-----------------------------------|
| `0x08049240` | `emgdHmiGetNativeDisplay` | `(&local_ndpy)` |
| `0x08049283` | `emgdHmiGetFramebuffer` | `(ndpy, &fb_out, &fb_info_out)` |
| `0x080492e6` | `emgdHmiCreatePixmap` | `(ndpy, 1 /*EMGD_HMI_BUFFER*/, 0x320=800, 0x3C0=960, &pix_out)` |
| `0x08049335` | `emgdHmiCreatePixmap` | `(ndpy, 3 /*EMGD_POPUP_BUFFER*/, 0x320=800, 0x1E0=480, &pix_out)` |

---

## Section 4 — create_egl_resources_with_parent (the EGL binder)

```c
int create_egl_resources_with_parent(S_EMGDDATA *p, EGLContext parent) {
    EGLint attribs[21];                          // [ebp-0x98], filled by rep movs from 0x8049cc0
    EGLConfig cfg;                                // [ebp-0x44]
    EGLint n_configs;                             // [ebp-0x1c]

    // copy 21 dwords (84 bytes) of attribs from .rodata 0x8049cc0
    EGLDisplay disp = eglGetDisplay(p->ndpy);    // 0x8049496
    eglInitialize(disp, NULL, NULL);              // 0x80494a5  -- args: (disp,0,0)
    eglChooseConfig(disp, attribs, &cfg, 10, &n_configs);  // 0x80494f3
    //                                     ^^
    //                                     max configs returned = 10

    if (p->fb != -1) {
        // WINDOW surface bound to framebuffer
        fb_surf = eglCreateWindowSurface(disp, cfg, p->fb, NULL);   // 0x8049545
    }
    if (p->hmi_pixmap != -1) {
        hmi_surf = eglCreatePixmapSurface(disp, cfg, p->hmi_pixmap, NULL);  // 0x8049595
    }
    if (p->popup_pixmap != -1) {
        popup_surf = eglCreatePixmapSurface(disp, cfg, p->popup_pixmap, NULL);  // 0x80495f3
    }
    ctx = eglCreateContext(disp, cfg, parent, NULL);   // 0x8049645
    //                                        ^^^^^^
    //                                        attrib_list = NULL (no GLES version pin!)

    p->disp     = disp;       // [ebx+0x14]
    p->fb_surf  = fb_surf;    // [ebx+0x18]
    p->hmi_surf = hmi_surf;   // [ebx+0x1c]   (NOT popup!)
    p->popup_surf = popup_surf; // [ebx+0x20]
    p->ctx      = ctx;        // [ebx+0x24]
    return 0;
}
```

**Note: `eglCreateContext` is called with `NULL` attribs.** That defaults to GLES1 (because the chosen config has `EGL_RENDERABLE_TYPE=EGL_OPENGL_ES_BIT=1`). For our Qt port we'd pass `[EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE]` and change the config to `EGL_OPENGL_ES2_BIT=4`.

### EGL attribute array — verbatim from .rodata 0x8049cc0

```
24 30 00 00  08 00 00 00     EGL_RED_SIZE,                8
23 30 00 00  08 00 00 00     EGL_GREEN_SIZE,              8
22 30 00 00  08 00 00 00     EGL_BLUE_SIZE,               8
21 30 00 00  08 00 00 00     EGL_ALPHA_SIZE,              8
25 30 00 00  18 00 00 00     EGL_DEPTH_SIZE,              24
26 30 00 00  08 00 00 00     EGL_STENCIL_SIZE,            8
32 30 00 00  01 00 00 00     EGL_BIND_TO_TEXTURE_RGBA,    EGL_TRUE
31 30 00 00  04 00 00 00     EGL_SAMPLES,                 4
40 30 00 00  01 00 00 00     EGL_RENDERABLE_TYPE,         EGL_OPENGL_ES_BIT (GLES1)
33 30 00 00  06 00 00 00     EGL_SURFACE_TYPE,            EGL_WINDOW_BIT|EGL_PIXMAP_BIT
38 30 00 00                  EGL_NONE  (terminator)
```

21 dwords copied via `rep movs` (ecx=0x15) at `0x08049492`. Last 32-bit slot is junk — terminator is only one EGLint (`0x3038 = EGL_NONE`).

---

## Section 5 — set_color_and_display (THE PER-FRAME LOOP — THIS IS WHERE PIXELS HAPPEN)

This is the function that drawbufd calls every time it receives a color from drawbuf's socket message. **This is what our spike's `glClear+eglSwap` should be replaced with.**

```c
int set_color_and_display(uint32_t color_argb) {     // color in edi
    pid_t pid = getpid(); pthread_t tid = pthread_self();

    // === STEP A: Query framebuffer geometry ===
    // emgdHmiGetFramebufferSize(ndpy, &width, &height, &stride, &fmtinfo) at 0x804905d
    // (passes pemgddata->ndpy = ds:0x804afa0)
    int w, h, stride;             // [ebp-0x28], [ebp-0x2c]
    SomeFmtInfo fmt;              // [ebp-0x208]   <- 224-byte struct
    if (emgdHmiGetFramebufferSize(ndpy, &h, &w, &stride, &fmt) != 0) return -3;

    // === STEP B: Map the PIXMAP into CPU memory ===
    // emgdHmiMapPixmap(ndpy, hmi_pixmap, &pitch, &h, &w, &cpu_ptr_out) at 0x80490aa
    //   args (right-to-left pushed):
    //     push [0x804afa0]  ; ndpy
    //     push [0x804afa8]  ; hmi_pixmap
    //     push &[ebp-0x1c]  ; out: pitch
    //     push &[ebp-0x20]  ; out: height
    //     push &[ebp-0x24]  ; out: width
    //     push &[ebp-0x30]  ; out: cpu_mapped_ptr (was passed as &result earlier)
    void *cpu_ptr;                // [ebp-0x30]: receives mapped CPU virtual address
    int pitch, h2, w2;
    if (emgdHmiMapPixmap(ndpy, hmi_pixmap, &cpu_ptr, &w2, &h2, &pitch) != 0) return -4;

    // === STEP C: Fill via direct DWORD writes (CPU memset, not GL!) ===
    // 0x80490e9 - 0x80490f8:
    //   uint32_t *dst = cpu_ptr;       // [ebp-0x30] is *(uint32_t**), dst = *[ebp-0x30]
    //   int count = (pitch/4) * height;
    //   for (int i=0; i<count; i++) dst[i] = color;   //  mov [ecx+edx*4], edi
    uint32_t *dst = (uint32_t*)cpu_ptr;
    int count = (pitch >> 2) * h2;       // pitch is in BYTES, divide by 4 for u32 stride
    for (int i = 0; i < count; i++)
        dst[i] = color_argb;

    // === STEP D: Query buffer state (which back-buffer is free) ===
    // emgdHmiBufferState(&s0, &s1, &s2, &s3) at 0x804910a
    //   returns 4 dwords of state. The selected back-buffer index drives steps E.
    int s_idx, s_a, s_b, s_c;     // [ebp-0x40], [ebp-0x3c], [ebp-0x38], [ebp-0x34]
    if (emgdHmiBufferState(&s_idx, &s_a, &s_b, &s_c) != 0) return -2;

    //   switch(s_idx) {
    //     case 0:  active_buf_ptr = &s_b;     // [ebp-0x38]
    //     case 1:  active_buf_ptr = &s_a;     // [ebp-0x3c]
    //     default: active_buf_ptr = &s_c;     // [ebp-0x34]
    //   }
    //   ebx = *active_buf_ptr;   // ebx = framebuffer slot ptr (PVR2DMEMINFO*?)

    // === STEP E: Copy pixmap into framebuffer slot, row by row ===
    // 0x8049156-0x80491aa: chunked memcpy in 0x1000-byte rows.
    //   for (row=0; row<min(h, pitch_h); row++)
    //       memcpy((u8*)fb_slot + row*0x1000, (u8*)cpu_ptr + row*pitch_in,
    //              min(stride_in, 0x1000));
    // (This is the "publish" of the pixmap into the active framebuffer back-buffer.)

    // === STEP F: Unmap ===
    emgdHmiFreeMem(cpu_ptr);                                  // 0x80491b2

    // === STEP G: GL swap (keeps the EGL state machine alive — does NOT show pixels) ===
    eglSwapBuffers(disp, fb_surf);                            // 0x80491c5
    //              ^^^^^^^^^^^^^
    //              uses [0x804afb4]=disp, [0x804afb8]=fb_surf (NOT hmi_surf)

    // === STEP H: THE ACTUAL PUBLISH ===
    // emgdHmiConfigureBuffers(ndpy, &cfg_array[]) at 0x80491fe
    //   args:
    //     push &configs_array        ; lea eax,[ebp-0x48]; the array of 2 pointers
    //                                ;   [ebp-0x48] = &cfg0  (at [ebp-0x128], size ~0xE0)
    //                                ;   [ebp-0x44] = &cfg1  (at [ebp-0x208], size ~0xE0)
    //     push [0x804afa0]           ; ndpy
    //   Each cfg struct has fields set immediately before the call:
    //     cfg0[0] = 1        ([ebp-0x128] = 1)   -- buffer-active flag?
    //     cfg0[0x38] = 0     ([ebp-0xf0]  = 0)   -- some attribute
    //     cfg1[0] = 1        ([ebp-0x208] = 1)   -- buffer-active flag?
    //     cfg1[0x38] = 0     ([ebp-0x1d0] = 0)
    //   ...other fields were left from emgdHmiGetFramebufferSize (it
    //   filled the 224-byte struct at [ebp-0x208] in step A).
    EmgdConfigureBufConfig cfgs[2];
    cfgs[0] = config_for_hmi_pixmap;     // 0xE0-byte struct, includes the fmt info
    cfgs[0].field_0  = 1;
    cfgs[0].field_38 = 0;
    cfgs[1] = config_for_popup_or_fb;
    cfgs[1].field_0  = 1;
    cfgs[1].field_38 = 0;
    EmgdConfigureBufConfig *cfg_ptrs[2] = { &cfgs[0], &cfgs[1] };
    emgdHmiConfigureBuffers(ndpy, cfg_ptrs);                  // 0x80491fe

    return 0;
}
```

### Detailed call decoding (the canonical evidence)

| Addr | Symbol | Push sequence (in order they execute, last pushed = first arg) | Decoded args |
|------|--------|--------------------------------------------------------------|---------------|
| `0x8049057` | `emgdHmiGetFramebufferSize` | `push &[ebp-0x208]; push &[ebp-0x2c]; push &[ebp-0x28]; push [0x804afa0]` | `(ndpy, &w, &h, &fmt_info)` |
| `0x80490aa` | `emgdHmiMapPixmap` | `push [0x804afa0]; push [0x804afa8]; push &[ebp-0x1c]; push &[ebp-0x20]; push &[ebp-0x24]; push &[ebp-0x30]` | `(ndpy, hmi_pix, &out_cpu_ptr, &out_w, &out_h, &out_pitch)` (6 args) |
| `0x804910a` | `emgdHmiBufferState` | `push &[ebp-0x40]; push &[ebp-0x3c]; push &[ebp-0x38]; push &[ebp-0x34]` | `(&idx, &slot_a, &slot_b, &slot_c)` (4 args, all out) |
| `0x80491b2` | `emgdHmiFreeMem` | `push [ebp-0x30]` | `(cpu_ptr)` |
| `0x80491c5` | `eglSwapBuffers` | `push [0x804afb8]; push [0x804afb4]` | `(disp, fb_surf)` |
| `0x80491fe` | `emgdHmiConfigureBuffers` | `push &[ebp-0x48]; push [0x804afa0]` | `(ndpy, &cfg_ptr_array)` where cfg_ptr_array = `{&cfg0_at_[ebp-0x128], &cfg1_at_[ebp-0x208]}` |

---

## Section 6 — Socket interaction (NOT the visibility path — diagnostic noise)

The socket symbol set (`socket`, `connect`, `send`, `close`) is **drawbuf's IPC to drawbufd**, not to emgdhmid. Evidence:

- String at `0x80499e4`: `/tmp/sdupdate_sock`
- Address-family literal: `0x1` (AF_UNIX) at `0x8048f4f`
- Socket type literal: `0x1` (SOCK_STREAM) at `0x8048f4d`
- Path length passed to `connect`: `0x6e = 110` bytes (sun_path size for sockaddr_un)
- `strncpy(addr.sun_path, "/tmp/sdupdate_sock", 0x6b=107)` at `0x8048fa3`
- `send(s, &color_int, 4, 0)` at `0x8048fcd` — sends a single 4-byte int (the color index)

**`/tmp/sdupdate_sock` is the drawbufd command socket.** `drawbuf` writes the color code, `drawbufd` reads it and does the EGL/HMI dance. This is **client-server within the test suite**, NOT a protocol with `emgdhmid`. emgdhmid's socket is `/tmp/.emgdhmid_socket` and is contacted automatically inside `libemgdhmi.so.0` during `emgdHmiGetNativeDisplay`.

---

## Section 7 — Exit / Cleanup

`test_fb_status_finish` (called at program exit):

```c
eglMakeCurrent(disp, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);   // 0x8049809
destroy_egl_resources(emgd_data);     // 0x8049815
destroy_emgd_resource(emgd_data);     // 0x804983e
```

`destroy_egl_resources` (0x8049773): calls `eglDestroyContext`, then `eglDestroySurface` for each of `fb_surf`, `hmi_surf`, `popup_surf` (in that order: 0x18, 0x1c, 0x20 offsets). Nulls each pointer in the struct.

`destroy_emgd_resource` (0x80493d0): calls `emgdHmiDestroyPixmap(ndpy, popup_pixmap)` then `emgdHmiDestroyPixmap(ndpy, hmi_pixmap)`. **It does NOT call any "release framebuffer" function** — the framebuffer is owned by emgdhmid.

**Cleanup order matters:** EGL surfaces released before HMI pixmaps. Destroying a pixmap that still has an EGL surface bound to it would corrupt the WSEGL backend's internal state.

---

## Section 8 — What our spike has been missing (gap analysis)

Our Plan B''' EGL spike does:
```
emgdHmiGetNativeDisplay -> eglGetDisplay -> eglInitialize -> eglChooseConfig
  -> eglCreateContext -> emgdHmiCreatePixmap(1, 800, 480, &pix)
  -> eglCreatePixmapSurface -> eglMakeCurrent -> glClearColor(red) -> glClear
  -> eglSwapBuffers
```

All calls succeed but **nothing appears**. Drawbuf's recipe reveals five missing pieces, **any of which alone could explain invisibility**:

### Missing piece 1 (almost certainly the issue): No emgdHmiConfigureBuffers

`eglSwapBuffers` against a **pixmap surface** is a no-op for visibility — pixmap surfaces are off-screen by definition. Visibility requires either (a) a window-surface bound to the framebuffer (which means calling `emgdHmiGetFramebuffer` first), or (b) explicitly publishing the pixmap via `emgdHmiConfigureBuffers`, which tells emgdhmid "this pixmap is one of my planes — composite it."

**Drawbuf does BOTH:** it binds the window-surface to the framebuffer, AND it calls ConfigureBuffers on the pixmaps after every paint. Our spike does neither.

### Missing piece 2: We're using a pixmap surface as if it were a window

`eglCreatePixmapSurface(disp, cfg, hmi_pix, NULL)` creates an **off-screen** render target. Even `glClear` + `eglSwapBuffers` against it just writes the contents into the pixmap's GTT memory — not the scanout plane. We need `eglCreateWindowSurface(disp, cfg, fb_pix, NULL)` where `fb_pix` came from `emgdHmiGetFramebuffer`, OR we need to publish the pixmap separately.

### Missing piece 3: Drawbuf doesn't draw with GL at all

The pixel data in `set_color_and_display` comes from a **CPU-side `for` loop writing DWORDs into the `emgdHmiMapPixmap` buffer** — not from `glClear`. Drawbuf calls `emgdHmiBufferState`/`emgdHmiMapPixmap`/`emgdHmiFreeMem` for the pixel path and uses GL only to keep the EGL surface "live."

This suggests the WSEGL backend's color-buffer is **decoupled** from the actual scanout buffer. `glClear` colors the WSEGL backbuffer, but the WSEGL→display copy only happens during `emgdHmiConfigureBuffers`. The pixmap and the framebuffer are two distinct GTT allocations.

### Missing piece 4: We never prime with first eglSwapBuffers

Drawbuf calls `eglSwapBuffers` once during `test_fb_status_init` BEFORE the paint loop starts (after `eglMakeCurrent`). This forces WSEGL to materialize the swap chain. Without it, the first `eglSwapBuffers` in the paint loop might fail silently.

### Missing piece 5: We never check emgdHmiBufferState

`emgdHmiBufferState` returns the active/free buffer indices. Drawbuf uses this to pick the correct memcpy destination. Without it we'd be writing to a buffer that's currently being scanned-out, causing tearing or no-op depending on emgdhmid's flip logic.

---

## Section 9 — Concrete fix for our spike

Replace our current spike body with **drawbuf's exact sequence**:

```c
// SETUP (once)
EGLNativeDisplayType ndpy;
emgdHmiGetNativeDisplay(&ndpy);

PVR2DMEMINFO *fb_pix;
EmgdHmiFbInfo fb_info;
emgdHmiGetFramebuffer(ndpy, &fb_pix, &fb_info);

PVR2DMEMINFO *hmi_pix;
emgdHmiCreatePixmap(ndpy, /*EMGD_HMI_BUFFER*/1, 800, 480, &hmi_pix);
//                                                ^^^^
//                          start with 800x480 NOT 800x960 — single panel first

EGLDisplay disp = eglGetDisplay(ndpy);
eglInitialize(disp, NULL, NULL);

EGLint attribs[] = {
    EGL_RED_SIZE,8, EGL_GREEN_SIZE,8, EGL_BLUE_SIZE,8, EGL_ALPHA_SIZE,8,
    EGL_DEPTH_SIZE,24, EGL_STENCIL_SIZE,8,
    EGL_BIND_TO_TEXTURE_RGBA,1,
    /* EGL_SAMPLES,4, */                              // drop MSAA
    EGL_RENDERABLE_TYPE, EGL_OPENGL_ES_BIT,           // GLES1 like drawbuf for first test
    EGL_SURFACE_TYPE, EGL_WINDOW_BIT|EGL_PIXMAP_BIT,
    EGL_NONE
};
EGLConfig cfg; EGLint n;
eglChooseConfig(disp, attribs, &cfg, 10, &n);

EGLSurface fb_surf  = eglCreateWindowSurface(disp, cfg, (EGLNativeWindowType)fb_pix, NULL);
EGLSurface hmi_surf = eglCreatePixmapSurface(disp, cfg, (EGLNativePixmapType)hmi_pix, NULL);
EGLContext ctx      = eglCreateContext(disp, cfg, EGL_NO_CONTEXT, NULL);  // NULL attribs = GLES1
eglMakeCurrent(disp, fb_surf, fb_surf, ctx);
eglSwapBuffers(disp, fb_surf);   // prime

// PAINT (per frame)
uint32_t COLOR = 0xFFFF0000;   // ARGB: opaque red

int dw, dh, dstride;
EmgdHmiFmt fmt_unused;
emgdHmiGetFramebufferSize(ndpy, &dh, &dw, &dstride, &fmt_unused);

void *cpu_ptr; int pitch, h2, w2;
emgdHmiMapPixmap(ndpy, hmi_pix, &cpu_ptr, &w2, &h2, &pitch);
uint32_t *d = (uint32_t*)cpu_ptr;
for (int i = 0; i < (pitch/4)*h2; i++) d[i] = COLOR;

int s_idx, s_a, s_b, s_c;
emgdHmiBufferState(&s_idx, &s_a, &s_b, &s_c);
// (drawbuf does an additional row-by-row memcpy from cpu_ptr into the FB slot
//  selected by s_idx — for the first test we can skip this and rely on
//  ConfigureBuffers to do the composite from the pixmap directly.)

emgdHmiFreeMem(cpu_ptr);
eglSwapBuffers(disp, fb_surf);

// THE PUBLISH
EmgdHmiBufCfg cfg0 = {0}, cfg1 = {0};   // 224-byte struct each — we'll need to RE its layout
cfg0.field_0 = 1; cfg0.field_38 = 0;
cfg1.field_0 = 1; cfg1.field_38 = 0;
EmgdHmiBufCfg *cfgs[2] = { &cfg0, &cfg1 };
emgdHmiConfigureBuffers(ndpy, cfgs);
```

**Open question:** the `EmgdHmiBufCfg` struct (224 bytes) has many fields we haven't decoded. The minimum we know: offset 0 = some "active" flag (set to 1), offset 0x38 = something (set to 0). Other fields are populated by `emgdHmiGetFramebufferSize` calling into the struct via the `&[ebp-0x208]` pointer. So the call sequence is **`emgdHmiGetFramebufferSize` writes into the cfg struct, then we set fields 0 and 0x38, then `emgdHmiConfigureBuffers` reads it.** That's the contract.

**Next step on this thread:** disassemble `libemgdhmi.so.0`'s `emgdHmiConfigureBuffers` function to fully decode the cfg struct layout. The 224-byte size suggests it includes: width, height, pitch, format, plane-z-order, alpha-blend mode, source rect, dest rect, and possibly a callback or flip-token. We have the binary at `/tmp/dsu-slot-a/usr/lib/libemgdhmi.so.0.1.0` — that's the next forensic agent's job if our spike still doesn't paint after applying the above.

---

## Section 10 — Evidence index

- Binary: `/tmp/dsu-slot-a/lib/systemd/system/systemdRelatedFiles/Display_Tools/drawbuf` (24,045 B)
- Daemon variant: `/tmp/dsu-slot-a/lib/systemd/system/systemdRelatedFiles/Display_Tools/drawbufd` (24,018 B)
- Wrapper script: `/tmp/dsu-slot-a/lib/systemd/system/systemdRelatedFiles/Display_Tools/display_color.sh`
- Header path baked into DWARF: `/home/naviwork/work/Display_Tool_source/drawbuf/DrawBuffer_c.c`
- EGL backend lib: `/tmp/dsu-slot-a/usr/lib/wsegl/libwsegl-hmi.so`
- HMI broker client lib: `/tmp/dsu-slot-a/usr/lib/libemgdhmi.so.0.1.0`
- HMI broker daemon: `/tmp/dsu-slot-a/usr/sbin/emgdhmid`

Cross-reference docs (this repo):
- `/Users/dpitek/Developer/q60-rebuild/docs/forensic-factory-ui-binary.md` (Agent 2)
- `/Users/dpitek/Developer/q60-rebuild/docs/forensic-egl-abi.md` (Agent 1)
- `/Users/dpitek/Developer/q60-rebuild/docs/forensic-emgd-init.md` (Agent 6)

---

## Section 11 — One-line summary for the team

**Add `emgdHmiConfigureBuffers(ndpy, cfg_array)` after `eglSwapBuffers`, and ideally paint pixels via `emgdHmiMapPixmap` CPU writes instead of (or in addition to) GL. eglSwapBuffers alone presents nothing — it's just a GL state-machine tick. ConfigureBuffers is the real present.**
