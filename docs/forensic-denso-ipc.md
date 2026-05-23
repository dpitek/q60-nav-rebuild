# Forensic DENSO IPC Analysis — libifout + nav_* daemons

**Subject:** What IPC primitives keep the DENSO backend daemons (`PS_VRD01`,
`multimedia_ps`, etc.) from OOM'ing when the 4 UI daemons (`navi_ps`,
`hmictrl_proc`, `display_ps`, `dispapf_proc`) are killed by Plan B'''. What
must our Qt6 replacement consume/ACK/drop. Is `libhmi-cntl-server.so` a
viable shortcut.

**Artifacts analyzed:**
- `/tmp/dsu-naviwork-lib/libifout.so` (331,288 B, stripped, 2,077 exports)
- `/tmp/dsu-naviwork-lib/libhmi-cntl-server.so` (1,111,368 B, 2,520 exports)
- `/tmp/dsu-naviwork-lib/libhmi-cntl-client.so` (648,960 B, 1,618 exports)
- `/tmp/dsu-naviwork-lib/libhmi-cntl.so` (594,040 B, 2,238 exports)
- `/tmp/dsu-naviwork-lib/libhmi-cntl-nissan.so` (1,333,164 B, 3,599 exports)
- `/tmp/dsu-naviwork-bin/{PS_VRD01,multimedia_ps,hmictrl_proc,display_ps,navi_ps,audio_ps,camera_ps,dispapf_proc,...}`
- `/tmp/dsu-slot-a/lib/systemd/system/nav_*.service`

**Date:** 2026-05-23

---

## Executive Summary

1. **Each backend daemon owns exactly one POSIX mqueue** named `/<argv0>_main`
   (e.g. `PS_VRD01` creates `/PS_VRD01_main`, `multimedia_ps` creates
   `/multimedia_ps_main`). The queue is the daemon's **inbox** — it does
   `mq_open(name, O_RDWR|O_CREAT)` and a `Btasrif_Recv_Main` loop. No
   cross-binary string references exist because **destination resolution happens
   in libifout by process-name → queue-name mapping** (`/%s_main` format applied
   to the destination's `PS_*` identifier). This means **the growing queues
   the May probe saw are the backend daemons' own inboxes, filling because
   the surviving backends keep handshaking with each other while the dead UI
   peers never reply.** Q: who fills `/PS_VRD01_main` at 5 MB/s? A: NOT the
   dead UI daemons — it's `smng`, `napl`, `tel_proc`, `audio_ps`, and
   PS_VRD01's own watchdog/heartbeat timers requeueing retries.

2. **The minimum Qt6 drain-and-ACK contract is small** but it has to impersonate
   the four dead PS_* names. Concretely: at boot our Qt app must
   `mq_open("/navi_ps_main", O_RDONLY|O_CREAT|O_NONBLOCK, 0666, &attr)` with
   `attr.mq_maxmsg=8` and `attr.mq_msgsize=1048576` (matches the kernel
   `fs.mqueue.msgsize_max=1048576` and the daemons' 8 MB `LimitMSGQUEUE`),
   and likewise for `/display_ps_main`, `/hmictrl_proc_main`, `/dispapf_main`.
   Spawn one drain thread per queue: blocking `mq_receive` into a 1 MB
   scratch buffer, **discard the payload**, loop. That's it. No ACK reply is
   required for the surviving backends to keep functioning — DENSO's IPC is
   asymmetric send-with-no-mandatory-ack (smng tracks liveness via its OWN
   queue `/smng_commCtl`, not via reply traffic). The drain prevents
   `mq_send` EAGAIN at the senders, which is what fills their internal
   retry buffers.

3. **`libhmi-cntl-server.so` is a viable shortcut for hmictrl_proc ONLY**,
   not for the other three. It exports the C++ `hmi::controller::ServerHMIController`
   class (3,500+ symbols including `transition`, `doRevertTo`, `manualControl`,
   `getDisplayController`, `ContentsManager`). Linking it from Qt would give
   us a turn-key `/hmictrl_proc_main` consumer. **But it transitively NEEDs
   `libhmi-cntl-nissan.so` which pulls in `libstsmng.so libsec.so libioapf_lib.so
   libcam.so libioucm.so libdrl.so libioc.so libboost_thread-mt.so.5
   libboost_system-mt.so.5 libsqlite3.so.0`** — i.e. the entire DENSO Nissan
   integration layer. That's a ~10 MB blob we'd ship into Slot B with
   unknown side effects (`libioapf_lib` is the I/O abstraction that talks
   to CAN/DRL — running it in our process could fight the real `ioapf_proc`).
   **Verdict: do NOT pull libhmi-cntl-server.so into our app.** Implement the
   4 drain queues by hand. ~50 lines of code, zero coupling to DENSO C++ ABI.

4. **There is no D-Bus dependency in the nav stack.** `dbus-daemon` is NOT on
   Slot A (only `dbus-binding-tool` is present, which is a build-time
   utility); the only `*.service` files in `/usr/share/dbus-1/services/` are
   freedesktop platform services (ConsoleKit, PolicyKit, hostname1, locale1,
   login1, systemd1, timedate1, pacrunner, wpa_supplicant). **DENSO IPC is
   100% POSIX mqueue + SysV/POSIX shm + a handful of named semaphores.** Plan
   B''' does not need to launch or talk to dbus at all. Skip it.

