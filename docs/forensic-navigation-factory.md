# Forensic — Factory Navigation Stack (`navi_ps` / PS_NAVI + map partitions + routing)

**Date:** 2026-05-23
**Source:** `/tmp/dsu-slot-a/` (extracted Slot A DSU backup) + cross-reference to existing forensics + Doug's `~/Developer/nissan-nav-updater` reverse engineering of the map partitions
**Subject:** How the factory Q60 head unit implements turn-by-turn navigation — the `navi_ps` daemon, its map data, GPS/CAN inputs, routing engine, voice prompts, rendering pipeline, and search backend. This is the system we are explicitly REPLACING in Plan B'''.

---

## Executive Summary

1. **There is one factory nav process: `navi_ps "PS_NAVI"`.** Started by [`nav_navi.service`](../tmp/dsu-slot-a/lib/systemd/system/nav_navi.service) under systemd, ExecStart=`/home/naviwork/system/bin/navi_ps "PS_NAVI"`. It is the heaviest single application on the DCU — it owns the map renderer, the GPS/dead-reckoning fusion, the routing engine, the address/POI search backend, voice-prompt scheduling, and visual chrome (route line, vehicle arrow, compass, ETA strip). The on-screen "Settings → Navigation" sub-screens are owned by `hmictrl_proc`, but the actual lookups and route compute live in navi_ps. Per [project_planB_kill_set.md](../../../.claude/projects/-Users-dpitek-Developer-q60-rebuild/memory/project_planB_kill_set.md), navi_ps is **one of two daemons** Plan B''' masks at boot.

2. **Service unit shape is identical to the four UI daemons.** `Type=simple`, `Requires=nav_pre.target`, `OnFailure=nav_smngpret.service`, `DefaultDependencies=no`, `LimitSTACK=524288` (512 KB — same as the UI siblings), `LimitMSGQUEUE=8192000` (8 MB — same as the UI siblings), `SendSIGKILL=yes`, `Type=simple`, no `Restart=`, all stdio = `null`. No explicit `Environment=LD_LIBRARY_PATH=` directive in the production unit (commented-out hint in `nav_hmictrl.service` shows the same path the other UI daemons inherit at runtime, which includes `/usr/lib/wsegl` — see §1.2). Per [forensic-daemon-supervision.md](forensic-daemon-supervision.md) §2.1, navi_ps's crash path triggers the smng cascade → `nav_smngpret.service` → stop `nav_smng.service` → `OnFailure=nav_backup.service` → **poweroff**. SIGTERM-via-`systemctl stop` is safe (unit goes `inactive`, not `failed`); a naive `kill` is not.

3. **Binary is not on Slot A.** `navi_ps` lives at `/home/naviwork/system/bin/navi_ps` on the `LABEL=homenaviwork` ext4 partition mounted by [`home-naviwork.mount`](../tmp/dsu-slot-a/lib/systemd/system/home-naviwork.mount) (note: `OnFailure=poweroff.service` on the mount itself — losing naviwork reboots the car). Same situation as `hmictrl_proc`/`display_ps`/`dispapf_proc` per [forensic-factory-ui-binary.md](forensic-factory-ui-binary.md) §1.2. We have NOT disassembled it; behavior below is triangulated from the service unit + the DENSO IPC contract documented in [forensic-denso-ipc.md](forensic-denso-ipc.md) + the EGL/HMI contract documented in [forensic-factory-ui-binary.md](forensic-factory-ui-binary.md) + Doug's binary reverse-engineering of the map partitions in `~/Developer/nissan-nav-updater`.

4. **Map data is on a SEPARATE physical SD card** — not on naviwork, not on eMMC. The factory ships a Clarion CLA-NAVI06-01-formatted SD card with NAVTEQ 14Q4 (Jan 2015) data, organized as 5 binary partitions (`MAPAL001`, `REFER001`, `REFER002`, `HOUSE001`, `RDSTM001`). Map data is **read-only at runtime**; updates happen offline by SD-card swap (Infiniti map-update portal program). navi_ps mmaps the partitions and walks them on demand for render/route/search. Doug's `nissan-nav-updater` project at `~/Developer/nissan-nav-updater/` has reverse-engineered the formats well enough to add roads (MAPAL) and POIs (REFER) — referenced in §6 below.

5. **Renderer architecture: EGL/GLES on an EmgdHmi pixmap.** Per [forensic-factory-ui-binary.md](forensic-factory-ui-binary.md), navi_ps holds an EGL surface bound to a `PVR2DMEMINFO *` pixmap allocated via `emgdHmiCreatePixmap(disp, EMGD_HMI_BUFFER=1, 800, 480, &pix)` against `/tmp/.emgdhmid_socket`. emgdhmid composites the navi pixmap onto the upper LVDS (port 2) via Sprite/Overlay planes. **navi_ps is the busiest renderer in the system** — full 800×480 map redraw at panning/zoom rates, with road geometry tessellation, anti-aliased line strokes, building extrusions, POI icon blits, and the vehicle-position chevron. POIs and route line are all drawn here, not by display_ps.

6. **GPS path: NMEA most likely arrives via AV-CAN, not a dedicated /dev/tty.** No `gps*`, `nmea*`, `ttyACM*` udev rule exists on Slot A targeting navi_ps (the only `/etc/udev/rules.d/` activity is USB storage handling and `ifup_navi0.sh`/`ifup_audio0.sh` for internal USB-CDC sub-board interfaces). The Q60 GPS antenna is wired to the **navigation antenna sub-module** which speaks AV-CAN (500 kbit/s, separate from chassis CAN — per [DSU_HARDWARE_INVENTORY.md](DSU_HARDWARE_INVENTORY.md)), and navi_ps consumes time-tagged position frames off AV-CAN. Wheel-speed and steering-angle frames also arrive on AV-CAN/V-CAN gateway and feed the dead-reckoning fusion when GPS is occluded (tunnels, parking decks, urban canyons).

7. **Routing engine is proprietary DENSO over the `RDSTM001` graph.** Almost certainly an A*/Dijkstra variant with heuristic costing (turn penalties, road class weights, real-time traffic deltas via SiriusXM NavTraffic when subscribed). The graph is bitwise read-only at runtime; offline routing only (no cloud routing). Doug's `nissan-nav-updater` does NOT modify RDSTM001 — that's why adding roads via the tool gives map-display-only without turn-by-turn: address lookup uses HOUSE001 B-tree which is also not modified. The factory uses an unmodified, NAVTEQ-shipped graph; we have no plausible path to extend it without DENSO's tooling. **Plan B''' replaces the routing engine entirely with Valhalla** over OSM PBF (per [CLAUDE.md](../CLAUDE.md)).

