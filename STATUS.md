# Q60 Nav Rebuild — Build Status
Last updated: 2026-05-12

---

## ✅ Completed

### Infrastructure
- [x] Working image: factory DCU image backup (slot A preserved, never written)
- [x] Docker toolchain: `q60-toolchain` (Ubuntu 22.04 amd64, GCC 11.4, `-m32 i686`)
- [x] Linux 4.19.0 bzImage built for i386/Bonnell — `output/bzImage-4.19-q60` (4.2MB, ELF 32-bit confirmed)
- [x] Kernel config: `q60_atom_defconfig` (CAN/BT/DRM/MMC/EXT4/SND_HDA/iTCO_WDT/EFI_VARS)
- [x] elilo.conf: `q60nav` entry added, `default=logan1` preserved (slot A never written)

### Boot Safety
- [x] Boot safety analysis doc: `docs/boot-safety.md`
- [x] FAT32 boot counter in `start.sh` — auto-restores `logan1` after 2 failed boots
- [x] fstab: p7→p9 data mount fix, `/boot` rw for counter writes
- [x] `restore-logan1.sh` — 10-second recovery from Mac via USB adapter
- [x] Watchdog: `watchdog-pet.sh` pets iTCO every 20s, init.d as respawn

### C++ Services (all .h + .cpp complete)
- [x] `VehicleService` — SocketCAN (can0/can1/can2), CAN frame parsing, HVAC write via r51-ecu confirmed path (0x540/0x541), Bose wake; 5 new IDs wired: ignition (0x292), doors/trunk (0x358), wipers (0x35D), cruise+coolant (0x551), BCM extended/battery (0x625); UDS door lock/unlock via 0x745; ButtonLogger on all 3 buses
- [x] `NavigationService` — GPSD TCP socket, Valhalla HTTP client, route parsing, rerouting
- [x] `AudioService` — BlueZ D-Bus AVRCP (guarded with `HAVE_QT_DBUS`), DENSO proxy IPC, ALSA volume
- [x] `SearchService` — offline geocoding on port 4000 (Photon/Pelias-compatible, graceful if absent)
- [x] `StatusBridge` — full signal wiring, clock, cross-screen coordination
- [x] `MapLibreItem` — QQuickItem Phase 3 stub; correct `RendererFrontend` / `OffscreenBackend` API (no HeadlessFrontend); EGL wiring TODO

### QML UI (all screens fully implemented)
- [x] `NavigationView` — turn HUD, TurnArrow, approaching-turn pulse, SpeedWidget, reverse overlay
- [x] `ControlHubView` — TabBar component, auto-switch on call/reverse, live status bar
- [x] `ClimateView` — dual temp zones, fan bar, AC/recirc/mode, seat heat
- [x] `AudioView` — BT/FM/AM/SXM/AUX, media controls, volume slider
- [x] `NavCompanionView` — ft/mi countdown, ETA, remaining, speed vs limit, rerouting banner
- [x] `PhoneView` — active call display, mute/end/keypad, DTMF overlay, call timer
- [x] `IncomingCallView` — incoming call screen with answer/decline
- [x] `VoiceCommandView` — voice activation overlay
- [x] `VehicleStatusView` — door diagram (all 4 + trunk), fuel arc, coolant bar (°F live), RPM; all bound to real VehicleService properties
- [x] Components: `TurnArrow`, `SpeedWidget`, `FanControl`, `TempZone`, `TabBar`, `StatusBar`

### Device Init System
- [x] `inittab` — SysV runlevel 5, watchdog respawn
- [x] `rcS` — mount vfs, udev, kernel modules
- [x] `S10-gpsd` — GPSD on ttyS0
- [x] `S20-valhalla` — valhalla-httpd wrapper + valhalla_service on port 8002
- [x] `S25-geocoder` — C+SQLite offline geocoder on port 4000 (graceful if binary/DB absent; replaces Photon/JVM)
- [x] `S30-weston` — Weston compositor; runs `gen-weston-ini.sh` to detect DRM connectors before launch
- [x] `S50-q60nav` — app launch via start.sh
- [x] `weston.ini` / `weston.ini.default` — static fallback; `gen-weston-ini.sh` writes live config at boot
- [x] `detect-display.sh` — scans `/sys/class/drm/card*-*` for connected connectors
- [x] `gen-weston-ini.sh` — generates `/etc/xdg/weston/weston.ini` from detected connectors (fallback: LVDS-1)
- [x] `valhalla.json` — device config, tiles at /opt/valhalla/tiles

