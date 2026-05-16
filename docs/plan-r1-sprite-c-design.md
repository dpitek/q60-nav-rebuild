# Plan R1 — Sprite C overlay client design

**Verdict:** R1 (paint q60nav UI onto Intel Tunnel Creek Sprite C overlay plane via `/dev/v2gbridge`, coexisting with the factory `hmictrl_proc` on the primary plane) is **viable**. The factory `emgdhmid` already proves the pattern — it's a rearview-camera renderer that pipes V4L2 capture frames onto Sprite C via the same path we'd use.

## Established facts (from emgdhmid binary analysis 2026-05-16)

`/usr/sbin/emgdhmid` (57 KB ELF 32-bit) pulled from Slot A. Confirmed ioctl set via `strings`:

| Path | ioctl | Purpose |
|---|---|---|
| `/dev/dri/card0` | `DRM_IOCTL_IGD_CONFIG_BUFFS` | Attach buffers to Sprite C (EMGD-specific) |
| `/dev/dri/card0` | `DRM_IOCTL_IGD_SWITCH_HZ` | Switch refresh rate |
| `/dev/dri/card0` | `DRM_IOCTL_IGD_ALTER_OVL2` | Reconfigure overlay (DRM_AUTH only, no master needed) |
| `/dev/v2gbridge` | `Enable Bridge` | Turn Sprite C compositing on |
| `/dev/v2gbridge` | `V2G_DISABLE_BRIDGE` | Turn it off |
| `/dev/video0` | `VIDIOC_*` (V4L2) | Camera capture (not needed for q60nav UI rendering) |
| LAPIS IOH | `IOH_VIDEO_GET_FRAME_BUFFERS`, `IOH_VIDEO_GET_BUFFER_SIZE` | Allocate GTT-mapped buffers from IOH (camera-side; alternative to PVRSRV DC for buffer allocation) |

User-mode wrappers in `/usr/lib/libemgdsrv_um.so.1.5.15.3226` (138 KB, stripped):

```
PVRSRVGetBCBuffer / PVRSRVGetBCBufferInfo    — Buffer Class (camera producer)
PVRSRVGetDCBuffers / PVRSRVGetDCSystemBuffer — Display Class (framebuffer planes)
PVRSRVSwapToDCBuffer                          — Atomic page-flip
```

EMGD on this device = **EMGD v1.5.15.3226** (Wind River-flavored), built atop PowerVR SGX 535 / Imagination Technologies PVRSRV middleware.

## Key struct (from cloned EMGD source, `drm/emgd/drm/user_config.h:52-62`)

```c
typedef struct _emgd_drm_splash_video {
    unsigned long offset;        // GTT offset of buffer
    unsigned long pixel_format;  // ARGB8888 etc.
    unsigned long src_width;
    unsigned long src_height;
    unsigned long src_pitch;
    unsigned long dst_x;
    unsigned long dst_y;
    unsigned long dst_width;
    unsigned long dst_height;
} emgd_drm_splash_video_t;
```

This is the descriptor passed to `DRM_IOCTL_IGD_ALTER_OVL2` to point Sprite C at our buffer.

## Two implementation paths

### Path A — PVRSRV Display Class swap chain (high-level)

```c
PVRSRVConnect()
PVRSRVOpenDCDevice(sprite_c_index)        // discover by enumerate
PVRSRVCreateDCSwapChain(3 buffers)        // triple-buffered
PVRSRVGetDCBuffers(swap_chain, &buffers[])
mmap(buffers[N])                          // CPU-writable
// render Qt QImage into buffer
PVRSRVSwapToDCBuffer(buffers[N])          // V-sync respecting flip
```

**Pros:** clean abstraction; automatic page-flip; PVRSRV handles GTT mapping + cache coherency.
**Cons:** need to discover Sprite C's DC device index; need PVRSRV headers + linkage (we have `libemgdsrv_um.so` from the pull).

### Path B — Direct DRM ioctls (low-level)

