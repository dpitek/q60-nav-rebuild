// q60_planb_spike1c_paint.c
//
// Plan B''' first paint. Builds on spike 1b's proven EGL bringup, then:
//   - dlopen libGLES_CM.so.1 (confirmed present at /usr/lib by spike 1b stage 01;
//     glClearColor + glClear have identical ABI to GLESv2 so will work in our
//     ES2 context)
//   - paint red ~50 times over 5 seconds, swap after each
//   - exit cleanly
//
// Still NO daemon mask. Expectation: brief red flash on LVDS upper while
// the factory display_ps / hmictrl_proc continue painting their own surfaces.
// We may see flicker or nothing visible if they fully overdraw us. The win
// here is the LOG saying "eglSwapBuffers succeeded N times with no glError".
// Visual stability is spike 2's job (with the 2-daemon mask).
//
// Run.sh sets LD_LIBRARY_PATH per spike 1b's confirmed-working order.

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
    snprintf(path, sizeof(path), "/tmp/q60-planb-1c-stage-%s.txt", stage);
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) { dprintf(fd, "%s\n", stage); fsync(fd); close(fd); }
    logf_("\n=== STAGE %s ===\n", stage);
}

#define DLSYM(handle, name) ({ \
    void *_p = dlsym(handle, #name); \
    logf_("  dlsym %s = %p  err=%s\n", #name, _p, dlerror() ?: "(none)"); \
    _p; \
})

// GL constants we need (avoid pulling in GLES headers)
#define GL_COLOR_BUFFER_BIT 0x00004000
#define GL_NO_ERROR         0

int main(void) {
    g_log = fopen("/tmp/q60-planb-1c.log", "w");
    if (!g_log) g_log = stderr;
    logf_("=== Plan B''' Spike 1c — first paint ===\n");
    logf_("Built %s %s\n", __DATE__, __TIME__);
    logf_("pid=%d uid=%d\n", getpid(), getuid());

    // ────────────────────────────────────────────────────────────────────
    marker("01_dlopen");
    void *libhmi = dlopen("libemgdhmi.so.0", RTLD_NOW | RTLD_GLOBAL);
    logf_("  dlopen libemgdhmi.so.0 = %p\n", libhmi);
    void *libegl = dlopen("libEGL.so.1", RTLD_NOW | RTLD_GLOBAL);
    logf_("  dlopen libEGL.so.1     = %p\n", libegl);
    void *libgl  = dlopen("libGLES_CM.so.1", RTLD_NOW | RTLD_GLOBAL);
    logf_("  dlopen libGLES_CM.so.1 = %p\n", libgl);
    if (!libhmi || !libegl || !libgl) {
        logf_("  ABORT — missing required lib (dlerror: %s)\n", dlerror() ?: "(none)");
        goto end;
    }

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
    unsigned int (*p_glGetError)(void)
        = (unsigned int (*)(void)) DLSYM(libgl, glGetError);
    void (*p_glFinish)(void)
        = (void (*)(void)) DLSYM(libgl, glFinish);

    if (!emgdHmiGetNativeDisplay || !p_eglMakeCurrent || !p_eglSwapBuffers
        || !p_glClearColor || !p_glClear) {
        logf_("  ABORT — missing required symbols\n"); goto end;
    }

    // ────────────────────────────────────────────────────────────────────
    marker("02_egl_bringup");
    void *ndpy = NULL;
    int rc = emgdHmiGetNativeDisplay(&ndpy);
    logf_("  emgdHmiGetNativeDisplay rc=%d ndpy=%p\n", rc, ndpy);
    if (rc != 0) goto end;

    EGLDisplay dpy = p_eglGetDisplay((EGLNativeDisplayType) ndpy);
    logf_("  eglGetDisplay = %p\n", dpy);
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
    logf_("  eglChooseConfig num=%d\n", num);
    if (num == 0) goto end;

    EGLint ctx_attrs[] = { 0x3098 /* EGL_CONTEXT_CLIENT_VERSION */, 2, EGL_NONE };
    EGLContext ctx = p_eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, ctx_attrs);
    logf_("  eglCreateContext = %p\n", ctx);
    if (ctx == EGL_NO_CONTEXT) goto end;

    void *pix = NULL;
    rc = emgdHmiCreatePixmap(ndpy, 1, 800, 480, &pix);
    logf_("  emgdHmiCreatePixmap rc=%d pix=%p\n", rc, pix);
    if (rc != 0 || !pix) goto end;

    EGLSurface surf = p_eglCreatePixmapSurface(dpy, cfg, (EGLNativePixmapType) pix, NULL);
    logf_("  eglCreatePixmapSurface = %p\n", surf);
    if (surf == EGL_NO_SURFACE) goto end;

    EGLBoolean ok = p_eglMakeCurrent(dpy, surf, surf, ctx);
    logf_("  eglMakeCurrent = %d\n", ok);
    if (!ok) goto end;

    // ────────────────────────────────────────────────────────────────────
    marker("03_paint_loop");
    int frames = 0;
    int swap_fails = 0;
    int gl_errors = 0;
    // ~5 seconds at ~10 fps = 50 frames. Cheap, gives Doug visual time.
    for (int i = 0; i < 50; i++) {
        p_glClearColor(1.0f, 0.0f, 0.0f, 1.0f);  // red
        p_glClear(GL_COLOR_BUFFER_BIT);
        if (p_glGetError) {
            unsigned int e = p_glGetError();
            if (e != GL_NO_ERROR) {
                gl_errors++;
                if (gl_errors <= 3) logf_("  glError frame=%d e=0x%x\n", i, e);
            }
        }
        if (p_glFinish) p_glFinish();
        EGLBoolean sok = p_eglSwapBuffers(dpy, surf);
        if (!sok) {
            swap_fails++;
            if (swap_fails <= 3) logf_("  eglSwapBuffers fail frame=%d egl_err=0x%x\n",
                                       i, p_eglGetError());
        }
        frames++;
        usleep(100000);  // 100ms = ~10 fps
    }
    logf_("  painted frames=%d  swap_fails=%d  gl_errors=%d\n",
          frames, swap_fails, gl_errors);

    marker("04_done");
    logf_("  *** PAINT LOOP COMPLETE — if you saw red flicker on LVDS upper,\n");
    logf_("      Plan B''' rendering pipeline is end-to-end functional ***\n");

end:
    marker("99_copy_to_boot");
    int crc = system("mountpoint -q /boot || mount /dev/mmcblk0p1 /boot 2>/dev/null "
                     "|| mount /dev/mmcblk1p1 /boot 2>/dev/null");
    (void) crc;
    system("cp /tmp/q60-planb-1c.log /boot/Q60_PLANB_SPIKE1C.LOG 2>/dev/null; sync");
    system("cp /tmp/q60-planb-1c-stage-*.txt /boot/ 2>/dev/null; sync");

    logf_("=== DONE ===\n");
    fclose(g_log);
    return 0;
}
