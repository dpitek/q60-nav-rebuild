# Q60 Nav Rebuild — Build Status
Last updated: 2026-05-11

---

## ✅ Completed

### Infrastructure
- [x] Working image: `/Users/dpitek/q60-nav-rebuild.img` (7.2GB Q50 base)
- [x] Docker toolchain: `q60-toolchain` (Ubuntu 22.04 amd64, GCC 11.4, `-m32 bonnell`)
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
- [x] `AudioService` — BlueZ D-Bus AVRCP, DENSO proxy IPC, ALSA volume
- [x] `SearchService` — Valhalla geocode + reverse geocode
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
- [x] `S20-valhalla` — Valhalla HTTP service on port 8002
- [x] `S30-weston` — Weston Wayland compositor (DRM + fbdev fallback)
- [x] `S50-q60nav` — app launch via start.sh
- [x] `weston.ini` — dual LVDS: LVDS-1 800×480 + LVDS-2 800×420
- [x] `valhalla.json` — device config, tiles at /opt/valhalla/tiles

### Map Data Pipeline
- [x] NC OSM PBF: `/tmp/north-carolina-latest.osm.pbf` (401MB, 2026-05-10, 55.3M nodes)
- [x] Valhalla config: `output/valhalla-config.json`
- [x] Scripts: `build-tiles.sh`, `deploy-tiles.sh`, `build-valhalla-host.sh`

### Build + Deploy Scripts
- [x] `scripts/build-app.sh` — cross-compile q60nav for i686 inside Docker
- [x] `scripts/deploy-to-image.sh` — write kernel to FAT32, flip elilo.conf for test
- [x] `scripts/restore-logan1.sh` — emergency recovery from Mac
- [x] `scripts/package-rootfs.sh` — build 1GB ext4 rootfs image from rootfs/

---

## 🔄 In Progress (Docker builds running)

| Build | Container | ETA |
|---|---|---|
| Qt 6.6.3 i386 from source | `beautiful_lichterman` | ~60-120 min total |
| Valhalla host tools (for tile build) | `q60-host-build` | ~20-30 min |

---

## ⏳ Blocked On

| Item | Blocker |
|---|---|
| `q60nav` binary | Qt 6.6 i386 must complete first |
| MapLibre Qt wrapper (`libqmaplibregl.so`) | Qt 6.6 i386 must complete first |
| NC routing tiles | Valhalla host build must complete first |
| Valhalla i386 runtime | GEOS built + cmake re-run (script ready, needs container run) |
| Phase 3: Full NavigationView map | MapLibre Qt wrapper + tiles |

---

## 📋 Remaining Work

- [ ] Valhalla i386 cross-compile (GEOS now in script as step 7a — re-run build)
- [ ] Build NC Valhalla routing tiles (~20-40 min after host tools ready)
- [ ] Qt 6.6 i386 → MapLibre Qt wrapper (`libqmaplibregl.so`)
- [ ] Phase 3: Replace NavigationView map placeholder with MapLibre QQuickItem
- [ ] J2534 CAN sniff — replace all placeholder CAN IDs in VehicleService.h
- [ ] GPS UART probe — confirm which ttyS* the Q60 GPS is on
- [ ] Physical boot test on device hardware
- [ ] Tune Weston DRM output to actual LVDS connector names (verify LVDS-1/LVDS-2)
- [ ] SXM retry: C001T003L000V000.psv (504 error from previous session)

---

## ⚠️ CAN IDs — PLACEHOLDER ONLY

All `CAN_*` constants in `VehicleService.h` are estimates based on community
research for similar Infiniti/Nissan platforms. **DO NOT send write frames to
the car until IDs are verified via J2534 capture.**

---

## Key Paths

| Path | Contents |
|---|---|
| `output/bzImage-4.19-q60` | Compiled kernel (4.2MB, ELF 32-bit i386) |
| `output/maplibre-i386/lib/` | MapLibre core static lib (20MB) |
| `output/qt6-i386/` | Qt 6.6 i386 (building…) |
| `output/valhalla-i386/` | Valhalla i386 runtime (re-run needed) |
| `output/valhalla-tiles/` | NC routing tiles (building…) |
| `rootfs/` | Slot B rootfs skeleton (ready to package) |
| `/Volumes/boot 1/elilo.conf` | Live boot config — q60nav entry added |
| `/tmp/north-carolina-latest.osm.pbf` | NC OSM source (401MB) |
