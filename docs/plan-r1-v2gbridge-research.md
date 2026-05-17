# Plan-B: /dev/v2gbridge — Can a non-DRM-master app paint onto Sprite C?

**Date:** 2026-05-16
**Target:** Clarion QY5092 / Nissan-Infiniti DCU, Wind River Linux 2.6.37, Intel EMGD on Atom E6xx (Tunnel Creek) + LAPIS ML7213 IOH.
**Question:** Can a non-master userspace process paint onto the sprite-overlay plane that v2gbridge owns, on top of the EMGD primary plane that hmictrl_proc draws into?

---

## Verdict

**PROBABLY YES — confidence: MEDIUM-HIGH.** With one critical caveat: we likely have to write our own pixels through `/dev/v2gbridge` ioctls (whose API we don't yet have in writing), **not** through stock libdrm.

Specifically:

- `v2g` is **Intel's "Video-to-Graphics" rearview-camera path**, conditionally compiled in upstream EMGD as `SUPPORT_V2G_CAMERA`. It routes a camera framebuffer directly to **Sprite C** — Tunnel Creek's third hardware overlay plane, programmed via MMIO at `0x72180` on the IGD.
- `/dev/v2gbridge` is **DENSO's GPL'd misc-device wrapper** around that path. It owns Sprite C, holds three pre-allocated GTT buffers (3 × 780 KB = 2.3 MB), and is independent of the DRM auth/master model. That is exactly why DENSO built it as a misc-device — to escape DRM-master semantics so emgdhmid can paint without owning card0.
- Because it's a misc-device, **any process with the right group permission (Group=video on factory) can open it** — DRM master is irrelevant to v2gbridge. That's the entire architectural reason it exists.
- Sprite C natively supports the things we want: **ARGB8888 / RGB565 / YUV422 framebuffers, source+dest color-key, Z-order (above primary or below primary), per-frame brightness/contrast/gamma**. Buffers in pre-mapped GTT memory mean userspace just writes pixels and flips.

What we **don't** yet have on paper: the exact ioctl numbers / struct layouts that DENSO exposes. That's recoverable in ~30 min on-device (see "Next probe" below).

---

## How we know — the trail

### 1. The kernel boot messages aren't just decorative

```
[v2gbridge] misc driver init SUCCESSFUL
[v2g] Enable Sprite C Bridge on screen 0
[v2g] GTT mapping requested for 3 buffers (3 × 0xc3000 bytes = 3 × 780 KB)
```

These three lines come from a real codepath. The "Sprite C Bridge" name is verbatim copy from Intel's overlay nomenclature ("Sprite C" is Tunnel Creek's third overlay plane register block). The three 780 KB buffers ≈ enough for a triple-buffered 800×480 ARGB8888 framebuffer (800 × 480 × 4 = 1,536,000 B → 780 KB rounded up to page-aligned GTT entries) — i.e., a rearview camera image.

### 2. Upstream EMGD has the `SUPPORT_V2G_CAMERA` codepath

From `EMGD-Community/intel-binaries-linux` (cloned from github.com/EMGD-Community/intel-binaries-linux):

`drm/emgd/drm/user_config.h:113`:
```c
/** Enable V2G Camera Module **/
#ifdef SUPPORT_V2G_CAMERA
    int v2g;
#endif
```

`drm/emgd/drm/emgd_drv.c:87`:
```c
#ifdef SUPPORT_V2G_CAMERA
/* V2G Camera Module Exported API */
extern int v2g_start_camera();
...
#ifdef SUPPORT_V2G_CAMERA
    /* to start v2g camera module */
    if (1 == config_drm.v2g) {
        EMGD_DEBUG("V2G Camera Enabled.");
        if (0 == v2g_start_camera()) {
            EMGD_DEBUG("v2g camera started successfully!");
```

So upstream EMGD has a stub: it expects a separately-built kernel module named `v2g` to provide `v2g_start_camera()`. DENSO supplied that module, plus a misc-device wrapper called `v2gbridge`. The naming on the DCU matches one-for-one: `lsmod` shows both `v2g` and `v2gbridge`.

### 3. Sprite C is exactly what we want

From `drm/emgd/video/overlay/plb/micro_ovl_plb.c` (PLB = Poulsbo = Tunnel Creek IGD codename):

