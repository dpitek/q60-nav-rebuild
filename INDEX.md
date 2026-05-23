# Q60 Nav — Code Index
Generated: 2026-05-23 (Phase 1 — first car boot)

Quick map of what's where. For build status see [STATUS.md](STATUS.md). For features see [README.md](README.md). For factory parity see [docs/feature-parity-audit.md](docs/feature-parity-audit.md).

---

## C++ Services (`app/src/services/`)

| Service | Header | Impl | Q_PROPERTYs | Role |
|---|---|---|---|---|
| VehicleService | [VehicleService.h](app/src/services/vehicle/VehicleService.h) | [VehicleService.cpp](app/src/services/vehicle/VehicleService.cpp) | 68 | SocketCAN on can0/1/2; all read paths, HVAC write, UDS, ADAS frame, BCM Work Support unlocks, DTC read/clear, maintenance routines, rain auto-up |
| ButtonLogger | [ButtonLogger.h](app/src/services/vehicle/ButtonLogger.h) | [ButtonLogger.cpp](app/src/services/vehicle/ButtonLogger.cpp) | — | CAN frame audit logger |
| NavigationService | [NavigationService.h](app/src/services/navigation/NavigationService.h) | [NavigationService.cpp](app/src/services/navigation/NavigationService.cpp) | 10 | GPSD + Valhalla HTTP client |
| AudioService | [AudioService.h](app/src/services/audio/AudioService.h) | [AudioService.cpp](app/src/services/audio/AudioService.cpp) | 30 | BlueZ AVRCP, DENSO IPC, ALSA, SSV, RDS, per-source presets |
| SearchService | [SearchService.h](app/src/services/search/SearchService.h) | [SearchService.cpp](app/src/services/search/SearchService.cpp) | 0 | Offline geocoder on :4000 |
| ProfileService | [ProfileService.h](app/src/services/profile/ProfileService.h) | [ProfileService.cpp](app/src/services/profile/ProfileService.cpp) | 11 | Driver profile + key-fob slot |
| SettingsService | [SettingsService.h](app/src/services/settings/SettingsService.h) | [SettingsService.cpp](app/src/services/settings/SettingsService.cpp) | 64 | JSON persistence, atomic write, 5s debounce, factory-parity sub-pages + BCM Work Support unlocks (canVerifiedWrites gate, mirror tilt, horn chirp, welcome lighting, DRL matrix, headlight delay, TPMS thresholds, autoUpOnRain) |
| NetworkService | [NetworkService.h](app/src/services/network/NetworkService.h) | [NetworkService.cpp](app/src/services/network/NetworkService.cpp) | 5 | Wi-Fi vs LTE TCU detect |
| WeatherService | [WeatherService.h](app/src/services/weather/WeatherService.h) | [WeatherService.cpp](app/src/services/weather/WeatherService.cpp) | 10 | Open-API + CAN ambient fallback |
| FuelService | [FuelService.h](app/src/services/fuel/FuelService.h) | [FuelService.cpp](app/src/services/fuel/FuelService.cpp) | 7 | Fuel level + low-fuel trigger |
| TripLoggerService | [TripLoggerService.h](app/src/services/trip/TripLoggerService.h) | [TripLoggerService.cpp](app/src/services/trip/TripLoggerService.cpp) | 15 | GPX writer per ignition cycle + trip A/B meters |
| ParkingService | [ParkingService.h](app/src/services/parking/ParkingService.h) | [ParkingService.cpp](app/src/services/parking/ParkingService.cpp) | 4 | Last-parked GPS coord; navigate-to-car |
| StatusBridge | [StatusBridge.h](app/src/ui/bridge/StatusBridge.h) | [StatusBridge.cpp](app/src/ui/bridge/StatusBridge.cpp) | 21 | Cross-screen coordination + AVM activation |
| MapLibreItem | [MapLibreItem.h](app/src/ui/map/MapLibreItem.h) | [MapLibreItem.cpp](app/src/ui/map/MapLibreItem.cpp) | 8 | Phase 3 stub; EGL TODO |

