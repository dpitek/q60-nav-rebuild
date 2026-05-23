// q60_planb_spike5_clean_paint.c
//
// Plan B''' refinement spike. Spike 4 proved we can paint to the LVDS upper
// (visible "purple wash" replaced the nav map). This spike addresses two
// observed issues:
//
//   1. Color rendered purple, not red. Likely a pixel-format mismatch
//      between what GL writes (RGBA8 per our config) and what emgd.ko
//      scans out. We test 3 colors in sequence (5s each) so Doug can
//      observe what format is actually being interpreted:
//        - frame block A: red    (1,0,0,1)
//        - frame block B: green  (0,1,0,1)
//        - frame block C: blue   (0,0,1,1)
//      Whatever we see → reverse-engineer the actual format.
//
//   2. Lower screen got clobbered. Per D5 §349: an empty `state[1]` array
//      may be interpreted by the daemon as "unbind everything on screen 1"
//      instead of "leave alone." Two strategies:
//        a) Don't touch screen 1 at all (but the API hardcodes
//           num_screens=2; we must send something)
//        b) Send screen 1 with plane_type=0 entries but populated with
//           sentinel data the daemon might recognize as no-op
//      We try (b) — leave the 3 entries zeroed BUT also set plane_type
//      to a value that the daemon's bindSurfaces validator skips without
//      unbinding. Per D5 §1, plane_type=0 IS the sentinel — the loop
//      exits on first 0. So sending all zeros may still be the unbind.
//
//      Alternative experiment: send state with a valid plane_type but
//      width=0 to fail validation gracefully without unbind.
//
//      For this spike: try the "all zero" approach (same as spike 4 — to
//      confirm reproducibly) AND log what happens to screen 1 in the photo.

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

#include <EGL/egl.h>
#include <EGL/eglext.h>

static FILE *g_log;
static void logf_(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    vfprintf(g_log, fmt, ap); va_end(ap);
    fflush(g_log); fsync(fileno(g_log));
}
static void marker(const char *stage) {
    char path[128];
    snprintf(path, sizeof(path), "/tmp/q60-planb-5-stage-%s.txt", stage);
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
    uint32_t plane_type;       // EMGD_HMI_BUFFER = 1
    uint32_t pixmap_handle;
    uint32_t pixmap_handle_hi;
    int32_t  screen_x, screen_y;
    int32_t  src_x, src_y;
    int32_t  width, height;
    uint32_t stride;
    uint32_t flags0, flags1, flags2, flags3;
} EMGDHmiBufferState;

#define GL_COLOR_BUFFER_BIT 0x00004000
#define GL_RGBA             0x1908
#define GL_UNSIGNED_BYTE    0x1401

