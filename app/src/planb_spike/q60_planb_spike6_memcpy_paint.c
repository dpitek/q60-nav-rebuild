// q60_planb_spike6_memcpy_paint.c
//
// Plan B''' spike 6 — TWO objectives in one boot:
//
//   A) Identify the backlight-control GPIO so future spikes can enable
//      panels at t=15s instead of waiting 75s. We snapshot all exported
//      GPIOs every 2s during the wait loop and log every transition.
//      Result lands at /boot/Q60_BL_TRANSITIONS.LOG. The GPIO that flips
//      around panel-on time is the answer.
//
//   B) Paint VISIBLY using CPU memcpy, NOT GL. Per Agent D1 forensic of
//      the working factory drawbuf binary: "drawbuf doesn't paint with GL
//      at all. It uses emgdHmiMapPixmap to get a CPU virtual address,
//      then a direct DWORD for loop writes the color." Our spike 5 used
//      glClear and produced the SAME uninitialized purple regardless of
//      what color we asked for — proof that GL writes don't reach the
//      scanned-out memory. This spike skips EGL/GL entirely.
//
// Paint pattern: 4 vertical bars (each 200px wide) so one photo
// identifies the byte order:
//   bar 0 (x=0..199):   0xFFFF0000   ← "RED" in ARGB literal
//   bar 1 (x=200..399): 0xFF00FF00   ← "GREEN" in ARGB literal
//   bar 2 (x=400..599): 0xFF0000FF   ← "BLUE" in ARGB literal
//   bar 3 (x=600..799): 0xFFFFFFFF   ← WHITE (all channels max)
//
// Whatever colors Doug actually sees → cross-reference and we know exactly
// which byte order the hardware scans out (RGBA/BGRA/ARGB/ABGR/RGB565).

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
#include <dirent.h>
#include <ctype.h>
#include <sys/stat.h>
#include <sys/wait.h>

static FILE *g_log;
static FILE *g_trans;