**Total: 254 Q_PROPERTYs across 13 services; ~20,000+ LOC across app/src.**

---

## QML Screens (`app/src/qml/`)

### Upper screen (NavigationView 800×480)
| File | Role |
|---|---|
| [NavigationView.qml](app/src/qml/screens/NavigationView.qml) | Turn HUD, cruise bubble, rerouting banner; sub-view stack drives DestinationSearch + RoutePreview |
| [DestinationSearch.qml](app/src/qml/screens/DestinationSearch.qml) | Upper-screen destination entry: search bar + category chips + recents |
| [RoutePreview.qml](app/src/qml/screens/RoutePreview.qml) | Route summary (travel/distance/ETA) + type pills + avoid toggles |
| [RearCameraView.qml](app/src/qml/screens/RearCameraView.qml) | Dynamic Loader; parking guides |
| [IncomingCallView.qml](app/src/qml/screens/IncomingCallView.qml) | Call overlay (z:100) |
| [VoiceCommandView.qml](app/src/qml/screens/VoiceCommandView.qml) | Voice activation overlay |

### Lower screen (ControlHubView 800×420 — 5-tab nav)
| File | Tab | Role |
|---|---|---|
| [ControlHubView.qml](app/src/qml/screens/ControlHubView.qml) | — | 5-tab shell |
| [NavCompanionView.qml](app/src/qml/screens/NavCompanionView.qml) | Home | Turn-by-turn companion |
| [AudioView.qml](app/src/qml/screens/AudioView.qml) | Audio | BT/FM/AM/SXM/AUX |
| [PhoneView.qml](app/src/qml/screens/PhoneView.qml) | Phone | DTMF + persistent 88px panel |
| [ClimateView.qml](app/src/qml/screens/ClimateView.qml) | Climate | Dual zones + fan + modes |
| [VehicleStatusView.qml](app/src/qml/screens/VehicleStatusView.qml) | Vehicle | Drive mode + doors + fuel/coolant/RPM |
| [VehicleSettingsView.qml](app/src/qml/screens/VehicleSettingsView.qml) | — | BCM Work Support unlocks; DTCs; maintenance routine resets. Reached from Settings → Vehicle Unlocks. |

### Reachable sub-screens
| File | Role |
|---|---|
| [SettingsView.qml](app/src/qml/screens/SettingsView.qml) | Settings — bound to SettingsService |
| [ProfileView.qml](app/src/qml/screens/ProfileView.qml) | Profile picker |
| [InfoView.qml](app/src/qml/screens/InfoView.qml) | FW / CAN / GPS / uptime |

### Components (`app/src/qml/components/`)
TurnArrow · SpeedWidget · FanControl · TempZone · TabBar · StatusBar · WelcomeOverlay · CameraFeed (isolated QtMultimedia) · **ContactsModel** (shared contact list, used by PhoneView + IncomingCallView) · **LaneGuidance** (upper-screen lane arrows) · **JunctionView** (interchange overlay) · **AvmOverlay** (4-camera scaffold with sonar arcs) · **MiniGauge** (VR30 telemetry gauges) · **GPad** (G-meter circular pad) · **QmlKeyboard** (touchscreen QWERTY + numeric/symbols slide-up; replaces missing Qt VirtualKeyboard on i386)

**Total: 30 QML files (28 + Main.qml registered in CMake; RearCameraView + CameraFeed loaded dynamically via Loader to fail gracefully if QtMultimedia absent).**

---

## Scripts (`scripts/`)

