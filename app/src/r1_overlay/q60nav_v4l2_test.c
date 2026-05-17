/*
 * q60nav_v4l2_test.c — v4: comprehensive single-boot test battery.
 *
 * All unknowns resolved in one boot. Phases run sequentially, most
 * non-destructive first, DRM-master takeover last. Every phase captures
 * /dev/kmsg (unfiltered) so we get the kernel's own rejection messages.
 *
 * Phases:
 *  P0  Survey    — process list, emgdhmid FDs, /proc/pvr, /sys/module,
 *                  full kmsg dump to Q60_KMSG.LOG
 *  P1  Framebuf  — /dev/fb0 direct write (bypasses DRM entirely)
 *  P2  V4L2      — REQBUFS/QUERYBUF/STREAMON, log exact GTT offsets+dims
 *  P3  V2G cold  — DISABLE-first sweep (maybe factory already enabled V2G),
 *                  then ENABLE; try _IO/_IOR/_IOW/_IOWR, arg-as-integer
 *  P4  ALTER nm  — IGD_ALTER_OVL2 non-master, 5 struct layouts, then V2G;
 *                  NULL-pointer probe first (EFAULT=got past auth, else auth fails)
 *  P5  DRM notkill— DRM_SET_MASTER as root without killing anything
 *  P6  DRM kill  — kill hmictrl_proc + emgdhmid, SET_MASTER, GMM_ALLOC,
 *                  ALTER_OVL2, V2G_ENABLE
 *  P7  Final     — kmsg dump, respawn check
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
#include <sys/wait.h>
#include <sys/syscall.h>
#include <signal.h>
#include <dirent.h>
#include <errno.h>
#include <time.h>

/* ── ioctl numbers ──────────────────────────────────────────────────────── */
/* V4L2 */
#define VIDIOC_QUERYCAP  0x80685600u
#define VIDIOC_S_FMT     0xc0cc5605u
#define VIDIOC_REQBUFS   0xc0145608u
#define VIDIOC_QUERYBUF  0xc0445609u
#define VIDIOC_QBUF      0xc044560fu
#define VIDIOC_STREAMON  0x40045612u
#define VIDIOC_STREAMOFF 0x40045613u
#define V4L2_BUF_TYPE_VIDEO_CAPTURE 1
#define V4L2_MEMORY_MMAP            1
#define V4L2_FIELD_NONE             1
#define V4L2_PIX_FMT_YUYV  0x56595559u
#define V4L2_PIX_FMT_RGB16 0x50424752u  /* RGBP */

/* Framebuffer */
#define FBIOGET_VSCREENINFO 0x4600
#define FBIOPUT_VSCREENINFO 0x4601
#define FBIOGET_FSCREENINFO 0x4602
#define FBIO_WAITFORVSYNC   0x40044620u

/* DRM */
#define DRM_VERSION_IOCTL   0xc0246400u
#define DRM_GET_MAGIC_IOCTL 0x80046402u
#define DRM_SET_MASTER      0x0000641eu   /* _IO('d', 0x1e) */
#define DRM_DROP_MASTER     0x0000641fu   /* _IO('d', 0x1f) */

/* EMGD */
#define IGD_GMM_ALLOC_IOCTL 0xc014644eu
#define IGD_ALTER_OVL2      0xc0c8646fu  /* _IOWR('d', 0x6f, 200) */

/* v2gbridge — enable variants to try */
#define V2G_IOWR_4_0  0xc0047600u  /* _IOWR('v',0,4) — original guess */
#define V2G_IOW_4_0   0x40047600u  /* _IOW('v',0,4) */
#define V2G_IOR_4_0   0x80047600u  /* _IOR('v',0,4) */
#define V2G_IO_0      0x00007600u  /* _IO('v',0) — arg as integer */
#define V2G_IOWR_8_0  0xc0087600u  /* _IOWR('v',0,8) */
#define V2G_IOWR_4_1  0xc0047601u  /* _IOWR('v',1,4) */
#define V2G_IOW_4_1   0x40047601u  /* _IOW('v',1,4) */
#define V2G_IO_1      0x00007601u  /* _IO('v',1) */
/* ioctl cmd builder for 'v' type dynamic sweep */
#define V2G_MKIOWR(n,sz)  (0xc0000000u | (((sz)&0xff)<<16) | ('v'<<8) | (n))

/* ── structs ────────────────────────────────────────────────────────────── */
struct v4l2_pix_format {
    unsigned int width,height,pixelformat,field,bytesperline,sizeimage,colorspace,priv;
};
struct v4l2_format {
    unsigned int type;
    union { struct v4l2_pix_format pix; unsigned char raw[200]; } fmt;
};
struct v4l2_requestbuffers { unsigned int count,type,memory,reserved[2]; };
struct v4l2_timecode { unsigned int type,flags; unsigned char frames,seconds,minutes,hours,userbits[4]; };
struct v4l2_buffer {
    unsigned int index,type,bytesused,flags,field;
    struct { long tv_sec; long tv_usec; } timestamp;
    struct v4l2_timecode timecode;
    unsigned int sequence,memory;
    union { unsigned int offset; unsigned long userptr; int fd; } m;
    unsigned int length,input,reserved;
};
struct igd_gmm_alloc { int rtn; unsigned long offset,size; unsigned int type; unsigned long flags; };

/* fb_var_screeninfo — 160 bytes on 32-bit */
struct fb_var { unsigned int xres,yres,xres_v,yres_v,xoff,yoff,bpp,gray;
    unsigned int r_off,r_len,r_msb, g_off,g_len,g_msb, b_off,b_len,b_msb, a_off,a_len,a_msb;
    unsigned int nonstd,activate,height_mm,width_mm,accel;
    unsigned int pixclock,lmargin,rmargin,umargin,dmargin,hsync,vsync,sync,vmode,rotate;
    unsigned int reserved[5];
};
struct fb_fix { char id[16]; unsigned long smem_start; unsigned int smem_len;
    unsigned int type,type_aux,visual; unsigned short xpan,ypan,ywrap; unsigned int line;
    unsigned long mmio_start; unsigned int mmio_len,accel; unsigned short cap,reserved[3];
};

/* ── logging ────────────────────────────────────────────────────────────── */
/* Write to /tmp first (always writable). main() copies to /boot at the end.
 * run.sh redirect captures stdout (nothing useful there), but the real data
 * comes from these fopen paths. Do NOT write to /boot directly — run.sh's
 * cp would overwrite with empty stdout capture. */
#define LOG_PATH  "/tmp/Q60_R1_V4L2.LOG"
#define KMSG_PATH "/tmp/Q60_KMSG.LOG"
#define BOOT_LOG  "/boot/Q60_R1_V4L2.LOG"
#define BOOT_KMSG "/boot/Q60_KMSG.LOG"
static FILE *logf, *kmsgf;