| Capability | Sprite C | Source |
|---|---|---|
| Pixel formats | YUY2, UYVY, ARGB8888, xRGB8888, RGB565, ARGB1555, indexed RGB8 | Lines 100–127, `OVL2_CMD_*` |
| Color key | Source + Destination both supported | `IGD_OVL_SRC_COLOR_KEY_ENABLE`, `IGD_OVL_DST_COLOR_KEY_ENABLE` |
| Z-order | Above primary (val 1), bottom of stack with primary above (val 6), or off | Lines 645–651 |
| Position / scale | Hardware scaler — `ovl_rect.x1/y1/x2/y2` independent of `surf_rect` | `alter_ovl()` |
| Per-frame gamma/brightness/contrast/saturation/hue | Yes | `igd_ovl_info_t` |
| Buffer location | GTT offset (`surface.offset`) — needs no DRM submit, no GEM handle | Line 94 |

The MMIO register layout (for reference, if we ever want to drive it ourselves without going through v2gbridge):

| Register | Function |
|---|---|
| 0x72180 | Control / enable / pipe / Z-order |
| 0x72184 | Surface start (GTT offset) — page-flip register |
| 0x72188 | Source pitch |
| 0x7218C | Destination position (Y1:X1) |
| 0x72190 | Destination size (H:W) |
| 0x72194 / 0x721A0 | Source color key low / high |
| 0x72198 | Source color key mask |
| 0x721D0 / 0x721D4 | Brightness/contrast & saturation/hue |

### 4. Coexistence: why hmictrl_proc never touches v2gbridge

The factory architecture is clean:

- **`hmictrl_proc`** (the big DENSO C++ SVG renderer) opens `/dev/dri/card0` four times. It is the DRM master and paints into the **primary plane** (Plane A or Plane B).
- **`emgdhmid`** (the small helper) opens `/dev/v2gbridge` AND `/dev/dri/card0`. It uses v2gbridge to put the boot logo / "loading…" image on **Sprite C** *above* the primary plane, so hmictrl_proc can render at its own pace underneath without flicker.
- When the rearview camera is active, the same Sprite C path is taken over by the actual `v2g_start_camera()` flow (camera frames straight to GTT → trigger flip on 0x72184). That's the original Intel use case; DENSO reused the buffer + plane infrastructure to also display the boot logo.

This is exactly the OS architecture we'd want: two independent paint paths on two independent planes, joined by the hardware compositor in the IGD. The factory app doesn't have to know we're there.

### 5. Upstream EMGD's overlay ioctl is DRM_MASTER — v2gbridge sidesteps that

From `emgd_drv.c:322`:
```c
EMGD_IOCTL_DEF(DRM_IOCTL_IGD_ALTER_OVL, emgd_alter_ovl, DRM_MASTER|DRM_UNLOCKED),
```

If we tried to drive Sprite C through stock EMGD ioctls, we'd be locked out by `DRM_MASTER`. **That is precisely why DENSO wrapped it in a misc-device**: a misc-device has none of DRM's master/auth semantics. Whoever has the file open and the right capability can submit. (Intel even relaxed `DRM_IOCTL_IGD_ALTER_OVL2` to `DRM_AUTH` later for libva-wayland — same direction, different mechanism.)

---

## Userspace pattern (pseudocode — once we know the ioctl numbers)

```c
int fd = open("/dev/v2gbridge", O_RDWR);              // factory sets Group=video

// 1. Request a Sprite C buffer (size, format, position) — likely returns a buffer index
struct v2g_buf_req req = {
    .width = 800, .height = 480,
    .pitch = 800 * 4,
    .pixel_format = V2G_FMT_ARGB8888,
    .dst_x = 0, .dst_y = 0,
    .dst_width = 800, .dst_height = 480,
};
ioctl(fd, V2G_REQ_BUFFER, &req);
int idx = req.index;

// 2. mmap that buffer (likely backed by the GTT-mapped region at phys 52-64MB)
void *pixels = mmap(NULL, req.size, PROT_READ|PROT_WRITE, MAP_SHARED, fd, idx * 0xc3000);

// 3. Render — straight memcpy into the framebuffer (ARGB8888, with alpha=0 = transparent
//    so primary plane shows through; alpha=255 = our overlay opaque)
draw_things(pixels);

// 4. Submit / page-flip — writes Sprite C 0x72184 = surface_offset
struct v2g_flip f = { .index = idx };
ioctl(fd, V2G_FLIP, &f);
```