### Build
- [build-app.sh](scripts/build-app.sh) — compile q60nav i386 inside Docker
- [build-app-worktree.sh](scripts/build-app-worktree.sh) — build from git worktree, reusing main repo's heavy outputs (Qt6, MapLibre, sysroot)
- [package-rootfs-worktree.sh](scripts/package-rootfs-worktree.sh) — build rootfs image from worktree, overlaying onto main repo's rootfs base
- [integrity-check.sh](scripts/integrity-check.sh) — pre-flash audit: ELF arch verification + rootfs structure
- [build-tiles.sh](scripts/build-tiles.sh) — Valhalla routing tiles
- [build-map-tiles.sh](scripts/build-map-tiles.sh) — MapLibre vector tiles (tilemaker)
- [build-geocoder-db.sh](scripts/build-geocoder-db.sh) — SQLite FTS5+rtree geocoder DB
- [build-geocoder-server.sh](scripts/build-geocoder-server.sh) — geocoder-server i386 binary
- [build-valhalla-host.sh](scripts/build-valhalla-host.sh) — host amd64 Valhalla
- [build-photon-db.sh](scripts/build-photon-db.sh) — *legacy*, superseded by geocoder
- [download-map-assets.sh](scripts/download-map-assets.sh)
- [download-photon.sh](scripts/download-photon.sh) — *legacy*
- [install-jre-rootfs.sh](scripts/install-jre-rootfs.sh) — *legacy*, JRE no longer needed
- [install-mesa-rootfs.sh](scripts/install-mesa-rootfs.sh)

### Deploy
- [deploy-phase1-sd.sh](scripts/deploy-phase1-sd.sh) — **Phase 1 SD card deploy** (one command: writes rootfs + kernel + elilo.conf). Usage: `sudo bash scripts/deploy-phase1-sd.sh -y disk4`
- [verify-slotb.sh](scripts/verify-slotb.sh) — verify Slot B ext4 label and rootfs integrity before booting
- [package-rootfs.sh](scripts/package-rootfs.sh) — build 3GB ext4 image
- [deploy-to-image.sh](scripts/deploy-to-image.sh) — write kernel + rootfs to eMMC
- [deploy-tiles.sh](scripts/deploy-tiles.sh) — push tiles to mounted partition
- [restore-logan1.sh](scripts/restore-logan1.sh) — emergency factory restore (~10s)
- [run-simulator.sh](scripts/run-simulator.sh) — Docker x86 desktop simulator (VNC client, port 5900)
- [run-simulator-web.sh](scripts/run-simulator-web.sh) — Browser-accessible simulator (noVNC over WebSocket, default port 8080). Full mouse + keyboard interactivity. Pass `--port N` to override.

### Dependencies (`deps/`)
- [build-qt6-host.sh](deps/build-qt6-host.sh) — host amd64 Qt6 (QT_HOST_PATH)
- [build-qt6-i386.sh](deps/build-qt6-i386.sh) — i386 cross Qt6
- [build-maplibre-i386.sh](deps/build-maplibre-i386.sh) — MapLibre i386 static
- [build-valhalla-i386.sh](deps/build-valhalla-i386.sh) — Valhalla i386
- [qt6-i386-toolchain.cmake](deps/qt6-i386-toolchain.cmake)
- [maplibre-compat/optional.hpp](deps/maplibre-compat/optional.hpp) — C++17 shim

---

## On-device files (`rootfs/`)

### Init system
- [inittab](rootfs/etc/inittab) — runlevel 5, watchdog respawn
- [init.d/rcS](rootfs/etc/init.d/rcS) — **Phase 1 diagnostic init**: mounts /boot (FAT32), probes gma500, writes gate result to `/boot/Q60_DISPLAY_GATE.TXT`, restores `default=logan1`, halts
- [S10-gpsd](rootfs/etc/init.d/S10-gpsd), [S20-valhalla](rootfs/etc/init.d/S20-valhalla), [S25-geocoder](rootfs/etc/init.d/S25-geocoder), [S30-weston](rootfs/etc/init.d/S30-weston), [S50-q60nav](rootfs/etc/init.d/S50-q60nav) — Phase 2+ production services
- [fstab](rootfs/etc/fstab) — `/boot rw` (counter writes), p9 → `/data`

