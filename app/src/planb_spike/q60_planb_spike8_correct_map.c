// q60_planb_spike8_correct_map.c
//
// Spike 7 segfaulted because the MapPixmap signature D2 documented was wrong.
// Disassembly of the real function at lib offset 0x1787 shows it sends opcode
// 8 (QUERYPIXMAP) and writes results to OUT pointers:
//
//   int emgdHmiMapPixmap(EGLNativeDisplayType display,
//                        EGLNativePixmapType  pixmap,
//                        unsigned int        *out_w,
//                        unsigned int        *out_h,
//                        unsigned int        *out_stride,
//                        PVR2D_VOID         **out_mem);
//
// arg3 (out_w), arg4 (out_h), arg5 (out_stride) — NOT by-value. The function
// queries the pixmap's actual dimensions and stride from the daemon, then
// returns the mapped CPU VA via *out_mem.
//
// Everything else identical to spike 7:
//   - no daemon kill (ConfigureBuffers rebinds scanout)
//   - 4-bar paint pattern for byte-order ID
//   - hold long enough for ~75s panel-on
//
// LESSON CAPTURED: when the disassembled function string-literal embeds an
// IPC opcode name (here: "QueryPixmap"), trust the disassembly over the
// agent-derived signature. Update the emulator shim before next iteration.

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
    snprintf(path, sizeof(path), "/tmp/q60-planb-8-stage-%s.txt", stage);
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
    g_log = fopen("/tmp/q60-planb-8.log", "w");
    if (!g_log) g_log = stderr;
    logf_("=== Spike 8 — corrected MapPixmap signature ===\n");
    logf_("launch uptime=%.2fs\n", uptime());

    marker("01_dlopen");
    void *libhmi = dlopen("libemgdhmi.so.0", RTLD_NOW | RTLD_GLOBAL);
    if (!libhmi) { logf_("  dlopen fail\n"); goto end; }

    int (*p_GetNd)(void **)
        = (int (*)(void **)) dlsym(libhmi, "emgdHmiGetNativeDisplay");
    int (*p_CreatePx)(void *, int, int, int, void **)
        = (int (*)(void *, int, int, int, void **)) dlsym(libhmi, "emgdHmiCreatePixmap");
    // CORRECTED: arg3/4/5 are OUT pointers
    int (*p_MapPx)(void *, void *, unsigned *, unsigned *, unsigned *, void **)
        = (int (*)(void *, void *, unsigned *, unsigned *, unsigned *, void **))
            dlsym(libhmi, "emgdHmiMapPixmap");
    int (*p_ConfBuf)(void *, BufState **)
        = (int (*)(void *, BufState **)) dlsym(libhmi, "emgdHmiConfigureBuffers");

    if (!p_GetNd || !p_CreatePx || !p_MapPx || !p_ConfBuf) {
        logf_("  ABORT: missing symbols (GetNd=%p CreatePx=%p MapPx=%p ConfBuf=%p)\n",
              p_GetNd, p_CreatePx, p_MapPx, p_ConfBuf);
        goto end;
    }

    marker("02_setup");
    void *ndpy = NULL;
    int rc = p_GetNd(&ndpy);
    logf_("  GetNativeDisplay rc=%d ndpy=%p\n", rc, ndpy);
    if (rc != 0) goto end;

    void *px = NULL;
    rc = p_CreatePx(ndpy, 1 /* EMGD_HMI_BUFFER */, 800, 480, &px);
    logf_("  CreatePixmap rc=%d px=%p\n", rc, px);
    if (rc != 0) goto end;

    marker("03_map");
    unsigned w_out = 0, h_out = 0, stride_out = 0;
    void *vaddr = NULL;
    rc = p_MapPx(ndpy, px, &w_out, &h_out, &stride_out, &vaddr);
    logf_("  MapPixmap rc=%d  w=%u h=%u stride=%u vaddr=%p\n",
          rc, w_out, h_out, stride_out, vaddr);
    if (rc != 0 || !vaddr) { logf_("  MapPixmap failed\n"); goto end; }

    // Sanity: w/h should be 800x480 (what we asked CreatePixmap for); stride
    // tells us the byte-pitch the kernel allocated. If stride != 800*4 then
    // we have to use it (not 800*4) when computing pixel offsets and when
    // setting BufState.stride below.
    unsigned bytes_per_pixel = stride_out / (w_out ? w_out : 800);
    logf_("  inferred bytes_per_pixel = %u (stride=%u / w=%u)\n",
          bytes_per_pixel, stride_out, w_out);

    marker("04_paint");
    int W = (w_out > 0) ? (int)w_out : 800;
    int H = (h_out > 0) ? (int)h_out : 480;
    if (bytes_per_pixel != 4) {
        // If hardware is RGB565 (2 bytes) or YUV (2 bytes), our 32-bit paint
        // pattern won't show as expected. Log loudly so we know to retry.
        logf_("  WARN: bytes_per_pixel=%u (expected 4 for ARGB8888)\n", bytes_per_pixel);
    }
    uint32_t *pix = (uint32_t *) vaddr;
    // Use stride-aware indexing in case stride > W*4
    int stride_pixels = (stride_out / 4 > 0) ? (int)(stride_out / 4) : W;
    for (int y = 0; y < H; y++) {
        for (int x = 0; x < W; x++) {
            int band = x / (W / 4 > 0 ? W / 4 : 1);
            uint32_t c;
            switch (band) {
                case 0:  c = 0xFFFF0000; break;  // RED in ARGB literal
                case 1:  c = 0xFF00FF00; break;  // GREEN
                case 2:  c = 0xFF0000FF; break;  // BLUE
                default: c = 0xFFFFFFFF; break;  // WHITE
            }
            pix[y * stride_pixels + x] = c;
        }
    }
    logf_("  painted %dx%d (stride_pixels=%d) first=0x%08x last=0x%08x\n",
          W, H, stride_pixels, pix[0], pix[H * stride_pixels - 1]);

    marker("05_configure");
    BufState s0[3] = {{0}};
    s0[0].plane_type    = 1;
    s0[0].pixmap_handle = (uint32_t)(uintptr_t) px;
    s0[0].width  = W;
    s0[0].height = H;
    s0[0].stride = (stride_out > 0) ? (int32_t)stride_out : (W * 4);
    BufState s1[3] = {{0}};
    BufState *state[2] = { s0, s1 };
    rc = p_ConfBuf(ndpy, state);
    logf_("  ConfigureBuffers rc=%d\n", rc);
    if (rc == -3) {
        // D5 per-screen-h fallback
        s0[0].height = 450;
        rc = p_ConfBuf(ndpy, state);
        logf_("  ConfigureBuffers (h=450) rc=%d\n", rc);
    }
    if (rc != 0) goto end;

    // Hold long enough for backlight-on at ~75s plus 30s observation window.
    marker("06_hold_120s");
    logf_("  holding 120s starting uptime=%.2fs\n", uptime());
    for (int i = 0; i < 24; i++) {  // 24 × 5s = 120s
        sleep(5);
        // every 30s log so we can correlate with what Doug sees
        if (i % 6 == 0) logf_("  ... hold uptime=%.1fs\n", uptime());
    }
    logf_("  hold complete uptime=%.2fs\n", uptime());

end:
    marker("99_copy");
    system("mountpoint -q /boot || mount /dev/mmcblk0p1 /boot 2>/dev/null "
           "|| mount /dev/mmcblk1p1 /boot 2>/dev/null");
    system("cp /tmp/q60-planb-8.log /boot/Q60_PLANB_SPIKE8.LOG 2>/dev/null");
    system("cp /tmp/q60-planb-8-stage-*.txt /boot/ 2>/dev/null; sync");
    logf_("=== DONE at uptime=%.2fs ===\n", uptime());
    fclose(g_log);
    return 0;
}
