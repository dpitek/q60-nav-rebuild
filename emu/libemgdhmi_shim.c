/*
 * libemgdhmi_shim.c
 *
 * Stand-in for the factory /usr/lib/libemgdhmi.so.0.1.0 used during
 * local LD_PRELOAD-style testing of the Q60 Plan B''' call chain.
 *
 * Compile to libemgdhmi.so.0  (i386 to match the target) and either:
 *   - LD_PRELOAD=./libemgdhmi.so.0 ./spike
 *   - install at /tmp/q60-shim/lib/libemgdhmi.so.0  and add to LD_LIBRARY_PATH
 *
 * Provides only the functions the Plan B''' spikes call (see
 * docs/forensic-libemgdhmi-api.md for the full 19-symbol surface):
 *
 *     emgdHmiGetNativeDisplay        — connects to /tmp/.emgdhmid_socket
 *     emgdHmiGetNumScreens
 *     emgdHmiGetFramebufferSize
 *     emgdHmiGetScreenParams
 *     emgdHmiCreatePixmap
 *     emgdHmiDestroyPixmap
 *     emgdHmiMapPixmap               — process-local mmap, NO IPC
 *     emgdHmiFreeMem
 *     emgdHmiConfigureBuffers
 *     emgdHmiRequestFlip
 *     emgdHmiFlipScreen
 *
 * Wire-format details cribbed from:
 *   docs/forensic-libemgdhmi-api.md  §3
 *   docs/forensic-emgdhmid-flip-protocol.md
 *
 * Each request is a 384-byte buffer:
 *   bytes  0..3   size           (set to message size, e.g. 0x17c for ConfigureBuffers)
 *   bytes  4..35  name           (ASCII, zero-padded; daemon ignores)
 *   bytes 36..39  opcode         (the dispatch key)
 *   bytes 40..    per-opcode payload
 *
 * Daemon replies with another 384-byte buffer in-place.
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <stdint.h>
#include <errno.h>
#include <pthread.h>
#include <sys/socket.h>
#include <sys/un.h>

#define SOCK_PATH "/tmp/.emgdhmid_socket"
#define MSG_SIZE  384
#define MAGIC_NDPY ((void *)(uintptr_t)0xd39ade6b)

/* return codes, from forensic-libemgdhmi-api.md */
#define EMGD_SUCCESS         0
#define EMGD_ERR_BAD_ALLOC  -4
#define EMGD_ERR_BAD_ID     -5
#define EMGD_ERR_IO_ERROR   -6

enum {
    OP_GETNUMSCREENS      = 0,
    OP_GETFRAMEBUFFERSIZE = 1,
    OP_GETSCREENPARAMS    = 2,
    OP_REQUESTFLIP        = 3,
    OP_FLIPSCREEN         = 4,
    OP_CREATEPIXMAP       = 5,
    OP_DESTROYPIXMAP      = 6,
    OP_QUERYPIXMAP        = 8,
    OP_CONFIGUREBUFFERS   = 9,
};

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

/* Per-process pixmap bookkeeping so MapPixmap can return CPU memory */
struct local_pixmap {
    uint32_t handle;
    int      w, h;
    unsigned int stride;          /* byte-pitch */
    size_t   bytes;
    void    *vaddr;               /* actual pixel buffer */
    void    *meminfo;             /* ShimPVR2DMEMINFO* returned by MapPixmap */
    struct local_pixmap *next;
};

static int  g_sockfd  = -1;
static struct local_pixmap *g_pixmap_list = NULL;
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;

/* ── plumbing ── */

static int connect_socket(void) {
    if (g_sockfd >= 0) return 0;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_un addr = {0};
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, SOCK_PATH, sizeof(addr.sun_path) - 1);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(fd); return -1;
    }
    g_sockfd = fd;
    return 0;
}

