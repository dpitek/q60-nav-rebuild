/*
 * emgdhmid_stub.c
 *
 * Minimal stub of the factory emgdhmid daemon, sufficient to exercise the
 * Plan B''' client call chain on a Linux host (LD_PRELOAD shim talks to it).
 *
 * Protocol references (this repo):
 *   docs/forensic-emgdhmid-flip-protocol.md      — wire format, 384-byte msgs
 *   docs/forensic-libemgdhmi-api.md              — client-side API & opcodes
 *   docs/forensic-emgdbuffertype-struct.md       — EMGDHmiBufferState layout
 *   docs/forensic-drawbuf-call-sequence.md       — full happy-path sequence
 *
 * Key facts the stub mirrors faithfully:
 *   - Path:          /tmp/.emgdhmid_socket
 *   - Family:        AF_UNIX
 *   - Type:          SOCK_DGRAM   (factory) — but SOCK_STREAM is what the
 *                    real libemgdhmi.so opens; we accept both. The library
 *                    builds calls check_socket() that uses SOCK_STREAM
 *                    + connect(). The DAEMON binds AF_UNIX SOCK_DGRAM.
 *                    To keep the stub simple AND match the lib (since our
 *                    shim is what we use), we listen as SOCK_STREAM so the
 *                    factory libemgdhmi.so would actually be able to talk
 *                    to us. The shim does the same — STREAM.
 *   - Fixed msg sz:  384 bytes both directions
 *   - Header (40 B): [size:4][name:32][opcode:4]
 *   - Opcode field:  at byte offset 36 (0x24) inside the 384-byte buffer
 *
 * Supported opcodes (returns EMGD_SUCCESS=0 for all unsupported):
 *      0 GETNUMSCREENS       — returns 2
 *      1 GETFRAMEBUFFERSIZE  — returns 800 x 960
 *      2 GETSCREENPARAMS     — screen 0 = (0,0,800,480), 1 = (0,480,800,480)
 *      5 CREATEPIXMAP        — returns monotonically-incrementing handle
 *      6 DESTROYPIXMAP       — looks up handle, marks free
 *      8 QUERYPIXMAP         — returns the dims we stored
 *      9 CONFIGUREBUFFERS    — logs every populated state[][] entry, succ
 *      3 REQUESTFLIP         — no-op success (like real daemon)
 *      4 FLIPSCREEN          — no-op success (like real daemon)
 *
 * Build (in Docker, see Makefile):  gcc -m32 -O0 -g -Wall -o emgdhmid_stub emgdhmid_stub.c -lpthread
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <unistd.h>
#include <stdint.h>
#include <errno.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/types.h>
#include <pthread.h>
#include <time.h>

#define SOCK_PATH "/tmp/.emgdhmid_socket"
#define MSG_SIZE  384                /* 0x180 — fixed on the wire */

/* opcode values match the EMGDHMIAPI enum */
enum {
    OP_GETNUMSCREENS      = 0,
    OP_GETFRAMEBUFFERSIZE = 1,
    OP_GETSCREENPARAMS    = 2,
    OP_REQUESTFLIP        = 3,
    OP_FLIPSCREEN         = 4,
    OP_CREATEPIXMAP       = 5,
    OP_DESTROYPIXMAP      = 6,
    OP_CONTROLPLANEFMT    = 7,
    OP_QUERYPIXMAP        = 8,
    OP_CONFIGUREBUFFERS   = 9,
    OP_STARTVIDEO         = 10,
    OP_STOPVIDEO          = 11,
    OP_SWITCHHZ           = 12,
};

/* EMGDHmiBufferState — 56 bytes, from forensic-emgdbuffertype-struct.md */
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

#define MAX_PIXMAPS 256
struct pixmap_rec {
    uint32_t handle;     /* 0 = empty slot */
    uint32_t usage;
    int32_t  width;
    int32_t  height;
    uint32_t stride;     /* bytes */
    void    *backing;    /* server-side memory (unused — kept for parity) */
};

static struct pixmap_rec g_pixmaps[MAX_PIXMAPS];
static uint32_t g_next_handle = 0x10000;   /* recognisable handle space */
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static volatile int g_run = 1;

static void log_msg(const char *fmt, ...) {
    char ts[32];
    time_t t = time(NULL);
    struct tm tm; localtime_r(&t, &tm);
    strftime(ts, sizeof(ts), "%H:%M:%S", &tm);
    fprintf(stderr, "[stub %s] ", ts);
    va_list ap; va_start(ap, fmt);
    vfprintf(stderr, fmt, ap); va_end(ap);
    fputc('\n', stderr);
    fflush(stderr);
}

