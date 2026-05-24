# Q60 Emulator — Plan B''' Parity Status

**Date:** 2026-05-24
**Goal of the build:** stop burning real-car boots to test changes to the EMGD HMI compositor call chain. Bring the local Linux emulator to the point where the full Plan B''' sequence (`emgdHmiGetNativeDisplay` → `emgdHmiCreatePixmap` → `emgdHmiMapPixmap` → CPU paint → `emgdHmiConfigureBuffers`) can be exercised against a stub `emgdhmid` daemon on a developer's machine — no DCU, no SD card, no 75-second boot delay.

---

## TL;DR

**Built and validated locally:**
- `emu/emgdhmid_stub.c` — 11-opcode stub daemon (190 LOC, listens on `/tmp/.emgdhmid_socket`)
- `emu/libemgdhmi_shim.c` — drop-in for `libemgdhmi.so.0` exposing 11 client exports (220 LOC)
- `emu/Makefile` — builds both i386 ELFs inside Alpine 3.18 via Docker `linux/386`
- `emu/spike_driver.c` — exercises the full call chain
- `emu/test-spike-local.sh` — orchestrates daemon + driver in one disposable container

**Result on the build host (Darwin / Docker linux/386 / Alpine 3.18):**

```
=== spike_driver — Plan B''' call chain against local stub ===
  emgdHmiGetNativeDisplay         rc=0 OK
  ndpy = 0xd39ade6b (expect 0xd39ade6b)
  GetNumScreens -> 2  OK
  emgdHmiGetFramebufferSize       rc=0 OK   framebuffer = 800x960
  emgdHmiGetScreenParams(0)       rc=0 OK   screen[0] = (0,0) 800x480
  emgdHmiGetScreenParams(1)       rc=0 OK   screen[1] = (0,480) 800x480
  emgdHmiCreatePixmap             rc=0 OK   handle = 0x10000
  emgdHmiMapPixmap                rc=0 OK   vaddr = 0x408a9020
  paint check: top-left=0xffff0000 top-right=0xffffffff
  emgdHmiConfigureBuffers         rc=0 OK
  emgdHmiRequestFlip              rc=0 OK   flip indicator = 1
  ConfigureBuffers(bad stride)    rc=-3 OK (caught)
  emgdHmiDestroyPixmap            rc=0 OK