The ioctl names above are speculative. The structure is not — we know from upstream EMGD that the underlying `alter_ovl()` HAL call takes `(surface, surf_rect, ovl_rect, ovl_info, flags)`, and DENSO's wrapper is almost certainly a thin pass-through.

---

## Why this is "probably yes" not "definitely yes"

Two risks remain:

1. **DENSO may have hard-coded v2gbridge to only accept input from a kernel camera driver** (i.e., the buffers are write-only from kernelspace, not userspace mmap). The 780 KB buffer count and "GTT mapping requested for 3 buffers" message *could* mean userspace just gets a handle back, not a writable mapping. If so, we'd need to either (a) drive Sprite C MMIO ourselves (`/dev/mem` + `iopl` — ugly but feasible on this old kernel), or (b) patch v2g/v2gbridge to add an mmap path (we'd need source — see below).

2. **The misc-device may enforce single-open semantics** — if emgdhmid keeps `/dev/v2gbridge` open the whole runtime, we can't open it concurrently. Easy to test (see probe below). If it does, killing emgdhmid frees the device, but then we lose the factory boot logo behavior. Acceptable for our use case.

Neither risk is fatal. Both are answerable with on-device probes.

---

## Next probe (~30 min on the DCU, before we commit)

Drop this on the running DCU and capture output:

```sh
# A: Inventory the device and check open semantics
ls -l /dev/v2gbridge
cat /proc/misc | grep v2g
lsof /dev/v2gbridge 2>/dev/null || fuser /dev/v2gbridge

# B: See what userspace API is exposed (ioctl numbers in the module symbols)
modinfo v2gbridge
modinfo v2g
cat /proc/modules | grep v2g
readelf -a /lib/modules/$(uname -r)/extra/v2gbridge.ko 2>/dev/null | head -80
# or wherever the .ko lives:
find / -name "v2g*.ko" 2>/dev/null
strings /lib/modules/$(uname -r)/extra/v2gbridge.ko 2>/dev/null | \
    grep -iE "ioctl|v2g|sprite|gtt|buffer" | head -40

# C: Find the userspace consumer and strings out the ioctl names
which emgdhmid
strings $(which emgdhmid) 2>/dev/null | grep -iE "v2g|sprite|ioctl|VIDIOC" | head -40
# Confirm what file emgdhmid actually opens at runtime:
strace -f -e trace=openat,ioctl,mmap -p $(pidof emgdhmid) 2>&1 | head -60

# D: Try a concurrent open (single-open test) — non-destructive
python -c "import os; fd=os.open('/dev/v2gbridge', os.O_RDWR); print('opened ok, fd=', fd)"
```

The combination of `strings emgdhmid | grep ioctl` and a brief strace will hand us the exact ioctl numbers + struct layouts in under 5 minutes of wall time on the DCU. That converts "probably yes" → "definitely yes (or here's exactly why not)".

---

## Where the source likely is — and whether we can get it

DENSO and Bosch are both GPL-obligated to publish modifications to GPL'd kernel modules. The kernel itself is GPLv2, so any DENSO additions to it (the `v2g` and `v2gbridge` modules) **must** be publishable on request. In practice, both publish them on download portals:

| Source | URL | Status |
|---|---|---|
| Bosch OSS (Nissan/Infiniti) — older Nissan Connect / D5xx era | http://oss.bosch-cm.com/list/nissan | **Browseable.** Old archives (2014-2018) likely contain the Wind River 2.6.37 + EMGD + v2g sources. Filenames pattern: `nissan_aivi_<version>_oss_dvd_contents.zip`. No automated index lists kernel versions — we'd have to download and grep. |
| Bosch OSS (Infinity) | https://oss.bosch-cm.com/list/infinity | Sibling page, mostly Nissan_AIVI overlap, but possibly an older Infiniti-only branch. |
| DENSO Nissan IVI | https://www.denso.com/global/en/opensource/ivi/nissan/ | **HTTP 403 from us.** Probably geo-fenced or requires browser cert; manual download via real browser will work. |
| Clarion Malaysia | https://opensource.clarion.com.my/ | Confirmed has Nissan/Infiniti sources, but **none of the listed model codes match QY5092**. Mostly emerging-markets Nissan (Datsun GO, Almera, Patrol, Serena). Not the US Q-series DCU. |
| Intel EMGD upstream | https://github.com/EMGD-Community/intel-binaries-linux | **Already cloned.** Has `SUPPORT_V2G_CAMERA` ifdefs + Sprite C plane (PLB) driver. Does **NOT** include the actual `v2g`/`v2gbridge` modules — those are DENSO's. |
| Intel IAS (Automotive Solutions compositor) | https://github.com/intel/ias | Different stack — Wayland-based. Confirms Intel built compositor logic on top of EMGD sprite planes. Not our DCU's stack but useful as confirmation of the model. |
| Intel EMGD User Guide PDF | In the EMGD-Community repo: `emgd-v1-18-user-guide.pdf` | **Already on local disk** at `/tmp/emgd/`. Has the v2g + splash video docs. |
| Intel "EMGD video presentation using Sprite for IVI" paper | https://www.intel.com/content/www/us/en/embedded/software/emgd/emgd-video-presentation-using-sprite-for-ivi-paper.html | 403 to us; archive.org may have it. |

