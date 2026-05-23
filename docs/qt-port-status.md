# Qt Port Status — Plan B''' (Configurable Buffers)

**Date:** 2026-05-23
**Author:** automated handoff
**Status:** **BUILD GREEN.** Binaries produced. NOT yet booted in car or QEMU.

---

## TL;DR

```
output/app-build/q60nav                                           — 743 KB, i386 ELF, Qt6 + emgdhmi plugin auto-loaded via QT_QPA_EGLFS_INTEGRATION
output/app-build/src/eglfs_emgdhmi/libqeglfs-emgdhmi-integration.so — 45 KB, i386 ELF, Plan B''' integration plugin
output/app-build/runtime-libs/                                    — 42 files, i386 .so bundle (icu, brotli, GLVND, fontconfig, freetype...)
```

Next action:
```bash
diskutil list
sudo bash /Users/dpitek/Developer/q60-rebuild/app/src/planb_qt/deploy-qt.sh disk4s2  # disk varies
# Drive car, then read /Volumes/boot/Q60_PLANB_QT_*.LOG
```

---

## Strategic call: stay on Qt6, ditch Qt5.15

The repo previously had `app/CMakeLists.txt` requiring Qt 5.15 (commit `1ae703a port(plan-b): Qt 6 → Qt 5.15 mechanical port`). That decision was for **old Plan B** (Weston + wl_shm + software raster). Plan B''' is direct EGL pixmap surface and **needs OpenGL/EGL in Qt**.

Evidence:
- `deps/build-qt515-i386.sh` lines 99-100: `-no-opengl -no-egl`. The Qt5.15 build, if completed, would be unable to run Plan B'''.
- The Qt5.15 build was never finished — `deps/qt5-src/`, `deps/qt5-build-i386/`, `output/qt5-i386/` are all absent.
- `output/qt6-i386/` is a **completed Qt 6.6.3 i386 build** with EGL/GL/EglFSDeviceIntegrationPrivate headers and libs all present.

**Decision:** Qt6 — reverted `app/CMakeLists.txt`, fixed Qt6 API drift (`geometryChange`, dropped `QTextCodec`), built clean.

---

## What's working

| Item | Status | Notes |
|---|---|---|
| `output/app-build/q60nav` | **Built** | 743 KB stripped i386 ELF. Links: Qt6Core/Gui/Quick/QuickControls2/Qml/Network/Positioning + libstdc++/libm/libgcc_s/libc (lib32) |
| `output/app-build/src/eglfs_emgdhmi/libqeglfs-emgdhmi-integration.so` | **Built** | 45 KB i386 ELF. IID `org.qt-project.qt.qpa.egl.QEglFSDeviceIntegrationFactoryInterface.5.5`, key `eglfs_emgdhmi`. Implements: `platformInit`, `platformDisplay`, `screenSize`, `surfaceFormatFor`, `surfaceType`, `createNativeWindow` + ConfigureBuffers, `destroyNativeWindow`, `presentBuffer` (with optional RequestFlip). |
| `output/app-build/runtime-libs/` | **Built** | 42 i386 .so files. Bundled because the factory rootfs (MeeGo 2.11.90 / glibc 2.11.90) is too old. Contains: icu70, brotli, double-conversion, pcre2, fontconfig, freetype, png16, glib, glvnd shims (libGLX, libOpenGL, libGLdispatch). |
| `scripts/build-app.sh` | **Working** | Docker container `q60-toolchain` (Ubuntu 22.04 + i386 deps). Single command — builds binary + plugin + runtime-libs bundle in one pass. |
| `app/src/planb_qt/run-q60qt.sh` | **Written** | On-device wrapper: mounts /boot, waits 80s (post-panel-on), stops `nav_navi.service + nav_dispapf.service`, sets `LD_LIBRARY_PATH=/opt/q60qt/lib:/usr/lib:/usr/lib/wsegl:...`, sets `QT_QPA_PLATFORM=eglfs + QT_QPA_EGLFS_INTEGRATION=eglfs_emgdhmi`, launches q60nav, copies logs to /boot. |
| `app/src/planb_qt/deploy-qt.sh` | **Written** | Modeled on `deploy-spike.sh`. Stages binary + plugin + runtime-libs + Qt6 core libs + Qt6 platform/image plugins + run-q60qt.sh into `/opt/q60qt/...` on Slot B via debugfs. Hooks android-mount.sh AND installs a systemd unit (`q60-planb-qt.service`). |

## What's blocked / unknown until first boot

1. **GLVND shim risk.** Qt6 i386 was built with `find_package(OpenGL)` → linked to `libGLX.so.0 + libOpenGL.so.0` (GLVND). The factory rootfs has only `libEGL.so.1 + libGLES_CM.so.1` — no GLVND. We're shipping the GLVND shims in `runtime-libs/`. The GLVND dispatcher will dlopen an "indirect" backend on first GL call; if our EGL path never triggers desktop-GL entry points (correct for Qt eglfs), nothing bad happens. **If it does**, we either crash or get an obscure "no GL" error.
2. **glibc compat (Qt-scale).** The spike4 binary worked with the LD trick (`/usr/lib` first → modern glibc; factory libs after). Qt pulls in MANY more deps; each could clash. Mitigation: we ship modern versions in `runtime-libs/` and put `/opt/q60qt/lib` first in `LD_LIBRARY_PATH`.
3. **ConfigureBuffers + Qt eglfs ordering.** Plugin calls ConfigureBuffers immediately after CreatePixmap in `createNativeWindow()`. This runs BEFORE Qt's eglCreateWindowSurface. Per spike4, that's the right order. If hardware says otherwise, we hook `presentBuffer()` for first-swap deferred binding.
4. **`surfaceType()` returns `EGL_WINDOW_BIT`** (not PIXMAP) because Qt's `QEglFSWindow` always calls `eglCreateWindowSurface`. The factory drawbuf binary does the same — passes the EMGD pixmap pointer as `EGLNativeWindowType`. The WSEGL backend (libwsegl-hmi.so) handles either form.
5. **Dual screen still TODO.** The plugin returns the single 800x480 upper LVDS for now; lower screen (800x420) needs a multi-screen story when we get past first paint.

