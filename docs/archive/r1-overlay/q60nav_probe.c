/*
 * q60nav_probe.c — PURE OBSERVER. Zero state-changing ioctls.
 *
 * Purpose: learn how the factory actually drives the display so we can
 * replicate it. After many boots dying at random points in ioctl chains
 * with no visible pixels, the only honest answer is: we don't know what
 * the factory actually does. Find out.
 *
 * What it dumps to /boot/Q60_PROBE.LOG:
 *   - For emgdhmid, camera_ps, display_p, hmictrl, navi_ps, dispapf:
 *       /proc/$pid/cmdline   — full argv
 *       /proc/$pid/maps      — all mapped regions (libraries, /dev/* mmaps, anon)
 *       /proc/$pid/fd        — every fd and where it points
 *       /proc/$pid/status    — uid/gid/threads
 *   - /proc/devices, /proc/modules, /proc/iomem, /proc/interrupts
 *   - /sys/class/drm/card0/* — every readable file
 *   - All /dev/dri/, /dev/video*, /dev/v2g*, /dev/fb* device nodes
 *   - kmsg tail
 *
 * Does NOT call: ioctl, mmap of /dev/*, SET_MASTER, ALTER_OVL2, anything mutating.
 * Only: open(O_RDONLY), read(), close(), opendir(), readdir(), readlink().
 *
 * Goal: when this finishes, we know EXACTLY which device nodes emgdhmid has
 * open, what physical/virtual memory it has mmap'd (revealing whether it
 * uses /dev/mem direct MMIO or DRM GTT or v2gbridge), and what shared libs
 * it loads. That's the real answer to "how does Sprite C get pixels."
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <dirent.h>
#include <errno.h>
#include <time.h>

#define BOOT_LOG "/boot/Q60_PROBE.LOG"
static FILE *flog;
#define LOG(...) do { fprintf(flog, __VA_ARGS__); fflush(flog); fsync(fileno(flog)); } while (0)

/* Targets we care about — name substrings */
static const char *targets[] = {
    "emgdhmi", "camera_ps", "display_p", "hmictrl",
    "navi_ps", "dispapf", "v4l", NULL
};

static void dump_file(const char *path, int max_bytes) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) { LOG("  (open %s errno=%d)\n", path, errno); return; }
    char buf[4096];
    int total = 0;
    while (total < max_bytes) {
        int want = sizeof(buf) - 1;
        if (max_bytes - total < want) want = max_bytes - total;
        int n = read(fd, buf, want);
        if (n <= 0) break;
        buf[n] = 0;
        fprintf(flog, "%s", buf);
        total += n;
    }
    close(fd);
    if (total > 0 && buf[total > (int)sizeof(buf)-1 ? sizeof(buf)-1 : total-1] != '\n')
        LOG("\n");
    fflush(flog);
}

static void dump_fd_dir(int pid) {
    char dpath[64];
    snprintf(dpath, sizeof(dpath), "/proc/%d/fd", pid);
    DIR *d = opendir(dpath);
    if (!d) { LOG("  (opendir %s errno=%d)\n", dpath, errno); return; }
    struct dirent *e;
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.') continue;
        char fdpath[128], target[256];
        snprintf(fdpath, sizeof(fdpath), "%s/%s", dpath, e->d_name);
        ssize_t n = readlink(fdpath, target, sizeof(target)-1);
        if (n > 0) {
            target[n] = 0;
            LOG("    fd %s -> %s\n", e->d_name, target);
        }
    }
    closedir(d);
}

static int read_comm(int pid, char *out, int outlen) {
    char path[64];
    snprintf(path, sizeof(path), "/proc/%d/comm", pid);
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    if (!fgets(out, outlen, f)) { fclose(f); return -1; }
    fclose(f);
    int l = strlen(out);
    while (l > 0 && (out[l-1]=='\n'||out[l-1]==' ')) out[--l] = 0;
    return 0;
}

static int target_match(const char *comm) {
    for (int i = 0; targets[i]; i++)
        if (strstr(comm, targets[i])) return 1;
    return 0;
}