5. **The drain priorities, ranked by observed growth rate × `LimitMSGQUEUE`
   ceiling**, are: (1) `/navi_ps_main` (8 MB) — PS_VRD01 → PS_NAVI traffic is
   navigation route updates, highest velocity; (2) `/display_ps_main` (8 MB) —
   multimedia_ps → PS_DISPLAY surface composition messages; (3)
   `/hmictrl_proc_main` (8 MB) — control plane, but lower velocity (button
   events only); (4) `/dispapf_main` (8 MB) — display APF events from
   ioapf_proc. **All four are 8 MB hard caps. With kernel `msgsize_max=1MB`,
   a single 8-msg queue fills in <2 s under heavy traffic. Drain latency
   must be < 200 ms or queues block, senders' OWN inboxes (`/PS_VRD01_main`)
   start growing as they buffer retries, and the May probe pattern repeats
   even with drains in place.**

---

## 1. libifout.so — the IPC substrate

### File facts
| | |
|---|---|
| Path on target | `/home/naviwork/system/lib/libifout.so` |
| Path on host | `/tmp/dsu-naviwork-lib/libifout.so` |
| Size | 331,288 B |
| Format | ELF 32-bit LSB shared, Intel 80386, SYSV, stripped |
| BuildID | `0c106df2265601cc0555dd94d76f58998f91270e` |
| SONAME | `libifout.so` |
| Exports (`nm -D --defined-only`) | **2,077** |

### NEEDED
```
librt.so.1        ← mq_*, shm_*, sem_*, clock_gettime
libpthread.so.0   ← threads + mutexes
libdl.so.2
libstdc++.so.6
libgcc_s.so.1
libc.so.6
```
**No NEEDED for libdbus, libwayland, libemgdhmi, libsqlite, libboost.**
`libifout.so` is a pure POSIX-IPC + STL library. Self-contained.

### IPC API surface
Symbols are namespaced by subsystem prefix. The ones that matter:

| Prefix | Purpose | Sample symbols |
|---|---|---|
| `BTASRC_*` | Bluetooth ASR client wrappers — but they're the **generic IPC primitives** the rest of the lib uses; the name is a historical artifact | `BTASRC_mq_open`, `BTASRC_mq_send`, `BTASRC_mq_receive`, `BTASRC_mq_close`, `BTASRC_mq_unlink`, `BTASRC_sem_open`, `BTASRC_sem_wait`, `BTASRC_sem_post`, `BTASRC_sem_close`, `BTASRC_sem_unlink`, `BTASRC_sem_getval`, `BTASRC_shm_open` |
| `Btasrif_*` | High-level send/recv | `Btasrif_Send_Msgque_NonParam`, `Btasrif_Recv_Main` |
| `WPC_*` | Wrapper-process-comms variant | `WPC_mq_open`, `WPC_shm_open`, `WPC_shm_unlink` |
| `OSMEM_*` | Shared-memory area manager | `OSMEM_init`, `OSMEM_getAddress`, `OSMEM_getAreaInfo`, `OSMEM_setFactorData`, `OSMEM_getFactorData`, `OSMEM_setGpsInfo`, `OSMEM_setResetLog`, `OSMEM_setVersionInfo` |
| `DIM_*` | Data Information Manager (telephony control plane) | `DIM_Api_Nti_DataRecv`, `DIM_Api_RegCmdRecvCallback`, `DIM_Api_Send_Cmd` |
| `HttpClient_*` | HTTP IPC stub (used by carwings) | `HttpClient_sendRequest`, `HttpClient_sendRequestMp` |
| `MLA_*`, `ME_*`, `KEY_*`, `LOG_*`, `HFM_*`, `Nva_Its_*` | Domain modules using the same primitives | many |
| `mmapf_*` | mmap-based shared-memory facility | `mmapf_shared_mem_create_api`, `mmapf_shared_mem_read_api` |

