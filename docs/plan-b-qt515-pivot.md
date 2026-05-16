# Plan B — Qt 5.15 LTS Pivot (Linux 2.6.37 / Atom E6xx i386)

**Context.** Plan A (Linux 4.19 + Qt 6.6.3) is on hold. Plan B keeps the factory Clarion DCU kernel (2.6.37 / glibc 2.13 era) and downgrades the framework to Qt 5.15 LTS. Qt 5.15 minimum kernel is 2.6.32, so the factory kernel is in scope. This doc covers (1) the i386 build plan and (2) the codebase porting audit.

---

## (1) Qt 5.15 LTS i386 Build Plan

### 1.1 Source — which patch level

| Option | Latest | Where | Recommendation |
|---|---|---|---|
| Qt official open-source tarball | **5.15.18** (Oct 31 2025) | `https://download.qt.io/archive/qt/5.15/5.15.18/single/qt-everywhere-opensource-src-5.15.18.tar.xz` (634 MB .xz) | **Baseline source** |
| KDE Qt 5.15 Patch Collection (`kde/5.15` branches) | actively maintained — CVE-2025-5455 landed ~Feb 2026 | `https://invent.kde.org/qt/qt/qt5.git` (super-repo) and per-module repos under `https://invent.kde.org/qt/qt/<module>.git` (`qtbase`, `qtdeclarative`, `qtquickcontrols2`, `qtmultimedia`, `qtlocation`, `qtwayland`, etc.) | **Optional overlay** for security fixes |

**Decision.** Target **Qt 5.15.18** as the tarball baseline. The Qt Company stopped public Qt 5.15.x releases at the 5.15.18 mark (Oct 2025); anything newer is paywalled commercial. KDE is the only ongoing free-software backport. Pull the `kde/5.15` branch of each module we ship and rebase onto 5.15.18 only if a specific CVE bites us — that's a Phase-2 task, not a Phase-0 build blocker.

**Why not 5.15.2?** That's what most distros shipped, but 16 patch releases of crash fixes and CVEs have landed since then. Use 5.15.18.

### 1.2 Source URLs

```bash
# Primary tarball (single archive, all modules)
https://download.qt.io/archive/qt/5.15/5.15.18/single/qt-everywhere-opensource-src-5.15.18.tar.xz
# MD5: https://download.qt.io/archive/qt/5.15/5.15.18/single/md5sums.txt

# KDE patch collection (super-repo + per-module)
git clone https://invent.kde.org/qt/qt/qt5.git           # branch: kde/5.15
git clone https://invent.kde.org/qt/qt/qtbase.git        # branch: kde/5.15
git clone https://invent.kde.org/qt/qt/qtdeclarative.git # branch: kde/5.15
# ... etc per module
```

### 1.3 Differences vs the Qt 6 build (`build-qt6-i386.sh`)

| Concern | Qt 6.6.3 (current) | Qt 5.15.18 (plan B) |
|---|---|---|
| Build system | CMake + Ninja | `configure` script → qmake → make (CMake support is incomplete in 5.15 — **do not use it**) |
| Host tools | Requires separate `QT_HOST_PATH` (we have `build-qt6-host.sh`) | Build script links host tools (moc/uic/rcc) **in-tree** — no separate host build needed |
| C++ standard | C++17 mandatory | C++17 default, C++14 still works |
| Multilib | `-m32 -march=i686` via CMake `CMAKE_CXX_FLAGS` | `-platform linux-g++-32` mkspec already exists in `qtbase/mkspecs/linux-g++-32/` and emits `-m32` correctly |
| 32-bit deps | `:i386` packages via `dpkg --add-architecture i386` | Same — identical `apt` package list works |
| Wayland | `-DFEATURE_wayland=ON` | `-feature-wayland-server` / config in `qtwayland` submodule (separate configure phase per module if doing a granular build) |
| SerialBus / SocketCAN | `-DFEATURE_serialbus=ON -DFEATURE_socketcan=ON` | `qtserialbus` submodule, builds by default |
| QML compiler | qmlcachegen (forced AOT) — **we already disabled with `NO_CACHEGEN`** | No qmlcachegen — interpreted QML by default. Cleaner story. |

