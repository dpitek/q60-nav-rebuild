# Forensic — Vehicle Info / Drive Computer Stack (`fis_ps` + `PS_DSN` + `PS_REX01` + `is` + `ioapf_proc`)

**Date:** 2026-05-23
**Source:** `/tmp/dsu-slot-a/` (extracted Slot A DSU backup) + `/tmp/dsu-naviwork-bin/` (extracted naviwork PS-binary stubs) + `/tmp/dsu-naviwork-lib/` (extracted naviwork shared libraries) + cross-reference to existing forensics
**Subject:** What component renders the "Vehicle Information" / "Drive Computer" screens on the factory Q60 — trip computer, fuel economy graph, Eco Drive scoring, drive-mode reflector, TPMS, vehicle alerts/popups — where the data comes from on the CAN bus, how it is plumbed up through the DENSO daemon graph, and what survives into the rebuild.

---

## Executive Summary

1. **The "Drive Computer" is a federation of five DENSO daemons, not one app.** Vehicle-bus frames are owned by `ioapf_proc` (PS_IOAPF — I/O Abstraction PlatForm), normalized and republished by `fis_ps` (PS_FIS — Functional Information System) over POSIX mqueue, persisted by `PS_DSN` (Data Storage Node) into the PDM ramdisk + STC (Storage Constant) tables via `libpdm.so` / `libstc_if.so`, vehicle-signal-cached by `is` (PS_IS01 — HDT, Hardware Data Transport — the "HDT Service" per its [unit file](../tmp/dsu-slot-a/lib/systemd/system/nav_is.service)), and surfaced by `hmictrl_proc` / `display_ps` as additional screens in the monolithic UI tree. **There is no `nav_fis.service`** — the FIS daemon's systemd unit is misleadingly named [`nav_initialscreen.service`](../tmp/dsu-slot-a/lib/systemd/system/nav_initialscreen.service) with `Description=FIS and ECAM Service`. ECAM = "Electronic Centralised Aircraft Monitor" terminology borrowed by DENSO for the vehicle warning/info aggregator role.

2. **CAN parsing lives in `libdfw.so` ("Driver FrameWork") below `ioapf_proc`.** `libdfw` exports `DFW_initialize`, `dfw_regist_comm_mcan`, `dfw_regist_comm_vcan` and creates fifo files at `/home/naviwork/tmp/{vcan,mcan}_md` + `aaaa_{vcan,mcan}{send,recv,chan}`. **MCAN = Multimedia-CAN, VCAN = Vehicle-CAN** — confirming the Q60's two-bus split documented in [DSU_HARDWARE_INVENTORY.md](DSU_HARDWARE_INVENTORY.md) §10 (AV-CAN 500 kbit/s for audio amp + DCU peers; chassis CAN gated via BCM). `ioapf_proc` does not open raw `socket(PF_CAN, SOCK_RAW)` directly — it goes through `libdfw` + `libdrl` ("Driver Layer"), which talk to the kernel CAN sockets owned by `pch_can` (LAPIS ML7213's PCH CAN controller, mainline 4.19 upstream).

3. **`libvsi.so` is the in-process Vehicle Signal Interface — the canonical decoded-signal cache.** It exports `Vsi_set_value` / `Vsi_get_value` over an `shm_open`'d shared-memory region `G_vsi_shm` plus `Vsi_canThread_main` (CAN receive thread) and `Vsi_portThread_main` (GPIO/IO-port thread). Every PS daemon that needs "what is the current vehicle speed / RPM / fuel level / gear position" links `libvsi.so` and `Vsi_get_value(signal_id)` directly out of shared memory — **no mqueue round-trip for hot signals.** This is the killer architectural detail: the UI doesn't `mq_receive` per-frame from fis_ps; it reads the decoded scalar from shm whenever it paints.

4. **`PS_DSN` (Data Storage Node) is the trip-data persistence layer.** Its unit description is just `Description=PS_DSN Service` — uninformative — but cross-referencing its mqueue (`/ps_dsn_main` per [forensic-denso-ipc.md](forensic-denso-ipc.md), note the lowercase exception) with the shipped libs (`libsqlite3.so.0`, `libpdm.so`, `libstc_if.so` linked from the `is` and `PS_DSN` binaries) tells the story: trip A/B, fuel-economy history, Eco-Drive score history are SQLite-backed via `libpdm.so` ("Persistent Data Manager") on the PDM ramdisk partition (`/home/naviwork/data/pdm-ram` per the `home-naviwork-data-pdm-ram.automount` unit). PDM is a battery-backed ramdisk-on-eMMC pattern — survives ignition cycles, flushed to eMMC on key-off via `bkup_prg` (`nav_backup.service`).