```c
fd = open("/dev/dri/card0", O_RDWR)
drmAuthMagic(fd, ...)                    // need DRM_AUTH (hmictrl_proc grants)

// allocate GTT buffer
ioctl(fd, DRM_IOCTL_GEM_CREATE, &args)
buf = mmap(...)

// render
memcpy(buf, qimage_argb_data, w*h*4);

// attach to Sprite C
emgd_drm_splash_video_t sv = {
    .offset = gtt_offset,
    .pixel_format = ARGB8888,
    .src_width = w, .src_height = h, .src_pitch = w*4,
    .dst_x = 0, .dst_y = 0, .dst_width = 800, .dst_height = 480,
};
ioctl(fd, DRM_IOCTL_IGD_ALTER_OVL2, &sv)

// turn it on
v2g_fd = open("/dev/v2gbridge", O_RDWR)
ioctl(v2g_fd, V2G_ENABLE_BRIDGE_IOCTL, &args)
```

**Pros:** no PVRSRV dependency; smaller link surface; direct visibility into the page-flip flow.
**Cons:** must manage GTT mapping manually; need `DRM_AUTH` token from hmictrl_proc (or run as root which provides implicit master/auth).

## Recommended path

**Path B (direct ioctls)** for the first proof-of-concept:
1. Smaller dependency surface — links only against `libdrm` and standard libc.
2. We have the exact struct layout from EMGD source.
3. Recovery: if we discover we need PVRSRV-only buffers (GTT alignment / coherency issues), switch to Path A.

After PoC: integrate into q60nav by feeding it the `QQuickWindow` output via `grabWindow()` → ARGB8888 QImage → buffer → flip.

## Open questions to settle in hardware test

1. **Exact `V2G_ENABLE_BRIDGE_IOCTL` number.** Recover via `strings` + `objdump -d` of emgdhmid (find ioctl callsite + immediate value).
2. **Color-key format.** Sprite C supports source + dest color-key. If we want transparent regions to show the factory UI underneath (e.g., for a small floating HUD), we need to set color-key. Likely a separate ioctl. Discoverable from the EMGD docs PDF in the cloned repo (`emgd-v1-18-user-guide.pdf`).
3. **Does opening `/dev/v2gbridge` while emgdhmid is also open succeed?** emgdhmid runs constantly per the inventory probe. We need to test concurrent open (likely yes — misc-device drivers usually allow multi-open).
4. **GTT offset allocation.** We need to know where to allocate our buffer in the IGD's GTT aperture. Probably via `DRM_IOCTL_I915_GEM_CREATE` (or EMGD equivalent) which returns a handle, then mmap → offset.

## Build / deploy plan

1. **Cross-compile target:** i386, gcc -m32, statically link minimum deps. Use existing q60-toolchain Docker image.
2. **No Qt yet** — bare C test binary first. Once Sprite C works, build the q60nav→Sprite-C bridge layer separately.
3. **Deploy:** debugfs into Slot A's `/opt/q60nav/sprite-test`. Add systemd unit `q60-spritec-test.service` with `WantedBy=multi-user.target`. (Same pattern that worked for the inventory probe.)
4. **Test:** boot OEM card. Probe should display a known pattern (red rectangle, or moving color bar) on Sprite C. If we see it on the actual LCD without disturbing the factory UI, R1 is proven on hardware.

## Files in scope

- `/tmp/q60-overnight/v2g/emgdhmid` (57 KB, ELF 32-bit)
- `/tmp/q60-overnight/v2g/libEMGD2d.so.1.5.15.3226` (32 KB)
- `/tmp/q60-overnight/v2g/libemgdsrv_init.so.1.5.15.3226` (122 KB)
- `/tmp/q60-overnight/v2g/libemgdsrv_um.so.1.5.15.3226` (138 KB)
- `/tmp/q60-overnight/v2g/libdrm.so.2.4.0` (45 KB)
- `/tmp/emgd/` — cloned EMGD source (Path B struct definitions, partial ioctl handlers)
- `/tmp/q60-overnight/plan-b-v2gbridge.md` — agent research deliverable

## Code we still need to write

- `tests/sprite-c-hello.c` — bare-metal Sprite C client (Path B), ~200 lines of C
- `deps/build-spritec-i386.sh` — cross-compile script
- `scripts/deploy-spritec-test.sh` — debugfs deploy + systemd unit injection
- Eventually: `app/src/ui/spritec_overlay.cpp` — Qt → Sprite C bridge for q60nav