static struct pixmap_rec *alloc_pixmap(uint32_t usage, int32_t w, int32_t h) {
    for (int i = 0; i < MAX_PIXMAPS; i++) {
        if (g_pixmaps[i].handle == 0) {
            g_pixmaps[i].handle = g_next_handle++;
            g_pixmaps[i].usage  = usage;
            g_pixmaps[i].width  = w;
            g_pixmaps[i].height = h;
            g_pixmaps[i].stride = (uint32_t)w * 4;   /* assume ARGB8888 */
            g_pixmaps[i].backing = NULL;
            return &g_pixmaps[i];
        }
    }
    return NULL;
}

static struct pixmap_rec *find_pixmap(uint32_t h) {
    if (!h) return NULL;
    for (int i = 0; i < MAX_PIXMAPS; i++)
        if (g_pixmaps[i].handle == h) return &g_pixmaps[i];
    return NULL;
}

static void handle_msg(char *buf) {
    /* opcode at offset 0x24 */
    uint32_t opcode;
    memcpy(&opcode, buf + 0x24, 4);

    switch (opcode) {

    case OP_GETNUMSCREENS: {
        /* response: out_count at offset 40 (0x28) */
        uint32_t n = 2;
        memcpy(buf + 40, &n, 4);
        log_msg("op=0 GETNUMSCREENS -> 2");
        break;
    }

    case OP_GETFRAMEBUFFERSIZE: {
        /* response: w at +40, h at +44, retval at +48 */
        int32_t w = 800, h = 960;
        int32_t rv = 0;
        memcpy(buf + 40, &w, 4);
        memcpy(buf + 44, &h, 4);
        memcpy(buf + 48, &rv, 4);
        log_msg("op=1 GETFRAMEBUFFERSIZE -> 800x960");
        break;
    }

    case OP_GETSCREENPARAMS: {
        /* in_screen at +40; out x,y,w,h,retval at +44,+48,+52,+56,+60 */
        int32_t scr; memcpy(&scr, buf + 40, 4);
        int32_t x, y, w, h, rv = 0;
        if (scr == 0) { x = 0; y = 0;   w = 800; h = 480; }
        else          { x = 0; y = 480; w = 800; h = 480; }
        memcpy(buf + 44, &x,  4);
        memcpy(buf + 48, &y,  4);
        memcpy(buf + 52, &w,  4);
        memcpy(buf + 56, &h,  4);
        memcpy(buf + 60, &rv, 4);
        log_msg("op=2 GETSCREENPARAMS(%d) -> %d,%d %dx%d", scr, x, y, w, h);
        break;
    }

    case OP_REQUESTFLIP: {
        /* in_screen+40, in_owner+44; out_result+48, out_retval+52 */
        int32_t scr, own;
        memcpy(&scr, buf + 40, 4);
        memcpy(&own, buf + 44, 4);
        int32_t res = 1, rv = 0;
        memcpy(buf + 48, &res, 4);
        memcpy(buf + 52, &rv,  4);
        log_msg("op=3 REQUESTFLIP(scr=%d own=%d) -> no-op success", scr, own);
        break;
    }

    case OP_FLIPSCREEN: {
        int32_t scr, own;
        memcpy(&scr, buf + 40, 4);
        memcpy(&own, buf + 44, 4);
        int32_t rv = 0;
        memcpy(buf + 48, &rv, 4);
        log_msg("op=4 FLIPSCREEN(scr=%d own=%d) -> no-op success", scr, own);
        break;
    }

    case OP_CREATEPIXMAP: {
        /* in_usage+40, in_w+44, in_h+48; out_handle+52, out_retval+56 */
        uint32_t usage; int32_t w, h;
        memcpy(&usage, buf + 40, 4);
        memcpy(&w,     buf + 44, 4);
        memcpy(&h,     buf + 48, 4);
        struct pixmap_rec *p = alloc_pixmap(usage, w, h);
        uint32_t handle = p ? p->handle : 0;
        int32_t  rv     = p ? 0 : -4;   /* EMGD_ERR_BAD_ALLOC */
        memcpy(buf + 52, &handle, 4);
        memcpy(buf + 56, &rv,     4);
        log_msg("op=5 CREATEPIXMAP(usage=%u %dx%d) -> handle=0x%x rv=%d",
                usage, w, h, handle, rv);
        break;
    }

    case OP_DESTROYPIXMAP: {
        /* in_pixmap+40; out_retval+44 */
        uint32_t h; memcpy(&h, buf + 40, 4);
        struct pixmap_rec *p = find_pixmap(h);
        int32_t rv = 0;
        if (p) { free(p->backing); memset(p, 0, sizeof(*p)); }
        memcpy(buf + 44, &rv, 4);
        log_msg("op=6 DESTROYPIXMAP(0x%x) -> rv=%d", h, rv);
        break;
    }

    case OP_QUERYPIXMAP: {
        /* in_pixmap+40; out_w+44, out_h+48, out_stride+52, out_usage+56, out_retval+60 */
        uint32_t h; memcpy(&h, buf + 40, 4);
        struct pixmap_rec *p = find_pixmap(h);
        int32_t rv = p ? 0 : -5;
        uint32_t w = p ? (uint32_t)p->width  : 0;
        uint32_t hh= p ? (uint32_t)p->height : 0;
        uint32_t s = p ? p->stride : 0;
        uint32_t u = p ? p->usage  : 0;
        memcpy(buf + 44, &w, 4);
        memcpy(buf + 48, &hh,4);
        memcpy(buf + 52, &s, 4);
        memcpy(buf + 56, &u, 4);
        memcpy(buf + 60, &rv,4);
        log_msg("op=8 QUERYPIXMAP(0x%x) -> %ux%u stride=%u usage=%u rv=%d",
                h, w, hh, s, u, rv);
        break;
    }

    case OP_CONFIGUREBUFFERS: {
        /* in_numscreens+40; state[0][0..2] starting at +44; state[1][0..2] at +44+168 */
        uint32_t nscr; memcpy(&nscr, buf + 40, 4);
        log_msg("op=9 CONFIGUREBUFFERS(nscreens=%u)", nscr);
        for (uint32_t s = 0; s < 2 && s < nscr; s++) {
            for (int j = 0; j < 3; j++) {
                EMGDHmiBufferState bs;
                size_t off = 44 + s * 168 + j * 56;
                memcpy(&bs, buf + off, sizeof(bs));
                if (bs.plane_type == 0) break;   /* end-of-list sentinel */
                log_msg("    state[%u][%d] plane=%u handle=0x%x rect=(%d,%d %dx%d) stride=%u",
                        s, j, bs.plane_type, bs.pixmap_handle,
                        bs.screen_x, bs.screen_y, bs.width, bs.height, bs.stride);
                /* basic validation parity with real daemon bindSurfaces */
                if (bs.plane_type > 4 ||
                    bs.screen_x < 0 || bs.screen_y < 0 ||
                    bs.width <= 0 || bs.height <= 0 ||
                    bs.stride < (uint32_t)bs.width) {
                    int32_t rv = -3;
                    memcpy(buf + 380, &rv, 4);
                    log_msg("    => BAD_CONFIG (-3)");
                    return;
                }
            }
        }
        int32_t rv = 0;
        memcpy(buf + 380, &rv, 4);
        break;
    }

    default: {
        log_msg("op=%u UNHANDLED -> success no-op", opcode);
        /* Many opcodes have retval at varying positions; for unhandled,
         * just zero the tail so callers see success.  */
        int32_t rv = 0;
        memcpy(buf + 44, &rv, 4);
        break;
    }
    } /* switch */
}