8. **Voice prompts are NOT in `/usr/share/sounds/` on Slot A.** That directory contains only ALSA channel-test WAVs (`Front_Left.wav`, `Rear_Center.wav`, etc.). The actual turn-by-turn voice prompts ("In 200 feet, turn right onto Main Street") live on the naviwork ext4 partition (most likely `/home/naviwork/system/data/voice/`) or are TTS-synthesized at runtime by a separate DENSO voice module. The audio path is navi_ps → mqueue → `audio_ps` (PS_AUDIO) → `snd` (PS_SND) → ALSA HDA → Bose amp. PulseAudio is in the loop for routing/cork-during-call (per [forensic-phone-stack.md](forensic-phone-stack.md) §5).

**Bottom line for the rebuild:** navi_ps is the largest single port target on the project. We replace it with a Qt6 nav app embedding **Valhalla** for routing + **MBTiles/PMTiles** raster/vector tiles for rendering + **our own POI/address index** (CSV → SQLite FTS5) + a small CAN reader for GPS/dead-reckoning + a TTS or pre-recorded prompt set for voice guidance. The map data partition is discarded entirely (we ship our own tiles). The cut line is clean: the only thing that *must* stay running is `emgdhmid` (we paint into its pixmap canvas the same way the factory does) — everything else navi_ps touched (RDSTM, HOUSE, MAPAL, REFER) is replaced wholesale.

---

## 1. Architecture Diagram

```
                     ┌─────────────────────────────────────────────┐
                     │  PHYSICAL INPUTS                            │
                     │                                             │
                     │   GPS antenna ──┐                           │
                     │   Wheel speed   │   AV-CAN 500 kbit/s       │
                     │   Steer angle   ├──▶ (LAPIS PCH CAN)        │
                     │   Yaw / accel   │                           │
                     │   Vehicle speed │                           │
                     │   Compass / Gyro┘                           │
                     │   (NAVI ECU sub-module aggregates)          │
                     └─────────────────────────────────────────────┘
                                       │
                                       ▼   AV-CAN frames
            ┌────────────────────────────────────────────────────────────┐
            │  navi_ps  "PS_NAVI"   /home/naviwork/system/bin/navi_ps    │
            │  (one process — owns map, route, search, voice scheduling) │
            │                                                            │
            │  ┌──────────────┐  ┌───────────────┐  ┌────────────────┐   │
            │  │ GPS+DR fuse  │  │  Route compute│  │   Search       │   │
            │  │ Kalman/EKF   │  │  A*/Dijkstra  │  │ Addr (HOUSE)   │   │
            │  │              │  │  over RDSTM   │  │ POI  (REFER)   │   │
            │  └──────┬───────┘  └───────┬───────┘  └────────┬───────┘   │
            │         │                  │                   │           │
            │         ▼                  ▼                   ▼           │
            │  ┌────────────────────────────────────────────────────┐    │
            │  │  Map renderer  (GLES1.x via libwsegl-hmi)          │    │
            │  │  reads MAPAL001 tiles, REFER icons, draws route    │    │
            │  │  line + vehicle chevron + ETA strip + compass      │    │
            │  └────────────────────────────────────────────────────┘    │
            │         │                  ▲                              │
            │         │ EGL              │ POSIX mqueue                 │
            │         ▼                  │ commands/state               │
            └─────────┬──────────────────┼──────────────────────────────┘
                      │                  │
   ┌──────────────────┘                  │
   ▼                                     │
┌─────────────────────────────────────┐  │  /navi_ps_main  (8 MB cap)
│ EMGD pixmap (800×480 ARGB8888)      │  │  inbound: state changes, dial-
│ via /tmp/.emgdhmid_socket           │  │  back results from peers
│                                     │  │
│ emgdhmid composites onto Sprite C   │  ├──◀── PS_VRD01  (vehicle/route data)
│ → upper LVDS panel (port 2)         │  ├──◀── audio_ps  (mute/duck state)
└─────────────────────────────────────┘  ├──◀── tel_proc  (call active → mute prompts)
                                          ├──◀── smng       (start/stop state machine)
                                          └──◀── hmictrl_proc (user input from UI screens)

(Map data on a separate physical SD card — read-only at runtime)
┌─────────────────────────────────────────────────────────────────┐
│  /mnt/<mapcard>/                                                │
│    MAPAL001/   — visual road geometry (tiles + LOD)             │
│    REFER001/   — POI database (general)                         │
│    REFER002/   — POI database (additional: dealerships, etc.)   │
│    RDSTM001/   — routing graph (road segments + topology)       │
│    HOUSE001/   — address B-tree (number/street → tile lookup)   │
└─────────────────────────────────────────────────────────────────┘

(Voice prompt path)
navi_ps ──"prompt id N"──▶ /audio_ps_main mqueue ──▶ audio_ps ──▶ /PS_SND mqueue ──▶ snd ──▶ ALSA HDA ──▶ Bose amp
                                                                                  └─ PulseAudio (ducks media during prompt)
```

---

## 2. The Service Unit — `nav_navi.service`

**File:** `/tmp/dsu-slot-a/lib/systemd/system/nav_navi.service`

```ini
[Unit]
Description=PS_NAVI Service
#Requires=nav_dmn.target
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
#ExecStart=/bin/sh -c 'ulimit -c unlimited; /home/naviwork/system/bin/navi_ps "PS_NAVI"'
ExecStart=/home/naviwork/system/bin/navi_ps "PS_NAVI"

TimeoutSec=90
SendSIGKILL=yes
```

**Wanted-by:** `/tmp/dsu-slot-a/lib/systemd/system/nav_pre.target.wants/nav_navi.service` (symlink). Pulled into the unit dependency graph transitively by smng's startup of `nav_pre.target`.

### 2.1 Per-property table

