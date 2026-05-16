/*
 * q60nav_sprite_c.c — R1 client: paint a colored rectangle onto Tunnel Creek
 * Sprite C overlay plane via DRM_IGD_ALTER_OVL2 + /dev/v2gbridge enable.
 *
 * Coexists with factory hmictrl_proc on the primary plane. Our buffer renders
 * ABOVE the factory UI via the sprite-overlay path that emgdhmid uses for the
 * rearview-camera.
 *
 * Phased test progression:
 *   Phase A: just open /dev/v2gbridge + /dev/dri/card0 + V2G_ENABLE/DISABLE
 *            cycle. Sees if the bridge can be toggled without a buffer
 *            configured (might show garbage GTT memory; either way, we know if
 *            the device responds).
 *   Phase B: + GMM_ALLOC_REGION to get a GTT-mapped buffer
 *   Phase C: + memset(buffer, 0xFF, ...) red ARGB8888 fill
 *   Phase D: + DRM_IOCTL_IGD_ALTER_OVL2 with cmd=CMD_ALTER_OVL2_OSD
 *   Phase E: V2G_ENABLE_BRIDGE — visible result
 *   Phase F: cleanup — DISABLE + cleanup buffer
 *
 * For the FIRST iteration we just do Phase A. Each ioctl call is logged to
 * /boot/Q60_R1.LOG (or /tmp fallback).
 *
 * Build (musl static for ABI-portability between emulator and real DCU):
 *   docker run --rm --platform linux/386 -v $(pwd):/build alpine:latest sh -c \
 *     "apk add gcc musl-dev binutils && \
 *      gcc -static -no-pie -O2 -Wall -o /build/q60nav_sprite_c /build/q60nav_sprite_c.c && \
 *      objcopy --remove-section=.note.ABI-tag --strip-all /build/q60nav_sprite_c"
 *
 * Test under emulator:
 *   docker run --rm --platform linux/386 -v $(pwd):/build:ro q60-dsu:latest \
 *     /build/q60nav_sprite_c
 *
 * Deploy to DCU (via debugfs into Slot A):
 *   debugfs -w -R "write q60nav_sprite_c /opt/q60r1/sprite_test" /dev/rdiskNs2
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <errno.h>
#include <time.h>

/* ----- ioctl numbers (recovered from emgdhmid strings + emgd_drm.h) ----- */
#define V2G_ENABLE_BRIDGE   0xc0047600u   /* _IOWR('v', 0, int) */
#define V2G_DISABLE_BRIDGE  0xc0047601u   /* _IOWR('v', 1, int) */

/* DRM_COMMAND_BASE = 0x40; DRM_IGD_ALTER_OVL2 = 0x2f → 0x6f; with sizeof
 * emgd_drm_alter_ovl2_t (i386, ~152 bytes worst case but we round) */
#define DRM_IGD_ALTER_OVL2_NR    0x6f
#define DRM_IGD_GMM_ALLOC_REGION_NR 0x4e

/* Phase A only uses /dev/v2gbridge open + ENABLE/DISABLE — no need to compute
 * the alter_ovl2 ioctl yet. Kept here for forward reference. */

/* ----- logging ----- */
#define PRIMARY_LOG  "/boot/Q60_R1.LOG"
#define FALLBACK_LOG "/tmp/Q60_R1.LOG"

static FILE *open_log(void) {
    FILE *f = fopen(PRIMARY_LOG, "w");
    if (f) return f;
    return fopen(FALLBACK_LOG, "w");
}

