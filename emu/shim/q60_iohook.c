/*
 * q60_iohook.c — LD_PRELOAD shim that fakes /dev/v2gbridge, /dev/dri/card0,
 * /dev/video0, /dev/i2c-0, /dev/v2g, and stubs ioctl() on them.
 *
 * Goal: let factory daemons (emgdhmid, hmictrl_proc, etc.) progress past
 * their hardware-init phase under the Docker DSU emulator so we can see what
 * they do NEXT.
 *
 * Build (i386 musl, no PIE, ABI tag stripped):
 *   docker run --rm --platform linux/386 -v $(pwd):/build alpine:latest sh -c \
 *     "apk add gcc musl-dev binutils && \
 *      gcc -shared -fPIC -m32 -O2 -o /build/q60_iohook.so /build/q60_iohook.c -ldl && \
 *      objcopy --remove-section=.note.ABI-tag /build/q60_iohook.so"
 *
 * Use:
 *   LD_PRELOAD=/q60_iohook.so /usr/sbin/emgdhmid
 *
 * Behavior:
 *  - open/open64 for matching path  → return synthetic fd starting at 4001
 *  - ioctl on synthetic fd          → log request, return 0
 *  - close on synthetic fd          → return 0
 *  - read/write/lseek/mmap on synthetic fd → log + sensible defaults
 *
 * Logging goes to /tmp/q60_iohook.log (append, line-buffered).
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <errno.h>
#include <pthread.h>
#include <dlfcn.h>

#define LOG_PATH "/tmp/q60_iohook.log"
#define FAKE_FD_BASE 4001
#define FAKE_FD_MAX  4100

/* Paths we fake. Tail-anchored substring match. */
static const char *FAKE_PATHS[] = {
    "/dev/v2gbridge",
    "/dev/dri/card0",
    "/dev/video0",
    "/dev/v2g",
    "/dev/i2c-0",
    "/dev/watchdog",
    "/dev/dri/controlD64",
    "/dev/dri/renderD128",
    NULL
};

/* Per-fake-fd state: which path it was opened with */
static struct {
    int in_use;
    char path[64];
} fake_fds[FAKE_FD_MAX - FAKE_FD_BASE];

static pthread_mutex_t fd_lock = PTHREAD_MUTEX_INITIALIZER;
/* Raw-fd logging — avoids glibc/musl FILE-layout incompatibility */
static int log_fd = -1;
static pthread_mutex_t log_lock = PTHREAD_MUTEX_INITIALIZER;

/* Real function pointers — chained via dlsym(RTLD_NEXT,...) against the target's libc */
static int (*real_open)(const char *, int, ...) = NULL;
static int (*real_open64)(const char *, int, ...) = NULL;
static int (*real_close)(int) = NULL;
static int (*real_ioctl)(int, int, ...) = NULL;
static ssize_t (*real_read)(int, void *, size_t) = NULL;
static ssize_t (*real_write)(int, const void *, size_t) = NULL;
static off_t (*real_lseek)(int, off_t, int) = NULL;
static void * (*real_mmap)(void *, size_t, int, int, int, off_t) = NULL;

static void init_real_syms(void) {
    if (!real_open)   real_open   = dlsym(RTLD_NEXT, "open");
    if (!real_open64) real_open64 = dlsym(RTLD_NEXT, "open64");
    if (!real_close)  real_close  = dlsym(RTLD_NEXT, "close");
    if (!real_ioctl)  real_ioctl  = dlsym(RTLD_NEXT, "ioctl");
    if (!real_read)   real_read   = dlsym(RTLD_NEXT, "read");
    if (!real_write)  real_write  = dlsym(RTLD_NEXT, "write");
    if (!real_lseek)  real_lseek  = dlsym(RTLD_NEXT, "lseek");
    if (!real_mmap)   real_mmap   = dlsym(RTLD_NEXT, "mmap");
}