### App support (`/opt/nav/`)
- [start.sh](rootfs/opt/nav/start.sh) — boot counter + service starter
- [detect-display.sh](rootfs/opt/nav/detect-display.sh) — DRM sysfs probe
- [gen-weston-ini.sh](rootfs/opt/nav/gen-weston-ini.sh) — dynamic compositor config
- [watchdog-pet.sh](rootfs/opt/nav/watchdog-pet.sh) — iTCO pet every 20s
- [bin/tcu-detect.sh](rootfs/opt/nav/bin/tcu-detect.sh) — first-boot LTE/Wi-Fi identification
- [bin/modem-connect.sh](rootfs/opt/nav/bin/modem-connect.sh)
- [config/config.json](rootfs/opt/nav/config/config.json) — app default config
- [style/q60-dark.json](rootfs/opt/nav/style/q60-dark.json) — MapLibre style

### Services
- [valhalla/valhalla.json](rootfs/opt/valhalla/valhalla.json), [valhalla-httpd.c](rootfs/opt/valhalla/valhalla-httpd.c)
- [geocoder/geocoder.c](rootfs/opt/geocoder/geocoder.c)
- [udev/rules.d/70-can.rules](rootfs/etc/udev/rules.d/70-can.rules), [71-touchscreen.rules](rootfs/etc/udev/rules.d/71-touchscreen.rules), [99-lte-modem.rules](rootfs/etc/udev/rules.d/99-lte-modem.rules)
- [systemd/system/tcu-detect.service](rootfs/etc/systemd/system/tcu-detect.service), [modem-connect.service](rootfs/etc/systemd/system/modem-connect.service), [modem-reconnect.service](rootfs/etc/systemd/system/modem-reconnect.service)

---

## CAN ID coverage (read paths)

**Confirmed (DBC / community-cross-referenced):** 0x002 steering, 0x185 torque, 0x1F9 RPM, 0x280 speed, 0x284/285 wheel-spd, 0x354 brake, 0x421 gear, 0x510 outside temp, 0x54A/B HVAC status, 0x5C5 cluster, 0x60D BCM body.

**Q50_LIKELY (parsed, not validated):** 0x292 ignition, 0x358 doors, 0x35D wipers, 0x385 TPMS, 0x551 cruise+coolant, 0x54C oil life, 0x554 fuel econ, 0x2DC drive mode cmd, 0x1CA ATTESA, 0x625 BCM ext.

**Unverified (placeholders):** 0x35B key slot, 0x266 drive mode broadcast, 0x47D ADAS write, 0x3B3 Bose wake, 0xFFFF seat heat write.

**Q_PROPERTY surface for QML:** 220+ across all services (full bind to UI).

---

## R1 Overlay (`app/src/r1_overlay/`)

Active hardware research track — paints arbitrary content onto EMGD Sprite C overlay
via `/dev/v2gbridge` without disrupting factory nav.

| File | Role |
|------|------|
| [q60nav_v4l2_test.c](app/src/r1_overlay/q60nav_v4l2_test.c) | Main test binary — phases P0 (survey) through P6 (DRM+V2G with pixel write). Deployed to DCU at each boot. |
| [deploy-thorough.sh](app/src/r1_overlay/deploy-thorough.sh) | Full redeploy: build binary → debugfs write to Slot A → hook injection. Uses Slot B as clean base. Requires `sudo`. |
| [build-r1.sh](app/src/r1_overlay/build-r1.sh) | Docker i386 alpine build script for sprite_c and probe binaries |
| [deploy-probe.sh](app/src/r1_overlay/deploy-probe.sh) | Lighter probe-only deploy |
| [deploy-r1.sh](app/src/r1_overlay/deploy-r1.sh) | R1 production deploy (future — once overlay is working) |
| [q60nav_sprite_c.c](app/src/r1_overlay/q60nav_sprite_c.c) | Future production R1 overlay client skeleton |
| [q60nav_r1_probe.c](app/src/r1_overlay/q60nav_r1_probe.c) | Lightweight hardware capability probe |

