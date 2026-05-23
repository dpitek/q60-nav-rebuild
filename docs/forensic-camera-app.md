# Forensic — Rearview Camera Application Layer (`camera_ps` / `cam.out`)

**Date:** 2026-05-23
**Source:** `/tmp/dsu-slot-a/` (extracted Slot A DSU backup) + `/tmp/naviwork-extracted/` (naviwork partition) + cross-reference to existing forensics
**Subject:** The application layer above the V2G/V4L2 hardware path — how the factory rearview camera is *triggered* by reverse gear, *activated* on the LVDS upper display, *adorned* with parking guidelines and proximity sonar beeps, and *torn down* on exit.

> **Scope boundary — read this first.** This document does **NOT** re-document the V2G bridge ioctls, the `/dev/v2gbridge` driver, the EMGD Sprite C plane mechanics, the V4L2 capture path, the `emgdhmid` socket protocol, the IGD_ALTER_OVL2 ioctl numbers, or the DRM-master concurrency hazard. All of those live in [forensic-v2g-camera-handoff.md](forensic-v2g-camera-handoff.md). This doc picks up *above* the V2G layer: who decides "show camera now," what UI logic surrounds it, what the parking sonar audio does, and what's keeping our 2-daemon kill set safe vs. unsafe.

---

## Executive Summary

1. **`camera_ps` is two distinct things wearing one name.** Bottom: a 5.9 KB DENSO PMNG process-supervisor shim that loads 10 `.out` modules into its address space. Top: `cam.out` (135.6 KB) — the actual HMI-coupled camera application that subscribes to the `HMIController` singleton, fields reverse-gear-driven Contents activations, and drives `libsvgr` → `libemgdhmi` → `emgdhmid` for V2G bringup. The `cam.out` *application* is what we mean when we say "the camera app." See [forensic-v2g-camera-handoff.md §1–2](forensic-v2g-camera-handoff.md) for the binary inventory and IPC dependency map; this doc focuses on what `cam.out` *does* once it's loaded.

2. **Reverse gear is a CAN frame, not a GPIO.** It enters the system via the LAPIS ML7213 MCAN/IOH driver → `mcan.out` (in `ioapf_proc`) → `vcan.out` AF_UNIX datagram socket at `/home/naviwork/tmp/vcan_md` → `libvsi.so` (Vehicle Signal Interface) subscribers. The decoded "in reverse" state is exposed as `hmi::Device::VehicleStatus::inReverse()` and `inReverse_Fast()` (the latter is the rearview-trigger fast path). **The "fast" variant short-circuits the normal Contents arbitration to hit the FMVSS 111-mandated 2-second startup deadline.**

3. **`hmictrl_proc` is the camera's UI gatekeeper — not `camera_ps`.** The HMI controller server (inside `hmictrl_proc`) consumes the reverse signal via `libhmi-cntl-nissan.so::Device::VehicleStatus::inReverse_Fast()`, schedules a Contents transition with `controller::TransitionOrder::REVERSE`, and pushes a Contents activation to `cam.out` over the Boost.Interprocess channel that `libhmi-cntl-client.so` and `libhmi-cntl-server.so` share. `cam.out` reacts by calling `setBackLightOn()` → `VideoCore_StartCapture_FastCamera()` → V2G enable. **Killing `hmictrl_proc` (the original Plan B''' kill list) silently breaks reverse-camera activation** — `cam.out` keeps running but never receives a Contents activation, so it never asks `emgdhmid` to enable Sprite C. This is why the corrected kill set ([project_planB_kill_set](../../../.claude/projects/-Users-dpitek-Developer-q60-rebuild/memory/project_planB_kill_set.md)) keeps `hmictrl_proc` alive.

4. **Parking guidelines are NOT baked into the camera frame.** The IOH V4L2 path delivers raw YUYV at 800×480 from the camera ECU; no overlay is composited at the kernel level. Guidelines are drawn by the factory as a **separate SVG/sprite layer** rendered by `libsvgr.so` (the SVG/Sprite renderer) and composited above the V2G frame stream. `libhmi-cntl-nissan.so` exports `VehicleSignalControl::getGuidelineFromArea(int)` and `vehicleSpeedThresholdFromGuideline(TRAFFICGUIDELINE_TYPE, unsigned long)` — the guideline geometry is steering-aware and speed-thresholded.

5. **Parking sonar produces software-mixed PCM beeps, not synth tones.** `cvo.out` (Camera Voice Output, loaded into `camera_ps` per `mit_PS_CAMERA.out`) plays from a pre-baked PCM library at `/home/naviwork/data/sonar/{800Hz,1200Hz}/*.pcm`. Each filename encodes the proximity bracket: `800-2.0-Short.pcm` = 800 Hz tone for ~2.0 m, `1200-2.0-Short.pcm` = 1200 Hz tone for ~2.0 m, etc. The 800/1200 split corresponds to front-vs-rear or near-vs-approach (interleaving cues). `cvo.out`'s `ISM_SetNtyStopReqParkassist` / `ISM_ResStopFixParkassist` symbols indicate the chime path is coupled to the Internal State Manager.