static void ensure_log(void) {
    pthread_mutex_lock(&log_lock);
    if (log_fd < 0 && real_open) {
        log_fd = real_open(LOG_PATH, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (log_fd >= 0 && real_write) {
            char banner[64];
            int n = snprintf(banner, sizeof(banner),
                             "=== q60_iohook loaded (pid=%d) ===\n", (int)getpid());
            if (n > 0) real_write(log_fd, banner, n);
        }
    }
    pthread_mutex_unlock(&log_lock);
}

static void hooklog(const char *fmt, ...) {
    char buf[1024];
    int n;
    va_list ap;

    init_real_syms();
    ensure_log();
    if (log_fd < 0 || !real_write) return;

    n = snprintf(buf, sizeof(buf), "[%d] ", (int)getpid());
    va_start(ap, fmt);
    n += vsnprintf(buf + n, sizeof(buf) - n - 1, fmt, ap);
    va_end(ap);
    if (n >= (int)sizeof(buf) - 1) n = sizeof(buf) - 2;
    buf[n++] = '\n';

    pthread_mutex_lock(&log_lock);
    real_write(log_fd, buf, n);
    pthread_mutex_unlock(&log_lock);
}

static int is_fake_path(const char *path) {
    if (!path) return 0;
    for (int i = 0; FAKE_PATHS[i]; i++) {
        if (strcmp(path, FAKE_PATHS[i]) == 0) return 1;
    }
    return 0;
}

static int alloc_fake_fd(const char *path) {
    pthread_mutex_lock(&fd_lock);
    int idx = -1;
    for (int i = 0; i < FAKE_FD_MAX - FAKE_FD_BASE; i++) {
        if (!fake_fds[i].in_use) {
            fake_fds[i].in_use = 1;
            strncpy(fake_fds[i].path, path, sizeof(fake_fds[i].path) - 1);
            fake_fds[i].path[sizeof(fake_fds[i].path) - 1] = 0;
            idx = i;
            break;
        }
    }
    pthread_mutex_unlock(&fd_lock);
    return (idx < 0) ? -1 : (FAKE_FD_BASE + idx);
}

static int is_fake_fd(int fd) {
    return fd >= FAKE_FD_BASE && fd < FAKE_FD_MAX
        && fake_fds[fd - FAKE_FD_BASE].in_use;
}

static void free_fake_fd(int fd) {
    if (is_fake_fd(fd)) {
        pthread_mutex_lock(&fd_lock);
        fake_fds[fd - FAKE_FD_BASE].in_use = 0;
        fake_fds[fd - FAKE_FD_BASE].path[0] = 0;
        pthread_mutex_unlock(&fd_lock);
    }
}

static const char *fake_path_for(int fd) {
    return is_fake_fd(fd) ? fake_fds[fd - FAKE_FD_BASE].path : "?";
}

/* ============================ wrappers ============================ */

int open(const char *path, int flags, ...) {
    init_real_syms();
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap; va_start(ap, flags);
        mode = va_arg(ap, int);
        va_end(ap);
    }

    if (is_fake_path(path)) {
        int fd = alloc_fake_fd(path);
        hooklog("open(\"%s\", 0x%x) → FAKE fd=%d", path, flags, fd);
        if (fd < 0) { errno = EMFILE; return -1; }
        return fd;
    }
    return real_open(path, flags, mode);
}

int open64(const char *path, int flags, ...) {
    init_real_syms();
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap; va_start(ap, flags);
        mode = va_arg(ap, int);
        va_end(ap);
    }
    if (is_fake_path(path)) {
        int fd = alloc_fake_fd(path);
        hooklog("open64(\"%s\", 0x%x) → FAKE fd=%d", path, flags, fd);
        if (fd < 0) { errno = EMFILE; return -1; }
        return fd;
    }
    if (real_open64) return real_open64(path, flags, mode);
    return real_open(path, flags, mode);
}

int close(int fd) {
    init_real_syms();
    if (is_fake_fd(fd)) {
        hooklog("close(fd=%d /* %s */)", fd, fake_path_for(fd));
        free_fake_fd(fd);
        return 0;
    }
    return real_close(fd);
}

/* Standard DRM struct layouts (i386 32-bit ABI) */
struct shim_drm_version {
    int major, minor, patchlevel;
    unsigned int name_len;
    char *name;
    unsigned int date_len;
    char *date;
    unsigned int desc_len;
    char *desc;
};
struct shim_drm_unique {
    unsigned int unique_len;
    char *unique;
};
struct shim_drm_auth {
    unsigned int magic;
};