static void dump_process(int pid, const char *comm) {
    LOG("\n========== PID %d (%s) ==========\n", pid, comm);

    char path[64];

    LOG("--- cmdline ---\n");
    snprintf(path, sizeof(path), "/proc/%d/cmdline", pid);
    int fd = open(path, O_RDONLY);
    if (fd >= 0) {
        char buf[1024];
        int n = read(fd, buf, sizeof(buf)-1);
        if (n > 0) {
            for (int i = 0; i < n; i++) if (buf[i] == 0) buf[i] = ' ';
            buf[n] = 0;
            LOG("  %s\n", buf);
        }
        close(fd);
    }

    LOG("--- status (key lines) ---\n");
    snprintf(path, sizeof(path), "/proc/%d/status", pid);
    FILE *f = fopen(path, "r");
    if (f) {
        char line[256];
        while (fgets(line, sizeof(line), f)) {
            if (strncmp(line, "Name:", 5) == 0 ||
                strncmp(line, "PPid:", 5) == 0 ||
                strncmp(line, "Uid:", 4) == 0 ||
                strncmp(line, "Threads:", 8) == 0 ||
                strncmp(line, "VmSize:", 7) == 0 ||
                strncmp(line, "VmRSS:", 6) == 0)
                LOG("  %s", line);
        }
        fclose(f);
    }

    LOG("--- fd ---\n");
    dump_fd_dir(pid);

    LOG("--- maps (filtered: /dev, anon-rwx, libemgd, libv4l, libpvr, libdrm) ---\n");
    snprintf(path, sizeof(path), "/proc/%d/maps", pid);
    f = fopen(path, "r");
    if (f) {
        char line[512];
        while (fgets(line, sizeof(line), f)) {
            if (strstr(line, "/dev/") ||
                strstr(line, "libemgd") ||
                strstr(line, "libv4l") ||
                strstr(line, "libdrm") ||
                strstr(line, "libpvr") ||
                strstr(line, "PVR") ||
                strstr(line, "emgd") ||
                strstr(line, "rwxp") ||  /* exec+writable anon — JIT or shellcode-style */
                strstr(line, "[heap]") ||
                strstr(line, "[stack]"))
                LOG("  %s", line);
        }
        fclose(f);
    }
}