**Net.** Qt 5 build is simpler: no host-tools precursor build, mkspec already exists for 32-bit, configure script handles everything in one pass. Expect ~30% less wall time vs the Qt 6 dual-build.

### 1.4 Modules to BUILD

Map the existing `find_package(Qt6 …)` list onto Qt 5.15 submodule names:

| Need | Qt 5.15 submodule | Notes |
|---|---|---|
| Core, Gui, Network, Qml, Quick, QmlModels, OpenGL, DBus | `qtbase` | All come from qtbase in Qt 5 |
| QuickControls2 + QtQuick.Controls | `qtquickcontrols2` | Includes Basic, Fusion, Material, Imagine styles — we only need Basic |
| Positioning + QGeoCoordinate | `qtlocation` | In Qt 5 `Positioning` is bundled inside `qtlocation` (Qt 6 split them) — must build `qtlocation` even though we don't use Map QML |
| QtMultimedia (rear-camera Loader) | `qtmultimedia` | Major API change vs Qt 6 — see §2 |
| Wayland (compositor client) | `qtwayland` | Required for dual-screen on Weston |
| QSerialBus / SocketCAN | `qtserialbus` | We use raw SocketCAN, not QCanBus — could `-skip` but it's cheap to build |
| QStringConverter | n/a — **does not exist** | Single porting fix needed; see §2 |

### 1.5 Modules to SKIP

Pass these to configure as `-skip <module>` (saves ~40 min build time + ~600 MB disk):

```
-skip qt3d              -skip qtactiveqt        -skip qtandroidextras
-skip qtcharts          -skip qtcoap            -skip qtconnectivity
-skip qtdatavis3d       -skip qtdoc             -skip qtdocgallery
-skip qtfeedback        -skip qtgamepad         -skip qtgraphicaleffects
-skip qtimageformats    -skip qtlottie           # keep imageformats if PNG/JPEG decoders break — they're usually safe to drop
-skip qtmacextras       -skip qtmqtt            -skip qtnetworkauth
-skip qtopcua           -skip qtpim             -skip qtpurchasing
-skip qtquick3d         -skip qtquicktimeline   -skip qtremoteobjects
-skip qtrepotools       -skip qtscript          -skip qtscxml
-skip qtsensors         -skip qtspeech          -skip qtsvg
-skip qttools           -skip qttranslations    -skip qtvirtualkeyboard
-skip qtwebchannel      -skip qtwebengine       -skip qtwebglplugin
-skip qtwebsockets      -skip qtwebview         -skip qtwinextras
-skip qtx11extras       -skip qtxmlpatterns     -skip qtsystems
-skip qtwayland          # ← REMOVE this line if dual-screen Weston is required (it is)
```