static int handle_drm(int fd, unsigned long req, void *arg, unsigned int nr, unsigned int sz) {
    /* DRM_IOCTL_VERSION (nr=0, sz=36 on i386) */
    if (nr == 0 && sz == 36 && arg) {
        struct shim_drm_version *v = (struct shim_drm_version *)arg;
        v->major = 1; v->minor = 0; v->patchlevel = 0;
        /* Fill name/date/desc if caller provided buffers */
        const char *name = "emgd";
        const char *date = "20100723";
        const char *desc = "Intel EMGD";
        if (v->name && v->name_len > 0) {
            unsigned int n = v->name_len < strlen(name) ? v->name_len : strlen(name);
            memcpy(v->name, name, n);
            v->name_len = strlen(name);
        } else { v->name_len = strlen(name); }
        if (v->date && v->date_len > 0) {
            unsigned int n = v->date_len < strlen(date) ? v->date_len : strlen(date);
            memcpy(v->date, date, n);
            v->date_len = strlen(date);
        } else { v->date_len = strlen(date); }
        if (v->desc && v->desc_len > 0) {
            unsigned int n = v->desc_len < strlen(desc) ? v->desc_len : strlen(desc);
            memcpy(v->desc, desc, n);
            v->desc_len = strlen(desc);
        } else { v->desc_len = strlen(desc); }
        hooklog("  → smart DRM_VERSION: emgd 1.0.0 (date=%s, desc=%s)", date, desc);
        return 0;
    }
    /* DRM_IOCTL_GET_UNIQUE (nr=1, sz=8) */
    if (nr == 1 && sz == 8 && arg) {
        struct shim_drm_unique *u = (struct shim_drm_unique *)arg;
        const char *unique = "PCI:0000:00:02.0";
        if (u->unique && u->unique_len > 0) {
            unsigned int n = u->unique_len < strlen(unique) ? u->unique_len : strlen(unique);
            memcpy(u->unique, unique, n);
            u->unique_len = strlen(unique);
        } else { u->unique_len = strlen(unique); }
        hooklog("  → smart DRM_GET_UNIQUE: %s", unique);
        return 0;
    }
    /* DRM_IOCTL_GET_MAGIC (nr=2, sz=4) */
    if (nr == 2 && sz == 4 && arg) {
        struct shim_drm_auth *a = (struct shim_drm_auth *)arg;
        a->magic = 0x1234abcd;
        hooklog("  → smart DRM_GET_MAGIC: 0x%x", a->magic);
        return 0;
    }
    /* DRM_IOCTL_SET_VERSION (nr=7, sz=16): accept whatever client wants */
    if (nr == 7 && sz == 16) {
        hooklog("  → smart DRM_SET_VERSION: accepted");
        return 0;
    }
    /* DRM_IGD_GMM_ALLOC_REGION (nr=78=0x4e, sz=20):
     *   struct { int rtn; unsigned long offset; unsigned long size; ... }
     *   Preserve client's size, fake an offset (so mmap is meaningful). */
    if (nr == 78 && sz == 20 && arg) {
        int *rtn = (int *)arg;
        unsigned long *offset_p = (unsigned long *)((char *)arg + 4);
        unsigned long *size_p = (unsigned long *)((char *)arg + 8);
        *rtn = 0;
        *offset_p = 0x10000000;   /* fake GTT offset — anything non-zero */
        /* keep size as-is so the client can mmap it */
        hooklog("  → smart DRM_IGD_GMM_ALLOC_REGION: offset=0x%lx size=%lu",
                *offset_p, *size_p);
        return 0;
    }
    /* DRM_IGD_ALTER_OVL2 (nr=0x6f=111): 200-byte struct from sprite_c.c.
     * Contract extracted from q60nav_alter.c work:
     *   request[8..11]   uint32 surface_offset (GTT offset)
     *   request[12..15]  uint32 pitch (1600 for YUYV 800x480)
     *   request[16..19]  uint32 width
     *   request[20..23]  uint32 height
     *   request[40..43]  uint32 FourCC (IGD_PF_YUY2 = 0x32595559, NOT 0x59555932)
     *   request[56..59]  uint32 render_ops (0 = NORMAL)
     *   request[60..63]  uint32 alpha (0xFF = opaque; 0x00 = invisible)
     *   request[120..136] uint32[4] src_rect (x,y,w,h)
     *   request[136..152] uint32[4] dst_rect (x,y,w,h)
     *   request[152..155] uint32 plane (3 or 5 valid; 5=Sprite C, 3=primary overlay)
     *   request[196..199] int32  cmd (2 = CMD_ALTER_OVL2_OSD)
     * If alpha=0 OR FourCC byte-reversed, the call returns r=0 but produces
     * an invisible/garbage surface — silent failure. We log warnings. */
    if (nr == 111 && arg) {
        unsigned char *req_buf = (unsigned char *)arg;
        int *rtn = (int *)req_buf;
        unsigned int plane  = *(unsigned int *)(req_buf + 152);
        unsigned int fourcc = *(unsigned int *)(req_buf + 40);
        unsigned int alpha  = *(unsigned int *)(req_buf + 60);
        unsigned int pitch  = *(unsigned int *)(req_buf + 12);
        unsigned int width  = *(unsigned int *)(req_buf + 16);
        unsigned int height = *(unsigned int *)(req_buf + 20);
        int          cmd    = *(int *)(req_buf + 196);

        hooklog("  ALTER_OVL2 plane=%u fourcc=0x%08x alpha=0x%x pitch=%u %ux%u cmd=%d",
                plane, fourcc, alpha, pitch, width, height, cmd);
        if (plane != 3 && plane != 5) {
            hooklog("    ⚠ plane %u not in {3,5} — may EINVAL on real hw", plane);
        }
        if (fourcc == 0x59555932) {
            hooklog("    ⚠ FourCC=0x59555932 is BYTE-REVERSED YUY2; correct value is 0x32595559");
        } else if (fourcc != 0x32595559 && fourcc != 0x00041422) {
            hooklog("    ⚠ FourCC=0x%08x not YUY2(0x32595559) or RGB565(0x00041422)", fourcc);
        }
        if (alpha == 0) {
            hooklog("    ⚠ alpha=0 — surface will render fully transparent (invisible)");
        }
        *rtn = 0;
        hooklog("  → smart DRM_IGD_ALTER_OVL2: accepted (r=0)");
        return 0;
    }
    /* DRM_SET_MASTER (0x641e, _IO('d', 0x1e)): always r=0 — matches CLAUDE.md
     * ground truth ("DRM_SET_MASTER succeeds as root without killing factory") */
    if (nr == 0x1e) {
        hooklog("  → smart DRM_SET_MASTER: r=0 (matches factory behavior)");
        return 0;
    }
    if (nr == 0x1f) {
        hooklog("  → smart DRM_DROP_MASTER: r=0");
        return 0;
    }
    /* Default: zero the buffer for read-style ioctls, return 0 */
    if (arg && (((req >> 30) & 0x3) & 2) && sz > 0 && sz < 4096) {
        memset(arg, 0, sz);
    }
    return 0;
}