=== PASS — 0 failure(s) ===
```

**Build + run:** `cd emu && make && ./test-spike-local.sh` — under 15 s cold, ~2 s after the alpine image is cached.

---

## What works (with confidence)

| Capability | Source of truth | Confidence |
|---|---|---|
| AF_UNIX socket on `/tmp/.emgdhmid_socket` | matches forensic doc | HIGH |
| Fixed 384-byte messages, both directions | matches forensic doc | HIGH |
| Header layout: `[size:4][name:32][opcode:4]` at offsets 0/4/36 | matches forensic doc | HIGH |
| Opcode 0 GETNUMSCREENS → returns 2 | matches forensic doc payload (`out_count @ +40`) | HIGH |
| Opcode 1 GETFRAMEBUFFERSIZE → returns 800x960 | matches `out_width @ +40, out_height @ +44, retval @ +48` | HIGH |
| Opcode 2 GETSCREENPARAMS → per-screen rect | matches `in_screen @ +40, out_x/y/w/h/retval @ +44..+60` | HIGH |
| Opcode 5 CREATEPIXMAP → monotonic handle starting 0x10000 | matches `in_usage/w/h @ +40/+44/+48, out_handle @ +52, retval @ +56` | HIGH |
| Opcode 6 DESTROYPIXMAP → frees pixmap record | matches `in_pixmap @ +40, retval @ +44` | HIGH |
| Opcode 8 QUERYPIXMAP → returns stored dims | matches `out_w/h/stride/usage/retval @ +44..+60` | HIGH |
| Opcode 9 CONFIGUREBUFFERS → parses 2×3 state matrix, validates each entry, retval @ +380 | matches forensic doc + `EMGDHmiBufferState` 56-byte layout | HIGH |
| Opcode 3 REQUESTFLIP / 4 FLIPSCREEN → no-op success | matches real daemon (stubs in factory binary) | HIGH |
| `emgdHmiGetNativeDisplay` returns magic 0xd39ade6b | matches DWARF-confirmed sentinel | HIGH |
| `emgdHmiMapPixmap` returns process-local memory (no IPC) | mirrors real lib (which calls `PVR2DMemMap` locally) | HIGH |
| `emgdHmiFreeMem` is a no-op success | safe stand-in for `PVR2DMemFree` | MEDIUM |
| Daemon-side `bindSurfaces` validation: `plane_type<=4, x/y>=0, w/h>0, stride>=width` | mirrors forensic-doc §4 validator | HIGH |

The Plan B''' happy path — connect, allocate pixmap, CPU-paint via mapped VA, publish via ConfigureBuffers, flip — runs cleanly end-to-end and the painted memory is the same memory the daemon "sees" via the published handle (the daemon doesn't actually scan it out, but it accepts the handle and the geometry).

---

## What this emulator **does NOT** do (the gaps)

Listed in roughly decreasing order of relevance to Plan B''' iteration.

### 1. No real scanout — no pixels visible anywhere
The stub does not run an `emgd.ko` equivalent, so the painted pixmap memory never reaches a framebuffer. The emulator validates **call sequence and wire correctness**, not pixels-on-glass. If you want to *see* what the Qt app rendered, you still need:
- the existing simulator (`scripts/run-simulator-web.sh` — Qt against host EGL), or
- a real car boot.

For our use case (catching off-by-one errors in the publish path, missing `ConfigureBuffers` calls, wrong struct layout, wrong opcodes) the emulator is sufficient.

### 2. No PVR2D / WSEGL backend
The real `libemgdhmi.so.0` calls `PVR2DCreateDeviceContext`, `PVR2DMemAlloc`, `PVR2DMemMap`, `PVR2DGetFrameBuffer`, and dlopens `/usr/lib/wsegl/libwsegl-hmi.so` for the `EmgdHmiFlipChainState` / `EmgdHmiDestroyPixmap` / `EmgdHmiSetUsage` callbacks. None of that exists here. The shim's `MapPixmap` is a `calloc`. The shim's `Cleanup` doesn't tear down a PVR2D context (there isn't one).

Implication: code paths that read back from PVR2D primitives (e.g. `emgdHmiGetFramebuffer` returning a real `PVR2DMEMINFO*`) will fail. The spike driver does not exercise those — neither does spike7. If a future spike does, the shim will need a fake `PVR2DMEMINFO` builder.

### 3. No EGL / GL
There is no Mesa, no SwiftShader, no WSEGL. Calls like `eglGetDisplay(ndpy)` / `eglCreatePixmapSurface` / `eglSwapBuffers` are NOT exercised by the emulator. The drawbuf forensic call sequence interleaves these with HMI calls; we test only the HMI half.

For Plan B''' the HMI half *is* the interesting half (that's where the missing `ConfigureBuffers` lives). EGL behaviour was already well-understood from the existing Qt simulator.

### 4. SOCK_STREAM not SOCK_DGRAM
The factory daemon binds `AF_UNIX SOCK_DGRAM`; the factory `libemgdhmi.so` opens `AF_UNIX SOCK_STREAM` and `connect()`s. The two work together in practice because `connect()` on a DGRAM socket implicitly sets the peer address. **Our stub uses SOCK_STREAM both sides** because that's the simpler model and matches what `connect()`+`read()`+`write()` does in the shim. The wire bytes are byte-for-byte identical either way — only the framing semantic differs.

A spike that does `recvfrom()` against the stub will not work without a stub change. None of our planned spikes do that.

### 5. No factory-side validations beyond bindSurfaces
The real daemon also does:
- DRM master grab via `drmcmd_master(0x32, ...)` for ConfigureBuffers
- `drmcmd(0x38, plane_table, 0x18c)` to commit plane table to `emgd.ko`
- per-pipe plane-availability check ("No plane available for HMI buffer on pipe %d")
- format coercion via `ControlPlaneFormat` (opcode 7)

We stub these entirely. If a future spike depends on the kernel-side state machine, the stub will report "everything is fine" when in reality the kernel would reject the configuration. **Run the spike on hardware before declaring victory.**

### 6. Plane-availability not modelled
The real `bindSurfaces` maintains a per-screen plane pool (HMI / X11 / Popup / Video). Our stub accepts any plane_type ≤ 4 unconditionally; in reality two clients claiming the same HMI plane on the same pipe race and the loser gets `-3`. If we ever build a multi-client test scenario, this matters.

### 7. `STARTVIDEO` (opcode 10) / `STOPVIDEO` (11) / `CONTROLPLANEFORMAT` (7) / `SWITCHHZ` (12) all default to no-op success
Spike7 doesn't use these. If we add a future video-camera test, we'd need to extend the stub. Opcodes 7/12 are trivial 12-byte payloads (one `int32_t` arg, one retval) and can be added in ~10 lines each when needed.

### 8. EmgdHmiFlipChainState / EmgdHmiSetUsage / EmgdHmiDestroyPixmap (WSEGL callbacks)
The real `libemgdhmi` calls into `/usr/lib/wsegl/libwsegl-hmi.so` for these. Our shim's `emgdHmiBufferState` doesn't exist at all (no caller in the spike); `emgdHmiDestroyPixmap` doesn't try to dlopen anything (it just sends opcode 6). If we later wire in a real WSEGL backend, the shim's pixmap bookkeeping will need to publish these callbacks.

### 9. Stride units assumed bytes (ARGB8888 path)
The shim's `MapPixmap` allocates `w*h*4` bytes unconditionally. If a spike asks for an 8-bit or RGB565 pixmap, the allocation will be over-sized but correct. The daemon's stride validator only checks `stride >= width`, which works in either unit interpretation.

---

## Files in this drop

```
emu/
├── Makefile                      build via docker linux/386 alpine
├── emgdhmid_stub.c               local daemon (~330 LOC incl. comments)
├── libemgdhmi_shim.c             client-side libemgdhmi.so.0 (~250 LOC)
├── spike_driver.c                end-to-end exerciser (~115 LOC)
├── test-spike-local.sh           runs everything in one disposable container
└── build/                        (gitignored) — emitted artefacts
    ├── emgdhmid_stub
    ├── libemgdhmi.so.0
    ├── libemgdhmi.so → libemgdhmi.so.0
    ├── spike_driver
    ├── spike-local.log           full transcript from last test-spike-local.sh
    └── stub.log                  daemon log from last run
