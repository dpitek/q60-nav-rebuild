/*
 * q60nav_alter.c — R1 overlay paint via DRM_IGD_ALTER_OVL2.
 *
 * Strategy:
 *   1. SIGSTOP 4 UI daemons (navi_ps, dispapf, display_p, hmictrl) —
 *      proven safe by disable probe (May 17). Factory recovers on SIGCONT.
 *   2. DRM_SET_MASTER on /dev/dri/card0 — proven succeeds as root after SIGSTOP.
 *   3. DRM_IGD_GMM_ALLOC_REGION (ioctl 0x4e) to get a GTT-mapped surface.
 *      Use 800x480x4 = 1,536,000 bytes for ARGB32 (clearer than YUYV).
 *   4. mmap the surface.
 *   5. Paint ARGB8888 test pattern: R/G/B/W quadrants + yellow center band.
 *   6. DRM_IOCTL_IGD_ALTER_OVL2 (ioctl 0x6f), 200-byte struct from
 *      sprite_c.c, pointing Sprite C plane at our GTT surface, pixfmt=ARGB32.
 *   7. Sleep 15s for visibility.
 *   8. ALTER_OVL2 disable + SIGCONT.
 *
 * NO v2gbridge access. That's what triggered factory's defense in prior tests.
 * Pure DRM-master + ALTER_OVL2 path that the May 17 disable probe proved
 * succeeds at the ioctl layer. Today's question: does it produce visible
 * pixels when we use the right pixfmt and SIGSTOP the UI daemons?
 *
 * Compile: docker run --rm --platform linux/386 -v ...:/build alpine
 *          gcc -static -no-pie -O2 -Wall -o q60nav_alter q60nav_alter.c
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
#include <sys/types.h>
#include <sys/wait.h>
#include <signal.h>
#include <dirent.h>
#include <errno.h>
#include <time.h>

#define DRM_SET_MASTER          0x0000641eu  /* _IO('d', 0x1e) */
#define DRM_DROP_MASTER         0x0000641fu  /* _IO('d', 0x1f) */
#define DRM_IGD_GMM_ALLOC_NR    0x4e
#define DRM_IGD_ALTER_OVL2_NR   0x6f

/* PROVEN params from May 17 disable probe: type=1 + size=768000 succeeded.
 * type=0 + size=1536000 (ARGB32) returns rtn=-2. Driver only allocates 16bpp. */
/* FourCC byte order: chars stored in memory as [Y,U,Y,2] → little-endian u32 = 0x32595559.
 * BUG: prior tests used 0x59555932 which is memory [2,Y,U,Y] = garbage FourCC; driver
 * fell back to default format (likely UYVY) and decoded our YUYV red as green.
 * This is consistent with Doug's "greenish tint" observation. */
#define IGD_PF_YUY2             0x32595559UL  /* "YUY2" FourCC (corrected) */
#define IGD_PF_RGB565           0x00041422UL  /* fallback if YUY2 rejected */

#define W 800
#define H 480
#define BPP 2                                  /* YUYV (2 bytes per pixel) */
#define BUF_SIZE (W * H * BPP)                 /* 768,000 bytes — matches disable probe */
#define PITCH (W * BPP)                         /* 1600 bytes/row */

#define BOOT_LOG "/boot/Q60_ALTER.LOG"
#define TRACE_PATH "/tmp/Q60_ALTER_TRACE.LOG"

static FILE *flog;
#define LOG(...) do { fprintf(flog, __VA_ARGS__); fflush(flog); fsync(fileno(flog)); } while (0)

struct gmm_alloc_region {
    int rtn;
    unsigned long offset;
    unsigned long size;
    unsigned int type;
    unsigned long flags;
};

static int suspended[16] = {0};
static int n_suspended = 0;

static void resume_all(void) {
    for (int i = n_suspended - 1; i >= 0; i--) {
        if (suspended[i] > 0) {
            kill(suspended[i], SIGCONT);
            LOG("  SIGCONT pid=%d\n", suspended[i]);
            suspended[i] = 0;
        }
    }
    n_suspended = 0;
}

static void emergency(int sig) {
    LOG("\n[!!] signal %d — resuming\n", sig);
    resume_all();
    _exit(1);
}