/* Factory V4L2 (type='V') contract — extracted from emgdhmid disasm + factory dmesg.
 *
 *   VIDIOC_S_FMT (nr=5, sz=204): fill bytesperline=1600, sizeimage=768000.
 *   VIDIOC_REQBUFS (nr=8, sz=20): return count=3.
 *   VIDIOC_QUERYBUF (nr=9, sz=68): per-index, return offset=index*0xe9000, length=0xc3000.
 *   IOH_VIDEO_GET_BUFFER_SIZE (nr=0xd5, sz=4): return 0xc3000.
 *   IOH_VIDEO_GET_FRAME_BUFFERS (nr=0xd8, sz=80): return 80-byte struct with 3 valid
 *     16-byte descriptors at offsets 0x00, 0x10, 0x20. Each descriptor matches what
 *     emgdhmid copies into the V2G_ENABLE struct: pitch at +0, sizeimage at +4,
 *     gtt_offset at +8, length at +12.
 */
static int handle_v4l2(int fd, unsigned long req, void *arg, unsigned int nr, unsigned int sz) {
    (void)fd; (void)req;
    if (nr == 5 && arg) {              /* VIDIOC_S_FMT */
        unsigned int *f = (unsigned int *)arg;
        /* fmt.pix.bytesperline = 1600, sizeimage = 768000 — populate the struct */
        f[5] = 1600; f[6] = 768000;
        hooklog("  → smart VIDIOC_S_FMT: pitch=1600 sizeimage=768000");
        return 0;
    }
    if (nr == 8 && arg) {              /* VIDIOC_REQBUFS */
        unsigned int *r = (unsigned int *)arg;
        if (r[0] == 0) { errno = EINVAL; return -1; }   /* count=0 invalid */
        r[0] = 3;
        hooklog("  → smart VIDIOC_REQBUFS: count=3");
        return 0;
    }
    if (nr == 9 && arg) {              /* VIDIOC_QUERYBUF */
        /* v4l2_buffer layout on i386: index@0, ..., sequence@44, memory@48,
         * m.offset@52, length@56. uint32 indices: index=[0], m.offset=[13],
         * length=[14].
         *
         * IMPORTANT: V4L2 QUERYBUF returns mmap-style offsets (used as the
         * 6th arg to mmap on /dev/video0). Factory v2gbridge research doc
         * shows mmap offsets are `idx * 0xc3000`, NOT idx * 0xe9000. Two
         * possible reasons:
         *   - QUERYBUF returns step=0xc3000 too (offsets are packed)
         *   - Step is 0xe9000 in GTT but mmap offsets are renumbered
         * We use 0xc3000 here to match the documented mmap example. If
         * hardware returns 0xe9000, our binary handles either because it
         * uses the QUERYBUF result verbatim. */
        unsigned int *b = (unsigned int *)arg;
        unsigned int idx = b[0];
        b[13] = idx * 0xc3000;
        b[14] = 0xc3000;
        hooklog("  → smart VIDIOC_QUERYBUF: idx=%u offset=0x%x length=0xc3000",
                idx, b[13]);
        return 0;
    }
    if (nr == 17 && arg) {             /* VIDIOC_DQBUF — factory uses in pipeline */
        hooklog("  → smart VIDIOC_DQBUF: accepted (no-op)");
        return 0;
    }
    if (nr == 19) {                    /* VIDIOC_STREAMOFF */
        hooklog("  → smart VIDIOC_STREAMOFF: accepted");
        return 0;
    }
    if (nr == 15 && arg) {             /* VIDIOC_QBUF */
        hooklog("  → smart VIDIOC_QBUF: accepted");
        return 0;
    }
    if (nr == 18 && arg) {             /* VIDIOC_STREAMON */
        hooklog("  → smart VIDIOC_STREAMON: type=%u accepted", *(unsigned int *)arg);
        return 0;
    }
    if (nr == 0xd5 && arg && sz == 4) { /* IOH_VIDEO_GET_BUFFER_SIZE */
        *(unsigned int *)arg = 0xc3000;
        hooklog("  → smart IOH_VIDEO_GET_BUFFER_SIZE: 0xc3000");
        return 0;
    }
    if (nr == 0xd8 && arg && sz == 80) { /* IOH_VIDEO_GET_FRAME_BUFFERS */
        /* 5 × 16-byte descriptors, first 3 valid. emgdhmid copies these to
         * V2G_ENABLE struct[0x40..0x90]. Layout per descriptor:
         *   +0  uint32 pitch    = 1600
         *   +4  uint32 size     = 768000
         *   +8  uint32 offset   = GTT offset (NOT V4L2 mmap offset)
         *   +12 uint32 length   = 0xc3000
         *
         * KEY DETAIL: GTT offsets here are DIFFERENT from V4L2 QUERYBUF mmap
         * offsets. Factory dmesg shows GTT step ~0x100000 (1 MB) per buffer
         * (paddr=0x36600000/0x36700000/0x36000000, offsets=0xf40000/0x1040000/
         * 0x1140000). The mmap-side step is 0xc3000. They're different
         * coordinate systems. Our shim returns offsets that match factory
         * dmesg GTT values to catch the case where our binary uses V4L2
         * QUERYBUF offsets instead of GET_FRAME_BUFFERS offsets. */
        unsigned int *d = (unsigned int *)arg;
        memset(d, 0, 80);
        unsigned int gtt_offsets[3] = { 0xf40000, 0x1040000, 0x1140000 };  /* from factory dmesg */
        for (int i = 0; i < 3; i++) {
            d[i*4 + 0] = 1600;
            d[i*4 + 1] = 768000;
            d[i*4 + 2] = gtt_offsets[i];
            d[i*4 + 3] = 0xc3000;
        }
        hooklog("  → smart IOH_VIDEO_GET_FRAME_BUFFERS: 3 buffers @ GTT 0xf40000/0x1040000/0x1140000");
        return 0;
    }
    if (arg && (((req >> 30) & 0x3) & 2) && sz > 0 && sz < 4096) memset(arg, 0, sz);
    hooklog("  → V4L2 default (zero+return 0)");
    return 0;
}

