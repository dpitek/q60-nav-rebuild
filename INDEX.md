# Q60 Nav — Code Index
Generated: 2026-05-13 (post backlog-execution sprint)

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
- [package-rootfs.sh](scripts/package-rootfs.sh) — build 3GB ext4 image
- [deploy-to-image.sh](scripts/deploy-to-image.sh) — write kernel + rootfs to eMMC
- [deploy-tiles.sh](scripts/deploy-tiles.sh) — push tiles to mounted partition
- [restore-logan1.sh](scripts/restore-logan1.sh) — emergency factory restore (~10s)
- [run-simulator.sh](scripts/run-simulator.sh) — Docker x86 desktop simulator

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
- [init.d/rcS](rootfs/etc/init.d/rcS), [S10-gpsd](rootfs/etc/init.d/S10-gpsd), [S20-valhalla](rootfs/etc/init.d/S20-valhalla), [S25-geocoder](rootfs/etc/init.d/S25-geocoder), [S30-weston](rootfs/etc/init.d/S30-weston), [S50-q60nav](rootfs/etc/init.d/S50-q60nav)
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

## Configs
- [configs/q60_kernel.config](configs/q60_kernel.config) — full kernel .config
- [configs/q60_atom_defconfig](configs/q60_atom_defconfig) — base defconfig

## Documentation
- [README.md](README.md) — top-level
- [STATUS.md](STATUS.md) — build state
- [BACKLOG.md](BACKLOG.md) — post-boot items
- [docs/boot-safety.md](docs/boot-safety.md) — elilo fallback analysis
- [docs/hardware-prep.md](docs/hardware-prep.md) — DCU pull + flash procedure
- [docs/feature-parity-audit.md](docs/feature-parity-audit.md) — factory feature gap analysis
- [docs/mockup/index.html](docs/mockup/index.html) — interactive HTML prototype