## What's been demonstrated

Independently from this session:
- `q60_planb_spike4_configure_buffers.c` painted solid red on the upper LVDS via the same C ABI calls we're wrapping in Qt. The plugin replicates that recipe exactly (see `qeglfsemgdhmi.cpp::configureBuffers()`).

In this session:
- Build green end-to-end.
- Plugin metadata correctly emitted (verified via `strings`: IID = `...5.5`, Key = `eglfs_emgdhmi`).
- Deploy script wired with all necessary file copies (Qt6 libs, plugins, integration, runtime-libs bundle).

## Risk inventory

| Risk | Severity | Mitigation |
|---|---|---|
| Qt plugin loader rejects integration (IID mismatch) | Med | Logged via `QT_DEBUG_PLUGINS=1` (set in `run-q60qt.sh`); IID matches Qt 6.6.3 header definition |
| ConfigureBuffers returns -3 (BAD_CONFIG) at 480 height | Low | Plugin auto-retries with height=450 (per D5 §4) |
| GLVND shim breaks GL calls | Med | Plan 2c fallback: drop Qt for now, paint test pattern via raw GL in extended spike |
| `nav_navi.service + nav_dispapf.service` won't stop cleanly | Low | `systemctl stop` is enforced; we don't kill emgdhmid or display_ps |
| /tmp/.emgdhmid_socket access (UID/GID/Group=video) | Low | Hook runs as root via android-mount.sh; can't fail permission check |

## Fallback Plan 2c (if Qt is hopeless)

The C spike (`app/src/planb_spike/q60_planb_spike4_configure_buffers.c`) already paints solid red over 15 seconds via the exact path we're trying. To validate the pipeline visually without Qt, extend the spike with a render-test pattern:

```c
// Insert at line 257 of q60_planb_spike4_configure_buffers.c
// Replace the simple red clear with a coordinate-anchored gradient:
for (int i = 0; i < 60; i++) {
    float t = i / 60.0f;
    p_glClearColor(t, 1.0f - t, 0.5f, 1.0f);  // red ↔ green gradient over time
    p_glClear(GL_COLOR_BUFFER_BIT);
    p_glFinish();
    p_eglSwapBuffers(dpy, surf);
    if (p_RequestFlip) {
        int did_flip = 0;
        p_RequestFlip(ndpy, 0, 0, &did_flip);
    }
    usleep(250000);  // 4 fps
}
```

That gives an unambiguous "I'm painting frames" visual signal — the screen colour rotates from red to green over 15 seconds. Without Qt, it's a 30-line change to `q60_planb_spike4_configure_buffers.c` and re-uses the working spike pipeline.

## Files created/modified in this session

| File | Action |
|---|---|
| `app/CMakeLists.txt` | Reverted Qt5→Qt6; added `add_subdirectory(src/eglfs_emgdhmi)` |
| `app/src/main.cpp` | Default `QT_QPA_PLATFORM=eglfs` + `QT_QPA_EGLFS_INTEGRATION=eglfs_emgdhmi` instead of wayland/software |
| `app/src/services/vehicle/ButtonLogger.cpp` | Dropped `<QTextCodec>` + `setCodec("UTF-8")` (Qt6 default is UTF-8) |
| `app/src/ui/map/MapLibreItem.h/cpp` | `geometryChanged` → `geometryChange` (Qt6 protected override name) |
| `app/src/eglfs_emgdhmi/qeglfsemgdhmi.h` | NEW — plugin class declaration |
| `app/src/eglfs_emgdhmi/qeglfsemgdhmi.cpp` | NEW — plugin impl |
| `app/src/eglfs_emgdhmi/qeglfsemgdhmi_main.cpp` | NEW — entry-point TU |
| `app/src/eglfs_emgdhmi/eglfs_emgdhmi.json` | NEW — plugin metadata |
| `app/src/eglfs_emgdhmi/CMakeLists.txt` | NEW — plugin build |
| `app/src/planb_qt/run-q60qt.sh` | NEW — on-device launch wrapper |
| `app/src/planb_qt/deploy-qt.sh` | NEW — SD card deploy (debugfs) |
| `scripts/build-app.sh` | Updated for Qt6 + plugin path + runtime-libs bundling |
| `docs/qt-port-status.md` | NEW — this file |

## Single most useful next action

Deploy to test SD card and boot the car.

```bash
cd /Users/dpitek/Developer/q60-rebuild
diskutil list                               # find the 64 GB SD card (e.g. disk4)
sudo bash app/src/planb_qt/deploy-qt.sh disk4s2

# In car: install card, boot. Wait ~90s for Qt to launch.
# After power-off, pull card and read:
ls /Volumes/boot/Q60_PLANB_QT_*.LOG
cat /Volumes/boot/Q60_PLANB_QT_STDERR.LOG    # QT_DEBUG_PLUGINS output — proves plugin loaded
cat /Volumes/boot/Q60_PLANB_QT_STDOUT.LOG    # qDebug from our plugin's emgdHmi calls
```

If the first attempt fails on Qt loading the plugin, `QT_DEBUG_PLUGINS=1` will tell us WHY (IID mismatch, missing dep, etc.) and we iterate from there.

If everything compiles but the screen stays black, fall back to Plan 2c (the 30-line spike extension above) to validate the underlying paint pipeline independent of Qt's complexity.