/* Factory v2gbridge (type='v') contract — this is the CRITICAL test.
 *
 *   V2G_ENABLE_BRIDGE (nr=0): the driver requires non-zero buffer descriptors at
 *     struct offset 0x40..0x90. If the caller's struct is the wrong shape (e.g.
 *     just {plane, screen} 8 bytes), the driver-side memory at 0x40+ is zero
 *     and the kernel reports "GTT mapping requested for 0 buffers" → EINVAL.
 *     This shim mimics that: walk struct[0x40..0x90] looking for any non-zero
 *     gtt_offset (offset+8 in each 16-byte descriptor). At least one required.
 *     Also screen field at 0x90 (uint16) must be non-zero.
 *
 *   V2G_DISABLE_BRIDGE (nr=1): always accept.
 *   V2G_DISPLAY_FRAME (nr=2): index 0/1/2 valid, else EINVAL. */
/* Track v2g state across ioctls in this shim instance */
static int v2g_enabled = 0;
static int v2g_enable_attempts = 0;

/* Track mmap'd V4L2 buffers so we can dump their pixels on V2G_DISPLAY_FRAME.
 * Each (ptr, length, fd) tuple stored when caller mmap's a fake fd. */
#define MMAP_TABLE_MAX 8
static struct { void *ptr; size_t len; int fd; unsigned int offset; } mmap_table[MMAP_TABLE_MAX];
static int mmap_table_n = 0;
static int frame_dump_count = 0;
static const char *FRAME_DUMP_DIR = "/build/frames";