static void logf_(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    vfprintf(g_log, fmt, ap); va_end(ap);
    fflush(g_log); fsync(fileno(g_log));
}
static void marker(const char *stage) {
    char path[128];
    snprintf(path, sizeof(path), "/tmp/q60-planb-6-stage-%s.txt", stage);
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

// Snapshot all /sys/class/gpio/gpioN/value as a string.
// Returns malloc'd string caller must free, NULL on error.
static char *gpio_snapshot(void) {
    DIR *d = opendir("/sys/class/gpio");
    if (!d) return NULL;
    char *buf = malloc(8192);
    if (!buf) { closedir(d); return NULL; }
    int off = 0;
    struct dirent *e;
    int gpios[256], ng = 0;
    while ((e = readdir(d)) && ng < 256) {
        if (strncmp(e->d_name, "gpio", 4) != 0) continue;
        if (!isdigit((unsigned char) e->d_name[4])) continue;
        gpios[ng++] = atoi(e->d_name + 4);
    }
    closedir(d);
    // Simple sort
    for (int i = 0; i < ng; i++)
        for (int j = i + 1; j < ng; j++)
            if (gpios[j] < gpios[i]) { int t = gpios[i]; gpios[i] = gpios[j]; gpios[j] = t; }
    for (int i = 0; i < ng; i++) {
        char path[64], val[8] = {0}, dir[8] = {0};
        snprintf(path, sizeof(path), "/sys/class/gpio/gpio%d/value", gpios[i]);
        FILE *f = fopen(path, "r");
        if (f) { fread(val, 1, sizeof(val)-1, f); fclose(f); }
        char *nl = strchr(val, '\n'); if (nl) *nl = 0;
        snprintf(path, sizeof(path), "/sys/class/gpio/gpio%d/direction", gpios[i]);
        f = fopen(path, "r");
        if (f) { fread(dir, 1, sizeof(dir)-1, f); fclose(f); }
        nl = strchr(dir, '\n'); if (nl) *nl = 0;
        off += snprintf(buf + off, 8192 - off, "%d:%s:%s ", gpios[i], dir, val);
        if (off >= 8000) break;
    }
    return buf;
}

int main(void) {
    g_log = fopen("/tmp/q60-planb-6.log", "w");
    if (!g_log) g_log = stderr;
    g_trans = fopen("/tmp/q60-bl-transitions.log", "w");
    if (!g_trans) g_trans = stderr;

    logf_("=== Spike 6 — GPIO discovery + memcpy paint (NO GL) ===\n");
    logf_("launch uptime=%.2fs pid=%d\n", uptime(), getpid());

    // ── Stage 01: initial GPIO snapshot ──
    marker("01_gpio_initial");
    char *prev = gpio_snapshot();
    if (prev) {
        logf_("  initial GPIOs (gpioN:direction:value):\n  %s\n", prev);
        fprintf(g_trans, "[uptime=%.2fs] initial state\n%s\n\n", uptime(), prev);
        fflush(g_trans); fsync(fileno(g_trans));
    }

    // ── Stage 02: poll for GPIO transitions while waiting for panel-on ──
    marker("02_wait_and_observe");
    int iter = 0;
    while (uptime() < 85.0) {
        sleep(2);
        char *curr = gpio_snapshot();
        if (curr && prev && strcmp(curr, prev) != 0) {
            fprintf(g_trans, "[uptime=%.2fs] CHANGE\n", uptime());
            // Simple word-level diff — print whole strings for now,
            // human can spot diff (~100 GPIOs, ~6KB)
            fprintf(g_trans, "  prev: %s\n  curr: %s\n\n", prev, curr);
            fflush(g_trans); fsync(fileno(g_trans));
            logf_("  uptime=%.1fs GPIO change detected (see transitions log)\n", uptime());
            free(prev);
            prev = curr;
        } else {
            free(curr);
        }
        if (++iter % 5 == 0) logf_("  ... uptime=%.1fs (no change since last)\n", uptime());
    }
    if (prev) free(prev);

    // ── Stage 03: stop kill set ──
    marker("03_stop");
    run_cmd("systemctl stop nav_navi.service nav_dispapf.service 2>&1");
    sleep(1);

    // ── Stage 04: dlopen ONLY libemgdhmi (no EGL/GL needed for memcpy path) ──
    marker("04_dlopen");
    void *libhmi = dlopen("libemgdhmi.so.0", RTLD_NOW | RTLD_GLOBAL);
    logf_("  libhmi=%p err=%s\n", libhmi, dlerror() ?: "(none)");
    if (!libhmi) goto restore;

    int (*p_GetNd)(void **)
        = (int (*)(void **)) dlsym(libhmi, "emgdHmiGetNativeDisplay");
    int (*p_CreatePx)(void *, int, int, int, void **)
        = (int (*)(void *, int, int, int, void **)) dlsym(libhmi, "emgdHmiCreatePixmap");
    int (*p_MapPx)(void *, void **)
        = (int (*)(void *, void **)) dlsym(libhmi, "emgdHmiMapPixmap");
    int (*p_FreeMem)(void *)
        = (int (*)(void *)) dlsym(libhmi, "emgdHmiFreeMem");

    typedef struct {
        uint32_t plane_type, pixmap_handle, pixmap_handle_hi;
        int32_t  screen_x, screen_y, src_x, src_y, width, height;
        uint32_t stride, flags0, flags1, flags2, flags3;
    } BufState;
    int (*p_ConfBuf)(void *, BufState **)
        = (int (*)(void *, BufState **)) dlsym(libhmi, "emgdHmiConfigureBuffers");

    logf_("  syms: GetNd=%p CreatePx=%p MapPx=%p FreeMem=%p ConfBuf=%p\n",
          p_GetNd, p_CreatePx, p_MapPx, p_FreeMem, p_ConfBuf);

    if (!p_GetNd || !p_CreatePx || !p_MapPx || !p_ConfBuf) {
        logf_("  ABORT: required symbols missing\n");
        goto restore;
    }

    // ── Stage 05: emgdHmi setup ──
    marker("05_setup");
    void *ndpy = NULL;
    int rc = p_GetNd(&ndpy);
    logf_("  GetNativeDisplay rc=%d ndpy=%p\n", rc, ndpy);
    if (rc != 0) goto restore;

    void *px = NULL;
    rc = p_CreatePx(ndpy, 1 /* EMGD_HMI_BUFFER */, 800, 480, &px);
    logf_("  CreatePixmap rc=%d px=%p\n", rc, px);
    if (rc != 0) goto restore;

    // ── Stage 06: map and paint via CPU memcpy ──
    marker("06_map_and_paint");
    void *vaddr = NULL;
    rc = p_MapPx(px, &vaddr);
    logf_("  MapPixmap rc=%d vaddr=%p\n", rc, vaddr);
    if (rc != 0 || !vaddr) {
        logf_("  ABORT: MapPixmap failed\n");
        goto restore;
    }

    // Paint 4 vertical color bars, 200px wide each.
    // ARGB8888 native order: byte 0=B, 1=G, 2=R, 3=A on little-endian
    // memory written as uint32_t 0xAARRGGBB.
    uint32_t *pix = (uint32_t *) vaddr;
    int W = 800, H = 480;
    for (int y = 0; y < H; y++) {
        for (int x = 0; x < W; x++) {
            int band = x / 200;
            uint32_t c;
            switch (band) {
                case 0: c = 0xFFFF0000; break;  // ARGB-literal RED   (bytes: 00 00 FF FF)
                case 1: c = 0xFF00FF00; break;  // ARGB-literal GREEN (bytes: 00 FF 00 FF)
                case 2: c = 0xFF0000FF; break;  // ARGB-literal BLUE  (bytes: FF 00 00 FF)
                default: c = 0xFFFFFFFF; break; // WHITE              (bytes: FF FF FF FF)
            }
            pix[y * W + x] = c;
        }
    }
    logf_("  painted 4 bars: ARGB literals 0xFFFF0000/0xFF00FF00/0xFF0000FF/0xFFFFFFFF\n");

    // ── Stage 07: bind pixmap to scanout ──
    marker("07_configure_buffers");
    BufState s0[3] = {{0}};
    s0[0].plane_type    = 1;  // EMGD_HMI_BUFFER
    s0[0].pixmap_handle = (uint32_t)(uintptr_t) px;
    s0[0].width  = 800;
    s0[0].height = 480;
    s0[0].stride = 800 * 4;

    BufState s1[3] = {{0}};
    BufState *state[2] = { s0, s1 };
    rc = p_ConfBuf(ndpy, state);
    logf_("  ConfigureBuffers rc=%d\n", rc);
    if (rc != 0) { logf_("  ConfigureBuffers failed\n"); goto restore; }

    // ── Stage 08: hold for 20 seconds so Doug can see + photograph ──
    marker("08_hold_20s");
    logf_("  holding for 20s starting uptime=%.2fs\n", uptime());
    sleep(20);
    logf_("  hold complete uptime=%.2fs\n", uptime());

    if (p_FreeMem) p_FreeMem(px);

restore:
    marker("09_restart");
    run_cmd("systemctl start nav_navi.service nav_dispapf.service 2>&1");

    marker("99_copy");
    system("mountpoint -q /boot || mount /dev/mmcblk0p1 /boot 2>/dev/null "
           "|| mount /dev/mmcblk1p1 /boot 2>/dev/null");
    system("cp /tmp/q60-planb-6.log /boot/Q60_PLANB_SPIKE6.LOG 2>/dev/null");
    system("cp /tmp/q60-bl-transitions.log /boot/Q60_BL_TRANSITIONS.LOG 2>/dev/null");
    system("cp /tmp/q60-planb-6-stage-*.txt /boot/ 2>/dev/null; sync");

    logf_("=== DONE at uptime=%.2fs ===\n", uptime());
    fclose(g_log);
    if (g_trans != stderr) fclose(g_trans);
    return 0;
}