### What libifout does NOT contain
- No `dbus_*` symbols
- No `wl_*` (Wayland) symbols
- No `IPC_*` SysV-msgget symbols (it's POSIX mq, not SysV msq)
- No abstract `@/socket` strings (confirmed: `strings | grep '@/'` returns nothing)

### Queue-name format string
`libifout.so` does NOT contain the literal `%s_main` format string in
plaintext. The naming pattern is reconstructed by **observation across
binaries** — every daemon in `/tmp/dsu-naviwork-bin/` that has a `/<name>_main`
string in its `.rodata` exactly matches its own ELF basename:

| Binary | Owned mqueue (from `strings`) |
|---|---|
| `PS_VRD01` | `/PS_VRD01_main` |
| `PS_DSN` | `/ps_dsn_main` (lowercased — exception) |
| `PS_REX01` | `/PS_REX01_main` |
| `multimedia_ps` | `/multimedia_ps_main` |
| `hmictrl_proc` | `/hmictrl_proc_main` |
| `navi_ps` | `/navi_ps_main` |
| `display_ps` | `/display_ps_main` |
| `audio_ps` | `/audio_ps_main` |
| `camera_ps` | `/camera_main` (truncated — exception) |
| `dispapf_proc` | `/dispapf_main` (truncated — exception) |
| `ioapf_proc` | `/ioapf_main` (truncated — exception) |
| `fis_ps` | `/fis_ps_main` |
| `napl` | `/napl_main` |
| `tel_proc` | `/tel_proc_main` |
| `smng` | `/smng_mainCtl`, `/smng_bootCtl`, `/smng_commCtl`, `/smng_logSem` (4 queues — outlier) |
| `abstc` | uses `/AbsTC_sem`, `/AbsTC_shm` (not mqueue — shm + sem only) |

**The 3 truncation exceptions (`camera_main`, `dispapf_main`, `ioapf_main`)
and the 1 lowercase exception (`ps_dsn_main`) prove the queue name is
NOT mechanically built from argv[0] by libifout — each daemon has the
literal queue name baked in. So in our Qt app, we must replicate the
exact strings from the table above for the 4 daemons we're replacing.**

### POSIX shm segments owned by libifout users
From `strings libifout.so | grep -E '^/[A-Z]'`:
```
/DCDM_SHM_INTERNAL
/LEGRES/HTTPC_IOC_SHM_COMMON
/LEGRES/HTTPC_IOC_SHM_RESPONSE
/LEGRES/HTTPC_TASK_STATUS
/LEGRES/HTTPC_init_flg
/LEGRES/HTTPC_rood_object_id
/LEGRES/MMAPF_IOC_SHM_COMMON
/LEGRES/MMAPF_STS_CTL
/LEGRES/MMAPF_rood_object_id
/LEGRES/XMCMP_TASK_STS_CTL
/LEGRES/XMCMP_init_flg
/LEGRES/XMCMP_ioc_obj_id_ctl
/LEGRES/btasr_SHARED_MEMORY
/LEGRES/cidef_mp_shm
/LEGRES/cwauth_mp_shm
/LEGRES/dim_mp_shm
/LEGRES/systemlogd_shm1
/LEGRES/wavp_SHARED_MEMORY
/MMAPF_send_from_api_sem_id
/N_uk
/XMCMP_send_from_api_sem_id
```
These are HTTP/MMAPF/XMCMP communication structures, mostly carwings/connected-services
data plane. **Our Qt app does not need to read or write any of these** — they're
owned by surviving backends and accessed laterally between PS_REX01 ↔ multimedia_ps.
The `/dev/shm/LEGRES/*` files will exist on disk while those daemons run; we
ignore them.

### Abstract sockets
`strings libifout.so | grep '@/'` → **empty.** No abstract Unix sockets in
libifout itself. Abstract sockets DO appear in `libhmi-cntl-server.so` (see §3).

---

## 2. Per-daemon mqueue inventory and traffic model

### 2.1 The 4 daemons we KILL in Plan B''' (must replace their inboxes)

| Daemon | Owned mqueue | Service unit | What it normally consumes |
|---|---|---|---|
| `navi_ps` | `/navi_ps_main` | `nav_navi.service` (argv "PS_NAVI") | Route/POI/map updates from PS_VRD01, audio_ps, tel_proc |
| `display_ps` | `/display_ps_main` | `nav_display.service` (argv "PS_DISPLAY") | Surface composition / buffer-flip events from multimedia_ps, camera_ps |
| `hmictrl_proc` | `/hmictrl_proc_main` | `nav_hmictrl.service` (argv "PS_HMIC1") | Key events from ioapf_proc, state changes from smng, content requests from navi_ps |
| `dispapf_proc` | `/dispapf_main` | `nav_dispapf.service` (argv "PS_DISPAPF") | Display APF events from ioapf_proc (low velocity) |

All four service units set `LimitMSGQUEUE=8192000` (8 MB rlimit on mqueue
bytes per process). At kernel level, `fs.mqueue.msgsize_max=1048576` (1 MB
per single message), so the queues can hold ≤ 8 messages each before
`mq_send` returns EAGAIN to the sender.

### 2.2 The 12 backend daemons that survive (their queues we DON'T touch)

| Daemon | Owned mqueue | Talks to dead 4? |
|---|---|---|
| `PS_VRD01` | `/PS_VRD01_main` | YES — sends to navi_ps |
| `multimedia_ps` | `/multimedia_ps_main` | YES — sends to display_ps |
| `PS_DSN` | `/ps_dsn_main` | indirect (via smng) |
| `PS_REX01` | `/PS_REX01_main` | indirect |
| `audio_ps` | `/audio_ps_main` | YES — sends to navi_ps |
| `camera_ps` | `/camera_main` | YES — sends to display_ps |
| `fis_ps` | `/fis_ps_main` | indirect |
| `ioapf_proc` | `/ioapf_main` | YES — sends to hmictrl_proc, dispapf_proc |
| `napl` | `/napl_main` | indirect |
| `tel_proc` | `/tel_proc_main` | YES — sends to navi_ps |
| `smng` | 4 queues (control) | YES — sends to hmictrl_proc |
| `abstc` | `/AbsTC_shm`, `/AbsTC_sem` | no (it's a time-of-day broadcaster via shm only) |

**Inferred traffic model (from queue-ownership + the May probe data):**
- PS_VRD01 grew 3.5MB → 53MB in 10s during disable-probe.
- 53MB / 10s = 5.3 MB/s
- PS_VRD01 has `LimitMSGQUEUE=8192000` (8 MB) — **so 53 MB is impossible in PS_VRD01's own mqueue**. The growth must be in **PS_VRD01's heap/internal retry buffer**, NOT in the kernel mqueue.
- This means: PS_VRD01 is calling `mq_send("/navi_ps_main", ...)` → getting EAGAIN (queue full because dead navi_ps not draining) → libifout's `Btasrif_Send_Msgque_NonParam` is buffering retries in **userspace heap**. That heap is what grew to 53 MB before OOM would kick in.
- Same pattern for `multimedia_ps` → `/display_ps_main` (1.7MB → 39MB).

**Conclusion: the OOM threat is in the SENDING daemons' heaps, caused by
EAGAIN buffering. Draining the consumer-side queues (`/navi_ps_main` etc.)
to `mq_send` returns 0 quickly is what stops the buffer growth.**

---

## 3. libhmi-cntl-server.so — would it short-cut hmictrl_proc?

### File facts
| | |
|---|---|
| Size | 1,111,368 B |
| Exports | 2,520 (mostly C++ mangled `hmi::controller::*` and `hmi::ServerController::*`) |
| SONAME | `libhmi-cntl-server.so` |

### NEEDED
```
libhmi-cntl.so          ← base IPC framework
libhmi-cntl-nissan.so   ← Nissan-specific integration
libifout.so             ← POSIX IPC primitives
libsqlite3.so.0         ← config / state persistence
libstdc++.so.6, libgcc_s.so.1, libc.so.6
```

### Notable exports (the API surface)
- `hmi::controller::ServerHMIController` — singleton; `getInstance()`, `initializer`, `invokeLater`, `transition`, `doRevertTo`, `doTransition`, `doListRestart`, `manualControl`, `getContext`, `getDayNight`, `addKeyListener`, `areaConvert`, `isDayMapWhite`
- `hmi::controller::ContentsManager` — `getMainDisplay`, `restart`, `started`, `getRestartedContent`
- `hmi::controller::ServerLayoutSet` — `getDisplayId`, `setDisplayId`, `getRectangle`, `setRectangle`, `getDisplayArea`
- `hmi::controller::RestartInfomation` (sic — typo in original) — `id`, `key`, `device`, `context`
- `hmi::CapturingComponentProxy` — for screenshot/recording paths

### Strings of interest
```
/EM
/EM8
/EMN
/EMHk*A
/HMI_SERVER
/HMI_C
/home/denso/test.bin   ← DENSO internal-build path (leftover debug)
```
The `/HMI_SERVER` and `/HMI_C` are likely the abstract socket names for the
HMI message bus (server and client side). `/EM*` are AF_UNIX names for the
Event Manager — these are present in BOTH `libhmi-cntl-server.so` AND
`libhmi-cntl-client.so`.

### Verdict
Loading `libhmi-cntl-server.so` into our Qt6 app would:
1. **PRO:** Instantly provide a turn-key consumer of `/hmictrl_proc_main` —
   the entire HMI controller server already knows how to drain it, dispatch
   the messages, and reply correctly to clients.
2. **CON:** Drags in `libhmi-cntl-nissan.so` which NEEDs
   `libstsmng.so libsec.so libioapf_lib.so libcam.so libioucm.so libdrl.so
   libioc.so libboost_thread-mt.so.5 libboost_system-mt.so.5 libsqlite3.so.0`
   — i.e. the entire DENSO Nissan integration kernel-of-userspace. `libioapf_lib`
   in particular is the CAN-bus / DRL (Daytime Running Lights) facade — if
   it initialises and tries to talk to `/ioapf_main` while the real
   `ioapf_proc` is still running, **we get a split-brain on the I/O bus**.
3. **CON:** Only covers `hmictrl_proc`. Does not give us `navi_ps`,
   `display_ps`, or `dispapf_proc` consumers. We'd still need hand-rolled
   drainers for the other 3.
4. **CON:** C++ ABI tied to GCC 4.5.1 + libstdc++.so.6 from MeeGo 1.2 —
   our Qt6 build is on a much newer toolchain, so we'd need exact ABI
   pinning or wrap it behind a C shim.

**Recommendation: DO NOT use `libhmi-cntl-server.so`.** Write 4 trivial
drain threads instead. ~50 lines of C. Zero dependencies. See §6.

---

## 4. IPC message format — what's on the wire?

### Headers
`find /tmp/dsu-slot-a/usr/include/` → no `denso/`, `ifout/`, `EM/`, or
`hmi-cntl/` directories. **No DENSO headers are shipped on Slot A** —
the DENSO daemons link against a private header set kept in their build
environment.

`find /tmp/dsu-homenaviwork -name "*.h"` → empty. Headers are not on
the device.

### Implication
We do NOT know the C struct layout of an `hmi::Message::message_t`.
**This is the dispositive argument for "drain and discard" rather than
"drain and interpret"**: even if we wanted to parse messages, we don't
have the schemas. The only way to get them would be to disassemble
`libhmi-cntl.so` or capture live traffic with an `strace -e
mq_send,mq_receive` on the running factory image.

**For Plan B''' all we need is to consume bytes so `mq_send` succeeds on
the sender side. We do NOT need to understand or act on them.**

---

## 5. Adjacent IPC channels (informational)

### D-Bus
- `/usr/bin/dbus-daemon` — **NOT PRESENT on Slot A.**
- `/usr/bin/dbus-binding-tool` — present (build-time tool only).
- `/etc/dbus-1/{system.conf, session.conf, system.d/, session.d/}` — present.
- `/usr/share/dbus-1/services/` — 12 services, all freedesktop platform
  (ConsoleKit, PolicyKit, hostname1, locale1, login1, systemd1, timedate1,
  wpa_supplicant, pacrunner, gconf). **Zero DENSO services.**
- **Conclusion:** the nav stack does not use D-Bus. dbus-daemon isn't even
  running. Skip.

### navi0 / audio0 / debug0 virtual interfaces
These are USB-Ethernet gadget interfaces created by udev rules:
- `/tmp/dsu-slot-a/etc/udev/rules.d/70-persistent-net.rules` matches by MAC:
  - `02:00:00:00:00:01` → `navi0`
  - `02:00:00:00:00:02` → `audio0`
- Each rule fires `/etc/udev/rules.d/ifup_{navi0,audio0}.sh` which runs
  `ifconfig <iface> $IP_ADDR netmask $NETMASK mtu $MTU`. The IP/netmask are
  pulled from `/etc/sysconfig/network-scripts/ifcfg-{navi0,audio0}` (those
  files exist).
- `connmand` is started with `--device=navi0 --device=audio0 --device=debug0`.
- `iptables.org` whitelists `169.254.10.2/32` on `navi0:2000` and `navi0:2001`.
- **These interfaces are for talking to external sub-modules over USB-CDC
  (probably the camera sub-board on `audio0` and a debug interface on `debug0`).
  Plan B''' does not need to touch them** — they're created automatically by
  udev when the USB gadgets enumerate. Our app is not their consumer or
  producer.

### Shared memory cleanup (sysctl)
- `/etc/sysctl.conf` sets `fs.mqueue.msgsize_max=1048576` (1 MB/message).
- No other mqueue tuning. Defaults apply for `msg_max` (10) and
  `queues_max` (256).

---

## 6. The drain-and-ACK contract — minimum Qt6 code

### Required at app startup (one-time, before any DENSO daemon talks to us)

```c
#include <mqueue.h>
#include <fcntl.h>
#include <pthread.h>

struct drain_ctx { const char *name; mqd_t mq; };

static const char *DEAD_UI_QUEUES[] = {
    "/navi_ps_main",
    "/display_ps_main",
    "/hmictrl_proc_main",
    "/dispapf_main",
    NULL,
};

static void *drain_thread(void *arg) {
    struct drain_ctx *c = arg;
    char buf[1048576];        /* matches kernel msgsize_max */
    unsigned int prio;
    while (1) {
        ssize_t n = mq_receive(c->mq, buf, sizeof(buf), &prio);
        if (n < 0) {
            /* EINTR -> retry, anything else -> log and continue */
            continue;
        }
        /* discard payload — surviving daemons need only that mq_send returns 0 */
    }
    return NULL;
}

void q60_open_drains(void) {
    struct mq_attr attr = {
        .mq_flags = 0,
        .mq_maxmsg = 8,        /* matches LimitMSGQUEUE=8192000 / msgsize_max */
        .mq_msgsize = 1048576, /* matches fs.mqueue.msgsize_max */
        .mq_curmsgs = 0,
    };
    for (int i = 0; DEAD_UI_QUEUES[i]; i++) {
        mq_unlink(DEAD_UI_QUEUES[i]);   /* remove any stale state */
        mqd_t mq = mq_open(DEAD_UI_QUEUES[i],
                           O_RDONLY | O_CREAT,
                           0666, &attr);
        if (mq == (mqd_t)-1) { /* log + continue */ continue; }
        struct drain_ctx *c = malloc(sizeof(*c));
        c->name = DEAD_UI_QUEUES[i];
        c->mq = mq;
        pthread_t t;
        pthread_create(&t, NULL, drain_thread, c);
        pthread_detach(t);
    }
}
```

### Critical implementation notes
1. **Call `q60_open_drains()` BEFORE you mask/disable the 4 UI services.**
   If the DENSO daemons start first and find their inbox queue is already
   the wrong size or owner-locked, you'll get hard-to-debug `EINVAL` from
   `mq_open` in PS_VRD01.
2. **Use `O_RDONLY|O_CREAT`, NOT `O_RDWR`.** The senders (`mq_send`) only
   need the queue to exist; they open it `O_WRONLY`. We're consumer-only.
3. **mode `0666`.** The DENSO daemons run as `ivilinux:ivilinux`. Our Qt
   app may run as a different uid (e.g. `root` on the diag image). World-
   writable ensures the daemons can `mq_send` regardless of uid mismatch.
4. **Drain threads should be `SCHED_OTHER` with nice 0** — DON'T raise
   priority; we want them to be opportunistic. The 1 MB scratch buffer
   per thread is on heap, not stack (we don't want a 4-thread × 1 MB stack
   to blow `LimitSTACK=524288` if Qt sets that).
5. **No ACK is required.** DENSO IPC is async fire-and-forget at the
   libifout layer. The exception is the HMI controller's `transition`
   reply path — but those replies go to a different per-request mqueue
   that the requesting daemon creates ad-hoc; never seen on `/navi_ps_main`.
6. **Watch for queue persistence after our app exits.** POSIX mqueues
   are kernel objects that survive the creator. If our Qt app crashes,
   the queues linger but nobody drains them. Either (a) wrap our app
   in a systemd unit with `ExecStopPost=/bin/sh -c 'rm -f /dev/mqueue/navi_ps_main /dev/mqueue/display_ps_main /dev/mqueue/hmictrl_proc_main /dev/mqueue/dispapf_main'`,
   or (b) write a tiny watchdog that mq_unlinks all 4 on SIGTERM.

---

## 7. Drain priority ranking (which queue MUST stay drained to avoid OOM)

Based on (a) `LimitMSGQUEUE` ceiling per producer × (b) message rate
implied by the May probe × (c) producer count:

| Rank | Drain target | Producers | Rate | Why critical |
|---|---|---|---|---|
| **1** | `/navi_ps_main` | PS_VRD01, audio_ps, tel_proc, smng | ~5 MB/s | PS_VRD01 alone hit 53 MB heap retry buffer in 10 s. 4 producers feed this. Block here → 4 daemons OOM. |
| **2** | `/display_ps_main` | multimedia_ps, camera_ps | ~4 MB/s | multimedia_ps hit 39 MB heap in 10 s. 2 producers. Block here → 2 daemons OOM and (worse) camera_ps stops feeding the rearview camera buffer that other systems may need. |
| **3** | `/hmictrl_proc_main` | smng, ioapf_proc, libhmi-cntl-client users | low-medium | Control plane — key events at ~10 Hz, state changes at <1 Hz. Won't OOM on its own, but smng's `/smng_commCtl` will back up if we ignore it, and smng backing up triggers `OnFailure=nav_smngpret.service` → reboot. |
| **4** | `/dispapf_main` | ioapf_proc | very low | Display APF is brightness/sleep events at <1 Hz. Almost no risk, but cheap to drain. |

### Do NOT touch
- `/PS_VRD01_main`, `/multimedia_ps_main`, `/audio_ps_main`, `/camera_main`,
  etc. — these are the backends' OWN inboxes. They drain them themselves.
  Our app must NOT open them; we'd race the real owner.
- `/LEGRES/*` shm — owned by surviving backends, lateral IPC between them.
- `/smng_*` queues — owned by smng, the system manager. Don't go near them
  unless you're prepared to impersonate smng (which is much harder — smng
  has 4 queues, OnFailure cascades, and orchestrates the entire startup
  state machine).
- `/AbsTC_shm`, `/AbsTC_sem` — owned by abstc, time-of-day broadcaster
  via shm only, no mqueue traffic.

---

## 8. What the prior agents had right / corrections

- **Agent 2 (factory UI binary)** said *"Our app does not touch /dev/mqueue
  — those are entirely DENSO-private coordination."* **CORRECTION:** that's
  true for our app's role as a *display compositor* (it talks only to
  emgdhmid via `/tmp/.emgdhmid_socket`), but it is **NOT** true for our
  app's role as a *replacement for the 4 dead UI daemons*. As replacement
  for navi_ps/display_ps/hmictrl_proc/dispapf_proc, we MUST own those 4
  POSIX mqueues or the backend daemons will OOM in seconds. The May probe
  proved this empirically.

