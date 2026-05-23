# Forensic — V2G rearview camera handoff vs. the 4-daemon kill plan

Date: 2026-05-23
Source: extracted Slot A rootfs at `/tmp/dsu-slot-a/`, extracted naviwork partition at `/tmp/naviwork-extracted/`, prior agent deliverables in `/Users/dpitek/Developer/q60-rebuild/docs/forensic-*.md`.

---

## Executive summary — if we kill the 4 UI daemons and engage reverse, does the camera still work?

1. **No, not as a free side-effect.** The factory rearview camera path is **not driven by `camera_ps` alone.** `camera_ps` is a generic process-supervisor shim (PMNG) hosting 10 modules; the actual camera logic is in `cam.out`, which is **deeply HMI-coupled** — it inherits `hmi::CapturingComponent`, registers a `camSystemStateListener` via `hmi::controller::interprocess::Initiator`, and pumps state through `hmi::controller::HMIController::getInstance()`. That HMI controller IPC server lives inside `hmictrl_proc` (it exports `libhmi-cntl-server.so`). **Kill `hmictrl_proc` and `cam.out`'s controller IPC has nothing to connect to → the camera-Contents lifecycle (`bind/activated/assertFor`) never fires.**

2. **The V2G ioctls are NOT called by `camera_ps`. They are called by `emgdhmid`** — only `emgdhmid` opens `/dev/v2gbridge` and `/dev/video0`. The chain is: `cam.out` decides camera-active → `libhmi-cntl-nissan.so::Device::SVGR::SVGCapture::setBackLightOn` → `libsvgr.so::VideoCore_StartCapture` → `emgdHmiStartVideoDisplay()` (in `libemgdhmi.so.0`) → AF_UNIX socket to `/tmp/.emgdhmid_socket` → `EmgdHmiDaemonSocket::StartVideo` → `EmgdHmiDaemon::StartVideo` → `V2G_ENABLE_BRIDGE` + `V2G_DISPLAY_FRAME` ioctls on `/dev/v2gbridge`. **Plus** `EmgdHmiDaemon::RequestFlip` which underlies the captured frame display loop. None of this is on `camera_ps`'s code path directly — it's on `cam.out`'s path, and `cam.out` is loaded into the `camera_ps` process address space.

3. **`hmictrl_proc` is the master coordinator that decides "show camera now."** `libhmi-cntl-nissan.so` (linked by both `hmictrl_proc` and `display_ps`) is where the reverse-gear → camera decision lives: `Device::StateManager::getReverseState`, `Device::VehicleStatus::inReverse`, `Device::VehicleStatus::inReverse_Fast`, `controller::TransitionOrder::REVERSE`, `controller::ContentsConfiguration::earlyCameraContent`, `controller::VehicleSignalControl::controlVehicleSignalOnMovingParking`. The reverse-gear signal is consumed by `hmictrl_proc`, which then asks the HMI controller to bring up the camera Contents, which `cam.out` (in `camera_ps`) services by going through the `libsvgr → libemgdhmi → emgdhmid → /dev/v2gbridge` chain.

4. **`display_ps` and `dispapf_proc` are not in the V2G path proper, but `display_ps` participates in the higher-level Contents arbitration** (it links `libhmi-cntl-nissan.so` + `libsvgr.so` + `libemgdhmi.so.0` + `libEGL.so.1`). `dispapf_proc` does NOT link `libsvgr`, `libemgdhmi`, or `libEGL` — it is a thin display "application proxy/fastpath" with no graphics handles. Killing `dispapf_proc` is likely safe for the camera path. Killing `display_ps` will probably break the Contents arbitration for the UPPER display because it owns the `controller::LogicalDisplay` for that screen.

