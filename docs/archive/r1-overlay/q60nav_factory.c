/*
 * q60nav_factory.c — REPLICATE THE FACTORY EXACTLY.
 *
 * Ground truth (from disassembling /tmp/q60-overnight/v2g/emgdhmid):
 *   emgdhmid uses ONLY these ioctls:
 *     V4L2: 0x80685600 QUERYCAP, 0xc0cc5605 S_FMT, 0xc0145608 REQBUFS,
 *           0xc0445609 QUERYBUF, 0xc044560f QBUF, 0x40045612 STREAMON
 *     Custom V4L2 (ioh_video_in): 0x800456d5 GET_BUFFER_SIZE (returns int),
 *                                 0x805056d8 GET_FRAME_BUFFERS (returns 80 bytes)
 *     V2G: 0xc0047600 ENABLE, 0xc0047601 DISABLE, 0xc0047602 DISPLAY_FRAME
 *
 *   NO DRM_SET_MASTER. NO ALTER_OVL2. NO GMM_ALLOC. NO /dev/dri/card0.
 *
 * V2G_ENABLE struct (from emgdhmid 0x804f302..0x804f3cf disassembly):
 *   - >= 0x248 bytes (we use 0x300 for safety)
 *   - offset 0x40..0x90: 5 × 16-byte buffer descriptors copied directly from
 *     IOH_VIDEO_GET_FRAME_BUFFERS result (80 bytes)
 *   - offset 0x90: uint16 screen = 1
 *   - offset 0x92: uint16 plane  = 1
 *   - Both values are factory-confirmed: emgdhmid binary unconditionally sets
 *     screen=1, plane=1 (only the second is gated on getenv — we set both).
 *
 * Factory kmsg success pattern (pro03.dmesg lines 1253-1261):
 *   [24.339145] open video0
 *   [24.339208] v2gbridge: open() SUCCESSFUL
 *   [24.344943] v2g: Enable Sprite C Bridge on screen 0
 *   [24.344957] v2g: GTT mapping requested for 3 buffers:
 *   [24.344968] v2g: map paddr=0x36e00000, size=0xc3000
 *   [24.345302] v2g: received offset=f40000   ← user-provided GTT offset
 *   [24.345892] v2g: v2g_enable_bridge() SUCCESSFUL
 *
 * If V2G_ENABLE still returns EINVAL with this exact factory call signature,
 * something is environmental (not call-shape). Logs will reveal it.
 *
 * Compile (Alpine i386 musl static):
 *   docker run --rm --platform linux/386 -v /tmp/q60-paint-build:/build alpine:latest sh -c '
 *     apk add --no-cache gcc musl-dev binutils >/dev/null
 *     gcc -static -no-pie -O2 -Wall -o /build/q60nav_factory /build/q60nav_factory.c
 *     objcopy --remove-section=.note.ABI-tag --strip-all /build/q60nav_factory'
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
#include <signal.h>
#include <errno.h>
#include <time.h>

/* V4L2 standard ioctls (factory-extracted from emgdhmid disasm) */
#define VIDIOC_QUERYCAP                 0x80685600u
#define VIDIOC_S_FMT                    0xc0cc5605u
#define VIDIOC_REQBUFS                  0xc0145608u
#define VIDIOC_QUERYBUF                 0xc0445609u
#define VIDIOC_QBUF                     0xc044560fu
#define VIDIOC_STREAMON                 0x40045612u
/* ioh_video_in custom ioctls — THIS IS THE PIECE WE'VE BEEN MISSING */
#define IOH_VIDEO_GET_BUFFER_SIZE       0x800456d5u  /* _IOR('V', 0xd5, int)  */
#define IOH_VIDEO_GET_FRAME_BUFFERS     0x805056d8u  /* _IOR('V', 0xd8, [80]) */
/* V2G */
#define V2G_ENABLE_BRIDGE               0xc0047600u
#define V2G_DISABLE_BRIDGE              0xc0047601u
#define V2G_DISPLAY_FRAME               0xc0047602u
/* V4L2 constants */
#define V4L2_BUF_TYPE_VIDEO_CAPTURE     1
#define V4L2_MEMORY_MMAP                1
#define V4L2_FIELD_NONE                 1
#define V4L2_PIX_FMT_YUYV               0x56595559u