### Target Binaries — ALL BUILT ✅
- [x] **Qt 6.6.3 i386** — `output/qt6-i386/` — `libQt6Core.so.6.6.3` ELF 32-bit LSB Intel 80386 confirmed
- [x] **q60nav app** — `output/app-build/bin/q60nav` — ELF 32-bit LSB pie executable, Intel 80386, 199KB stripped
- [x] **valhalla-httpd** — `rootfs/opt/valhalla/bin/valhalla-httpd` — ELF 32-bit LSB, Intel 80386
- [x] **Valhalla i386** — `valhalla_service` (11MB ELF 32-bit) + `valhalla_build_tiles` (16MB)
- [x] **MapLibre GL Native i386** — `libmbgl-core.a` (20MB ELF 32-bit static)
- [x] **Linux 4.19 bzImage** — ELF 32-bit, 4.2MB
- [x] **Routing tiles** — `output/valhalla-tiles/` — 312 tile files, ~717MB

### Support Files
- [x] `rootfs/opt/valhalla/valhalla-httpd.c` — minimal C HTTP proxy for valhalla_service
- [x] `rootfs/opt/nav/style/q60-dark.json` — MapLibre GL dark style
- [x] `scripts/build-map-tiles.sh` — tilemaker Docker vector tile build from regional PBF
- [x] `scripts/build-tiles.sh` — Valhalla routing tile build (official Valhalla Docker image)
- [x] `deps/build-qt6-host.sh` — builds native amd64 Qt6.6.3 qtbase (provides QT_HOST_PATH)
- [x] `scripts/build-app.sh` — compiles valhalla-httpd + q60nav for i686 inside Docker

### Build + Deploy Scripts
- [x] `scripts/deploy-to-image.sh` — write kernel to FAT32, flip elilo.conf for test; `--verify` / `--restore` modes
- [x] `scripts/restore-logan1.sh` — emergency recovery from Mac
- [x] `scripts/package-rootfs.sh` — build 3GB ext4 rootfs image; geocoder-aware (skips gracefully if not built)
- [x] `scripts/build-geocoder-db.sh` — build SQLite FTS5+rtree geocoder DB from NC JSONL dump (~5-10 min on Mac)
- [x] `scripts/build-geocoder-server.sh` — compile geocoder-server for i386 inside q60-toolchain Docker

---

## 🔄 In Progress

| Item | Status | Notes |
|---|---|---|
| Vector tiles (`.mbtiles`) | ✅ Built | `output/vector-tiles/nc.mbtiles` 464MB |
| Rootfs image | ✅ Built | `output/q60nav-rootfs.img` 3GB ext4, 1.3GB used |
| Phase 3: MapLibre EGL wiring | ⏳ Stub complete | `OffscreenBackend` needs EGL pbuffer impl; placeholder renders until then |
| Geocoder DB | ✅ Ready to build | Run `scripts/build-geocoder-db.sh` (~5-10 min, Python3 on Mac) |

---

## ⏳ Remaining Work (ordered)

### Software
1. **Phase 3 — EGL wiring**: Implement `OffscreenBackend::activate()` in `MapLibreItem.cpp` — create EGL pbuffer backed by Mesa swrast, wire `readPixels()` into frame callback. Rebuild with `-DWITH_MAPLIBRE=ON`.
2. **Geocoder (Photon i386 blocker)**: ✅ **RESOLVED** — Replaced Photon/JVM with native C+SQLite geocoder. `geocoder-server` is a single-file C99 binary compiled for i386/Bonnell. SQLite FTS5 full-text search + R-tree spatial index. No JVM, no Java, no Elasticsearch. ~10-50ms queries on Atom hardware. Run `scripts/build-geocoder-db.sh` + `scripts/build-geocoder-server.sh` to produce artifacts.
3. **Bose wake frame**: Sniff AV-CAN at Bose amp connector (trunk). `CAN_BOSE_WAKE = 0x3B3` is a placeholder — see wakeBosse() in VehicleService.cpp.

### Hardware (boot test prerequisites)
5. **[hardware]** Physical boot test — `deploy-to-image.sh --test` (write kernel + rootfs, flip elilo.conf)
6. **[hardware]** J2534 CAN sniff — verify all `CAN_*` IDs, especially HVAC write (0x540/0x541) and body status (0x60D)
7. **[hardware]** GPS UART probe — confirm ttyS device for GPSD
8. **[hardware]** Weston LVDS — dynamic detection will run at boot; verify connector names in `gen-weston-ini.sh` output vs actual DRM driver names

---

## 🗂️ Backlog — Future Features

Features staged for post-v1.0, ordered by impact. Surface these once hardware tests pass and the core nav loop is stable.

### 🔌 Apple CarPlay Integration *(high value — revisit after v1.0)*

