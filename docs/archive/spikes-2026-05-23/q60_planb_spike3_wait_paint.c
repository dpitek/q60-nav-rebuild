// q60_planb_spike3_wait_paint.c
//
// Plan B''' visible-paint test, panel-aware version.
//
// Doug's finding: LVDS panels don't actually power on until ~75s into boot.
// Spike 1c/2 painted at ~20s — invisible because panels were still off.
// This spike waits until after panel-on, kills ALL 4 painters, paints red
// for 15s, then restores everything.
//
// Killing hmictrl_proc would normally break rearview camera (per Agent 5
// forensic). For THIS test that's acceptable — we just need to prove visible
// paint is possible. Production will revisit the kill set.
//
// Boot timeline (target):
//   t=0     ignition
//   t=~75s  factory panels power on
//   t=80s   spike fires:
//             - snapshot /sys/class/backlight before
//             - stop all 4 painters
//             - paint red 15s
//             - snapshot backlight after
//             - restart all 4 painters
//   t=95s   spike done, factory UI rebuilds

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
    snprintf(path, sizeof(path), "/tmp/q60-planb-3-stage-%s.txt", stage);
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

static double uptime(void) {
    FILE *f = fopen("/proc/uptime", "r");
    if (!f) return 0.0;
    double u = 0.0;
    if (fscanf(f, "%lf", &u) != 1) u = 0.0;
    fclose(f);
    return u;
}

#define DLSYM(handle, name) ({ \
    void *_p = dlsym(handle, #name); \
    logf_("  dlsym %s = %p  err=%s\n", #name, _p, dlerror() ?: "(none)"); \
    _p; \
})

#define GL_COLOR_BUFFER_BIT 0x00004000

