# Plan B — Execution Plan (synthesized, Wayland + ivi-shell)

**Decision committed:** 2026-05-16, after 24+ hours of fighting elilo + Linux 4.19 boot on Clarion QY5092 + confirming via live in-factory probe that factory uses Intel EMGD (proprietary) for display + duplicate-card Variant W test still failing to boot.

**Strategy in one line:** keep factory kernel + factory display + factory drivers + factory backend daemons; **replace only `emgdhmid.service`** with our own `weston-q60.service` + `q60nav.service` pair, where q60nav is a Qt 5 Wayland client speaking ivi-shell to a Weston compositor we control.

Folds in research from three parallel agents: Qt 5.15 build/compat (`plan-b-qt515-pivot.md`), Mesa+IPC (`plan-b-mesa-and-denso-ipc.md`), DENSO userland (`plan-b-userland-architecture.md`). The userland agent's findings forced a significant architectural revision: original sketch assumed `/dev/fb0` linuxfb paint; in reality EMGD owns `/dev/dri/card0` exclusively and the factory IS already a Wayland stack (Weston + ivi-shell, the protocol DENSO co-authored with BMW in 2013).

---

## Architectural diff vs Plan A

| Layer | Plan A (abandoned) | Plan B (revised) |
|---|---|---|
| Boot loader | elilo (replace) | **factory elilo, unchanged** |
| Kernel | Linux 4.19 i386 custom build | **factory Linux 2.6.37, unchanged** |
| DRM / display | gma500 + Mesa swrast (unverified) | **factory EMGD + v2g, unchanged** (EMGD owns /dev/dri/card0) |
| Mesa | swrast / OSMesa fallback | **none** — q60nav uses Qt Quick software backend, ships wl_shm buffers to Weston |
| Compositor | none (direct framebuffer) | **our own Weston** with ivi-shell.so + hmi-controller.so (mirroring `emgdhmid.service`'s config) |
| Audio chain | ALSA via Bose amp wake | **factory ml7213ioh I2S + Bose, unchanged**; route via DENSO `sound.out` IPC |
| Bluetooth | BlueZ 5 AVRCP | **factory BlueZ, unchanged** |
| CAN bus | SocketCAN can0/can1/can2 | **DENSO IPC named pipes + AMB on D-Bus**; raw SocketCAN fallback only if vcan.out rejects raw frames |
| GPS | gpsd on `/dev/ttyPCH0` | **AMB D-Bus** (`org.automotive.Location`) or direct `ttyPCH0` if not exposed |
| Vehicle data | direct CAN parsing | **AMB D-Bus** (`org.automotive.<DataType>`) |
| systemd init | Our minimal stack | **factory systemd, unchanged** |
| UI app launcher | New q60nav.service | **`systemctl disable emgdhmid.service`** + add `weston-q60.service` + `q60nav.service` |
| UI framework | Qt 6.6.3 i386 | **Qt 5.15.18 i386** (last open-source patch, Oct 2025) |
| QPA platform | linuxfb + Mesa swrast | **wayland + ivi-shell** (Qt5: `QT_QPA_PLATFORM=wayland`, `QT_WAYLAND_SHELL_INTEGRATION=ivi-shell`) |
| Quick backend | OpenGL scene-graph | **`QT_QUICK_BACKEND=software`** — QPainter raster path into wl_shm; Weston composites with EMGD GLES |
| Map rendering | MapLibre GL Native via headless EGL | MapLibre GL Native, software backend; output into Qt's raster scene-graph |
| Rear camera | Qt camera item via Qt Multimedia | **factory v2g sprite plane**, kernel-side; q60nav doesn't render the camera at all |
| Routing | Valhalla 3.4 | unchanged |
| Geocoder | SQLite FTS5 C99 | unchanged |
| Rootfs delivery | dd entire ext4 image to p3 | **debugfs-injected files into factory Slot A** (proven 2026-05-16) |
| Boot variants | logan1 / q60nav | **logan1 only** — factory boot, our app on top |
| eMMC modifications | replace p3 + FAT32 boot | **minimal Slot A overlay only; p3–p9 untouched** |

---

## Why this is the right pivot (in five facts)

1. **`emgdhmid.service` = "EMGD HMI Daemon" = DENSO's productized `weston --shell=ivi-shell.so --modules=hmi-controller.so`.** Not Googleable because it's DENSO-internal naming. The ivi-hmi-controller protocol was authored by DENSO + BMW Car IT in 2013 — Q60 ships exactly that 2013 design.
2. **EMGD owns `/dev/dri/card0` exclusively** — no Mesa, no `/dev/fb0` direct-paint path. Our integration must speak Wayland to a Weston that runs against EMGD's proprietary EGL/GLES blobs.
3. **Q60nav doesn't render with GL**: Qt Quick software backend produces raster surfaces; Wayland transports them as `wl_shm` (shared memory) buffers; Weston composites them with EMGD on the GPU. We never link Mesa or GLES.
4. **Rear-camera overlay is a v2g sprite plane managed kernel-side** — not a Weston surface. q60nav doesn't render the camera; it just listens for reverse-gear via AMB D-Bus and the kernel composites the camera sprite over our UI.
5. **DENSO backend daemons (sxmcgs/radiofc/sound/vcan) speak D-Bus over `navi0`, plus `/tmp/*.cmd` named pipes for short commands.** AMB (`org.automotive.*`) is the most likely vehicle-data broker. Qt has first-class D-Bus support — reuse, don't rewrite.

---

## What stays from the existing project

- `app/src/services/` — all 13 services (28k LOC C++)
- `app/src/qml/` — all 32 QML files with mechanical Qt 5.15 syntax adjustments
- `app/src/ui/` — bridge layer; MapLibre item rebuilt against Qt 5 (small `geometryChange` rename)
- Valhalla routing tiles + build pipeline
- MapLibre vector tiles + build pipeline
- Geocoder (C99 + SQLite)
- All maps + tiles already built
- All documentation, mockups, diag-menu captures
- Hardware ground-truth findings, BCM/UDS research

## Code we retire

- `output/bzImage-4.19-q60` — kernel we never got to boot
- `output/q60nav-rootfs.img` — broken
- `rootfs/etc/init.d/*` — factory init replaces this
- `rootfs/opt/nav/start.sh` boot-counter logic
- `deploy-to-image.sh` — replaced by debugfs deploy
- `configs/q60_kernel.config` — moot
- `scripts/restore-logan1.sh` — irrelevant (we never modify Slot A bootability)
- `deps/build-qt6-i386.sh` + `deps/build-qt6-host.sh` — replaced by single-pass Qt 5
- `scripts/install-mesa-rootfs.sh` — Mesa not used at all
- `deps/build-maplibre-i386.sh` Qt 6 deps — rebuild MapLibre against Qt 5
- `CameraFeed.qml` rendering pipeline — the camera is a hardware sprite plane; this surface stays but never paints anything

## Code we add (staged in `/tmp/q60-overnight/plan-B-staging/`)

- `build-qt515-i386.sh` — Qt 5.15.18 cross-build, qpa=wayland, no Mesa, qtwayland enabled
- `qml-port-qt6-to-qt5.sh` — mechanical sed for versioned imports + CameraFeed Qt 6→5 multimedia fixes
- `deploy-to-slot-a.sh` — debugfs injection of q60nav binary + libs + Wayland plugins + weston.ini + weston-q60.service + q60nav.service
- `rc.local.denso-ipc-capture` — five-minute factory probe: pipe inventory, strace each daemon, capture `emgdhmid.service` text, weston.ini, `ldd` factory HMI, `dbus-send ListNames`, `/proc/<emgdhmid-pid>/environ`

---

## The work, broken down

### 1. Qt 5.15.18 i386 build pipeline — staged

**Source:** `qt-everywhere-opensource-src-5.15.18.tar.xz` (Qt official, Oct 31 2025, last open-source patch). KDE Qt 5 patch collection kept as optional CVE overlay.

**Why Qt 5 is *simpler* than Qt 6 here:**
- Single-pass `configure → make → make install`. No host-tools precursor.
- Existing `linux-g++-32` mkspec emits `-m32` natively — no `-march=bonnell` SIGBUS risk.
- QML interpreted at runtime — no qmlcachegen, no `NO_CACHEGEN`, no `QtObject` workaround.

**Build target modules:** qtbase, qtquickcontrols2, qtlocation (provides Qt5::Positioning), qtmultimedia, qtserialbus, **qtwayland** (required — was skipped in earlier sketch).

**Build flags:**
```
-no-opengl -no-egl -no-eglfs -no-feature-vulkan
-qpa wayland -linuxfb -no-xcb -no-directfb
-dbus-linked     # AudioService BlueZ AVRCP + AMB
-gstreamer 1.0
-platform linux-g++-32
```

**Resources:** ~7 GB build dir, ~500 MB install prefix, **45–60 min wall time** (qtwayland adds ~15 min vs the linuxfb-only sketch).

### 2. Codebase Qt 6 → Qt 5.15 port — ~1 hour mechanical

9 files affected. See `/tmp/q60-overnight/plan-b-qt515-pivot.md` §2 for line numbers.

| Concern | Effort |
|---|---|
| Versioned QML imports (44 lines, 32 files) | 5 min (one sed) |
| `function on…Changed` | 0 — already Qt 5.15-compatible |
| `QML_NAMED_ELEMENT(MapLibreMap)` → `qmlRegisterType<MapLibreItem>("Q60Nav",1,0,"MapLibreMap")` in main.cpp | 10 min |
| `qt6_add_qml_module` → generated `.qrc` | 30 min |
| `geometryChange` → `geometryChanged` | 5 min |
| `QStringConverter::Utf8` → `setCodec("UTF-8")` + `#include <QTextCodec>` | 2 min |
| `MediaPlayer onErrorOccurred` → `onError`, `VideoOutput { player: }` → `source:` | 5 min |
| `find_package(Qt6 …)` → `find_package(Qt5 5.15 …)` | 5 min |

### 3. Userland integration — three actions

**(a) Disable factory UI launcher** (single unit):
```
systemctl disable emgdhmid.service
```
All other DENSO daemons (sxmcgs.out, radiofc.out, sound.out, vcan.out, sud-change-elilo, android-mount, etc.) stay running untouched.

**(b) Install `weston-q60.service`** — runs Weston with same ivi-shell + hmi-controller config that `emgdhmid.service` was running, minus the autolaunch of the factory upper-UI app. Uses factory's existing `/etc/modprobe.d/emgd.conf` configid/dc settings.

**(c) Install `q60nav.service`** — runs our Qt 5 app with:
```
QT_QPA_PLATFORM=wayland
QT_WAYLAND_SHELL_INTEGRATION=ivi-shell
QT_IVI_SURFACE_ID=<factory_id>            # captured by IPC probe
QT_QUICK_BACKEND=software
QT_PLUGIN_PATH=/opt/q60nav/plugins
LD_LIBRARY_PATH=/opt/q60nav/lib
```

The surface ID is the **single integration risk** — q60nav must register with the same `ivi_id` the factory app used, so any DENSO debug surface / camera-overlay coordination still finds its peer. The IPC capture probe extracts this value before first deploy.

Deploy script staged at: `/tmp/q60-overnight/plan-B-staging/deploy-to-slot-a.sh`

### 4. CAN + vehicle data — D-Bus first, IPC second

DENSO userland agent confirms vehicle data flows through AMB (`org.automotive.<DataType>`) on the system D-Bus. Path:

1. **Phase 1 — Discover.** IPC capture probe runs `dbus-send ListNames` to confirm AMB presence + enumerate object paths.
2. **Phase 2 — Refactor VehicleService.** Replace SocketCAN raw socket with `QDBusConnection::systemBus()` calls to `org.automotive.*` properties. Keep public API byte-identical so QML layer is unchanged.
3. **Phase 3 — Fallback.** If AMB doesn't expose what we need (e.g., specific HVAC commands), write to `/tmp/sound.cmd`, `/tmp/vcan.cmd` named pipes for those operations. ButtonLogger functionality stays available via the same IPC.

Worst case: 1–2 days of D-Bus introspection + targeted refactor.

### 5. Rootfs delivery — debugfs into Slot A

Proven 2026-05-16: `e2fsprogs` debugfs injects files into Slot A's ext4 without mounting. Runs under Docker on macOS. No `dd`, no Mac garbage, no Slot A bootability changes.

Total deployment size: ~80–120 MB (Qt 5 install prefix ~500 MB; ship only linked-against subset). Fits easily in Slot A's free space.

### 6. Test cycle

Plan A: change kernel/rootfs → dd 7 GB → boot → black screen → guess again. ~10 min, near-zero signal.

Plan B: change app code → cross-compile (~30 sec) → `debugfs -w` (~5 sec) → boot SD in DCU → factory boots → weston-q60 starts → q60nav appears as ivi-shell client. **~2 min per iteration, full visual feedback.**

---

## Order of operations (when Doug says "execute")

**Phase 0 — pre-flight (can start now, before any boot test):**
- [x] Plan B doc (this file)
- [x] Stage `build-qt515-i386.sh` (Wayland-enabled)
- [x] Stage `qml-port-qt6-to-qt5.sh`
- [x] Stage `deploy-to-slot-a.sh` (Wayland + ivi-shell unit pair)
- [x] Stage `rc.local.denso-ipc-capture` (extended to capture emgdhmid, weston.ini, DBus topology, surface ID)
- [ ] Copy staged scripts into repo (`deps/`, `scripts/`, `rootfs/probes/`)

**Phase 1 — resolve duplicate SD card issue (separate track):**
- Doug's pending: try md5sum diff against OEM, or try a different SD brand (SanDisk Industrial 16 GB), or proceed on OEM card directly with debugfs-only writes (non-destructive to factory bootability).

**Phase 2 — capture the five missing variables from factory:**
- [ ] Inject `rc.local.denso-ipc-capture` via debugfs into a boot SD
- [ ] Boot, exercise factory UI for 5 min, capture
- [ ] Extract:
  - factory `ivi_id` (surface ID) — drives `QT_IVI_SURFACE_ID`
  - factory `emgdhmid.service` ExecStart — informs our `weston-q60.service`
  - factory `weston.ini` location + contents — informs our `/etc/q60/weston.ini`
  - factory HMI binary `ldd` — confirms which EMGD `.so` we need on LD_LIBRARY_PATH
  - DBus `ListNames` — confirms AMB presence + object paths

**Phase 3 — Qt 5.15 build + port (parallel to Phase 2):**
- [ ] Pull `qt-everywhere-opensource-src-5.15.18.tar.xz` (634 MB)
- [ ] Kick off `build-qt515-i386.sh` in Docker (~50 min)
- [ ] During Qt build:
  - [ ] Run `qml-port-qt6-to-qt5.sh app/src/qml`
  - [ ] Hand-edit C++: `geometryChange` rename, `QStringConverter` swap, `qmlRegisterType` for MapLibreItem
  - [ ] CMakeLists.txt: Qt6 → Qt5 + qrc-based QML resource
  - [ ] Rebuild MapLibre GL Native against Qt 5

**Phase 4 — first deploy:**
- [ ] Build q60nav against Qt 5
- [ ] `deploy-to-slot-a.sh /dev/rdiskNs2 /path/to/build`
- [ ] **Don't disable emgdhmid yet** — first prove our q60nav can connect to a Wayland socket we control. Test by: boot factory, our q60nav.service starts, fails to connect to ivi-shell (because factory emgdhmid owns the only Weston). Logs confirm Qt sees ivi-shell binding attempt. Then re-deploy with `emgdhmid.service` disabled.
- [ ] Iterate

**Phase 5 — feature integration (1–2 weeks):**
- [ ] VehicleService refactor (DBus to AMB, IPC fallback to /tmp/*.cmd)
- [ ] AudioService through `sound.out` IPC + factory BlueZ AVRCP
- [ ] BluetoothService through factory BlueZ stack
- [ ] CameraFeed: remove all rendering, just listen for reverse-gear AMB event (kernel handles the sprite plane)

---

## Open questions (will be answered by capture probe)

1. **Factory `ivi_id` for the upper-UI surface** — surface ID we must reuse.
2. **Path of factory upper-UI binary** + ldd output — confirms EMGD libs to put on LD_LIBRARY_PATH.
3. **AMB presence on system D-Bus** + object paths — drives VehicleService refactor.
4. **Is `dbus-1.10`-class daemon available** or are we on a 1.6.x-era D-Bus? Affects QDBus compatibility.
5. **Does the factory have a "splash" / boot-anim surface** before emgdhmid runs? Affects handoff timing.
6. **Surface ID conflicts** with v2g sprite plane / debug surfaces — we must not steal IDs already claimed.

---

## Risks

1. **Qt 5.15 hit EOL upstream (May 2025).** KDE maintains it best-effort. Acceptable for an air-gapped automotive ECU.
2. **EMGD EGL/GLES libs on factory rootfs may be version-pinned** to a specific Weston ABI. Our `weston-q60.service` must use the EMGD-patched Weston binary the factory ships (`/usr/bin/weston` — confirm via ldd). We can't bring our own Weston without also bringing our own EMGD libs (impractical).
3. **Surface ID collision** breaks rear-camera handoff. Mitigation: capture before deploy; deploy script accepts `Q60_IVI_SURFACE_ID=<id>` override.
4. **AMB may not be present** — older DCU firmwares predate AMB integration. Fallback: pure /tmp/*.cmd IPC.
5. **Duplicate SD cards may not boot** at all (currently observed). Mitigation: develop on OEM card directly with debugfs-only writes (non-destructive); investigate root cause as separate track.

All bounded. None are project-killing.

---

## Estimated total Plan B effort

- Probe injection + capture: 0.5 day
- Qt 5.15 build + script changes: 1 day
- QML port + C++ fixes: 1 day (mostly waiting on Qt build)
- MapLibre Qt 5 rebuild: 0.5 day
- Deploy script + first Wayland-client boot: 0.5 day
- **First visible UI on DCU: ~3–4 days**

Then VehicleService D-Bus refactor + Audio/BT integration: 1–2 weeks
Then polish + emgdhmid-disable + factory parity: 1 week
Total to feature parity: ~3–4 weeks.

Compare to Plan A's "indefinite, blocked by elilo + Linux 4.x EFI handover wall." Plan B is the engineering decision.

---

## Staged artifacts (ready to copy into repo on "execute")

| Staged path | Destination |
|---|---|
| `/tmp/q60-overnight/plan-B-staging/build-qt515-i386.sh` | `deps/build-qt515-i386.sh` |
| `/tmp/q60-overnight/plan-B-staging/qml-port-qt6-to-qt5.sh` | `scripts/qml-port-qt6-to-qt5.sh` |
| `/tmp/q60-overnight/plan-B-staging/deploy-to-slot-a.sh` | `scripts/deploy-to-slot-a.sh` |
| `/tmp/q60-overnight/plan-B-staging/rc.local.denso-ipc-capture` | `rootfs/probes/denso-ipc-capture.sh` |
| `/tmp/q60-overnight/plan-b-qt515-pivot.md` | `docs/plan-b-qt515-pivot.md` |
| `/tmp/q60-overnight/plan-b-mesa-and-denso-ipc.md` | `docs/plan-b-mesa-and-denso-ipc.md` |
| `/tmp/q60-overnight/plan-b-userland-architecture.md` | `docs/plan-b-userland-architecture.md` |
| `/tmp/q60-overnight/plan-B-execution.md` (this file) | `docs/plan-b-execution.md` |