static int xchg(char *buf) {
    if (connect_socket() < 0) return EMGD_ERR_IO_ERROR;
    pthread_mutex_lock(&g_lock);
    ssize_t sent = 0;
    while (sent < MSG_SIZE) {
        ssize_t w = write(g_sockfd, buf + sent, MSG_SIZE - sent);
        if (w <= 0) { pthread_mutex_unlock(&g_lock);
                      close(g_sockfd); g_sockfd = -1;
                      return EMGD_ERR_IO_ERROR; }
        sent += w;
    }
    ssize_t got = 0;
    while (got < MSG_SIZE) {
        ssize_t r = read(g_sockfd, buf + got, MSG_SIZE - got);
        if (r <= 0) { pthread_mutex_unlock(&g_lock);
                      close(g_sockfd); g_sockfd = -1;
                      return EMGD_ERR_IO_ERROR; }
        got += r;
    }
    pthread_mutex_unlock(&g_lock);
    return EMGD_SUCCESS;
}

static void pack_hdr(char *buf, const char *name, uint32_t size, uint32_t op) {
    memset(buf, 0, MSG_SIZE);
    memcpy(buf + 0, &size, 4);
    strncpy(buf + 4, name, 31);
    memcpy(buf + 36, &op, 4);
}

/* ── exports ── */

int emgdHmiGetNativeDisplay(void **result) {
    if (!result) return EMGD_ERR_BAD_ALLOC;
    if (connect_socket() < 0) return EMGD_ERR_IO_ERROR;
    *result = MAGIC_NDPY;
    return EMGD_SUCCESS;
}

int emgdHmiGetNumScreens(void *display) {
    (void)display;
    char buf[MSG_SIZE];
    pack_hdr(buf, "GetNumScreens", 44, OP_GETNUMSCREENS);
    if (xchg(buf) != EMGD_SUCCESS) return -1;
    int32_t n; memcpy(&n, buf + 40, 4);
    return n;
}

int emgdHmiGetFramebufferSize(void *display, int *w, int *h) {
    (void)display;
    char buf[MSG_SIZE];
    pack_hdr(buf, "GetFramebufferSize", 52, OP_GETFRAMEBUFFERSIZE);
    int rc = xchg(buf);
    if (rc != EMGD_SUCCESS) return rc;
    if (w) memcpy(w, buf + 40, 4);
    if (h) memcpy(h, buf + 44, 4);
    int32_t rv; memcpy(&rv, buf + 48, 4);
    return rv;
}

int emgdHmiGetScreenParams(void *display, int screen,
                           int *x, int *y, int *w, int *h) {
    (void)display;
    char buf[MSG_SIZE];
    pack_hdr(buf, "GetScreenParams", 64, OP_GETSCREENPARAMS);
    memcpy(buf + 40, &screen, 4);
    int rc = xchg(buf);
    if (rc != EMGD_SUCCESS) return rc;
    if (x) memcpy(x, buf + 44, 4);
    if (y) memcpy(y, buf + 48, 4);
    if (w) memcpy(w, buf + 52, 4);
    if (h) memcpy(h, buf + 56, 4);
    int32_t rv; memcpy(&rv, buf + 60, 4);
    return rv;
}

int emgdHmiCreatePixmap(void *display, int usage, int w, int h, void **result) {
    (void)display;
    if (!result) return EMGD_ERR_BAD_ALLOC;
    char buf[MSG_SIZE];
    pack_hdr(buf, "CreatePixmap", 60, OP_CREATEPIXMAP);
    memcpy(buf + 40, &usage, 4);
    memcpy(buf + 44, &w,     4);
    memcpy(buf + 48, &h,     4);
    int rc = xchg(buf);
    if (rc != EMGD_SUCCESS) return rc;
    uint32_t handle; memcpy(&handle, buf + 52, 4);
    int32_t  rv;     memcpy(&rv,     buf + 56, 4);
    if (rv != 0) return rv;

    /* Local bookkeeping so MapPixmap can return memory */
    struct local_pixmap *p = calloc(1, sizeof(*p));
    if (!p) return EMGD_ERR_BAD_ALLOC;
    p->handle = handle;
    p->w = w; p->h = h;
    p->stride = (unsigned)w * 4;            /* assume ARGB8888 byte-pitch */
    p->bytes = (size_t)p->stride * (size_t)h;
    p->vaddr = NULL;
    p->meminfo = NULL;
    pthread_mutex_lock(&g_lock);
    p->next = g_pixmap_list; g_pixmap_list = p;
    pthread_mutex_unlock(&g_lock);
    *result = (void *)(uintptr_t)handle;
    return 0;
}