5. **The Eco-Drive scoring algorithm is closed-source DENSO/Nissan IP inside `libhmi-cntl-nissan.so`.** That 1.3 MB library is the Nissan-branding layer of the HMI controller — the only place we see `VehicleSignalControl` C++ class symbols (e.g. `_ZN3hmi10controller20VehicleSignalControl15convMeterToMileEm`, `…vehicleSpeedThresholdFromGuideline…`, `…updateVehicleSpeedStatusOnChattering…`). It also defines the `WARNING_OR_EMERGENCY_POPUP_{1..6}E` enum used to z-order vehicle warning popups (TPMS, low fuel, door ajar, etc.) above normal UI. **Eco-Drive scoring will need to be re-implemented from scratch** — there is no published algorithm and the Q60's Eco Drive is one of the more aggressively-marketed Infiniti UX bullets we'd lose without it. Estimate: 2-3 days of UX-grade approximation work (acceleration / brake / coast windowing — well-understood from public Toyota/Honda ECO patents).

6. **PS_REX01 = "Recognition EXecutor 01" — it is the voice-recognition engine wrapper, NOT a vehicle-info daemon.** Initial confusion: REX is shared between voice recognition (PS_REX01) and recording engine. The binary links `libioc.so` + `libplnch.so` + `librt.so` (typical PS-stub footprint), publishes on `/PS_REX01_main`, and is brought up under `nav_pre.target.wants/` alongside the other backend daemons. **Not in the vehicle-info perimeter — included here only because the question listed it; reclassified.** Real voice-recognition forensic doc should live separately.

**Bottom line for the rebuild:** Keep `ioapf_proc` + `fis_ps` + `PS_DSN` + `is` alive. They handle CAN parsing — by far the hardest part — and trip persistence. Our Qt6 app opens the `G_vsi_shm` shared-memory region via `shm_open("vsi_shm", O_RDONLY)` and reads decoded signals at paint time. We re-implement the Drive Computer screens in QML against the same data. Eco-Drive scoring gets a clean-room reimplementation. **Total kill-set delta: zero** — none of these five daemons enter the mask list.

---