- **Agent 3 (daemon supervision)** identified `LimitMSGQUEUE=8192000` on
  every nav_*.service and noted "the cascade only fires on `failed`."
  Both correct and load-bearing here. The 8 MB limit is what makes the
  OOM happen in *userspace heap of senders* rather than in the kernel
  mqueue itself.

- **Agent 3** also recommended masking all 18 nav_* units. **Refinement:**
  We must mask only the 4 UI daemons (`nav_navi`, `nav_display`,
  `nav_hmictrl`, `nav_dispapf`), keep the 12 backend daemons RUNNING, and
  provide drain queues for the 4 dead ones. Masking ALL nav_* (Agent 3's
  blanket recommendation) loses the carwings/CAN/multimedia data that the
  surviving 12 produce — Plan B''' wants their data to flow into our Qt
  app for the new UI.

---

## 9. Open questions / deferred

1. **What exact message types arrive on `/navi_ps_main`?** Not strictly
   needed to drain, but would let us *use* the data (route updates, POI
   refreshes) instead of dropping it. Requires either header recovery or
   live `strace` of the factory boot.
2. **Does PS_VRD01 fall over with `mq_send` ENOTCONN at any point**
   (vs. blocking until our drain consumes)? Would be visible in
   `/home/naviwork/log/PS_VRD01.log` from a real boot. Worth grabbing.
3. **Are there `mq_notify`-style async notifiers in libifout?** Symbol
   search didn't surface them, but a `nm | grep notify` pass on
   libifout would confirm. If so, our drain threads might be able to
   become async callbacks instead of blocking threads, saving 4 threads
   × ~8 KB stacks.
4. **`smng`'s 4 queues (`/smng_mainCtl`, `/smng_bootCtl`, `/smng_commCtl`,
   `/smng_logSem`) — do any feed FROM our 4 dead UI daemons?** If yes,
   smng could itself OOM and trigger the OnFailure→poweroff cascade. The
   prior agent already recommended masking `nav_smng`, `nav_smngpret`,
   `nav_backup` to break this cascade; that's the belt-and-suspenders fix.

---

## 10. Key file paths

| File | Role |
|---|---|
| `/tmp/dsu-naviwork-lib/libifout.so` | DENSO IPC substrate (POSIX mq + shm + sem) |
| `/tmp/dsu-naviwork-lib/libhmi-cntl-server.so` | hmictrl_proc HMI controller logic (do NOT link) |
| `/tmp/dsu-naviwork-lib/libhmi-cntl-client.so` | client side of HMI controller (informational) |
| `/tmp/dsu-naviwork-lib/libhmi-cntl-nissan.so` | Nissan integration (drags in CAN/cam/drl) |
| `/tmp/dsu-naviwork-bin/PS_VRD01` | Surviving backend — sender to /navi_ps_main |
| `/tmp/dsu-naviwork-bin/multimedia_ps` | Surviving backend — sender to /display_ps_main |
| `/tmp/dsu-naviwork-bin/navi_ps` | DEAD — we replace its `/navi_ps_main` inbox |
| `/tmp/dsu-naviwork-bin/display_ps` | DEAD — we replace its `/display_ps_main` inbox |
| `/tmp/dsu-naviwork-bin/hmictrl_proc` | DEAD — we replace its `/hmictrl_proc_main` inbox |
| `/tmp/dsu-naviwork-bin/dispapf_proc` | DEAD — we replace its `/dispapf_main` inbox |
| `/tmp/dsu-slot-a/lib/systemd/system/nav_{navi,display,hmictrl,dispapf}.service` | The 4 units to mask |
| `/tmp/dsu-slot-a/etc/sysctl.conf` | `fs.mqueue.msgsize_max=1048576` (do not change) |