#define LOG(fmt, ...) do { \
    if (logf) { fprintf(logf, fmt "\n", ##__VA_ARGS__); fflush(logf); } \
    fprintf(stderr, fmt "\n", ##__VA_ARGS__); \
} while (0)

static FILE *logf;

/* ----- phase implementations ----- */

static int phase_a_bridge_toggle(int v2g_fd) {
    LOG("[Phase A] V2G enable/disable cycle");
    int arg = 1;
    int r = ioctl(v2g_fd, V2G_ENABLE_BRIDGE, &arg);
    if (r < 0) {
        LOG("  V2G_ENABLE_BRIDGE failed: r=%d errno=%d (%s)", r, errno, strerror(errno));
        return -1;
    }
    LOG("  V2G_ENABLE_BRIDGE OK (arg-out=%d) — sleeping 8 sec, observe LCD", arg);
    sleep(8);

    int zero = 0;
    r = ioctl(v2g_fd, V2G_DISABLE_BRIDGE, &zero);
    LOG("  V2G_DISABLE_BRIDGE: r=%d errno=%d", r, errno);
    return 0;
}

/* Phase B+: GMM alloc — minimal struct, only fields we know matter.
 * Reference: emgd_drm_gmm_alloc_region_t from emgd_drm.h (offset 318 in our copy):
 *   int rtn;
 *   unsigned long offset;     // OUT
 *   unsigned long size;       // IN/OUT
 *   unsigned int type;        // IN
 *   unsigned long flags;      // IN
 * Total i386: 20 bytes
 */
struct gmm_alloc_region {
    int rtn;
    unsigned long offset;
    unsigned long size;
    unsigned int type;
    unsigned long flags;
};

static int phase_b_alloc_buffer(int drm_fd, struct gmm_alloc_region *out) {
    LOG("[Phase B] GMM alloc 800x480 ARGB8888 buffer (1.5 MB)");
    struct gmm_alloc_region req = {
        .rtn = 0,
        .offset = 0,
        .size = 800 * 480 * 4,   /* 1,536,000 bytes */
        .type = 0,                /* surface type — TBD; 0 = system mem? */
        .flags = 0,
    };
    /* Compute ioctl number: _IOWR('d', 0x4e, sizeof(struct)) = ... */
    unsigned long size_bits = sizeof(req);
    unsigned long ioctl_num = (3u << 30) | (size_bits << 16) | ('d' << 8) | DRM_IGD_GMM_ALLOC_REGION_NR;
    LOG("  ioctl(0x%lx, struct size=%lu)", ioctl_num, (unsigned long)sizeof(req));
    int r = ioctl(drm_fd, ioctl_num, &req);
    if (r < 0) {
        LOG("  GMM_ALLOC_REGION failed: r=%d rtn=%d errno=%d (%s)", r, req.rtn, errno, strerror(errno));
        return -1;
    }
    LOG("  GMM_ALLOC_REGION OK: offset=0x%lx size=%lu", req.offset, req.size);
    *out = req;
    return 0;
}

int main(int argc, char **argv) {
    logf = open_log();
    if (logf) setvbuf(logf, NULL, _IOLBF, 0);

    time_t t = time(NULL);
    LOG("=== Q60 R1 Sprite C test — %s", ctime(&t));
    LOG("argv0=%s pid=%d uid=%d", argv[0], (int)getpid(), (int)getuid());

    /* Open /dev/dri/card0 */
    int drm_fd = open("/dev/dri/card0", O_RDWR);
    if (drm_fd < 0) {
        LOG("open(/dev/dri/card0) FAILED errno=%d (%s)", errno, strerror(errno));
        return 1;
    }
    LOG("open(/dev/dri/card0) OK fd=%d", drm_fd);

    /* Open /dev/v2gbridge */
    int v2g_fd = open("/dev/v2gbridge", O_RDWR);
    if (v2g_fd < 0) {
        LOG("open(/dev/v2gbridge) FAILED errno=%d (%s)", errno, strerror(errno));
        close(drm_fd);
        return 2;
    }
    LOG("open(/dev/v2gbridge) OK fd=%d", v2g_fd);

    /* Phase B: allocate a 800x480 ARGB8888 buffer via DRM_IGD_GMM_ALLOC_REGION */
    struct gmm_alloc_region buf;
    int b_ok = (phase_b_alloc_buffer(drm_fd, &buf) == 0);

    /* Phase C: fill the buffer with red (ARGB8888 = 0xFFFF0000 little-endian) */
    void *mapped = NULL;
    if (b_ok) {
        LOG("[Phase C] mmap + fill buffer (size=%lu)", buf.size);
        mapped = mmap(NULL, buf.size, PROT_READ | PROT_WRITE,
                      MAP_SHARED, drm_fd, buf.offset);
        if (mapped == MAP_FAILED) {
            LOG("  mmap FAILED errno=%d (%s)", errno, strerror(errno));
            mapped = NULL;
        } else {
            LOG("  mmap OK at %p", mapped);
            unsigned int *pixels = (unsigned int *)mapped;
            unsigned int count = buf.size / 4;
            for (unsigned int i = 0; i < count; i++) pixels[i] = 0xFFFF0000;  /* opaque red */
            LOG("  filled %u pixels with 0xFFFF0000 (red ARGB8888)", count);
        }
    }

    /* Phase D: attach buffer to Sprite C OSD plane via DRM_IOCTL_IGD_ALTER_OVL2 */
    if (b_ok && mapped) {
        LOG("[Phase D] DRM_IOCTL_IGD_ALTER_OVL2 (cmd=CMD_ALTER_OVL2_OSD=2)");
        /* Exact emgd_drm_alter_ovl2_t layout on i386 (computed from EMGD source):
         *   off 0   int   rtn                     (4)
         *   off 4   ptr   display_handle          (4)
         *   off 8   igd_surface_t src_surf       (112)
         *     off 8    unsigned long offset        (GTT offset of our buffer)
         *     off 12   unsigned int  pitch         (bytes per row)
         *     off 16   unsigned int  width
         *     off 20   unsigned int  height
         *     off 24   unsigned long u_offset      (YUV-only, zero)
         *     off 28   unsigned int  u_pitch
         *     off 32   unsigned long v_offset
         *     off 36   unsigned int  v_pitch
         *     off 40   unsigned long pixel_format  (0 = let kernel default; for ARGB8888 set right value)
         *     off 44   ptr  palette_info           (NULL for non-paletted)
         *     off 48   unsigned long flags         (GMM alignment flags)
         *     off 52   unsigned int  logic_ops
         *     off 56   unsigned int  render_ops
         *     off 60   unsigned int  alpha
         *     off 64   unsigned int  diffuse
         *     off 68   unsigned long chroma_high
         *     off 72   unsigned long chroma_low
         *     off 76   ptr  virt_addr
         *     off 80   ptr  pvr2d_mem_info
         *     off 84   ptr  pvr2d_context_h
         *     off 88   unsigned long FlipChainID
         *     off 92   ptr  hPVR2DFlipChain
         *     off 96   float proc_amp_const[6]    (24 bytes)
         *   off 120 igd_rect_t src_rect           (16: x1,y1,x2,y2)
         *   off 136 igd_rect_t dst_rect           (16)
         *   off 152 igd_ovl_info_t ovl_info        (40)
         *   off 192 unsigned long flags            (4)
         *   off 196 int cmd                        (4)
         *   total = 200 bytes
         */
        unsigned char request[200] = {0};
        int *rtn = (int *)&request[0];

        /* fill src_surf */
        *(unsigned long *)&request[8]  = buf.offset;    /* offset */
        *(unsigned int  *)&request[12] = 800 * 4;       /* pitch */
        *(unsigned int  *)&request[16] = 800;           /* width */
        *(unsigned int  *)&request[20] = 480;           /* height */
        /* pixel_format = 0 → kernel default; for ARGB8888 the value is platform-specific
         * but most EMGD versions use 'BGRA' fourcc (0x41524742) or IGD_PF_ARGB32_8888 */
        *(unsigned long *)&request[40] = 0x41524742;    /* 'BGRA' fourcc — try first */

        /* fill src_rect (entire buffer) */
        *(unsigned int *)&request[120] = 0;             /* x1 */
        *(unsigned int *)&request[124] = 0;             /* y1 */
        *(unsigned int *)&request[128] = 800;           /* x2 */
        *(unsigned int *)&request[132] = 480;           /* y2 */

        /* fill dst_rect (full screen) */
        *(unsigned int *)&request[136] = 0;             /* x1 */
        *(unsigned int *)&request[140] = 0;             /* y1 */
        *(unsigned int *)&request[144] = 800;           /* x2 */
        *(unsigned int *)&request[148] = 480;           /* y2 */

        /* cmd at offset 196 */
        *(int *)&request[196] = 2;                       /* CMD_ALTER_OVL2_OSD */

        unsigned long ioctl_num = (3u << 30) | (((unsigned long)sizeof(request)) << 16)
                                | ('d' << 8) | DRM_IGD_ALTER_OVL2_NR;
        LOG("  ioctl(0x%lx, size=%zu, cmd=2/OSD, ARGB8888 800x480 → full screen)",
            ioctl_num, sizeof(request));
        int r = ioctl(drm_fd, ioctl_num, request);
        LOG("  ALTER_OVL2 r=%d rtn=%d errno=%d (%s)", r, *rtn, errno, strerror(errno));
    }

    /* Phase E: enable v2gbridge — visible result on real HW */
    if (b_ok && mapped) {
        LOG("[Phase E] V2G_ENABLE_BRIDGE + 10 sec observe window");
        int arg = 1;
        int r = ioctl(v2g_fd, V2G_ENABLE_BRIDGE, &arg);
        LOG("  enable: r=%d errno=%d", r, errno);
        sleep(10);

        int zero = 0;
        r = ioctl(v2g_fd, V2G_DISABLE_BRIDGE, &zero);
        LOG("  disable: r=%d errno=%d", r, errno);
    } else {
        /* Fall back to just phase A toggle if alloc failed */
        phase_a_bridge_toggle(v2g_fd);
    }

    /* Phase F: cleanup */
    if (mapped) munmap(mapped, buf.size);

    LOG("=== Cleanup ===");
    close(v2g_fd);
    close(drm_fd);

    LOG("=== Q60 R1 test done ===");
    if (logf) fclose(logf);
    return 0;
}
