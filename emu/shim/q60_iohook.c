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
static int (*real_ioctl)(int, unsigned long, ...) = NULL;
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
    /* Default: zero the buffer for read-style ioctls, return 0 */
    if (arg && (((req >> 30) & 0x3) & 2) && sz > 0 && sz < 4096) {
        memset(arg, 0, sz);
    }
    return 0;
}

int ioctl(int fd, unsigned long req, ...) {
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
        if (type == 'd') {
            /* /dev/dri/card0 — standard DRM ioctls */
            return handle_drm(fd, req, arg, nr, sz);
        }

        /* v2gbridge (type='v'), V4L2 (type='V'), and default: zero + return 0 */
        if (arg && (dir & 2) && sz > 0 && sz < 4096) {
            memset(arg, 0, sz);
        }
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
        return r;
    }
    return real_mmap(addr, length, prot, flags, fd, offset);
}