| Property | Value | Forensic meaning |
|---|---|---|
| `Type=simple` | long-running daemon | Same shape as every other nav_*; not forking, no notify protocol |
| no `Restart=` directive | implicit `Restart=no` | systemd will NOT respawn on crash. Instead `OnFailure=` fires |
| `OnFailure=nav_smngpret.service` | poison-pill cascade | Crash → smngpret → stop smng → nav_backup → **poweroff** (see [forensic-daemon-supervision.md](forensic-daemon-supervision.md) §3.3) |
| `Requires=nav_pre.target` | early-tier nav service | Brought up with the other nav daemons via smng's orchestration |
| `DefaultDependencies=no` | bypass standard ordering | Started by smng explicitly, not by sysinit |
| `LimitSTACK=524288` | 512 KB | Larger than `tel_proc`'s 384 KB and `snd`'s 384 KB; matches the four UI daemons (`hmictrl_proc`/`display_ps`/`dispapf_proc` — all 524288). The extra 128 KB above tel_proc's stack hints at deeper call chains (renderer + routing + search worker callbacks all in-process) but is still NOT a Qt-event-loop sized stack. |
| `LimitMSGQUEUE=8192000` | 8 MB | 32× the default 256 KB. Matches the four UI daemons. The 8 MB ceiling × 1 MB `msgsize_max` = 8 messages max in the kernel mqueue → senders' userspace heap buffers retries beyond that (per [forensic-denso-ipc.md](forensic-denso-ipc.md) §2). |
| `StandardInput/Output/Error=null` | headless daemon | No tty, no stdout — logs go through systemlogd over IPC if at all |
| `SendSIGKILL=yes` | force-kill on timeout | Treated as expendable on shutdown |
| `TimeoutSec=90` | generous shutdown timeout | Implies graceful drain on stop (save current route, sync POI cache, persist favorites) |
| no `Environment=LD_LIBRARY_PATH=` | inherits parent path from smng | Same as `hmictrl_proc`/`display_ps`/`dispapf_proc` — runtime path includes `/usr/lib/wsegl` per the commented hint in `nav_hmictrl.service` |
| no `Group=video` | inherits root group | But it still reaches `/dev/dri/card0` via emgdhmid broker (no direct DRM I/O — only via libemgdhmi/libwsegl-hmi) |
| Commented `core_pattern` line | dev-build leftover | Production drops core; dev builds wrote to `/home/naviwork/log/core` |

### 2.2 Why the LimitSTACK is 524288 not 393216

The four UI daemons that touch EGL surfaces (`navi_ps`, `hmictrl_proc`, `display_ps`, `dispapf_proc`) all carry `LimitSTACK=524288`. The non-renderer daemons (`tel_proc`, `snd`) sit at `LimitSTACK=393216`. **The 128 KB delta is the EGL/PVR2D call stack** — the WSEGL backend (`libwsegl-hmi.so`) makes deep recursive calls through `libEGL.so.1 → libGLES_CM.so.1 → libwsegl-hmi.so → libemgdhmi.so.0 → AF_UNIX RPC` and back. This is the same kind of evidence that classifies a daemon as a renderer vs. a backend in the systemd unit topology.

### 2.3 Comparison table — navi_ps vs. peers

| Daemon | `LimitSTACK` | `LimitMSGQUEUE` | Wsegl in path | UI rendering? | In kill set? |
|---|---:|---:|:---:|:---:|:---:|
| **`navi_ps`** | **524288** | **8 MB** | **yes (inherited)** | **yes** | **YES** |
| `hmictrl_proc` | 524288 | 8 MB | yes (inherited) | yes | NO (keep alive — cam dep) |
| `display_ps` | 524288 | 8 MB | yes (inherited) | yes | NO (keep alive on first pass) |
| `dispapf_proc` | 524288 | 8 MB | yes (inherited) | yes | YES |
| `camera_ps` | 524288 | 8 MB | yes (inherited) | yes (video plane) | NO (cam path) |
| `audio_ps` | 524288 | 8 MB | yes (explicit env) | no | NO |
| `tel_proc` | 393216 | 8 MB | no | no | NO (replace logic) |
| `snd` | 393216 | 8 MB | no | no | NO |
| `abstc` (`abs_clock.service`) | 524288 | (default) | no | no | optional mask |

navi_ps shares the "wsegl-using, big mqueue, big stack" cluster with the other UI daemons. The forensic signal is clear: **this is a renderer daemon**, not a backend service.

---

## 3. Inferred Behavior — Inside `navi_ps`

(Binary not extracted. Behavior triangulated from service unit + DENSO IPC contract + EMGD pixmap contract + the map-partition formats Doug reverse-engineered + the Q60 feature list at [feature-parity-audit.md](feature-parity-audit.md) §1.2.)

### 3.1 Startup sequence

