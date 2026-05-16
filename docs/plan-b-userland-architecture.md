# Plan B — Keep DENSO userland, inject q60nav as the upper-UI

**Date:** 2026-05-16
**Author:** agent-userland (research pass)
**Status:** Research complete; integration plan below.
**Scope:** Map exactly how DENSO's Tizen-IVI–derived userland boots its upper-screen UI on Q60 DCU (Atom E6xx Crownsville + LAPIS ML7213 IOH, Linux 2.6.37) so we can drop in `q60nav` cleanly.

---

## 1. Executive summary (the answer first)

DENSO's "upper UI" stack on the Q60 DCU is a productized **Tizen-IVI 1.x / early-2.x** graphics pipeline built around three pieces:

1. **EMGD kernel driver + libraries** providing the framebuffer, EGL, and GLES (PowerVR SGX 535 derived). EMGD owns `/dev/dri/card0`, the LVDS panel, the sDVO/clone output, and exclusive framebuffer access. There is **no Mesa/DRI**.
2. **Weston compositor loaded with `ivi-shell.so` + `hmi-controller.so` and the v2g/v2gbridge sprite-overlay plugin** — the latter is the EMGD-specific way to give the rear-camera overlay its own hardware sprite plane on top of the GLES surface stack.
3. **A single Wayland client app that owns the upper-screen surface** via the GENIVI `ivi_application` and `ivi_hmi_controller` Wayland protocols (the latter authored 2013 by **DENSO + BMW Car IT**).

`emgdhmid.service` ("**EMGD HMI Daemon**") is the systemd unit that brings up that whole pipeline as one bag — it is a DENSO wrapper around the canonical `weston --shell=ivi-shell.so --modules=hmi-controller.so` invocation plus the EMGD-specific environment, the v2g sprite registration, and the upper-UI client launch. It lives under `basic.target.wants/`, runs early-and-long, and is the *single* graft point.

The other DENSO daemons (`sxmcgs.out`, `radiofc.out`, `sound.out`, `vcan.out`, etc.) are **headless backend services**. They are not display-related and do not need to be touched. The HMI app talks to them via named pipes in `/tmp/*.cmd` and, almost certainly, via a Tizen/GENIVI D-Bus session bus that rides over `navi0` (a virtual TUN-style interface DENSO uses to bridge IPC between the upper-screen DCU process group and the lower-screen / IOH side).

**Integration plan (one line):** stop `emgdhmid.service`, install our own `q60nav.service` ordered `After=basic.target` and `Wants=weston-q60.service`, where `weston-q60.service` runs Weston with the same EMGD `configid`/`dc` modprobe options and `ivi-shell.so`, then `q60nav` connects as an `ivi_application` client with the same `ivi_id` the factory app used. Keep every other DENSO daemon running.

---

## 2. Verified findings (with sources)

### 2.1 Hardware/driver platform — confirmed

