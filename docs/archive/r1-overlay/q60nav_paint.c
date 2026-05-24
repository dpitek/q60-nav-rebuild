/*
 * q60nav_paint.c — R1 overlay raw-pixel painter for Q60 DCU.
 *
 * Proven path (verified working in Q60_R1_V4L2.LOG, line ~75 of kmsg):
 *   1. open /dev/video0 (V4L2 capture device)
 *   2. open /dev/v2gbridge
 *   3. V2G_ENABLE_BRIDGE with {plane=Sprite C (5), screen=0}
 *      → driver maps 3 GTT buffers (paddr 0x36e00000/0x36f00000/0x36800000)
 *      → returns 3 offsets
 *   4. mmap the 3 buffers from /dev/v2gbridge
 *   5. paint YUYV pixels (800x480, pitch=1600)
 *   6. V2G_DISPLAY_FRAME(buf_index) repeatedly
 *
 * Compile static against musl (Alpine i386) so we don't fight factory glibc 2.11:
 *   docker run --rm --platform linux/386 -v $PWD:/src alpine:latest sh -c \
 *     'apk add --no-cache gcc musl-dev binutils && \
 *      gcc -static -no-pie -O2 -Wall -o /src/q60nav_paint /src/q60nav_paint.c && \
 *      objcopy --remove-section=.note.ABI-tag --strip-all /src/q60nav_paint'
 *
 * Deploy: replace /opt/q60r1/v4l2_test with this binary; run.sh stays as-is.
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
#include <sys/wait.h>

/* V4L2 ioctls */
#define VIDIOC_QUERYCAP  0x80685600u
#define VIDIOC_S_FMT     0xc0cc5605u
#define VIDIOC_REQBUFS   0xc0145608u
#define VIDIOC_QUERYBUF  0xc0445609u
#define VIDIOC_QBUF      0xc044560fu
#define VIDIOC_STREAMON  0x40045612u
#define V4L2_BUF_TYPE_VIDEO_CAPTURE 1
#define V4L2_MEMORY_MMAP            1
#define V4L2_FIELD_NONE             1
#define V4L2_PIX_FMT_YUYV  0x56595559u

/* v2gbridge ioctls (verified from CLAUDE.md + kmsg) */
#define V2G_ENABLE_BRIDGE  0xc0047600u   /* _IOWR('v',0,4) */
#define V2G_DISPLAY_FRAME  0xc0047602u   /* _IOWR('v',2,4) — arg = buf index 0/1/2 */
#define SPRITE_C_PLANE     5
#define SCREEN_DEFAULT     0

struct v4l2_pix_format {
    unsigned int width, height, pixelformat, field, bytesperline, sizeimage, colorspace, priv;
};
struct v4l2_format {
    unsigned int type;
    union { struct v4l2_pix_format pix; unsigned char raw[200]; } fmt;
};
struct v4l2_requestbuffers { unsigned int count, type, memory, reserved[2]; };
struct v4l2_timecode { unsigned int type, flags; unsigned char frames, seconds, minutes, hours, userbits[4]; };
struct v4l2_buffer {
    unsigned int index, type, bytesused, flags, field;
    struct { long tv_sec, tv_usec; } timestamp;
    struct v4l2_timecode timecode;
    unsigned int sequence, memory;
    union { unsigned int offset; unsigned long userptr; int fd; } m;
    unsigned int length, input, reserved;
};

#define W 800
#define H 480
#define PITCH 1600                 /* YUYV: 2 bytes per pixel */
#define BUF_SIZE 0xc3000           /* 798720 bytes, matches kmsg */
#define BOOT_LOG "/boot/Q60_PAINT.LOG"

static FILE *flog;
#define LOG(...) do { fprintf(flog, __VA_ARGS__); fflush(flog); } while (0)

/* Encode an RGB color as YUYV byte pattern that fills 2 pixels.
 * Returns 4 bytes: Y0 U0 Y1 V0.
 * CRITICAL: r,g,b must be 'int' not 'unsigned' — otherwise -38*r promotes to
 * unsigned arithmetic, producing huge positive instead of small negative.
 * Bug found 2026-05-18 via PPM unit test; previously RGB → magenta. */
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

/* Paint a 4-quadrant test pattern (Red TL, Green TR, Blue BL, White BR)
 * with a thick yellow "Q60" sign in the center. Easy to see we wrote pixels. */