/* YUYV → RGB (BT.601). dst must be 3*W*H bytes (RGB packed). */
static void yuyv_to_rgb(const unsigned char *yuyv, unsigned char *rgb, int w, int h) {
    for (int i = 0; i < w * h / 2; i++) {
        int y0 = yuyv[i*4 + 0], u = yuyv[i*4 + 1];
        int y1 = yuyv[i*4 + 2], v = yuyv[i*4 + 3];
        for (int p = 0; p < 2; p++) {
            int y = (p == 0) ? y0 : y1;
            int c = y - 16, d = u - 128, e = v - 128;
            int R = (298*c + 409*e + 128) >> 8;
            int G = (298*c - 100*d - 208*e + 128) >> 8;
            int B = (298*c + 516*d + 128) >> 8;
            if (R < 0) R = 0; if (R > 255) R = 255;
            if (G < 0) G = 0; if (G > 255) G = 255;
            if (B < 0) B = 0; if (B > 255) B = 255;
            rgb[(i*2 + p)*3 + 0] = (unsigned char)R;
            rgb[(i*2 + p)*3 + 1] = (unsigned char)G;
            rgb[(i*2 + p)*3 + 2] = (unsigned char)B;
        }
    }
}

/* Dump buffer N as PPM (RGB) so we can convert to PNG offline. */
static void dump_buffer_as_ppm(int idx, const void *buf) {
    if (!buf) { hooklog("    dump_buffer[%d]: NULL pointer", idx); return; }
    /* mkdir best-effort */
    char dir_cmd[128];
    snprintf(dir_cmd, sizeof(dir_cmd), "mkdir -p %s 2>/dev/null", FRAME_DUMP_DIR);
    system(dir_cmd);

    char path[128];
    snprintf(path, sizeof(path), "%s/frame_%03d_buf%d.ppm",
             FRAME_DUMP_DIR, frame_dump_count, idx);

    /* YUYV 800x480 → RGB */
    const int W = 800, H = 480;
    unsigned char *rgb = malloc(W * H * 3);
    if (!rgb) return;
    yuyv_to_rgb((const unsigned char *)buf, rgb, W, H);

    int fd = real_open ? real_open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644)
                       : open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) {
        char hdr[64];
        int n = snprintf(hdr, sizeof(hdr), "P6\n%d %d\n255\n", W, H);
        if (real_write) {
            real_write(fd, hdr, n);
            real_write(fd, rgb, W * H * 3);
        } else {
            write(fd, hdr, n);
            write(fd, rgb, W * H * 3);
        }
        close(fd);
        hooklog("    dump_buffer[%d] → %s (%dx%d RGB)", idx, path, W, H);
    }
    free(rgb);
    frame_dump_count++;
}

