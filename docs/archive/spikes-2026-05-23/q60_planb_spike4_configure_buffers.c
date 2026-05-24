// q60_planb_spike4_configure_buffers.c
//
// Plan B''' visible paint — the real one.
//
// Synthesis of D1+D2+D3+D5 forensic findings: the missing call is
// emgdHmiConfigureBuffers, which sends a 384-byte AF_UNIX DGRAM message
// (opcode 9) that maps our pixmap into emgd.ko's scanout buffer table
// via DRM_IOCTL_IGD_CONFIG_BUFFS. Without this, pixmap is allocated in
// the daemon's std::map but never bound to a plane slot — so anything
// rendered into it stays invisible.
//
// Per D4: backlight isn't a magic call. It comes on as a side effect of
// nav_pre.target services completing (bound by /home/naviwork mount +
// nav_smng orchestration), typically ~75s into boot. Wait for that.
//
// Per kill_set memory: stop ONLY nav_navi + nav_dispapf — keeping
// display_ps + hmictrl_proc alive preserves backlight orchestration
// and rearview camera path.
//
// Sequence:
//   1. Wait until uptime > 80s (after normal panel-on)
//   2. Stop nav_navi + nav_dispapf
//   3. emgdHmiGetNativeDisplay
//   4. emgdHmiCreatePixmap(ndpy, EMGD_HMI_BUFFER=1, 800, 480, &px)
//   5. *** emgdHmiConfigureBuffers(ndpy, state) — THE MISSING CALL ***
//   6. eglCreatePixmapSurface + eglMakeCurrent
//   7. glClearColor(red) + glClear + eglSwapBuffers × 60 frames @ 4fps = 15s
//   8. Restart nav_navi + nav_dispapf

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
    snprintf(path, sizeof(path), "/tmp/q60-planb-4-stage-%s.txt", stage);
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

// EMGDHmiBufferState — 56 bytes — per D5 forensic (offsets confirmed from
// libemgdhmi disasm and emgdhmid::bindSurfaces validator)
typedef struct {
    uint32_t plane_type;        // +0x00  EMGD_HMI_BUFFER = 1
    uint32_t pixmap_handle;     // +0x04  low 32 bits of pixmap from emgdHmiCreatePixmap
    uint32_t pixmap_handle_hi;  // +0x08  always 0 on this platform
    int32_t  screen_x;          // +0x0c
    int32_t  screen_y;          // +0x10
    int32_t  src_x;             // +0x14
    int32_t  src_y;             // +0x18
    int32_t  width;             // +0x1c  must satisfy screen_x + width <= screen_width
    int32_t  height;            // +0x20  must satisfy screen_y + height <= per_screen_h
    uint32_t stride;            // +0x24  bytes (per D5 §6, byte-pitch most likely)
    uint32_t flags0;            // +0x28  passthrough, zero is safe
    uint32_t flags1;            // +0x2c
    uint32_t flags2;            // +0x30
    uint32_t flags3;            // +0x34
} EMGDHmiBufferState;

#define GL_COLOR_BUFFER_BIT 0x00004000