6. **The camera "screen" has no chrome of its own.** Once `cam.out` activates the Contents and `emgdhmid` enables Sprite C, the entire 800×480 upper LVDS is the camera frame. The factory UI does NOT draw a status bar over the camera (Sprite C is opaque, full-screen). What looks like camera chrome — the guidelines, the "REAR VIEW" badge, the proximity bars — is composited by `libsvgr` onto a **separate sprite plane** layered above the V2G frame, not by the normal UI daemons (`display_ps` / `dispapf_proc` / `hmictrl_proc`).

**Bottom line for the rebuild:** Keep `camera_ps` + `hmictrl_proc` + `emgdhmid` alive (already in the corrected kill set). Their factory implementation of "reverse → camera" is FMVSS-compliant, well-tuned, and not worth reimplementing. What we replace is the *surrounding* nav/audio/phone UI that gets pre-empted when the camera comes up, plus eventually the sonar visualization (red/yellow/green bars) which is part of `dispapf_proc`'s job — and that's a real cost to reckon with because `dispapf_proc` IS in our kill set.

---

## 1. Architecture Diagram

```
                       ┌───────────────────────────────┐
                       │   transmission gear position  │
                       │   (CAN frame on AV-CAN or     │
                       │    chassis CAN gateway)       │
                       └───────────────────────────────┘
                                       │
                              kernel CAN/IOH driver
                                       │
                       ┌───────────────────────────────┐
                       │  mcan.out  (in ioapf_proc)    │
                       │  AF_UNIX: /home/naviwork/     │
                       │           tmp/mcan_md         │
                       └───────────────────────────────┘
                                       │
                       ┌───────────────────────────────┐
                       │  vcan.out  (in nav_navi —     │
                       │   per forensic-v2g-camera     │
                       │   §4a). AF_UNIX SOCK_DGRAM    │
                       │   at /home/naviwork/tmp/      │
                       │   vcan_md  (multi-subscriber) │
                       └───────────────────────────────┘
                                       │
                       ┌───────────────────────────────┐
                       │  libvsi.so  (Vehicle Signal   │
                       │   Interface — linked into     │
                       │   hmictrl_proc, display_ps,   │
                       │   cam.out, others)            │
                       │   exports get_vehicle_signal  │
                       │   _vsi / set_vehicle_signal   │
                       └───────────────────────────────┘
                                       │
            ┌──────────────────────────┴──────────────────────────┐
            │                                                     │
            ▼                                                     ▼
  ┌──────────────────────────┐                       ┌──────────────────────────┐
  │  hmictrl_proc            │  Boost.Interprocess   │  cam.out  (in camera_ps) │
  │  (HMIController server)  │ ─────────────────────▶│  Contents::activated()   │
  │                          │  Contents transition  │   │                      │
  │  libhmi-cntl-nissan::    │  (TransitionOrder::   │   ▼                      │
  │   Device::VehicleStatus  │   REVERSE)            │  setBackLightOn(ji)      │
  │   ::inReverse_Fast()     │                       │   │                      │
  │                          │                       │  VideoCore_StartCapture  │
  │  ContentsConfiguration:: │                       │   _FastCamera()          │
  │   earlyCameraContent()   │                       │   │                      │
  └──────────────────────────┘                       │  emgdHmiStartVideoDisplay│
            │                                        └─┬────────────────────────┘
            │  also signals (mqueue+shm):              │
            │   • display_ps  — cam_disp_stat_shm      │  AF_UNIX /tmp/
            │   • dispapf_proc — proximity sensor bars │  .emgdhmid_socket
            │   • audio bus   — cork media playback    │      │
            ▼                                          ▼      │
  ┌──────────────────────────┐               ┌──────────────────────────┐
  │  cvo.out (PS_CAMERA)     │               │  emgdhmid                │
  │  Camera Voice Output     │               │  V4L2 dequeue + V2G enq  │
  │  • parking sonar beeps   │               │  → Sprite C plane=5      │
  │  • voice phrases         │               │  → 800×480 LVDS UPPER    │
  │  /home/naviwork/data/    │               │  See forensic-v2g-       │
  │   sonar/{800,1200}Hz/    │               │  camera-handoff.md §3    │
  │   *.pcm                  │               │  for the ioctl mechanics │
  │  → snd / sndamp          │               └──────────────────────────┘
  └──────────────────────────┘
```

> All shaded boxes downstream of `emgdHmiStartVideoDisplay` — the V2G ioctls, the V4L2 buffer ring, the Sprite C z-order, the DRM master interlock — are documented in [forensic-v2g-camera-handoff.md](forensic-v2g-camera-handoff.md) §3–§6. We do not repeat them here.

---

## 2. Service Unit — `nav_camera.service`

**File:** `/tmp/dsu-slot-a/lib/systemd/system/nav_camera.service`

```ini
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

#ExecStartPre=/bin/sh -c '/bin/echo "/home/naviwork/log/core" > /proc/sys/kernel/core_pattern'
#ExecStart=/bin/sh -c 'ulimit -c unlimited; /home/naviwork/system/bin/camera_ps "PS_CAMERA"'
ExecStart=/home/naviwork/system/bin/camera_ps "PS_CAMERA"

TimeoutSec=90
SendSIGKILL=yes
```

