// q60_planb_spike2_paint_masked.c
//
// Plan B''' visible-paint test. Builds on spike 1c's proven paint loop +
// adds the 2-daemon kill from the kill_set memory:
//   - systemctl stop nav_navi.service nav_dispapf.service  (removes the
//     painters that were overdrawing our pixmap at 60 Hz in spike 1c)
//   - paint red for 5s
//   - exit clean
//
// We do NOT mask:
//   - hmictrl_proc — cam.out imports its HMIController singleton (rearview)
//   - display_ps   — cam_disp_stat_shm may be advisory; first-pass keep alive
//   - emgdhmid     — EGL gatekeeper, must stay
//   - camera_ps    — rearview camera path
//
// If LVDS upper shows STABLE red for 5s → Plan B''' architecturally proven
// end-to-end. We then know which daemons to permanently mask in production.
//
// If LVDS still shows nothing → display_ps is also a painter and needs to
// die. Probe that on a later iteration.
//
// Restart daemons at exit so Doug's car isn't left without UI if he doesn't
// power-cycle immediately.

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <dlfcn.h>
#include <sys/stat.h>

#include <EGL/egl.h>
#include <EGL/eglext.h>

static FILE *g_log;

static void logf_(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vfprintf(g_log, fmt, ap);
    va_end(ap);
    fflush(g_log);
    fsync(fileno(g_log));
}

static void marker(const char *stage) {
    char path[128];
    snprintf(path, sizeof(path), "/tmp/q60-planb-2-stage-%s.txt", stage);
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) { dprintf(fd, "%s\n", stage); fsync(fd); close(fd); }
    logf_("\n=== STAGE %s ===\n", stage);
}

static void run_cmd(const char *cmd) {
    logf_("$ %s\n", cmd);
    FILE *p = popen(cmd, "r");
    if (!p) { logf_("  popen errno=%d\n", errno); return; }
    char line[512];
    while (fgets(line, sizeof(line), p)) logf_("  %s", line);
    int rc = pclose(p);
    logf_("  [exit %d]\n", WEXITSTATUS(rc));
}

#define DLSYM(handle, name) ({ \
    void *_p = dlsym(handle, #name); \
    logf_("  dlsym %s = %p  err=%s\n", #name, _p, dlerror() ?: "(none)"); \
    _p; \
})

#define GL_COLOR_BUFFER_BIT 0x00004000
#define GL_NO_ERROR         0