static int find_pid(const char *needle) {
    DIR *d = opendir("/proc"); if (!d) return 0;
    struct dirent *e;
    while ((e = readdir(d))) {
        if (e->d_name[0] < '1' || e->d_name[0] > '9') continue;
        int pid = atoi(e->d_name);
        char path[64]; snprintf(path, sizeof(path), "/proc/%d/comm", pid);
        FILE *f = fopen(path, "r"); if (!f) continue;
        char comm[32]; if (fgets(comm, sizeof(comm), f)) {
            int l = strlen(comm); while (l>0 && (comm[l-1]=='\n')) comm[--l] = 0;
            if (strstr(comm, needle)) { fclose(f); closedir(d); return pid; }
        }
        fclose(f);
    }
    closedir(d); return 0;
}

static int wait_for_factory_ui(void) {
    for (int sec = 0; sec < 30; sec++) {
        if (find_pid("navi_ps") && find_pid("hmictrl")) {
            LOG("[wait] factory UI up at sec=%d\n", sec);
            return 0;
        }
        sleep(1);
    }
    LOG("[wait] timed out (factory UI not detected)\n");
    return -1;
}

/* YUYV encoder — must use int (not unsigned) for r,g,b — see q60nav_paint.c
 * comment about magenta bug. */
static void rgb_to_yuyv(int r, int g, int b, unsigned char out[4]) {
    int y = ((66*r + 129*g + 25*b + 128) >> 8) + 16;
    int u = ((-38*r - 74*g + 112*b + 128) >> 8) + 128;
    int v = ((112*r - 94*g - 18*b + 128) >> 8) + 128;
    if (y < 0) y = 0; if (y > 255) y = 255;
    if (u < 0) u = 0; if (u > 255) u = 255;
    if (v < 0) v = 0; if (v > 255) v = 255;
    out[0]=y; out[1]=u; out[2]=y; out[3]=v;
}

/* Paint YUYV 4-quadrant test pattern + yellow center band */
static void paint_yuyv_pattern(unsigned char *buf) {
    unsigned char y_r[4], y_g[4], y_b[4], y_w[4], y_y[4], y_k[4];
    rgb_to_yuyv(255, 0, 0, y_r);
    rgb_to_yuyv(0, 255, 0, y_g);
    rgb_to_yuyv(0, 0, 255, y_b);
    rgb_to_yuyv(255, 255, 255, y_w);
    rgb_to_yuyv(255, 230, 0, y_y);
    rgb_to_yuyv(0, 0, 0, y_k);
    int half_w = W/2, half_h = H/2;
    for (int y = 0; y < H; y++) {
        unsigned char *row = buf + y * PITCH;
        const unsigned char *src;
        if (y < half_h) {
            for (int x = 0; x < W; x += 2) {
                src = (x < half_w) ? y_r : y_g;
                memcpy(row + x*2, src, 4);
            }
        } else {
            for (int x = 0; x < W; x += 2) {
                src = (x < half_w) ? y_b : y_w;
                memcpy(row + x*2, src, 4);
            }
        }
    }
    /* center yellow band w/ black border */
    int cx0 = (W - 200) / 2, cy0 = (H - 100) / 2;
    for (int y = cy0; y < cy0 + 100; y++) {
        unsigned char *row = buf + y * PITCH;
        for (int x = cx0; x < cx0 + 200; x += 2) memcpy(row + x*2, y_y, 4);
    }
    for (int x = cx0; x < cx0 + 200; x += 2) {
        memcpy(buf + cy0*PITCH + x*2, y_k, 4);
        memcpy(buf + (cy0+99)*PITCH + x*2, y_k, 4);
    }
    for (int y = cy0; y < cy0 + 100; y++) {
        memcpy(buf + y*PITCH + cx0*2, y_k, 4);
        memcpy(buf + y*PITCH + (cx0+198)*2, y_k, 4);
    }
}