**Build output:** `/tmp/q60-overnight/r1-build/q60nav_v4l2_test.static`  
**Logs after boot:** `/Volumes/boot/Q60_R1_V4L2.LOG`, `Q60_KMSG.LOG`, `Q60_HOOK_RAN.TXT`

---

## Emulator (`emu/`)

Docker-based factory daemon emulator for iteration without hardware. See [emu/README.md](emu/README.md).
Runs i386 factory binaries under QEMU + LD_PRELOAD shim that intercepts `/dev/v2gbridge`,
`/dev/dri/card0`, `/dev/video0` ioctls and logs them.

---

## Configs
- [configs/q60_kernel.config](configs/q60_kernel.config) — full kernel .config
- [configs/q60_atom_defconfig](configs/q60_atom_defconfig) — base defconfig

## Documentation

### Always-current (read these first)
- [CLAUDE.md](CLAUDE.md) — session instructions; deploy cycle, current status, hardware facts
- [ONBOARDING.md](ONBOARDING.md) — live research log: 12 R1 findings + Phase 1 pivot + Finding 13 (first boot RCA)
- [STATUS.md](STATUS.md) — build state + Phase 1 status
- [README.md](README.md) — project overview, UI, architecture
- [BACKLOG.md](BACKLOG.md) — open items

### Hardware research
- [docs/v2gbridge-hardware-findings-2026-05-17.md](docs/v2gbridge-hardware-findings-2026-05-17.md) — full V2G/overlay test findings
- [docs/plan-r1-v2gbridge-research.md](docs/plan-r1-v2gbridge-research.md) — V2G bridge architecture
- [docs/plan-r1-sprite-c-design.md](docs/plan-r1-sprite-c-design.md) — Sprite C overlay design
- [docs/r1-privilege-findings.md](docs/r1-privilege-findings.md) — DRM ioctl permission model
- [docs/hardware-ground-truth-2026-05-16.md](docs/hardware-ground-truth-2026-05-16.md) — runtime-captured hardware facts
- [docs/factory-version-baseline.md](docs/factory-version-baseline.md) — factory version table (from diag menu)
- [docs/oem-boot-security.md](docs/oem-boot-security.md) — boot security model
- [docs/oem-hidden-functions.md](docs/oem-hidden-functions.md) — factory hidden menu catalog

### Architecture
- [docs/lower-screen-architecture.md](docs/lower-screen-architecture.md) — lower screen / Integral Switch
- [docs/powervr-sgx-driver-analysis.md](docs/powervr-sgx-driver-analysis.md) — PowerVR SGX driver verdict (don't build)
- [docs/boot-safety.md](docs/boot-safety.md) — elilo fallback analysis
- [docs/kernel-config-required-fixes.md](docs/kernel-config-required-fixes.md) — required kernel config
- [docs/feature-parity-audit.md](docs/feature-parity-audit.md) — factory feature gap analysis

### UI
- [docs/mockup/index.html](docs/mockup/index.html) — interactive HTML prototype

### Other
- [docs/hardware-day-capture-checklist.md](docs/hardware-day-capture-checklist.md) — J2534 capture session tasks
- [docs/sd-replacement-deep-dive.md](docs/sd-replacement-deep-dive.md) — SD card replacement research
- [docs/dcu-sd-replacement-research.md](docs/dcu-sd-replacement-research.md) — DCU SD replacement

### Archive (stale, superseded, or one-time)
`docs/archive/` — plan-b docs, boot-failure RCA, diagnostic rcS design, initial hardware prep notes.
Load on demand only.