int main(void) {
    g_log = fopen("/tmp/q60-planb-4.log", "w");
    if (!g_log) g_log = stderr;
    logf_("=== Plan B''' Spike 4 — ConfigureBuffers + visible paint ===\n");
    logf_("Built %s %s\n", __DATE__, __TIME__);
    logf_("launch uptime=%.2fs pid=%d uid=%d\n", uptime(), getpid(), getuid());

    // ────────────────────────────────────────────────────────────────────
    marker("01_wait_for_panel");
    // Per D4: wait until well after nav_pre.target services have completed
    // their orchestration (panel-on side effect). 80s covers normal factory
    // timing observed in spike 3.
    while (uptime() < 80.0) {
        sleep(3);
        logf_("  uptime=%.1fs\n", uptime());
    }
    logf_("  resumed at uptime=%.2fs\n", uptime());
    run_cmd("systemctl is-active nav_pre.target nav_smng.service 2>&1");
    run_cmd("ls /sys/class/gpio/ 2>&1 | head -20");

    // ────────────────────────────────────────────────────────────────────
    marker("02_stop_kill_set");
    // Only nav_navi + nav_dispapf per project_planB_kill_set memory.
    // Keep display_ps + hmictrl_proc + emgdhmid alive — needed for
    // backlight orchestration and rearview camera path.
    run_cmd("systemctl stop nav_navi.service nav_dispapf.service 2>&1");
    sleep(1);
    run_cmd("ps -A -o pid,comm | grep -E '(navi_ps|dispapf)' || echo '  (no surviving navi/dispapf procs)'");

    // ────────────────────────────────────────────────────────────────────
    marker("03_dlopen");
    void *libhmi = dlopen("libemgdhmi.so.0", RTLD_NOW | RTLD_GLOBAL);
    void *libegl = dlopen("libEGL.so.1", RTLD_NOW | RTLD_GLOBAL);
    void *libgl  = dlopen("libGLES_CM.so.1", RTLD_NOW | RTLD_GLOBAL);
    logf_("  libhmi=%p libegl=%p libgl=%p\n", libhmi, libegl, libgl);
    if (!libhmi || !libegl || !libgl) { logf_("  ABORT: dlopen failed\n"); goto restore; }

    int (*p_GetNativeDisplay)(void **)
        = (int (*)(void **)) dlsym(libhmi, "emgdHmiGetNativeDisplay");
    int (*p_GetNumScreens)(void *)
        = (int (*)(void *)) dlsym(libhmi, "emgdHmiGetNumScreens");
    int (*p_CreatePixmap)(void *, int, int, int, void **)
        = (int (*)(void *, int, int, int, void **)) dlsym(libhmi, "emgdHmiCreatePixmap");
    int (*p_ConfigureBuffers)(void *, EMGDHmiBufferState **)
        = (int (*)(void *, EMGDHmiBufferState **)) dlsym(libhmi, "emgdHmiConfigureBuffers");
    int (*p_RequestFlip)(void *, int, int, int *)
        = (int (*)(void *, int, int, int *)) dlsym(libhmi, "emgdHmiRequestFlip");

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
    EGLint (*p_eglGetError)(void)
        = (EGLint (*)(void)) dlsym(libegl, "eglGetError");

    void (*p_glClearColor)(float, float, float, float)
        = (void (*)(float, float, float, float)) dlsym(libgl, "glClearColor");
    void (*p_glClear)(unsigned int)
        = (void (*)(unsigned int)) dlsym(libgl, "glClear");
    void (*p_glFinish)(void)
        = (void (*)(void)) dlsym(libgl, "glFinish");

    if (!p_GetNativeDisplay || !p_CreatePixmap || !p_ConfigureBuffers) {
        logf_("  ABORT: required emgdHmi symbols missing\n"); goto restore;
    }

    // ────────────────────────────────────────────────────────────────────
    marker("04_native_display_and_pixmap");
    void *ndpy = NULL;
    int rc = p_GetNativeDisplay(&ndpy);
    logf_("  emgdHmiGetNativeDisplay rc=%d ndpy=%p\n", rc, ndpy);
    if (rc != 0) goto restore;
    if (p_GetNumScreens) {
        int n = p_GetNumScreens(ndpy);
        logf_("  emgdHmiGetNumScreens = %d (expect 2)\n", n);
    }

    void *px = NULL;
    rc = p_CreatePixmap(ndpy, 1 /* EMGD_HMI_BUFFER */, 800, 480, &px);
    logf_("  emgdHmiCreatePixmap rc=%d px=%p\n", rc, px);
    if (rc != 0 || !px) goto restore;

    // ────────────────────────────────────────────────────────────────────
    marker("05_configure_buffers");
    // The recipe from D5 §10 — bind our pixmap as the scanout buffer for
    // screen 0 (upper LVDS), leave screen 1 (lower LVDS) untouched.
    EMGDHmiBufferState screen0[3] = {{0}};
    screen0[0].plane_type    = 1;             // EMGD_HMI_BUFFER
    screen0[0].pixmap_handle = (uint32_t)(uintptr_t) px;
    screen0[0].width         = 800;
    screen0[0].height        = 480;
    screen0[0].stride        = 800 * 4;       // ARGB8888 byte-pitch

    EMGDHmiBufferState screen1[3] = {{0}};

    EMGDHmiBufferState *state[2] = { screen0, screen1 };

    rc = p_ConfigureBuffers(ndpy, state);
    logf_("  emgdHmiConfigureBuffers (h=480) rc=%d\n", rc);

    // D5 §4 risk: per_screen_h = total_fb_h / num_screens may be 450 on Q60.
    // If we got -3 (BAD_CONFIG), retry with height=450.
    if (rc == -3) {
        logf_("  retrying with height=450 (per_screen_h fallback)\n");
        screen0[0].height = 450;
        rc = p_ConfigureBuffers(ndpy, state);
        logf_("  emgdHmiConfigureBuffers (h=450) rc=%d\n", rc);
    }
    if (rc != 0) { logf_("  ConfigureBuffers failed; cannot proceed\n"); goto restore; }

    // ────────────────────────────────────────────────────────────────────
    marker("06_egl_bringup");
    EGLDisplay dpy = p_eglGetDisplay((EGLNativeDisplayType) ndpy);
    EGLint major, minor;
    p_eglInitialize(dpy, &major, &minor);
    logf_("  eglInitialize EGL %d.%d\n", major, minor);

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

    EGLint ctx_attrs[] = { 0x3098 /* EGL_CONTEXT_CLIENT_VERSION */, 2, EGL_NONE };
    EGLContext ctx = p_eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, ctx_attrs);
    EGLSurface surf = p_eglCreatePixmapSurface(dpy, cfg, (EGLNativePixmapType)(uintptr_t) px, NULL);
    EGLBoolean ok = p_eglMakeCurrent(dpy, surf, surf, ctx);
    logf_("  eglMakeCurrent = %d  err=0x%x\n", ok, p_eglGetError());
    if (!ok) goto restore;

    // ────────────────────────────────────────────────────────────────────
    marker("07_paint_15s_red");
    int frames = 0;
    for (int i = 0; i < 60; i++) {
        p_glClearColor(1.0f, 0.0f, 0.0f, 1.0f);
        p_glClear(GL_COLOR_BUFFER_BIT);
        if (p_glFinish) p_glFinish();
        p_eglSwapBuffers(dpy, surf);
        // Optional: RequestFlip — D3 says it's a no-op stub but harmless.
        if (p_RequestFlip) {
            int did_flip = 0;
            p_RequestFlip(ndpy, 0 /* screen 0 = upper */, 0 /* EMGD_DISPLAY_HMI */, &did_flip);
        }
        frames++;
        usleep(250000);  // 250ms = 4fps
    }
    logf_("  painted %d frames over 15s at uptime=%.2fs\n", frames, uptime());

restore:
    marker("08_restart_kill_set");
    run_cmd("systemctl start nav_navi.service nav_dispapf.service 2>&1");

    marker("99_copy_to_boot");
    int crc = system("mountpoint -q /boot || mount /dev/mmcblk0p1 /boot 2>/dev/null "
                     "|| mount /dev/mmcblk1p1 /boot 2>/dev/null");
    (void) crc;
    system("cp /tmp/q60-planb-4.log /boot/Q60_PLANB_SPIKE4.LOG 2>/dev/null; sync");
    system("cp /tmp/q60-planb-4-stage-*.txt /boot/ 2>/dev/null; sync");

    logf_("=== DONE at uptime=%.2fs ===\n", uptime());
    fclose(g_log);
    return 0;
}