static int handle_v2g(int fd, unsigned long req, void *arg, unsigned int nr, unsigned int sz) {
    (void)fd; (void)req; (void)sz;
    if (nr == 0) {                      /* V2G_ENABLE_BRIDGE */
        v2g_enable_attempts++;
        if (!arg) { hooklog("  → V2G_ENABLE: NULL arg → EFAULT"); errno = EFAULT; return -1; }

        /* Inspect the struct: dump first 0x98 bytes so we see EVERYTHING the
         * caller passed. Then evaluate BOTH possible contracts and report
         * which one matches. We do NOT pick a winner — hardware will. */
        unsigned char *vge = (unsigned char *)arg;
        hooklog("  V2G_ENABLE first 8 bytes (minimal {plane,screen} hypothesis):");
        hooklog("    plane=0x%08x screen=0x%08x",
                *(unsigned int *)(vge + 0),
                *(unsigned int *)(vge + 4));

        int valid_buffers = 0;
        for (int i = 0; i < 5; i++) {
            unsigned int pitch   = *(unsigned int *)(vge + 0x40 + i*16 + 0);
            unsigned int size    = *(unsigned int *)(vge + 0x40 + i*16 + 4);
            unsigned int gtt_off = *(unsigned int *)(vge + 0x40 + i*16 + 8);
            unsigned int len     = *(unsigned int *)(vge + 0x40 + i*16 + 12);
            if (len > 0) valid_buffers++;
            if (pitch || size || gtt_off || len) {
                hooklog("  V2G_ENABLE struct[0x%x]: pitch=%u size=%u gtt_offset=0x%x length=0x%x",
                        0x40 + i*16, pitch, size, gtt_off, len);
            }
        }
        unsigned short screen = *(unsigned short *)(vge + 0x90);
        unsigned short plane  = *(unsigned short *)(vge + 0x92);
        hooklog("  V2G_ENABLE +0x90: screen=%u plane=%u  (factory disasm: both=1)", screen, plane);
        hooklog("  V2G_ENABLE summary: attempt=%d valid_buffers=%d (offset-0x40 hypothesis)",
                v2g_enable_attempts, valid_buffers);

        /* If camera_ps already opened v2gbridge, second ENABLE may EBUSY.
         * We simulate this on attempt #2 to test our retry path. */
        if (v2g_enabled && v2g_enable_attempts > 1) {
            hooklog("  → V2G_ENABLE FAIL: bridge already enabled (camera_ps owns it) → EBUSY");
            errno = EBUSY; return -1;
        }

        /* Accept BOTH valid shapes — log which one the caller used: */
        if (valid_buffers >= 3 && (screen == 1 && plane == 1)) {
            hooklog("  → V2G_ENABLE SUCCESS: full struct (descriptors @0x40 + screen/plane @0x90) ✓");
            v2g_enabled = 1; return 0;
        }
        if (valid_buffers == 0 && *(unsigned int *)(vge + 0) == 1 && *(unsigned int *)(vge + 4) == 1) {
            hooklog("  → V2G_ENABLE SUCCESS: minimal 8-byte struct ({plane=1, screen=1}) — driver may pull V4L2 state internally");
            v2g_enabled = 1; return 0;
        }
        hooklog("  → V2G_ENABLE FAIL: struct matches NEITHER known shape → EINVAL");
        errno = EINVAL; return -1;
    }
    if (nr == 1) {                      /* V2G_DISABLE_BRIDGE */
        v2g_enabled = 0;
        hooklog("  → V2G_DISABLE: accepted");
        return 0;
    }
    if (nr == 2 && arg) {               /* V2G_DISPLAY_FRAME */
        unsigned int idx = *(unsigned int *)arg;
        if (idx > 2) { hooklog("  → V2G_DISPLAY_FRAME idx=%u → EINVAL", idx); errno = EINVAL; return -1; }
        if (!v2g_enabled) {
            hooklog("  → V2G_DISPLAY_FRAME idx=%u FAIL: bridge not enabled → EINVAL", idx);
            errno = EINVAL; return -1;
        }
        hooklog("  → V2G_DISPLAY_FRAME idx=%u accepted (bridge live)", idx);
        /* Capture the painted pixels for that buffer. Dump every ~10th frame
         * so we get a stream we can render later. */
        if (frame_dump_count < 12 && idx < (unsigned)mmap_table_n) {
            dump_buffer_as_ppm((int)idx, mmap_table[idx].ptr);
        }
        return 0;
    }
    hooklog("  → v2g default (zero+return 0)");
    return 0;
}

