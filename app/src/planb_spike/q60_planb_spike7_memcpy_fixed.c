// q60_planb_spike7_memcpy_fixed.c
//
// Fixes two things from spike 6:
//   1. emgdHmiMapPixmap signature was wrong (took 6 args, I passed 2).
//      Per D2 forensic: emgdHmiMapPixmap(ndpy, px, w, h, stride, **mem).
//   2. Don't kill any daemons. ConfigureBuffers rebinds the scan-out
//      source; factory daemons keep painting into their pixmaps (which
//      are no longer scanned out) but their touch handling stays alive.
//      No daemon kill = no boot recovery delay if this works.
//
// Backlight timing: GPIO discovery in spike 6 showed gpio253/254 fire
// at uptime 16s but no GPIO changed near Doug's observed panel-on (~75s).
// So the LVDS backlight is most likely an I2C command from display_ps —
// not something we can toggle from /sys/class/gpio. Accept the ~75s
// panel-on for now; we can't beat it without I2C reverse engineering.
//
// Strategy: paint immediately at t=15s, hold for 90s so the painted
// pixmap is still bound when factory panels light up (~75s).

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
    snprintf(path, sizeof(path), "/tmp/q60-planb-7-stage-%s.txt", stage);
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

int main(void) {
    g_log = fopen("/tmp/q60-planb-7.log", "w");
    if (!g_log) g_log = stderr;
    logf_("=== Spike 7 — fixed MapPixmap, no daemon kill ===\n");
    logf_("launch uptime=%.2fs\n", uptime());

    // ── Stage 01: dlopen — no need to wait, no daemons to stop ──
    marker("01_dlopen");
    void *libhmi = dlopen("libemgdhmi.so.0", RTLD_NOW | RTLD_GLOBAL);
    if (!libhmi) { logf_("  dlopen fail\n"); goto end; }

    // CORRECTED SIGNATURE (was wrong in spike 6):
    //   EMGDerr emgdHmiMapPixmap(EGLNativeDisplayType display,
    //                            EGLNativePixmapType pixmap,
    //                            unsigned int w, unsigned int h,
    //                            unsigned int stride,
    //                            PVR2D_VOID **mem)
    int (*p_GetNd)(void **)
        = (int (*)(void **)) dlsym(libhmi, "emgdHmiGetNativeDisplay");
    int (*p_CreatePx)(void *, int, int, int, void **)
        = (int (*)(void *, int, int, int, void **)) dlsym(libhmi, "emgdHmiCreatePixmap");
    int (*p_MapPx)(void *, void *, unsigned, unsigned, unsigned, void **)
        = (int (*)(void *, void *, unsigned, unsigned, unsigned, void **))
            dlsym(libhmi, "emgdHmiMapPixmap");
    int (*p_ConfBuf)(void *, BufState **)
        = (int (*)(void *, BufState **)) dlsym(libhmi, "emgdHmiConfigureBuffers");
    logf_("  syms: GetNd=%p CreatePx=%p MapPx=%p ConfBuf=%p\n",
          p_GetNd, p_CreatePx, p_MapPx, p_ConfBuf);
    if (!p_GetNd || !p_CreatePx || !p_MapPx || !p_ConfBuf) {
        logf_("  ABORT: missing symbols\n"); goto end;
    }

    // ── Stage 02: emgdHmi setup ──
    marker("02_setup");
    void *ndpy = NULL;
    int rc = p_GetNd(&ndpy);
    logf_("  GetNativeDisplay rc=%d ndpy=%p\n", rc, ndpy);
    if (rc != 0) goto end;

    void *px = NULL;
    rc = p_CreatePx(ndpy, 1 /* EMGD_HMI_BUFFER */, 800, 480, &px);
    logf_("  CreatePixmap rc=%d px=%p\n", rc, px);
    if (rc != 0) goto end;

    // ── Stage 03: map with CORRECT 6-arg signature ──
    marker("03_map");
    void *vaddr = NULL;
    rc = p_MapPx(ndpy, px, 800, 480, 800 * 4, &vaddr);
    logf_("  MapPixmap(ndpy, px, 800, 480, 3200, &vaddr) rc=%d vaddr=%p\n", rc, vaddr);
    if (rc != 0 || !vaddr) { logf_("  MapPixmap failed\n"); goto end; }

    // ── Stage 04: paint 4 vertical color bars ──
    marker("04_paint");
    uint32_t *pix = (uint32_t *) vaddr;
    for (int y = 0; y < 480; y++) {
        for (int x = 0; x < 800; x++) {
            int band = x / 200;
            uint32_t c;
            switch (band) {
                case 0:  c = 0xFFFF0000; break;  // ARGB literal RED
                case 1:  c = 0xFF00FF00; break;  // ARGB literal GREEN
                case 2:  c = 0xFF0000FF; break;  // ARGB literal BLUE
                default: c = 0xFFFFFFFF; break;  // WHITE
            }
            pix[y * 800 + x] = c;
        }
    }
    logf_("  painted 4 bars; first pixel = 0x%08x  last = 0x%08x\n",
          pix[0], pix[480 * 800 - 1]);

    // ── Stage 05: bind to scanout — DO NOT kill any daemons ──
    marker("05_configure");
    BufState s0[3] = {{0}};
    s0[0].plane_type    = 1;
    s0[0].pixmap_handle = (uint32_t)(uintptr_t) px;
    s0[0].width  = 800;
    s0[0].height = 480;
    s0[0].stride = 800 * 4;
    BufState s1[3] = {{0}};
    BufState *state[2] = { s0, s1 };
    rc = p_ConfBuf(ndpy, state);
    logf_("  ConfigureBuffers rc=%d\n", rc);
    if (rc != 0) { logf_("  ConfigureBuffers failed\n"); goto end; }

    // ── Stage 06: hold 90s — covers normal backlight-on window (~75s) ──
    // Without killing daemons: factory keeps painting their (now hidden)
    // pixmaps. Our buffer is what the kernel scans out. Backlight comes
    // on at its normal time. Doug should see our 4 bars then.
    marker("06_hold_90s");
    logf_("  holding 90s starting uptime=%.2fs\n", uptime());
    for (int i = 0; i < 18; i++) {  // 18 × 5s = 90s
        sleep(5);
        logf_("  ... hold uptime=%.1fs\n", uptime());
    }
    logf_("  hold complete uptime=%.2fs\n", uptime());

end:
    marker("99_copy");
    system("mountpoint -q /boot || mount /dev/mmcblk0p1 /boot 2>/dev/null "
           "|| mount /dev/mmcblk1p1 /boot 2>/dev/null");
    system("cp /tmp/q60-planb-7.log /boot/Q60_PLANB_SPIKE7.LOG 2>/dev/null");
    system("cp /tmp/q60-planb-7-stage-*.txt /boot/ 2>/dev/null; sync");
    logf_("=== DONE at uptime=%.2fs ===\n", uptime());
    fclose(g_log);
    return 0;
}