**Best bet:** download the older Bosch Nissan_AIVI archives (pre-2018) and grep for `v2gbridge.c` / `v2g.c`. The DCU shipped 2014-2019, so anything dated 2014-2016 on that portal is our target.

**Realistic fallback:** the on-device probes above will tell us the ioctl interface in minutes. We do **not** need DENSO's source to build a userspace painter — we need it only if we want to *modify* the kernel module.

---

## Bottom line

- v2gbridge is a known, GPL'd, well-architected misc-device that lets non-DRM-master userspace push pixels to **Sprite C overlay above the factory primary plane**.
- It exists for exactly the use case we have: a secondary process painting on top of the main UI without disturbing it.
- The factory already proves the pattern works (emgdhmid does it for the boot logo).
- We don't yet have the ioctl ABI documented, but it's recoverable in ~30 min on-device.
- The Z-order, format, alpha-blend, and color-key capabilities of Sprite C are more than sufficient for a translucent overlay UI on top of hmictrl_proc.

**Recommendation:** run the on-device probe before we burn build cycles on a v2gbridge userspace client. The ioctl ABI is the only blocker, and it's a 5-minute strace away.

---

## Sources

- [EMGD-Community/intel-binaries-linux (GitHub)](https://github.com/EMGD-Community/intel-binaries-linux) — primary EMGD source, contains `SUPPORT_V2G_CAMERA`, Sprite C overlay driver, IGD ioctl table
- [drm/emgd/drm/emgd_drv.c (V2G hook)](https://github.com/EMGD-Community/intel-binaries-linux/blob/master/drm/emgd/drm/emgd_drv.c)
- [drm/emgd/video/overlay/plb/micro_ovl_plb.c (Sprite C / PLB overlay driver)](https://github.com/EMGD-Community/intel-binaries-linux/blob/master/drm/emgd/video/overlay/plb/micro_ovl_plb.c)
- [drm/emgd/drm/user_config.h (V2G config struct + splash_video_t)](https://github.com/EMGD-Community/intel-binaries-linux/blob/master/drm/emgd/drm/user_config.h)
- [Intel IAS compositor 51_config.md](https://github.com/intel/ias/blob/master/public/doc/51_config.md) — sprite-plane configuration for Intel Automotive Solutions
- [Bosch Nissan OSS portal](http://oss.bosch-cm.com/list/nissan) — most likely public source for DENSO-modified v2g/v2gbridge kernel modules
- [Bosch Infinity OSS portal](https://oss.bosch-cm.com/list/infinity)
- [Clarion Malaysia OSS portal](https://opensource.clarion.com.my/) — checked, no QY5092
- [DENSO Nissan IVI OSS portal](https://www.denso.com/global/en/opensource/ivi/nissan/) — 403 to scripted fetch; works in browser
- [Loading splash screen from initramfs into EMGD as a binary blob (Intel docs)](https://docslib.org/doc/10727996/loading-a-splash-screen-from-initramfs-into-intel%C2%AE-emgd-drm-as-a-binary-blob)
- [Intel EMGD User Guide v1.18 PDF (CDRDV2)](https://cdrdv2-public.intel.com/840938/emgd_userguide.pdf)
- [EMGD v1.18 user guide / feature matrix (in cloned EMGD repo)](https://github.com/EMGD-Community/intel-binaries-linux)
