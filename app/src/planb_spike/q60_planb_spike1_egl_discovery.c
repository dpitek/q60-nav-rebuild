// q60_planb_spike1_egl_discovery.c
//
// Plan B''' EGL discovery spike. First boot probe — does NOT mask any factory
// daemon, does NOT take DRM master, does NOT try to paint. Just dlopens the
// factory EGL stack and reports what works while the factory nav is running
// alongside.
//
// Goals:
//   1. Settle the PID 1 question (Android init vs systemd) by writing
//      /proc/1/comm + ls -l /sbin/init to log BEFORE any other action.
//   2. Confirm the EGL backend dlopens, initializes, and reports versions/
//      extensions/configs we can paint into.
//   3. Probe what eglGetDisplay/eglQueryString return without disrupting the
//      running factory UI.
//
// Why dlopen instead of -lEGL: build container has no EMGD libs. Function
// signatures come from EGL headers (libegl1-mesa-dev provides them); the
// runtime symbol resolution lands in /usr/lib/libEGL.so.1.5.15.3226.
//
// Build: see build-spike.sh (Debian bullseye i386, glibc 2.31, libegl1-mesa-dev).
// Deploy: see deploy-spike.sh.
//
// Log: /tmp/q60-planb.log (always writable), copied to /boot/Q60_PLANB_SPIKE1.LOG
// at the end. Per-stage markers also written so a hang leaves evidence.

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
#include <sys/types.h>
#include <sys/wait.h>

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
    snprintf(path, sizeof(path), "/tmp/q60-planb-stage-%s.txt", stage);
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) { dprintf(fd, "%s\n", stage); fsync(fd); close(fd); }
    logf_("\n=== STAGE %s ===\n", stage);
}