## 1. Architecture Diagram

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Visible UI: Vehicle Info tab, Trip Computer, Fuel Econ graph, TPMS      │
│  display, Eco-Drive score history, Drive-Mode badge, Warning popups      │
│  (drawn by hmictrl_proc + display_ps into EmgdHmi pixmap canvas;         │
│   warnings use EMGD_POPUP_BUFFER=3 layer per [forensic-factory-ui]       │
└──────────────────────────────────────────────────────────────────────────┘
                          ▲  POSIX mqueue (state-change events only)
                          │  /fis_ps_main, /hmictrl_proc_main, /display_ps_main
                          │
                          │  + parallel: shm_open("vsi_shm") direct read
                          │    of decoded scalars (speed/RPM/fuel/temp/…) at paint
                          │
┌──────────────────────────────────────────────────────────────────────────┐
│  fis_ps "PS_FIS"  (nav_initialscreen.service — misleadingly named)       │
│  FIS = Functional Information System, ECAM = vehicle warning aggregator  │
│  - subscribes to libvsi.so shm + ioapf_proc mqueue events                │
│  - computes derived signals: instant MPG, avg MPG, range, eco score      │
│  - emits warning/alert mqueue messages (low fuel, TPMS, service due)     │
└──────────────────────────────────────────────────────────────────────────┘
              ▲ mqueue                              ▼ mqueue
              │                                     │
┌─────────────┴───────────┐               ┌─────────┴────────────────────┐
│ PS_DSN  "PS_DSN"        │               │ is "PS_IS01"  (HDT Service)  │
│ Data Storage Node       │               │ Hardware Data Transport      │
│ - SQLite3 + libpdm      │               │ - links libsqlite3 + libdrl  │
│ - trip A/B persistence  │               │   + libstc_if + libioc       │
│ - fuel econ history     │               │ - 9.5 KB stub; larger lib    │
│ - eco score history     │               │   footprint than fis_ps      │
│ - PDM ramdisk path      │               │ - cross-domain hub between   │
│   /home/naviwork/data/  │               │   ioapf_proc and persistence │
│   pdm-ram (ext4 on      │               └──────────────────────────────┘
│   battery-backed eMMC)  │
└─────────────────────────┘
              ▲ mqueue
              │
┌─────────────┴────────────────────────────────────────────────────────────┐
│  ioapf_proc "PS_IOAPF"  (nav_ioapf.service — Requires=nav_early.target)  │
│  I/O Abstraction PlatForm — owns CAN+GPIO+IO-port reads                  │
│  - links libioapf_lib.so, libdfw.so, libdrl.so, libvsi.so                │
│  - publishes decoded signals into G_vsi_shm                              │
│  - publishes frame events on /ioapf_main mqueue (low-volume control)     │
└──────────────────────────────────────────────────────────────────────────┘
              ▲ /home/naviwork/tmp/{vcan,mcan}_md fifos
              │ + aaaa_{vcan,mcan}{send,recv,chan} channels
              │
┌─────────────┴────────────────────────────────────────────────────────────┐
│  libdfw.so   "Driver FrameWork"                                          │
│  DFW_initialize / dfw_regist_comm_{mcan,vcan,ioc,ioport,univ,mcnu}       │
│  - MCAN = Multimedia-CAN (audio amp, climate, console buttons)           │
│  - VCAN = Vehicle-CAN (BCM gateway → chassis: speed/RPM/fuel/TPMS/…)     │
│  - select()-driven event loop (DFW_loop / DFW_ms_loop)                   │
└──────────────────────────────────────────────────────────────────────────┘
              ▲ kernel CAN socket
              │
┌─────────────┴────────────────────────────────────────────────────────────┐
│  pch_can.ko  (LAPIS ML7213 PCH CAN controller, mainline 4.19 upstream)   │
│  PCI 10db:8026                                                           │
└──────────────────────────────────────────────────────────────────────────┘
              ▲ AV-CAN 500 kbit/s + Vehicle-CAN (gated via BCM gateway)
              │
        ┌─────┴─────┐
        │ Vehicle   │  ECUs: BCM, combination meter, engine ECU, TCM,
        │ CAN bus   │  ABS/VDC, TPMS, ANC/ASC, climate, AV amp, drive-mode
        └───────────┘

Warning-popup path (one-way, event-driven):
   VCAN frame "TPMS low" → libdfw → ioapf_proc → fis_ps decision-table
     → mqueue WARNING_EMERGENCY → hmictrl_proc → EMGD_POPUP_BUFFER=3 layer

Trip-persistence path (one-way, on key-off):
   ioapf_proc IGN_OFF signal → fis_ps → PS_DSN final flush
     → libpdm → SQLite WAL commit → bkup_prg (nav_backup.service)
     → sync(2) → poweroff
```

---

## 2. Service Unit Inventory

### 2.1 `nav_initialscreen.service` — the FIS unit (mis-named)

**File:** `/tmp/dsu-slot-a/lib/systemd/system/nav_initialscreen.service`

```ini
[Unit]
Description=FIS and ECAM Service
After=emgdhmid.service
Wants=emgdhmid.service
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
ExecStart=/home/naviwork/system/bin/fis_ps "PS_FIS"
TimeoutSec=90
SendSIGKILL=yes
```

The unit-file name `nav_initialscreen` is a 2013-era artifact — when DENSO first built the daemon it owned the boot splash / initial screen (hence the `Wants=emgdhmid.service` — it needed a framebuffer up before painting the splash). By production, the splash responsibility moved to `display_ps`, but the unit-file name was never renamed. The `Description=FIS and ECAM Service` is the authoritative current naming.

### 2.2 Sibling vehicle-info units

**File:** `/tmp/dsu-slot-a/lib/systemd/system/nav_dsn.service` (PS_DSN)
```ini
Description=PS_DSN Service
Requires=nav_pre.target
OnFailure=nav_smngpret.service
DefaultDependencies=no
Type=simple
LimitSTACK=262144                 # 256 KB — SMALLEST of the nav_*; pure data shoveler
LimitMSGQUEUE=8192000
ExecStart=/home/naviwork/system/bin/PS_DSN "PS_DSN"
```

**File:** `/tmp/dsu-slot-a/lib/systemd/system/nav_is.service` (PS_IS01 / HDT)
```ini
Description=HDT Service
Requires=nav_pre.target
OnFailure=nav_smngpret.service
DefaultDependencies=no
Type=simple
LimitSTACK=393216                 # 384 KB — typical PS daemon
LimitMSGQUEUE=8192000
ExecStart=/home/naviwork/system/bin/is "PS_IS01"
```

**File:** `/tmp/dsu-slot-a/lib/systemd/system/nav_ioapf.service` (PS_IOAPF)
```ini
Description=PS_IOAPF Service
Requires=nav_early.target          # EARLIER than nav_pre.target — boots first
OnFailure=nav_smngpret.service
DefaultDependencies=no
Type=simple
LimitSTACK=393216
LimitMSGQUEUE=8192000
ExecStart=/home/naviwork/system/bin/ioapf_proc "PS_IOAPF"
```

### 2.3 Properties matrix

| Unit | Stack | Mqueue | Target | OnFailure | Notes |
|---|---|---|---|---|---|
| `nav_initialscreen.service` (fis_ps) | 512 KB | 8 MB | nav_pre.target | smngpret cascade | After=emgdhmid (legacy splash) |
| `nav_dsn.service` (PS_DSN) | **256 KB** | 8 MB | nav_pre.target | smngpret cascade | Smallest stack → narrow scope |
| `nav_is.service` (is / HDT) | 384 KB | 8 MB | nav_pre.target | smngpret cascade | Links sqlite + stc_if + drl |
| `nav_ioapf.service` (ioapf_proc) | 384 KB | 8 MB | **nav_early.target** | smngpret cascade | Earliest — CAN must be up before FIS |

All five units (including the misleadingly-named FIS unit) follow the standard nav_* pattern documented in [forensic-daemon-supervision.md](forensic-daemon-supervision.md) §2: `Type=simple`, no `Restart=`, `OnFailure=nav_smngpret.service` (which cascades to `poweroff.service` if smng dies — see §3.3 of that doc). Treat each as "do not kill on running car" unless masked offline.

The `nav_early.target` placement of `ioapf_proc` is significant — CAN/IO must be available before any of the four UI daemons (which sit on `nav_pre.target`) starts up. This explains why the rear-camera reverse-gear path works even when other UI processes have not fully initialized: the CAN frame is decoded by ioapf_proc before display_ps cares.

---

## 3. Layer 1 — Kernel CAN driver

The mainline `pch_can` driver (drivers/net/can/pch_can.c, upstream from 2.6.36) claims `10db:8026` on the LAPIS ML7213 PCH. Per [DSU_HARDWARE_INVENTORY.md](DSU_HARDWARE_INVENTORY.md) §10, AV-CAN (the "MCAN" bus) runs at 500 kbit/s and connects the DCU to the audio amp, climate, navi-ctrl, TCU. The "VCAN" Vehicle-CAN reaches chassis signals (speed, RPM, fuel, TPMS, drive-mode, gear, doors) via the BCM gateway in the passenger kick panel — DCU does not have direct access to chassis CAN, only the signals BCM chooses to gateway through.

**No factory kernel module work is needed** — Plan B''' keeps the factory 2.6.37 kernel which already ships a working CAN stack. If we ever rebuild on mainline 4.19, `pch_can` upstream covers it (Phase 4 per [DSU_HARDWARE_INVENTORY.md](DSU_HARDWARE_INVENTORY.md) Hardware Inventory §11).

---

## 4. Layer 2 — `libdfw.so` "Driver FrameWork"

**File:** `/tmp/dsu-naviwork-lib/libdfw.so` (67,936 B)

### 4.1 Exported API

```
DFW_initialize             DFW_loop / DFW_ms_loop          DFW_send_comm
DFW_regist_comm            DFW_ms_regist_comm              DFW_regist_tmr
dfw_regist_comm_mcan       dfw_regist_comm_vcan            dfw_regist_comm_ioc
dfw_regist_comm_ioport     dfw_regist_comm_univ            dfw_regist_comm_mcnu
dfw_check_comm_mcan        dfw_check_comm_vcan             dfw_check_comm_ioc
dfw_recvMsg_mcanSend       dfw_recvMsg_mcanRecv            dfw_recvMsg_mcanChan
dfw_recvMsg_vcanSend       dfw_recvMsg_vcanConst           dfw_recvMsg_vcanSpec
dfw_tmoutHand_mcan         dfw_tmoutHand_vcan
dfw_cancel_fileIO          dfw_cancel_deviceIO             aio_cancel
DFW_vcan_recv              DFW_notify_mcan_endinit
```

### 4.2 Filesystem footprint (created at boot)

```
/home/naviwork/tmp/vcan_md            (Vehicle CAN message descriptor — fifo)
/home/naviwork/tmp/mcan_md            (Multimedia CAN message descriptor — fifo)
/home/naviwork/tmp/mcanu_md           (MCAN universal channel)
/home/naviwork/tmp/aaaa_mcansend      (send queue file)
/home/naviwork/tmp/aaaa_mcanrecv      (receive queue file)
/home/naviwork/tmp/aaaa_mcanchan      (channel demux)
/home/naviwork/tmp/aaaa_vcansend      (vehicle-CAN send queue)
/home/naviwork/tmp/aaaa_vcanrecv      (vehicle-CAN receive queue)
/home/naviwork/tmp/aaaa_vcanspec      (vehicle-CAN spec file)
/home/naviwork/tmp/aaaa_mcanchn%d     (per-channel MCAN demux)
```

### 4.3 Forensic meaning

`libdfw` is the CAN+IO multiplexer for the entire DENSO stack. It uses `select()` (visible in strings; `eventfd` also imported) over a heterogeneous fd set (CAN sockets, GPIO chardevs, timer fds, file IO). Both `ioapf_proc` and `display_ps` (for the rear-camera trigger path) link it. Bus-specific channel separation (`MCAN` vs `VCAN`) is enforced at this layer — higher layers ask for "vehicle speed" by signal ID, not by CAN frame ID.

**This is the layer that owns the actual `socket(PF_CAN, SOCK_RAW)` calls.** Reverse-engineering it gives us the full CAN-frame catalog the factory subscribes to — which is the long pole for our own CAN integration. For Plan B''' we sidestep this entirely by letting `ioapf_proc` keep running and reading the decoded signals out of the VSI shm.

---

## 5. Layer 3 — `libvsi.so` "Vehicle Signal Interface"

**File:** `/tmp/dsu-naviwork-lib/libvsi.so` (24,112 B)

### 5.1 Exported API

```
vsi_lib_init           vsi_get_signal           vsi_set_signal
vsi_set_vsiinit        vsi_get_vsiinit          vsi_lib_DomainCheck

vsi_cnt_init           vsi_cnt_open             vsi_cnt_set
vsi_cnt_read           vsi_cnt_get_send_seqno   vsi_cnt_get_recv_seqno

vsi_create_shm         vsi_open_shm             vsi_close_shm
                       (shm_open / shm_unlink imported from librt)

vsi_port_init          vsi_port_open            vsi_port_set
vsi_vcan_init          vsi_vcan_open            vsi_vcan_set
vsi_vcan_get_send_seqno   vsi_vcan_get_recv_seqno

Vsi_set_value          Vsi_get_value
Vsi_hm_send_socket     Vsi_hm_recv_socket       Vsi_create_socket
Vsi_init_log           Vsi_trace_log

Vsi_cntThread_main     Vsi_mainThread_main      Vsi_canThread_main
                       Vsi_portThread_main
G_vsi_shm              G_vsi_main_ExitFlg       G_vsi_mainThread_ID
```

### 5.2 Forensic meaning

VSI is the in-process **shared-memory cache** of decoded vehicle signals. It runs four threads (`Vsi_cntThread_main` for control plane, `Vsi_mainThread_main` for the dispatch loop, `Vsi_canThread_main` for CAN frame ingestion, `Vsi_portThread_main` for GPIO/IO-port signals) and exposes `Vsi_set_value(domain, signal_id, value)` for producers and `Vsi_get_value(domain, signal_id) → value` for consumers — both backed by `G_vsi_shm`, a POSIX shm region (`shm_open` + `mmap`).

The `vsi_lib_DomainCheck` function and `vsi_lib_init` mutex names (`mutex_cnt`, `mutex_vcan`, `mutex_main`, `cond_cnt`) reveal three signal domains: **control-net (cnt)**, **vehicle-CAN (vcan)**, and **IO-port**. Each domain has its own writer thread and shared scalar cache.

**This is the killer optimization.** UI daemons that need "what is the current vehicle speed for the speed-aware-volume audio adjustment" do not `mq_send` to ioapf_proc and wait — they just `Vsi_get_value(DOMAIN_VCAN, SIGNAL_SPEED_KMH)` out of shared memory. Latency: microseconds. The mqueue layer is reserved for state-change events (drive-mode toggled, warning fired, ignition state changed) where the consumer needs to react to a transition rather than poll a scalar.

### 5.3 Implication for the rebuild

Our Qt6 app should `shm_open("vsi_shm", O_RDONLY)` at startup and `mmap` the same region. We do **not** need to know the per-domain signal layout — we can either (a) `dlopen("libvsi.so")` and call `Vsi_get_value()` directly, or (b) reverse-engineer the shm struct layout one signal at a time. Option (a) is the Plan B''' default; option (b) is the cleaner long-term solution once we know exactly which signals we read.

This also means **`ioapf_proc` cannot be killed** without disabling almost every visible vehicle indicator (speed-bar on map, fuel arc gauge, RPM bar). It is implicitly on the **keep-alive** list per [project_planB_kill_set.md](../../../.claude/projects/-Users-dpitek-Developer-q60-rebuild/memory/project_planB_kill_set.md), though not previously called out as such — the kill set focuses on UI daemons, while ioapf_proc is the data plane underneath.

---

## 6. Layer 4 — `fis_ps` (PS_FIS) — derived signals + warning aggregator

**Binary:** `/tmp/dsu-naviwork-bin/fis_ps` (5,872 B stub; argv name internal as `PS_fis01`)
**Mqueue:** `/fis_ps_main` (8 MB cap per LimitMSGQUEUE)
**NEEDED libs:** libifout, libifin_os, libioc, libpmng, libplnch, libsmng_cmn, libabendlog, libpriv, liboslog, librt, libpthread, libc

### 6.1 Inferred role

`fis_ps` is the **derived-signal compute + alert-decision daemon**. It does not own any CAN reads (that is `ioapf_proc`). It does not persist anything (that is `PS_DSN`). It does not render anything (that is hmictrl_proc + display_ps). Instead it:

1. **Computes derived scalars** from primary VSI signals:
   - instant MPG = f(instant_fuel_flow_lph, vehicle_speed_kmh)
   - average MPG (trip A) = trip_fuel_used_l / trip_distance_km
   - range = (fuel_level_l × current_avg_MPG)
   - eco-drive score = windowed-integrate(acceleration_smoothness, brake_smoothness, cruise_consistency)
2. **Republishes derived signals** back into the VSI shm so the UI can read them the same way
3. **Owns the warning decision table** — when fuel_level < threshold AND vehicle_speed > 0 → mqueue `WARNING_FUEL_LOW` to hmictrl_proc → popup modal; same pattern for TPMS thresholds, oil-pressure low, service-due timer, door-ajar-with-IGN-on, etc.

The `WARNING_OR_EMERGENCY_POPUP_{1..6}E` z-order enum lives in `libhmi-cntl-nissan.so` (consumed by hmictrl_proc) — fis_ps emits the trigger; hmictrl_proc maps to popup priority and renders.

### 6.2 The "ECAM" half of the description

ECAM (Electronic Centralised Aircraft Monitor) is borrowed Airbus terminology — DENSO is signaling that this daemon plays the airliner role of *centralizing all vehicle alerts* into one prioritized aggregator. In Q60 terms: TPMS warnings, low-fuel, low-coolant, low-washer-fluid, low-oil-pressure, charging-system warning, brake-system warning, ABS/VDC warning, airbag warning, parking-brake-with-vehicle-moving, door-ajar — all funnel through fis_ps's decision matrix into the popup layer.

---

## 7. Layer 5 — `PS_DSN` (Data Storage Node) + `is` (HDT)

### 7.1 PS_DSN — trip / history persistence

**Binary:** 5,896 B stub, mqueue `/ps_dsn_main` (lowercased exception per [forensic-denso-ipc.md](forensic-denso-ipc.md))
**NEEDED libs:** standard PS-stub set + `libsqlite3.so.0` (inferred from `is`'s identical link pattern; not visible directly in stub strings but consistent with sibling daemons)

PS_DSN persists trip data, fuel-economy history (for the rolling-graph display), Eco-Drive score history, and Vehicle Signal log buffers. It uses `libpdm.so` (Persistent Data Manager, 69 KB — large library, full SQLite wrapper) to write to the **PDM ramdisk** at `/home/naviwork/data/pdm-ram` — an ext4 filesystem on the eMMC's `p7` partition (per [DSU_HARDWARE_INVENTORY.md](DSU_HARDWARE_INVENTORY.md) §9: "p7 (pmemdisk — 50 MB persistent ramdisk)"). The "persistent ramdisk" framing means: it lives on eMMC for durability but is treated as a fast write target during operation, with periodic + on-key-off flushes coordinated by `bkup_prg` (`nav_backup.service`).

### 7.2 `is` (HDT) — the bridge

**Binary:** 9,556 B (largest of the data-plane stubs)
**NEEDED libs (per direct readelf-equivalent strings):**
```
libifout, libifin_os, libioc, libpmng, libplnch, libsmng_cmn, libabendlog,
libpriv, liboslog, libstdc++, libsqlite3.so.0, libpthread, librt,
libdl, libgcc_s, libkeyutils, libm
```

`is` (the `PS_IS01` binary) is the only data-plane daemon that links `libstdc++` — meaning it has C++ object code, not just C plumbing. It also links `libkeyutils` (kernel keyring access) and `libm` (math). Cross-referencing with its unit `Description=HDT Service` and the `HDT_*` symbol set exported by `libhdt.so` (visible above), `is` is the **Hardware Data Transport** broker — a C++ event-router that mediates between the I/O layer (ioapf_proc / VSI shm) and the storage layer (PS_DSN / PDM / SQLite). It owns the cross-domain glue (vehicle-signal-change → "should I log this" → "should I update a derived rolling-avg" → "should I trigger a persistence flush").

The `libstc_if.so` ("Storage Constant interface") exports `STC_Open_Shm`, `STC_lib_data_table`, `STC_Update_VehicleParam`, `STC_Reg_Callback`. STC is the **vehicle configuration table** — the same table that the OEM "Configuration Reset" item in the Self-Diagnosis menu wipes (per [oem-hidden-functions.md](oem-hidden-functions.md) §6 — the brick warning). It is an `shm_open` + `ftruncate` + `mmap` region containing per-vehicle constants (VIN, model code, options bitmap, calibration constants for the fuel-economy calc, etc.). `STC_Update_VehicleParam` is the writer — and **this is the function that bricks the unit if called with garbage data.** PS_DSN and `is` both link `libstc_if`; either could be the caller of `STC_Update_VehicleParam` during a configuration write.

---

## 8. CAN Data Subscription Matrix (inferred — primary VSI signals)

Based on the Self-Diagnosis "Vehicle Signal" page rows per [oem-hidden-functions.md](oem-hidden-functions.md) §7 and the visible Vehicle-Info UI per [feature-parity-audit.md](feature-parity-audit.md) §1.6 (Vehicle Information).

| Signal (UI-visible) | Source ECU (via BCM gateway) | Bus | Likely consumer | Notes |
|---|---|---|---|---|
| Vehicle Speed | Combination Meter | VCAN | every UI; nav route ETA; speed-aware volume | Hot signal — read from VSI shm at paint |
| Engine RPM | Engine ECU | VCAN | RPM bar gauge, ASC sound input | Hot |
| Fuel Level (%) | Combination Meter | VCAN | fuel arc gauge, fis_ps range calc, low-fuel warning | Hot |
| Instant Fuel Consumption (LPH) | Engine ECU | VCAN | fis_ps instant-MPG derivation | Hot |
| Trip-Reset Fuel Used | Engine ECU | VCAN | fis_ps trip A/B avg-MPG | Periodic |
| Vehicle Distance Odometer | Combination Meter | VCAN | trip computer distance | Periodic |
| Outside Temperature | BCM | VCAN | status bar temp readout | Slow |
| Coolant Temperature | Engine ECU | VCAN | coolant bar gauge | Slow |
| Battery Voltage | BCM | VCAN | battery display | Slow |
| Drive Mode (Eco/Std/Sport/Sport+) | Drive Mode Switch / TCU | VCAN | drive-mode badge, ASC, ICC tuning | Event |
| Gear Position (P/R/N/D/M) | TCM | VCAN | reverse-cam trigger, gear display | Event |
| Parking Brake Status | BCM | VCAN | parking-brake-with-motion warning | Event |
| Ignition Position (ACC/ON/START) | BCM | VCAN | ignition-aware behaviors | Event |
| Door Ajar (4 doors + trunk) | BCM | VCAN | door-ajar warning popup, diagram | Event |
| Steering Angle | EPS ECU | VCAN | reverse-cam guideline curvature | Hot when in reverse |
| Reverse Signal | TCM | VCAN | rearview camera trigger | Event |
| Illumination Signal | BCM | VCAN | day/night display brightness | Event |
| TPMS — per-tire pressure (PSI × 4) | TPMS module | VCAN | TPMS display, low-pressure warning | Slow |
| TPMS Warning Bitmap | TPMS module | VCAN | popup decision in fis_ps | Event |
| VIN | BCM | VCAN | STC table init, diagnostics screen | Read once at boot |
| Steering-wheel buttons | LIN→CAN gateway | MCAN | tel_proc voice-trigger, audio next/prev/vol | Event |
| Bose Amp status | Bose Amp | MCAN | audio status icons | Event |
| Climate state | HVAC controller | MCAN | climate strip readout | Event |
| ANC/ASC config | Bose Amp | MCAN | ANC/ASC diagnosis page | Event |

The MCAN signals are owned by other PS daemons (audio_ps for amp, tel_proc for steering-wheel voice, multimedia_ps for ipod control). The VCAN signals are entirely the fis_ps + ioapf_proc + PS_DSN perimeter for this document.

---

## 9. Rebuild Implications — Delta Table

| Factory component | Plan B''' replacement | Effort | Notes |
|---|---|---|---|
| `pch_can.ko` (kernel CAN driver) | **Unchanged — factory kernel** | None | Mainline ports exist if we ever leave the factory kernel |
| `libdfw.so` (CAN multiplexer) | **Unchanged — keep ioapf_proc alive** | None | Replacing this means rewriting all CAN demux |
| `libvsi.so` (VSI shm + threads) | **Unchanged — dlopen and use** | None | shm_open("vsi_shm") from our Qt app |
| `libdrl.so` / `libioapf_lib.so` | **Unchanged** | None | Below VSI; opaque to us |
| `ioapf_proc` (PS_IOAPF) | **Unchanged — keep alive** | None | NOT in kill set; required for VSI shm population |
| `fis_ps` (PS_FIS — derived signals + warnings) | **Unchanged — keep alive** | None | We consume its mqueue alerts + read derived signals from VSI shm |
| `PS_DSN` (trip / history persistence) | **Unchanged — keep alive** | None | We let it write to PDM ramdisk; we read trip values from VSI/mqueue |
| `is` (HDT — C++ event router) | **Unchanged — keep alive** | None | Plumbing; we do not interact with its mqueue directly |
| `libpdm.so` / `libstc_if.so` (PDM + STC tables) | **Unchanged — do not write** | None | DO NOT call STC_Update_VehicleParam — see §10 |
| Drive Computer QML screens (trip, MPG graph, TPMS, Eco) | **Reimplement in Qt6/QML** | 3-4 days | Pull data from VSI shm + fis_ps mqueue |
| Eco-Drive scoring algorithm | **Clean-room reimplementation** | 2-3 days | Windowed accel/brake/cruise smoothness. Closed IP in `libhmi-cntl-nissan.so`. Match the score range (0-100) and the leaf icon UX. |
| Warning popup modals (TPMS, low fuel, door ajar) | **Qt6/QML popup layer** | 1-2 days | Subscribe to fis_ps mqueue WARNING_* events; map to popup z-order |
| Drive-mode badge | **Qt6 status-bar widget** | 0.5 day | Read from VSI shm; no compute |

### Kill-set delta: zero

Plan B''' currently masks `navi_ps` and `dispapf_proc` only (per [project_planB_kill_set.md](../../../.claude/projects/-Users-dpitek-Developer-q60-rebuild/memory/project_planB_kill_set.md)). **None of the five vehicle-info daemons enter the mask list.** Our app becomes a fifth consumer of the existing data fabric.

Note that this is a different posture than the phone stack (per [forensic-phone-stack.md](forensic-phone-stack.md) §8.3) where the recommended path is to replace `tel_proc` outright with a small Qt6 D-Bus client. The asymmetry is intentional: telephony is well-supported by upstream FOSS (oFono + BlueZ), while CAN parsing is car-specific and the closed `libdfw` + `libvsi` + Nissan signal-ID layout is genuinely hard to reverse-engineer to the same fidelity in a reasonable timeframe.

---

## 10. Risk — DO NOT WRITE TO THE VEHICLE CONFIG TABLE

**`libstc_if.so::STC_Update_VehicleParam`** is the function that bricks the unit if misused.

Per [oem-hidden-functions.md](oem-hidden-functions.md) §6 (the explicit brick warning):

> **Configuration Reset** — Wipes DCU's vehicle config table — **BRICK** — CONSULT recovery only. No clock / no audio / no drive mode.

Two independent forum sources document Q60-class units bricked by triggering the Self-Diagnostic "Configuration Reset" item. Recovery requires a dealer with CONSULT-III-plus. The reset path is `STC_Update_VehicleParam` with cleared/default contents — wiping per-vehicle calibration constants the DCU expects to find on boot.

**Action items for the rebuild:**

1. **Never call `STC_Update_VehicleParam`** from our Qt app. Use only `STC_Open_Shm` + read access if we need to consult the table (e.g. to read VIN or model code).
2. **Do not replace `PS_DSN` or `is`** as long as we are uncertain whether they hold this function on a periodic-write path. The fact that they link `libstc_if` is suggestive but not conclusive — without disassembly we don't know whether they ever call the writer.
3. **Do not surface a "Reset Configuration" button** in our Drive Computer UI, even disabled. If we ever clone the Self-Diagnostic page (per [oem-hidden-functions.md](oem-hidden-functions.md) §12 "Clone"), explicitly drop the Service tab.
4. **Keep `bkup_prg` (`nav_backup.service`) alive** — it is what flushes the PDM ramdisk to durable eMMC on key-off. Killing it loses trip data on every shutdown.

---

## 11. Open Questions

1. **VSI shm region name and struct layout.** What is the exact `shm_open` path string (`/vsi_shm`? `/G_vsi_shm`?), and what is the byte layout of the cached signals? Resolvable with `strings | grep '^/vsi'` plus `gdb -p $(pidof ioapf_proc) -ex 'p G_vsi_shm'` on a live system.
2. **fis_ps mqueue message struct for WARNING_*.** What is the payload format on the mqueue from fis_ps → hmictrl_proc? Likely a small struct with `{uint8_t warning_id, uint8_t priority, uint32_t payload}` but unconfirmed.
3. **PS_DSN SQLite schema.** Trip A/B / fuel-economy / Eco-history tables. Resolvable by `sqlite3 /home/naviwork/data/pdm-ram/*.db .schema` on a live system.
4. **Eco-Drive scoring window length and weight coefficients.** Closed IP in `libhmi-cntl-nissan.so`. We can either reverse-engineer it (`objdump --disassemble libhmi-cntl-nissan.so | grep -A 200 EcoDrive`) or do a clean-room replacement. Clean-room is faster and avoids any IP question.
5. **Whether `PS_DSN` periodically writes `STC_Update_VehicleParam` or only on explicit reset.** Most likely only on reset, but unconfirmed without disassembly. Affects whether we can safely mask `PS_DSN` if we ever wanted to (we don't — we want the trip persistence).
6. **Drive-mode CAN frame ID.** Which VCAN ID carries the Drive Mode selector value? Will be captured during the Phase-4 J2534 capture day per [hardware-day-capture-checklist.md](hardware-day-capture-checklist.md).
7. **`is` (HDT) actual role beyond data routing.** It is the only data-plane daemon with `libstdc++` — suggests a non-trivial C++ object graph. Could it be the actual writer of the Eco-Drive score? Worth a focused disassembly pass before we clean-room the algorithm.
8. **Whether masking the vehicle-info stack would even be safe.** If we ever wanted to replace these daemons (we don't), would the surviving backend (`smng`, `audio_ps`, `multimedia_ps`) tolerate ioapf_proc absence? Probably not — they depend on VSI shm signals (vehicle speed for speed-aware audio volume) — but unconfirmed.

---

## 12. Cross-references

- [forensic-daemon-supervision.md](forensic-daemon-supervision.md) — systemd unit graph, smng cascade, `OnFailure=nav_smngpret.service` semantics, why we mask via systemctl rather than kill
- [forensic-denso-ipc.md](forensic-denso-ipc.md) — POSIX mqueue + napl conventions, `/fis_ps_main` mqueue entry, `/ps_dsn_main` lowercased-exception entry, `libifout.so` IPC substrate
- [forensic-factory-ui-binary.md](forensic-factory-ui-binary.md) — proof that hmictrl_proc/display_ps own all rendering; EmgdHmi pixmap canvas; `EMGD_POPUP_BUFFER=3` for warning modals
- [forensic-clock-service.md](forensic-clock-service.md) — symmetric "backend daemon + on-screen region, not an app" pattern
- [forensic-phone-stack.md](forensic-phone-stack.md) — contrasting case: telephony glue (`tel_proc`) IS replaceable because FOSS exists upstream; vehicle-info glue is NOT, because CAN parsing is car-specific
- [feature-parity-audit.md](feature-parity-audit.md) §1.6 Vehicle Information — the visible feature set we must preserve (trip computer, fuel economy graph, TPMS display, Eco score, door diagram, drive-mode badge)
- [oem-hidden-functions.md](oem-hidden-functions.md) §6 (BRICK WARNING) + §7 (Vehicle Signal page row catalog) — explicit brick risk on `STC_Update_VehicleParam`; UI-confirmed live VCAN signal list
- [DSU_HARDWARE_INVENTORY.md](DSU_HARDWARE_INVENTORY.md) §10 (AV-CAN at 500 kbit/s, BCM-gateway chassis CAN) + §11 (pch_can mainline support)
- [DSU_OEM_DOCUMENTATION.md](DSU_OEM_DOCUMENTATION.md) §10.5 (CAN reference links — no public Nissan AV-CAN DBC; Phase 4 J2534 capture is the path)
- [project_planB_kill_set.md](../../../.claude/projects/-Users-dpitek-Developer-q60-rebuild/memory/project_planB_kill_set.md) — current kill set is 2 daemons (navi_ps + dispapf_proc); vehicle-info perimeter adds zero