#define W 800
#define H 480
#define PITCH 1600                              /* YUYV 2bpp */
#define BUF_SIZE (W * H * 2)                     /* 768,000 */
#define N_BUFS 3

#define BOOT_LOG "/boot/Q60_FACTORY.LOG"
static FILE *flog;
#define LOG(...) do { fprintf(flog, __VA_ARGS__); fflush(flog); fsync(fileno(flog)); } while (0)

/* Signal trap: prior boots died silently during sleep — we never knew which signal.
 * This logs the signal number + siginfo source then exits, so the log captures
 * whatever kill mechanism the factory is using. */
static void sig_trap(int sig, siginfo_t *info, void *ctx) {
    (void)ctx;
    if (flog) {
        fprintf(flog, "\n[!!] caught signal %d from pid=%d uid=%d code=%d\n",
                sig, info ? info->si_pid : -1, info ? info->si_uid : -1,
                info ? info->si_code : -1);
        fflush(flog); fsync(fileno(flog));
    }
    _exit(100 + sig);
}

static void install_sig_handlers(void) {
    struct sigaction sa = {0};
    sa.sa_sigaction = sig_trap;
    sa.sa_flags = SA_SIGINFO;
    sigemptyset(&sa.sa_mask);
    int sigs[] = { SIGHUP, SIGINT, SIGQUIT, SIGTERM, SIGTSTP, SIGTTIN, SIGTTOU,
                   SIGPIPE, SIGALRM, SIGUSR1, SIGUSR2, SIGCHLD, SIGURG,
                   SIGSEGV, SIGBUS, SIGFPE, SIGILL, SIGABRT, SIGXCPU, SIGXFSZ };
    for (size_t i = 0; i < sizeof(sigs)/sizeof(sigs[0]); i++)
        sigaction(sigs[i], &sa, NULL);
}

/* V4L2 struct layouts (musl-compatible, fixed-width fields) */
struct v4l2_pix_format {
    unsigned int width, height, pixelformat, field;
    unsigned int bytesperline, sizeimage, colorspace, priv;
};
struct v4l2_format {
    unsigned int type;
    union { struct v4l2_pix_format pix; unsigned char raw[200]; } fmt;
};
struct v4l2_requestbuffers { unsigned int count, type, memory, reserved[2]; };
struct v4l2_timecode { unsigned int type, flags;
    unsigned char frames, seconds, minutes, hours, userbits[4]; };
struct v4l2_buffer {
    unsigned int index, type, bytesused, flags, field;
    struct { long tv_sec, tv_usec; } timestamp;
    struct v4l2_timecode timecode;
    unsigned int sequence, memory;
    union { unsigned int offset; unsigned long userptr; int fd; } m;
    unsigned int length, input, reserved;
};

/* YUYV color encoder. r,g,b MUST be int (not unsigned) to avoid promotion bug. */
static void rgb_to_yuyv(int r, int g, int b, unsigned char out[4]) {
    int y =  ((66*r + 129*g + 25*b + 128) >> 8) + 16;
    int u = ((-38*r - 74*g + 112*b + 128) >> 8) + 128;
    int v = ((112*r - 94*g - 18*b + 128) >> 8) + 128;
    if (y < 0) y = 0; if (y > 255) y = 255;
    if (u < 0) u = 0; if (u > 255) u = 255;
    if (v < 0) v = 0; if (v > 255) v = 255;
    out[0] = (unsigned char)y;
    out[1] = (unsigned char)u;
    out[2] = (unsigned char)y;
    out[3] = (unsigned char)v;
}

static void paint_solid(unsigned char *buf, int r, int g, int b) {
    unsigned char yuyv[4];
    rgb_to_yuyv(r, g, b, yuyv);
    for (int y = 0; y < H; y++) {
        unsigned char *row = buf + y * PITCH;
        for (int x = 0; x < W; x += 2) memcpy(row + x*2, yuyv, 4);
    }
}