static void paint_test_pattern(unsigned char *buf, unsigned frame) {
    unsigned char y_r[4], y_g[4], y_b[4], y_w[4], y_y[4], y_k[4];
    rgb_to_yuyv(255, 0, 0, y_r);
    rgb_to_yuyv(0, 255, 0, y_g);
    rgb_to_yuyv(0, 0, 255, y_b);
    rgb_to_yuyv(255, 255, 255, y_w);
    rgb_to_yuyv(255, 230, 0, y_y);
    rgb_to_yuyv(0, 0, 0, y_k);
    int half_w = W/2, half_h = H/2;

    /* Animated tint — shift colors slightly each frame so we can SEE motion */
    unsigned tint = frame & 0xFF;
    y_r[0] = (unsigned char)((y_r[0] + tint) & 0xFF);
    y_g[0] = (unsigned char)((y_g[0] + tint) & 0xFF);

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

    /* Center 200x100 yellow band so motion-tint doesn't hide our marker */
    int cx0 = (W - 200) / 2, cy0 = (H - 100) / 2;
    for (int y = cy0; y < cy0 + 100; y++) {
        unsigned char *row = buf + y * PITCH;
        for (int x = cx0; x < cx0 + 200; x += 2) {
            memcpy(row + x*2, y_y, 4);
        }
    }
    /* Black border on yellow band */
    for (int x = cx0; x < cx0 + 200; x += 2) {
        memcpy(buf + cy0*PITCH + x*2, y_k, 4);
        memcpy(buf + (cy0+99)*PITCH + x*2, y_k, 4);
    }
    for (int y = cy0; y < cy0 + 100; y++) {
        memcpy(buf + y*PITCH + cx0*2, y_k, 4);
        memcpy(buf + y*PITCH + (cx0+198)*2, y_k, 4);
    }
}