```

---

## How to use it

### Daily iteration loop
```
cd /Users/dpitek/Developer/q60-rebuild/emu
make                    # build all three i386 artefacts (Docker-driven)
./test-spike-local.sh   # daemon + driver in one shot, PASS/FAIL exit code
```

### Iterating on a new spike
Don't run spike7 itself directly against the shim — spike7 has hard-coded uptime gates and `/tmp/q60-planb-7-stage-*.txt` markers that won't behave on a host. Instead, **port the spike's HMI calls into `spike_driver.c`** or write a `spike8_driver.c` alongside it. The shim provides the standard libemgdhmi exports the spike would link against.

### Snooping the wire
Stub logs every message it handles to stderr with opcode, args, and return values. Inspect via:
```
cat emu/build/stub.log
```

### Adding a new opcode
1. Add a `case OP_XXXX:` to `handle_msg()` in `emgdhmid_stub.c` (offsets per forensic-libemgdhmi-api.md §3).
2. Add a wrapper export to `libemgdhmi_shim.c`.
3. Call it from `spike_driver.c` to confirm.
4. `make && ./test-spike-local.sh`.

---

## Honest assessment

This is a **call-sequence and wire-format emulator**, not a pixel emulator. It will catch:
- Missing `emgdHmiConfigureBuffers` calls (the original sin of spikes 1–4)
- Wrong opcode values
- Wrong struct field offsets within `EMGDHmiBufferState`
- Reversed argument order
- Missing handles
- Stride/width inversions
- Header `size` field mismatches (silently — daemon doesn't read it)

It will NOT catch:
- DRM/kernel-side issues
- PVR2D allocation failures
- WSEGL flip-chain misbehaviour
- Backlight timing (Doug's 75 s panel-on)
- Plane-arbitration races between us and surviving factory daemons

For the next handful of Plan B''' iterations (where we're still nailing down the publish-step argument layout), this is the right tool. The first time we get a clean PASS here and a black screen in the car, we know to look outside the call-sequence — i.e. at DRM, at the kernel, at `nav_smng`'s residual state, at the backlight I2C path.