int emgdHmiDestroyPixmap(void *display, void *pixmap) {
    (void)display;
    uint32_t handle = (uint32_t)(uintptr_t)pixmap;
    char buf[MSG_SIZE];
    pack_hdr(buf, "DestroyPixmap", 48, OP_DESTROYPIXMAP);
    memcpy(buf + 40, &handle, 4);
    int rc = xchg(buf);
    if (rc != EMGD_SUCCESS) return rc;
    int32_t rv; memcpy(&rv, buf + 44, 4);

    pthread_mutex_lock(&g_lock);
    struct local_pixmap **pp = &g_pixmap_list;
    while (*pp) {
        if ((*pp)->handle == handle) {
            struct local_pixmap *dead = *pp;
            *pp = dead->next;
            free(dead->vaddr); free(dead->meminfo); free(dead);
            break;
        }
        pp = &(*pp)->next;
    }
    pthread_mutex_unlock(&g_lock);
    return rv;
}

/* CORRECTED 2026-05-24 to match real lib disasm at offset 0x4163a6f0:
 *   int emgdHmiMapPixmap(display, pixmap,
 *                        unsigned *out_w, unsigned *out_h, unsigned *out_stride,
 *                        PVR2DMEMINFO **out_mem)
 *
 * Sends opcode 8 QUERYPIXMAP to the daemon, gets back the pixmap's actual
 * w/h/stride, then calls PVR2DMemMap which returns a PVR2DMEMINFO* (NOT a
 * direct CPU VA). Caller must dereference *out_mem to a PVR2DMEMINFO struct,
 * then use its .pBase field to get the actual pixel pointer.
 *
 * Spike 7 / 8 crashed by treating w/h/stride as by-value (wrong — they are
 * OUT pointers) and by treating *out_mem as a direct VA (wrong — it's a
 * pointer to PVR2DMEMINFO whose first field is the VA).
 */

/* Mimic the real Imagination PVR2DMEMINFO layout (Khronos PVR2D ABI). */
typedef struct {
    void     *pBase;            /* +0x00 — virtual address of pixel buffer */
    uint32_t  ui32MemSize;      /* +0x04 — size in bytes */
    uint32_t  ui32DevAddr;      /* +0x08 — GTT/device address */
    uint32_t  ulFlags;          /* +0x0c */
    void     *hPrivateData;     /* +0x10 */
    void     *hPrivateMapData;  /* +0x14 */
} ShimPVR2DMEMINFO;