static void hexdump_n(const unsigned char *p, int n, const char *label) {
    LOG("  %s [%d bytes]:\n", label, n);
    for (int i = 0; i < n; i += 16) {
        LOG("    %04x:", i);
        for (int j = 0; j < 16 && i+j < n; j++) LOG(" %02x", p[i+j]);
        LOG("\n");
    }
}

int main(void) {
    /* Daemonize: fork, parent exit, setsid, fork, grandchild ppid=1 */
    if (fork() > 0) return 0;
    if (setsid() < 0) return 98;
    if (fork() > 0) return 0;

    mkdir("/boot", 0755);
    flog = fopen(BOOT_LOG, "w");
    if (!flog) flog = stderr;
    setvbuf(flog, NULL, _IOLBF, 0);

    LOG("=== Q60 FACTORY PATH — pid=%d ppid=%d sid=%d t=%ld ===\n",
        getpid(), getppid(), getsid(0), (long)time(NULL));

    install_sig_handlers();
    LOG("[init] signal handlers installed (will log signal# on any kill)\n");

    /* Wait for factory UI — 8 × 1s, log between each so death is timestamped */
    LOG("[wait] heartbeat poll for 8s\n");
    for (int s = 1; s <= 8; s++) {
        sleep(1);
        LOG("  +%ds alive (pid=%d ppid=%d)\n", s, getpid(), getppid());
    }

    /* === STEP 1: open /dev/video0 === */
    LOG("\n[1] open /dev/video0\n");
    int vid = open("/dev/video0", O_RDWR);
    if (vid < 0) { LOG("  FATAL: open errno=%d\n", errno); return 1; }
    LOG("  vid_fd = %d\n", vid);

    /* === STEP 2: VIDIOC_S_FMT YUYV 800x480 === */
    LOG("\n[2] VIDIOC_S_FMT YUYV 800x480\n");
    struct v4l2_format fmt = {0};
    fmt.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    fmt.fmt.pix.width = W;
    fmt.fmt.pix.height = H;
    fmt.fmt.pix.pixelformat = V4L2_PIX_FMT_YUYV;
    fmt.fmt.pix.field = V4L2_FIELD_NONE;
    int r = ioctl(vid, VIDIOC_S_FMT, &fmt);
    LOG("  r=%d errno=%d pix=%ux%u pitch=%u sizeimage=%u\n",
        r, errno, fmt.fmt.pix.width, fmt.fmt.pix.height,
        fmt.fmt.pix.bytesperline, fmt.fmt.pix.sizeimage);

    /* === STEP 3: VIDIOC_REQBUFS count=3 === */
    LOG("\n[3] VIDIOC_REQBUFS count=3\n");
    struct v4l2_requestbuffers req = {0};
    req.count = N_BUFS;
    req.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    req.memory = V4L2_MEMORY_MMAP;
    r = ioctl(vid, VIDIOC_REQBUFS, &req);
    LOG("  r=%d errno=%d got=%u\n", r, errno, req.count);
    if (r < 0 || req.count == 0) { LOG("  FATAL: REQBUFS failed\n"); return 2; }

    /* === STEP 4: IOH_VIDEO_GET_BUFFER_SIZE (factory does this) === */
    LOG("\n[4] IOH_VIDEO_GET_BUFFER_SIZE (0x800456d5)\n");
    unsigned int buf_size = 0;
    r = ioctl(vid, IOH_VIDEO_GET_BUFFER_SIZE, &buf_size);
    LOG("  r=%d errno=%d buffer_size=%u (0x%x)\n", r, errno, buf_size, buf_size);

    /* === STEP 5: IOH_VIDEO_GET_FRAME_BUFFERS — the key step ===
     * Returns 80 bytes = 5 × 16-byte buffer descriptors. Factory copies these
     * directly into V2G_ENABLE struct at offset 0x40. */
    LOG("\n[5] IOH_VIDEO_GET_FRAME_BUFFERS (0x805056d8) — KEY STEP\n");
    unsigned char frame_buffers[80] = {0};
    r = ioctl(vid, IOH_VIDEO_GET_FRAME_BUFFERS, frame_buffers);
    LOG("  r=%d errno=%d\n", r, errno);
    if (r == 0) hexdump_n(frame_buffers, 80, "GET_FRAME_BUFFERS result");

    /* === STEP 6: QUERYBUF each buffer, mmap them so we can paint === */
    LOG("\n[6] QUERYBUF + mmap each of %d V4L2 buffers\n", N_BUFS);
    void *mbufs[N_BUFS] = {0};
    unsigned int mlens[N_BUFS] = {0};
    unsigned int moffs[N_BUFS] = {0};
    for (int i = 0; i < N_BUFS; i++) {
        struct v4l2_buffer qb = {0};
        qb.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        qb.memory = V4L2_MEMORY_MMAP;
        qb.index = i;
        r = ioctl(vid, VIDIOC_QUERYBUF, &qb);
        LOG("  buf[%d]: QUERYBUF r=%d errno=%d offset=0x%x length=%u\n",
            i, r, errno, qb.m.offset, qb.length);
        if (r != 0 || qb.length == 0) continue;
        moffs[i] = qb.m.offset;
        mlens[i] = qb.length;
        void *m = mmap(NULL, qb.length, PROT_READ|PROT_WRITE,
                       MAP_SHARED, vid, qb.m.offset);
        if (m == MAP_FAILED) {
            LOG("    mmap FAILED errno=%d\n", errno);
        } else {
            mbufs[i] = m;
            LOG("    mmap = %p\n", m);
        }
    }

    /* === STEP 7: paint a distinct solid color into each buffer === */
    LOG("\n[7] paint solid RED/GREEN/BLUE into buf[0..2]\n");
    if (mbufs[0]) paint_solid(mbufs[0], 255, 0, 0);
    if (mbufs[1]) paint_solid(mbufs[1], 0, 255, 0);
    if (mbufs[2]) paint_solid(mbufs[2], 0, 0, 255);
    for (int i = 0; i < N_BUFS; i++) if (mbufs[i]) msync(mbufs[i], mlens[i], MS_SYNC);
    LOG("  painted (RED, GREEN, BLUE)\n");

    /* === STEP 8: QBUF each buffer + STREAMON === */
    LOG("\n[8] QBUF each + STREAMON\n");
    for (int i = 0; i < N_BUFS; i++) {
        struct v4l2_buffer qb = {0};
        qb.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        qb.memory = V4L2_MEMORY_MMAP;
        qb.index = i;
        r = ioctl(vid, VIDIOC_QBUF, &qb);
        LOG("  QBUF[%d] r=%d errno=%d\n", i, r, errno);
    }
    unsigned int stream_type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    r = ioctl(vid, VIDIOC_STREAMON, &stream_type);
    LOG("  STREAMON r=%d errno=%d\n", r, errno);

    /* === STEP 9: open /dev/v2gbridge === */
    LOG("\n[9] open /dev/v2gbridge\n");
    int v2g = open("/dev/v2gbridge", O_RDWR);
    if (v2g < 0) { LOG("  FATAL: open v2g errno=%d\n", errno); close(vid); return 3; }
    LOG("  v2g_fd = %d\n", v2g);

    /* === STEP 10: BUILD V2G_ENABLE struct exactly like emgdhmid does ===
     * Layout (from disasm of emgdhmid 0x804f302..0x804f3cf):
     *   - 0x00..0x3f: header (zero-init seems fine in factory binary)
     *   - 0x40..0x8f: 5 × 16-byte buffer descriptors (copy frame_buffers[80])
     *   - 0x90: uint16 screen = 1
     *   - 0x92: uint16 plane  = 1
     *   - 0x94..0x247: rest (zero) */
    LOG("\n[10] build V2G_ENABLE struct (0x300 bytes; factory uses ~0x248)\n");
    unsigned char vge[0x300] = {0};
    memcpy(vge + 0x40, frame_buffers, 80);
    *(unsigned short *)(vge + 0x90) = 1;   /* screen */
    *(unsigned short *)(vge + 0x92) = 1;   /* plane  */
    hexdump_n(vge, 0xa0, "V2G_ENABLE struct first 0xa0 bytes");

    /* === STEP 11: V2G_ENABLE_BRIDGE — the moment of truth === */
    LOG("\n[11] ioctl(v2g_fd, V2G_ENABLE_BRIDGE, vge)\n");
    r = ioctl(v2g, V2G_ENABLE_BRIDGE, vge);
    int v2g_errno = errno;
    LOG("  r=%d errno=%d   (factory kmsg expects 'v2g_enable_bridge() SUCCESSFUL')\n",
        r, v2g_errno);

    /* === STEP 12: kmsg snapshot to confirm — should see "Enable Sprite C Bridge" === */
    LOG("\n[12] kmsg tail (v2g/sprite/GTT only)\n");
    int kfd = open("/dev/kmsg", O_RDONLY | O_NONBLOCK);
    if (kfd >= 0) {
        char kb[4096]; int cap = 0;
        for (int i = 0; i < 400 && cap < 4000; i++) {
            int n = read(kfd, kb, sizeof(kb)-1);
            if (n <= 0) break;
            kb[n] = 0;
            char *l = kb;
            while (l && *l) {
                char *nx = strchr(l, '\n');
                if (nx) *nx++ = 0;
                if (strstr(l, "v2g") || strstr(l, "Sprite") || strstr(l, "GTT") ||
                    strstr(l, "ioh") || strstr(l, "paddr=0x36")) {
                    LOG("  kmsg: %s\n", l);
                    cap += strlen(l);
                }
                l = nx;
            }
        }
        close(kfd);
        if (cap == 0) LOG("  (no matching kmsg lines)\n");
    }

    /* === STEP 13: if V2G_ENABLE succeeded, run DISPLAY_FRAME loop for 10s === */
    if (r == 0) {
        LOG("\n[13] V2G_ENABLE SUCCESS — entering DISPLAY_FRAME loop (10s, 60Hz)\n");
        LOG("     Cycle buffers RED→GREEN→BLUE at ~10 Hz so eye can resolve change\n");
        int frame_ok = 0;
        for (int frame = 0; frame < 100; frame++) {
            unsigned int idx = (frame / 6) % N_BUFS;   /* ~6 frames per color */
            int dr = ioctl(v2g, V2G_DISPLAY_FRAME, &idx);
            if (dr == 0) frame_ok++;
            if (frame < 5 || frame % 20 == 0)
                LOG("  frame %d buf %u DISPLAY_FRAME r=%d errno=%d\n",
                    frame, idx, dr, errno);
            usleep(100000);  /* 10 Hz */
        }
        LOG("  DISPLAY_FRAME successes: %d / 100\n", frame_ok);
    } else {
        LOG("\n[13] V2G_ENABLE failed — skipping DISPLAY_FRAME loop\n");
        LOG("     Try: variant struct layouts. But first inspect step [5] hexdump.\n");
        LOG("     If frame_buffers was all zeros, IOH_VIDEO_GET_FRAME_BUFFERS\n");
        LOG("     needs to run AFTER STREAMON, not before. Reorder.\n");
    }

    /* === STEP 14: cleanup — DISABLE v2g and exit === */
    LOG("\n[14] cleanup: V2G_DISABLE + close fds\n");
    unsigned int disable_arg = 0;
    r = ioctl(v2g, V2G_DISABLE_BRIDGE, &disable_arg);
    LOG("  V2G_DISABLE r=%d errno=%d\n", r, errno);
    for (int i = 0; i < N_BUFS; i++) if (mbufs[i]) munmap(mbufs[i], mlens[i]);
    close(v2g);
    close(vid);

    LOG("\n=== DONE ===\n");
    fclose(flog);
    return 0;
}