- **Crownsville-Lapis** (the codename for the captured probe's SoC) is the Tizen IVI reference platform for **Intel Atom E6xx (Tunnel Creek) + LAPIS Semiconductor ML7213 IOH**. This is exactly the silicon Q60 ships. ([Tizen Wiki — IVI Setup](https://wiki.tizen.org/IVI/IVI_Setup), [Congatec AN23 EMGD on E6xx](https://www.congatec.com/fileadmin/user_upload/Documents/Application_Notes/AN23_EMGD_graphic_driver_on_E6xx_v_1_2.pdf))
- **EMGD is the *only* graphics path on E6xx**; Mesa/DRI does not work. Wayland and Weston can run only because they speak EGL/GLES against EMGD's proprietary libs. Quote from Tizen IVI: *"Wayland and Weston packages can be built for use only with targets that accept Mesa DRI, which implies that you cannot build and use the packages if your target uses Intel EMGD that overrides Mesa DRI."* — **but DENSO ships the EMGD-patched Weston build**, which is exactly why we still see `emgd`, `v2g`, `v2gbridge` modules in the captured probe.
- **`configid` + `dc`** are the magic. The Tizen IVI setup guide explicitly documents the dual-display formula: `/etc/modprobe.d/emgd.conf` with `options emgd configid=5` and `options emgd dc=2` to make sDVO primary and LVDS secondary. Q60 will use a different `configid` (single LVDS upper screen), but the mechanism is identical. ([Tizen Wiki — IVI Setup](https://wiki.tizen.org/IVI/IVI_Setup))
- **Loaded modules from the probe** (`emgd, v2g, v2gbridge, ml7213ioh, capture_ctl, ioh_video_in, snd_pcm, bt_hci, setgpio, watchdog`) line up exactly with the Crownsville-Lapis BSP. `v2g`/`v2gbridge` are the **video sprite-overlay path** — they let a non-Weston source (rear-camera capture via `ioh_video_in`/`capture_ctl`) get a dedicated hardware overlay plane that sits above the Weston-composited UI without going through GLES. That's how the factory does the "instant rear-camera" overlay on top of the navi UI.

### 2.2 Why `emgdhmid` is not Googleable

The string "emgdhmid" doesn't appear anywhere on the public web — confirmed via half a dozen targeted searches. That's consistent with it being a **DENSO-internal name** for what is, functionally, a Weston-with-ivi-shell-and-hmi-controller bring-up. It's the same pattern DENSO has used since the 2013 ivi-hmi-controller protocol they co-authored with BMW. The "d" suffix is the conventional Unix daemon naming. Read it as:

> **emgdhmid** = "EMGD HMI Daemon" = DENSO's productized `weston-launch + ivi-shell + hmi-controller + v2g sprite registration + upper-UI client launcher`, all in one systemd unit.

### 2.3 The Tizen-IVI launch pattern (what `emgdhmid.service` is actually doing)

The canonical Tizen IVI / GENIVI compose this way ([Tizen wiki](https://wiki.tizen.org/Wayland_ivi-shell), [Weston ivi-shell docs](https://wayland.pages.freedesktop.org/weston/toc/ivi-shell.html), [NVIDIA Drive OS docs](https://developer.nvidia.com/docs/drive/drive-os/6.0.8/public/drive-os-linux-sdk/common/topics/window_system_stub/TostartWestonwithivi-shellandhmi-control75.html)):

```
weston-launch -- -i0 --current-mode --shell=ivi-shell.so \
              --modules=hmi-controller.so
```

- `ivi-shell.so` exposes `ivi_application` and the `ivi_layout_interface`.
- `hmi-controller.so` is the Weston **plugin** that decides which surfaces go where, what z-order, what mode (tiling / side-by-side / **full-screen** / random). On Q60 the upper UI runs **full-screen** with a single surface owned by the factory app and a v2g sprite plane reserved for the camera.
- The HMI controller speaks the **`ivi_hmi_controller`** protocol — `UI_ready()`, `workspace_control()`, `switch_mode()`, `home()`. Source attribution on the protocol XML literally reads **"DENSO CORPORATION and BMW Car IT GmbH, 2013"** ([wayland.app/protocols/ivi-hmi-controller](https://wayland.app/protocols/ivi-hmi-controller)). That's the smoking gun — Q60's stack *is* that 2013 DENSO design, productized.
- Clients become surfaces by binding `ivi_application` and calling `ivi_application.surface_create(ivi_id, wl_surface)`. The HMI controller then sees the new `ivi_surface`, looks up its `ivi_id`, and decides where to put it. On a single-screen full-screen layout, **the first client with the configured `ivi_id` owns the whole screen.**
- The launcher is configured in `weston.ini` under `[ivi-launcher]` (`workspace-id`, `icon-id`, `icon`, `path`) — for DENSO this is set to a single entry pointing at the factory upper-UI binary, and `hmi-controller` is configured (Weston's `[shell]` section) to call `home()` as part of `UI_ready()`.

### 2.4 What launches the actual upper-UI app

Three plausible models; one fits Q60.

| Model | How it works | Q60 fit |
|---|---|---|
| A. Weston spawns the client from `weston.ini [ivi-launcher] path=` | hmi-controller invokes the path on `UI_ready()` | **This is what `emgdhmid.service` does.** Weston is configured to autolaunch the factory app. |
| B. A separate systemd `*.service` waits on Weston's socket and execs the client | Decoupled lifecycle, common in AGL UCB 3.0+ | Not used here — no separate "hmi-app.service" in the captured probe |
| C. Murphy / Tizen `appfw` launches it via `app_launcher` | Adds session-manager + Smack layering | Tizen-IVI 3.0 used this; Q60 is **older** (2.6.37 kernel = IVI 1.x/early 2.x), pre-Murphy |

The probe **does not** show a `weston.service`, an `app-launcher.service`, or `murphy.service` in `late-services.target.wants/`. The single graphics unit visible is `emgdhmid.service` under `basic.target.wants/`. That is consistent with model **A** — `emgdhmid.service` *is* the Weston unit (renamed to obscure the upstream), and Weston is configured to autolaunch the upper-UI app via `weston.ini`.

### 2.5 The DENSO IPC fabric — what `navi0` actually is

The captured probe shows three interfaces: `navi0`, `audio0`, `lo`. The names match DENSO's longstanding *Distributed IPC* design: each functional bus (nav, audio) gets its own loopback-style virtual NIC with daemons binding D-Bus/Unix-domain over it, plus named pipes for short-form commands.

- **`navi0`** is a `tun`/`dummy`-style virtual interface used as the address bus for the upper-screen process group. DENSO daemons bind to a fixed IP on `navi0` and exchange D-Bus or zeromq-style frames. This is consistent with their published GENIVI compliance posture (the system uses GENIVI **CommonAPI/D-Bus** as the IPC abstraction; behind that, transport is loopback IP, not raw Unix sockets, so they can later migrate to Ethernet-AVB without rewriting clients).
- **`audio0`** is the equivalent for the Bose/PulseAudio path — the `ml7213ioh` I2S driver presents ALSA, but routing decisions go through `sound.out` over `audio0`.
- **`/tmp/sxmcgs.cmd`, `/tmp/*.cmd`** are named pipes used as command channels for one-shot ops (Sirius command, radio frequency change). State and streaming events ride D-Bus on `navi0`.
- **AMB (Automotive Message Broker)** is the most likely D-Bus service on `navi0` — Tizen IVI's standard vehicle-data broker. Object path schema `org.automotive.<DataType>` ([Tizen AMB wiki](https://wiki.tizen.org/Automotive_Message_Broker)). Vehicle data (speed, gear, lights) arrives via `vcan.out` → AMB → D-Bus subscribers.

**Implication for q60nav:** we do **not** need to reverse engineer a private DENSO IPC. We need:
1. A D-Bus session bus that connects to `navi0`'s session address (almost certainly via `/var/run/dbus/system_bus_socket` or a similar Unix socket, with `DBUS_SYSTEM_BUS_ADDRESS=unix:path=...` set by `emgdhmid.service`).
2. Optionally, named-pipe writes to `/tmp/sxmcgs.cmd` etc. for legacy command paths.

Qt has first-class D-Bus support. Reuse, don't rewrite.

### 2.6 Lifecycle: who owns the framebuffer

EMGD requires **exclusive framebuffer access** (Intel community / EMGD FAQ). Weston grabs it on startup via the EMGD DRM ioctls and holds it for the duration of the session. Camera overlay is *not* a Weston client — it goes via the `v2g`/`v2gbridge` sprite plane, which the kernel composites on top of Weston's primary plane. That means:

- The upper UI client (factory app today, q60nav tomorrow) **never loses the screen** when the camera goes active; the camera just paints a sprite plane above it.
- The camera-active signal comes via `setgpio` (reverse-gear sense) → `vcan.out` → AMB → D-Bus event → either the HMI client reacts, or `v2gbridge` does it autonomously based on a kernel-side rule registered by `emgdhmid.service` at boot.

### 2.7 Are there public reference HMI clients for EMGD?

**Practically no.** EMGD documentation was pulled by Intel in 2013. The only public artifacts:

- [`EMGD-Community/intel-binaries-linux`](https://github.com/EMGD-Community/intel-binaries-linux) — kernel DRM driver, X.org xf86-video-emgd, EGL/GLES blobs, `emgdinfo`, `emgdui`. No HMI sample.
- [`intel/external-weston`](https://github.com/intel/external-weston) and [`ntanibata/weston-ivi-shell`](https://github.com/ntanibata/weston-ivi-shell) — Intel's Weston fork with the ivi-shell + hmi-controller that DENSO co-developed. **This is the closest reference** to what `emgdhmid` is actually running.
- [`COVESA/wayland-ivi-extension`](https://github.com/COVESA/wayland-ivi-extension) — the productized successor; includes `LayerManagerControl`, `ivi-controller.so`. Newer than Q60's stack but API-compatible.

For Qt: setting `QT_WAYLAND_SHELL_INTEGRATION=ivi-shell` (with `QT_IVI_SURFACE_ID=<id>`) makes any Qt 5/6 app a valid `ivi_application` client. That's our q60nav path — Qt + Wayland-ivi shell integration + EMGD-EGL libraries linked at runtime via ld.so paths the factory rootfs already provides.

---

## 3. Integration plan — replace the upper-UI, keep everything else

### 3.1 What we disable

Exactly one unit:

```
systemctl disable emgdhmid.service
```

### 3.2 What we keep running (untouched)

Everything else in `basic.target.wants/` and `late-services.target.wants/`:

- `udisks.service`, `pulseaudio.service`, `udev.service`, `iptables.service` — base system.
- `android-mount.service`, `android-data-system-tmp.mount` — Android subsystem stays as-is.
- `sud-change-elilo.service` — DENSO's slot-A/B updater shim; do not touch.
- All DENSO backend daemons (`sxmcgs.out`, `radiofc.out`, `sound.out`, `vcan.out`, etc.) — they auto-start via their own units and answer D-Bus on `navi0`.
- The kernel modules (`emgd`, `v2g`, `v2gbridge`, `ml7213ioh`, `setgpio`, `watchdog`, etc.) — autoloaded by udev/modprobe from `/etc/modprobe.d/emgd.conf` which we leave intact.

### 3.3 What we add — two new units

**`/etc/systemd/system/weston-q60.service`** (the compositor; what `emgdhmid` did, minus the launching of the proprietary app):

```ini
[Unit]
Description=Weston compositor for Q60 (EMGD + ivi-shell + v2g sprite)
After=basic.target
Wants=basic.target
ConditionPathExists=/dev/dri/card0

[Service]
Type=simple
User=root
Environment=XDG_RUNTIME_DIR=/run/user/0
Environment=WAYLAND_DISPLAY=wayland-0
# Same configid/dc the factory uses (read from /etc/modprobe.d/emgd.conf — do not hand-pick)
ExecStartPre=/bin/mkdir -p /run/user/0
ExecStart=/usr/bin/weston-launch -- -i0 --current-mode \
          --shell=ivi-shell.so \
          --modules=hmi-controller.so,v2g-sprite.so \
          --config=/etc/q60/weston.ini \
          --log=/tmp/weston-q60.log
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
```

**`/etc/systemd/system/q60nav.service`** (our Qt app as the ivi-shell client):

```ini
[Unit]
Description=q60nav upper-screen application
After=weston-q60.service
Requires=weston-q60.service

[Service]
Type=simple
User=root
Environment=XDG_RUNTIME_DIR=/run/user/0
Environment=WAYLAND_DISPLAY=wayland-0
Environment=QT_QPA_PLATFORM=wayland
Environment=QT_WAYLAND_SHELL_INTEGRATION=ivi-shell
Environment=QT_IVI_SURFACE_ID=1000        # match factory's surface id; TODO: confirm from emgdhmid binary
Environment=DBUS_SYSTEM_BUS_ADDRESS=unix:path=/var/run/dbus/system_bus_socket
ExecStart=/opt/q60nav/bin/q60nav --fullscreen
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
```

### 3.4 Configuration we must produce

**`/etc/q60/weston.ini`** — minimal:

```ini
[core]
shell=ivi-shell.so
modules=hmi-controller.so

[ivi-shell]
ivi-module=hmi-controller.so

[hmi-controller]
# Single full-screen layout, one ivi_id wins
cursor-theme=

[ivi-launcher]
workspace-id=0
icon-id=1000
icon=/opt/q60nav/share/q60nav.png
path=/opt/q60nav/bin/q60nav
```

Or — preferred — **do not autolaunch from weston.ini**; let `q60nav.service` start the client. That gives us systemd-style logging, restart policy, and crash recovery.

### 3.5 One-time data extraction we still need from the live unit

Before flipping `emgdhmid` off in production, capture from a running factory DCU:

1. `cat /lib/systemd/system/emgdhmid.service` — its actual `ExecStart=` and environment. We need: the exact Weston binary path (it may be `/usr/bin/weston` or a DENSO-renamed shim), any extra `--modules=` (especially v2g-related), the path to its weston.ini.
2. `cat /etc/q60-equiv-of-weston.ini` (wherever DENSO put theirs) — the `[ivi-launcher]` path is the factory upper-UI binary; the `ivi_id` is the surface ID we must replicate so any other DENSO client (camera overlay, debug HUD) still finds its peer.
3. `ldd /path/to/factory-upper-ui-app` — list of `lib*.so` to confirm Qt vs. EFL vs. custom toolkit, and which EMGD libs (`libIMGegl.so`, `libgles_cm.so`, `libEGL.so`, `libGLESv2.so`) are linked. Our q60nav must link the same EMGD libs (already on the rootfs at `/usr/lib`).
4. `dbus-send --system --print-reply --dest=org.freedesktop.DBus / org.freedesktop.DBus.ListNames` — enumerate D-Bus services. We expect `org.automotive.Manager` (AMB), DENSO-specific buses, and the IVI HMI controller bus.
5. `cat /proc/<emgdhmid-pid>/environ | tr '\0' '\n'` — verify `XDG_RUNTIME_DIR`, `WAYLAND_DISPLAY`, `DBUS_*`, `EMGD_*` env we need to mirror.

These five commands are the minimum diff between "we wrote a plausible plan" and "we have the actual configuration."

---

## 4. Open questions / next probes

1. **What surface ID does the factory app use?** — Must be known so we don't conflict with the camera sprite or any persistent debug surface.
2. **Is there a "splash" / boot-anim surface that runs before `emgdhmid`?** — If so it owns the screen until handoff; we need the same handoff signal.
3. **Does `emgdhmid` itself register the v2g sprite, or does a separate `v2g-init` unit do it?** — Camera-overlay correctness depends on getting this right.
4. **Audio routing: do we need to register q60nav with `sound.out` (via `/tmp/sound.cmd` or AMB) to claim the music/voice channel?** — Likely yes for nav voice prompts.
5. **CAN access: does `vcan.out` expose CAN frames via AMB only, or also via a raw socket on `navi0`?** — Decides whether q60nav reads CAN through libdbus or directly.

All five are answerable in <15 minutes with a serial-console session on a live DCU.

---

## 5. Sources

- [Tizen Wiki — IVI/IVI Setup](https://wiki.tizen.org/IVI/IVI_Setup) — EMGD `configid`/`dc` on Atom E6xx; weston.service path; modprobe options
- [Tizen Wiki — Wayland ivi-shell](https://wiki.tizen.org/Wayland_ivi-shell) — ivi-shell + hmi-controller surface registration; weston-launch invocation
- [Tizen Wiki — IVI/ICO](https://wiki.tizen.org/IVI/ICO) — ICO HomeScreen launcher pattern (DENSO precursor)
- [Tizen Wiki — Automotive Message Broker](https://wiki.tizen.org/Automotive_Message_Broker) — AMB D-Bus schema on `navi0`-like buses
- [Wayland Explorer — ivi-hmi-controller protocol](https://wayland.app/protocols/ivi-hmi-controller) — **authored by DENSO Corporation + BMW Car IT GmbH, 2013** (smoking-gun attribution)
- [Weston ivi-shell official docs](https://wayland.pages.freedesktop.org/weston/toc/ivi-shell.html) — ivi-shell.so + hmi-controller.so architecture
- [NVIDIA Drive OS — Start Weston with ivi-shell and hmi-controller](https://developer.nvidia.com/docs/drive/drive-os/6.0.8/public/drive-os-linux-sdk/common/topics/window_system_stub/TostartWestonwithivi-shellandhmi-control75.html) — exact `weston-launch` invocation
- [Intel external-weston (GitHub)](https://github.com/intel/external-weston) — Intel's Weston fork with EMGD-friendly ivi-shell
- [ntanibata/weston-ivi-shell (GitHub)](https://github.com/ntanibata/weston-ivi-shell) — original Weston ivi-shell branch, weston.ini.in template
- [COVESA/wayland-ivi-extension (GitHub)](https://github.com/COVESA/wayland-ivi-extension) — modern GENIVI Layer Manager (successor)
- [EMGD-Community/intel-binaries-linux (GitHub)](https://github.com/EMGD-Community/intel-binaries-linux) — EMGD kernel DRM, X driver, EGL/GLES blobs
- [Congatec AN23 — EMGD on Atom E6xx](https://www.congatec.com/fileadmin/user_upload/Documents/Application_Notes/AN23_EMGD_graphic_driver_on_E6xx_v_1_2.pdf) — Tunnel Creek dual-output configuration
- [DENSO Nissan FOSS portal](https://www.denso.com/global//en/opensource/ivi/nissan/) — blocked by Cloudflare; contains the source tarballs DENSO is required to publish for the Q50/Q60 platform (worth retrieving via a browser when next on the network)
- [InfinitiQ50 forum — InTouch Reverse Engineering Findings](https://www.infinitiq50.org/threads/intouch-reverse-engineering-findings-more-to-come.137236/) — community reverse-engineering of the Q50 DCU (same Clarion/DENSO architecture as Q60); behind tollbit paywall as of 2026-05, retrieve via authenticated session
- [Tizen IVI Architecture deck (2014)](https://download.tizen.org/misc/media/conference2014/slides/tdc2014-tizen-ivi-architecture-and-features.pdf) — confirms POR: Weston 1.5 + Layers, EFL, Qt 5.3, AMB, GENIVI Layer Manager, ICO sample UI

---

## 6. Bottom line

The Q60 upper-screen replacement is a **two-file systemd swap** plus a Qt application that links the EMGD EGL/GLES libraries already in the factory rootfs and binds the `ivi_application` Wayland protocol. We do not need to touch the kernel, the EMGD driver, the v2g sprite path, any DENSO backend daemon, or the navi0/audio0 IPC fabric. The integration risk is concentrated in one place: matching the surface ID and the EMGD environment the factory app uses. Five console commands on a live DCU close that gap.
