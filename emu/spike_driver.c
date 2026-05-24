/*
 * spike_driver.c
 *
 * Minimal driver that mirrors the spike7 / drawbuf call sequence — used
 * to exercise the local emgdhmid_stub + libemgdhmi_shim end-to-end without
 * needing GL / EGL or the real hardware.
 *
 * We deliberately do NOT include spike7's source — it pulls in dlopen
 * shenanigans, marker files in /tmp, and uptime-gated stalls. This driver
 * compiles against the shim's declared API directly so we get a clean
 * pass/fail signal.
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>

typedef struct {
    uint32_t plane_type;
    uint32_t pixmap_handle;
    uint32_t pixmap_handle_hi;
    int32_t  screen_x, screen_y;
    int32_t  src_x, src_y;
    int32_t  width, height;
    uint32_t stride;
    uint32_t flags0, flags1, flags2, flags3;
} EMGDHmiBufferState;

extern int emgdHmiGetNativeDisplay(void **);
extern int emgdHmiGetNumScreens(void *);
extern int emgdHmiGetFramebufferSize(void *, int *, int *);
extern int emgdHmiGetScreenParams(void *, int, int *, int *, int *, int *);
extern int emgdHmiCreatePixmap(void *, int, int, int, void **);
extern int emgdHmiDestroyPixmap(void *, void *);
extern int emgdHmiMapPixmap(void *, void *, unsigned, unsigned, unsigned, void **);
extern int emgdHmiFreeMem(void *);
extern int emgdHmiConfigureBuffers(void *, EMGDHmiBufferState **);
extern int emgdHmiRequestFlip(void *, int, int, int *);

#define CHECK(call, ok) do { \
    int _rc = (call); \
    printf("  %-30s rc=%d %s\n", #call, _rc, (_rc == (ok)) ? "OK" : "FAIL"); \
    if (_rc != (ok)) { fails++; } \
} while (0)

int main(void) {
    int fails = 0;

    printf("=== spike_driver — Plan B''' call chain against local stub ===\n");

    /* 1. Connect */
    void *ndpy = NULL;
    CHECK(emgdHmiGetNativeDisplay(&ndpy), 0);
    printf("  ndpy = %p (expect 0xd39ade6b)\n", ndpy);
    if ((uintptr_t)ndpy != 0xd39ade6b) { printf("  ndpy magic mismatch\n"); fails++; }

    /* 2. Inventory */
    int n = emgdHmiGetNumScreens(ndpy);
    printf("  GetNumScreens -> %d  %s\n", n, n == 2 ? "OK" : "FAIL");
    if (n != 2) fails++;

    int fbw = 0, fbh = 0;
    CHECK(emgdHmiGetFramebufferSize(ndpy, &fbw, &fbh), 0);
    printf("  framebuffer = %dx%d\n", fbw, fbh);

    int sx, sy, sw, sh;
    CHECK(emgdHmiGetScreenParams(ndpy, 0, &sx, &sy, &sw, &sh), 0);
    printf("  screen[0] = (%d,%d) %dx%d\n", sx, sy, sw, sh);
    CHECK(emgdHmiGetScreenParams(ndpy, 1, &sx, &sy, &sw, &sh), 0);
    printf("  screen[1] = (%d,%d) %dx%d\n", sx, sy, sw, sh);

    /* 3. Allocate pixmap (the GLES surface) */
    void *px = NULL;
    CHECK(emgdHmiCreatePixmap(ndpy, 1 /*EMGD_HMI_BUFFER*/, 800, 480, &px), 0);
    printf("  pixmap handle = %p\n", px);
    if (!px) { printf("  no pixmap handle returned\n"); fails++; }

    /* 4. Map for CPU paint */
    void *vaddr = NULL;
    CHECK(emgdHmiMapPixmap(ndpy, px, 800, 480, 800 * 4, &vaddr), 0);
    printf("  mapped vaddr = %p\n", vaddr);
    if (!vaddr) { printf("  MapPixmap returned NULL\n"); fails++; }

    /* 5. Paint vertical bars (the drawbuf-style memcpy paint) */
    if (vaddr) {
        uint32_t *pix = (uint32_t *)vaddr;
        for (int y = 0; y < 480; y++) {
            for (int x = 0; x < 800; x++) {
                int band = x / 200;
                uint32_t c;
                switch (band) {
                case 0:  c = 0xFFFF0000; break;
                case 1:  c = 0xFF00FF00; break;
                case 2:  c = 0xFF0000FF; break;
                default: c = 0xFFFFFFFF; break;
                }
                pix[y * 800 + x] = c;
            }
        }
        /* Spot-check the corners — proves the buffer is real memory */
        printf("  paint check: top-left=0x%08x top-right=0x%08x\n",
               pix[0], pix[799]);
        if (pix[0] != 0xFFFF0000 || pix[799] != 0xFFFFFFFF) {
            printf("  paint did not survive\n"); fails++;
        }
    }

    /* 6. Publish via ConfigureBuffers */
    EMGDHmiBufferState screen0[3] = {{0}};
    screen0[0].plane_type    = 1;
    screen0[0].pixmap_handle = (uint32_t)(uintptr_t)px;
    screen0[0].width  = 800;
    screen0[0].height = 480;
    screen0[0].stride = 800 * 4;
    EMGDHmiBufferState screen1[3] = {{0}};
    EMGDHmiBufferState *state[2] = { screen0, screen1 };
    CHECK(emgdHmiConfigureBuffers(ndpy, state), 0);

    /* 7. RequestFlip (no-op in real daemon; ours returns success) */
    int did_flip = 0;
    CHECK(emgdHmiRequestFlip(ndpy, 0, 0, &did_flip), 0);
    printf("  flip indicator = %d\n", did_flip);

    /* 8. Validation — feed deliberately bad config to confirm BAD_CONFIG */
    EMGDHmiBufferState bad[3] = {{0}};
    bad[0].plane_type = 1;
    bad[0].pixmap_handle = (uint32_t)(uintptr_t)px;
    bad[0].width  = 800;
    bad[0].height = 480;
    bad[0].stride = 100;            /* invalid: stride < width */
    EMGDHmiBufferState *bstate[2] = { bad, screen1 };
    int rc_bad = emgdHmiConfigureBuffers(ndpy, bstate);
    printf("  ConfigureBuffers(bad stride) rc=%d %s\n",
           rc_bad, rc_bad == -3 ? "OK (caught)" : "FAIL (should be -3)");
    if (rc_bad != -3) fails++;

    /* 9. Cleanup */
    CHECK(emgdHmiDestroyPixmap(ndpy, px), 0);

    printf("\n=== %s — %d failure(s) ===\n",
           fails == 0 ? "PASS" : "FAIL", fails);
    return fails ? 1 : 0;
}