int main(void) {
    /* Daemonize so init's reap-children doesn't kill us */
    if (fork() > 0) return 0;
    if (setsid() < 0) return 98;
    if (fork() > 0) return 0;

    mkdir("/boot", 0755);
    flog = fopen(BOOT_LOG, "w");
    if (!flog) flog = stderr;
    setvbuf(flog, NULL, _IOLBF, 0);

    LOG("=== Q60 PROBE (read-only observer) — pid=%d ppid=%d t=%ld ===\n",
        getpid(), getppid(), (long)time(NULL));

    /* Wait for factory UI to be fully up so emgdhmid is in steady state */
    LOG("\n[wait] sleeping 10s for factory UI steady-state...\n");
    sleep(10);

    LOG("\n========== /proc/devices ==========\n");
    dump_file("/proc/devices", 8192);

    LOG("\n========== /proc/iomem ==========\n");
    dump_file("/proc/iomem", 8192);

    LOG("\n========== /proc/modules ==========\n");
    dump_file("/proc/modules", 8192);

    LOG("\n========== /proc/interrupts ==========\n");
    dump_file("/proc/interrupts", 8192);

    LOG("\n========== /sys/class/drm listing ==========\n");
    DIR *d = opendir("/sys/class/drm");
    if (d) {
        struct dirent *e;
        while ((e = readdir(d))) {
            if (e->d_name[0] != '.') LOG("  %s\n", e->d_name);
        }
        closedir(d);
    }

    /* Useful /sys/class/drm/card0 entries */
    const char *drm_files[] = {
        "/sys/class/drm/card0/dev",
        "/sys/class/drm/card0/uevent",
        "/sys/class/drm/card0/device/uevent",
        "/sys/class/drm/card0/device/modalias",
        "/sys/class/drm/card0/device/vendor",
        "/sys/class/drm/card0/device/device",
        "/sys/class/drm/card0/device/resource",
        "/sys/class/drm/version",
        NULL
    };
    LOG("\n========== /sys/class/drm/card0/* contents ==========\n");
    for (int i = 0; drm_files[i]; i++) {
        LOG("--- %s ---\n", drm_files[i]);
        dump_file(drm_files[i], 2048);
    }

    LOG("\n========== /dev listing (video/dri/v2g/fb only) ==========\n");
    d = opendir("/dev");
    if (d) {
        struct dirent *e;
        while ((e = readdir(d))) {
            if (strstr(e->d_name, "video") || strstr(e->d_name, "v2g") ||
                strstr(e->d_name, "v4l") || strstr(e->d_name, "fb") ||
                strstr(e->d_name, "drm") || strstr(e->d_name, "dri")) {
                char p[128]; snprintf(p, sizeof(p), "/dev/%s", e->d_name);
                struct stat st;
                if (stat(p, &st) == 0) {
                    LOG("  %s mode=%o uid=%d gid=%d major=%u minor=%u\n",
                        e->d_name, st.st_mode & 0777, st.st_uid, st.st_gid,
                        (unsigned)((st.st_rdev >> 8) & 0xff),
                        (unsigned)(st.st_rdev & 0xff));
                }
            }
        }
        closedir(d);
    }
    /* /dev/dri is a subdir on modern systems */
    d = opendir("/dev/dri");
    if (d) {
        struct dirent *e;
        LOG("  /dev/dri/ contents:\n");
        while ((e = readdir(d))) {
            if (e->d_name[0] != '.') {
                char p[128]; snprintf(p, sizeof(p), "/dev/dri/%s", e->d_name);
                struct stat st;
                if (stat(p, &st) == 0) {
                    LOG("    %s mode=%o major=%u minor=%u\n", e->d_name,
                        st.st_mode & 0777,
                        (unsigned)((st.st_rdev >> 8) & 0xff),
                        (unsigned)(st.st_rdev & 0xff));
                }
            }
        }
        closedir(d);
    }

    /* Scan /proc for all PIDs, dump details for targets */
    LOG("\n========== Process scan (target processes only) ==========\n");
    d = opendir("/proc");
    if (d) {
        struct dirent *e;
        while ((e = readdir(d))) {
            if (e->d_name[0] < '1' || e->d_name[0] > '9') continue;
            int pid = atoi(e->d_name);
            if (pid <= 0) continue;
            char comm[64];
            if (read_comm(pid, comm, sizeof(comm)) != 0) continue;
            if (target_match(comm))
                dump_process(pid, comm);
        }
        closedir(d);
    }

    /* Also find ANY pid that has /dev/dri/card0 or /dev/video0 or /dev/v2gbridge open */
    LOG("\n========== Processes holding /dev/dri, /dev/video*, /dev/v2g* open ==========\n");
    d = opendir("/proc");
    if (d) {
        struct dirent *e;
        while ((e = readdir(d))) {
            if (e->d_name[0] < '1' || e->d_name[0] > '9') continue;
            int pid = atoi(e->d_name);
            if (pid <= 0) continue;
            char fdpath[64];
            snprintf(fdpath, sizeof(fdpath), "/proc/%d/fd", pid);
            DIR *fd_d = opendir(fdpath);
            if (!fd_d) continue;
            struct dirent *fe;
            int header_printed = 0;
            while ((fe = readdir(fd_d))) {
                if (fe->d_name[0] == '.') continue;
                char fp[128], tgt[256];
                snprintf(fp, sizeof(fp), "%s/%s", fdpath, fe->d_name);
                ssize_t n = readlink(fp, tgt, sizeof(tgt)-1);
                if (n <= 0) continue;
                tgt[n] = 0;
                if (strstr(tgt, "/dev/dri/") || strstr(tgt, "/dev/video") ||
                    strstr(tgt, "/dev/v2g") || strstr(tgt, "/dev/v4l") ||
                    strstr(tgt, "/dev/mem") || strstr(tgt, "/dev/fb")) {
                    if (!header_printed) {
                        char comm[64] = {0};
                        read_comm(pid, comm, sizeof(comm));
                        LOG("  pid=%d comm=%s\n", pid, comm);
                        header_printed = 1;
                    }
                    LOG("    fd %s -> %s\n", fe->d_name, tgt);
                }
            }
            closedir(fd_d);
        }
        closedir(d);
    }

    /* kmsg tail */
    LOG("\n========== /dev/kmsg tail (filter: v2g/emgd/drm/sprite/overlay/Plane) ==========\n");
    int kfd = open("/dev/kmsg", O_RDONLY | O_NONBLOCK);
    if (kfd >= 0) {
        char buf[4096];
        int captured = 0;
        for (int i = 0; i < 500 && captured < 8000; i++) {
            int n = read(kfd, buf, sizeof(buf)-1);
            if (n <= 0) break;
            buf[n] = 0;
            char *line = buf;
            while (line && *line) {
                char *next = strchr(line, '\n');
                if (next) *next++ = 0;
                if (strstr(line, "v2g") || strstr(line, "emgd") || strstr(line, "EMGD") ||
                    strstr(line, "drm") || strstr(line, "DRM") || strstr(line, "OVL") ||
                    strstr(line, "Sprite") || strstr(line, "sprite") || strstr(line, "Plane") ||
                    strstr(line, "plane") || strstr(line, "PVR") || strstr(line, "GMM") ||
                    strstr(line, "overlay") || strstr(line, "Overlay") ||
                    strstr(line, "video") || strstr(line, "v4l")) {
                    LOG("  %s\n", line);
                    captured += strlen(line);
                }
                line = next;
            }
        }
        close(kfd);
        if (captured == 0) LOG("  (no matching kmsg lines)\n");
    }

    LOG("\n=== DONE ===\n");
    fclose(flog);
    return 0;
}