int main(void) {
    g_log = fopen("/tmp/q60-planb-3.log", "w");
    if (!g_log) g_log = stderr;
    logf_("=== Plan B''' Spike 3 — wait for panels, then paint ===\n");
    logf_("Built %s %s\n", __DATE__, __TIME__);
    logf_("launch uptime=%.2fs pid=%d uid=%d\n", uptime(), getpid(), getuid());

    // ────────────────────────────────────────────────────────────────────
    marker("01_initial_backlight_state");
    // Snapshot before sleep so we can see brightness transition over time
    run_cmd("ls /sys/class/backlight/ 2>&1");
    run_cmd("for b in /sys/class/backlight/*/; do "
            "  echo \"-- $b --\"; "
            "  for f in brightness bl_power max_brightness actual_brightness; do "
            "    [ -f \"$b$f\" ] && printf \"%s = %s\\n\" \"$f\" \"$(cat \"$b$f\")\"; "
            "  done; "
            "done 2>&1");
    run_cmd("ls /sys/class/drm/ 2>&1");
    run_cmd("for c in /sys/class/drm/card*-*/status; do "
            "  echo \"$c = $(cat $c 2>/dev/null)\"; "
            "done 2>&1");

    // ────────────────────────────────────────────────────────────────────
    marker("02_wait_for_panel_on");
    // Sleep ~60s — combined with our ~20s start time = ~80s elapsed, just
    // after Doug's observed 75s panel-on threshold. Poll uptime so we know
    // exact moment.
    double t0 = uptime();
    logf_("  sleeping ~60s, target uptime ~80s\n");
    while (uptime() < 80.0) {
        sleep(2);
        logf_("  uptime=%.1fs\n", uptime());
    }
    logf_("  resumed at uptime=%.2fs (elapsed sleep %.2fs)\n", uptime(), uptime() - t0);

    // ────────────────────────────────────────────────────────────────────
    marker("03_post_wait_backlight_state");
    // Confirm panels are actually on now
    run_cmd("for b in /sys/class/backlight/*/; do "
            "  echo \"-- $b --\"; "
            "  for f in brightness bl_power actual_brightness; do "
            "    [ -f \"$b$f\" ] && printf \"%s = %s\\n\" \"$f\" \"$(cat \"$b$f\")\"; "
            "  done; "
            "done 2>&1");

    // ────────────────────────────────────────────────────────────────────
    marker("04_stop_all_painters");
    run_cmd("systemctl stop nav_navi.service nav_dispapf.service nav_display.service nav_hmictrl.service 2>&1");
    sleep(1);
    run_cmd("ps -A -o pid,comm | grep -E '(navi_ps|hmictrl|display_|dispapf)' || echo '  (no surviving painters)'");

    // ────────────────────────────────────────────────────────────────────
    marker("05_dlopen_and_egl");
    void *libhmi = dlopen("libemgdhmi.so.0", RTLD_NOW | RTLD_GLOBAL);
    void *libegl = dlopen("libEGL.so.1", RTLD_NOW | RTLD_GLOBAL);
    void *libgl  = dlopen("libGLES_CM.so.1", RTLD_NOW | RTLD_GLOBAL);
    if (!libhmi || !libegl || !libgl) { logf_("  dlopen failed\n"); goto restore; }

    int (*emgdHmiGetNativeDisplay)(void **)
        = (int (*)(void **)) dlsym(libhmi, "emgdHmiGetNativeDisplay");
    int (*emgdHmiCreatePixmap)(void *, int, int, int, void **)
        = (int (*)(void *, int, int, int, void **)) dlsym(libhmi, "emgdHmiCreatePixmap");
    EGLDisplay (*p_eglGetDisplay)(EGLNativeDisplayType)
        = (EGLDisplay (*)(EGLNativeDisplayType)) dlsym(libegl, "eglGetDisplay");
    EGLBoolean (*p_eglInitialize)(EGLDisplay, EGLint *, EGLint *)
        = (EGLBoolean (*)(EGLDisplay, EGLint *, EGLint *)) dlsym(libegl, "eglInitialize");
    EGLBoolean (*p_eglChooseConfig)(EGLDisplay, const EGLint *, EGLConfig *, EGLint, EGLint *)
        = (EGLBoolean (*)(EGLDisplay, const EGLint *, EGLConfig *, EGLint, EGLint *))
            dlsym(libegl, "eglChooseConfig");
    EGLContext (*p_eglCreateContext)(EGLDisplay, EGLConfig, EGLContext, const EGLint *)
        = (EGLContext (*)(EGLDisplay, EGLConfig, EGLContext, const EGLint *))
            dlsym(libegl, "eglCreateContext");
    EGLSurface (*p_eglCreatePixmapSurface)(EGLDisplay, EGLConfig, EGLNativePixmapType, const EGLint *)
        = (EGLSurface (*)(EGLDisplay, EGLConfig, EGLNativePixmapType, const EGLint *))
            dlsym(libegl, "eglCreatePixmapSurface");
    EGLBoolean (*p_eglMakeCurrent)(EGLDisplay, EGLSurface, EGLSurface, EGLContext)
        = (EGLBoolean (*)(EGLDisplay, EGLSurface, EGLSurface, EGLContext))
            dlsym(libegl, "eglMakeCurrent");
    EGLBoolean (*p_eglSwapBuffers)(EGLDisplay, EGLSurface)
        = (EGLBoolean (*)(EGLDisplay, EGLSurface)) dlsym(libegl, "eglSwapBuffers");
    void (*p_glClearColor)(float, float, float, float)
        = (void (*)(float, float, float, float)) dlsym(libgl, "glClearColor");
    void (*p_glClear)(unsigned int)
        = (void (*)(unsigned int)) dlsym(libgl, "glClear");
    void (*p_glFinish)(void)
        = (void (*)(void)) dlsym(libgl, "glFinish");

    void *ndpy = NULL;
    int rc = emgdHmiGetNativeDisplay(&ndpy);
    if (rc != 0) { logf_("  emgdHmiGetNativeDisplay rc=%d\n", rc); goto restore; }

    EGLDisplay dpy = p_eglGetDisplay((EGLNativeDisplayType) ndpy);
    EGLint major, minor;
    p_eglInitialize(dpy, &major, &minor);

    EGLint attrs[] = {
        EGL_SURFACE_TYPE,    EGL_PIXMAP_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
        EGL_DEPTH_SIZE, 24, EGL_STENCIL_SIZE, 8,
        EGL_NONE
    };
    EGLConfig cfg;
    EGLint num = 0;
    p_eglChooseConfig(dpy, attrs, &cfg, 1, &num);
    if (num == 0) { logf_("  no EGL config\n"); goto restore; }

    EGLint ctx_attrs[] = { 0x3098, 2, EGL_NONE };
    EGLContext ctx = p_eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, ctx_attrs);
    void *pix = NULL;
    rc = emgdHmiCreatePixmap(ndpy, 1, 800, 480, &pix);
    if (rc != 0 || !pix) { logf_("  pixmap rc=%d\n", rc); goto restore; }
    EGLSurface surf = p_eglCreatePixmapSurface(dpy, cfg, (EGLNativePixmapType) pix, NULL);
    EGLBoolean ok = p_eglMakeCurrent(dpy, surf, surf, ctx);
    if (!ok) { logf_("  makeCurrent failed\n"); goto restore; }
    logf_("  EGL up at uptime=%.2fs\n", uptime());

    // ────────────────────────────────────────────────────────────────────
    marker("06_paint_15s_red");
    // 60 frames × 250ms = 15 seconds. Long enough for Doug to clearly see.
    int frames = 0;
    for (int i = 0; i < 60; i++) {
        p_glClearColor(1.0f, 0.0f, 0.0f, 1.0f);
        p_glClear(GL_COLOR_BUFFER_BIT);
        if (p_glFinish) p_glFinish();
        p_eglSwapBuffers(dpy, surf);
        frames++;
        usleep(250000);
    }
    logf_("  painted %d frames over 15s, uptime=%.2fs\n", frames, uptime());

restore:
    // ────────────────────────────────────────────────────────────────────
    marker("07_restore_painters");
    run_cmd("systemctl start nav_navi.service nav_dispapf.service nav_display.service nav_hmictrl.service 2>&1");

end:
    marker("99_copy_to_boot");
    int crc = system("mountpoint -q /boot || mount /dev/mmcblk0p1 /boot 2>/dev/null "
                     "|| mount /dev/mmcblk1p1 /boot 2>/dev/null");
    (void) crc;
    system("cp /tmp/q60-planb-3.log /boot/Q60_PLANB_SPIKE3.LOG 2>/dev/null; sync");
    system("cp /tmp/q60-planb-3-stage-*.txt /boot/ 2>/dev/null; sync");

    logf_("=== DONE at uptime=%.2fs ===\n", uptime());
    fclose(g_log);
    return 0;
}