static void on_sigint(int sig) { (void)sig; g_run = 0; }

int main(int argc, char **argv) {
    (void)argc; (void)argv;
    signal(SIGINT,  on_sigint);
    signal(SIGTERM, on_sigint);
    signal(SIGPIPE, SIG_IGN);

    unlink(SOCK_PATH);

    int srv = socket(AF_UNIX, SOCK_STREAM, 0);
    if (srv < 0) { perror("socket"); return 1; }

    struct sockaddr_un addr = {0};
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, SOCK_PATH, sizeof(addr.sun_path) - 1);
    if (bind(srv, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind"); return 1;
    }
    if (listen(srv, 8) < 0) { perror("listen"); return 1; }
    log_msg("listening on %s (SOCK_STREAM)", SOCK_PATH);

    while (g_run) {
        struct sockaddr_un cl; socklen_t cl_len = sizeof(cl);
        int c = accept(srv, (struct sockaddr *)&cl, &cl_len);
        if (c < 0) {
            if (errno == EINTR) continue;
            perror("accept"); continue;
        }
        log_msg("client connected fd=%d", c);

        char buf[MSG_SIZE];
        for (;;) {
            ssize_t got = 0;
            while (got < MSG_SIZE) {
                ssize_t r = read(c, buf + got, MSG_SIZE - got);
                if (r <= 0) goto client_done;
                got += r;
            }
            pthread_mutex_lock(&g_lock);
            handle_msg(buf);
            pthread_mutex_unlock(&g_lock);

            ssize_t sent = 0;
            while (sent < MSG_SIZE) {
                ssize_t w = write(c, buf + sent, MSG_SIZE - sent);
                if (w <= 0) goto client_done;
                sent += w;
            }
        }
client_done:
        log_msg("client disconnected fd=%d", c);
        close(c);
    }

    close(srv);
    unlink(SOCK_PATH);
    log_msg("shutdown");
    return 0;
}