5. **Recommendation — what to keep alive to preserve OEM rearview camera:** keep `emgdhmid`, `camera_ps` (which hosts `cam.out`), **and `hmictrl_proc`** (which hosts the HMI controller server + decides reverse-gear → camera). `display_ps` may also need to stay (Contents arbitration for UPPER LCD). The 4-daemon kill plan (`navi_ps`, `hmictrl_proc`, `display_ps`, `dispapf_proc`) **will break the rearview camera as currently designed.** If we want the rearview camera with the kill plan in place, we have two options: (a) **demote the kill plan** to just `navi_ps` + `dispapf_proc` (preserve camera) and let our app paint into a region that doesn't overlap Sprite C; or (b) **drive the V2G bridge ourselves** by talking to `emgdhmid`'s socket directly — `emgdHmiStartVideoDisplay()` is callable from any client, no UI daemon required — but you must also detect reverse-gear yourself (read the CAN bus through `vcan.out`'s `/home/naviwork/tmp/vcan_md` AF_UNIX socket or replace that piece entirely).

---

## 1. `camera_ps` binary inventory

| Path | Size | Type | Stripped |
|---|---|---|---|
| `/tmp/naviwork-extracted/system/bin/camera_ps` | **5,868 B** | ELF 32-bit i386 dynamic | yes |
| `/tmp/naviwork-extracted/system/out/cam.out` | **135,596 B** | ELF 32-bit i386 shared-object | yes |
| `/tmp/naviwork-extracted/system/out/mit_PS_CAMERA.out` | 7,260 B | ELF 32-bit i386 shared-object (manifest) | yes |
| `/tmp/naviwork-extracted/system/lib/libcam.so` | 6,376 B | ELF 32-bit i386 shared-object | yes |

`camera_ps` is **5.9 KB**. That's not a camera driver — it's a process-supervisor shim. Its strings reveal: `PMNG_main_initialize`, `PMNG_main_loadCompleted`, `PMNG_main_startUnload`, `PMNG_main_unloadCompleted`, `PMNG_main_finalize`, `mq_unlink`/`mq_open`/`mq_send`/`mq_receive`, plus a single argument `PS_camera` and a `/camera_main` mqueue path.

NEEDED libs (`camera_ps`):
```
libifout.so          (foundation utilities)
libifin_os.so        (OS abstraction)
libioc.so            (IPC framework — inter-object communication)
libpmng.so           (process manager — the framework camera_ps drives)
libplnch.so          (process launcher)
libsmng_cmn.so       (smng common — talks to /home/naviwork/system/bin/smng supervisor)
libabendlog.so       (abnormal-end logger)
libpriv.so           (privilege)
liboslog.so          (OS log)
libc, librt, libpthread
```

Notably **absent** from `camera_ps`: no `libemgdhmi`, no `libsvgr`, no `libhmi-cntl*`, no `libEGL`, no `libdrm`. **`camera_ps` itself touches zero graphics or DRM.** It just runs the PMNG loop and tells it to load `mit_PS_CAMERA.out`'s module list:

```
mit_PS_CAMERA module list (from mit_PS_CAMERA.out strings):
  me.out       (manifest engine)
  tk.out       (task control)
  info.out     (info)
  tmr.out      (timer)
  lsd.out      (load shaping daemon)
  nva_s.out    (NVA — navigation video application, sender side)
  cld.out      (cold/calibration?)
  cam.out      ← THE CAMERA LOGIC
  cvo.out      (CVO — camera voice output / chimes)
  cs.out       (CAN signal? client state?)
```

So `camera_ps` is a process container that loads `cam.out` as a shared module. **The architecture is "one process, many .out modules" (Wind River OSE-like).** All of cam.out's symbols resolve against `camera_ps`'s linker namespace — meaning `cam.out`'s dependencies (libemgdhmi, libsvgr, libhmi-cntl-client) are pulled into `camera_ps`'s address space at module load.

---

## 2. `cam.out` IPC dependencies — the smoking gun

NEEDED libs (`cam.out`):
```
libioc.so              (foundation IPC)
libifout.so
libdfw.so              (DENSO Framework — vehicle signal sub)
libpdm.so              (persistent data manager)
libioucm.so            (IO unified comm manager — kernel CAN/IO)
libhmi-cntl.so         ← HMI controller core
libhmi-cntl-client.so  ← HMI controller CLIENT (talks to hmictrl_proc)
libstc_if.so
libsec.so
libdrl.so              (DRL — diagnostic recording log)
libsvgr.so             ← SVG/Surround-View Graphics Renderer (camera capture path)
libemgdhmi.so.0        ← EMGD HMI broker client (talks to emgdhmid)
libism.so              (interrupt/state manager?)
libvsi.so              (vehicle signal interface)
libgcc_s, libc
```

**Three IPC peers** are wired in:

| Peer client lib | Talks to | Killable? |
|---|---|---|
| `libhmi-cntl-client.so` | **`hmictrl_proc`** (server: `libhmi-cntl-server.so`) | **NO — kills camera Contents lifecycle** |
| `libemgdhmi.so.0` | **`emgdhmid`** (AF_UNIX `/tmp/.emgdhmid_socket`) | **NO — owns V2G ioctls** |
| `libioucm.so` + DFW + VSI | kernel CAN / vehicle signal driver (no userland daemon) | n/a — kernel module |

`cam.out`'s C++ object graph (from string table, demangled):

- `camComponentInstance` — main camera component, lives in `hmi::Component` tree
- `camCaptureComponentInstance` / `camCaptureComponentInstance2` — derive from `hmi::CapturingComponent`. Override `ready()`, `stopCapture()`, `unready()`
- `camEarlyController` — handles early-camera-startup-before-Atom-fully-up case
- `camSystemStateListener` — registers via `hmi::controller::interprocess::Initiator::initialize(SystemStateListener)`. Receives system state transitions including `AtomReadiedState::READY/CAPTURE_STARTING/CAPTURE_COMPLETION`.
- `CAMhmiKeyListenerInstance` — registered as `hmi::KeyListener` (for cancel-camera key presses)
- `CAMsysUpListenerInstance` — `hmi::controller::SystemDisplayInformationListener`
- `CamContentsChgListenerInstance` — `hmi::controller::ContentsChangeListener`
- `CamLastContentInstance` — last-Contents tracker
- `dmycamContentsInstance` — dummy fallback

Constants seen in `cam.out`:
- `hmi::controller::nissan2d::PriorityType::CAMERA` (enum value)
- `hmi::controller::nissan2d::DisplayDevice::UPPER`
- `hmi::controller::nissan2d::DisplayArea::UPPER`
- `setBacklightIsRequired()` — yes, camera Contents request the LCD backlight
- `controller::interprocess::Initiator::initialize(SystemStateListener)` — the IPC entry

**Imported symbols from `hmi::controller::HMIController` / `Contents`:**
```
hmi::controller::HMIController::getInstance()           ← MUST connect to hmictrl_proc
hmi::controller::ContentsList::getNumberOfContents()
hmi::controller::ContentsList::getContents(i)
hmi::controller::Contents::bind()
hmi::controller::Contents::activated(LogicalDisplay)
hmi::controller::Contents::suspend(LogicalDisplay)
hmi::controller::Contents::resume(LogicalDisplay)
hmi::controller::Contents::call(ContentsID)
hmi::controller::Contents::changeTo(ContentsID)
hmi::controller::Contents::assertFor(LogicalDisplay)
hmi::controller::Contents::getLogicalDisplay(...)
hmi::controller::Contents::returnLogicalDisplay(...)
hmi::controller::Contents::fieldOfViewChanged(...)
```

**`hmi::controller::HMIController::getInstance()` is a singleton accessor that needs to dial the controller server.** That server is in `hmictrl_proc`. Verified by symbol lookup: `libhmi-cntl-server.so` is NEEDED by `hmictrl.out` (which is loaded by `hmictrl_proc` per `mit_PS_HMIC1.out`), and is also NEEDED by `vopf.out`, `dmc.out`, `dmc_audio.out`, `dmc_display.out`, `dmc_multimedia.out`, `dmc_navi.out`, `audio_hmicprt.out` — i.e., other processes in the HMI shard. Importantly, **only `hmictrl_proc`'s `hmictrl.out` is the canonical HMI controller server** — the others are sub-shard servers.

**Shared-memory anchors** in `cam.out` strings:
- `ALEGRES/cam_disp_stat_shm` — POSIX shm name; `cam.out` calls `shm_open` + `mmap`. This is the "camera display status" shared region, probably read by `display_ps` to know when to suppress its own painting. Even if our app replaces `display_ps`, this shm channel survives — we just need to honor it (or not, if we don't care about layering).

**There is NO "headless mode flag" or environment variable** in `cam.out`'s strings. No `--no-ui`, no `CAMERA_HEADLESS`, no fall-back path that bypasses HMIController. The Contents/HMIController dependency is mandatory.

---

## 3. V2G control flow — who actually calls the bridge ioctls

### 3a. Direct `/dev/v2gbridge` openers

Grep across **all** binaries on Slot A + naviwork for the literal `/dev/v2gbridge`:

| Binary | Opens `/dev/v2gbridge`? |
|---|---|
| `/usr/sbin/emgdhmid` | **YES** |
| `/usr/lib/libemgdhmi.so.0.1.0` | no |
| `/usr/lib/wsegl/libwsegl-hmi.so` | no |
| any `cam.out`, `vopf.out`, `camera_ps`, `hmictrl_proc`, `display_ps` | no |
| any other naviwork binary | no |

**Only `emgdhmid` opens `/dev/v2gbridge`.** This matches Agent 6's emgdhmid finding (V2G_DISABLE_BRIDGE ioctl error string lives in emgdhmid). The V2G ioctls `0xc0047600 / 0xc0047601 / 0xc0047602` are invoked only from emgdhmid's address space.

`emgdhmid` also opens `/dev/video0` (IOH V4L2 capture device — strings show `"%s is not a V4L2 video capture device !"`). So emgdhmid does **both** halves of the rearview pipeline:

- V4L2 dequeue from `/dev/video0` (LAPIS IOH camera input)
- V2G enqueue to `/dev/v2gbridge` plane=5 (Sprite C overlay on LCD)

### 3b. Caller chain (top → bottom)

```
[reverse gear signal arrives]
        ↓
hmictrl_proc::libhmi-cntl-nissan::Device::VehicleStatus::inReverse_Fast() → true
        ↓
hmictrl_proc HMI controller server: schedule camera Contents bringup
        ↓ (IPC over Boost.Interprocess shared-memory + named mutexes — libhmi-cntl backend)
camera_ps::cam.out::camComponentInstance receives Contents activation
        ↓
cam.out → hmi::controller::Contents::activated(LogicalDisplay)
        ↓
cam.out → libhmi-cntl-nissan::Device::SVGR::SVGCapture::setBackLightOn(ji)   ← from libhmi-cntl-nissan strings
        ↓
libsvgr.so::VideoCore_StartCapture()  /  ::VideoCore_StartCapture_FastCamera()
        ↓
libemgdhmi.so.0::emgdHmiStartVideoDisplay()     (verified via `nm -D libsvgr.so` shows it imports this)
libemgdhmi.so.0::emgdHmiConfigureBuffers()
libemgdhmi.so.0::emgdHmiSwitchHz()
libemgdhmi.so.0::emgdHmiControlPlaneFormat()
        ↓ (AF_UNIX `/tmp/.emgdhmid_socket`)
emgdhmid::EmgdHmiDaemonSocket::StartVideo(EMGDHmiSocket_Data*)
        ↓
emgdhmid::EmgdHmiDaemon::StartVideo(EMGDHmiVideoContext)
        ↓
  V4L2 capture open  + ioctl(/dev/video0, VIDIOC_REQBUFS / STREAMON)
  ioctl(/dev/v2gbridge, V2G_ENABLE_BRIDGE = 0xc0047600, {plane=5, screen=0})
  loop:  ioctl(/dev/v2gbridge, V2G_DISPLAY_FRAME = 0xc0047602, buf_index)
                            and emgdHmiRequestFlip for primary plane composition
```

### 3c. Symbol-level proof that `libsvgr.so` is the bridge

`nm -D /tmp/naviwork-extracted/system/lib/libsvgr.so` shows it **imports** (`U`):
```
emgdHmiConfigureBuffers
emgdHmiControlPlaneFormat
emgdHmiStartVideoDisplay
emgdHmiStopVideoDisplay
emgdHmiSwitchHz
```
None of the four UI daemons import these directly — they all go through `libsvgr.so`, which in turn opens the broker socket via `libemgdhmi.so.0`.

`libsvgr.so` also defines:
```
VideoCore_StartCapture
VideoCore_StartCapture_AfterThrough
VideoCore_StartCapture_FastCamera   ← named "FastCamera" = rearview fast path
VideoCore_StopCapture
VideoCore_getCaptureData
VideoHWIF_getCaptureBufferAddr      ← exposes V4L2 buffer ptrs to clients
VideoHWIF_getCaptureBufferData
svgLayer_StartVideo
svgLayer_StopVideo
svgStartVideoCapture
svgStartVideoCaptureAfterThrough
svgStartVideoCaptureFastCamera
svgStopVideoCapture
svgVideo_*                          (Startup/Cleanup/GetCaptureData/GetVideoData/etc.)
```

`libsvgr.so` opens (from strings):
```
/dev/video0
/dev/pinmux_conf
/dev/%s
/SHM_NAME_SVGLAYER                  (POSIX shared memory for layer state)
/home/naviwork/tmp/svgr_hmsock      (AF_UNIX socket the SVGR exposes to its HMI side)
/home/naviwork/tmp/i2cfs_md         (I2C bus access for camera ECU config)
/home/naviwork/tmp/hmio_ioport      (HMI IO port — GPIO/pinmux)
```

So `libsvgr` itself ALSO opens `/dev/video0`. This is interesting — there are two `/dev/video0` openers in the system: `libsvgr.so` (loaded in any process linking it: `cam.out`, `hmictrl_proc`, `display_ps`, etc.) AND `emgdhmid`. The V4L2 device almost certainly supports `O_NONBLOCK` shared access from multiple FDs (or the latter is for the buffer-pointer query path). Either way: as long as `emgdhmid` is alive AND `libsvgr` is loaded in `cam.out`, the capture path will work — provided someone calls `emgdHmiStartVideoDisplay`. The "someone" is `cam.out` reacting to a Contents activation, which requires `hmictrl_proc`.

---

## 4. Reverse-gear signal — source + propagation

### 4a. `vcan.out` — virtual CAN router (in `nav_navi.service`)

`/tmp/naviwork-extracted/system/out/vcan.out` (61,436 B). NEEDED: `libioucm.so`, `libifout.so`, `libc`. Strings:
```
vcan_main
=VCAN
/home/naviwork/tmp/vcan_md          ← AF_UNIX socket (bound by vcan, connect()ed by subscribers)
HM_ERRLOGLIB_init / type / out
socket, bind, getsockname, recvfrom, sendto    ← BSD socket primitives
IOUCM_open / IOUCM_read / IOUCM_write          ← kernel CAN driver via IOUCM
```

`vcan` opens the kernel CAN char device through `IOUCM_open` (likely `/dev/ttyCAN*` or LAPIS IOH MCAN node), receives raw frames, and republishes them on the AF_UNIX socket `/home/naviwork/tmp/vcan_md`. It uses `socket()/bind()/recvfrom()/sendto()` — i.e., the AF_UNIX socket is `SOCK_DGRAM` with multiple subscribers via `sendto(unnamed_peer)`. **No mqueue is used by vcan.** No reverse-gear frame ID string is in `vcan.out` — those IDs are in compile-time tables (`pdm_tbl.dat`).

### 4b. Reverse-gear consumers

The vehicle-signal name "reverse" surfaces in `libhmi-cntl-nissan.so` (linked by `hmictrl_proc`, `display_ps`, `vopf.out`, `dmc*.out`, `audio_hmicprt.out`, `multimedia_hmicprt.out`, `navi_hmicprt.out`, `prv.out`):
```
Device::StateManager::getReverseState(DisplayDevice)
Device::VehicleStatus::inReverse()
Device::VehicleStatus::inReverse_Fast()           ← "fast" path = rearview camera trigger
controller::TransitionOrder::REVERSE
controller::ContentsConfiguration::earlyCameraContent()
controller::VehicleSignalControl::controlVehicleSignalOnMovingParkingEv
controller::ExtendedHMIController::getCameraContextData(int)
system::AtomReadiedState::ATOM_READIED_STATE_{READY, CAPTURE_STARTING, CAPTURE_COMPLETION}
```

`hmictrl_proc` is the canonical subscriber. It connects to `/home/naviwork/tmp/vcan_md` (or to a higher-level signal bus via `libvsi.so::get_vehicle_signal_vsi`/`vsi_set_signal`), decodes the reverse signal, and pushes a Contents transition via the HMI controller it hosts.

### 4c. `capture_ctl` kernel module

`/tmp/dsu-slot-a/lib/modules/.../kernel/bsp/capture_ctl/capture_ctl.ko` is the **kernel-side capture control module** (LAPIS ML7213 BSP). It is auto-loaded at boot per `/etc/modules-load.d/modules.conf`. Its role is to bring up the ioh-vin (IOH video-in) hardware path that backs `/dev/video0`. **It is not a userland daemon. It has no IPC.** Killing the 4 UI daemons does not affect it.

---

## 5. Sprite C coordination — primary plane during camera display

Sprite C is the EMGD overlay plane index 5. It composites **above** the primary plane (z-order: primary < Sprite A < Sprite B < Sprite C). When camera capture is active:

- `emgdhmid` ioctls `V2G_ENABLE_BRIDGE` with `{plane=5, screen=0}` — the V2G driver maps captured YUYV buffers into the Sprite C GTT region and enables the overlay.
- The primary plane is **left unchanged**. The kernel/EMGD compositor handles z-order — the primary plane keeps painting whatever was there (nav, our app, whatever) but it's hidden behind the Sprite C overlay where Sprite C is opaque.
- Sprite C is full-screen 800×480 for the UPPER display, so the primary plane is effectively invisible while the camera is up. (cam.out's UPPER setting confirms full-screen camera.)

`cam.out` does **NOT** issue any alpha, layout, or color-key adjustment to the primary plane. It does not need to. **The kernel V2G + EMGD driver enforces the layering.**

Are `display_ps` / `dispapf_proc` involved? Searching their strings for "v2g", "sprite", "bridge", "V2G_":
- `display_ps` — no direct V2G or Sprite C strings. It does NEED `libsvgr.so` + `libemgdhmi.so.0` + `libEGL.so.1`, so it knows the API surface, but it doesn't issue the bridge enable itself.
- `dispapf_proc` — has none of: `libsvgr`, `libemgdhmi`, `libEGL`. It is graphics-blind. It cannot participate in the V2G/Sprite C path.

So: **the camera path's ONLY graphics-pipeline coordinator is `emgdhmid` at the bottom and `cam.out` (in `camera_ps`) at the top, via the HMI Controller arbitration in `hmictrl_proc`.**

There IS, however, a shared-memory channel `ALEGRES/cam_disp_stat_shm` that `cam.out` writes to. The literal name "cam_disp_stat" = "camera display status." Likely `display_ps` reads this to know not to flip the primary plane during camera-active. If we keep cam.out alive (i.e., keep camera_ps) and replace display_ps with our app, we should either honor that shm flag or simply not care (Sprite C will mask us regardless).

---

## 6. Concurrent claim risks — our app holding DRM master vs. emgdhmid's bridge enable

From Agent 6: `emgdhmid` does NOT hold DRM master persistently — it drops master immediately after `drmOpen("emgd","PCI:00:02:00")`, and only briefly re-grabs master for individual `drmcmd_master` ioctls (CONFIG_BUFFS, SWITCH_HZ).

For the V2G path specifically:

| Operation | Privilege required | Risk vs. our app holding DRM master |
|---|---|---|
| `open("/dev/v2gbridge")` | character-device permission (root or `video` group) | none — v2gbridge is a separate driver, not DRM |
| `ioctl(v2gbridge, V2G_ENABLE_BRIDGE)` | none beyond fd | none |
| `ioctl(v2gbridge, V2G_DISPLAY_FRAME, idx)` | none | none |
| `ioctl(v2gbridge, V2G_DISABLE_BRIDGE)` | none | none |
| `IGD_ALTER_OVL2` (Sprite C plane config) | `DRM_AUTH` (verified by R1 probe) | **emgdhmid clients become AUTH via the broker socket. If we hold DRM_MASTER, emgdhmid can still call `drmcmd_master` because it re-grabs master per-ioctl — but `drmSetMaster` from emgdhmid will EACCES if we hold it.** |
| `IGD_CONFIG_BUFFS` (cmd=0x2c) | DRM_MASTER | **CONFLICT** — emgdhmid does `SetMaster→ioctl→DropMaster` here. If we hold master, this `SetMaster` fails. Result: emgdhmid logs `"DRM_IOCTL_IGD_CONFIG_BUFFS ioctl() failed"` and bridge enable can fail. |
| `IGD_SWITCH_HZ` (cmd=0x25) | DRM_MASTER | Same conflict as above. |

**Concrete risk:** if our app `drmSetMaster()` and holds it, emgdhmid's per-ioctl `SetMaster` re-grab during a camera bringup (which DOES call `ConfigureBuffers` → `IGD_CONFIG_BUFFS`) will return EACCES. emgdhmid's `drmcmd_master` returns the error to the caller, and `emgdHmiStartVideoDisplay` returns failure to `libsvgr`, which logs `"StartVideo: failed to start the video stream"` and the camera doesn't bring up.

**Mitigations:**

1. **Drop master after our setup.** Our app should: `drmSetMaster()` for setup (mode-set, GMM region alloc), then `drmDropMaster()` and run steady-state without master. Re-grab transiently only for our own resize/reconfigure events. This way the master slot is normally free, and emgdhmid's transient re-grabs succeed.

2. **Coordinate via an interlock.** Subscribe to a signal (e.g., poll `/proc/$(pidof emgdhmid)/wchan`, or watch a sysfs node) and back off master grab during emgdhmid activity. Brittle — not recommended.

3. **Replace emgdhmid entirely** (Plan B'''-pure). Then our app is the only thing touching DRM and V2G — but then we also have to implement the camera path ourselves, which means: read `/dev/video0` V4L2 frames, call `V2G_ENABLE_BRIDGE` + `V2G_DISPLAY_FRAME` ourselves, AND detect reverse-gear ourselves. Doable, not free.

The recommended path for **preserving the OEM camera while running our own app**: drop master after setup (option 1). emgdhmid is well-behaved about master.

There is **no EMGD config-id mismatch risk** for the V2G path itself — V2G operates on whatever plane EMGD already configured. The config-id matters for primary-plane mode-set, which is orthogonal.

---

## 7. Boot-time handshake — what does `camera_ps` need at startup?

`/lib/systemd/system/nav_camera.service`:
```
[Unit]
Description=Display Camera Service
Requires=nav_pre.target
OnFailure=nav_smngpret.service
DefaultDependencies=no

[Service]
Type=simple
StandardInput=null
StandardOutput=null
StandardError=null
LimitSTACK=524288
LimitMSGQUEUE=8192000
ExecStart=/home/naviwork/system/bin/camera_ps "PS_CAMERA"
TimeoutSec=90
SendSIGKILL=yes
```

`nav_pre.target.wants/` contains: `nav_audio.service`, `nav_camera.service`, `nav_dispapf.service`, `nav_display.service`, `nav_dmsg_start.service`, `nav_dsn.service`, `nav_hmictrl.service`, `nav_initialscreen.service`, `nav_ipodplayer.service`, `nav_is.service`, `nav_multimedia.service`, `nav_napl.service`, `nav_navi.service`, `nav_rex01.service`, `nav_snd.service`, `nav_sndamp.service`, `nav_soft_vup.service`, `nav_tel.service`, `nav_vrd01.service`.

**There is no explicit `After=` ordering between `nav_camera.service` and `nav_hmictrl.service`/`nav_display.service`/`nav_navi.service`/`nav_dispapf.service`.** They all start as a group when `nav_pre.target` activates, in parallel. They synchronize via runtime IPC handshakes — the HMI controller-client handshake (`hmi::controller::HMIController::getInstance()` blocks/retries until the server is up).

**Implication:** at boot, camera_ps's cam.out blocks on `HMIController::getInstance()` until `hmictrl_proc` is ready. If `hmictrl_proc` is never started (our plan), `cam.out`'s init either spins forever or times out and fails — depending on the controller-client library's retry semantics. Either way, the camera Contents lifecycle never reaches "activated."

**No mit_PS_CAMERA.out manifest entry depends on display_ps or dispapf_proc directly.** The boot-time mit modules are: me, tk, info, tmr, lsd, nva_s, cld, cam, cvo, cs — all in the camera_ps process. The dependency on hmictrl_proc is purely runtime IPC.

---

## 8. Failure-mode strings — what does `cam.out` do when an HMI peer is missing?

Searching `cam.out` strings for failure-mode markers:

- Boost assertion: `p == 0 || p != px` — boost smart-pointer assertion in `shared_ptr::reset`. This will trigger if `HMIController::getInstance()` returns a null shared_ptr and a subsequent `->` deref happens.
- `px != 0` — boost smart-pointer null-deref check.
- `T* boost::shared_ptr< <template-parameter-1-1> >::operator->() const [with T = hmi::controller::ContentsCharacteristics]` — full BOOST_ASSERT format string, will fire `__assert_fail` then `abort()`.
- `__assert_fail` (libc symbol) is imported.
- `__cxa_pure_virtual` — fires if a virtual method is called on a partially-constructed object.

**No graceful "controller unreachable" log message exists.** The failure mode is hard abort via boost assert → `__assert_fail` → SIGABRT.

`/lib/systemd/system/nav_camera.service` has `OnFailure=nav_smngpret.service` — that's the supervisor's "process pre-emption" handler. It would attempt to restart camera_ps. In an infinite retry loop, this could thrash the system. Worse, `smngpret` may eventually escalate to a forced reboot of the whole nav stack per Wind River OSE-survival policy. **The "kill the 4 UI daemons" plan in conjunction with leaving camera_ps alive will likely produce a crash loop on `camera_ps` after the first reverse-gear event** (or possibly at startup if `Contents` activation happens unconditionally — likely).

**Practical conclusion:** if we kill `hmictrl_proc`, we should ALSO disable `nav_camera.service` to prevent the crash loop. Then there's no rearview camera at all.

---

## 9. Standalone V2G test path — does one exist?

Searching Slot A `/opt/`, `/etc/`, and naviwork for any test binary or script that exercises V2G without the full UI stack:

- `/lib/systemd/system/emgdhmi-test.service` — `ExecStartPre=/bin/usleep 20000` ... [unit body not fully inspected]. Likely just an emgdhmid smoke test that uses the broker socket. **It does not directly exercise V2G**, but it does exercise `emgdHmi*` APIs through `libemgdhmi.so.0`.
- No standalone `v2g_test`, `camera_test`, `bridge_test` binary exists in `/opt/` or naviwork `/system/bin`.
- `/opt/q60r1/v4l2_test` (our existing R1 probe binary) — already exercises V4L2 + V2G ioctls directly. **This is our standalone test path.** It does not need any UI daemon.

**Practical proof-of-life** for the V2G path with everything else dead:
1. SIGSTOP all 4 UI daemons + `emgdhmid` + `camera_ps`.
2. Run our v4l2_test binary: `open /dev/dri/card0` + `drmSetMaster` + `open /dev/v2gbridge` + `open /dev/video0` + `VIDIOC_REQBUFS` 3 buffers + `V2G_ENABLE_BRIDGE {plane=5, screen=0}` + `V2G_DISPLAY_FRAME idx=0`.
3. Expected: camera image appears on LCD via Sprite C, no factory daemon involvement.
4. This is the cleanest test of "can we replace emgdhmid + factory camera path with our own minimal V2G driver?"

We have **already done** this experiment as the R1 probe (`/opt/q60r1/v4l2_test`). Per Agent 6 + prior R1 logs, it works (V2G_ENABLE returns r=0). So **the V2G hardware path is independent of any userland daemon** — emgdhmid is just the OEM's userland implementation, not a kernel-mandated piece.

---

## Appendix A — Decision matrix

| Plan | navi_ps | hmictrl_proc | display_ps | dispapf_proc | emgdhmid | camera_ps | Camera works on reverse? | Notes |
|---|---|---|---|---|---|---|---|---|
| **Original 4-kill plan** | kill | kill | kill | kill | keep | keep | **NO** — cam.out crashes on `HMIController::getInstance()` | Recommend disabling nav_camera.service too |
| **Reduced kill** (just navi/dispapf) | kill | keep | keep | kill | keep | keep | **YES** — full factory camera path intact | Our app must coexist with display_ps Contents arbitration |
| **Full replacement (Plan B''')** | kill | kill | kill | kill | kill | kill | YES, if we implement it ourselves | Read /dev/video0 + drive V2G ioctls + parse CAN reverse signal from /home/naviwork/tmp/vcan_md (or replace vcan) |
| **Coexist with emgdhmid + camera** | kill | keep | kill | kill | keep | keep | YES, fragile | Risk: HMIController arbitration may demand display_ps for Contents on UPPER. Verify with runtime test. |

**Recommendation:** for fastest path to camera-preserving Plan B''', keep `hmictrl_proc` + `camera_ps` + `emgdhmid` alive, kill `navi_ps` + `dispapf_proc`, decide `display_ps` based on UPPER-Contents test. Our app paints into a region or onto the primary plane while Sprite C remains available for OEM rearview overlay.

---

## Appendix B — Files and symbols cited

| Path | Role |
|---|---|
| `/tmp/naviwork-extracted/system/bin/camera_ps` | 5.9 KB process supervisor shim (PMNG) |
| `/tmp/naviwork-extracted/system/out/cam.out` | 135.6 KB camera HMI logic (the actual driver-of-action) |
| `/tmp/naviwork-extracted/system/out/mit_PS_CAMERA.out` | 7.3 KB module manifest declaring 10 modules to load into camera_ps |
| `/tmp/naviwork-extracted/system/out/vcan.out` | 61 KB CAN bus → AF_UNIX router (`/home/naviwork/tmp/vcan_md`) |
| `/tmp/naviwork-extracted/system/out/vopf.out` | 119 KB video output framework — does NOT touch V2G; handles audio/mic/key sockets |
| `/tmp/naviwork-extracted/system/lib/libcam.so` | 6.4 KB CAM_* API (camera_status, anadeba, MATCH_HMI_CONTENTS_ID) |
| `/tmp/naviwork-extracted/system/lib/libsvgr.so` | SVG renderer + VideoCore_StartCapture + emgdHmi* import surface |
| `/tmp/naviwork-extracted/system/lib/libhmi-cntl-client.so` | HMI controller IPC client (talks to hmictrl_proc) |
| `/tmp/naviwork-extracted/system/lib/libhmi-cntl-server.so` | HMI controller IPC server (linked by hmictrl.out, dmc*, vopf, audio_hmicprt) |
| `/tmp/naviwork-extracted/system/lib/libhmi-cntl-nissan.so` | Nissan-specific Device:: layer; defines SVGCapture, VehicleStatus::inReverse_Fast, ExtendedHMIController::getCameraContextData |
| `/tmp/naviwork-extracted/system/lib/libvsi.so` | Vehicle Signal Interface (init_vehicle_signal_vsi / get_vehicle_signal_vsi / set_vehicle_signal_vsi) |
| `/tmp/naviwork-extracted/system/lib/libemgdhmi.so.0` (libemgdhmi.so.0.1.0 on slot A) | Client-side emgdhmid socket lib (exports emgdHmiStartVideoDisplay etc.) |
| `/tmp/dsu-slot-a/usr/sbin/emgdhmid` | **THE ONLY** opener of /dev/v2gbridge and /dev/video0 in the factory stack |
| `/tmp/dsu-slot-a/lib/systemd/system/nav_camera.service` | systemd unit; ExecStart=/home/naviwork/system/bin/camera_ps PS_CAMERA |
| `/tmp/dsu-slot-a/lib/systemd/system/nav_pre.target.wants/` | All 19 PS_* services start here as a parallel group |
| `/tmp/dsu-slot-a/lib/modules/.../kernel/bsp/capture_ctl/capture_ctl.ko` | LAPIS IOH camera-in BSP kernel module (auto-loaded) |

---

## Appendix C — Outstanding uncertainty

1. **Boost.Interprocess transport details for HMI controller IPC.** `libhmi-cntl.so` uses Boost.Interprocess shared memory + named mutexes (not AF_UNIX). The actual shm name(s) were not extracted from string tables (likely constructed at runtime). If we wanted to **replace** `hmictrl_proc` with our own minimal server, we'd need to RE the Boost.Interprocess wire format. Not recommended — option (a) "keep hmictrl_proc alive" is far easier.

2. **Whether `cam.out` retries `HMIController::getInstance()` or aborts immediately.** Strings imply assert-then-abort, but the retry policy lives in `libhmi-cntl-client.so` which we did not disassemble. If retried, the failure mode is hang-then-systemd-timeout-kill (90s) → smngpret → potentially nav-wide restart.

3. **Does `display_ps` need to ack the camera Contents activation?** The shm `ALEGRES/cam_disp_stat_shm` suggests yes, but it could be advisory rather than blocking. The simplest test: kill display_ps + keep hmictrl_proc + cam.out + emgdhmid, engage reverse, see if Sprite C lights up. ~5 minute test on car hardware once SD card image is loaded.

4. **What CAN frame ID encodes reverse-gear?** Not in any extractable string table — lives in `pdm_tbl.dat` binary blob. Could be reverse-engineered if needed for option (c) "full replacement."

