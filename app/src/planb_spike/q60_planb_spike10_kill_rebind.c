// q60_planb_spike10_kill_rebind.c
//
// Spike 9 proved the API call chain works end-to-end (no crash, all rc=0,
// 1.5MB written to pBase) but produced nothing visible on the LVDS.
//
// Theory: ConfigureBuffers succeeded but other factory daemons (likely
// display_ps or hmictrl_proc) immediately re-call ConfigureBuffers and
// override our binding. Evidence:
//   - Spike 4 (with navi_ps + dispapf_proc killed via systemctl) showed
//     visible purple wash on upper LVDS — our pixmap WAS scanned out.
//   - Spike 9 (no daemon kill) showed nothing.
// The difference is the daemon kill.
//
// Spike 10 = spike 9 + spike 4's kill set + defensive re-bind every 5s
// during the hold to defeat any process trying to re-claim the plane.

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
    snprintf(path, sizeof(path), "/tmp/q60-planb-10-stage-%s.txt", stage);
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) { dprintf(fd, "%s\n", stage); fsync(fd); close(fd); }
    logf_("\n=== STAGE %s ===\n", stage);
}
static void run_cmd(const char *cmd) {
    logf_("$ %s\n", cmd);
    FILE *p = popen(cmd, "r"); if (!p) return;
    char line[512];
    while (fgets(line, sizeof(line), p)) logf_("  %s", line);
    pclose(p);
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

typedef struct {
    void     *pBase;
    uint32_t  ui32MemSize;
    uint32_t  ui32DevAddr;
    uint32_t  ulFlags;
    void     *hPrivateData;
    void     *hPrivateMapData;
} PVR2DMEMINFO;

int main(void) {
    g_log = fopen("/tmp/q60-planb-10.log", "w");
    if (!g_log) g_log = stderr;
    logf_("=== Spike 10 — kill daemons + defensive re-bind ===\n");
    logf_("launch uptime=%.2fs\n", uptime());

    marker("01_stop_daemons");
    // Same kill set as spike 4 (the only spike that showed our pixmap visibly)
    run_cmd("systemctl stop nav_navi.service nav_dispapf.service 2>&1");
    sleep(1);

    marker("02_dlopen");
    void *libhmi = dlopen("libemgdhmi.so.0", RTLD_NOW | RTLD_GLOBAL);
    if (!libhmi) { logf_("  dlopen fail\n"); goto restore; }
    int (*p_GetNd)(void **)
        = (int (*)(void **)) dlsym(libhmi, "emgdHmiGetNativeDisplay");
    int (*p_CreatePx)(void *, int, int, int, void **)
        = (int (*)(void *, int, int, int, void **)) dlsym(libhmi, "emgdHmiCreatePixmap");
    int (*p_MapPx)(void *, void *, unsigned *, unsigned *, unsigned *, void **)
        = (int (*)(void *, void *, unsigned *, unsigned *, unsigned *, void **))
            dlsym(libhmi, "emgdHmiMapPixmap");
    int (*p_ConfBuf)(void *, BufState **)
        = (int (*)(void *, BufState **)) dlsym(libhmi, "emgdHmiConfigureBuffers");
    if (!p_GetNd || !p_CreatePx || !p_MapPx || !p_ConfBuf) {
        logf_("  ABORT syms\n"); goto restore;
    }

    marker("03_setup");
    void *ndpy = NULL;
    int rc = p_GetNd(&ndpy);
    if (rc != 0) { logf_("  GetNd rc=%d\n", rc); goto restore; }
    void *px = NULL;
    rc = p_CreatePx(ndpy, 1, 800, 480, &px);
    if (rc != 0) { logf_("  CreatePx rc=%d\n", rc); goto restore; }

    marker("04_map_and_paint");
    unsigned qw = 0, qh = 0, qstride = 0;
    void *info_ptr = NULL;
    rc = p_MapPx(ndpy, px, &qw, &qh, &qstride, &info_ptr);
    logf_("  MapPx rc=%d w=%u h=%u stride=%u info=%p\n", rc, qw, qh, qstride, info_ptr);
    if (rc != 0 || !info_ptr) goto restore;
    PVR2DMEMINFO *info = (PVR2DMEMINFO *) info_ptr;
    uint32_t *pix = (uint32_t *) info->pBase;
    logf_("  pBase=%p size=%u\n", info->pBase, info->ui32MemSize);
    if (!pix) goto restore;

    int W = (int) qw, H = (int) qh;
    int sp = (int)(qstride / 4); if (sp < W) sp = W;
    for (int y = 0; y < H; y++) {
        for (int x = 0; x < W; x++) {
            int band = x / (W / 4 > 0 ? W / 4 : 1);
            uint32_t c;
            switch (band) {
                case 0:  c = 0xFFFF0000; break;
                case 1:  c = 0xFF00FF00; break;
                case 2:  c = 0xFF0000FF; break;
                default: c = 0xFFFFFFFF; break;
            }
            pix[y * sp + x] = c;
        }
    }
    logf_("  paint done first=0x%08x\n", pix[0]);

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
    logf_("  ConfigureBuffers initial rc=%d\n", rc);
    if (rc == -3) { s0[0].height = 450; rc = p_ConfBuf(ndpy, state); }
    if (rc != 0) goto restore;

    marker("06_hold_with_rebind");
    logf_("  hold start uptime=%.2fs — re-binding every 5s\n", uptime());
    // 24 × 5s = 120s. Every iteration re-calls ConfigureBuffers so any
    // other process that tries to re-claim the HMI plane loses immediately.
    for (int i = 0; i < 24; i++) {
        sleep(5);
        int rc2 = p_ConfBuf(ndpy, state);
        if (i % 4 == 0) {
            logf_("  ... uptime=%.1fs rebind_rc=%d\n", uptime(), rc2);
        }
    }
    logf_("  hold complete uptime=%.2fs\n", uptime());

restore:
    marker("07_restart");
    run_cmd("systemctl start nav_navi.service nav_dispapf.service 2>&1");

    marker("99_copy");
    system("mountpoint -q /boot || mount /dev/mmcblk0p1 /boot 2>/dev/null "
           "|| mount /dev/mmcblk1p1 /boot 2>/dev/null");
    system("cp /tmp/q60-planb-10.log /boot/Q60_PLANB_10.LOG 2>/dev/null");
    system("cp /tmp/q60-planb-10-stage-*.txt /boot/ 2>/dev/null; sync");
    logf_("=== DONE at uptime=%.2fs ===\n", uptime());
    fclose(g_log);
    return 0;
}
