// q60_planb_spike1b_egl_native.c
//
// Plan B''' EGL discovery spike 1b. Follow-up to spike 1.
//
// Spike 1 results that drive this:
//   - PID 1 = systemd (confirmed; CLAUDE.md was wrong)
//   - All 4 UI daemons + emgdhmid + camera_ps + audio_ps running
//   - /tmp/.emgdhmid_socket present, /dev/dri/card0 present
//   - libEGL.so.1 dlopens, all 9 EGL symbols dlsym cleanly
//   - eglGetDisplay(EGL_DEFAULT_DISPLAY) returns EGL_NO_DISPLAY (silent)
//   - libGLESv2.so.1 NOT at /usr/lib (no LD_LIBRARY_PATH was set)
//
// What this spike adds (per drawbuf binary's symbol contract):
//   1. dlopen libemgdhmi.so.0 first
//   2. emgdHmiGetNativeDisplay() → ndpy
//   3. eglGetDisplay(ndpy) — should now return a valid EGLDisplay
//   4. eglInitialize, eglQueryString, eglChooseConfig, eglCreateContext
//   5. emgdHmiCreatePixmap(ndpy, 1, 800, 480, &pix)
//   6. eglCreatePixmapSurface(dpy, cfg, pix, NULL)
//   7. eglMakeCurrent
//
// Still NON-DESTRUCTIVE: no painting, no DRM master, no daemon mask.
// run.sh sets LD_LIBRARY_PATH per Agent 2's recipe before launch.
//
// Log: /tmp/q60-planb-1b.log, copied to /boot/Q60_PLANB_SPIKE1B.LOG.

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
    snprintf(path, sizeof(path), "/tmp/q60-planb-1b-stage-%s.txt", stage);
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) { dprintf(fd, "%s\n", stage); fsync(fd); close(fd); }
    logf_("\n=== STAGE %s ===\n", stage);
}

static void stat_path(const char *path) {
    struct stat st;
    if (stat(path, &st) == 0) {
        logf_("  STAT %s  mode=%07o size=%lld\n", path,
              (unsigned)st.st_mode, (long long)st.st_size);
    } else {
        logf_("  STAT %s  errno=%d (%s)\n", path, errno, strerror(errno));
    }
}

static void run_cmd(const char *cmd) {
    logf_("$ %s\n", cmd);
    FILE *p = popen(cmd, "r");
    if (!p) { logf_("  popen errno=%d\n", errno); return; }
    char line[512];
    while (fgets(line, sizeof(line), p)) logf_("  %s", line);
    pclose(p);
}

#define DLSYM(handle, name) ({ \
    void *_p = dlsym(handle, #name); \
    logf_("  dlsym %s = %p  err=%s\n", #name, _p, dlerror() ?: "(none)"); \
    _p; \
})