int main(int argc, char **argv) {
    /* Daemonize: fork → parent exit → setsid → fork → grandchild orphaned to init */
    if (fork() > 0) return 0;
    if (setsid() < 0) return 98;
    if (fork() > 0) return 0;

    mkdir("/boot", 0755);
    flog = fopen(BOOT_LOG, "w");
    if (!flog) flog = fopen(TRACE_PATH, "w");
    if (!flog) flog = stderr;
    setvbuf(flog, NULL, _IOLBF, 0);

    /* Signal handlers — make sure we SIGCONT on any abnormal exit */
    struct sigaction sa = {0};
    sa.sa_handler = emergency;
    sigaction(SIGTERM, &sa, NULL); sigaction(SIGINT, &sa, NULL);
    sigaction(SIGSEGV, &sa, NULL); sigaction(SIGABRT, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);  sigaction(SIGFPE, &sa, NULL);
    sigaction(SIGHUP, &sa, NULL);  sigaction(SIGALRM, &sa, NULL);
    alarm(60);  /* hard kill after 60s — fail-safe */

    LOG("=== Q60 ALTER OVL2 PAINT — pid=%d ppid=%d sid=%d t=%ld ===\n",
        getpid(), getppid(), getsid(0), (long)time(NULL));

    /* Wait for factory UI to settle */
    wait_for_factory_ui();
    LOG("\n");

    /* PHASE 0: PROBES (the diagnostics we've been blind to). */
    LOG("[phase0] PROBES\n");
    /* /proc/iomem for PCI BAR mapping (needed for MMIO fallback path) */
    FILE *iom = fopen("/proc/iomem", "r");
    if (iom) {
        char line[256]; int n = 0;
        while (fgets(line, sizeof(line), iom) && n < 30) {
            if (strstr(line, "emgd") || strstr(line, "0000:00:02") ||
                strstr(line, "drm") || strstr(line, "Intel") || strstr(line, "PCI")) {
                LOG("  iomem: %s", line);
                n++;
            }
        }
        fclose(iom);
    } else LOG("  /proc/iomem: open failed errno=%d\n", errno);

    /* /sys/class/drm */
    DIR *d = opendir("/sys/class/drm");
    if (d) {
        struct dirent *e;
        LOG("  /sys/class/drm:");
        while ((e = readdir(d))) if (e->d_name[0] != '.') LOG(" %s", e->d_name);
        LOG("\n");
        closedir(d);
    }

    /* Find emgdhmid pid + dump its open FDs */
    int hmid_pid = find_pid("emgdhmi");
    LOG("  emgdhmid pid=%d\n", hmid_pid);

    /* kmsg snapshot BEFORE our work */
    LOG("\n  kmsg BEFORE (last v2g/emgd/drm lines):\n");
    int kfd_pre = open("/dev/kmsg", O_RDONLY | O_NONBLOCK);
    if (kfd_pre >= 0) {
        char kb[4096]; int kcap = 0;
        for (int i = 0; i < 200 && kcap < 2000; i++) {
            int n = read(kfd_pre, kb, sizeof(kb)-1);
            if (n <= 0) break;
            kb[n] = 0;
            char *l = kb;
            while (l && *l) {
                char *nx = strchr(l, '\n');
                if (nx) *nx++ = 0;
                if (strstr(l, "v2g") || strstr(l, "emgd") || strstr(l, "EMGD") ||
                    strstr(l, "OVL") || strstr(l, "GMM") || strstr(l, "Sprite")) {
                    LOG("  pre: %s\n", l);
                    kcap += strlen(l);
                }
                l = nx;
            }
        }
        close(kfd_pre);
    }
    LOG("\n");

    /* Phase 1: NO SIGSTOPs. Last test proved factory watchdog kills both us
     * AND breaks factory boot when daemons are held for 15s. The CLAUDE.md
     * ground truth says DRM_SET_MASTER succeeds as root WITHOUT killing
     * factory processes. Test that here — paint Sprite C on top of running
     * factory, the original R1 plan. */
    LOG("[phase1] SKIPPED — no SIGSTOPs (avoid factory watchdog disrupt)\n");

    /* Phase 2: open DRM + master */
    LOG("\n[phase2] DRM_SET_MASTER\n");
    int drm = open("/dev/dri/card0", O_RDWR);
    if (drm < 0) { LOG("  open card0 failed errno=%d\n", errno); resume_all(); return 1; }
    LOG("  open card0 = %d\n", drm);
    int r = ioctl(drm, DRM_SET_MASTER, 0);
    LOG("  DRM_SET_MASTER r=%d errno=%d\n", r, errno);

    /* Phase 3: GMM alloc — proven params from May 17 disable probe */
    LOG("\n[phase3] GMM_ALLOC_REGION 800x480 YUYV/16bpp (%d bytes) type=1\n", BUF_SIZE);
    struct gmm_alloc_region req = {0};
    req.size = BUF_SIZE;     /* 768000 — what disable probe used */
    req.type = 1;            /* what disable probe used */
    req.flags = 0;
    unsigned long ioctl_alloc = (3u << 30) | (((unsigned long)sizeof(req)) << 16)
                              | ('d' << 8) | DRM_IGD_GMM_ALLOC_NR;
    r = ioctl(drm, ioctl_alloc, &req);
    LOG("  GMM_ALLOC r=%d rtn=%d errno=%d offset=0x%lx size=%lu\n",
        r, req.rtn, errno, req.offset, req.size);
    if (r < 0 || req.rtn != 0) {
        LOG("  GMM_ALLOC failed — abort\n");
        close(drm); resume_all(); return 2;
    }

    /* Phase 4: mmap */
    LOG("\n[phase4] mmap offset=0x%lx size=%lu\n", req.offset, req.size);
    void *m = mmap(NULL, req.size, PROT_READ|PROT_WRITE, MAP_SHARED, drm, req.offset);
    if (m == MAP_FAILED) {
        LOG("  mmap FAILED errno=%d\n", errno);
        close(drm); resume_all(); return 3;
    }
    LOG("  mmap OK at %p\n", m);

    /* Phase 5: paint YUYV (using corrected encoder; magenta bug is dead) */
    LOG("\n[phase5] paint YUYV pattern\n");
    paint_yuyv_pattern((unsigned char *)m);
    msync(m, req.size, MS_SYNC);
    LOG("  painted (sample bytes at (0,0)=%02x%02x%02x%02x)\n",
        ((unsigned char*)m)[0], ((unsigned char*)m)[1],
        ((unsigned char*)m)[2], ((unsigned char*)m)[3]);

    /* Phase 6: ALTER_OVL2 — 200-byte struct, exact layout from sprite_c.c */
    LOG("\n[phase6] ALTER_OVL2 plane=5 (Sprite C)\n");
    unsigned char request[200] = {0};
    int *rtn_p = (int *)&request[0];
    *(unsigned long *)&request[8]   = req.offset;
    *(unsigned int  *)&request[12]  = PITCH;
    *(unsigned int  *)&request[16]  = W;
    *(unsigned int  *)&request[20]  = H;
    *(unsigned long *)&request[40]  = IGD_PF_YUY2;  /* match GMM type=1 buffer */
    /* src_rect at offset 120 */
    *(unsigned int *)&request[120]  = 0;
    *(unsigned int *)&request[124]  = 0;
    *(unsigned int *)&request[128]  = W;
    *(unsigned int *)&request[132]  = H;
    /* dst_rect at offset 136 */
    *(unsigned int *)&request[136]  = 0;
    *(unsigned int *)&request[140]  = 0;
    *(unsigned int *)&request[144]  = W;
    *(unsigned int *)&request[148]  = H;
    /* CRITICAL fields previously left at 0 — likely the reason no pixels appeared:
     *   off 60: src_surf.alpha     — if 0, surface is treated as fully transparent
     *   off 56: src_surf.render_ops — controls blending behavior
     * Default of 0 explains every prior "ioctl r=0 but invisible result". */
    *(unsigned int *)&request[60] = 0xFF;       /* alpha: fully opaque */
    *(unsigned int *)&request[56] = 0;          /* render_ops: NORMAL */
    *(unsigned long *)&request[192] = 0;        /* top-level flags */
    *(int *)&request[196] = 2;                  /* cmd: CMD_ALTER_OVL2_OSD */

    unsigned long ioctl_alter = (3u << 30) | (((unsigned long)sizeof(request)) << 16)
                              | ('d' << 8) | DRM_IGD_ALTER_OVL2_NR;

    /* Phase 6.5: PRIME ALTER_OVL2 plane=5 only. PRIOR FINDING: plane=3 (upper
     * LCD primary overlay) is what the factory nav is actively rendering to —
     * touching it triggers factory defense and kills us before V4L2 path runs.
     * Plane=5 is Sprite C (lower LCD overlay) which the factory uses only for
     * rearview camera, so it's safe to grab when no camera is active. */
    LOG("\n[phase6.5] prime ALTER_OVL2 plane=5 only (plane=3 kills us)\n");
    *(unsigned int *)&request[152] = 5;
    *rtn_p = 0;
    int prime_r = ioctl(drm, ioctl_alter, request);
    LOG("  prime ALTER_OVL2 plane=5 r=%d rtn=%d errno=%d\n",
        prime_r, *rtn_p, errno);

    LOG("  kmsg snapshot RIGHT AFTER prime (this is the data we've been missing):\n");
    int kfd_mid = open("/dev/kmsg", O_RDONLY | O_NONBLOCK);
    if (kfd_mid >= 0) {
        char mb[4096]; int mcap = 0;
        for (int i = 0; i < 300 && mcap < 3000; i++) {
            int n = read(kfd_mid, mb, sizeof(mb)-1);
            if (n <= 0) break;
            mb[n] = 0;
            char *l = mb;
            while (l && *l) {
                char *nx = strchr(l, '\n');
                if (nx) *nx++ = 0;
                /* Broader filter — catch ANY EMGD/DRM/overlay/v2g activity */
                if (strstr(l, "v2g") || strstr(l, "emgd") || strstr(l, "EMGD") ||
                    strstr(l, "OVL") || strstr(l, "GMM") || strstr(l, "Sprite") ||
                    strstr(l, "drm") || strstr(l, "DRM") || strstr(l, "overlay") ||
                    strstr(l, "alter") || strstr(l, "ALTER") || strstr(l, "Plane") ||
                    strstr(l, "plane") || strstr(l, "PVR")) {
                    LOG("    mid: %s\n", l);
                    mcap += strlen(l);
                }
                l = nx;
            }
        }
        close(kfd_mid);
        if (mcap == 0) LOG("    (NO matching kmsg lines — driver is silent)\n");
    }
    LOG("\n");

    /* Phase 6.7: V4L2 BUFFER PATH — moved BEFORE rainbow loop because rainbow
     * consistently dies at iter 2-30 and we never reached the V4L2 phase before.
     * Theory now backed by phase 6.5 kmsg-is-silent finding: driver accepts
     * ALTER_OVL2 but doesn't write hardware registers; only emgdhmid does.
     * Sprite C is hardwired to read from camera GTT range.
     * V4L2 REQBUFS allocates buffers in that range; we paint there. */
    LOG("[phase6.7] V4L2 buffer path — paint INTO camera GTT range\n");
    #define VIDIOC_S_FMT_     0xc0cc5605u
    #define VIDIOC_REQBUFS_   0xc0145608u
    #define VIDIOC_QUERYBUF_  0xc0445609u
    struct v4l_fmt_ { unsigned int type; unsigned char fmt[200]; } v4l_fmt;
    struct v4l_req_ { unsigned int count, type, memory, reserved[2]; } v4l_req;
    struct v4l_buf_ {
        unsigned int index,type,bytesused,flags,field;
        struct { long tv_sec,tv_usec;} timestamp;
        unsigned char tc[16];
        unsigned int sequence,memory;
        unsigned int offset;
        unsigned int length,input,reserved;
    } v4l_buf;
    int vid = open("/dev/video0", O_RDWR);
    LOG("  open /dev/video0 = %d errno=%d\n", vid, errno);
    if (vid >= 0) {
        memset(&v4l_fmt, 0, sizeof(v4l_fmt));
        v4l_fmt.type = 1;
        *(unsigned int *)&v4l_fmt.fmt[0]  = W;
        *(unsigned int *)&v4l_fmt.fmt[4]  = H;
        *(unsigned int *)&v4l_fmt.fmt[8]  = 0x56595559;  /* V4L2_PIX_FMT_YUYV */
        *(unsigned int *)&v4l_fmt.fmt[12] = 1;
        r = ioctl(vid, VIDIOC_S_FMT_, &v4l_fmt);
        LOG("  V4L2 S_FMT YUYV 800x480 r=%d pitch=%u\n",
            r, *(unsigned int*)&v4l_fmt.fmt[16]);
        memset(&v4l_req, 0, sizeof(v4l_req));
        v4l_req.count = 3; v4l_req.type = 1; v4l_req.memory = 1;
        r = ioctl(vid, VIDIOC_REQBUFS_, &v4l_req);
        LOG("  V4L2 REQBUFS r=%d got=%u\n", r, v4l_req.count);
        if (r == 0 && v4l_req.count > 0) {
            memset(&v4l_buf, 0, sizeof(v4l_buf));
            v4l_buf.type = 1; v4l_buf.memory = 1; v4l_buf.index = 0;
            r = ioctl(vid, VIDIOC_QUERYBUF_, &v4l_buf);
            LOG("  V4L2 QUERYBUF buf[0] r=%d offset=0x%x length=%u\n",
                r, v4l_buf.offset, v4l_buf.length);
            if (r == 0 && v4l_buf.length > 0) {
                void *v_m = mmap(NULL, v4l_buf.length, PROT_READ|PROT_WRITE,
                                 MAP_SHARED, vid, v4l_buf.offset);
                if (v_m != MAP_FAILED) {
                    unsigned char red_yuyv[4];
                    rgb_to_yuyv(255,0,0,red_yuyv);
                    for (unsigned int y = 0; y < H; y++) {
                        unsigned char *row = (unsigned char *)v_m + y * PITCH;
                        for (int x = 0; x < W; x += 2) memcpy(row+x*2, red_yuyv, 4);
                    }
                    msync(v_m, v4l_buf.length, MS_SYNC);
                    LOG("  painted RED into V4L2 buf[0] (GTT offset=0x%x)\n", v4l_buf.offset);

                    /* Point ALTER_OVL2 at V4L2 GTT offset (NOT GMM offset) */
                    *(unsigned long *)&request[8] = v4l_buf.offset;
                    /* 100 iters at 10ms = 1s hold with V4L2 offset, plane=5 only */
                    LOG("  ALTER_OVL2 sweep with V4L2 offset (100 iters x 10ms, p5 only)\n");
                    int v_p5=0;
                    *(unsigned int *)&request[152] = 5;
                    for (int iter = 0; iter < 100; iter++) {
                        ioctl(drm, DRM_SET_MASTER, 0);
                        *rtn_p = 0;
                        if (ioctl(drm, ioctl_alter, request) == 0 && *rtn_p == 0) v_p5++;
                        usleep(10000);
                    }
                    LOG("  V4L2-PATH TOTALS: p5 ok=%d / 100\n", v_p5);

                    /* kmsg snapshot AFTER V4L2 path */
                    LOG("  kmsg AFTER V4L2 path:\n");
                    int kf = open("/dev/kmsg", O_RDONLY|O_NONBLOCK);
                    if (kf >= 0) {
                        char kb[4096]; int kc = 0;
                        for (int i = 0; i < 300 && kc < 3000; i++) {
                            int n = read(kf, kb, sizeof(kb)-1);
                            if (n <= 0) break;
                            kb[n] = 0;
                            char *l = kb;
                            while (l && *l) {
                                char *nx = strchr(l, '\n'); if (nx) *nx++ = 0;
                                if (strstr(l, "v2g") || strstr(l, "emgd") || strstr(l, "EMGD") ||
                                    strstr(l, "OVL") || strstr(l, "GMM") || strstr(l, "drm") ||
                                    strstr(l, "DRM") || strstr(l, "alter") || strstr(l, "ALTER") ||
                                    strstr(l, "plane") || strstr(l, "Plane")) {
                                    LOG("    v4l-kmsg: %s\n", l); kc += strlen(l);
                                }
                                l = nx;
                            }
                        }
                        close(kf);
                        if (kc == 0) LOG("    (silent)\n");
                    }
                    munmap(v_m, v4l_buf.length);
                }
            }
        }
        close(vid);
    }

    /* Restore ALTER_OVL2 to use GMM offset for the rainbow loop */
    *(unsigned long *)&request[8] = req.offset;
    LOG("\n");

    /* Phase 7: RAINBOW PROOF cycle. Two reasons:
     *   (a) prior tests died at iter 3 even with active loop → emgdhmid grabbed
     *       master back; our drm fd became unauthenticated; kernel killed us.
     *       FIX: re-assert DRM_SET_MASTER every iteration.
     *   (b) solid-color cycle (RED → GREEN → BLUE → WHITE → PURPLE) is
     *       UNMISTAKABLE if any single color appears, vs a quadrant pattern
     *       that blends to a muddy color when alpha/format wrong. */
    LOG("\n[phase7] RAINBOW cycle: 5 colors x 30 iters x 10ms = ~1.5s total\n");
    LOG("         plane=5 only (plane=3 = factory primary overlay, kills us)\n");
    int p5_ok=0, p5_fail=0, sm_ok=0, sm_fail=0;
    int first_p5_rtn=-99;
    const char *color_name[] = {"RED", "GREEN", "BLUE", "WHITE", "PURPLE"};
    int color_rgb[][3] = {{255,0,0}, {0,255,0}, {0,0,255}, {255,255,255}, {255,0,255}};
    for (int iter = 0; iter < 150; iter++) {
        int seg = iter / 30;
        if (seg > 4) seg = 4;

        /* Re-paint buffer with solid color at start of each segment */
        if (iter % 30 == 0) {
            unsigned char yuyv[4];
            rgb_to_yuyv(color_rgb[seg][0], color_rgb[seg][1], color_rgb[seg][2], yuyv);
            unsigned char *bp = (unsigned char *)m;
            for (int y = 0; y < H; y++)
                for (int x = 0; x < W; x += 2)
                    memcpy(bp + y*PITCH + x*2, yuyv, 4);
            msync(m, BUF_SIZE, MS_SYNC);
            LOG("  ── segment %d: SOLID %s (yuyv=%02x%02x%02x%02x) ──\n",
                seg, color_name[seg], yuyv[0], yuyv[1], yuyv[2], yuyv[3]);
        }

        /* Re-take DRM master each iter — fights emgdhmid for control */
        int srm = ioctl(drm, DRM_SET_MASTER, 0);
        if (srm == 0) sm_ok++; else sm_fail++;

        /* plane=5 (lower LVDS Sprite C) — ONLY plane we touch */
        *(unsigned int *)&request[152] = 5;
        *rtn_p = 0;
        int r5 = ioctl(drm, ioctl_alter, request);
        if (iter == 0) first_p5_rtn = *rtn_p;
        if (r5 == 0 && *rtn_p == 0) p5_ok++; else p5_fail++;
        if (iter < 5 || iter % 30 == 5)
            LOG("    iter %d: sm=%d p5=%d\n", iter, srm, r5);
        usleep(10000);
    }
    LOG("  TOTALS: SET_MASTER ok=%d fail=%d, plane=5 ok=%d (first_rtn=%d)\n",
        sm_ok, sm_fail, p5_ok, first_p5_rtn);

    /* Phase 7.5: kmsg snapshot — what did the kernel say during our ALTER_OVL2 calls?
     * EMGD driver and v2g/v2gbridge log to kmsg on overlay state changes.
     * This is the diagnostic we've been missing all day. */
    LOG("\n[phase7.5] kmsg tail — kernel messages during/after our paint loop\n");
    int kfd = open("/dev/kmsg", O_RDONLY | O_NONBLOCK);
    if (kfd >= 0) {
        char buf[4096];
        int captured = 0;
        for (int i = 0; i < 500 && captured < 4000; i++) {
            int n = read(kfd, buf, sizeof(buf)-1);
            if (n <= 0) break;
            buf[n] = 0;
            /* Filter for lines about emgd/v2g/drm/overlay/sprite */
            char *line = buf;
            while (line && *line) {
                char *next = strchr(line, '\n');
                if (next) *next++ = 0;
                if (strstr(line, "v2g") || strstr(line, "emgd") || strstr(line, "drm") ||
                    strstr(line, "EMGD") || strstr(line, "DRM") || strstr(line, "overlay") ||
                    strstr(line, "OVL") || strstr(line, "sprite") || strstr(line, "Sprite") ||
                    strstr(line, "GMM") || strstr(line, "alter") || strstr(line, "ALTER")) {
                    LOG("  kmsg: %s\n", line);
                    captured += strlen(line);
                }
                line = next;
            }
        }
        close(kfd);
        if (captured == 0) LOG("  (no matching kmsg lines — driver may be silent or we missed window)\n");
    } else {
        LOG("  /dev/kmsg open failed errno=%d\n", errno);
    }

    /* Phase 8: cleanup */
    LOG("\n[phase8] cleanup\n");
    /* disable overlay */
    memset(request, 0, sizeof(request));
    *(unsigned int *)&request[152] = 5;
    *(int *)&request[196] = 0;  /* CMD_ALTER_OVL2_OFF? */
    r = ioctl(drm, ioctl_alter, request);
    LOG("  ALTER_OVL2 disable r=%d errno=%d\n", r, errno);

    munmap(m, req.size);
    ioctl(drm, DRM_DROP_MASTER, 0);
    close(drm);
    resume_all();
    LOG("\n=== DONE ===\n");
    fclose(flog);
    return 0;
}