Note that **`qtsvg` is normally fine to keep** if any icon/asset uses SVG; we don't, so skip.
**Keep `qtimageformats`** if PNG/JPEG decoding ends up failing (Qt's bundled libpng/libjpeg fallback lives there).

### 1.6 Configure command (drop-in replacement for `build-qt6-i386.sh`)

```bash
#!/bin/bash
set -e
SRC=/build/deps/qt5-src/qt-everywhere-src-5.15.18
BUILD_DIR=/build/deps/qt5-build-i386
INSTALL_PREFIX=/build/output/qt5-i386
LOG_DIR="$INSTALL_PREFIX"
mkdir -p "$LOG_DIR" "$BUILD_DIR"

# i386 multilib packages (same set as qt6 build — already verified in toolchain image)
dpkg --add-architecture i386 || true
apt-get update -qq
apt-get install -y --no-install-recommends \
    libfontconfig1-dev:i386 libfreetype6-dev:i386 libxkbcommon-dev:i386 \
    libgl1-mesa-dev:i386 libgles2-mesa-dev:i386 libglib2.0-dev:i386 \
    libdbus-1-dev:i386 libinput-dev:i386 libudev-dev:i386 libssl-dev:i386 \
    zlib1g-dev:i386 libpcre2-dev:i386 libdouble-conversion-dev:i386 \
    libicu-dev:i386 libjpeg-dev:i386 libpng-dev:i386 \
    libwayland-dev:i386 libwayland-egl-backend-dev:i386 \
    libalsa-dev:i386 libpulse-dev:i386 gstreamer1.0-plugins-base:i386 \
    libgstreamer-plugins-base1.0-dev:i386

export PKG_CONFIG_LIBDIR=/usr/lib/i386-linux-gnu/pkgconfig
export PKG_CONFIG_SYSROOT_DIR=/

cd "$BUILD_DIR"

"$SRC/configure" \
    -prefix "$INSTALL_PREFIX" \
    -opensource -confirm-license \
    -release \
    -shared \
    -platform linux-g++-32 \
    \
    -c++std c++17 \
    -no-pch \
    -ltcg \
    \
    -nomake examples -nomake tests -nomake tools \
    \
    -qt-zlib -qt-libpng -qt-libjpeg -qt-pcre -qt-doubleconversion -qt-harfbuzz \
    \
    -dbus-linked \
    -openssl-linked \
    -fontconfig \
    -xkbcommon \
    \
    -opengl desktop \
    -no-eglfs \
    -linuxfb \
    -no-xcb \
    -no-directfb \
    \
    -gstreamer 1.0 \
    \
    -skip qt3d -skip qtactiveqt -skip qtandroidextras \
    -skip qtcharts -skip qtcoap -skip qtconnectivity \
    -skip qtdatavis3d -skip qtdoc -skip qtgamepad \
    -skip qtgraphicaleffects -skip qtlottie -skip qtmqtt \
    -skip qtnetworkauth -skip qtopcua -skip qtpurchasing \
    -skip qtquick3d -skip qtquicktimeline -skip qtremoteobjects \
    -skip qtscript -skip qtscxml -skip qtsensors -skip qtspeech \
    -skip qtsvg -skip qttools -skip qttranslations \
    -skip qtvirtualkeyboard -skip qtwebchannel -skip qtwebengine \
    -skip qtwebglplugin -skip qtwebsockets -skip qtwebview \
    -skip qtwinextras -skip qtx11extras -skip qtxmlpatterns \
    2>&1 | tee "$LOG_DIR/configure.log"

make -j"$(nproc)" 2>&1 | tee "$LOG_DIR/make.log"
make install     2>&1 | tee "$LOG_DIR/make-install.log"

# Verify
LIBCORE="$INSTALL_PREFIX/lib/libQt5Core.so.5"
file "$LIBCORE" || { echo "ERROR: $LIBCORE missing"; exit 1; }
```

**Sources for build flags:**
- [Qt 5.15 Configure Options](https://doc.qt.io/qt-5/configure-options.html)
- [Compile Qt Sources for Linux 32-bit (Qt Forum)](https://forum.qt.io/topic/101513/compile-qt-sources-for-linux-32-bit) — `linux-g++-32` mkspec
- [Cross-Compiling Qt 5.15 for Raspberry Pi 4](https://github.com/UvinduW/Cross-Compiling-Qt-for-Raspberry-Pi-4) — module-skip technique
- [Qt 5.15 Archive Index](https://download.qt.io/archive/qt/5.15/) — patch levels

### 1.7 Build time & disk

| Resource | Estimate | Notes |
|---|---|---|
| Source unpack | ~3.5 GB | `qt-everywhere-src-5.15.18` extracted |
| Build dir | ~7 GB | With `-skip` list above; ~12 GB without |
| Install prefix | ~450 MB | After `make install`, before stripping |
| Build wall time | **35–55 min** on a modern 8-core x86_64 host (vs 75–90 min for the Qt 6 dual-build) | Single-pass — no host-tools precursor |
| Build parallelism | `make -j$(nproc)`; safe to use all cores | Qt 5 build is less RAM-hungry than 6 (peaks ~2 GB per cc1plus vs ~5 GB in Qt 6 with LTO) |

---

## (2) Qt 6 → Qt 5.15 Codebase Audit

Scanned: `app/src/main.cpp`, `app/src/services/**`, `app/src/ui/**`, `app/src/qml/**`. Total LOC ~6.8k C++, ~5.4k QML.

### 2.1 QML imports — versioned imports required

Qt 5 QML requires explicit version numbers on every module import. **Every QML file needs a versioned import line.** Mapping:

| Qt 6 (versionless) | Qt 5.15 (versioned) |
|---|---|
| `import QtQuick` | `import QtQuick 2.15` |
| `import QtQuick.Controls` | `import QtQuick.Controls 2.15` |
| `import QtQuick.Window` | `import QtQuick.Window 2.15` |
| `import QtPositioning` | `import QtPositioning 5.15` |
| `import QtMultimedia 6.6` | `import QtMultimedia 5.15` |
| `import Q60Nav 1.0 as Q60Nav` | `import Q60Nav 1.0 as Q60Nav` *(unchanged — local module)* |

**Files needing edits (44 instances total):**

```
src/qml/Main.qml:6,7
src/qml/components/AvmOverlay.qml:16
src/qml/components/CameraFeed.qml:5,6        # also has QtMultimedia 6.6 → 5.15
src/qml/components/ContactsModel.qml:24
src/qml/components/FanControl.qml:2
src/qml/components/GPad.qml:4
src/qml/components/JunctionView.qml:8
src/qml/components/LaneGuidance.qml:10
src/qml/components/MiniGauge.qml:4
src/qml/components/QmlKeyboard.qml:7
src/qml/components/SpeedWidget.qml:1
src/qml/components/StatusBar.qml:3
src/qml/components/TabBar.qml:2
src/qml/components/TempZone.qml:2,3
src/qml/components/TurnArrow.qml:3
src/qml/components/WelcomeOverlay.qml:14
src/qml/screens/AudioView.qml:9,10
src/qml/screens/ClimateView.qml:3,4
src/qml/screens/ControlHubView.qml:6,7
src/qml/screens/DestinationSearch.qml:5,6
src/qml/screens/IncomingCallView.qml:3
src/qml/screens/InfoView.qml:4
src/qml/screens/NavCompanionView.qml:6,7
src/qml/screens/NavigationView.qml:4,5,6
src/qml/screens/PhoneView.qml:5,6
src/qml/screens/ProfileView.qml:12,13
src/qml/screens/RearCameraView.qml:5,6
src/qml/screens/RoutePreview.qml:5,6
src/qml/screens/SettingsView.qml:6,7
src/qml/screens/VehicleSettingsView.qml:5,6
src/qml/screens/VehicleStatusView.qml:4
src/qml/screens/VoiceCommandView.qml:3
```

**Mechanical fix.** A 3-line `sed` script handles this in one pass:

```bash
find app/src/qml -name "*.qml" -exec sed -i \
  -e 's|^import QtQuick$|import QtQuick 2.15|' \
  -e 's|^import QtQuick\.Controls$|import QtQuick.Controls 2.15|' \
  -e 's|^import QtQuick\.Window$|import QtQuick.Window 2.15|' \
  -e 's|^import QtPositioning$|import QtPositioning 5.15|' \
  -e 's|^import QtMultimedia 6\.6$|import QtMultimedia 5.15|' {} \;
```

### 2.2 `Connections { function on…Changed() }` — **CRITICAL syntax change**

The function-shorthand syntax (`function onFooChanged() { … }`) was added in Qt 5.15 itself, so **it works on both Qt 5.15 and Qt 6** — no porting required for the function form. **Good news: every Connections block in our codebase already uses the function form.**

Verified call sites (all OK on Qt 5.15):
- `src/qml/Main.qml:72-77, 124-129`
- `src/qml/screens/NavigationView.qml:45-51, 557-565`
- `src/qml/screens/ControlHubView.qml:20-31`
- `src/qml/screens/AudioView.qml:34-39`
- `src/qml/screens/PhoneView.qml:723-728`
- `src/qml/screens/VehicleStatusView.qml:81-86, 105-, 536-539, 1552-1555`
- `src/qml/components/GPad.qml:33-35`

**No `onFooChanged: { … }` legacy form found** — nothing to convert.

> Caveat: when targeting Qt 5.15, all Connections blocks emit a deprecation warning if both the function-shorthand AND a property-binding form are mixed in the same block. None of ours do, so no warnings expected.

### 2.3 `required` QML keyword — **none in use**

Search returned only `text: "Restart required to apply language."` (string literal in `SettingsView.qml:970`). No `required property` declarations. Nothing to port.

### 2.4 `QML_ELEMENT` / `QML_NAMED_ELEMENT` macros — **needs manual `qmlRegisterType`**

| Site | Current (Qt 6) | Qt 5.15 fix |
|---|---|---|
| `src/ui/map/MapLibreItem.h:44` | `QML_NAMED_ELEMENT(MapLibreMap)` | **Delete macro.** Register manually in `main.cpp`. |
| `src/main.cpp:56-58` (comment only) | "QML_ELEMENT + qt6_add_qml_module — no manual qmlRegisterType needed" | Replace with the call below. |

Add to `main.cpp` immediately before `engine.load(...)`:

```cpp
qmlRegisterType<MapLibreItem>("Q60Nav", 1, 0, "MapLibreMap");
```

This restores the same QML identity (`Q60Nav.MapLibreMap` 1.0) that the macro produced under Qt 6.

### 2.5 `qt_add_qml_module` / `qt6_add_qml_module` CMake — **must be replaced**

Qt 5.15 has no equivalent CMake helper. Two viable paths:

1. **Stay on CMake**, use `qrc` for QML files + `find_package(Qt5 …)`. Recommended — minimal disruption.
2. Switch to `.pro` + qmake. Worse: loses the existing build-system investment.

CMakeLists.txt rewrite plan:

```cmake
cmake_minimum_required(VERSION 3.16)
project(q60nav VERSION 0.1.0 LANGUAGES CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)

if(DEFINED ENV{QT5_I386_PREFIX})
    set(CMAKE_PREFIX_PATH "$ENV{QT5_I386_PREFIX}")
endif()

find_package(Qt5 5.15 REQUIRED COMPONENTS
    Core Gui Quick QuickControls2 Network Qml Positioning
)
find_package(Qt5 OPTIONAL_COMPONENTS DBus Multimedia)

# Generate a .qrc that captures every QML file under src/qml/.
# Equivalent to qt6_add_qml_module(QML_FILES …) but the Qt 5 way.
file(WRITE ${CMAKE_BINARY_DIR}/qml.qrc "<RCC><qresource prefix=\"/Q60Nav\">\n")
file(GLOB_RECURSE _qml_files RELATIVE ${CMAKE_CURRENT_SOURCE_DIR} src/qml/*.qml)
foreach(_q ${_qml_files})
    file(APPEND ${CMAKE_BINARY_DIR}/qml.qrc
         "<file alias=\"${_q}\">${CMAKE_CURRENT_SOURCE_DIR}/${_q}</file>\n")
endforeach()
file(APPEND ${CMAKE_BINARY_DIR}/qml.qrc "</qresource></RCC>\n")

add_executable(q60nav ${SOURCES} ${CMAKE_BINARY_DIR}/qml.qrc)
target_link_libraries(q60nav PRIVATE
    Qt5::Core Qt5::Gui Qt5::Quick Qt5::QuickControls2
    Qt5::Network Qt5::Qml Qt5::Positioning
)
if(Qt5DBus_FOUND)      target_link_libraries(q60nav PRIVATE Qt5::DBus)       endif()
if(Qt5Multimedia_FOUND) target_link_libraries(q60nav PRIVATE Qt5::Multimedia) endif()
```

The `qrc:/Q60Nav/src/qml/Main.qml` URL in `main.cpp:93` continues to work unchanged because we recreated the same resource prefix.

### 2.6 `QQuickItem::geometryChange` — **Qt 6 override name, must rename**

`src/ui/map/MapLibreItem.h:97` and `src/ui/map/MapLibreItem.cpp:272-276`:

```cpp
// Qt 6:
void geometryChange(const QRectF &newGeometry, const QRectF &oldGeometry) override;
// → Qt 5.15:
void geometryChanged(const QRectF &newGeometry, const QRectF &oldGeometry) override;
```

The `QQuickItem::geometryChange()` invocation on line 276 must also become `QQuickItem::geometryChanged(...)`. A `#if QT_VERSION >= QT_VERSION_CHECK(6,0,0)` guard works if dual-targeting is wanted.

### 2.7 `QStringConverter::Utf8` — **Qt 6 only, replace**

`src/services/vehicle/ButtonLogger.cpp:40`:

```cpp
// Qt 6:
m_stream.setEncoding(QStringConverter::Utf8);
// → Qt 5.15:
m_stream.setCodec("UTF-8");   // requires #include <QTextCodec>
```

This is the **only** Qt 6-exclusive string API in the codebase. `QStringLiteral`, `QString::arg`, all other string ops are identical.

### 2.8 QtMultimedia — **significant QML API change**

`src/qml/components/CameraFeed.qml` (the only multimedia surface in the app):

```qml
// Qt 6 (current):
MediaPlayer {
    id: player
    source: "v4l2:///dev/video0"
    autoPlay: true
    loops: MediaPlayer.Infinite
    onErrorOccurred: console.log("...", errorString)
}
VideoOutput {
    fillMode: VideoOutput.PreserveAspectCrop
    player: player                       // ← Qt 6 wires VO → player
}
```

```qml
// Qt 5.15:
MediaPlayer {
    id: player
    source: "v4l2:///dev/video0"
    autoPlay: true
    loops: MediaPlayer.Infinite
    onError: console.log("MediaPlayer error:", errorString)   // signal renamed
}
VideoOutput {
    fillMode: VideoOutput.PreserveAspectCrop
    source: player                       // ← Qt 5 wires VO ← player (`source`, not `player`)
}
```

Three concrete diffs in `CameraFeed.qml`:
- L6: `import QtMultimedia 6.6` → `import QtMultimedia 5.15`
- L18: signal `onErrorOccurred:` → `onError:` (single arg `errorString`)
- L27: property `player: player` → `source: player`

**Behavioural risk.** Qt 5.15 GStreamer backend on i386 is well-trodden territory — far more mature than Qt 6's `QPlatformMediaIntegration` rewrite. V4L2 source via `gst-launch v4l2src` is the actual playback path on both. Net: lower risk on Qt 5.15 for this surface.

### 2.9 QtPositioning — **mostly compatible**

- `QGeoCoordinate` exists in both — identical API. Used in `NavigationService.h`, `StatusBridge.cpp`, `TripLoggerService.cpp`, `MapLibreItem.h` — **no changes**.
- `QtPositioning.coordinate(lat, lon)` QML factory — exists in 5.15.
- In Qt 5 the module physically lives inside the `qtlocation` repo. Build `qtlocation` (don't skip it) to get `Qt5::Positioning`. **No source edits needed.**

### 2.10 QtDBus — **fully compatible**

`src/services/audio/AudioService.cpp` uses `QDBusConnection`, `QDBusInterface`, `QDBusReply`, `QDBusObjectPath`. All identical between Qt 5.15 and Qt 6. No changes.

Note we currently disable DBus in the Qt 6 i386 build (`-DFEATURE_dbus=OFF`). For Qt 5 we should **enable** DBus (`-dbus-linked` is in the configure command above) so AudioService BlueZ AVRCP works without the socket fallback.

### 2.11 Scene-graph / RHI — **safe**

`MapLibreItem.cpp:299-319` uses `QSGImageNode`, `window()->createImageNode()`, `window()->createTextureFromImage(...)`, `QQuickWindow::TextureHasAlphaChannel`. **All of these exist in Qt 5.15 with identical signatures.**

No use of `QQuickRhiItem` (Qt 6.7+), no `QQuickRenderControl`, no Vulkan/Metal — we render via the software scene graph (`QSG_RENDER_LOOP=basic`, `QT_QUICK_BACKEND=software`), which is unchanged.

### 2.12 `qmlcachegen` workaround — **becomes unnecessary**

CMakeLists.txt:114 carries `NO_CACHEGEN` and Main.qml:4-5 still hosts a `QtObject` root forced by qmlcachegen's "one root item" constraint. Qt 5.15 has **no qmlcachegen**, so:

- `NO_CACHEGEN` is irrelevant (delete on Qt 5 migration).
- The `QtObject` workaround in `Main.qml` is no longer necessary. **Recommended:** leave Main.qml structure as-is for now (the `findChildren<QQuickWindow*>` C++ discovery in main.cpp still works), then optionally simplify in a Phase-2 cleanup.

### 2.13 MapLibre native library — **Qt 5.15 path is supported**

We're not using `maplibre-native-qt` bindings; we use `mbgl::HeadlessFrontend` directly and render to `QImage` via `QSGImageNode`. That path is Qt-version-agnostic — depends only on `QQuickItem`/`QSGImageNode` which are stable.

**No MapLibre build changes needed** for the Qt 5 pivot. `deps/build-maplibre-i386.sh` continues to apply.

### 2.14 Compatibility summary table

| Concern | Files affected | Effort |
|---|---|---|
| Versioned QML imports | 32 files | 5 min (one sed) |
| `Connections` syntax | 9 sites | 0 — already 5.15-compatible |
| `required` keyword | 0 | 0 |
| `QML_NAMED_ELEMENT` → `qmlRegisterType` | 1 (`MapLibreItem.h` + `main.cpp`) | 10 min |
| `qt6_add_qml_module` → qrc | `CMakeLists.txt` | 30 min |
| `geometryChange` → `geometryChanged` | `MapLibreItem.h/.cpp` | 5 min |
| `QStringConverter` → `setCodec` | `ButtonLogger.cpp` | 2 min |
| QtMultimedia `player:` → `source:`, `onError` | `CameraFeed.qml` | 5 min |
| QtPositioning | 0 | 0 |
| QtDBus | 0 | 0 |
| `find_package(Qt6)` → `find_package(Qt5)` | `CMakeLists.txt` | 5 min |
| MapLibre/scene-graph | 0 | 0 |
| **Total porting work** | ~9 files | **~1 hour with testing** |

---

## Recommendation

Plan B is genuinely lower-risk than Plan A from this codebase's perspective. The QML/C++ porting surface is small (~1 hour of mechanical edits, no architecture changes), Qt 5.15.18 is a well-tested release on the 2.6.32+ kernel family, and our software-rendered scene graph is stable across both Qt 5 and Qt 6.

Build effort flips in our favour too: single-pass `configure` + `make`, no host-tools precursor, ~30% faster wall time, fewer toolchain edges (no `-march=bonnell` SIGBUS surprises since `linux-g++-32` mkspec already settles on i686).

---

## Sources

- [Qt 5.15 Archive Index](https://download.qt.io/archive/qt/5.15/) — 5.15.18 is the latest open-source release (Oct 31 2025)
- [Qt 5.15.18 single-archive directory](https://download.qt.io/archive/qt/5.15/5.15.18/single/) — `qt-everywhere-opensource-src-5.15.18.tar.xz` (634 MB)
- [KDE Qt5 Patch Collection](https://community.kde.org/Qt5PatchCollection) — security backports, `kde/5.15` branches at `https://invent.kde.org/qt/qt/`
- [KDE qtbase kde/5.15 commits](https://invent.kde.org/qt/qt/qtbase/-/commits/kde/5.15) — actively maintained
- [Qt 5.15 Configure Options](https://doc.qt.io/qt-5/configure-options.html) — `-skip`, `-platform`, `-xplatform` syntax
- [Qt 5.15 Embedded Linux configure guide](https://doc.qt.io/qt-5/configure-linux-device.html)
- [Compile Qt Sources for Linux 32-bit (Qt Forum)](https://forum.qt.io/topic/101513/compile-qt-sources-for-linux-32-bit) — `linux-g++-32` mkspec
- [QQuickItem 5.15 docs](https://doc.qt.io/qt-5/qquickitem.html) — `geometryChanged` override
- [Changes to Qt Quick (Qt 6 porting guide)](https://doc.qt.io/qt-6/quick-changes-qt6.html) — `geometryChange` rename
- [Qt Multimedia in Qt 6 blog](https://www.qt.io/blog/qt-multimedia-in-qt-6) — VideoOutput `source:` vs `player:` change
- [MediaPlayer QML 5.15 docs](https://doc.qt.io/qt-5/qml-qtmultimedia-mediaplayer.html) — `onError` signal signature
- [VideoOutput QML 5.15 docs](https://doc.qt.io/archives/qt-5.15/qml-qtmultimedia-videooutput.html) — `source` property
- [maplibre-native-qt](https://github.com/maplibre/maplibre-native-qt) — Qt 5.15 desktop is fully supported; we don't use these bindings directly anyway
