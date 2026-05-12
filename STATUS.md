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
- [x] `VehicleService` — SocketCAN (can0/can1/can2), CAN frame parsing, full HVAC write, Bose wake
- [x] `NavigationService` — GPSD TCP socket, Valhalla HTTP client, route parsing, rerouting
- [x] `AudioService` — BlueZ D-Bus AVRCP (guarded with `HAVE_QT_DBUS`), DENSO proxy IPC, ALSA volume
- [x] `SearchService` — offline geocoding on port 4000 (Nominatim/Photon, graceful if absent)
- [x] `StatusBridge` — full signal wiring, clock, cross-screen coordination

### QML UI (all screens fully implemented)
- [x] `NavigationView` — turn HUD, TurnArrow, approaching-turn pulse, SpeedWidget, reverse overlay
- [x] `ControlHubView` — TabBar component, auto-switch on call/reverse, live status bar
- [x] `ClimateView` — dual temp zones, fan bar, AC/recirc/mode, seat heat
- [x] `AudioView` — BT/FM/AM/SXM/AUX, media controls, volume slider
- [x] `NavCompanionView` — ft/mi countdown, ETA, remaining, speed vs limit, rerouting banner
- [x] `PhoneView` — active call display, mute/end/keypad, DTMF overlay, call timer
- [x] Components: `TurnArrow`, `SpeedWidget`, `FanControl`, `TempZone`, `TabBar`

### Device Init System
- [x] `inittab` — SysV runlevel 5, watchdog respawn
- [x] `rcS` — mount vfs, udev, kernel modules
- [x] `S10-gpsd` — GPSD on ttyS0
- [x] `S20-valhalla` — valhalla-httpd wrapper + valhalla_service on port 8002
- [x] `S30-weston` — Weston Wayland compositor (DRM + fbdev fallback)
- [x] `S50-q60nav` — app launch via start.sh
- [x] `weston.ini` — dual LVDS: LVDS-1 800×480 + LVDS-2 800×420
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
- [x] `scripts/deploy-to-image.sh` — write kernel to FAT32, flip elilo.conf for test
- [x] `scripts/restore-logan1.sh` — emergency recovery from Mac
- [x] `scripts/package-rootfs.sh` — build 1GB ext4 rootfs image from rootfs/

---

## 🔄 In Progress

| Item | Status |
|---|---|
| Vector tiles (`.mbtiles`) | ⏳ Not yet built — run `./scripts/build-map-tiles.sh` |

---

## ⏳ Remaining Work (ordered)

1. **Vector tiles**: `./scripts/build-map-tiles.sh` — tilemaker Docker, ~30-60 min
2. **Phase 3**: Build `libqmaplibregl.so` Qt/MapLibre GL wrapper
3. **Phase 3**: Replace `NavigationView` Canvas placeholder with `MapLibreItem` (enable `-DWITH_MAPLIBRE=ON`)
4. **[hardware]** J2534 CAN sniff — verify all `CAN_*` IDs in `VehicleService.h`
5. **[hardware]** GPS UART probe — confirm ttyS device for GPSD
6. **[hardware]** Verify Weston LVDS connector names (LVDS-1/LVDS-2)
7. **[hardware]** Physical boot test — `deploy-to-image.sh --test`
8. **[future]** Offline geocoder for SearchService (Nominatim-lite or Photon on port 4000)

---

## ⚠️ CAN IDs — PLACEHOLDER ONLY

All `CAN_*` constants in `VehicleService.h` are estimates based on community
research for similar Infiniti/Nissan platforms. **DO NOT send write frames to
the car until IDs are verified via J2534 capture.**

---

## Key Architectural Notes

| Issue | Resolution |
|---|---|
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
