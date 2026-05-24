/*
 * q60nav_r1_probe.c — Diagnostic probe for R1 hardware capabilities.
 *
 * Runs an array of small experiments in one boot, logging which APIs are
 * accessible and what errors they return. The result tells us which buffer
 * allocator + ALTER_OVL2 variant to use without burning multiple boot cycles
 * for each guess.
 *
 * Probes (in order):
 *   1. /dev/dri/card0 open
 *   2. DRM_VERSION → confirm we talk to a real EMGD kernel module
 *   3. DRM_GET_UNIQUE
 *   4. DRM_GET_MAGIC
 *   5. DRM_IGD_GMM_ALLOC_REGION (DRM_MASTER required — expect EACCES if non-master)
 *   6. /dev/v2gbridge open + ioctls (enable, disable)
 *   7. /dev/video0 open + VIDIOC_QUERYCAP (camera path alternative)
 *   8. V4L2 REQBUFS attempt (alternative buffer alloc)
 *   9. PVRSRV-related path probes (/dev/pvr*, /proc/pvr/version)
 *
 * Output: /boot/Q60_R1_PROBE.LOG (FAT32, easy to read off card)
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <errno.h>
#include <time.h>
#include <dirent.h>

#define PRIMARY_LOG  "/boot/Q60_R1_PROBE.LOG"
#define FALLBACK_LOG "/tmp/Q60_R1_PROBE.LOG"

static FILE *logf;
#define LOG(fmt, ...) do { \
    if (logf) { fprintf(logf, fmt "\n", ##__VA_ARGS__); fflush(logf); } \
    fprintf(stderr, fmt "\n", ##__VA_ARGS__); \
} while (0)

static FILE *open_log(void) {
    FILE *f = fopen(PRIMARY_LOG, "w");
    if (f) return f;
    return fopen(FALLBACK_LOG, "w");
}

/* DRM ioctl ABI helpers */
struct drm_version {
    int major, minor, patchlevel;
    unsigned int name_len; char *name;
    unsigned int date_len; char *date;
    unsigned int desc_len; char *desc;
};
struct drm_unique  { unsigned int len; char *unique; };
struct drm_auth    { unsigned int magic; };

#define DRM_VERSION_IOCTL    0xc0246400  /* _IOWR('d', 0, sizeof(struct drm_version))=36 */
#define DRM_GET_UNIQUE_IOCTL 0xc0086401  /* _IOWR('d', 1, sizeof(struct drm_unique))=8 */
#define DRM_GET_MAGIC_IOCTL  0x80046402  /* _IOR('d', 2, struct drm_auth)=4 */

#define IGD_GMM_ALLOC_REGION_IOCTL 0xc014644e  /* _IOWR('d', 0x4e, 20) */
#define IGD_ALTER_OVL2_IOCTL       0xc0c8646f  /* _IOWR('d', 0x6f, 200) */

#define V2G_ENABLE_BRIDGE   0xc0047600
#define V2G_DISABLE_BRIDGE  0xc0047601

#define VIDIOC_QUERYCAP     0x80685600  /* _IOR('V', 0, struct v4l2_capability)=104 */
#define VIDIOC_REQBUFS      0xc0145608  /* _IOWR('V', 8, 20) */

struct igd_gmm_alloc {
    int rtn;
    unsigned long offset;
    unsigned long size;
    unsigned int type;
    unsigned long flags;
};

static const char *ok_or_errno(int r) {
    static char buf[128];
    if (r >= 0) { snprintf(buf, sizeof(buf), "OK (r=%d)", r); }
    else { snprintf(buf, sizeof(buf), "FAIL r=%d errno=%d (%s)", r, errno, strerror(errno)); }
    return buf;
}