int main(void) {
    g_log = fopen("/tmp/q60-planb-5.log", "w");
    if (!g_log) g_log = stderr;
    logf_("=== Spike 5 — color + screen-1 preservation diagnostic ===\n");
    logf_("launch uptime=%.2fs\n", uptime());

    // ── Stage 01: wait for panel-on ──
    marker("01_wait");
    while (uptime() < 80.0) {
        sleep(3);
        logf_("  uptime=%.1fs\n", uptime());
    }
    run_cmd("systemctl is-active nav_pre.target nav_smng.service display_ps_alias 2>&1 | head -5");

    // ── Stage 02: stop kill set ──
    marker("02_stop");
    run_cmd("systemctl stop nav_navi.service nav_dispapf.service 2>&1");
    sleep(1);

    // ── Stage 03: dlopen ──
    marker("03_dlopen");
    void *libhmi = dlopen("libemgdhmi.so.0", RTLD_NOW | RTLD_GLOBAL);
    void *libegl = dlopen("libEGL.so.1", RTLD_NOW | RTLD_GLOBAL);
    void *libgl  = dlopen("libGLES_CM.so.1", RTLD_NOW | RTLD_GLOBAL);
    if (!libhmi || !libegl || !libgl) { logf_("dlopen fail\n"); goto restore; }

    int (*p_GetNd)(void **)
        = (int (*)(void **)) dlsym(libhmi, "emgdHmiGetNativeDisplay");
    int (*p_CreatePx)(void *, int, int, int, void **)
        = (int (*)(void *, int, int, int, void **)) dlsym(libhmi, "emgdHmiCreatePixmap");
    int (*p_ConfBuf)(void *, EMGDHmiBufferState **)
        = (int (*)(void *, EMGDHmiBufferState **)) dlsym(libhmi, "emgdHmiConfigureBuffers");

    EGLDisplay (*p_GetDpy)(EGLNativeDisplayType)
        = (EGLDisplay (*)(EGLNativeDisplayType)) dlsym(libegl, "eglGetDisplay");
    EGLBoolean (*p_Init)(EGLDisplay, EGLint *, EGLint *)
        = (EGLBoolean (*)(EGLDisplay, EGLint *, EGLint *)) dlsym(libegl, "eglInitialize");
    EGLBoolean (*p_ChooseCfg)(EGLDisplay, const EGLint *, EGLConfig *, EGLint, EGLint *)
        = (EGLBoolean (*)(EGLDisplay, const EGLint *, EGLConfig *, EGLint, EGLint *))
            dlsym(libegl, "eglChooseConfig");
    EGLBoolean (*p_GetCfgAttr)(EGLDisplay, EGLConfig, EGLint, EGLint *)
        = (EGLBoolean (*)(EGLDisplay, EGLConfig, EGLint, EGLint *)) dlsym(libegl, "eglGetConfigAttrib");
    EGLContext (*p_CreateCtx)(EGLDisplay, EGLConfig, EGLContext, const EGLint *)
        = (EGLContext (*)(EGLDisplay, EGLConfig, EGLContext, const EGLint *))
            dlsym(libegl, "eglCreateContext");
    EGLSurface (*p_CreatePxSurf)(EGLDisplay, EGLConfig, EGLNativePixmapType, const EGLint *)
        = (EGLSurface (*)(EGLDisplay, EGLConfig, EGLNativePixmapType, const EGLint *))
            dlsym(libegl, "eglCreatePixmapSurface");
    EGLBoolean (*p_MakeCurr)(EGLDisplay, EGLSurface, EGLSurface, EGLContext)
        = (EGLBoolean (*)(EGLDisplay, EGLSurface, EGLSurface, EGLContext)) dlsym(libegl, "eglMakeCurrent");
    EGLBoolean (*p_Swap)(EGLDisplay, EGLSurface)
        = (EGLBoolean (*)(EGLDisplay, EGLSurface)) dlsym(libegl, "eglSwapBuffers");

    void (*p_glClearColor)(float, float, float, float)
        = (void (*)(float, float, float, float)) dlsym(libgl, "glClearColor");
    void (*p_glClear)(unsigned int)
        = (void (*)(unsigned int)) dlsym(libgl, "glClear");
    void (*p_glFinish)(void) = (void (*)(void)) dlsym(libgl, "glFinish");

    if (!p_GetNd || !p_CreatePx || !p_ConfBuf || !p_glClearColor) {
        logf_("missing symbols\n"); goto restore;
    }

    // ── Stage 04: emgdHmi setup ──
    marker("04_setup");
    void *ndpy = NULL;
    int rc = p_GetNd(&ndpy);
    logf_("  GetNd rc=%d\n", rc);
    if (rc != 0) goto restore;

    void *px = NULL;
    rc = p_CreatePx(ndpy, 1, 800, 480, &px);
    logf_("  CreatePixmap rc=%d px=%p\n", rc, px);
    if (rc != 0) goto restore;

    // ── Stage 05: ConfigureBuffers ──
    // Try preserving screen 1: send a valid plane_type but with size 0 so
    // bindSurfaces validation fails *gracefully* without unbinding what's
    // currently there. Per D5 §4: validator returns -3 on width<=0 (jle fail);
    // BUT we don't want a partial commit either. Safer: keep screen 1 fully
    // zeroed and observe — accept the clobber for now, document the trade-off.
    marker("05_configure_buffers");
    EMGDHmiBufferState s0[3] = {{0}};
    s0[0].plane_type    = 1;
    s0[0].pixmap_handle = (uint32_t)(uintptr_t) px;
    s0[0].width  = 800;
    s0[0].height = 480;
    s0[0].stride = 800 * 4;

    EMGDHmiBufferState s1[3] = {{0}};  // empty — will unbind lower screen

    EMGDHmiBufferState *state[2] = { s0, s1 };
    rc = p_ConfBuf(ndpy, state);
    logf_("  ConfigureBuffers rc=%d\n", rc);
    if (rc != 0) { logf_("  failed\n"); goto restore; }

    // ── Stage 06: EGL bringup ──
    marker("06_egl");
    EGLDisplay dpy = p_GetDpy((EGLNativeDisplayType) ndpy);
    EGLint maj, min;
    p_Init(dpy, &maj, &min);

    EGLint attrs[] = {
        EGL_SURFACE_TYPE,    EGL_PIXMAP_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
        EGL_NONE
    };
    EGLConfig cfg;
    EGLint num = 0;
    p_ChooseCfg(dpy, attrs, &cfg, 1, &num);

    // Dump chosen config to log so we know what GL config we actually got
    if (p_GetCfgAttr) {
        EGLint r,g,b,a,d,s;
        p_GetCfgAttr(dpy, cfg, EGL_RED_SIZE, &r);
        p_GetCfgAttr(dpy, cfg, EGL_GREEN_SIZE, &g);
        p_GetCfgAttr(dpy, cfg, EGL_BLUE_SIZE, &b);
        p_GetCfgAttr(dpy, cfg, EGL_ALPHA_SIZE, &a);
        p_GetCfgAttr(dpy, cfg, EGL_DEPTH_SIZE, &d);
        p_GetCfgAttr(dpy, cfg, EGL_STENCIL_SIZE, &s);
        logf_("  cfg RGBA=%d/%d/%d/%d depth=%d stencil=%d\n", r,g,b,a,d,s);
    }

    EGLint ctxa[] = { 0x3098, 2, EGL_NONE };
    EGLContext ctx = p_CreateCtx(dpy, cfg, EGL_NO_CONTEXT, ctxa);
    EGLSurface surf = p_CreatePxSurf(dpy, cfg, (EGLNativePixmapType)(uintptr_t) px, NULL);
    if (!p_MakeCurr(dpy, surf, surf, ctx)) { logf_("  makeCurrent fail\n"); goto restore; }

    // ── Stage 07: color cycle (5s each: RED, GREEN, BLUE) ──
    // Lets Doug observe which channel renders as what. If "red" looks
    // purple/blue/etc, we can back-solve the actual byte order.
    marker("07_paint_color_cycle");
    struct { const char *name; float r, g, b; } colors[] = {
        {"RED",   1.0f, 0.0f, 0.0f},
        {"GREEN", 0.0f, 1.0f, 0.0f},
        {"BLUE",  0.0f, 0.0f, 1.0f},
    };
    for (int c = 0; c < 3; c++) {
        logf_("  painting %s for 5s at uptime=%.1fs\n", colors[c].name, uptime());
        // 20 frames * 250ms = 5s per color
        for (int i = 0; i < 20; i++) {
            p_glClearColor(colors[c].r, colors[c].g, colors[c].b, 1.0f);
            p_glClear(GL_COLOR_BUFFER_BIT);
            if (p_glFinish) p_glFinish();
            p_Swap(dpy, surf);
            usleep(250000);
        }
    }
    logf_("  paint cycle complete at uptime=%.2fs\n", uptime());

restore:
    marker("08_restart");
    run_cmd("systemctl start nav_navi.service nav_dispapf.service 2>&1");

    marker("99_copy");
    system("mountpoint -q /boot || mount /dev/mmcblk0p1 /boot 2>/dev/null "
           "|| mount /dev/mmcblk1p1 /boot 2>/dev/null");
    system("cp /tmp/q60-planb-5.log /boot/Q60_PLANB_SPIKE5.LOG 2>/dev/null; sync");
    system("cp /tmp/q60-planb-5-stage-*.txt /boot/ 2>/dev/null; sync");
    logf_("=== DONE at uptime=%.2fs ===\n", uptime());
    fclose(g_log);
    return 0;
}