static void dump_file(const char *path, const char *label) {
    logf_("--- %s (%s) ---\n", label, path);
    int fd = open(path, O_RDONLY);
    if (fd < 0) { logf_("  open errno=%d (%s)\n", errno, strerror(errno)); return; }
    char buf[1024];
    ssize_t n = read(fd, buf, sizeof(buf) - 1);
    if (n < 0) { logf_("  read errno=%d\n", errno); close(fd); return; }
    buf[n] = 0;
    // /proc/1/cmdline has NUL separators — translate to spaces for readability
    for (ssize_t i = 0; i < n; i++) if (buf[i] == 0) buf[i] = ' ';
    logf_("  %s\n", buf);
    close(fd);
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

static void stat_path(const char *path) {
    struct stat st;
    if (stat(path, &st) == 0) {
        logf_("  STAT %s  mode=%07o size=%lld\n", path,
              (unsigned)st.st_mode, (long long)st.st_size);
    } else {
        logf_("  STAT %s  errno=%d (%s)\n", path, errno, strerror(errno));
    }
}

// ── EGL function pointer table (resolved via dlsym after dlopen libEGL.so.1) ──
struct egl_fns {
    EGLDisplay  (*GetDisplay)(EGLNativeDisplayType);
    EGLBoolean  (*Initialize)(EGLDisplay, EGLint *, EGLint *);
    const char *(*QueryString)(EGLDisplay, EGLint);
    EGLBoolean  (*GetConfigs)(EGLDisplay, EGLConfig *, EGLint, EGLint *);
    EGLBoolean  (*ChooseConfig)(EGLDisplay, const EGLint *, EGLConfig *, EGLint, EGLint *);
    EGLBoolean  (*GetConfigAttrib)(EGLDisplay, EGLConfig, EGLint, EGLint *);
    EGLContext  (*CreateContext)(EGLDisplay, EGLConfig, EGLContext, const EGLint *);
    EGLint      (*GetError)(void);
    EGLBoolean  (*Terminate)(EGLDisplay);
};

#define RESOLVE(name) do { \
    fns.name = dlsym(libegl, "egl" #name); \
    logf_("  dlsym egl" #name " = %p  err=%s\n", \
          (void*)fns.name, dlerror() ?: "(none)"); \
    if (!fns.name) { logf_("  ABORT — missing egl" #name "\n"); goto egl_done; } \
} while (0)

int main(int argc, char **argv) {
    (void)argc; (void)argv;

    g_log = fopen("/tmp/q60-planb.log", "w");
    if (!g_log) g_log = stderr;
    logf_("=== Plan B''' Spike 1 — EGL discovery ===\n");
    logf_("Built %s %s\n", __DATE__, __TIME__);
    logf_("pid=%d ppid=%d uid=%d\n", getpid(), getppid(), getuid());

    // ────────────────────────────────────────────────────────────────────
    marker("01_pid1");
    // Settle the long-standing PID 1 question. Mask strategy depends on this.
    dump_file("/proc/1/comm",    "PID 1 comm");
    dump_file("/proc/1/cmdline", "PID 1 cmdline");
    run_cmd("ls -l /sbin/init");
    run_cmd("ls /init.rc /system/init.rc /etc/init/ 2>&1 | head -20");
    run_cmd("which systemctl && systemctl --version | head -2");

    // ────────────────────────────────────────────────────────────────────
    marker("02_factory_state");
    // What's running? Don't touch anything — just snapshot.
    run_cmd("ps -A -o pid,ppid,user,comm | grep -E '(navi|hmictrl|display|dispapf|emgdhmid|camera|audio)' | head -30");
    run_cmd("ls -l /tmp/.emgdhmid_socket 2>&1");
    run_cmd("ls -l /dev/dri/ /dev/v2gbridge /dev/video0 2>&1");

    // ────────────────────────────────────────────────────────────────────
    marker("03_egl_libs");
    stat_path("/usr/lib/libEGL.so.1");
    stat_path("/usr/lib/libEGL.so.1.5.15.3226");
    stat_path("/usr/lib/libGLESv2.so.1");
    stat_path("/usr/lib/wsegl/libwsegl-hmi.so");
    stat_path("/etc/powervr.ini");
    run_cmd("cat /etc/powervr.ini 2>&1");

    // ────────────────────────────────────────────────────────────────────
    marker("04_dlopen_egl");
    void *libegl = dlopen("libEGL.so.1", RTLD_LAZY | RTLD_GLOBAL);
    logf_("  dlopen(libEGL.so.1) = %p  err=%s\n", libegl, dlerror() ?: "(none)");
    if (!libegl) {
        libegl = dlopen("/usr/lib/libEGL.so.1.5.15.3226", RTLD_LAZY | RTLD_GLOBAL);
        logf_("  dlopen(/usr/lib/libEGL.so.1.5.15.3226) = %p  err=%s\n",
              libegl, dlerror() ?: "(none)");
    }
    if (!libegl) goto end;

    struct egl_fns fns = {0};
    RESOLVE(GetDisplay);
    RESOLVE(Initialize);
    RESOLVE(QueryString);
    RESOLVE(GetConfigs);
    RESOLVE(ChooseConfig);
    RESOLVE(GetConfigAttrib);
    RESOLVE(CreateContext);
    RESOLVE(GetError);
    RESOLVE(Terminate);

    // ────────────────────────────────────────────────────────────────────
    marker("05_egl_get_display");
    EGLDisplay dpy = fns.GetDisplay(EGL_DEFAULT_DISPLAY);
    logf_("  eglGetDisplay(EGL_DEFAULT_DISPLAY) = %p  err=0x%x\n",
          dpy, fns.GetError());
    if (dpy == EGL_NO_DISPLAY) goto egl_done;

    // ────────────────────────────────────────────────────────────────────
    marker("06_egl_initialize");
    EGLint major = -1, minor = -1;
    EGLBoolean ok = fns.Initialize(dpy, &major, &minor);
    logf_("  eglInitialize -> %d  EGL %d.%d  err=0x%x\n",
          ok, major, minor, fns.GetError());
    if (!ok) goto egl_done;

    // ────────────────────────────────────────────────────────────────────
    marker("07_egl_query");
    logf_("  EGL_VENDOR     = %s\n", fns.QueryString(dpy, EGL_VENDOR));
    logf_("  EGL_VERSION    = %s\n", fns.QueryString(dpy, EGL_VERSION));
    logf_("  EGL_CLIENT_APIS= %s\n", fns.QueryString(dpy, EGL_CLIENT_APIS));
    logf_("  EGL_EXTENSIONS = %s\n", fns.QueryString(dpy, EGL_EXTENSIONS));

    // ────────────────────────────────────────────────────────────────────
    marker("08_egl_configs");
    EGLint num_total = 0;
    fns.GetConfigs(dpy, NULL, 0, &num_total);
    logf_("  total configs available: %d\n", num_total);
    EGLConfig cfgs[64];
    EGLint num_returned = 0;
    fns.GetConfigs(dpy, cfgs, 64, &num_returned);
    logf_("  enumerated: %d  (showing first 4)\n", num_returned);
    for (int i = 0; i < num_returned && i < 4; i++) {
        EGLint r, g, b, a, d, s, samp, rt;
        fns.GetConfigAttrib(dpy, cfgs[i], EGL_RED_SIZE, &r);
        fns.GetConfigAttrib(dpy, cfgs[i], EGL_GREEN_SIZE, &g);
        fns.GetConfigAttrib(dpy, cfgs[i], EGL_BLUE_SIZE, &b);
        fns.GetConfigAttrib(dpy, cfgs[i], EGL_ALPHA_SIZE, &a);
        fns.GetConfigAttrib(dpy, cfgs[i], EGL_DEPTH_SIZE, &d);
        fns.GetConfigAttrib(dpy, cfgs[i], EGL_STENCIL_SIZE, &s);
        fns.GetConfigAttrib(dpy, cfgs[i], EGL_SAMPLES, &samp);
        fns.GetConfigAttrib(dpy, cfgs[i], EGL_RENDERABLE_TYPE, &rt);
        logf_("    cfg[%d] RGBA=%d/%d/%d/%d depth=%d stencil=%d samples=%d rt=0x%x\n",
              i, r, g, b, a, d, s, samp, rt);
    }

    // ────────────────────────────────────────────────────────────────────
    marker("09_egl_choose");
    // RGB565 matches LVDS upper (800x480, R5G6B5)
    EGLint attrs[] = {
        EGL_SURFACE_TYPE,    EGL_WINDOW_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
        EGL_RED_SIZE,        5,
        EGL_GREEN_SIZE,      6,
        EGL_BLUE_SIZE,       5,
        EGL_NONE
    };
    EGLConfig cfg;
    EGLint num = 0;
    ok = fns.ChooseConfig(dpy, attrs, &cfg, 1, &num);
    logf_("  eglChooseConfig RGB565+GLES2 -> %d  num=%d  err=0x%x\n",
          ok, num, fns.GetError());

    if (ok && num > 0) {
        EGLint ctx_attrs[] = { 0x3098 /* EGL_CONTEXT_CLIENT_VERSION */, 2, EGL_NONE };
        EGLContext ctx = fns.CreateContext(dpy, cfg, EGL_NO_CONTEXT, ctx_attrs);
        logf_("  eglCreateContext -> %p  err=0x%x\n", ctx, fns.GetError());
        // We deliberately do NOT call CreateWindowSurface here — that's
        // where we expect the interesting failure mode, and we want spike 2
        // (which will be designed around what this log tells us) to handle it.
    }

    fns.Terminate(dpy);

egl_done:
    if (libegl) dlclose(libegl);

end:
    marker("10_copy_to_boot");
    // Mount /boot (FAT32) if not already, copy log
    int rc = system("mountpoint -q /boot || mount /dev/mmcblk0p1 /boot 2>/dev/null "
                    "|| mount /dev/mmcblk1p1 /boot 2>/dev/null");
    logf_("  mount /boot rc=%d\n", rc);
    rc = system("cp /tmp/q60-planb.log /boot/Q60_PLANB_SPIKE1.LOG && sync");
    logf_("  cp -> /boot rc=%d\n", rc);
    rc = system("cp /tmp/q60-planb-stage-*.txt /boot/ 2>/dev/null; sync");
    logf_("  cp stage markers rc=%d\n", rc);

    logf_("=== DONE ===\n");
    fclose(g_log);
    return 0;
}