int main(int argc, char **argv) {
    logf = open_log();
    if (logf) setvbuf(logf, NULL, _IOLBF, 0);

    time_t t = time(NULL);
    LOG("=== Q60 R1 Hardware Capability Probe — %s", ctime(&t));
    LOG("uid=%d euid=%d gid=%d", (int)getuid(), (int)geteuid(), (int)getgid());

    /* === 1. /dev/dri/card0 === */
    LOG("--- /dev/dri/card0 ---");
    int drm = open("/dev/dri/card0", O_RDWR);
    LOG("open /dev/dri/card0: %s fd=%d", ok_or_errno(drm), drm);
    if (drm < 0) goto skip_drm;

    /* DRM_VERSION (probe driver identity) */
    struct drm_version ver = {0};
    char name_buf[64] = {0}, date_buf[64] = {0}, desc_buf[128] = {0};
    /* First call: query lengths */
    int r = ioctl(drm, DRM_VERSION_IOCTL, &ver);
    LOG("DRM_VERSION (query lens): %s", ok_or_errno(r));
    if (r == 0) {
        LOG("  driver: major=%d minor=%d patchlevel=%d (name_len=%u date_len=%u desc_len=%u)",
            ver.major, ver.minor, ver.patchlevel, ver.name_len, ver.date_len, ver.desc_len);
        ver.name = name_buf; if (ver.name_len > 63) ver.name_len = 63;
        ver.date = date_buf; if (ver.date_len > 63) ver.date_len = 63;
        ver.desc = desc_buf; if (ver.desc_len > 127) ver.desc_len = 127;
        r = ioctl(drm, DRM_VERSION_IOCTL, &ver);
        LOG("DRM_VERSION (fetch): %s — name='%.64s' date='%.64s' desc='%.128s'",
            ok_or_errno(r), name_buf, date_buf, desc_buf);
    }

    /* DRM_GET_UNIQUE */
    struct drm_unique uniq = {0};
    char unique_buf[128] = {0};
    r = ioctl(drm, DRM_GET_UNIQUE_IOCTL, &uniq);
    if (r == 0 && uniq.len > 0 && uniq.len < 127) {
        uniq.unique = unique_buf;
        r = ioctl(drm, DRM_GET_UNIQUE_IOCTL, &uniq);
        LOG("DRM_GET_UNIQUE: %s — unique='%.128s'", ok_or_errno(r), unique_buf);
    } else {
        LOG("DRM_GET_UNIQUE (query len): %s — len=%u", ok_or_errno(r), uniq.len);
    }

    /* DRM_GET_MAGIC */
    struct drm_auth auth = {0};
    r = ioctl(drm, DRM_GET_MAGIC_IOCTL, &auth);
    LOG("DRM_GET_MAGIC: %s — magic=0x%x", ok_or_errno(r), auth.magic);

    /* DRM_IGD_GMM_ALLOC_REGION — THE master-blocked probe */
    struct igd_gmm_alloc alloc = { .size = 800*480*4, .type = 0, .flags = 0 };
    r = ioctl(drm, IGD_GMM_ALLOC_REGION_IOCTL, &alloc);
    LOG("DRM_IGD_GMM_ALLOC_REGION: %s — offset=0x%lx size=%lu rtn=%d",
        ok_or_errno(r), alloc.offset, alloc.size, alloc.rtn);
    /* If success: try mmap + ALTER_OVL2 + V2G enable */
    if (r == 0 && alloc.offset != 0) {
        LOG("  GMM succeeded, attempting full alter/enable cycle...");
        void *mapped = mmap(NULL, alloc.size, PROT_READ|PROT_WRITE, MAP_SHARED, drm, alloc.offset);
        LOG("  mmap: %s addr=%p", mapped == MAP_FAILED ? "FAIL" : "OK", mapped);
        if (mapped != MAP_FAILED) {
            memset(mapped, 0xFF, alloc.size); /* white */
            LOG("  buffer filled (white)");
            /* TODO: ALTER_OVL2 + V2G_ENABLE */
            munmap(mapped, alloc.size);
        }
    }

skip_drm:
    /* === 2. /dev/v2gbridge === */
    LOG("--- /dev/v2gbridge ---");
    int v2g = open("/dev/v2gbridge", O_RDWR);
    LOG("open /dev/v2gbridge: %s fd=%d", ok_or_errno(v2g), v2g);
    if (v2g >= 0) {
        int en = 1;
        r = ioctl(v2g, V2G_ENABLE_BRIDGE, &en);
        LOG("V2G_ENABLE_BRIDGE arg=1: %s (out=%d) — 5 sec observe", ok_or_errno(r), en);
        sleep(5);
        int dis = 0;
        r = ioctl(v2g, V2G_DISABLE_BRIDGE, &dis);
        LOG("V2G_DISABLE_BRIDGE arg=0: %s", ok_or_errno(r));
    }

    /* === 3. /dev/video0 — V4L2 camera path (alternative buffer alloc) === */
    LOG("--- /dev/video0 (V4L2) ---");
    int vid = open("/dev/video0", O_RDWR);
    LOG("open /dev/video0: %s fd=%d", ok_or_errno(vid), vid);
    if (vid >= 0) {
        unsigned char cap[104] = {0};
        r = ioctl(vid, VIDIOC_QUERYCAP, cap);
        LOG("VIDIOC_QUERYCAP: %s — driver='%.16s' card='%.32s'",
            ok_or_errno(r), &cap[0], &cap[16]);
    }

    /* === 4. PVRSRV paths === */
    LOG("--- PVRSRV inventory ---");
    const char *pvr_paths[] = {
        "/dev/pvrsrvkm", "/dev/pvrsrv", "/dev/pvr",
        "/proc/pvr/version", "/proc/pvr/queue", NULL
    };
    for (int i = 0; pvr_paths[i]; i++) {
        struct stat st;
        if (stat(pvr_paths[i], &st) == 0) {
            LOG("  %s EXISTS (mode=0%o size=%lld)", pvr_paths[i],
                (unsigned)st.st_mode, (long long)st.st_size);
        } else {
            LOG("  %s ABSENT (errno=%d)", pvr_paths[i], errno);
        }
    }

    /* === 5. /dev contents — what's actually here? === */
    LOG("--- /dev listing (devices we might want) ---");
    DIR *d = opendir("/dev");
    if (d) {
        struct dirent *e;
        while ((e = readdir(d))) {
            if (strstr(e->d_name, "pvr") || strstr(e->d_name, "dri") ||
                strstr(e->d_name, "video") || strstr(e->d_name, "v2g") ||
                strstr(e->d_name, "fb") || strstr(e->d_name, "i2c") ||
                strstr(e->d_name, "ioh")) {
                struct stat st;
                char path[128];
                snprintf(path, sizeof(path), "/dev/%s", e->d_name);
                if (stat(path, &st) == 0) {
                    LOG("  /dev/%s (mode=0%o major=%u minor=%u)",
                        e->d_name, (unsigned)st.st_mode,
                        (unsigned)((st.st_rdev >> 8) & 0xff),
                        (unsigned)(st.st_rdev & 0xff));
                }
            }
        }
        closedir(d);
    }

    /* === 6. /sys/class/drm — what does the kernel see? === */
    LOG("--- /sys/class/drm ---");
    d = opendir("/sys/class/drm");
    if (d) {
        struct dirent *e;
        while ((e = readdir(d))) {
            if (e->d_name[0] != '.') LOG("  %s", e->d_name);
        }
        closedir(d);
    } else {
        LOG("  /sys/class/drm: errno=%d (%s)", errno, strerror(errno));
    }

    /* Cleanup */
    if (vid >= 0) close(vid);
    if (v2g >= 0) close(v2g);
    if (drm >= 0) close(drm);

    LOG("=== Probe done ===");
    if (logf) fclose(logf);
    return 0;
}