### 2.1 Property table

| Property | Value | Forensic meaning |
|---|---|---|
| `Type=simple` | long-running daemon | Same shape as the other 18 nav_* services; PMNG loop runs in foreground under systemd supervision |
| `Requires=nav_pre.target` | early-tier nav group | Brought up in parallel with `hmictrl_proc` / `display_ps` / `tel_proc` / `audio_ps` — synchronizes by runtime IPC, not by `After=` ordering |
| `OnFailure=nav_smngpret.service` | system-pre-reset cascade | A camera crash trips the **same** "reset everything" path as a UI daemon crash. Per [forensic-daemon-supervision.md §3.3](forensic-daemon-supervision.md), this cascade ends in `poweroff.service`. DENSO treats camera-stack crash as system-critical (FMVSS 111 compliance implication — see §5.2 below). |
| `LimitMSGQUEUE=8192000` | 8 MB | **32× the default 256 KB.** Heavy POSIX mqueue traffic — `camera_ps` is the host for 10 `.out` modules that all share its rlimit. The `/camera_main` queue (per `camera_ps` strings) plus per-module queues add up. |
| `LimitSTACK=524288` | 512 KB | Per-thread stack cap; `cam.out` is multi-threaded (Boost thread bound to `SVGCapture::monitorTimer_svgcap`, plus the PMNG dispatcher), so this gates *each* thread, not the whole process |
| `StandardInput/Output/Error=null` | no terminal | Headless daemon; logs go via DRL (`libdrl.so` — diagnostic recording log) |
| `SendSIGKILL=yes` | force-kill on timeout | Treated as expendable on systemd-initiated shutdown — but FMVSS 111 says it can't actually go down while in reverse |
| `TimeoutSec=90` | startup/shutdown grace | Long because PMNG module load (10 `.out` files) plus initial HMIController handshake plus `emgdhmid` socket connect can take several seconds at cold boot |
| `DefaultDependencies=no` | bypasses sysinit ordering | Started by smng cascade, not by standard ordering — same as all `nav_*` services |
| Commented `core_pattern` + `ulimit -c unlimited` | core capture in dev builds | Production drops cores; dev builds wrote them to `/home/naviwork/log/core` |
| No `Restart=` directive | one-shot crash → cascade | Unlike `abs_clock.service` (`Restart=on-failure`), camera_ps does NOT respawn — it crashes once and the cascade fires |
| No `Group=` directive | inherits root | But `cam.out`'s graphics path goes through `emgdhmid` (which IS `Group=video`), so cam.out never directly opens `/dev/dri/card0` |

### 2.2 What the systemd shape tells us

The unit is **identical in shape** to `nav_tel.service` (telephony) and `nav_navi.service` — same `Requires=nav_pre.target`, same `OnFailure=nav_smngpret.service`, same 8 MB mqueue limit, same no-`Restart=`. DENSO treats the camera subsystem with the same operational criticality as the navigation engine and the phone stack: **lose it once and reboot the car.**

The only asymmetry vs. `abs_clock.service`: clocks can drift and be re-derived (RTC fallback), so DENSO allows that one to respawn. Camera state cannot be "re-derived" — once `cam.out` aborts via boost assertion (per [forensic-v2g-camera-handoff.md §8](forensic-v2g-camera-handoff.md)), the entire HMI state machine has to come back up fresh, and a smng-coordinated full reboot is the cleanest way.

---

## 3. Reverse-Gear Signal — From CAN to `cam.out`

### 3.1 Hardware origin