#define LOG(fmt, ...) do { \
    if (logf) { fprintf(logf, fmt "\n", ##__VA_ARGS__); fflush(logf); } \
} while(0)

/*
 * kmsg_dump: reads kernel ring buffer via syslog(3,...) syscall.
 * This is what dmesg(1) uses — reads without consuming, works even if
 * syslogd has already drained /proc/kmsg.
 * On i386 Linux 2.6.37: NR_syslog=103, type=3 = SYSLOG_ACTION_READ_ALL.
 */
static void kmsg_dump(const char *label) {
    if (kmsgf) { fprintf(kmsgf, "\n=== KMSG @ %s ===\n", label); fflush(kmsgf); }

    char *buf = malloc(131072); /* 128 KB — typical ring buffer size */
    if (!buf) { LOG("  [kmsg] malloc failed"); return; }
    int n = syscall(103, 3, buf, 131071); /* syslog(SYSLOG_ACTION_READ_ALL) */
    if (n <= 0) {
        LOG("  [kmsg %s] syslog(3) returned %d errno=%d", label, n, errno);
        free(buf); return;
    }
    buf[n] = '\0';
    if (kmsgf) { fwrite(buf, 1, n, kmsgf); fprintf(kmsgf, "\n"); fflush(kmsgf); }

    /* echo interesting lines to main log */
    char *p = buf, *end = buf + n;
    int cnt = 0;
    while (p < end) {
        char *nl = memchr(p, '\n', end - p);
        int len = nl ? (int)(nl - p) : (int)(end - p);
        if (len > 0 && len < 512) {
            char line[512]; memcpy(line, p, len); line[len] = '\0';
            /* strip syslog priority prefix "<N>" */
            char *msg = (line[0]=='<') ? (strchr(line,'>')+1) : line;
            if (strstr(msg,"v2g")||strstr(msg,"V2G")||strstr(msg,"emgd")||strstr(msg,"EMGD")||
                strstr(msg,"ovl")||strstr(msg,"sprite")||strstr(msg,"drm")||strstr(msg,"DRM")||
                strstr(msg,"ioh")||strstr(msg,"IOH")||strstr(msg,"pvr")||strstr(msg,"bridge")||
                strstr(msg,"invalid")||strstr(msg,"INVALID")||strstr(msg,"error")||strstr(msg,"EINVAL"))
                LOG("  KMSG: %s", msg);
        }
        p = nl ? nl+1 : end;
        cnt++;
    }
    LOG("  [kmsg %s: %d lines total]", label, cnt);
    free(buf);
}

static int xi(int fd, unsigned long req, void *arg, const char *nm) {
    int r = ioctl(fd, req, arg);
    if (r < 0) LOG("  %-35s FAIL errno=%2d (%s)", nm, errno, strerror(errno));
    else        LOG("  %-35s OK   r=%d", nm, r);
    return r;
}

/* ── shared state ────────────────────────────────────────────────────────── */
static int g_vid=-1, g_drm=-1;
static unsigned int g_nbufs=0;
static void *g_buf[4]; static unsigned int g_blen[4], g_boff[4];
static unsigned int g_fmt_w=800, g_fmt_h=480, g_fmt_pitch=1600, g_fmt_sz=768000;

/* ══════════════════════════════════════════════════════════════════════════
 * P0 — Survey
 * ══════════════════════════════════════════════════════════════════════════ */
/* ── helpers ─────────────────────────────────────────────────────────────── */
static void cat_file(const char *path, int maxlines) {
    FILE *f=fopen(path,"r"); if(!f){LOG("  %s: absent (errno=%d)",path,errno);return;}
    char line[256]; int n=0;
    while(n<maxlines && fgets(line,sizeof(line),f)){
        int l=strlen(line); while(l>0&&(line[l-1]=='\n'||line[l-1]=='\r')) line[--l]='\0';
        LOG("  %s",line); n++;
    }
    if(!feof(f)) LOG("  [... truncated at %d lines]",maxlines);
    fclose(f);
}

static void read_sysdir_params(const char *dir) {
    DIR *d=opendir(dir); if(!d) return;
    struct dirent *e;
    while((e=readdir(d))){
        if(e->d_name[0]=='.') continue;
        char p[256]; snprintf(p,sizeof(p),"%s/%s",dir,e->d_name);
        FILE *f=fopen(p,"r"); if(!f) continue;
        char v[128]={0}; fgets(v,127,f); fclose(f);
        int l=strlen(v); while(l>0&&(v[l-1]=='\n'||v[l-1]==' ')) v[--l]='\0';
        LOG("    %-30s = %s",e->d_name,v);
    }
    closedir(d);
}

/* Deep-inspect a specific PID: cmdline, status caps, maps, fd list */
static void inspect_pid(const char *pidstr) {
    LOG("  --- pid %s ---", pidstr);

    /* cmdline */
    char path[128]; snprintf(path,sizeof(path),"/proc/%s/cmdline",pidstr);
    int fd=open(path,O_RDONLY); if(fd>=0){
        char buf[512]={0}; int n=read(fd,buf,511); close(fd);
        if(n>0){
            /* NUL-separated args — replace NUL with space */
            for(int i=0;i<n-1;i++) if(buf[i]=='\0') buf[i]=' ';
            LOG("  cmdline: %s",buf);
        }
    }

    /* status — state, ppid, vmrss, cap */
    snprintf(path,sizeof(path),"/proc/%s/status",pidstr);
    FILE *f=fopen(path,"r"); if(f){
        char line[128]; int n=0;
        while(n<30 && fgets(line,sizeof(line),f)){
            int l=strlen(line); while(l>0&&(line[l-1]=='\n'||line[l-1]=='\r')) line[--l]='\0';
            if(strstr(line,"State")||strstr(line,"PPid")||strstr(line,"VmRSS")||
               strstr(line,"VmPeak")||strstr(line,"Cap")||strstr(line,"Threads"))
                LOG("  status: %s",line);
            n++;
        }
        fclose(f);
    }

    /* maps — first 40 lines to find device mappings */
    snprintf(path,sizeof(path),"/proc/%s/maps",pidstr);
    f=fopen(path,"r"); if(f){
        char line[256]; int n=0;
        LOG("  maps (first 40 lines):");
        while(n<40 && fgets(line,sizeof(line),f)){
            int l=strlen(line); while(l>0&&(line[l-1]=='\n'||line[l-1]=='\r')) line[--l]='\0';
            LOG("    %s",line); n++;
        }
        if(!feof(f)) LOG("    [...maps truncated]");
        fclose(f);
    }

    /* fd symlinks — what files/devices are open */
    snprintf(path,sizeof(path),"/proc/%s/fd",pidstr);
    DIR *d=opendir(path); if(d){
        struct dirent *e;
        LOG("  open fds:");
        while((e=readdir(d))){
            if(e->d_name[0]=='.') continue;
            char lpath[128],target[256]={0};
            snprintf(lpath,sizeof(lpath),"%s/%s",path,e->d_name);
            int n=readlink(lpath,target,255);
            if(n>0){ target[n]='\0'; LOG("    fd%-4s -> %s",e->d_name,target); }
        }
        closedir(d);
    }
}

/* ── P0: comprehensive boot survey ─────────────────────────────────────── */
static void p0_survey(void) {
    LOG("\n══ P0: BOOT SURVEY ═════════════════════════════════════════════");

    /* ── 1. kernel boot info ── */
    LOG("--- /proc/uptime ---");
    cat_file("/proc/uptime",2);

    LOG("--- /proc/cmdline ---");
    cat_file("/proc/cmdline",2);

    LOG("--- printk log levels (/proc/sys/kernel/printk) ---");
    cat_file("/proc/sys/kernel/printk",2);
    LOG("  (format: console_loglevel default_msg_loglevel min_console_loglevel default_console_loglevel)");

    LOG("--- dmesg_restrict (/proc/sys/kernel/dmesg_restrict) ---");
    cat_file("/proc/sys/kernel/dmesg_restrict",1);

    /* ── 2. full process list with cmdline ── */
    LOG("--- process list (pid | comm | ppid | cmdline) ---");
    DIR *pd=opendir("/proc");
    if(pd){
        struct dirent *pe;
        while((pe=readdir(pd))){
            if(pe->d_name[0]<'1'||pe->d_name[0]>'9') continue;
            char comm[64]={0},cmdl[256]={0},ppid[16]={0};
            char p[128];
            snprintf(p,sizeof(p),"/proc/%s/comm",pe->d_name);
            FILE *f=fopen(p,"r"); if(f){fgets(comm,63,f);fclose(f);}
            int l=strlen(comm); while(l>0&&comm[l-1]=='\n') comm[--l]='\0';
            /* ppid from status */
            snprintf(p,sizeof(p),"/proc/%s/status",pe->d_name);
            f=fopen(p,"r"); if(f){
                char line[64]; while(fgets(line,64,f))
                    if(strncmp(line,"PPid:",5)==0){sscanf(line,"PPid:%s",ppid);break;}
                fclose(f);
            }
            /* cmdline */
            snprintf(p,sizeof(p),"/proc/%s/cmdline",pe->d_name);
            int fd=open(p,O_RDONLY); if(fd>=0){
                int n=read(fd,cmdl,255); close(fd);
                if(n>0){for(int i=0;i<n-1;i++) if(cmdl[i]=='\0') cmdl[i]=' ';}
            }
            LOG("  %-6s %-20s ppid=%-6s %s",pe->d_name,comm,ppid,cmdl);
        }
        closedir(pd);
    }

    /* ── 3. which pids own key devices ── */
    LOG("--- device ownership ---");
    struct { const char *path; dev_t rdev; } devs[8]={0};
    const char *devpaths[]={"/dev/dri/card0","/dev/video0","/dev/v2gbridge",
                            "/dev/fb0","/dev/fb1",NULL};
    int ndevs=0;
    for(int i=0;devpaths[i]&&ndevs<8;i++){
        struct stat s={0};
        if(stat(devpaths[i],&s)==0){devs[ndevs].path=devpaths[i];devs[ndevs].rdev=s.st_rdev;ndevs++;}
    }
    pd=opendir("/proc");
    if(pd){
        struct dirent *pe;
        while((pe=readdir(pd))){
            if(pe->d_name[0]<'1'||pe->d_name[0]>'9') continue;
            char comm[32]={0},p[128];
            snprintf(p,sizeof(p),"/proc/%s/comm",pe->d_name);
            FILE *f=fopen(p,"r"); if(f){fgets(comm,31,f);fclose(f);}
            int l=strlen(comm); while(l>0&&comm[l-1]=='\n') comm[--l]='\0';
            snprintf(p,sizeof(p),"/proc/%s/fd",pe->d_name);
            DIR *d=opendir(p); if(!d) continue;
            struct dirent *fe;
            while((fe=readdir(d))){
                if(fe->d_name[0]=='.') continue;
                char lp[256]; snprintf(lp,sizeof(lp),"%s/%s",p,fe->d_name);
                struct stat fst={0};
                if(stat(lp,&fst)!=0||!S_ISCHR(fst.st_mode)) continue;
                for(int i=0;i<ndevs;i++)
                    if(fst.st_rdev==devs[i].rdev)
                        LOG("  pid=%-6s %-20s has %s (fd %s)",
                            pe->d_name,comm,devs[i].path,fe->d_name);
            }
            closedir(d);
        }
        closedir(pd);
    }

    /* ── 4. deep-inspect hmictrl_proc / emgdhmid ── */
    LOG("--- deep process inspection ---");
    const char *targets[]={"hmictrl_proc","emgdhmid","hmictrl","android_hmi","camera_ps","camera","stage0_v2g",NULL};
    pd=opendir("/proc");
    if(pd){
        struct dirent *pe;
        while((pe=readdir(pd))){
            if(pe->d_name[0]<'1'||pe->d_name[0]>'9') continue;
            char comm[64]={0},p[128];
            snprintf(p,sizeof(p),"/proc/%s/comm",pe->d_name);
            FILE *f=fopen(p,"r"); if(f){fgets(comm,63,f);fclose(f);}
            int l=strlen(comm); while(l>0&&comm[l-1]=='\n') comm[--l]='\0';
            for(int i=0;targets[i];i++)
                if(strcmp(comm,targets[i])==0){ inspect_pid(pe->d_name); break; }
        }
        closedir(pd);
    }

    /* ── 5. kernel modules ── */
    LOG("--- loaded kernel modules (/sys/module) ---");
    DIR *md=opendir("/sys/module");
    if(md){
        struct dirent *me;
        while((me=readdir(md))){
            if(me->d_name[0]=='.') continue;
            char ver[64]={0},ref[16]={0},p[256];
            snprintf(p,sizeof(p),"/sys/module/%s/version",me->d_name);
            FILE *f=fopen(p,"r"); if(f){fgets(ver,63,f);fclose(f);}
            int l=strlen(ver); while(l>0&&ver[l-1]=='\n') ver[--l]='\0';
            snprintf(p,sizeof(p),"/sys/module/%s/refcnt",me->d_name);
            f=fopen(p,"r"); if(f){fgets(ref,15,f);fclose(f);}
            l=strlen(ref); while(l>0&&ref[l-1]=='\n') ref[--l]='\0';
            LOG("  %-25s refcnt=%-3s %s",me->d_name,ref,ver);
        }
        closedir(md);
    }

    /* emgd + v2gbridge module parameters */
    LOG("--- /sys/module/emgd/parameters ---");
    read_sysdir_params("/sys/module/emgd/parameters");
    LOG("--- /sys/module/v2gbridge/parameters ---");
    read_sysdir_params("/sys/module/v2gbridge/parameters");

    /* ── 6. /proc/iomem — IOH-GTT location ── */
    LOG("--- /proc/iomem (all) ---");
    cat_file("/proc/iomem",80);

    /* ── 7. /proc/interrupts — active IRQs ── */
    LOG("--- /proc/interrupts (first 30) ---");
    cat_file("/proc/interrupts",30);

    /* ── 8. PCI devices ── */
    LOG("--- PCI devices (/sys/bus/pci/devices) ---");
    DIR *pci=opendir("/sys/bus/pci/devices");
    if(pci){
        struct dirent *pe;
        while((pe=readdir(pci))){
            if(pe->d_name[0]=='.') continue;
            char ven[16]={0},dev[16]={0},cls[16]={0},drv[128]={0},p[256];
            snprintf(p,sizeof(p),"/sys/bus/pci/devices/%s/vendor",pe->d_name);
            FILE *f=fopen(p,"r"); if(f){fgets(ven,15,f);fclose(f);}
            snprintf(p,sizeof(p),"/sys/bus/pci/devices/%s/device",pe->d_name);
            f=fopen(p,"r"); if(f){fgets(dev,15,f);fclose(f);}
            snprintf(p,sizeof(p),"/sys/bus/pci/devices/%s/class",pe->d_name);
            f=fopen(p,"r"); if(f){fgets(cls,15,f);fclose(f);}
            int l;
            l=strlen(ven);while(l>0&&ven[l-1]=='\n')ven[--l]='\0';
            l=strlen(dev);while(l>0&&dev[l-1]=='\n')dev[--l]='\0';
            l=strlen(cls);while(l>0&&cls[l-1]=='\n')cls[--l]='\0';
            snprintf(p,sizeof(p),"/sys/bus/pci/devices/%s/driver",pe->d_name);
            int n=readlink(p,drv,127); if(n>0){drv[n]='\0';}
            LOG("  %s vendor=%s dev=%s class=%s driver=%s",pe->d_name,ven,dev,cls,drv);
        }
        closedir(pci);
    } else LOG("  absent errno=%d",errno);

    /* ── 9. /sys/class/drm deep ── */
    LOG("--- /sys/class/drm (deep) ---");
    DIR *dd=opendir("/sys/class/drm");
    if(dd){
        struct dirent *de;
        while((de=readdir(dd))){
            if(de->d_name[0]=='.') continue;
            char p[256]; snprintf(p,sizeof(p),"/sys/class/drm/%s",de->d_name);
            LOG("  %s:",de->d_name);
            /* read key files */
            const char *drm_files[]={"enabled","status","dpms","modes",NULL};
            for(int i=0;drm_files[i];i++){
                char fp[300]; snprintf(fp,sizeof(fp),"%s/%s",p,drm_files[i]);
                FILE *f=fopen(fp,"r"); if(!f) continue;
                char v[128]={0}; fgets(v,127,f); fclose(f);
                int l=strlen(v); while(l>0&&v[l-1]=='\n') v[--l]='\0';
                LOG("    %-10s = %s",drm_files[i],v);
            }
        }
        closedir(dd);
    }

    /* ── 10. /sys/class/video4linux ── */
    LOG("--- /sys/class/video4linux ---");
    DIR *vd=opendir("/sys/class/video4linux");
    if(vd){
        struct dirent *ve;
        while((ve=readdir(vd))){
            if(ve->d_name[0]=='.') continue;
            char p[256]; snprintf(p,sizeof(p),"/sys/class/video4linux/%s",ve->d_name);
            LOG("  %s:",ve->d_name);
            const char *vf[]={"name","index","dev",NULL};
            for(int i=0;vf[i];i++){
                char fp[300]; snprintf(fp,sizeof(fp),"%s/%s",p,vf[i]);
                FILE *f=fopen(fp,"r"); if(!f) continue;
                char v[128]={0}; fgets(v,127,f); fclose(f);
                int l=strlen(v); while(l>0&&v[l-1]=='\n') v[--l]='\0';
                LOG("    %-10s = %s",vf[i],v);
            }
        }
        closedir(vd);
    } else LOG("  absent errno=%d",errno);

    /* ── 11. systemd service state ── */
    LOG("--- /etc/systemd/system (unit files) ---");
    DIR *sd=opendir("/etc/systemd/system");
    if(sd){
        struct dirent *se; while((se=readdir(sd)))
            if(se->d_name[0]!='.') LOG("  %s",se->d_name);
        closedir(sd);
    }
    LOG("--- /etc/systemd/system/multi-user.target.wants ---");
    sd=opendir("/etc/systemd/system/multi-user.target.wants");
    if(sd){
        struct dirent *se; while((se=readdir(sd))){
            if(se->d_name[0]=='.') continue;
            char p[256],t[256]={0};
            snprintf(p,sizeof(p),"/etc/systemd/system/multi-user.target.wants/%s",se->d_name);
            int n=readlink(p,t,255); if(n>0) t[n]='\0';
            LOG("  %s -> %s",se->d_name,t);
        }
        closedir(sd);
    }

    /* systemd runtime state */
    LOG("--- /run/systemd/units (runtime unit states) ---");
    DIR *ru=opendir("/run/systemd/units");
    if(ru){
        struct dirent *re; int n=0;
        while((re=readdir(ru))&&n<60){
            if(re->d_name[0]!='.'){LOG("  %s",re->d_name);n++;}
        }
        closedir(ru);
    } else {
        LOG("  /run/systemd/units absent — trying /run/systemd/");
        ru=opendir("/run/systemd");
        if(ru){struct dirent *re;while((re=readdir(ru)))
            if(re->d_name[0]!='.') LOG("  %s",re->d_name);
            closedir(ru);}
    }

    /* ── 12. /proc/pvr full content ── */
    LOG("--- /proc/pvr ---");
    DIR *pvrd=opendir("/proc/pvr");
    if(pvrd){
        struct dirent *pe;
        while((pe=readdir(pvrd))){
            if(pe->d_name[0]=='.') continue;
            char p[128]; snprintf(p,sizeof(p),"/proc/pvr/%s",pe->d_name);
            LOG("  %s:",pe->d_name);
            cat_file(p,20);
        }
        closedir(pvrd);
    } else LOG("  /proc/pvr absent errno=%d",errno);

    /* ── 13. /proc/driver ── */
    LOG("--- /proc/driver ---");
    DIR *drvd=opendir("/proc/driver");
    if(drvd){
        struct dirent *de;
        while((de=readdir(drvd))){
            if(de->d_name[0]=='.') continue;
            char p[128]; snprintf(p,sizeof(p),"/proc/driver/%s",de->d_name);
            LOG("  %s:",de->d_name); cat_file(p,10);
        }
        closedir(drvd);
    } else LOG("  absent errno=%d",errno);

    /* ── 14. debugfs (DRM debug) ── */
    LOG("--- /sys/kernel/debug/dri ---");
    struct stat dbg={0};
    if(stat("/sys/kernel/debug/dri",&dbg)==0){
        DIR *dd2=opendir("/sys/kernel/debug/dri");
        if(dd2){struct dirent *de;while((de=readdir(dd2)))
            if(de->d_name[0]!='.') LOG("  %s",de->d_name);
            closedir(dd2);}
        /* read emgd debug entries if present */
        const char *dbgf[]={"/sys/kernel/debug/dri/0/name",
                            "/sys/kernel/debug/dri/0/clients",
                            "/sys/kernel/debug/dri/0/mm",NULL};
        for(int i=0;dbgf[i];i++){LOG("  %s:",dbgf[i]);cat_file(dbgf[i],20);}
    } else LOG("  absent (errno=%d) — debugfs not mounted",errno);

    /* ── 15. /dev full listing (all char/block devices) ── */
    LOG("--- /dev interesting devices ---");
    DIR *devd=opendir("/dev");
    if(devd){
        struct dirent *de;
        while((de=readdir(devd))){
            if(de->d_name[0]=='.') continue;
            char p[128]; snprintf(p,sizeof(p),"/dev/%s",de->d_name);
            struct stat s={0}; if(stat(p,&s)!=0) continue;
            if(S_ISCHR(s.st_mode)||S_ISBLK(s.st_mode)){
                unsigned maj=(unsigned)((s.st_rdev>>8)&0xff);
                unsigned min=(unsigned)(s.st_rdev&0xff);
                if(maj==10||maj==29||maj==81||maj==226||  /* misc,fb,video,drm */
                   strstr(de->d_name,"pvr")||strstr(de->d_name,"v2g")||
                   strstr(de->d_name,"ioh")||strstr(de->d_name,"emgd")||
                   strstr(de->d_name,"dri")||strstr(de->d_name,"mmcblk"))
                    LOG("  %-20s mode=0%o maj=%u min=%u",
                        de->d_name,(unsigned)s.st_mode,maj,min);
            }
        }
        closedir(devd);
    }

    /* ── 16. android-mount.sh full content ── */
    LOG("--- /sbin/android-mount.sh (first 80 lines) ---");
    cat_file("/sbin/android-mount.sh",80);

    kmsg_dump("P0-baseline");
}

/* ══════════════════════════════════════════════════════════════════════════
 * P1 — Framebuffer direct write
 * ══════════════════════════════════════════════════════════════════════════ */
static void p1_fbdev(void) {
    LOG("\n══ P1: FRAMEBUFFER ═════════════════════════════════════════════");
    for (int i=0; i<2; i++) {
        char p[16]; snprintf(p,sizeof(p),"/dev/fb%d",i);
        int fd=open(p,O_RDWR);
        LOG("  open %s: fd=%d errno=%d",p,fd,fd<0?errno:0);
        if (fd<0) continue;

        struct fb_var vinfo={0};
        if (xi(fd,FBIOGET_VSCREENINFO,&vinfo,"GET_VSCREENINFO")==0)
            LOG("    %ux%u bpp=%u",vinfo.xres,vinfo.yres,vinfo.bpp);

        struct fb_fix finfo={0};
        if (xi(fd,FBIOGET_FSCREENINFO,&finfo,"GET_FSCREENINFO")==0)
            LOG("    smem_len=%u line=%u",finfo.smem_len,finfo.line);

        unsigned int fbsz = finfo.smem_len ? finfo.smem_len : 800*480*4;
        void *fb=mmap(NULL,fbsz,PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);
        LOG("    mmap %u bytes: %s ptr=%p",fbsz,fb==MAP_FAILED?"FAIL":"OK",fb);
        if (fb!=MAP_FAILED) {
            /* save first 64 bytes for restore */
            unsigned char save[64]; memcpy(save,fb,64);
            /* write solid red: RGB32 = 0x00FF0000, RGB16 = 0xF800 */
            if (vinfo.bpp==16) {
                unsigned short *p16=(unsigned short*)fb;
                for (unsigned j=0; j<fbsz/2; j++) p16[j]=0xF800;
            } else {
                unsigned int *p32=(unsigned int*)fb;
                for (unsigned j=0; j<fbsz/4; j++) p32[j]=0x00FF0000;
            }
            LOG("    wrote red pattern (%u bpp) — sleeping 3s", vinfo.bpp);
            sleep(3);
            /* restore */
            memcpy(fb,save,64);
            munmap(fb,fbsz);
        }
        close(fd);
    }
}

/* ══════════════════════════════════════════════════════════════════════════
 * P2 — V4L2 setup (kept open for P3/P4/P5/P6)
 * ══════════════════════════════════════════════════════════════════════════ */
static int p2_v4l2(void) {
    LOG("\n══ P2: V4L2 SETUP ══════════════════════════════════════════════");
    g_vid=open("/dev/video0",O_RDWR);
    LOG("  open /dev/video0: fd=%d errno=%d",g_vid,g_vid<0?errno:0);
    if (g_vid<0) return -1;

    /* S_FMT — log what kernel actually accepts */
    struct v4l2_format fmt={0};
    fmt.type=V4L2_BUF_TYPE_VIDEO_CAPTURE;
    fmt.fmt.pix.width=800; fmt.fmt.pix.height=480;
    fmt.fmt.pix.pixelformat=V4L2_PIX_FMT_YUYV;
    fmt.fmt.pix.field=V4L2_FIELD_NONE;
    xi(g_vid,VIDIOC_S_FMT,&fmt,"S_FMT 800x480 YUYV");
    g_fmt_w=fmt.fmt.pix.width; g_fmt_h=fmt.fmt.pix.height;
    g_fmt_pitch=fmt.fmt.pix.bytesperline; g_fmt_sz=fmt.fmt.pix.sizeimage;
    LOG("  kernel accepted: %ux%u pitch=%u sz=%u pf=0x%08x",
        g_fmt_w,g_fmt_h,g_fmt_pitch,g_fmt_sz,fmt.fmt.pix.pixelformat);

    /* REQBUFS */
    struct v4l2_requestbuffers req={.count=3,.type=V4L2_BUF_TYPE_VIDEO_CAPTURE,.memory=V4L2_MEMORY_MMAP};
    if (xi(g_vid,VIDIOC_REQBUFS,&req,"REQBUFS 3")<0) return -1;
    g_nbufs=req.count;
    LOG("  %u buffers granted",g_nbufs);

    /* QUERYBUF + mmap + fill + QBUF */
    for (unsigned i=0; i<g_nbufs && i<4; i++) {
        struct v4l2_buffer buf={.index=i,.type=V4L2_BUF_TYPE_VIDEO_CAPTURE,.memory=V4L2_MEMORY_MMAP};
        if (xi(g_vid,VIDIOC_QUERYBUF,&buf,"QUERYBUF")<0) continue;
        g_boff[i]=buf.m.offset; g_blen[i]=buf.length;
        LOG("  buf[%u] offset=0x%06x length=%u",i,g_boff[i],g_blen[i]);
        g_buf[i]=mmap(NULL,buf.length,PROT_READ|PROT_WRITE,MAP_SHARED,g_vid,buf.m.offset);
        if (g_buf[i]==MAP_FAILED){LOG("  mmap[%u] FAILED",i);g_buf[i]=NULL;continue;}
        /* fill YUYV red: Y=0xFF U=0x80 Y=0xFF V=0xFF */
        unsigned char *p=g_buf[i];
        for (unsigned j=0; j+3<buf.length; j+=4){p[j]=0xFF;p[j+1]=0x80;p[j+2]=0xFF;p[j+3]=0xFF;}
        struct v4l2_buffer qb={.index=i,.type=V4L2_BUF_TYPE_VIDEO_CAPTURE,.memory=V4L2_MEMORY_MMAP};
        xi(g_vid,VIDIOC_QBUF,&qb,"QBUF");
    }

    int btype=V4L2_BUF_TYPE_VIDEO_CAPTURE;
    xi(g_vid,VIDIOC_STREAMON,&btype,"STREAMON");
    kmsg_dump("P2-after-STREAMON");
    return 0;
}

/* ══════════════════════════════════════════════════════════════════════════
 * P3 — V2G sweep: disable-first + ioctl format variants
 * ══════════════════════════════════════════════════════════════════════════ */
static void p3_v2g_sweep(void) {
    LOG("\n══ P3: V2G IOCTL SWEEP ═════════════════════════════════════════");
    int v2g=open("/dev/v2gbridge",O_RDWR);
    LOG("  open /dev/v2gbridge: fd=%d errno=%d",v2g,v2g<0?errno:0);
    if (v2g<0) return;

    /* --- sub-phase A: DISABLE first (maybe factory left it enabled) --- */
    LOG("  [A] DISABLE-first sweep");
    struct { unsigned long cmd; const char *name; } dis_cmds[] = {
        {V2G_IOWR_4_1, "_IOWR('v',1,4)"},
        {V2G_IOW_4_1,  "_IOW('v',1,4)"},
        {V2G_IO_1,     "_IO('v',1)"},
        {V2G_IOWR_4_0, "_IOWR('v',0,4) arg=0"},
        {0,NULL}
    };
    unsigned int zero=0;
    for (int i=0; dis_cmds[i].cmd; i++) {
        unsigned int a=0;
        int r=(dis_cmds[i].cmd==V2G_IO_1)
            ? ioctl(v2g,dis_cmds[i].cmd,0)
            : ioctl(v2g,dis_cmds[i].cmd,&a);
        LOG("    DISABLE %s → r=%d errno=%d", dis_cmds[i].name, r, errno);
    }
    kmsg_dump("P3-after-DISABLE-sweep");

    /* --- sub-phase B: ENABLE format sweep --- */
    LOG("  [B] ENABLE ioctl-format sweep (all direction/size variants)");
    struct { unsigned long cmd; int use_int; const char *name; } cmds[] = {
        {V2G_IOWR_4_0, 0, "_IOWR('v',0,4) &{1,1}"},
        {V2G_IOW_4_0,  0, "_IOW('v',0,4)  &{1,1}"},
        {V2G_IOR_4_0,  0, "_IOR('v',0,4)  &{1,1}"},
        {V2G_IO_0,     1, "_IO('v',0)     val=1   (legacy int arg)"},
        {V2G_IO_0,     1, "_IO('v',0)     val=0x00010001"},
        {V2G_IOWR_8_0, 0, "_IOWR('v',0,8) &{1,1,0,0}"},
        {V2G_IOWR_4_0, 0, "_IOWR('v',0,4) NULL ptr"},
        {0,0,NULL}
    };
    unsigned long long arg8 = 0x0000000100000001ULL;
    unsigned int args[] = {0x00010001, 0x00010001, 0x00010001, 1, 0x00010001, 0,0};
    int use_nulls[] = {0,0,0,0,0,0,1,0};
    int i=0;
    for (; cmds[i].cmd; i++) {
        int r;
        if (use_nulls[i])
            r = ioctl(v2g, cmds[i].cmd, 0);
        else if (cmds[i].use_int)
            r = ioctl(v2g, cmds[i].cmd, (unsigned long)(cmds[i].cmd==V2G_IO_0 && args[i]==1 ? 1 : 0x00010001));
        else if (cmds[i].cmd==V2G_IOWR_8_0)
            r = ioctl(v2g, cmds[i].cmd, &arg8);
        else {
            unsigned int a=args[i];
            r = ioctl(v2g, cmds[i].cmd, &a);
        }
        LOG("    %-42s → r=%d errno=%d", cmds[i].name, r, errno);
        kmsg_dump("P3-V2G-ENABLE");
        if (r==0) {
            LOG("  *** P3 SUCCESS *** sleeping 10s, watch LCD");
            sleep(10);
            unsigned int z=0; ioctl(v2g,V2G_IOWR_4_1,&z);
            goto p3_done;
        }
    }
    /* also try ENABLE with arg = value of a currently-valid overlay handle */
    LOG("  [C] ENABLE with arg=2..8 (probe overlay handles)");
    for (unsigned int h=0; h<=8; h++) {
        unsigned int a=h;
        int r=ioctl(v2g,V2G_IOWR_4_0,&a);
        LOG("    arg=0x%x → r=%d errno=%d", h, r, errno);
        if (r==0) {
            LOG("  *** P3 SUCCESS handle=%u ***", h);
            sleep(10);
            a=0; ioctl(v2g,V2G_IOWR_4_1,&a);
            goto p3_done;
        }
    }
p3_done:
    close(v2g);
}

/* ══════════════════════════════════════════════════════════════════════════
 * P4 — ALTER_OVL2 non-master: 5 struct layouts, then V2G
 * ══════════════════════════════════════════════════════════════════════════ */
/* 200-byte raw struct — fill as 50 uint32s */
static void fill_ovl2(unsigned int *b, unsigned long surf_off,
    unsigned int surf_w, unsigned int surf_h, unsigned int pitch,
    unsigned int pixfmt, unsigned int flags,
    int dx1, int dy1, int dx2, int dy2, int sx1, int sy1, int sx2, int sy2,
    unsigned int display_h, unsigned int ovl_plane)
{
    memset(b,0,200);
    /* Layout variant: rtn | ovl_ctx | src_rect(x1y1x2y2) | dst_rect | surf fields */
    b[0]=0;           /* rtn (output) */
    b[1]=0;           /* ovl_context (0=new) */
    /* src rect: x1,y1,x2,y2 at [2..5] */
    b[2]=(unsigned)sx1; b[3]=(unsigned)sy1; b[4]=(unsigned)sx2; b[5]=(unsigned)sy2;
    /* dst rect: x1,y1,x2,y2 at [6..9] */
    b[6]=(unsigned)dx1; b[7]=(unsigned)dy1; b[8]=(unsigned)dx2; b[9]=(unsigned)dy2;
    /* surface at [10..] */
    b[10]=(unsigned)surf_off;  /* offset low 32 bits */
    b[11]=0;                   /* offset high 32 bits (if 64-bit) */
    b[12]=surf_w;
    b[13]=surf_h;
    b[14]=pitch;
    b[15]=pixfmt;
    b[16]=0; /* mip_count */
    b[17]=flags;
    /* display/overlay control */
    b[18]=display_h;
    b[19]=ovl_plane;
    b[20]=0xFF; /* alpha */
    b[21]=flags; /* command flags again */
    /* rest zeros */
}

/* v2g_try_enable: exhaustive V2G_ENABLE sweep.
 * Key insight from boot log: "GTT mapping requested for 0 buffers" — need real GTT offsets.
 * Valid planes are 3 (primary overlay) and 5 (Sprite C).
 * Returns 0 on first success, -1 on all failure. */
static int v2g_try_enable(const char *ctx) {
    int v2g=open("/dev/v2gbridge",O_RDWR);
    if (v2g<0) { LOG("  [%s] v2gbridge open failed",ctx); return -1; }
    int found=-1;

    /* --- A: direct integer, no pointer (emgdhmid calling convention) --- */
    /* plane bits 31:16, screen bits 15:0 — planes 3 and 5 valid per kmsg.
     * screen is EMGD port number: portorder=2,4,0,0,0 → port 2=LVDS, port 4=SDVO.
     * Try both 0-indexed (0,1) and port-number (2,4) forms. */
    static const unsigned int direct_vals[]={
        0x00050002, /* plane=5 Sprite C, screen=port 2 (LVDS) */
        0x00050004, /* plane=5 Sprite C, screen=port 4 (SDVO) */
        0x00050001, /* plane=5 screen=1 */
        0x00050000, /* plane=5 screen=0 */
        0x00030002, /* plane=3 primary, screen=port 2 */
        0x00030004, /* plane=3 primary, screen=port 4 */
        0x00030001, /* plane=3 screen=1 */
        0x00030000, /* plane=3 screen=0 */
        0x00020005, /* screen=port2 hi, plane=5 lo */
        0x00040005, /* screen=port4 hi, plane=5 lo */
        0x00010005, /* byteswap: low=1, high=5 */
        0x00010003, /* byteswap: low=1, high=3 */
        0
    };
    LOG("  [%s-A] direct-int plane/screen sweep:",ctx);
    for (int i=0; direct_vals[i] && found<0; i++) {
        int r=ioctl(v2g,V2G_IOWR_4_0,(unsigned long)direct_vals[i]);
        LOG("    0x%08x → r=%d errno=%d",direct_vals[i],r,errno);
        if (r==0) found=i;
    }

    /* --- B: struct pointer — {screen, n_bufs, gtt[3], buf_sz, src_w, src_h, dst} --- */
    /* screen field: try 0-indexed (0,1) AND EMGD port numbers (2=LVDS, 4=SDVO) */
    if (found<0 && g_nbufs>0) {
        static const int bscreens[]={0,1,2,4,-1};
        LOG("  [%s-B] struct L1 {screen,n_bufs,gtt,sz,w,h,dst}:",ctx);
        for (int si=0; bscreens[si]>=0 && found<0; si++) {
            int sc=bscreens[si];
            uint32_t s[16]={0};
            s[0]=(uint32_t)sc;    /* screen / port number */
            s[1]=g_nbufs;        /* n_bufs */
            s[2]=g_boff[0];
            s[3]=g_nbufs>1?g_boff[1]:0;
            s[4]=g_nbufs>2?g_boff[2]:0;
            s[5]=g_blen[0];      /* buf_sz */
            s[6]=g_fmt_w; s[7]=g_fmt_h;
            s[8]=0; s[9]=0; s[10]=g_fmt_w; s[11]=g_fmt_h; /* dst x,y,w,h */
            int r=ioctl(v2g,V2G_IOWR_4_0,s);
            LOG("    sc=%d n=%d gtt0=0x%x sz=%u → r=%d errno=%d",
                sc,g_nbufs,g_boff[0],g_blen[0],r,errno);
            if (r==0) found=100+si;
        }
    }

    /* --- C: struct L2 — {plane, screen, n_bufs, gtt[3], buf_sz, w, h, dst} --- */
    /* screen: 0-indexed (0,1) AND EMGD port numbers (2=LVDS, 4=SDVO) */
    if (found<0 && g_nbufs>0) {
        static const int planes[]={5,3,1,0,-1};
        static const int cscreens[]={0,1,2,4,-1};
        LOG("  [%s-C] struct L2 {plane,screen,n_bufs,gtt,sz,w,h,dst}:",ctx);
        for (int pi=0; planes[pi]>=0 && found<0; pi++) {
            for (int si=0; cscreens[si]>=0 && found<0; si++) {
                int sc=cscreens[si];
                uint32_t s[16]={0};
                s[0]=(uint32_t)planes[pi]; s[1]=(uint32_t)sc;
                s[2]=g_nbufs;
                s[3]=g_boff[0];
                s[4]=g_nbufs>1?g_boff[1]:0;
                s[5]=g_nbufs>2?g_boff[2]:0;
                s[6]=g_blen[0]; s[7]=g_fmt_w; s[8]=g_fmt_h;
                s[9]=0; s[10]=0; s[11]=g_fmt_w; s[12]=g_fmt_h;
                int r=ioctl(v2g,V2G_IOWR_4_0,s);
                LOG("    plane=%d sc=%d → r=%d errno=%d",planes[pi],sc,r,errno);
                if (r==0) found=200+pi*4+si;
            }
        }
    }

    /* --- D: 4-byte ptr sweep — covers emgdhmid's observed exact value and variants.
     * emgdhmid disassembly: arg = ptr→{uint16=1, uint16=1} = 0x00010001.
     * Also test all plausible {screen/port, plane} field combos. */
    if (found<0) {
        /* 0x00010001 is emgdhmid's confirmed value. Test it first. */
        static const uint32_t packed[]={
            0x00010001, /* emgdhmid exact: {1,1} — MUST test */
            0x00000001, /* {0,1} */
            0x00010000, /* {1,0} */
            0x00020001, /* port 2 (LVDS) + inner=1 */
            0x00040001, /* port 4 (SDVO) + inner=1 */
            0x00010002, /* inner=1 + port 2 */
            0x00010004, /* inner=1 + port 4 */
            0x00000005, /* {0, plane=5 Sprite C} */
            0x00010005, 0x00020005, 0x00040005,
            0x00000003, /* {0, plane=3 primary} */
            0x00010003, 0x00020003, 0x00040003,
            0x00050001, 0x00050002, 0x00050004,
            0x00030001, 0x00030002, 0x00030004,
            0x00000000  /* terminator (also tests all-zero) */
        };
        LOG("  [%s-D] 4-byte ptr sweep (emgdhmid value + variants):",ctx);
        for (int i=0; i<(int)(sizeof(packed)/sizeof(packed[0])) && found<0; i++) {
            uint32_t a=packed[i];
            int r=ioctl(v2g,V2G_IOWR_4_0,&a);
            LOG("    0x%08x → r=%d errno=%d",packed[i],r,errno);
            if (r==0) found=300+i;
        }
    }

    /* --- D2: same values via _IOW (write-only) cmd — driver may have been compiled
     * with _IOW, which has a different cmd number (0x40047600 vs 0xc0047600). --- */
    if (found<0) {
        static const unsigned long iow_cmd = 0x40047600u; /* _IOW('v',0,4) */
        static const uint32_t packed2[]={
            0x00010001, 0x00000005, 0x00010005, 0x00000003, 0x00010003,
            0x00020001, 0x00040001, 0x00050001, 0x00030001, 0};
        LOG("  [%s-D2] _IOW('v',0,4) cmd=0x%lx ptr sweep:",ctx,iow_cmd);
        for (int i=0; packed2[i] && found<0; i++) {
            uint32_t a=packed2[i];
            int r=ioctl(v2g,iow_cmd,&a);
            LOG("    0x%08x → r=%d errno=%d",packed2[i],r,errno);
            if (r==0) found=350+i;
        }
    }

    /* --- E: ioctl cmd size sweep — kernel may read N>4 bytes regardless of cmd encoding.
     * Try _IOWR('v',0,N) for N=8..32 with properly-sized structs containing GTT info. */
    if (found<0 && g_nbufs>0) {
        static const int sizes[]={8,12,16,20,24,32,-1};
        LOG("  [%s-E] ioctl size sweep (kernel ignores cmd size?):",ctx);
        for (int si=0; sizes[si]>0 && found<0; si++) {
            int sz=sizes[si]; int nw=sz/4;
            uint32_t s[8]={0};
            /* fill with most likely layout for each size */
            s[0]=1;           /* screen=1 (emgdhmid value) */
            s[1]=1;           /* plane or n_bufs */
            if (nw>2) s[2]=g_nbufs;
            if (nw>3) s[3]=g_boff[0];
            if (nw>4) s[4]=g_nbufs>1?g_boff[1]:0;
            if (nw>5) s[5]=g_blen[0];
            if (nw>6) s[6]=g_fmt_w;
            if (nw>7) s[7]=g_fmt_h;
            unsigned long cmd=(0xc0000000u|(((unsigned)sz&0xff)<<16)|('v'<<8)|0);
            int r=ioctl(v2g,cmd,s);
            LOG("    sz=%d cmd=0x%lx → r=%d errno=%d",sz,cmd,r,errno);
            if (r==0) found=400+si;
        }
    }

    /* --- F: V2G_DISPLAY_FRAME (v+2) with correct buf indices 0..g_nbufs-1.
     * Theory: calling DISPLAY_FRAME registers each IOH DMA buffer with the
     * v2g bridge, incrementing the count that enable_direct_display_tnc() checks.
     * After registering all buffers, retry V2G_ENABLE with confirmed layout. */
    if (found<0) {
        unsigned long df_cmd=V2G_MKIOWR(2,4); /* _IOWR('v',2,4) = DISPLAY_FRAME */
        LOG("  [%s-F] DISPLAY_FRAME(0..%u) then V2G_ENABLE retry:",ctx,
            g_nbufs>0?(g_nbufs-1):0);
        for (int bi=0; bi<(int)g_nbufs && bi<3; bi++) {
            uint32_t bidx=(uint32_t)bi;
            int dr=ioctl(v2g,df_cmd,&bidx);
            LOG("    DISPLAY_FRAME buf=%d -> r=%d errno=%d",bi,dr,errno);
        }
        /* retry ENABLE -- DISPLAY_FRAME may have primed the IOH DMA buffer count */
        static const uint32_t fe_pairs[][2]={
            {5,0},{5,1},{5,2},{5,4},
            {3,0},{3,1},{3,2},{3,4},
            {0,0}
        };
        for (int i=0; fe_pairs[i][0]!=0 && found<0; i++) {
            uint32_t s[2]={fe_pairs[i][0],fe_pairs[i][1]};
            int r=ioctl(v2g,V2G_IOWR_4_0,s);
            LOG("    ENABLE plane=%u sc=%u -> r=%d errno=%d",s[0],s[1],r,errno);
            if (r==0) found=500+i;
        }
        /* sweep v+3, v+4 -- any other undocumented cmds */
        for (int n=3; n<=4 && found<0; n++) {
            unsigned long cmd=V2G_MKIOWR(n,4);
            uint32_t a=1u;
            int r=ioctl(v2g,cmd,&a);
            LOG("    _IOWR('v',%d,4) a=1 -> r=%d errno=%d",n,r,errno);
            if (r==0) found=450+n;
        }
    }

    kmsg_dump(ctx);
    if (found>=0) {
        LOG("  *** [%s] V2G SUCCESS code=%d *** watching 10s",ctx,found);
        sleep(10);
    }
    uint32_t z=0; ioctl(v2g,V2G_IOWR_4_1,&z);
    close(v2g);
    return found>=0?0:-1;
}

static void p4_alter_nonmaster(void) {
    LOG("\n══ P4: ALTER_OVL2 NON-MASTER ═══════════════════════════════════");
    g_drm=open("/dev/dri/card0",O_RDWR);
    LOG("  open /dev/dri/card0: fd=%d errno=%d",g_drm,g_drm<0?errno:0);
    if (g_drm<0) return;

    /* Auth probe: NULL pointer → EFAULT if got past auth check, EACCES/EPERM if auth blocks first */
    LOG("  [null-ptr probe] ALTER_OVL2 arg=NULL");
    int r=ioctl(g_drm,IGD_ALTER_OVL2,0);
    LOG("  ALTER_OVL2(NULL) → r=%d errno=%d (%s)",r,errno,strerror(errno));
    kmsg_dump("P4-null-probe");
    /* EFAULT → kernel accepts the call and tries to copy → we passed auth */
    /* EACCES/EPERM/ENOTTY → auth or dispatch fails before copy → need master */
    LOG("  (EFAULT=got-past-auth, EACCES/EPERM=auth-fail, ENOTTY=no-such-ioctl)");

    unsigned int buf[50];

    /* Layout A: x,y,w,h rects; ovl_plane=1 (Sprite C); YUYV; V4L2 GTT offset */
    LOG("  [A] layout A: x,y,w,h rects, ovl_plane=1, YUYV, V4L2 gtts");
    {
        memset(buf,0,200);
        buf[0]=0; buf[1]=0;
        /* src x,y,w,h at [2..5] */
        buf[2]=0; buf[3]=0; buf[4]=g_fmt_w; buf[5]=g_fmt_h;
        /* dst x,y,w,h at [6..9] */
        buf[6]=0; buf[7]=0; buf[8]=g_fmt_w; buf[9]=g_fmt_h;
        buf[10]=(g_nbufs>0)?g_boff[0]:0;  /* V4L2 buf[0] GTT offset */
        buf[11]=0; buf[12]=g_fmt_w; buf[13]=g_fmt_h;
        buf[14]=g_fmt_pitch; buf[15]=V4L2_PIX_FMT_YUYV;
        buf[16]=0; buf[17]=1; /* flags=enable */
        buf[18]=0; buf[19]=1; /* display_h=0, ovl_plane=1=SpriteC */
        buf[20]=0xFF; buf[21]=1;
    }
    r=ioctl(g_drm,IGD_ALTER_OVL2,buf);
    LOG("  alter A: r=%d rtn=%d errno=%d",r,(int)buf[0],errno);
    kmsg_dump("P4-A"); v2g_try_enable("P4-A");

    /* Layout B: x1,y1,x2,y2 rects */
    LOG("  [B] layout B: x1,y1,x2,y2 rects");
    fill_ovl2(buf, g_nbufs>0?g_boff[0]:0,
        g_fmt_w,g_fmt_h,g_fmt_pitch, V4L2_PIX_FMT_YUYV, 1,
        0,0,g_fmt_w-1,g_fmt_h-1, 0,0,g_fmt_w-1,g_fmt_h-1, 0,1);
    r=ioctl(g_drm,IGD_ALTER_OVL2,buf);
    LOG("  alter B: r=%d rtn=%d errno=%d",r,(int)buf[0],errno);
    kmsg_dump("P4-B"); v2g_try_enable("P4-B");

    /* Layout C: surface struct first (igd_surface_t at [2]), then rects */
    LOG("  [C] layout C: igd_surface_t-first layout");
    {
        memset(buf,0,200);
        buf[0]=0; buf[1]=0;
        /* igd_surface_t at [2]: offset,w,h,pitch,pf,mip,flags,virt,base_off,u_off,v_off */
        buf[2]=(g_nbufs>0)?g_boff[0]:0; /* GTT offset */
        buf[3]=g_fmt_w; buf[4]=g_fmt_h; buf[5]=g_fmt_pitch;
        buf[6]=V4L2_PIX_FMT_YUYV; buf[7]=1; buf[8]=1; /* mip=1 flags=1 */
        buf[9]=0; buf[10]=0; /* virt, base_off */
        /* igd_ovl_info_t at [13]: src_rect(x1y1x2y2), dst_rect, color_key... */
        buf[13]=0; buf[14]=0; buf[15]=g_fmt_w-1; buf[16]=g_fmt_h-1; /* src */
        buf[17]=0; buf[18]=0; buf[19]=g_fmt_w-1; buf[20]=g_fmt_h-1; /* dst */
        /* display_h, flags at end */
        buf[46]=0; buf[47]=1; buf[48]=0; buf[49]=1;
    }
    r=ioctl(g_drm,IGD_ALTER_OVL2,buf);
    LOG("  alter C: r=%d rtn=%d errno=%d",r,(int)buf[0],errno);
    kmsg_dump("P4-C"); v2g_try_enable("P4-C");

    /* Layout D: all zeros (let driver reject and tell us why via kmsg) */
    LOG("  [D] all-zeros (baseline rejection)");
    memset(buf,0,200);
    r=ioctl(g_drm,IGD_ALTER_OVL2,buf);
    LOG("  alter D: r=%d rtn=%d errno=%d",r,(int)buf[0],errno);
    kmsg_dump("P4-D");

    /* Layout E: ovl_plane=0 (use overlay engine, not Sprite C) */
    LOG("  [E] layout E: ovl_plane=0 (primary overlay, not Sprite C)");
    fill_ovl2(buf, g_nbufs>0?g_boff[0]:0,
        g_fmt_w,g_fmt_h,g_fmt_pitch, V4L2_PIX_FMT_YUYV, 1,
        0,0,g_fmt_w-1,g_fmt_h-1, 0,0,g_fmt_w-1,g_fmt_h-1, 0,0);
    r=ioctl(g_drm,IGD_ALTER_OVL2,buf);
    LOG("  alter E: r=%d rtn=%d errno=%d",r,(int)buf[0],errno);
    kmsg_dump("P4-E"); v2g_try_enable("P4-E");
}

/* ══════════════════════════════════════════════════════════════════════════
 * P5 — DRM_SET_MASTER without killing (root may succeed)
 * ══════════════════════════════════════════════════════════════════════════ */
static void p5_drm_notkill(void) {
    LOG("\n══ P5: DRM_SET_MASTER (no kill) ════════════════════════════════");
    /* Try on existing g_drm fd, then on a fresh fd */
    for (int attempt=0; attempt<2; attempt++) {
        int fd=(attempt==0)?g_drm:open("/dev/dri/card0",O_RDWR);
        LOG("  attempt %d: fd=%d",attempt,fd);
        if (fd<0) continue;
        int r=ioctl(fd,DRM_SET_MASTER,0);
        LOG("  DRM_SET_MASTER → r=%d errno=%d (%s)",r,errno,strerror(errno));
        kmsg_dump("P5-SET_MASTER");
        if (r==0) {
            LOG("  *** Got DRM master (no kill) — trying GMM_ALLOC + ALTER + V2G");
            struct igd_gmm_alloc gmm={0};
            gmm.size=g_fmt_sz ? g_fmt_sz : 800*480*2;
            int gr=ioctl(fd,IGD_GMM_ALLOC_IOCTL,&gmm);
            LOG("  GMM_ALLOC: r=%d rtn=%d off=0x%lx",gr,gmm.rtn,gmm.offset);
            unsigned int buf[50];
            fill_ovl2(buf, gmm.offset>0?gmm.offset:(g_nbufs?g_boff[0]:0),
                g_fmt_w,g_fmt_h,g_fmt_pitch, V4L2_PIX_FMT_YUYV,1,
                0,0,g_fmt_w-1,g_fmt_h-1, 0,0,g_fmt_w-1,g_fmt_h-1, 0,1);
            int ar=ioctl(fd,IGD_ALTER_OVL2,buf);
            LOG("  ALTER_OVL2: r=%d rtn=%d",ar,(int)buf[0]);
            kmsg_dump("P5-ALTER");
            v2g_try_enable("P5");
            ioctl(fd,DRM_DROP_MASTER,0);
        }
        if (attempt==1 && fd!=g_drm) close(fd);
    }
}

/* ══════════════════════════════════════════════════════════════════════════
 * P6 — V2G with fresh fd after ALTER_OVL2 + DRM master (no kill).
 * Previous analysis: killing emgdhmid crashes nav AND doesn't help (GMM rtn=-2
 * regardless). Real blocker is "GTT mapping requested for 0 buffers".
 * v2g_try_enable() now passes actual GTT buffer info — test that path here
 * using DRM master we already obtained in P5.
 * ══════════════════════════════════════════════════════════════════════════ */
static void p6_drm_nokill(void) {
    LOG("\n══ P6: V2G WITH GTT BUFFERS + DRM MASTER (NO KILL) ════════════");

    /* DRM fd from P5 is still open (g_drm). If not, open fresh. */
    int drm=(g_drm>=0)?g_drm:open("/dev/dri/card0",O_RDWR);
    if (drm<0) { LOG("  card0 unavailable"); return; }

    int r=ioctl(drm,DRM_SET_MASTER,0);
    LOG("  DRM_SET_MASTER → r=%d errno=%d",r,errno);

    /* GMM alloc — log result even if rtn=-2 (EMGD internal error) */
    struct igd_gmm_alloc gmm={0};
    gmm.size=g_nbufs?g_blen[0]:800*480*2;
    r=ioctl(drm,IGD_GMM_ALLOC_IOCTL,&gmm);
    LOG("  GMM_ALLOC: r=%d rtn=%d off=0x%lx sz=%lu",r,gmm.rtn,gmm.offset,gmm.size);

    /* Use V4L2 GTT offset if GMM failed */
    unsigned long surf_off=(r==0&&gmm.rtn==0&&gmm.offset)?gmm.offset:(g_nbufs?g_boff[0]:0);

    unsigned int ab[50];
    /* ALTER with plane=5 (Sprite C confirmed valid) — x1y1x2y2 layout */
    fill_ovl2(ab,surf_off,g_fmt_w,g_fmt_h,g_fmt_pitch,V4L2_PIX_FMT_YUYV,1,
        0,0,g_fmt_w-1,g_fmt_h-1, 0,0,g_fmt_w-1,g_fmt_h-1, 0,5);
    r=ioctl(drm,IGD_ALTER_OVL2,ab);
    LOG("  ALTER plane=5: r=%d rtn=%d errno=%d",r,(int)ab[0],errno);
    kmsg_dump("P6-ALTER5");
    v2g_try_enable("P6-A5");

    /* ALTER with plane=3 (primary overlay confirmed valid) */
    fill_ovl2(ab,surf_off,g_fmt_w,g_fmt_h,g_fmt_pitch,V4L2_PIX_FMT_YUYV,1,
        0,0,g_fmt_w-1,g_fmt_h-1, 0,0,g_fmt_w-1,g_fmt_h-1, 0,3);
    r=ioctl(drm,IGD_ALTER_OVL2,ab);
    LOG("  ALTER plane=3: r=%d rtn=%d errno=%d",r,(int)ab[0],errno);
    kmsg_dump("P6-ALTER3");
    v2g_try_enable("P6-A3");

    ioctl(drm,DRM_DROP_MASTER,0);
    if (drm!=g_drm) close(drm);

    /* --- P6.5: direct pixel write to V4L2 buf[0] mmap + ALTER_OVL2 plane=5 ---
     * Tests whether IOH GTT offsets (from ioh_vin) are in the same address
     * space as EMGD overlay surfaces. If yes, we can paint Sprite C without
     * V2G_ENABLE — bypassing the camera DMA requirement entirely. */
    if (g_nbufs>0 && g_buf[0] && g_blen[0]>0) {
        LOG("  --- P6.5: YUYV red -> buf[0] + ALTER_OVL2 plane=5 ---");
        /* Fill buf[0] with YUYV red: Y=76 U=85 Y=76 V=255 (R=255 G=0 B=0) */
        unsigned char *pix=(unsigned char *)g_buf[0];
        unsigned int nb=g_blen[0];
        for (unsigned int i=0; i<nb; i+=4) {
            pix[i+0]=76; pix[i+1]=85; pix[i+2]=76; pix[i+3]=255;
        }
        __sync_synchronize(); /* ensure GTT sees writes before ioctl */
        LOG("  buf[0] filled with YUYV red (%u bytes gtt=0x%x)",nb,g_boff[0]);
        /* re-open DRM for this test (dropped master above) */
        int drm2=open("/dev/dri/card0",O_RDWR);
        if (drm2>=0) {
            ioctl(drm2,DRM_SET_MASTER,0);
            unsigned int ab2[50];
            fill_ovl2(ab2,g_boff[0],g_fmt_w,g_fmt_h,g_fmt_pitch,
                V4L2_PIX_FMT_YUYV,1,
                0,0,g_fmt_w-1,g_fmt_h-1,
                0,0,g_fmt_w-1,g_fmt_h-1,
                0,5); /* plane=5 Sprite C */
            int r2=ioctl(drm2,IGD_ALTER_OVL2,ab2);
            LOG("  ALTER plane=5 V4L2-GTT red: r=%d rtn=%d errno=%d",
                r2,(int)ab2[0],errno);
            kmsg_dump("P6.5-pixwrite");
            if (r2==0) { LOG("  SUCCESS -- watching 5s (screen should show red)"); sleep(5); }
            /* disable overlay */
            fill_ovl2(ab2,g_boff[0],g_fmt_w,g_fmt_h,g_fmt_pitch,
                V4L2_PIX_FMT_YUYV,0,
                0,0,g_fmt_w-1,g_fmt_h-1,
                0,0,g_fmt_w-1,g_fmt_h-1,
                0,5);
            ioctl(drm2,IGD_ALTER_OVL2,ab2);
            ioctl(drm2,DRM_DROP_MASTER,0);
            close(drm2);
        }
    }

    kmsg_dump("P6-final");
    LOG("  --- usleep 75s scanner ---");
    /* Find the 75s factory delay process so we know what script spawned it.
     * /proc/PID/cmdline uses NUL as arg separator — replace with spaces before strstr. */
    {
        DIR *dp=opendir("/proc"); struct dirent *ep; if(dp){
        while((ep=readdir(dp))){
            if(ep->d_name[0]<'1'||ep->d_name[0]>'9') continue;
            char pp[128]; snprintf(pp,sizeof(pp),"/proc/%s/cmdline",ep->d_name);
            int fd=open(pp,O_RDONLY); if(fd<0) continue;
            char cmd[512]={0}; int cn=(int)read(fd,cmd,511); close(fd);
            /* replace NUL separators with spaces so strstr searches all args */
            for(int i=0;i<cn-1;i++) if(cmd[i]=='\0') cmd[i]=' ';
            if(strstr(cmd,"75000000")||strstr(cmd,"usleep")){
                LOG("    pid=%s cmdline=[%s]",ep->d_name,cmd);
                /* get PPid and State */
                snprintf(pp,sizeof(pp),"/proc/%s/status",ep->d_name);
                FILE *sf=fopen(pp,"r"); int ppid=-1; if(sf){
                    char ln[256]; while(fgets(ln,256,sf)){
                        int l=(int)strlen(ln); while(l>0&&(ln[l-1]=='\n'||ln[l-1]=='\r')) ln[--l]='\0';
                        if(strstr(ln,"PPid:")){ LOG("    status: %s",ln); sscanf(ln,"PPid:\t%d",&ppid); }
                        else if(strstr(ln,"State:")) LOG("    status: %s",ln);
                    } fclose(sf);
                }
                /* trace parent cmdline to identify which script spawned the delay */
                if(ppid>1){
                    snprintf(pp,sizeof(pp),"/proc/%d/cmdline",ppid);
                    fd=open(pp,O_RDONLY); if(fd>=0){
                        char pcmd[512]={0}; int pn=(int)read(fd,pcmd,511); close(fd);
                        for(int i=0;i<pn-1;i++) if(pcmd[i]=='\0') pcmd[i]=' ';
                        LOG("    parent pid=%d cmdline=[%s]",ppid,pcmd);
                    }
                    /* also check exe symlink */
                    snprintf(pp,sizeof(pp),"/proc/%d/exe",ppid);
                    char exe[256]={0};
                    if(readlink(pp,exe,255)>0) LOG("    parent exe=%s",exe);
                    /* read /proc/PID/maps snippet to see script path if shell */
                    snprintf(pp,sizeof(pp),"/proc/%d/status",ppid);
                    FILE *pf=fopen(pp,"r"); if(pf){
                        char ln[256]; while(fgets(ln,256,pf)){
                            int l=(int)strlen(ln); while(l>0&&(ln[l-1]=='\n'||ln[l-1]=='\r')) ln[--l]='\0';
                            if(strstr(ln,"Name:")||strstr(ln,"PPid:")) LOG("    parent status: %s",ln);
                        } fclose(pf);
                    }
                }
            }
        } closedir(dp); }
    }

    /* Scan init.d / rc.d / upstart scripts for the "75000000" sleep source.
     * ppid=1 means init launched it directly — find which conf/script. */
    LOG("  --- init.d scan for 75s delay ---");
    {
        static const char *dirs[]={
            "/etc/init.d", "/etc/rc.d/init.d", "/etc/rc.d",
            "/etc/upstart", "/etc/event.d", "/etc/rc3.d",
            "/etc/rc5.d", "/etc/rcS.d", NULL
        };
        for (int di=0; dirs[di]; di++) {
            DIR *dd=opendir(dirs[di]); if(!dd) continue;
            struct dirent *de;
            while((de=readdir(dd))){
                if(de->d_name[0]=='.') continue;
                char fp[256]; snprintf(fp,sizeof(fp),"%s/%s",dirs[di],de->d_name);
                FILE *f=fopen(fp,"r"); if(!f) continue;
                char line[512]; int lnum=0; int hit=0;
                while(fgets(line,sizeof(line),f) && lnum<500){
                    lnum++;
                    if(strstr(line,"75000000")||strstr(line,"usleep")||
                       (strstr(line,"sleep")&&strstr(line,"75"))){
                        if(!hit){ LOG("    [%s]",fp); hit=1; }
                        int l=(int)strlen(line); while(l>0&&(line[l-1]=='\n'||line[l-1]=='\r')) line[--l]='\0';
                        LOG("      L%d: %s",lnum,line);
                    }
                }
                fclose(f);
            }
            closedir(dd);
        }
        /* Also dump /proc/1/cmdline so we know init type */
        {
            int fd=open("/proc/1/cmdline",O_RDONLY);
            if(fd>=0){ char buf[256]={0}; int n=(int)read(fd,buf,255); close(fd);
                for(int i=0;i<n-1;i++) if(buf[i]=='\0') buf[i]=' ';
                LOG("  init (pid=1) cmdline=[%s]",buf);
            }
        }
    }

    /* Android init uses init.rc files, not init.d — scan those for the 75s delay.
     * ppid=1 with /sbin/init android means it was launched from an init.rc service
     * or on-boot section. */
    LOG("  --- init.rc scan (Android init) ---");
    {
        static const char *rcfiles[]={
            "/init.rc","/system/init.rc","/etc/init.rc",
            "/system/etc/init.rc",NULL
        };
        for (int ri=0; rcfiles[ri]; ri++) {
            FILE *f=fopen(rcfiles[ri],"r"); if(!f) continue;
            char line[512]; int lnum=0; int hit=0;
            while(fgets(line,sizeof(line),f)&&lnum<2000){
                lnum++;
                if(strstr(line,"75000000")||strstr(line,"usleep")||
                   (strstr(line,"sleep")&&strstr(line,"75"))){
                    if(!hit){LOG("    [%s]",rcfiles[ri]);hit=1;}
                    int l=(int)strlen(line);
                    while(l>0&&(line[l-1]=='\n'||line[l-1]=='\r')) line[--l]='\0';
                    LOG("      L%d: %s",lnum,line);
                }
            }
            fclose(f);
        }
        /* scan init.rc directory variants */
        static const char *rcdirs[]={
            "/etc/init","/system/etc/init","/system/init",NULL
        };
        for (int di=0; rcdirs[di]; di++) {
            DIR *dd=opendir(rcdirs[di]); if(!dd) continue;
            struct dirent *de;
            while((de=readdir(dd))){
                if(de->d_name[0]=='.') continue;
                char fp[256]; snprintf(fp,sizeof(fp),"%s/%s",rcdirs[di],de->d_name);
                FILE *f=fopen(fp,"r"); if(!f) continue;
                char line[512]; int lnum=0; int hit=0;
                while(fgets(line,sizeof(line),f)&&lnum<1000){
                    lnum++;
                    if(strstr(line,"75000000")||strstr(line,"usleep")||
                       (strstr(line,"sleep")&&strstr(line,"75"))){
                        if(!hit){LOG("    [%s]",fp);hit=1;}
                        int l=(int)strlen(line);
                        while(l>0&&(line[l-1]=='\n'||line[l-1]=='\r')) line[--l]='\0';
                        LOG("      L%d: %s",lnum,line);
                    }
                }
                fclose(f);
            }
            closedir(dd);
        }
        /* dump /proc/1/fd symlinks for any .rc files init has open */
        LOG("  --- /proc/1/fd (init's open .rc files) ---");
        {
            DIR *fddir=opendir("/proc/1/fd"); if(fddir){
                struct dirent *fe;
                while((fe=readdir(fddir))){
                    if(fe->d_name[0]=='.') continue;
                    char lp[128],tgt[256]={0};
                    snprintf(lp,sizeof(lp),"/proc/1/fd/%s",fe->d_name);
                    int n2=(int)readlink(lp,tgt,255);
                    if(n2>0){ tgt[n2]='\0';
                        if(strstr(tgt,".rc")||strstr(tgt,"init"))
                            LOG("    fd%s -> %s",fe->d_name,tgt);
                    }
                }
                closedir(fddir);
            }
        }
    }
}

/* ══════════════════════════════════════════════════════════════════════════
 * main
 * ══════════════════════════════════════════════════════════════════════════ */
int main(int argc, char **argv) {
    /* Single-instance lock — prevents two concurrent runs trampling each other */
    int lockfd = open("/tmp/q60-v4l2.lock", O_CREAT|O_EXCL|O_WRONLY, 0600);
    if (lockfd < 0) {
        /* Another instance is running — bail out silently */
        return 0;
    }
    close(lockfd);

    logf = fopen(LOG_PATH,"w");
    kmsgf = fopen(KMSG_PATH,"w");
    if (logf) setvbuf(logf,NULL,_IOLBF,0);
    if (kmsgf) setvbuf(kmsgf,NULL,_IOLBF,0);

    time_t t=time(NULL);
    LOG("=== Q60 R1 v4 comprehensive test — %s",ctime(&t));
    kmsg_dump("BOOT-IMMEDIATE");
    LOG("pid=%d uid=%d euid=%d",(int)getpid(),(int)getuid(),(int)geteuid());

    p0_survey();
    p1_fbdev();
    if (p2_v4l2() < 0)
        LOG("\n[WARN] V4L2 setup failed — phases using video0 will skip V4L2 precond");
    p3_v2g_sweep();
    p4_alter_nonmaster();
    p5_drm_notkill();
    p6_drm_nokill();

    /* cleanup V4L2 */
    if (g_vid>=0) {
        int bt=V4L2_BUF_TYPE_VIDEO_CAPTURE;
        ioctl(g_vid,VIDIOC_STREAMOFF,&bt);
        for(unsigned i=0;i<g_nbufs&&i<4;i++) if(g_buf[i]) munmap(g_buf[i],g_blen[i]);
        close(g_vid);
    }

    LOG("\n=== v4 done ===");
    if (logf)  { fclose(logf);  logf  = NULL; }
    if (kmsgf) { fclose(kmsgf); kmsgf = NULL; }

    /* Copy /tmp logs to /boot now that everything is flushed.
     * run.sh will cp /tmp/q60v4l2.log (stdout capture, empty) to
     * Q60_RUN_STDOUT.LOG — we copy the real logs here under different names
     * so run.sh's cp cannot overwrite them. */
    system("cp /tmp/Q60_R1_V4L2.LOG /boot/Q60_R1_V4L2.LOG 2>/dev/null");
    system("cp /tmp/Q60_KMSG.LOG    /boot/Q60_KMSG.LOG    2>/dev/null");
    sync();

    unlink("/tmp/q60-v4l2.lock");
    return 0;
}