int emgdHmiMapPixmap(void *display, void *pixmap,
                     unsigned int *out_w, unsigned int *out_h,
                     unsigned int *out_stride,
                     void **out_mem)
{
    (void)display;
    if (!out_mem) return EMGD_ERR_BAD_ALLOC;
    uint32_t handle = (uint32_t)(uintptr_t)pixmap;
    pthread_mutex_lock(&g_lock);
    struct local_pixmap *p = g_pixmap_list;
    while (p && p->handle != handle) p = p->next;
    if (!p) { pthread_mutex_unlock(&g_lock); return EMGD_ERR_BAD_ID; }
    if (!p->vaddr) {
        p->vaddr = calloc(1, p->bytes);
        if (!p->vaddr) { pthread_mutex_unlock(&g_lock); return EMGD_ERR_BAD_ALLOC; }
    }
    /* Allocate/reuse a PVR2DMEMINFO struct for this pixmap.
     * Real lib keeps these in a cache; we just attach one per pixmap. */
    if (!p->meminfo) {
        p->meminfo = calloc(1, sizeof(ShimPVR2DMEMINFO));
        if (!p->meminfo) { pthread_mutex_unlock(&g_lock); return EMGD_ERR_BAD_ALLOC; }
    }
    ShimPVR2DMEMINFO *info = (ShimPVR2DMEMINFO *) p->meminfo;
    info->pBase       = p->vaddr;
    info->ui32MemSize = p->bytes;
    info->ui32DevAddr = 0;          /* GTT offset; emulator doesn't model GTT */
    info->ulFlags     = 0;
    info->hPrivateData = NULL;
    info->hPrivateMapData = NULL;
    /* Write OUT params */
    if (out_w)      *out_w      = p->w;
    if (out_h)      *out_h      = p->h;
    if (out_stride) *out_stride = p->stride;
    *out_mem = p->meminfo;          /* PVR2DMEMINFO*, NOT a pixel VA */
    pthread_mutex_unlock(&g_lock);
    return EMGD_SUCCESS;
}

int emgdHmiFreeMem(void *pmem) {
    /* In the real lib this calls PVR2DMemFree on a PVR2DMEMINFO* — for our
     * stub we keep the allocation alive (it's owned by the pixmap rec) so
     * subsequent ConfigureBuffers can use it. No-op success. */
    (void)pmem;
    return EMGD_SUCCESS;
}

int emgdHmiConfigureBuffers(void *display, EMGDHmiBufferState **state) {
    (void)display;
    if (!state) return EMGD_ERR_BAD_ALLOC;
    char buf[MSG_SIZE];
    pack_hdr(buf, "ConfigureBuffers", 0x17c, OP_CONFIGUREBUFFERS);
    uint32_t nscr = 2;
    memcpy(buf + 40, &nscr, 4);
    for (uint32_t s = 0; s < 2; s++) {
        if (!state[s]) continue;
        for (int j = 0; j < 3; j++) {
            size_t off = 44 + s * (3 * 56) + j * 56;
            memcpy(buf + off, &state[s][j], 56);
            if (state[s][j].plane_type == 0) break;
        }
    }
    int rc = xchg(buf);
    if (rc != EMGD_SUCCESS) return rc;
    int32_t rv; memcpy(&rv, buf + 380, 4);
    return rv;
}

int emgdHmiRequestFlip(void *display, int screen, int owner, int *result) {
    (void)display;
    char buf[MSG_SIZE];
    pack_hdr(buf, "RequestFlip", 56, OP_REQUESTFLIP);
    memcpy(buf + 40, &screen, 4);
    memcpy(buf + 44, &owner,  4);
    int rc = xchg(buf);
    if (rc != EMGD_SUCCESS) return rc;
    if (result) memcpy(result, buf + 48, 4);
    int32_t rv; memcpy(&rv, buf + 52, 4);
    return rv;
}

int emgdHmiFlipScreen(void *display, int screen, int owner) {
    (void)display;
    char buf[MSG_SIZE];
    pack_hdr(buf, "FlipScreen", 52, OP_FLIPSCREEN);
    memcpy(buf + 40, &screen, 4);
    memcpy(buf + 44, &owner,  4);
    int rc = xchg(buf);
    if (rc != EMGD_SUCCESS) return rc;
    int32_t rv; memcpy(&rv, buf + 48, 4);
    return rv;
}

int emgdHmiCleanup(void) {
    pthread_mutex_lock(&g_lock);
    if (g_sockfd >= 0) { close(g_sockfd); g_sockfd = -1; }
    while (g_pixmap_list) {
        struct local_pixmap *d = g_pixmap_list;
        g_pixmap_list = d->next;
        free(d->vaddr); free(d);
    }
    pthread_mutex_unlock(&g_lock);
    return EMGD_SUCCESS;
}