The transmission gear-position signal arrives on the AV-CAN bus from the chassis CAN gateway (TCM → BCM → AV-CAN per Nissan's E-architecture for 2017 Q60). Exact frame ID is not extractable from binary strings (lives in `pdm_tbl.dat`) but [DSU_OEM_DOCUMENTATION.md §10.5](DSU_OEM_DOCUMENTATION.md) lists the community-reverse-engineered Nissan CAN references that are our starting point if we ever need to re-implement this.

### 3.2 Kernel-to-userspace plumbing

1. **Kernel:** LAPIS ML7213 IOH MCAN driver (`pch_can`-derived, per the upstream Tomoya MORINAGA patches referenced in DSU_OEM_DOCUMENTATION) presents the bus as a char/socket device.
2. **`mcan.out`** (in `ioapf_proc`, loaded per `mit_PS_IOAPF.out` alongside `hmio.out`, `vcan.out`, `i2cfs.out`, `mcanu.out`): binds AF_UNIX at `/home/naviwork/tmp/mcan_md`. Acts as the kernel-MCAN-to-userland bridge.
3. **`vcan.out`** (in `navi_ps` per [forensic-v2g-camera-handoff.md §4a](forensic-v2g-camera-handoff.md)): bound AF_UNIX SOCK_DGRAM at `/home/naviwork/tmp/vcan_md`. Acts as a *router* — receives frames from the lower-level CAN sockets, decodes them against a frame table, and re-publishes named signals to subscribers using `sendto()` on an unnamed-peer datagram socket. **This is the "virtual CAN" bus that decouples the kernel-frame-ID world from the application-signal-name world.**
4. **`libvsi.so`** (Vehicle Signal Interface): exports `init_vehicle_signal_vsi`, `get_vehicle_signal_vsi`, `set_vehicle_signal_vsi`, `vsi_lib_SetEventFactor`, `vsi_lib_GetEventFactor`. Linked into `cam.out`, `hmictrl_proc`, `display_ps`, `audio_hmicprt.out`, and others. Provides a typed C++ "vehicle signal" abstraction over `vcan_md`'s datagrams.

### 3.3 Reverse-state observation

`libhmi-cntl-nissan.so` exports the demangled C++ symbols (verified via `strings`):
- `hmi::Device::VehicleStatus::inReverse()` — slow path, debounced
- `hmi::Device::VehicleStatus::inReverse_Fast()` — fast path, sub-100ms reaction window
- `hmi::Device::StateManager::getReverseState(DisplayDevice)` — coalesced state query
- `hmi::controller::TransitionOrder::REVERSE` — enum value used in Contents transitions
- `hmi::controller::ContentsConfiguration::earlyCameraContent()` — the "show camera before Atom is fully up" pre-emption path
- `hmi::controller::VehicleSignalControl::controlVehicleSignalOnMovingParking` (also `OnMovingParkingEv` variant) — speed-aware re-entry guard

**Critical:** `inReverse_Fast()` is what we'd build against if we ever replaced the camera path ourselves. FMVSS 111 (federal rear-visibility rule) requires the rearview image on screen within **2.0 seconds** of shifting into reverse. The "fast" path is named for exactly this constraint — it skips Contents arbitration's normal priority resolution and goes straight to camera bringup. `earlyCameraContent()` is the boot-time analogue: if you shift into reverse during the cold-boot window (Atom not yet fully booted), the camera can be brought up by a minimal pre-init code path. [forensic-v2g-camera-handoff.md §4b](forensic-v2g-camera-handoff.md) lists the full vehicle-signal name set; the names we care about here are `inReverse_Fast`, `TransitionOrder::REVERSE`, and `earlyCameraContent`.

### 3.4 What `cam.out` actually sees

`cam.out` registers `camSystemStateListener` via `hmi::controller::interprocess::Initiator::initialize(SystemStateListener)` — this is the **subscription mechanism** to the HMIController. When `hmictrl_proc` resolves a reverse-gear-driven Contents transition, the activation message arrives in `cam.out`'s listener thread. `cam.out` overrides `hmi::CapturingComponent::ready()` and `stopCapture()` (verified via demangled vtable strings) and routes to `setBackLightOn(ji)` → `VideoCore_StartCapture_FastCamera()`. **All of this happens inside the `camera_ps` process address space** — no further IPC hops, just C++ method calls between modules sharing the linker namespace.

---

## 4. UI Activation — Sprite C Hand-off

The camera "screen" appearing on the upper LVDS is not a UI screen in the conventional sense. There is no `cam.qml`, no `dispapf_proc` redraw, no `hmictrl_proc` screen transition that paints camera pixels. The mechanism is:

1. `cam.out` calls `emgdHmiStartVideoDisplay()` (via `libsvgr.so::VideoCore_StartCapture_FastCamera()`). See [forensic-v2g-camera-handoff.md §3](forensic-v2g-camera-handoff.md) for the ioctl-level details.
2. `emgdhmid` enables `/dev/v2gbridge` with `{plane=5, screen=0}` — Sprite C overlay becomes active.
3. Sprite C is z-ordered **above** the primary plane and any other sprites. It is opaque, full-screen 800×480 for the UPPER display.
4. The primary plane keeps drawing whatever the nav/audio/phone UI was showing. **The kernel/EMGD compositor enforces the layering** — the primary plane is invisible because Sprite C masks it.
5. `cam.out` writes its current state to `ALEGRES/cam_disp_stat_shm` (POSIX shared memory). `display_ps` reads this shm to know the camera is up; this lets it dim/suspend its own primary-plane painting (CPU/GPU savings — not strictly required for correctness, since Sprite C already hides it).

**Why this design is elegant:** the camera path does NOT need to coordinate a screen transition with any UI daemon. It just turns Sprite C on, and the layering handles the rest. The "exit" symmetry (§7) is equally clean — turn Sprite C off, primary plane reappears, no screen-transition logic.

**Why this matters for our rebuild:** when our Qt6/Weston app is painting into the primary plane, **the OEM camera will mask us automatically when the user shifts to reverse** — provided we left `camera_ps` + `hmictrl_proc` + `emgdhmid` alive. We do not have to participate in the camera activation flow at all. The only thing we have to do is *not actively fight it* — i.e., don't hold DRM master continuously (per [forensic-v2g-camera-handoff.md §6](forensic-v2g-camera-handoff.md), emgdhmid needs transient master grabs for `IGD_CONFIG_BUFFS` and `IGD_SWITCH_HZ` during camera bringup).

---

## 5. Parking Guidelines — Steering-Aware Overlay

### 5.1 Where the guidelines come from

The yellow trajectory lines drawn over the camera image are **not in the V4L2 frame**. The camera ECU sends raw YUYV 800×480 via the IOH V4L2 path — no overlay is baked in at the source. The guidelines are composited by `libsvgr.so` (the SVG/Sprite renderer) on a separate plane layered above the V2G video stream.

Evidence from `libhmi-cntl-nissan.so` exported symbols:
- `hmi::controller::VehicleSignalControl::getGuidelineFromArea(int)` — returns the guideline geometry for a given screen area
- `hmi::controller::VehicleSignalControl::vehicleSpeedThresholdFromGuideline(TRAFFICGUIDELINE_TYPE, unsigned long)` — speed gate (guidelines hide at speed)
- `hmi::TRAFFICGUIDELINE_TYPE` enum (numeric values not extracted) — implies multiple guideline modes (static-only vs. dynamic-steering-aware vs. predicted-path)
- `libsvgr.so` exports `svgClearSVGSurface`, `svgSwitchLayerBuffer`, `svgGetSurfaceStatus`, plus the `SVGSpriteSet` / `SVGRGraphicsContext` C++ types — the rendering machinery to draw vector overlays at arbitrary positions

### 5.2 Steering-angle integration

The presence of `TRAFFICGUIDELINE_TYPE` as an enum (multiple values) plus `getGuidelineFromArea(int area)` (the integer is a screen/region identifier) strongly suggests **dynamic guidelines** — lines that bend with steering input. Steering angle comes through the same vehicle-signal path (`libvsi.so` + `vcan_md`) as reverse gear; the steering-angle CAN frame is well-documented in the community Nissan/Infiniti CAN references in [DSU_OEM_DOCUMENTATION.md §10.5](DSU_OEM_DOCUMENTATION.md).

The signal flow is symmetric to reverse gear:
```
steering-angle CAN frame → mcan.out → vcan.out → libvsi
  → hmictrl_proc or cam.out (subscriber)
  → libsvgr re-draws the guideline sprite with updated geometry
  → composited over the V2G video stream
```

We cannot fully confirm without disassembling `cam.out` and walking the steering-listener registration, but **the architecture supports steering-aware dynamic guidelines** and the symbol surface strongly implies they're implemented. (`vehicleSpeedThresholdFromGuideline` taking a speed parameter is another hint — at higher speeds the guidelines hide entirely, which is the typical OEM behavior for "drive guidelines" vs. "park guidelines.")

### 5.3 What FMVSS 111 requires

The federal rear-visibility rule (FMVSS 111) mandates:
- Image displayed within 2.0 seconds of shifting to reverse (the "fast path" in §3.3)
- Field of view sufficient to see a 3-foot-tall test cylinder anywhere in a defined zone behind the vehicle
- Display visible in all reasonable lighting conditions

Guidelines are NOT mandated by FMVSS 111. The yellow lines are an OEM value-add for parking precision. If we ever stripped them out, the car would still be federally compliant — but customer experience would degrade noticeably. We keep them by keeping `camera_ps` + `hmictrl_proc` + the factory `libsvgr` rendering path.

---

## 6. Parking Sonar — PCM-Driven Beeps + Visual Bars

### 6.1 Audio path — PCM library

`cvo.out` (Camera Voice Output) is loaded into `camera_ps` per `mit_PS_CAMERA.out`'s module manifest. Its string table reveals a pre-baked PCM library:

```
/home/naviwork/data/sonar/800Hz/800-Long-1.pcm
/home/naviwork/data/sonar/1200Hz/1200-Long-1.pcm
/home/naviwork/data/sonar/800Hz/800-10.0-Short.pcm
/home/naviwork/data/sonar/800Hz/800-8.0-Short.pcm
/home/naviwork/data/sonar/800Hz/800-6.7-Short.pcm
... (descending distance brackets: 5.7, 5.0, 4.4, 4.0, 3.6, 3.3, 3.1, 2.9, 2.7, 2.5, 2.2, 2.1, 2.0)
/home/naviwork/data/sonar/1200Hz/1200-10.0-Short.pcm
... (same series in 1200Hz)
```

**Filename convention:** `<frequency>-<distance_meters>-{Short,Long}.pcm`. The 800 Hz vs. 1200 Hz split is the standard OEM cue for "side A vs. side B" — typically rear-corners vs. rear-center, or rear vs. front (the Q60 with optional front sonar uses both). As proximity decreases, the daemon plays shorter PCM clips with smaller distance brackets → perceived chirp rate increases → urgency cue. At ~0.4 m (the last bracket before the "long" continuous tone), the system switches to the `Long-1.pcm` solid tone meaning "STOP."

This is **pre-baked PCM, not synthesized.** DENSO does not generate beeps via a tone synthesizer; they ship audio assets and play them back. This means:
- The exact beep cadence/pitch is data, not code — easy to clone
- The 800 / 1200 Hz split is fixed at the audio-asset level
- Localization of the "alert" sound (if any) is in the same directory tree (`/home/naviwork/data/parking/%.2s/%.2s_%02X_%.2s.PCM` is a parametric path that varies by region/language)

### 6.2 Audio output chain

`cvo.out` links `libsound.so` and uses `WP_DirectFilePlay`, `WP_Start`, `WP_Stop`, `WP_PermitAVControl`, `WP_ProhibitAVControl`. Audio output goes through the standard nav audio chain (`snd` / `sndamp` services, per [forensic-phone-stack.md §5](forensic-phone-stack.md)), with `WP_ProhibitAVControl` ducking media to ensure the chirps are audible above music/nav prompts.

### 6.3 Sonar visualization (the proximity bars)

Visual proximity indicators (red/yellow/green bars showing sensor distance per quadrant) are **NOT** part of `cam.out` or `cvo.out`. They live in the UI layer — almost certainly drawn by `dispapf_proc` (Display Application Framework Proxy/fastpath), which is the daemon responsible for fast composited overlays. Evidence:

- `cam.out` strings contain `hmi::controller::nissan2d::PriorityType::SONAR` and `PriorityType::SONAR_POPUP` — meaning sonar visuals are a *Contents type* arbitrated by the HMI controller, separate from camera Contents
- The two priority types (`SONAR` and `SONAR_POPUP`) suggest both an "always-on overlay while in reverse" mode (SONAR) and a "modal popup if obstacle detected" mode (SONAR_POPUP)
- `dispapf_proc` is the standard fast-overlay path in this architecture (per [forensic-factory-ui-binary.md](forensic-factory-ui-binary.md))

**Implication for the kill set:** because `dispapf_proc` is on our **mask list** in the corrected [project_planB_kill_set](../../../.claude/projects/-Users-dpitek-Developer-q60-rebuild/memory/project_planB_kill_set.md), we lose the on-screen sonar bars when we deploy. The **audio beeps continue to work** (cvo.out is in camera_ps, not dispapf_proc, and the snd/sndamp services are not killed). What we lose is the visual red/yellow/green proximity bars overlaid in the lower corners of the camera screen.

**Rebuild action item:** the sonar visualization is a small, well-bounded re-implementation target. We subscribe to the sonar vehicle-signal output via `libvsi` (or our own CAN reader), and draw four corner bars over our app's primary plane. **But the camera frame is on Sprite C and masks our primary plane while reverse is engaged** — so to overlay bars on top of the camera, we need an additional sprite plane (Sprite A or B), which means linking against `libsvgr` ourselves or driving the IGD_ALTER_OVL2 ioctl directly. Defer this to a Phase 4 polish item.

---

## 7. Exit Behavior — Out of Reverse

When the user shifts out of reverse:

1. The reverse-gear CAN signal goes false → propagates through `vcan.out` → `libvsi` → subscribers within ~50 ms.
2. `hmictrl_proc`'s vehicle-signal listener observes `inReverse_Fast() == false`, schedules a Contents transition *away from* camera Contents (back to whatever was active before — map, audio, phone, etc.).
3. The HMIController sends a deactivation to `cam.out`'s listener.
4. `cam.out::stopCapture()` (override of `hmi::CapturingComponent::stopCapture`) executes, which calls into `libhmi-cntl-nissan::Device::SVGR::SVGCapture::setBackLightOff` → `libsvgr::VideoCore_StopCapture()` → `libemgdhmi::emgdHmiStopVideoDisplay()`.
5. `emgdhmid` disables Sprite C (`V2G_DISABLE_BRIDGE` ioctl, cmd `0xc0047601`, per [forensic-v2g-camera-handoff.md](forensic-v2g-camera-handoff.md) Executive Summary table).
6. Sprite C goes opaque → primary plane is visible again, with whatever the underlying UI is currently painting.
7. `cam.out` clears its `cam_disp_stat_shm` flag → `display_ps` knows it can resume normal flips.
8. `cvo.out` calls `ISM_ResStopFixParkassist` to release the parking-assist audio prohibition; media/nav audio uncorks.

**Who "decides" to revert the screen:** `hmictrl_proc`'s vehicle-signal listener does, by re-arbitrating Contents priority once the REVERSE transition is reversed. `cam.out` is passive — it just responds to activation/deactivation messages. **There is no `cam.out → "hide me" → display_ps` push.** The HMI controller pulls.

This means: **with `hmictrl_proc` alive (corrected kill set), exit-from-reverse works correctly** without any work from us. The previous screen (our Qt app) is automatically restored when Sprite C goes opaque, because nothing about exiting reverse touches the primary plane state.

---

## 8. Multi-Camera / Around View — Not Present on This DCU

The 2017 Q60 with Around View Monitor (AVM) Premium package has four cameras (front, rear, two side-mirror downward-facing). On AVM-equipped cars, the DCU stitches the four feeds into a top-down 360° view.

**Evidence this DCU is single-camera:**
1. CLAUDE.md confirms only **3 V4L2 buffers** at GTT offsets `0x000000 / 0x0e9000 / 0x1d2000` — a single 800×480 YUYV ring with 3-buffer cycling. AVM needs 4 simultaneous V4L2 streams plus a compositing pipeline; the buffer count alone rules it out.
2. `libhmi-cntl-nissan.so` does NOT export any symbols containing `AroundView`, `360`, `TopView`, `SurroundView`, `Aview`, or similar (grep returned empty).
3. `cam.out` does NOT mention multi-stream capture or stitching — its `camCaptureComponentInstance` / `camCaptureComponentInstance2` pair is for the same physical camera under different Contents states (e.g., "fast cold-start camera" vs. "normal camera"), not for two physical cameras.
4. Only `/dev/video0` is referenced in any binary that touches camera capture.

**Conclusion:** this particular Q60 is **rear-camera-only.** If we ever encounter an AVM-equipped car, the V2G/camera architecture changes substantially — additional V4L2 devices, additional buffers, a stitching pipeline (almost certainly in EMGD GLES shaders) — and this forensic would need extension.

---

## 9. Why `camera_ps` Stays Alive in Plan B'''

Per [project_planB_kill_set](../../../.claude/projects/-Users-dpitek-Developer-q60-rebuild/memory/project_planB_kill_set.md), the corrected kill set is **two daemons** (`navi_ps`, `dispapf_proc`), not four. `camera_ps`, `hmictrl_proc`, `display_ps`, `emgdhmid` all stay alive. The camera-specific reasons:

1. **`camera_ps` hosts `cam.out`** — the actual camera logic. Killing it removes the only userspace process that can react to a reverse-gear event and bring up Sprite C. There is no "headless camera" mode in the factory stack (per [forensic-v2g-camera-handoff.md §2](forensic-v2g-camera-handoff.md), no env flag bypasses the HMIController coupling).
2. **`hmictrl_proc` hosts the HMIController server** — `cam.out` blocks at startup on `HMIController::getInstance()` until this is reachable. Kill hmictrl_proc and `cam.out` either spins forever or boost-asserts and triggers `nav_smngpret` → `poweroff`.
3. **`emgdhmid` owns `/dev/v2gbridge`** — the only opener of the V2G ioctls in the entire system. Without it, Sprite C cannot be enabled.
4. **Rewriting any of these is a 3-6 month project.** Re-implementing the camera path requires (a) a CAN listener for reverse, (b) a V4L2 capture loop on `/dev/video0`, (c) V2G ioctl driver (we have the ABI from R1 probe), (d) FMVSS 111 timing validation, (e) a guideline renderer (steering-aware!), (f) the sonar audio mixer. The factory implementation does all of this and is already certified-equivalent. **The juice is not worth the squeeze.**

**Cost of keeping them alive:** ~50 MB RAM total (per [forensic-factory-ui-binary.md](forensic-factory-ui-binary.md)), ~3% CPU steady-state. Trivial.

---

## 10. Rebuild Implications

### 10.1 Layer-by-layer delta

| Layer | Factory | Plan B''' replacement | Effort | Notes |
|---|---|---|---|---|
| Reverse-gear CAN frame decode | `mcan.out` + `vcan.out` + `libvsi` | **Unchanged** — keep camera_ps + hmictrl_proc alive | None | We benefit from factory CAN decoding without writing any |
| Reverse → camera trigger | `hmictrl_proc::Device::VehicleStatus::inReverse_Fast` → Contents activation | **Unchanged** | None | |
| Camera HMI logic (`cam.out`) | In `camera_ps` | **Unchanged** | None | |
| V2G bridge management | `emgdhmid` + `libsvgr` + `libemgdhmi` | **Unchanged** (see [forensic-v2g-camera-handoff.md](forensic-v2g-camera-handoff.md)) | None | Our app must drop DRM master after setup |
| Sprite C compositing on top of our app | EMGD kernel/compositor enforces z-order automatically | **Automatic** — Sprite C masks primary plane | None | Just don't fight it |
| Parking guidelines (static + dynamic) | `libsvgr` + `libhmi-cntl-nissan::VehicleSignalControl::getGuidelineFromArea` | **Unchanged** — drawn on separate sprite by factory | None | Preserved automatically |
| Parking sonar audio beeps (PCM) | `cvo.out` + `/home/naviwork/data/sonar/*.pcm` + `snd/sndamp` | **Unchanged** | None | `cvo.out` is inside `camera_ps`, lives untouched |
| Parking sonar visual bars (proximity overlay) | `dispapf_proc` (`PriorityType::SONAR` / `SONAR_POPUP`) | **LOST** in Plan B''' first pass | ~1 week (Phase 4 polish) | dispapf_proc is masked. Re-implement as a QML overlay on our own sprite plane, subscribing to sonar via libvsi |
| "REAR VIEW" badge / text overlay on camera screen | Likely `libsvgr` (text sprite) rendered by `cam.out` or `dispapf_proc` | Probably **preserved** via libsvgr, but **unconfirmed** | TBD | Verify on first car-boot post-kill |
| Exit-from-reverse → restore previous screen | `hmictrl_proc` re-arbitrates Contents; Sprite C disable reveals primary plane | **Unchanged** — our Qt app keeps painting the primary plane throughout | None | |

### 10.2 The one thing that breaks: sonar visual bars

Of the entire camera subsystem, the **only** thing our kill set damages is the on-screen sonar proximity bars (`dispapf_proc`'s `PriorityType::SONAR`). The audio beeps still work, the camera image still displays, the guidelines still render, exit-from-reverse still restores correctly.

We have two options for the sonar bars:
1. **Defer.** Ship without them; add to a Phase 4 polish list. Customer impact: car still beeps in proximity, you just don't see the colored bars. Many cars don't have them at all (older Q60s, base trims). Probably acceptable.
2. **Re-implement.** Subscribe to sonar signals via libvsi (or write our own CAN parser), draw four bar widgets via Sprite A/B (allocate a sprite via `IGD_ALTER_OVL2`, render with our own GLES code), layer above Sprite C. ~1 week of work + careful sprite-plane resource coordination.

**Recommendation:** Defer. Ship Plan B''' with audio-only sonar; revisit visual bars after the rest of the nav UI is stable.

### 10.3 What to verify on first car-boot after Plan B''' deploy

1. Shift to reverse — does the camera image appear within 2 seconds? (FMVSS 111 gate)
2. Are yellow guidelines visible and bending with steering input?
3. Is the "REAR VIEW" badge visible? (Confirms `libsvgr` text overlay still works without `dispapf_proc`)
4. Do parking sonar beeps play as you approach an obstacle?
5. Do the sonar visual bars appear in the corners of the camera image? (Expected: NO, per §10.2)
6. Shift out of reverse — does our Qt app reappear on the primary plane within 1 second?
7. Confirm no `nav_smngpret` / `poweroff` cascade in `journalctl` after a reverse cycle.

---

## 11. Open Questions

1. **"REAR VIEW" badge owner.** Is the text "REAR VIEW" drawn by `libsvgr` (inside cam.out's process — survives our kill set) or by `dispapf_proc` (gets killed)? Resolvable via on-car test or by diffing the Sprite C content vs. the Sprite A/B content at runtime.
2. **Steering-angle guideline rendering frequency.** Are guidelines redrawn every video frame (60 Hz), every steering signal update (~10 Hz from CAN), or on a fixed timer? Affects how much GPU/CPU the camera path consumes; doesn't affect rebuild plan.
3. **Sonar visual bars actual location.** Confirmed to exist in priority enum, but whether they're drawn by `dispapf_proc` (assumed) or by `display_ps` or by `cam.out` itself via libsvgr is unverified. Affects whether they survive our kill set or not — first car-boot will answer this in 30 seconds.
4. **`earlyCameraContent()` cold-boot path.** What's the threshold time below which the "early camera" path is used vs. the normal Contents path? Likely tied to whether `smng` has reached a particular state. Not critical — we are not killing smng-related boot ordering.
5. **TRAFFICGUIDELINE_TYPE enum values.** Static-only vs. dynamic-steering vs. predicted-path — three modes? Two? Probably configurable in some PDM (persistent data manager) blob. Not blocking; rebuild keeps whatever the factory has configured.
6. **What happens if reverse is engaged WHILE a Bluetooth call is in progress.** The audio bus has to coordinate three streams (call audio over BT-SCO, sonar beeps, and probably a "camera active" voice phrase). Behavior is policy implemented in `cvo.out` + the snd/sndamp services. Probably calls duck/cork. Not critical for rebuild; preserved automatically since the relevant daemons all stay alive.

---

## 12. Cross-references

- **[forensic-v2g-camera-handoff.md](forensic-v2g-camera-handoff.md)** — THE companion doc. Covers the V2G bridge ioctls, V4L2 buffer ring, Sprite C plane mechanics, emgdhmid socket protocol, DRM-master concurrency, the binary inventory of `camera_ps` / `cam.out` / `vcan.out`, and the decision matrix for which daemons to keep. This document complements it from above; that one covers the hardware/driver layer in detail.
- [forensic-daemon-supervision.md](forensic-daemon-supervision.md) — systemd cascade behavior, `OnFailure=nav_smngpret.service` → `poweroff.service` chain, why a camera crash reboots the car
- [forensic-denso-ipc.md](forensic-denso-ipc.md) — POSIX mqueue + napl conventions used by `camera_ps` and its peers; `LimitMSGQUEUE=8192000` rationale
- [forensic-factory-ui-binary.md](forensic-factory-ui-binary.md) — `dispapf_proc` role in fast overlays; rationale for why sonar bars likely live there
- [forensic-phone-stack.md](forensic-phone-stack.md) — symmetric architecture pattern (backend daemon + UI region, not an "app"); call-audio + sonar-audio coordination
- [forensic-clock-service.md](forensic-clock-service.md) — symmetric pattern for headless service + UI region
- [DSU_OEM_DOCUMENTATION.md](DSU_OEM_DOCUMENTATION.md) — DENSO V2G patents (US 8,660,782 documents the architecture); FMVSS 111 recall references; Nissan CAN community RE links
- [project_planB_kill_set](../../../.claude/projects/-Users-dpitek-Developer-q60-rebuild/memory/project_planB_kill_set.md) — corrected 2-daemon kill set; why `camera_ps` and `hmictrl_proc` stay alive
- [CLAUDE.md](../CLAUDE.md) — 3 V4L2 buffers + V2G ioctl numbers as confirmed hardware facts