int main(void) {
    g_log = fopen("/tmp/q60-planb-2.log", "w");
    if (!g_log) g_log = stderr;
    logf_("=== Plan B''' Spike 2 — paint with 2-daemon mask ===\n");
    logf_("Built %s %s\n", __DATE__, __TIME__);
    logf_("pid=%d uid=%d\n", getpid(), getuid());

    // ────────────────────────────────────────────────────────────────────
    marker("01_pre_kill_state");
    run_cmd("ps -A -o pid,comm | grep -E '(navi_ps|hmictrl|display|dispapf|emgdhmid|camera)' | head -10");

    marker("02_stop_painters");
    // Use systemctl stop, NOT kill — stop marks unit "inactive" (not "failed"),
    // which avoids the OnFailure cascade ending in poweroff.service.
    run_cmd("systemctl stop nav_navi.service 2>&1");
    run_cmd("systemctl stop nav_dispapf.service 2>&1");
    sleep(1);  // give them time to actually exit
    run_cmd("ps -A -o pid,comm | grep -E '(navi_ps|dispapf)' || echo '  (no surviving painter procs)'");

    // ────────────────────────────────────────────────────────────────────
    marker("03_dlopen");
    void *libhmi = dlopen("libemgdhmi.so.0", RTLD_NOW | RTLD_GLOBAL);
    void *libegl = dlopen("libEGL.so.1", RTLD_NOW | RTLD_GLOBAL);
    void *libgl  = dlopen("libGLES_CM.so.1", RTLD_NOW | RTLD_GLOBAL);
    logf_("  libhmi=%p libegl=%p libgl=%p\n", libhmi, libegl, libgl);
    if (!libhmi || !libegl || !libgl) { logf_("  ABORT — dlopen failed\n"); goto end; }

    int (*emgdHmiGetNativeDisplay)(void **)
        = (int (*)(void **)) DLSYM(libhmi, emgdHmiGetNativeDisplay);
    int (*emgdHmiCreatePixmap)(void *, int, int, int, void **)
        = (int (*)(void *, int, int, int, void **)) DLSYM(libhmi, emgdHmiCreatePixmap);
    EGLDisplay (*p_eglGetDisplay)(EGLNativeDisplayType)
        = (EGLDisplay (*)(EGLNativeDisplayType)) DLSYM(libegl, eglGetDisplay);
    EGLBoolean (*p_eglInitialize)(EGLDisplay, EGLint *, EGLint *)
        = (EGLBoolean (*)(EGLDisplay, EGLint *, EGLint *)) DLSYM(libegl, eglInitialize);
    EGLBoolean (*p_eglChooseConfig)(EGLDisplay, const EGLint *, EGLConfig *, EGLint, EGLint *)
        = (EGLBoolean (*)(EGLDisplay, const EGLint *, EGLConfig *, EGLint, EGLint *))
            DLSYM(libegl, eglChooseConfig);
    EGLContext (*p_eglCreateContext)(EGLDisplay, EGLConfig, EGLContext, const EGLint *)
        = (EGLContext (*)(EGLDisplay, EGLConfig, EGLContext, const EGLint *))
            DLSYM(libegl, eglCreateContext);
    EGLSurface (*p_eglCreatePixmapSurface)(EGLDisplay, EGLConfig, EGLNativePixmapType, const EGLint *)
        = (EGLSurface (*)(EGLDisplay, EGLConfig, EGLNativePixmapType, const EGLint *))
            DLSYM(libegl, eglCreatePixmapSurface);
    EGLBoolean (*p_eglMakeCurrent)(EGLDisplay, EGLSurface, EGLSurface, EGLContext)
        = (EGLBoolean (*)(EGLDisplay, EGLSurface, EGLSurface, EGLContext))
            DLSYM(libegl, eglMakeCurrent);
    EGLBoolean (*p_eglSwapBuffers)(EGLDisplay, EGLSurface)
        = (EGLBoolean (*)(EGLDisplay, EGLSurface)) DLSYM(libegl, eglSwapBuffers);
    EGLint (*p_eglGetError)(void)
        = (EGLint (*)(void)) DLSYM(libegl, eglGetError);
    void (*p_glClearColor)(float, float, float, float)
        = (void (*)(float, float, float, float)) DLSYM(libgl, glClearColor);
    void (*p_glClear)(unsigned int)
        = (void (*)(unsigned int)) DLSYM(libgl, glClear);
    void (*p_glFinish)(void)
        = (void (*)(void)) DLSYM(libgl, glFinish);

    if (!emgdHmiGetNativeDisplay || !p_eglMakeCurrent || !p_eglSwapBuffers
        || !p_glClearColor || !p_glClear) {
        logf_("  ABORT — symbol resolve failed\n"); goto end;
    }

    // ────────────────────────────────────────────────────────────────────
    marker("04_egl_bringup");
    void *ndpy = NULL;
    int rc = emgdHmiGetNativeDisplay(&ndpy);
    logf_("  emgdHmiGetNativeDisplay rc=%d ndpy=%p\n", rc, ndpy);
    if (rc != 0) goto end;

    EGLDisplay dpy = p_eglGetDisplay((EGLNativeDisplayType) ndpy);
    EGLint major, minor;
    p_eglInitialize(dpy, &major, &minor);
    logf_("  eglInitialize EGL %d.%d\n", major, minor);

    EGLint attrs[] = {
        EGL_SURFACE_TYPE,    EGL_PIXMAP_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
        EGL_RED_SIZE,        8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
        EGL_DEPTH_SIZE,      24, EGL_STENCIL_SIZE, 8,
        EGL_NONE
    };
    EGLConfig cfg;
    EGLint num = 0;
    p_eglChooseConfig(dpy, attrs, &cfg, 1, &num);
    if (num == 0) { logf_("  no matching EGL config\n"); goto end; }

    EGLint ctx_attrs[] = { 0x3098 /* EGL_CONTEXT_CLIENT_VERSION */, 2, EGL_NONE };
    EGLContext ctx = p_eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, ctx_attrs);
    if (ctx == EGL_NO_CONTEXT) { logf_("  ctx creation failed\n"); goto end; }

    void *pix = NULL;
    rc = emgdHmiCreatePixmap(ndpy, 1, 800, 480, &pix);
    logf_("  emgdHmiCreatePixmap rc=%d pix=%p\n", rc, pix);
    if (rc != 0 || !pix) goto end;

    EGLSurface surf = p_eglCreatePixmapSurface(dpy, cfg, (EGLNativePixmapType) pix, NULL);
    if (surf == EGL_NO_SURFACE) { logf_("  surface creation failed\n"); goto end; }

    EGLBoolean ok = p_eglMakeCurrent(dpy, surf, surf, ctx);
    if (!ok) { logf_("  eglMakeCurrent failed\n"); goto end; }
    logf_("  EGL context current — about to paint\n");

    // ────────────────────────────────────────────────────────────────────
    marker("05_paint_loop");
    // Slower frame rate than spike 1c (was 100ms = 10fps), now 250ms = 4fps.
    // If display_ps is dead, fewer frames are needed for stable visible red.
    // 20 frames × 250ms = 5s of red.
    int frames = 0, swap_fails = 0;
    for (int i = 0; i < 20; i++) {
        p_glClearColor(1.0f, 0.0f, 0.0f, 1.0f);
        p_glClear(GL_COLOR_BUFFER_BIT);
        if (p_glFinish) p_glFinish();
        EGLBoolean sok = p_eglSwapBuffers(dpy, surf);
        if (!sok) { swap_fails++; if (swap_fails<=3) logf_("  swap fail frame=%d err=0x%x\n", i, p_eglGetError()); }
        frames++;
        usleep(250000);  // 250ms
    }
    logf_("  painted frames=%d swap_fails=%d\n", frames, swap_fails);

    // ────────────────────────────────────────────────────────────────────
    marker("06_restart_daemons");
    // Safety: bring the daemons back so Doug's car has UI again if he forgets
    // to power-cycle. systemd will restart them (Restart=no is default but
    // systemctl start is explicit).
    run_cmd("systemctl start nav_navi.service 2>&1");
    run_cmd("systemctl start nav_dispapf.service 2>&1");

end:
    marker("99_copy_to_boot");
    int crc = system("mountpoint -q /boot || mount /dev/mmcblk0p1 /boot 2>/dev/null "
                     "|| mount /dev/mmcblk1p1 /boot 2>/dev/null");
    (void) crc;
    system("cp /tmp/q60-planb-2.log /boot/Q60_PLANB_SPIKE2.LOG 2>/dev/null; sync");
    system("cp /tmp/q60-planb-2-stage-*.txt /boot/ 2>/dev/null; sync");

    logf_("=== DONE ===\n");
    fclose(g_log);
    return 0;
}