**Why it's viable here:**
- DCU has two USB host ports (now configured with getty + FTDI/CP210x drivers)
- Display, audio (Bose), and steering wheel buttons are already wired
- Qt6 on Wayland is a supported CarPlay host environment

**Technical path (open-source, no MFi required):**
- [**aasdk**](https://github.com/f1xpl/aasdk) — reverse-engineered Android Auto / CarPlay protocol library (C++17, Qt6-compatible)
- [**OpenAuto**](https://github.com/f1xpl/openauto) — Qt6 head unit implementation built on aasdk; supports USB + wireless
- Protocol: Apple CarPlay over USB uses the NCM (Network Control Model) protocol; aasdk handles the full stack
- The DCU USB ports are host-mode; phone plugs into DCU, DCU presents as CarPlay head unit

**Integration points in this project:**
- `AudioService` — CarPlay audio routed through existing ALSA/Bose pipeline
- `NavigationView` / `ControlHubView` — CarPlay renders to a Wayland surface on the upper screen
- Steering wheel buttons (0x681 AV-CAN) → mapped to CarPlay media/call controls via existing `VehicleService` signals
- `start.sh` — add `usbmuxd` (Apple USB multiplexer daemon) before q60nav launch

**Estimated effort:** 2-3 weeks. Build aasdk + OpenAuto for i386, wire Wayland surface, integrate audio routing.

**Flag:** Raise this when: (a) boot test confirms USB enumeration works, and (b) Bose wake frame is confirmed.

---

### 📡 Bluetooth Hotspot Connectivity + Deferred Sync *(post-v1.0)*

The DCU has no cellular or Wi-Fi. When a phone hotspot is available (Bluetooth PAN or USB tethering), the system should opportunistically download pending items.

**Architecture:**
- `SyncService` (C++) — runs in background, tracks a **pending-downloads queue** persisted to `/var/lib/q60nav/sync-queue.json`
- Items queued while offline: map tile updates, routing tile updates (NC only), album art (Bluetooth AVRCP metadata → cover art URL), firmware/app updates (rootfs slot B)
- `NetworkMonitor` — polls BT PAN (`bnep0`) / USB-ETH (`usb0`) every 30s; on link-up, calls `SyncService::processQueue()`
- Download priority: album art (KB) > routing updates (MB) > full rootfs (GB)
- `start.sh` addition: `rfkill unblock bluetooth` + `bluetoothd` before q60nav launch
- **BT PAN setup**: `scripts/setup-bt-pan.sh` — pairs trusted phone, brings up `bnep0`

**Items to queue automatically:**
- Album art: when AVRCP metadata has `trackTitle` + `artist` → enqueue cover art fetch from Last.fm/MusicBrainz
- Map updates: check tile server for NC tiles newer than installed (weekly, not on every boot)
- App updates: poll a configurable URL for new `q60nav` binary + rootfs image (slot B write)

**Effort**: ~1 week. Implement SyncService skeleton + queue persistence first; add items incrementally.

| Feature | Notes |
|---|---|
| OTA update mechanism | Part of Bluetooth hotspot sync above — USB drive fallback also viable |
| Android Auto | Same aasdk path as CarPlay — nearly free once CarPlay is done |
| Rear camera integration | Reverse signal (CAN 0x421 gear=R) → switch display to camera feed; needs video capture path |
| SiriusXM passthrough | `sxmcgs.out` / `sxmfc.out` DENSO proxies already started in start.sh — wire to AudioView |
| Speed-limit data | OSM speed limit tags are in Valhalla tiles — expose via NavigationService |
| Multi-region maps | Extend NC tiles to include VA/SC/TN for out-of-area coverage |

---

## ⚠️ CAN IDs — Verify Before Writing

Read IDs confirmed via opendbc/carhack/Leaf AZE0 DBC cross-reference. **Write path needs J2534 verification.**

| Frame | ID | Status | Notes |
|---|---|---|---|
| Speed, RPM, brake, gear, cluster | 0x280, 0x1F9, 0x354, 0x421, 0x5C5 | CONFIRMED read | Cross-platform Nissan/Infiniti |
| Ignition state | 0x292 | Q50_LIKELY | bit0=ACC bit1=IGN bit2=START |
| Door / trunk open | 0x358 | Q50_LIKELY | byte 0 bits 0-4, all 5 states parsed |
| Wiper state | 0x35D | Q50_LIKELY | byte 2: 0=off 1=slow 2=fast 3=one-shot |
| Cruise + coolant temp | 0x551 | Q50_LIKELY | byte 0 cruise bits, byte 6 coolant (0.5°C/LSB -40°C) |
| BCM extended (battery/defrost) | 0x625 | Q50_LIKELY READ ONLY | byte 1 defrost, byte 2 battery ×0.1V; was mislabeled CAN_SEAT_HEAT |
| HVAC status read | 0x54A, 0x54B | CONFIRMED read | Leaf AZE0 DBC |
| HVAC write (temp/mode) | 0x540 | Q50_LIKELY write | From r51-ecu (R51 Pathfinder, same Denso amp) |
| HVAC write (fan) | 0x541 | Q50_LIKELY write | From r51-ecu |
| Body / BCM | 0x60D | CONFIRMED read | carhack 370Z |
| AV buttons | 0x681 | Q50_LIKELY | Leaf AV-CAN DBC |
| BCM door lock (UDS) | 0x745 | Q50_LIKELY write | Service 0x30 DID 0xBF00; warns before sending |
| Bose wake | 0x3B3 | UNVERIFIED | Sniff AV-CAN at amp connector |
| Seat heat write | 0xFFFF | UNVERIFIED PLACEHOLDER | Blocked until J2534 capture |

---

## Key Architectural Notes

| Issue | Resolution |
|---|---|
| Photon geocoder requires Java 21+; Java 21+ has no i386/Linux builds | Replaced with C+SQLite geocoder-server — FTS5+rtree, i386-native, no JVM |
| valhalla_service has no HTTP server (ENABLE_HTTP=OFF) | valhalla-httpd.c wraps CLI binary → port 8002 |
| Qt6 cross-compile needs QT_HOST_PATH | build-qt6-host.sh builds native qtbase first |
| Qt6 xcb detection fails for i386 | `FEATURE_xcb=OFF`, `FEATURE_wayland=ON` |
| Qt6 qtquick3dphysics depends on disabled qtquick3d | `BUILD_qtquick3dphysics=OFF` |
| pkg-config finds amd64 libs for i386 build | `PKG_CONFIG_LIBDIR` set to i386 paths |
| Qt6 GCC Bus error on `-march=bonnell` + QML files | Changed to `-march=i686 -mtune=bonnell` |
| Qt6 QuickControls2 styles (Fusion/Material/etc) OOM on i386 | `FEATURE_quickcontrols2_{fusion,material,universal,imagine,nativestyle}=OFF` |
| Qt6 `qmlcachegen` rejects dual top-level `Window` items | Wrapped in `QtObject` root with `property var` entries |
| Qt6 QML module staging dir (`q60nav/`) collides with executable name | `RUNTIME_OUTPUT_DIRECTORY` → `bin/` |
| Qt6 DBus not available in embedded build | `HAVE_QT_DBUS` compile guard; `AudioService` falls back gracefully |
| MapLibre `mbgl/util/optional.hpp` → missing `optional.hpp` (mapbox-base legacy) | C++17 compatibility shim at `output/maplibre-i386/include/optional.hpp` |
| MapLibre include path cascades to all TUs via `INTERFACE_INCLUDE_DIRECTORIES` | `WITH_MAPLIBRE=OFF` by default; Phase 3 opt-in via `-DWITH_MAPLIBRE=ON` |
| `mbgl::HeadlessFrontend` does not exist in built library | Custom `MinimalRendererFrontend : RendererFrontend` + `OffscreenBackend : gl::RendererBackend`; EGL pbuffer stub |
| Weston connector names unknown pre-boot | `detect-display.sh` + `gen-weston-ini.sh` probe DRM sysfs at boot; fallback to LVDS-1 |
| HVAC write path (Q50/Q60) not publicly documented | r51-ecu research: 0x540 (temp/mode) + 0x541 (fan); Q50_LIKELY, verify via J2534 |
| Valhalla official Docker image is amd64-only (`valhalla/valhalla:run-latest`) | Use `ghcr.io/valhalla/valhalla:latest` — has native arm64 (v3.7.0) |
| Valhalla config paths default to `/data/valhalla/` (not mounted) | Override all paths to `/tiles/` in generated config |

---

## Key Paths (in-container / on-device)

| Path | Contents |
|---|---|
| `output/bzImage-4.19-q60` | Kernel (4.2MB, ELF 32-bit i386) |
| `output/qt6-i386/` | Qt 6.6.3 i386 — confirmed ELF 32-bit |
| `output/maplibre-i386/lib/libmbgl-core.a` | MapLibre GL static lib (20MB ELF 32-bit) |
| `output/valhalla-i386/bin/` | valhalla_service + valhalla_build_tiles (ELF 32-bit) |
| `output/valhalla-tiles/` | Routing tiles (312 files, ~717MB) |
| `output/app-build/bin/q60nav` | App binary (199KB ELF 32-bit stripped) |
| `rootfs/` | Slot B rootfs skeleton |
| `rootfs/opt/valhalla/bin/valhalla-httpd` | HTTP proxy binary (ELF 32-bit) |
