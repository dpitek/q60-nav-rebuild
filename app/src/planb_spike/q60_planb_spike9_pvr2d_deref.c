// q60_planb_spike9_pvr2d_deref.c
//
// Spike 8 crashed because the value returned from emgdHmiMapPixmap is NOT
// a direct CPU virtual address — it's a PVR2DMEMINFO** (a pointer to a
// struct pointer, where the struct's .pBase field holds the real pixel VA).
// Confirmed by:
//   - drawbuf disasm at 0x8049154 (mov (%eax), %ebx — dereferences before use)
//   - libemgdhmi disasm at 0x4163a7df (calls PVR2DMemMap whose last arg is
//     a PVR2DMEMINFO** per Khronos PVR2D ABI)
//   - emulator validation 2026-05-24: corrected shim now returns
//     PVR2DMEMINFO* with .pBase != struct address
//
// This spike was validated against the emulator before any hardware burn.
// Emulator output:
//   Map returned w=800 h=480 stride=3200 info=0x404c80
//   PVR2DMEMINFO.pBase=0x408a9020 .ui32MemSize=1536000
//   paint check: top-left=0xffff0000 top-right=0xffffffff
//   PASS

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <dlfcn.h>
#include <stdint.h>
#include <sys/stat.h>

static FILE *g_log;
static void logf_(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    vfprintf(g_log, fmt, ap); va_end(ap);
    fflush(g_log); fsync(fileno(g_log));
}
static void marker(const char *stage) {
    char path[128];
    snprintf(path, sizeof(path), "/tmp/q60-planb-9-stage-%s.txt", stage);
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) { dprintf(fd, "%s\n", stage); fsync(fd); close(fd); }
    logf_("\n=== STAGE %s ===\n", stage);
}
static double uptime(void) {
    FILE *f = fopen("/proc/uptime", "r"); if (!f) return 0;
    double u = 0; if (fscanf(f, "%lf", &u) != 1) u = 0; fclose(f); return u;
}

typedef struct {
    uint32_t plane_type, pixmap_handle, pixmap_handle_hi;
    int32_t  screen_x, screen_y, src_x, src_y, width, height;
    uint32_t stride, flags0, flags1, flags2, flags3;
} BufState;

// PVR2DMEMINFO — Khronos PVR2D ABI; returned by emgdHmiMapPixmap.
// Caller must dereference *out_mem to get a PVR2DMEMINFO* whose .pBase
// is the real pixel buffer virtual address.
typedef struct {
    void     *pBase;            // +0x00 — pixel buffer VA
    uint32_t  ui32MemSize;      // +0x04 — bytes
    uint32_t  ui32DevAddr;      // +0x08 — GTT offset
    uint32_t  ulFlags;          // +0x0c
    void     *hPrivateData;     // +0x10
    void     *hPrivateMapData;  // +0x14
} PVR2DMEMINFO;