int main(void) {
    g_log = fopen("/tmp/q60-planb-1b.log", "w");
    if (!g_log) g_log = stderr;
    logf_("=== Plan B''' Spike 1b — emgdHmi native display + full EGL bringup ===\n");
    logf_("Built %s %s\n", __DATE__, __TIME__);
    logf_("pid=%d uid=%d  argv0=spike1b\n", getpid(), getuid());
    logf_("LD_LIBRARY_PATH = %s\n", getenv("LD_LIBRARY_PATH") ?: "(unset)");

    // ────────────────────────────────────────────────────────────────────
    marker("01_lib_inventory");
    stat_path("/usr/lib/libEGL.so.1");
    stat_path("/usr/lib/libemgdhmi.so.0");
    stat_path("/usr/lib/libEMGD2d.so");
    stat_path("/usr/lib/libGLESv2.so.1");
    stat_path("/usr/lib/libGLES_CM.so.1");
    stat_path("/usr/lib/libOpenVG.so");
    stat_path("/usr/lib/wsegl/libwsegl-hmi.so");
    stat_path("/home/naviwork/system/lib/libGLESv2.so.1");
    stat_path("/home/naviwork/system/lib/libGLES_CM.so.1");
    stat_path("/home/naviwork/system/lib/libOpenVG.so");
    run_cmd("ls /home/naviwork/system/lib/ 2>&1 | head -30");

    // ────────────────────────────────────────────────────────────────────
    marker("02_dlopen_emgdhmi");
    void *libhmi = dlopen("libemgdhmi.so.0", RTLD_NOW | RTLD_GLOBAL);
    logf_("  dlopen(libemgdhmi.so.0) = %p  err=%s\n", libhmi, dlerror() ?: "(none)");
    if (!libhmi) { logf_("  ABORT — cannot proceed without libemgdhmi\n"); goto end; }

    // ABI from disassembly of libemgdhmi.so.0:
    //   int emgdHmiGetNativeDisplay(void **out_display)
    //     - returns 0 on success, -6 if socket not connected
    //     - writes magic cookie 0xd39ade6b to *out_display
    //   int emgdHmiCreatePixmap(void *ndpy, int buftype, int w, int h, void **out_pix)
    //     - Agent 2's recipe; buftype=1 (EMGD_HMI_BUFFER)
    int (*emgdHmiGetNativeDisplay)(void **)
        = (int (*)(void **)) DLSYM(libhmi, emgdHmiGetNativeDisplay);
    int (*emgdHmiCreatePixmap)(void *, int, int, int, void **)
        = (int (*)(void *, int, int, int, void **)) DLSYM(libhmi, emgdHmiCreatePixmap);
    int (*emgdHmiDestroyPixmap)(void *)
        = (int (*)(void *)) DLSYM(libhmi, emgdHmiDestroyPixmap);
    (void) emgdHmiDestroyPixmap;
    if (!emgdHmiGetNativeDisplay || !emgdHmiCreatePixmap) {
        logf_("  ABORT — missing required emgdHmi symbols\n"); goto end;
    }

    // ────────────────────────────────────────────────────────────────────
    marker("03_get_native_display");
    void *ndpy = NULL;
    int rc = emgdHmiGetNativeDisplay(&ndpy);
    logf_("  emgdHmiGetNativeDisplay(&ndpy) rc=%d  ndpy=%p\n", rc, ndpy);
    if (rc != 0) {
        logf_("  emgdhmid socket not connected (rc=%d, -6 = check_socket failed)\n", rc);
        run_cmd("ls -la /tmp/.emgdhmid_socket 2>&1");
        goto end;
    }
    if (!ndpy) {
        logf_("  rc=0 but ndpy is NULL — unexpected\n");
        goto end;
    }
    logf_("  expected magic cookie 0xd39ade6b, got %p\n", ndpy);

    // ────────────────────────────────────────────────────────────────────
    marker("04_dlopen_egl");
    void *libegl = dlopen("libEGL.so.1", RTLD_NOW | RTLD_GLOBAL);
    logf_("  dlopen(libEGL.so.1) = %p  err=%s\n", libegl, dlerror() ?: "(none)");
    if (!libegl) goto end;

    EGLDisplay (*p_eglGetDisplay)(EGLNativeDisplayType)
        = (EGLDisplay (*)(EGLNativeDisplayType)) DLSYM(libegl, eglGetDisplay);
    EGLBoolean (*p_eglInitialize)(EGLDisplay, EGLint *, EGLint *)
        = (EGLBoolean (*)(EGLDisplay, EGLint *, EGLint *)) DLSYM(libegl, eglInitialize);
    const char *(*p_eglQueryString)(EGLDisplay, EGLint)
        = (const char *(*)(EGLDisplay, EGLint)) DLSYM(libegl, eglQueryString);
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
    EGLint (*p_eglGetError)(void)
        = (EGLint (*)(void)) DLSYM(libegl, eglGetError);

    if (!p_eglGetDisplay || !p_eglInitialize) goto end;

    // ────────────────────────────────────────────────────────────────────
    marker("05_egl_get_display");
    EGLDisplay dpy = p_eglGetDisplay((EGLNativeDisplayType) ndpy);
    logf_("  eglGetDisplay(ndpy=%p) = %p  err=0x%x\n", ndpy, dpy, p_eglGetError());
    if (dpy == EGL_NO_DISPLAY) goto end;

    // ────────────────────────────────────────────────────────────────────
    marker("06_egl_initialize");
    EGLint major = -1, minor = -1;
    EGLBoolean ok = p_eglInitialize(dpy, &major, &minor);
    logf_("  eglInitialize -> %d  EGL %d.%d  err=0x%x\n", ok, major, minor, p_eglGetError());
    if (!ok) goto end;

    logf_("  EGL_VENDOR     = %s\n", p_eglQueryString(dpy, EGL_VENDOR));
    logf_("  EGL_VERSION    = %s\n", p_eglQueryString(dpy, EGL_VERSION));
    logf_("  EGL_CLIENT_APIS= %s\n", p_eglQueryString(dpy, EGL_CLIENT_APIS));
    logf_("  EGL_EXTENSIONS = %s\n", p_eglQueryString(dpy, EGL_EXTENSIONS));

    // ────────────────────────────────────────────────────────────────────
    marker("07_egl_choose_config");
    // drawbuf used RGBA8/D24/S8/no-MSAA per Agent 2
    EGLint attrs[] = {
        EGL_SURFACE_TYPE,    EGL_PIXMAP_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
        EGL_RED_SIZE,        8,
        EGL_GREEN_SIZE,      8,
        EGL_BLUE_SIZE,       8,
        EGL_ALPHA_SIZE,      8,
        EGL_DEPTH_SIZE,      24,
        EGL_STENCIL_SIZE,    8,
        EGL_NONE
    };
    EGLConfig cfg;
    EGLint num = 0;
    ok = p_eglChooseConfig(dpy, attrs, &cfg, 1, &num);
    logf_("  eglChooseConfig RGBA8 D24 S8 PIXMAP+GLES2 -> %d  num=%d  err=0x%x\n",
          ok, num, p_eglGetError());
    if (!ok || num == 0) {
        // Try a looser config — drop depth/stencil
        EGLint attrs2[] = {
            EGL_SURFACE_TYPE,    EGL_PIXMAP_BIT,
            EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
            EGL_RED_SIZE,        8,
            EGL_GREEN_SIZE,      8,
            EGL_BLUE_SIZE,       8,
            EGL_NONE
        };
        ok = p_eglChooseConfig(dpy, attrs2, &cfg, 1, &num);
        logf_("  retry RGB888 PIXMAP+GLES2 -> %d  num=%d  err=0x%x\n",
              ok, num, p_eglGetError());
        if (!ok || num == 0) goto end;
    }

    // ────────────────────────────────────────────────────────────────────
    marker("08_egl_create_context");
    EGLint ctx_attrs[] = { 0x3098 /* EGL_CONTEXT_CLIENT_VERSION */, 2, EGL_NONE };
    EGLContext ctx = p_eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, ctx_attrs);
    logf_("  eglCreateContext -> %p  err=0x%x\n", ctx, p_eglGetError());
    if (ctx == EGL_NO_CONTEXT) goto end;

    // ────────────────────────────────────────────────────────────────────
    marker("09_emgdhmi_create_pixmap");
    // drawbuf signature: emgdHmiCreatePixmap(ndpy, EMGD_HMI_BUFFER=1, width, height, &pix)
    void *pix = NULL;
    int prc = emgdHmiCreatePixmap(ndpy, 1, 800, 480, &pix);
    logf_("  emgdHmiCreatePixmap(ndpy, 1, 800, 480, &pix) rc=%d  pix=%p\n", prc, pix);
    if (prc != 0 || !pix) {
        logf_("  pixmap creation failed — cannot create surface\n"); goto end;
    }

    // ────────────────────────────────────────────────────────────────────
    marker("10_egl_create_pixmap_surface");
    EGLSurface surf = p_eglCreatePixmapSurface(dpy, cfg, (EGLNativePixmapType) pix, NULL);
    logf_("  eglCreatePixmapSurface -> %p  err=0x%x\n", surf, p_eglGetError());
    if (surf == EGL_NO_SURFACE) goto end;

    // ────────────────────────────────────────────────────────────────────
    marker("11_egl_make_current");
    ok = p_eglMakeCurrent(dpy, surf, surf, ctx);
    logf_("  eglMakeCurrent -> %d  err=0x%x\n", ok, p_eglGetError());
    if (!ok) goto end;

    logf_("  *** EGL CONTEXT IS CURRENT — Spike 1b SUCCESS ***\n");
    logf_("  Next spike (1c/2) can paint into this surface.\n");

end:
    marker("99_copy_to_boot");
    int crc = system("mountpoint -q /boot || mount /dev/mmcblk0p1 /boot 2>/dev/null "
                     "|| mount /dev/mmcblk1p1 /boot 2>/dev/null");
    logf_("  mount /boot rc=%d\n", crc);
    crc = system("cp /tmp/q60-planb-1b.log /boot/Q60_PLANB_SPIKE1B.LOG && sync");
    logf_("  cp -> /boot rc=%d\n", crc);
    crc = system("cp /tmp/q60-planb-1b-stage-*.txt /boot/ 2>/dev/null; sync");
    logf_("  cp markers rc=%d\n", crc);

    logf_("=== DONE ===\n");
    fclose(g_log);
    return 0;
}