int ioctl(int fd, int req, ...) {
    init_real_syms();
    void *arg;
    va_list ap; va_start(ap, req);
    arg = va_arg(ap, void *);
    va_end(ap);

    if (is_fake_fd(fd)) {
        unsigned int dir = (req >> 30) & 0x3;
        unsigned int sz  = (req >> 16) & 0x3fff;
        unsigned int type = (req >> 8) & 0xff;
        unsigned int nr   = req & 0xff;
        const char *fp = fake_path_for(fd);
        hooklog("ioctl(fd=%d /* %s */, req=0x%08lx [dir=%u sz=%u type='%c' nr=%u], arg=%p)",
                fd, fp, (unsigned long)req, dir, sz,
                (type >= 32 && type < 127) ? (char)type : '?',
                nr, arg);

        /* Smart handlers per device type */
        if (type == 'd') return handle_drm(fd, req, arg, nr, sz);   /* DRM */
        if (type == 'V') return handle_v4l2(fd, req, arg, nr, sz);  /* V4L2 + IOH ext */
        if (type == 'v') return handle_v2g(fd, req, arg, nr, sz);   /* v2gbridge */

        /* default: zero + return 0 */
        if (arg && (dir & 2) && sz > 0 && sz < 4096) memset(arg, 0, sz);
        return 0;
    }
    return real_ioctl(fd, req, arg);
}

ssize_t read(int fd, void *buf, size_t count) {
    init_real_syms();
    if (is_fake_fd(fd)) {
        hooklog("read(fd=%d /* %s */, buf=%p, n=%zu) → 0 (EOF-like)",
                fd, fake_path_for(fd), buf, count);
        if (buf && count) memset(buf, 0, count > 4096 ? 4096 : count);
        return 0;
    }
    return real_read(fd, buf, count);
}

ssize_t write(int fd, const void *buf, size_t count) {
    init_real_syms();
    if (is_fake_fd(fd)) {
        hooklog("write(fd=%d /* %s */, buf=%p, n=%zu) → %zu (swallowed)",
                fd, fake_path_for(fd), buf, count);
        return count;
    }
    return real_write(fd, buf, count);
}

off_t lseek(int fd, off_t off, int whence) {
    init_real_syms();
    if (is_fake_fd(fd)) {
        hooklog("lseek(fd=%d /* %s */, %ld, %d) → 0",
                fd, fake_path_for(fd), (long)off, whence);
        return 0;
    }
    return real_lseek(fd, off, whence);
}

void *mmap(void *addr, size_t length, int prot, int flags, int fd, off_t offset) {
    init_real_syms();
    if (is_fake_fd(fd)) {
        /* Replace with anonymous mapping so the caller gets writable memory */
        hooklog("mmap(addr=%p, len=%zu, prot=0x%x, flags=0x%x, fd=%d /* %s */, off=%ld) → anon",
                addr, length, prot, flags, fd, fake_path_for(fd), (long)offset);
        void *r = real_mmap(NULL, length, prot, MAP_ANONYMOUS | MAP_PRIVATE, -1, 0);
        /* Remember (ptr, len, fd, offset) so V2G_DISPLAY_FRAME can dump pixels.
         * Buffers are tracked in mmap order — index 0 = first mmap = V4L2 buf[0]. */
        if (r && r != MAP_FAILED && mmap_table_n < MMAP_TABLE_MAX) {
            mmap_table[mmap_table_n].ptr = r;
            mmap_table[mmap_table_n].len = length;
            mmap_table[mmap_table_n].fd = fd;
            mmap_table[mmap_table_n].offset = (unsigned int)offset;
            hooklog("  tracked mmap_table[%d] = %p (len=%zu)", mmap_table_n, r, length);
            mmap_table_n++;
        }
        return r;
    }
    return real_mmap(addr, length, prot, flags, fd, offset);
}