1. **napl/libifout init** — registers itself with smng as `PS_NAVI` via `/PS_OS01` mqueue (smng's primary inbox). Per [forensic-denso-ipc.md](forensic-denso-ipc.md) §1, libifout provides the POSIX mqueue + shm + sem primitives.
2. **Open `/navi_ps_main` mqueue** — `mq_open("/navi_ps_main", O_RDONLY|O_CREAT, 0666, &attr)` with `mq_maxmsg=8`, `mq_msgsize=1048576` (matches the kernel `fs.mqueue.msgsize_max=1048576` and the `LimitMSGQUEUE=8192000` rlimit). This is navi_ps's inbox.
3. **mmap the map partitions** — open `MAPAL001/`, `RDSTM001/`, `HOUSE001/`, `REFER001/`, `REFER002/` from the nav SD card mount point, page-fault-driven mmap so unused tiles never touch RAM.
4. **Load persisted state** — last position, route in progress (if any), favorites, recent destinations, settings. Storage probably in `/home/naviwork/system/data/pdm/` (PDM = persistent data manager — the `home-naviwork-data-pdm-ram.mount` automount hints at a RAM-resident overlay backed by flash on shutdown).
5. **EGL bring-up** — `emgdHmiGetNativeDisplay(&ndpy)`, `eglGetDisplay(ndpy)`, `eglInitialize`, `eglChooseConfig` (RGBA8/D24/S8 — see drawbuf reference at [forensic-factory-ui-binary.md](forensic-factory-ui-binary.md) §2.3), `emgdHmiCreatePixmap(ndpy, EMGD_HMI_BUFFER=1, 800, 480, &pix)` for the main map canvas. May also create a `EMGD_POPUP_BUFFER=3` 800×480 surface for the maneuver instruction overlay.
6. **Subscribe to AV-CAN frames** — likely through `/ioapf_main` mqueue (ioapf_proc owns the CAN-bus abstraction) or directly via a `socket(PF_CAN, SOCK_RAW, CAN_RAW)`. The exact path is one of the open questions (§10).
7. **Begin render loop + IPC loop** — two main threads at least (renderer + IPC), probably more (route worker, search worker, prompt scheduler).

### 3.2 GPS + dead-reckoning fusion

The Q60 navigation antenna sub-module (a separate ECU under the dashboard, attached to the navigation antenna on the roof shark fin) ingests:
- Raw GPS NMEA from the GPS receiver chip
- Wheel-speed pulses from the ABS sensors (off chassis CAN, gatewayed onto AV-CAN by the BCM in the passenger kick panel)
- Steering angle from the SAS (Steering Angle Sensor — chassis CAN → AV-CAN gateway)
- Vehicle speed from the meter cluster
- Yaw rate / lateral accel from the gyro IC on the nav ECU sub-board itself
- 3-axis accelerometer for road grade detection

The sub-module **fuses these into a single time-tagged position frame** (probably at 5–10 Hz) and emits onto AV-CAN. navi_ps consumes the frame — it does NOT do the raw Kalman filter itself (DENSO put the EKF on the dedicated NAVI ECU for determinism and to keep navi_ps a Linux-userspace process that can occasionally be preempted by other UI work). This is the standard automotive split: critical sensor fusion on a deterministic MCU, application logic on the rich-OS DCU.

**Fallback behavior:** when GPS signal drops (tunnels, parking garage, under bridges), the NAVI ECU continues integrating wheel-speed + steering + yaw + accelerometer and emits a **DR-only position estimate** with a confidence flag. navi_ps draws the vehicle-position chevron in a slightly different style (often dimmer / dashed outline) to indicate DR mode. When GPS reacquires, position snaps back to truth — sometimes with a visible jump if the DR estimate drifted.

### 3.3 Routing engine

Proprietary DENSO routing engine over the `RDSTM001` graph. From general industry knowledge of automotive nav (Clarion/NAVTEQ/HERE ecosystem):

- **Algorithm:** A* with road-class-weighted edge costs. Hierarchical (skip to higher-class roads for long routes, descend back to local streets near origin/destination). Bidirectional search common.
- **Cost function:** base time = length / posted speed; turn penalties (cost+10s for left turn against traffic, +5s right turn, +20s U-turn); road-class bias (driver preference — Fastest vs. Shortest vs. Eco); avoid flags (toll roads, highways, ferries, unpaved).
- **Real-time traffic:** when SiriusXM NavTraffic subscription is active, traffic deltas arrive via `multimedia_ps` (SiriusXM tuner owner) → mqueue → navi_ps, applied as a multiplicative cost penalty on affected edges. Triggers automatic reroute when route ETA changes by > some threshold.
- **Output:** an ordered list of road segments + a maneuver list (turn-by-turn instructions: "in 0.3 mi, turn right onto MAIN ST"). Stored in navi_ps memory and rendered as the magenta route polyline.
- **Re-route triggers:** off-route detection (vehicle position > ~30 m from route polyline for > 2 consecutive ticks), manual user request, traffic-update-driven, destination change.

The routing engine is the **part of navi_ps that we cannot port** — we don't have the binary, we don't have the algorithm specifics, and even if we did, the input is the proprietary `RDSTM001` graph format which DENSO bakes from NAVTEQ source data we don't have. **This is the largest single argument for the Plan B''' approach of replacing navi_ps wholesale rather than wrapping it.**

### 3.4 Search backend

Two search paths:
- **Address search** (`Settings → Destination → Address`): user enters state → city → street → number. Each level is a HOUSE001 B-tree probe. HOUSE001 stores normalized address strings → tile coordinates / lat-lon. Doug's `nissan-nav-updater` documents this as a B-tree but does NOT write to it (which is why nav-updater can add roads to MAPAL but you still can't search for them — same limitation we'd have if we ever modified the card without HOUSE updates).
- **POI search** (`Settings → Destination → Points of Interest`): category browse (Gas, Food, ATM, etc.) or name search. Categories are top-level indexes into REFER001/REFER002 records, each containing name + lat-lon + phone + category code. POI search is a linear/indexed scan over REFER entries filtered by the active map view bounding box or a textual prefix match.

navi_ps does both lookups. The UI for entering addresses/POIs is owned by `hmictrl_proc` (touchscreen keyboard, list-picker widgets). Flow: user taps "Enter Address" → `hmictrl_proc` opens the keyboard screen → captures characters → `mq_send("/navi_ps_main", "search-address", state="NC", city="CARY", street="MAIN")` → navi_ps does the B-tree walk → replies with a candidate list over an ad-hoc reply queue → `hmictrl_proc` paints the list → user picks → `mq_send("/navi_ps_main", "navigate-to", lat=…, lon=…)` → navi_ps computes route → replies with route summary → user confirms → navi_ps switches to navigating state and starts emitting prompt + map updates.

### 3.5 Voice prompts

Pre-recorded WAV prompts are the standard automotive approach (deterministic latency, no TTS engine to license). Suspected locations on the naviwork partition:
- `/home/naviwork/system/data/voice/<lang>/` — language-tagged WAV directories
- Per-language: `turn_left.wav`, `turn_right.wav`, `bear_left.wav`, `bear_right.wav`, `keep_left.wav`, `keep_right.wav`, `merge_left.wav`, `merge_right.wav`, `exit_<n>.wav`, `roundabout_<exit>.wav`, plus number/distance fragments concatenated at runtime ("in" + "two hundred" + "feet" + "turn right" + "onto" + dynamic street-name TTS?)

If street names are spoken (e.g., "turn right onto **Main Street**"), that's almost certainly a **TTS module** because the prompt corpus can't include every street in NAVTEQ. The Q60 likely uses Nuance Vocalizer (industry standard at the time) — would be a separate library/process. Need to confirm by inspecting the naviwork partition.

The Slot A `/usr/share/sounds/alsa/` directory contains only ALSA channel-test WAVs (`Front_Left.wav`, `Side_Left.wav`, etc., 8 files), explicitly NOT nav prompts. Confirms the voice prompts live elsewhere (naviwork or the map SD card itself).

**Trigger sequence:** navi_ps detects an upcoming maneuver based on remaining-distance-along-route < threshold (e.g., "in 0.25 mi"), looks up the prompt id, and `mq_send`s to `/audio_ps_main` with a "play prompt N" message. `audio_ps` opens the WAV, decodes it (probably just PCM read), and pumps the samples to `snd` (PS_SND) via shared memory or mqueue, which writes to ALSA HDA → Bose amp. PulseAudio's `module-cork-music-on-phone` and similar role-based modules duck the active media source during the prompt. Per [forensic-phone-stack.md](forensic-phone-stack.md), media-cork is already in place for incoming calls — same mechanism likely applies to nav prompts.

### 3.6 Visual rendering pipeline

navi_ps's render loop, per draw:
1. Compute current vehicle position from latest AV-CAN frame.
2. Determine map view center (heading-up: center = vehicle pos, rotation = heading; north-up: center = vehicle pos, rotation = 0).
3. Compute the tile bounding box for current zoom level + view.
4. Walk `MAPAL001/` to fetch the road geometry tiles intersecting the bbox (mmaped — already in pagecache after first access).
5. Tessellate road segments into GLES1.x triangle strips (line thickness based on road class + zoom level), apply anti-aliasing where the GPU supports it.
6. Draw road network (background first → highways → arterials → locals → labels last).
7. Draw POI icons for visible category filters (icons baked into REFER records — small bitmaps).
8. Draw the route polyline on top (magenta `EmgdHmi` color, ~6 px wide).
9. Draw the vehicle-position chevron (blue arrow, rotated to match heading).
10. Draw compass widget (corner of screen).
11. Draw ETA strip, next-maneuver instruction, distance-to-next-maneuver (top of screen).
12. `eglSwapBuffers(dpy, surf)` → emgdhmid flips the Sprite C plane to show the new frame.

Frame rate: probably 10–20 fps for smooth panning, lower when stationary (15-second redraw is fine when nothing is moving). The SGX535 GPU is slow by 2026 standards but adequate for 800×480 vector road rendering.

### 3.7 Lower-screen overlap

Per [lower-screen-architecture.md](lower-screen-architecture.md), the lower 7" screen (Integral Switch unit) is a thin client driven by the upper DCU over LVDS. The DCU renders BOTH displays into a single 800×960 stacked virtual framebuffer (drawbuf's `EMGD_HMI_BUFFER` size of `0x320×0x3C0` = 800×960 is the smoking gun — see [forensic-factory-ui-binary.md](forensic-factory-ui-binary.md) §2.3) and serializes both halves out over the two LVDS streams.

When the lower screen shows audio/climate (normal mode), navi_ps owns ONLY the upper-half of the 800×960 canvas. But when the user is in nav mode and the lower screen shows a **mini-map / next-turn companion view** (a standard InTouch behavior for nav-active state), navi_ps probably renders BOTH:
- Upper half (rows 0–479): main map view (heading-up, route, vehicle)
- Lower half (rows 480–959): next-turn arrow + distance + street name, or a small compass + ETA repeater

Whether navi_ps actually owns the lower 480 rows of its canvas, or whether `hmictrl_proc` composites the nav-companion view on top of navi_ps's pixmap, is one of the open questions (§10). Most likely: `display_ps` orchestrates the composition across pixmaps from all UI daemons, and navi_ps just provides its 800×480 main-map and a separate (or just-the-upper-half) pixmap for the lower nav-companion.

---

## 4. Map Data Partitions — Reference

**Status: read-only at runtime, updated by SD-card swap.** Doug's `~/Developer/nissan-nav-updater` project has reverse-engineered enough of the formats to add roads and POIs. Full format documentation lives there (`lib/mapal.py`, `lib/refer.py`, `lib/tiles.py`); this section is a high-level reference for what navi_ps consumes, not a re-documentation.

| Partition | Format | Role | Modified by nav-updater? | Used by navi_ps for |
|-----------|--------|------|:---:|---|
| `MAPAL001/` | Big-endian binary, zlib-compressed sections, tile-coordinate naming (e.g. `B18R110R`) | Visual road geometry — line strokes drawn on the map | YES (`lib/mapal.py`) | Map rendering (roads appear on screen) |
| `REFER001/` | Binary POI database with POINT047 record blocks (per `lib/refer.py`) | General POI database (gas stations, restaurants, ATMs, etc.) — name + lat/lon + phone + category | YES (POI updates) | "Nearby Places" results, category browse, POI search |
| `REFER002/` | Same format as REFER001 | Additional POI database (dealerships, custom categories) | YES (dealer coords patchable) | Dealer locator, custom POI categories |
| `RDSTM001/` | Binary routing graph (road segments + topology + costs) | The graph the routing engine walks — every road that supports turn-by-turn must be here | **NO** (nav-updater cannot modify) | Turn-by-turn route compute (A*/Dijkstra) |
| `HOUSE001/` | Binary B-tree of normalized address strings | Address index for "Enter Address" search | **NO** (nav-updater cannot modify) | Address search ("123 Main St, Cary NC") |

**Why nav-updater cannot extend routing/search:** adding a road to MAPAL gives you a visible line on the screen but no graph edge in RDSTM, so routing has no idea the road exists. Adding it to RDSTM requires inverting the proprietary topology encoding (segment IDs, intersection IDs, turn-restriction encoding, cost weights) which is much harder than the MAPAL geometry encoding. HOUSE has the same problem at the address-index level.

**Map data lifecycle:**
- Factory: NAVTEQ 14Q4 (January 2015) data shipped in the original CLA-NAVI06-01 card.
- Infiniti map updates: paid annual updates from the Infiniti Navigation update portal — Doug had access to these until subscription lapsed.
- Last factory-blessed update: per [DSU_OEM_DOCUMENTATION.md](DSU_OEM_DOCUMENTATION.md) ITB22-013, **2022-03-31 was the cutoff** for the final Infiniti map+OTA update on 2017-2019 Q60.
- Post-2022: no official path. nav-updater is one of the few options for keeping data fresh.

**For Plan B''' we discard the map SD card entirely** and ship our own map data baked from OpenStreetMap into MBTiles (raster) or PMTiles (vector) — sourced from current OSM, regenerated on whatever cadence we want, never paywalled.

---

## 5. GPS + CAN Inputs — What Feeds the EKF

### 5.1 No direct /dev/tty for GPS on Slot A

We searched `/etc/udev/rules.d/` for any rule matching GPS, NMEA, ttyACM*, ttyUSB*, ttyPCH* with a navi association — **none exists**. The Slot A udev rules cover:
- USB storage hotplug (`insert.sh`, `remove.sh`)
- Two internal USB-Ethernet gadget interfaces (`ifup_navi0.sh` for `navi0` at 169.254.10.1/24 mtu 9000, `ifup_audio0.sh` for `audio0`) — these talk to internal sub-boards, NOT external GPS
- Persistent serial naming for USB-attached modems (the PPP `cmu200` peer file references `/dev/ttyACM0` for cellular modem, **not** GPS)

If navi_ps owned a `/dev/tty*` for GPS, we'd expect a udev rule setting permissions or a symlink. Absence of such a rule supports the conclusion that **GPS arrives over AV-CAN**, not a dedicated serial port.

### 5.2 AV-CAN as the GPS bearer

Per [DSU_HARDWARE_INVENTORY.md](DSU_HARDWARE_INVENTORY.md), the DCU has an AV-CAN bus (500 kbit/s, LAPIS PCH CAN controller) that connects the DCU to the NAVI control ECU, AV control, AC amp, and TCU (telematics). The NAVI control ECU is the GPS antenna sub-module — it owns the GPS receiver chip + EKF + emits position frames on AV-CAN.

The standard Nissan/Infiniti AV-CAN frames carry:
- GPS position (lat, lon, alt) at ~5–10 Hz
- GPS time-of-day (for clock sync — `abstc` consumes this too, per [forensic-clock-service.md](forensic-clock-service.md) §1.3)
- GPS quality / fix state (no fix / 2D / 3D / DR-only)
- Heading + speed
- DR-only fallback position when GPS unavailable

navi_ps subscribes to these frames either through:
- **`/ioapf_main` mqueue** — `ioapf_proc` (in `nav_early.target.wants/`) owns the I/O abstraction including CAN. ioapf_proc reads CAN frames and republishes as mqueue messages.
- **OR a direct `socket(PF_CAN, SOCK_RAW)` open** — possible but less likely given DENSO's pattern of abstracting hardware through napl daemons.

The exact path is an open question that requires either the binary or a live `strace` to confirm (§10).

### 5.3 Wheel speed + steering + yaw — dead-reckoning inputs

These do NOT feed navi_ps directly. They feed the NAVI ECU's EKF, which produces the fused position output. navi_ps consumes the fused output as a black box — it doesn't run its own Kalman filter. This split is consistent with automotive determinism patterns (rich-OS DCU is not the right place for hard-realtime sensor fusion).

The wheel-speed / steering / yaw frames live on the **chassis CAN** (gatewayed onto AV-CAN by the BCM in the passenger kick panel — per [DSU_HARDWARE_INVENTORY.md](DSU_HARDWARE_INVENTORY.md)). navi_ps does NOT need to subscribe to them for nav purposes; they're consumed by the NAVI ECU upstream.

### 5.4 Implication for Plan B'''

We need to:
1. **Identify the AV-CAN frame IDs** for GPS position / time / quality. The Racelogic Q50 PDF covers chassis CAN only — AV-CAN is undocumented publicly. Doug's existing `VehicleService.h` CAN-parsing code (per the v2 audit note in [feature-parity-audit.md](feature-parity-audit.md)) may already cover some.
2. **Connect to the CAN bus** from our Qt app — `socket(PF_CAN, SOCK_RAW)` is standard Linux SocketCAN.
3. **Parse the GPS frames** into Qt-friendly position events.
4. **Decide on DR fallback policy** — for v1, just freeze the vehicle chevron when GPS is unavailable; for v2, integrate wheel-speed/steering ourselves (or trust the NAVI ECU's DR-only frame if it broadcasts one we can identify).

The DR-fallback is the part that's most painful to replicate from scratch, but it's only critical for tunnels and dense urban canyons — for v1, frozen-position with a "GPS lost" indicator is acceptable.

---

## 6. Map Data — Why We Replace It, Not Reuse It

Three options were considered for map data in Plan B''':

| Option | Pros | Cons | Verdict |
|--------|------|------|---------|
| **A — Reuse factory NAVTEQ 14Q4 card** | Already in the car. Existing format. Lat/lon coordinate system known. | Read-only proprietary format. Routing/search formats only partially RE'd. Cannot fix stale data without offline tooling. 10-year-old data. No path to extend coverage. | Rejected |
| **B — Reuse factory format, replace data via nav-updater** | Existing rendering path. Doug already has the tooling for MAPAL/REFER. | RDSTM and HOUSE still unmodifiable → no turn-by-turn or address search for new roads. Locks us to the factory render engine which we don't have. | Rejected |
| **C — Discard factory map data, ship our own (Plan B''')** | Current OSM data. Open formats. MBTiles for raster, PMTiles for vector. Standard Valhalla routing graph. SQLite FTS5 for address/POI search. Fully extensible. | Larger storage footprint (~10 GB OSM-derived data for the US). Rendering pipeline is our problem. | **Selected** |

Plan B''' uses **Valhalla** as the routing engine over OSM PBF (per [CLAUDE.md](../CLAUDE.md)). Tiles are MBTiles (raster, for v1 simplicity) or PMTiles (vector, for v2 efficiency). Address/POI search is SQLite FTS5 over a normalized index built offline from OSM.

`~/Developer/nissan-nav-updater` remains useful as a tool for users who want to keep their *factory* map current without losing the factory UI — but for our Plan B''' rebuild, it is informational only.

---

## 7. Rendering Pipeline (Detailed)

navi_ps's rendering contract is identical in shape to the other UI daemons documented in [forensic-factory-ui-binary.md](forensic-factory-ui-binary.md) §2. Per drawbuf reference impl:

```c
// At startup
EGLNativeDisplayType ndpy;
emgdHmiGetNativeDisplay(&ndpy);             // AF_UNIX connect to /tmp/.emgdhmid_socket

PVR2DMEMINFO *map_pixmap;
emgdHmiCreatePixmap(ndpy, EMGD_HMI_BUFFER /*=1*/, 800, 480, &map_pixmap);

EGLDisplay disp = eglGetDisplay(ndpy);
eglInitialize(disp, NULL, NULL);

EGLConfig cfg;
EGLint n;
EGLint attribs[] = { EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8,
                     EGL_ALPHA_SIZE, 8, EGL_DEPTH_SIZE, 24, EGL_STENCIL_SIZE, 8,
                     EGL_RENDERABLE_TYPE, EGL_OPENGL_ES_BIT, EGL_NONE };
eglChooseConfig(disp, attribs, &cfg, 1, &n);
EGLSurface surf = eglCreatePixmapSurface(disp, cfg, map_pixmap, NULL);
EGLContext ctx = eglCreateContext(disp, cfg, EGL_NO_CONTEXT, NULL);
eglMakeCurrent(disp, surf, surf, ctx);

// Per frame
glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
// ... draw tiles, route, chevron, chrome ...
eglSwapBuffers(disp, surf);    // emgdhmid flips Sprite C plane to LVDS upper
```

Compositing into the final framebuffer is handled by `emgdhmid` in kernel/DRM space via private EMGD ioctls (`IGD_ALTER_OVL2`, etc.). navi_ps does NOT call DRM directly — it just produces pixels in its pixmap and tells emgdhmid to flip.

**Pitch/format:**
- Pixmap is `ARGB8888` (4 bytes per pixel)
- Pitch is `800 × 4 = 3200` bytes per row (no padding observed in drawbuf)
- Full pixmap = `800 × 480 × 4 = 1,536,000 bytes ≈ 1.5 MB` in GTT-mapped GPU memory
- Triple-buffered probably (one in front, one being rendered, one queued) → ~4.5 MB GTT footprint per surface

**Plane assignment:** navi_ps's pixmap is assigned to the **Sprite C overlay plane** by emgdhmid (per [forensic-emgdhmid-flip-protocol.md](forensic-emgdhmid-flip-protocol.md)). Sprite C is the main HMI plane on the upper LVDS. The base framebuffer carries background chrome; navi's pixmap is composited over it.

---

## 8. Rebuild Plan — Full Replacement

### 8.1 The cut line

```
KEEP:    emgdhmid, hmictrl_proc (cam dep), display_ps (first pass), camera_ps,
         audio_ps, snd, sndamp, multimedia_ps, tel_proc, ioapf_proc, smng,
         abstc, BlueZ, ofonod, PulseAudio, the kernel, libemgdhmi, libwsegl-hmi

REPLACE: navi_ps  →  our Qt6 nav app (links libemgdhmi, libwsegl-hmi via custom
                     Qt eglfs platform plugin)

NEW:     Valhalla routing daemon (separate process or in-process lib)
NEW:     Map tile store (MBTiles or PMTiles on Slot B ext4)
NEW:     Address/POI SQLite FTS5 index
NEW:     CAN reader thread inside Qt app (reads AV-CAN GPS frames)
NEW:     Voice prompt asset bundle (pre-recorded WAVs in /opt/nav/voice/)
NEW:     Drain thread for /navi_ps_main mqueue (per forensic-denso-ipc.md §6)

DISCARD: /home/naviwork/system/bin/navi_ps  (masked via systemctl mask nav_navi.service)
DISCARD: Factory MAPAL001 / REFER001 / REFER002 / RDSTM001 / HOUSE001 partitions
DISCARD: DENSO routing engine, voice prompt set, search backend (factory copies)
```

### 8.2 Component delta table

| Factory | Replacement | Effort | Notes |
|---|---|---|---|
| `navi_ps` daemon | Qt6 app (`q60nav`) — single process | Large (multi-month) | The whole project's primary deliverable |
| Render to EmgdHmi pixmap (GLES 1.x) | Qt6 RHI/OpenGL ES 2 via custom `QEglFSDeviceIntegration` plugin (per [forensic-factory-ui-binary.md](forensic-factory-ui-binary.md) §9) | ~300 LoC plugin | Already designed; eglfs_emgdhmi |
| Map tile data (MAPAL001 binary) | MBTiles (raster) or PMTiles (vector), generated from OSM PBF | ~1 day per region | Plenty of open tooling |
| Routing graph (RDSTM001 binary) + DENSO router | **Valhalla** routing engine over OSM | medium | Standard FOSS routing engine; static graph build per region |
| Address index (HOUSE001 B-tree) | SQLite FTS5 over normalized OSM address records | small | Standard sqlite + FTS5 |
| POI database (REFER001/002 binary) | SQLite FTS5 over OSM amenity tags | small | Same DB as addresses |
| GPS via NAVI ECU sub-module → AV-CAN | **Keep AV-CAN path** — read GPS frames in Qt CAN-reader thread | small | Already partially in `VehicleService.h` |
| Dead reckoning (NAVI ECU EKF) | Keep — DR fused position arrives on same AV-CAN frame | none | Reuse the factory NAVI ECU as-is |
| Voice prompt WAVs | Ship our own WAV bundle (or eSpeak/Festival TTS at runtime) | small-medium | Pre-recorded simpler; TTS handles street names |
| Voice prompt scheduling/audio routing | Qt app sends to `/audio_ps_main` mqueue — keep factory audio path | small | Reuse audio_ps + snd for output |
| Map updates (SD-card swap) | OTA update of tile/POI/graph bundle | future work | Out of scope for v1; manual rsync OK initially |
| Map → vehicle interaction (route line, chevron, compass) | Qt QML scene with custom OpenGL items | normal QML work | Renders into the same pixmap canvas |
| Address/POI search UI screens | QML screens in Qt app (no longer hmictrl_proc → mqueue → navi_ps round trip) | normal QML work | All in-process now |

### 8.3 What we lose by not extracting `navi_ps`

Without disassembling the binary, we cannot know:
1. **Exact mqueue protocol on `/navi_ps_main`** — message structs, command codes. Per [forensic-denso-ipc.md](forensic-denso-ipc.md) §6 we don't need to *understand* it (just drain), but if we ever wanted to **reuse** factory peers (e.g., let SiriusXM traffic data still flow), we'd need to know.
2. **Settings persistence format** — where favorites, recent destinations, route history are stored, and in what format. With Plan B''' we're starting fresh anyway, so this is moot for our app, but it means users won't be able to import factory-saved favorites.
3. **Voice prompt selection logic** — exact threshold distances ("at 0.25 mi: 'in a quarter mile, turn right'"; "at 0.1 mi: 'turn right'"; "at 50 ft: 'turn right now'"). We can sensibly default these but won't match factory exactly.
4. **POI category taxonomy** — REFER categories and their codes. We define our own from OSM amenity tags.

All four are surmountable with sensible defaults. None is a blocker.

### 8.4 Why not link `libnavi-*` libs from naviwork (if any exist)?

There is no `libnavi.so` or similar publicly-named library on the system. The nav code lives entirely inside the `navi_ps` binary — DENSO did not split it into a reusable lib. (Compare to `libhmi-cntl-server.so` for hmictrl_proc, which IS a separable lib — see [forensic-denso-ipc.md](forensic-denso-ipc.md) §3.) So there's no analog of the "link libhmi-cntl-server" shortcut available for nav.

Even if such a lib existed, the same risks apply (pulls in libstdc++ 4.5.1 ABI, transitively pulls Nissan integration libs, ties our Qt app to DENSO's threading model). Not worth it.

---

## 9. What Stays in the Kill Set

Per [project_planB_kill_set.md](../../../.claude/projects/-Users-dpitek-Developer-q60-rebuild/memory/project_planB_kill_set.md), the current kill set is **navi_ps + dispapf_proc**. nav_navi.service is the primary target — when we mask it, we get the upper LVDS canvas to ourselves for our Qt app.

Required additional steps when masking `nav_navi.service`:
- **Drain `/navi_ps_main` mqueue** before masking. Per [forensic-denso-ipc.md](forensic-denso-ipc.md) §7, this queue is **rank 1** in drain priority — 4 producers (PS_VRD01, audio_ps, tel_proc, smng) feed it at ~5 MB/s. Without drain, PS_VRD01's userspace heap grew to 53 MB in 10 seconds in the May probe. Our Qt app at startup opens `/navi_ps_main` with `O_RDONLY|O_CREAT|O_NONBLOCK`, `mq_maxmsg=8`, `mq_msgsize=1048576`, mode `0666`, and runs a discard-loop thread.
- **Keep `hmictrl_proc` alive** — it holds the `HMIController` singleton that the rearview camera path (`cam.out`) depends on. Killing it breaks reverse-gear camera display.
- **Keep `display_ps` alive on first pass** — `cam_disp_stat_shm` may be load-bearing for camera. Test killing on a later cycle.
- **Do NOT mask `nav_smng.service`** unless we also accept losing all the surviving 12 backend daemons (audio_ps, camera_ps, multimedia_ps, tel_proc, etc.). Plan B''' wants those alive so we get their data flowing into our app.
- **Mask path:** `systemctl mask nav_navi.service nav_dispapf.service`. The `OnFailure=` cascade does NOT fire for masked units (they never start, so they never fail). The cascade only fires when a started unit enters `failed` state.

---

## 10. Open Questions (resolvable only with naviwork partition extracted + on-device probe)

1. **GPS bearer path.** Does navi_ps consume CAN frames via `/ioapf_main` mqueue (going through ioapf_proc), via a direct `socket(PF_CAN, SOCK_RAW)`, or via some shared-memory IPC from the NAVI ECU? Confirm with `strace -f -e socket,mq_open,mq_receive` on a live boot.
2. **AV-CAN GPS frame IDs.** No public AV-CAN DBC exists for the Q60. We need to either reverse-engineer by capturing live traffic (CAN sniffer on the AV-CAN pins on the DCU harness), or extract the parsing from navi_ps's strings/disassembly once we have the binary.
3. **Voice prompt asset location.** `/home/naviwork/system/data/voice/`? `/home/naviwork/system/data/<lang>/voice/`? Pre-recorded WAVs vs. TTS? Confirm by listing the naviwork partition once extracted.
4. **Street-name TTS engine.** Is there a Nuance Vocalizer lib on naviwork? Or are street names spoken by concatenated number/letter fragments? Listen to factory prompts and check naviwork for `libvocalizer*.so` or similar.
5. **Lower-screen nav-companion ownership.** Does navi_ps render the lower-screen mini-map / next-turn directly into rows 480–959 of a 800×960 pixmap, or does it produce a separate companion pixmap that display_ps composites? Could be answered by checking what pixmap sizes navi_ps allocates from emgdhmid (`strings naviwork/navi_ps | grep -E "EMGD_HMI_BUFFER|emgdHmiCreate"`).
6. **Settings/favorites persistence.** Probably `/home/naviwork/system/data/pdm/` (per the `home-naviwork-data-pdm-ram` automount hint). Format unknown — likely a DENSO-private binary blob; sqlite would be a pleasant surprise.
7. **SiriusXM NavTraffic integration path.** `multimedia_ps` owns the SiriusXM tuner; how does traffic data reach navi_ps for reroute computation? Probably mqueue with traffic-update messages, but the message format is opaque.
8. **DR-only fallback frame.** Does the NAVI ECU emit a separately-tagged DR-only frame, or just the fused position with a "GPS quality" flag? Affects how we detect tunnel state.
9. **POI icon storage.** Are POI icons inline in REFER records, or referenced by ID into a separate `/home/naviwork/system/data/icons/` directory? Affects port effort (we re-draw all POI icons from scratch with our own asset set anyway, so not strictly blocking).
10. **Speed-limit overlay.** Where does navi_ps get the speed-limit data? Probably embedded in MAPAL/RDSTM road class records, or a separate `SPEED001` partition we haven't catalogued. Affects feature parity for the speed-alert feature in [feature-parity-audit.md](feature-parity-audit.md) §1.2.

These are all answerable in <2 hours once `LABEL=homenaviwork` is mounted and we can `strings`/`readelf`/`objdump` `navi_ps` plus look at `/home/naviwork/system/data/`.

---

## 11. Cross-references

- [forensic-clock-service.md](forensic-clock-service.md) — `abstc` consumes GPS-time off the same AV-CAN frames navi_ps cares about
- [forensic-phone-stack.md](forensic-phone-stack.md) — `tel_proc` is one of the senders to `/navi_ps_main` (call-active state → navi_ps suppresses voice prompts during call); also documents the PulseAudio media-cork pattern used for nav prompt ducking
- [forensic-daemon-supervision.md](forensic-daemon-supervision.md) — `nav_navi.service` shape, the smng cascade, masking strategy
- [forensic-denso-ipc.md](forensic-denso-ipc.md) — `/navi_ps_main` queue is rank-1 drain priority (Plan B''' MUST own this queue or backend daemons OOM)
- [forensic-factory-ui-binary.md](forensic-factory-ui-binary.md) — EmgdHmi pixmap rendering contract that navi_ps inherits from the UI daemon family; eglfs_emgdhmi Qt plugin design
- [forensic-emgdhmid-flip-protocol.md](forensic-emgdhmid-flip-protocol.md) — how navi_ps's pixmap gets onto the Sprite C plane → LVDS
- [forensic-drawbuf-call-sequence.md](forensic-drawbuf-call-sequence.md) — reference impl of EGL+emgdHmi bring-up that navi_ps follows
- [feature-parity-audit.md](feature-parity-audit.md) §1.2 — visible navigation feature set we must preserve in the rebuild
- [lower-screen-architecture.md](lower-screen-architecture.md) — explains the 800×960 stacked virtual canvas that navi_ps may render into
- [DSU_HARDWARE_INVENTORY.md](DSU_HARDWARE_INVENTORY.md) — AV-CAN bus, NAVI ECU sub-module hardware context
- [DSU_OEM_DOCUMENTATION.md](DSU_OEM_DOCUMENTATION.md) — ITB22-013 (last factory map update 2022-03-31), AV section reference
- [project_planB_kill_set.md](../../../.claude/projects/-Users-dpitek-Developer-q60-rebuild/memory/project_planB_kill_set.md) — confirms navi_ps is in the kill set (replace), with `/navi_ps_main` drain requirement
- [project_planB_triple_prime.md](../../../.claude/projects/-Users-dpitek-Developer-q60-rebuild/memory/project_planB_triple_prime.md) — Plan B''' architecture: Qt eglfs against factory EMGD libs, take over rendering
- [project_strategic_pivot_back_to_r1.md](../../../.claude/projects/-Users-dpitek-Developer-q60-rebuild/memory/project_strategic_pivot_back_to_r1.md) — confirms factory kernel + factory libs is the path forward
- `~/Developer/nissan-nav-updater/` — Doug's reverse engineering of MAPAL/REFER/HOUSE/RDSTM partition formats (referenced; not re-documented here)
- [CLAUDE.md](../CLAUDE.md) — project-wide context, including Valhalla as the routing engine for Plan B'''