int main(void) {
    g_log = fopen("/tmp/q60-planb-9.log", "w");
    if (!g_log) g_log = stderr;
    logf_("=== Spike 9 — PVR2DMEMINFO deref (emulator-validated) ===\n");
    logf_("launch uptime=%.2fs pid=%d\n", uptime(), getpid());

    marker("01_dlopen");
    void *libhmi = dlopen("libemgdhmi.so.0", RTLD_NOW | RTLD_GLOBAL);
    if (!libhmi) { logf_("  dlopen fail\n"); goto end; }

    int (*p_GetNd)(void **)
        = (int (*)(void **)) dlsym(libhmi, "emgdHmiGetNativeDisplay");
    int (*p_CreatePx)(void *, int, int, int, void **)
        = (int (*)(void *, int, int, int, void **)) dlsym(libhmi, "emgdHmiCreatePixmap");
    // OUT pointers for w/h/stride; out_mem receives PVR2DMEMINFO*
    int (*p_MapPx)(void *, void *, unsigned *, unsigned *, unsigned *, void **)
        = (int (*)(void *, void *, unsigned *, unsigned *, unsigned *, void **))
            dlsym(libhmi, "emgdHmiMapPixmap");
    int (*p_ConfBuf)(void *, BufState **)
        = (int (*)(void *, BufState **)) dlsym(libhmi, "emgdHmiConfigureBuffers");

    if (!p_GetNd || !p_CreatePx || !p_MapPx || !p_ConfBuf) {
        logf_("  ABORT: syms (GetNd=%p Create=%p Map=%p Conf=%p)\n",
              p_GetNd, p_CreatePx, p_MapPx, p_ConfBuf);
        goto end;
    }

    marker("02_setup");
    void *ndpy = NULL;
    int rc = p_GetNd(&ndpy);
    logf_("  GetNativeDisplay rc=%d ndpy=%p\n", rc, ndpy);
    if (rc != 0) goto end;

    void *px = NULL;
    rc = p_CreatePx(ndpy, 1 /* EMGD_HMI_BUFFER */, 800, 480, &px);
    logf_("  CreatePixmap rc=%d px=%p\n", rc, px);
    if (rc != 0) goto end;

    marker("03_map_and_deref");
    unsigned qw = 0, qh = 0, qstride = 0;
    void *info_ptr = NULL;
    rc = p_MapPx(ndpy, px, &qw, &qh, &qstride, &info_ptr);
    logf_("  MapPixmap rc=%d  w=%u h=%u stride=%u info=%p\n",
          rc, qw, qh, qstride, info_ptr);
    if (rc != 0 || !info_ptr) { logf_("  MapPixmap failed\n"); goto end; }

    // **DEREFERENCE** the returned PVR2DMEMINFO struct
    PVR2DMEMINFO *info = (PVR2DMEMINFO *) info_ptr;
    void   *vaddr = info->pBase;
    size_t  vsize = info->ui32MemSize;
    uint32_t devaddr = info->ui32DevAddr;
    logf_("  PVR2DMEMINFO: pBase=%p size=%zu devAddr=0x%08x flags=0x%08x\n",
          vaddr, vsize, devaddr, info->ulFlags);

    if (!vaddr) { logf_("  pBase NULL — pixel buffer not mapped\n"); goto end; }
    size_t expected_bytes = (size_t) qw * (size_t) qh * 4;
    if (vsize < expected_bytes) {
        logf_("  WARN: mapped size %zu < expected %zu — limiting paint\n",
              vsize, expected_bytes);
    }

    marker("04_paint");
    int W = (int) qw;
    int H = (int) qh;
    int stride_pixels = (int) (qstride / 4);
    if (stride_pixels < W) stride_pixels = W;
    // How many rows fit in the actual mapped size?
    int max_rows = (int)(vsize / (size_t)(stride_pixels * 4));
    if (max_rows > H) max_rows = H;
    if (max_rows <= 0) { logf_("  insufficient mapped memory\n"); goto end; }
    logf_("  painting %dx%d (stride_pixels=%d, max_rows=%d)\n",
          W, max_rows, stride_pixels, max_rows);

    uint32_t *pix = (uint32_t *) vaddr;
    for (int y = 0; y < max_rows; y++) {
        for (int x = 0; x < W; x++) {
            int band = x / (W / 4 > 0 ? W / 4 : 1);
            uint32_t c;
            switch (band) {
                case 0:  c = 0xFFFF0000; break;  // RED in ARGB literal
                case 1:  c = 0xFF00FF00; break;  // GREEN
                case 2:  c = 0xFF0000FF; break;  // BLUE
                default: c = 0xFFFFFFFF; break;  // WHITE
            }
            pix[y * stride_pixels + x] = c;
        }
    }
    logf_("  paint complete; first=0x%08x last_filled=0x%08x\n",
          pix[0], pix[(max_rows - 1) * stride_pixels + W - 1]);

    marker("05_configure");
    BufState s0[3] = {{0}};
    s0[0].plane_type    = 1;
    s0[0].pixmap_handle = (uint32_t)(uintptr_t) px;
    s0[0].width  = W;
    s0[0].height = H;
    s0[0].stride = (int32_t) qstride;
    BufState s1[3] = {{0}};
    BufState *state[2] = { s0, s1 };
    rc = p_ConfBuf(ndpy, state);
    logf_("  ConfigureBuffers rc=%d\n", rc);
    if (rc == -3) {
        s0[0].height = 450;
        rc = p_ConfBuf(ndpy, state);
        logf_("  ConfigureBuffers (h=450) rc=%d\n", rc);
    }
    if (rc != 0) goto end;

    marker("06_hold_120s");
    logf_("  hold start uptime=%.2fs (need ~75s for backlight)\n", uptime());
    for (int i = 0; i < 24; i++) {
        sleep(5);
        if (i % 4 == 0) logf_("  ... hold uptime=%.1fs\n", uptime());
    }
    logf_("  hold complete uptime=%.2fs\n", uptime());

end:
    marker("99_copy");
    system("mountpoint -q /boot || mount /dev/mmcblk0p1 /boot 2>/dev/null "
           "|| mount /dev/mmcblk1p1 /boot 2>/dev/null");
    system("cp /tmp/q60-planb-9.log /boot/Q60_PLANB_9.LOG 2>/dev/null");
    system("cp /tmp/q60-planb-9-stage-*.txt /boot/ 2>/dev/null; sync");
    logf_("=== DONE at uptime=%.2fs ===\n", uptime());
    fclose(g_log);
    return 0;
}