int main(void) {
    /* PROPER DAEMONIZE — last test's binary died at 750ms because setsid()
     * silently failed (we exec'd from shell and inherited pgrp-leader status).
     * Pattern: fork → parent exits → child runs setsid → second fork to drop
     * controlling terminal hooks. Result: fully detached daemon. */
    pid_t p1 = fork();
    if (p1 < 0) return 99;
    if (p1 > 0) return 0;     /* original parent exits — its parent in shell can reap it */
    /* First child: now we can setsid because we're NOT pgrp leader */
    if (setsid() < 0) return 98;
    pid_t p2 = fork();
    if (p2 < 0) return 97;
    if (p2 > 0) return 0;     /* first child exits — second child reparented to init(1) */
    /* Now we are: ppid=1 (init), sid=our_own, no controlling tty, fully detached.
     * Android init cannot reap us via process-group sweep. */

    /* Best-effort /boot mount (parent shell did this but verify) */
    mkdir("/boot", 0755);
    flog = fopen(BOOT_LOG, "w");
    if (!flog) flog = fopen("/tmp/Q60_PAINT.LOG", "w");
    if (!flog) flog = stderr;
    LOG("=== Q60 R1 PAINT (daemonized) — pid=%d ppid=%d sid=%d %ld ===\n",
        getpid(), getppid(), getsid(0), (long)time(NULL));
    LOG("    (if ppid=1 we're orphaned to init — Android can't reap us)\n");

    /* 1. open /dev/video0 — required for v2gbridge GTT buffer allocation */
    int vid = open("/dev/video0", O_RDWR);
    LOG("open /dev/video0 = %d (errno %d)\n", vid, errno);
    if (vid < 0) { LOG("FATAL: no video0\n"); return 1; }

    /* Tell v4l2 we want YUYV 800x480 */
    struct v4l2_format fmt = {0};
    fmt.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    fmt.fmt.pix.width = W; fmt.fmt.pix.height = H;
    fmt.fmt.pix.pixelformat = V4L2_PIX_FMT_YUYV;
    fmt.fmt.pix.field = V4L2_FIELD_NONE;
    int r = ioctl(vid, VIDIOC_S_FMT, &fmt);
    LOG("VIDIOC_S_FMT = %d (errno %d) pix=%ux%u pitch=%u\n",
        r, errno, fmt.fmt.pix.width, fmt.fmt.pix.height, fmt.fmt.pix.bytesperline);

    struct v4l2_requestbuffers req = {0};
    req.count = 3; req.type = V4L2_BUF_TYPE_VIDEO_CAPTURE; req.memory = V4L2_MEMORY_MMAP;
    r = ioctl(vid, VIDIOC_REQBUFS, &req);
    LOG("VIDIOC_REQBUFS(3) = %d (errno %d) got=%u\n", r, errno, req.count);

    /* 2. + 3. V2G_ENABLE retry loop — CRITICAL: open+close /dev/v2gbridge
     *    PER ATTEMPT. Factory's working sequence (Q60_R1_V4L2.LOG kmsg) was:
     *      t=6.99: open, ENABLE plane=0/1/2 fail, RELEASE (close)
     *      t=16.29: OPEN AGAIN (fresh fd), ENABLE Sprite C → SUCCESS
     *    Retrying on the same fd is what killed us at 750ms (driver kicks
     *    the fd after repeated EINVAL). */
    int v2g = -1;
    unsigned int v2g_args[2] = { SPRITE_C_PLANE, SCREEN_DEFAULT };
    r = -1;
    LOG("V2G_ENABLE retry loop (fresh fd per attempt)...\n");
    fflush(flog);
    for (int attempt = 0; attempt < 240; attempt++) {
        /* Log AT START of each early iteration so we know we got here */
        if (attempt < 8 || attempt % 20 == 0) {
            LOG("[t=%dms] attempt %d entry\n", attempt*250, attempt);
            fflush(flog);
        }

        /* Try plane=5 (Sprite C) on a fresh fd */
        int fd = open("/dev/v2gbridge", O_RDWR);
        if (fd < 0) {
            if (attempt < 8 || attempt % 20 == 0)
                LOG("  open v2g failed errno=%d\n", errno);
            usleep(250000);
            continue;
        }
        v2g_args[0] = SPRITE_C_PLANE; v2g_args[1] = SCREEN_DEFAULT;
        r = ioctl(fd, V2G_ENABLE_BRIDGE, v2g_args);
        if (r == 0) {
            LOG("  attempt %d: V2G_ENABLE plane=5 SUCCESS after %dms (fd=%d)\n",
                attempt, attempt*250, fd);
            fflush(flog);
            v2g = fd;  /* keep open for buffer mapping below */
            break;
        }
        int errno_p5 = errno;
        close(fd);

        /* Try plane=3 on another fresh fd */
        fd = open("/dev/v2gbridge", O_RDWR);
        if (fd < 0) { usleep(250000); continue; }
        v2g_args[0] = 3; v2g_args[1] = SCREEN_DEFAULT;
        int r2 = ioctl(fd, V2G_ENABLE_BRIDGE, v2g_args);
        if (r2 == 0) {
            LOG("  attempt %d: V2G_ENABLE plane=3 SUCCESS after %dms (fd=%d)\n",
                attempt, attempt*250, fd);
            fflush(flog);
            v2g = fd; r = 0;
            break;
        }
        int errno_p3 = errno;
        close(fd);

        if (attempt < 8 || attempt % 20 == 0) {
            LOG("  attempt %d (%dms): p5 r=%d e=%d / p3 r=%d e=%d\n",
                attempt, attempt*250, r, errno_p5, r2, errno_p3);
            fflush(flog);
        }
        usleep(250000);
    }
    LOG("V2G_ENABLE final: r=%d v2g_fd=%d\n", r, v2g);
    fflush(flog);

    /* 4. mmap buffers — kmsg shows offsets at 0x1000000 / 0x1100000 / 0x1200000.
     *    We try sequential 0x1000000-stepped offsets. */
    unsigned char *bufs[3] = {0};
    unsigned long offsets[3] = { 0x1000000UL, 0x1100000UL, 0x1200000UL };
    for (int i = 0; i < 3; i++) {
        void *m = mmap(NULL, BUF_SIZE, PROT_READ|PROT_WRITE, MAP_SHARED, v2g, offsets[i]);
        if (m == MAP_FAILED) {
            LOG("mmap buf[%d] off=0x%lx FAILED errno=%d\n", i, offsets[i], errno);
        } else {
            bufs[i] = (unsigned char*)m;
            LOG("mmap buf[%d] off=0x%lx -> %p\n", i, offsets[i], m);
        }
    }
    if (!bufs[0]) {
        LOG("FATAL: buf[0] mmap failed — try mmap on /dev/video0 fallback\n");
        struct v4l2_buffer vbuf = {0};
        vbuf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE; vbuf.memory = V4L2_MEMORY_MMAP; vbuf.index = 0;
        if (ioctl(vid, VIDIOC_QUERYBUF, &vbuf) == 0) {
            void *m = mmap(NULL, vbuf.length, PROT_READ|PROT_WRITE, MAP_SHARED, vid, vbuf.m.offset);
            if (m != MAP_FAILED) { bufs[0] = m; LOG("v4l2 mmap fallback worked offset=0x%x\n", vbuf.m.offset); }
        }
    }
    if (!bufs[0]) { LOG("FATAL: no buffer to paint into\n"); return 3; }

    /* 5. Animation loop — paint pattern, DISPLAY_FRAME, repeat */
    LOG("\n=== ENTERING PAINT LOOP — painting buf[0..%d] ===\n", bufs[2] ? 2 : 0);
    int n_bufs = (bufs[2] ? 3 : (bufs[1] ? 2 : 1));
    for (unsigned frame = 0; frame < 600; frame++) {  /* ~10 sec at 60Hz */
        int bi = frame % n_bufs;
        if (bufs[bi]) {
            paint_test_pattern(bufs[bi], frame);
            msync(bufs[bi], BUF_SIZE, MS_SYNC);
            unsigned int idx = (unsigned int)bi;
            int dr = ioctl(v2g, V2G_DISPLAY_FRAME, &idx);
            if (frame < 5 || frame % 60 == 0)
                LOG("frame %u buf %d DISPLAY_FRAME=%d errno=%d\n", frame, bi, dr, errno);
        }
        usleep(16000);  /* ~60Hz */
    }
    LOG("\n=== PAINT LOOP DONE ===\n");

    fclose(flog);
    /* Copy /tmp log to /boot if we wrote there */
    if (access("/tmp/Q60_PAINT.LOG", R_OK) == 0) {
        FILE *s = fopen("/tmp/Q60_PAINT.LOG", "r");
        FILE *d = fopen(BOOT_LOG, "w");
        if (s && d) { char buf[4096]; size_t n; while ((n=fread(buf,1,sizeof buf,s))>0) fwrite(buf,1,n,d); }
        if (s) fclose(s); if (d) fclose(d);
    }
    return 0;
}
