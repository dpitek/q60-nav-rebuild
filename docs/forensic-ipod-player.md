# Forensic — iPod / iPhone Player (`ipodplayer_ps` / iAP / MFi)

**Date:** 2026-05-23
**Source:** `/tmp/dsu-slot-a/` (extracted Slot A DSU backup) + cross-reference to existing forensics
**Subject:** How the factory Q60 head unit implements iPod / iPhone playback (browse library, now-playing, transport control, cover art, audio routing). Where the iAP (iPod Accessory Protocol) stack lives. What the MFi (Made For iPhone) coprocessor and licensing implications are for the rebuild.

---

## Executive Summary

1. **The factory iPod stack is a single closed-source DENSO daemon — `ipodplayer_ps` ("PS_IPODPLAYER") — with a statically-linked Apple-licensed iAP SDK inside it.** There is **no `libimobiledevice`, no `usbmuxd`, no `libplist`, no `libusbmuxd`, no Apple firmware blob, no MFi-specific kernel module, and no Apple VID (0x05AC) anywhere in the udev rules.** Every layer that would be open-source under a Linux/community implementation is instead collapsed into the `ipodplayer_ps` binary on the naviwork ext4 partition (which we have not extracted). This is the canonical MFi licensee pattern.

2. **`nav_ipodplayer.service` is the ONLY `nav_*.service` with `After=dbus.service udev.service`.** Every other PS daemon — `audio_ps`, `tel_proc`, `multimedia_ps`, `camera_ps`, `abs_clock`, etc. — has either `After=home-naviwork.mount`, `After=emgdhmid.service`, or no explicit `After=` at all. The dbus/udev dependency is a smoking gun: ipodplayer_ps consumes **D-Bus** (almost certainly BlueZ signals for "iPhone over Bluetooth A2DP/AVRCP" — see §6) and **udev** (for USB hotplug to detect a Lightning iPhone or 30-pin iPod plugged into the head unit's USB port). No other DENSO daemon needs either. iAP makes both unavoidable.

3. **iAP transport is USB serial.** All eight USB-serial transport modules are shipped (`cdc-acm.ko`, `ftdi_sio.ko`, `pl2303.ko`, `cp210x.ko`, etc.) plus `snd-usb-audio.ko` and `usbnet.ko`+`cdc_ether.ko`. The Apple iAP2 over USB endpoint is a vendor-class USB interface (not CDC-ACM in the strict sense) — but the kernel-side transport is generic USB bulk endpoints which ipodplayer_ps almost certainly opens directly via libusb-style raw access rather than through a tty serial driver. The presence of `snd-usb-audio.ko` is the audio half: **iPod/iPhone audio is delivered as USB Audio Class to the head unit**, not as analog over an old 30-pin dock.

4. **No MFi authentication coprocessor evidence on the host side.** No `i2c-dev.ko` is shipped (only `i2c-ocores.ko` and `i2c-xiic.ko` bus drivers); no Apple-specific I2C client driver; no userspace MFi-chip helper. The Apple Authentication Coprocessor (MFi 2.0C / 3.0 chip) is almost certainly on the board — every certified iAP2 head unit needs one — and is accessed by `ipodplayer_ps` via a generic SMBus/I2C path the binary opens directly. **We will only know the chip's I2C address (typical: 0x10 or 0x11) by running `i2cdetect` on hardware.** This is the single biggest open question for the rebuild.

5. **No CarPlay. Confirmed by absence.** No `carplay`, no `usbmuxd`, no `libimobiledevice`, no AirPlay components, no NCM-class endpoint negotiation in udev rules, no CarPlay-specific D-Bus interfaces. The DCU dates to ~2012 (PulseAudio system.pa header is dated `2012-03-23`); CarPlay launched Mar 2014 and Nissan/Infiniti did **not** ship the firmware update to bring it to 2017 Q60 DCUs. The factory iPod stack is iAP-only.

6. **The "iPod app" is not a separate UI process.** Like the clock (see [forensic-clock-service.md](forensic-clock-service.md)) and the phone dialer (see [forensic-phone-stack.md](forensic-phone-stack.md)), the iPod browse screens (Artists/Albums/Playlists/Songs/Genres), now-playing, and cover art are sub-screens of the monolithic UI screen-tree owned by `hmictrl_proc`; the status-bar source indicator is owned by `display_ps`. `ipodplayer_ps` is a headless backend daemon that publishes library + transport state on POSIX mqueues, consumed by the UI daemons via the DENSO IPC bus.

**Bottom line for the rebuild:** This is the **single hardest factory feature to replace.** Three options, in order of effort: (A) **drop iPod/iPhone-USB support entirely** — most iPhones use Bluetooth A2DP+AVRCP for audio anyway, which is a totally separate stack (BlueZ+oFono — already documented in [forensic-phone-stack.md](forensic-phone-stack.md)); (B) **keep DENSO's `ipodplayer_ps` binary alive** if it can be coaxed to run alongside our Qt6 app — preserves iAP/MFi licensing without us needing to license anything; (C) **implement iAP2 on top of `libimobiledevice`** — open-source, no Apple license fee, but unsanctioned (Apple has historically tolerated rather than blessed this path) and will lack official certification. Recommend **(A) for v1, revisit (B) for v2 once we know whether the binary can run untethered.**

---

## 1. Architecture Diagram

```
                ┌──────────────────────────────────────────────────┐
                │  iPhone / iPod (USB endpoint, Lightning or       │
                │  30-pin dock with USB cable)                     │
                │  - USB Audio Class endpoint  (music PCM out)     │
                │  - iAP2 vendor-class endpoint (control + meta)   │
                └──────────────────────────────────────────────────┘
                          │                              │
                          │ USB bulk (USB Audio Class)   │ USB bulk (iAP2 vendor class)
                          ▼                              ▼
            ┌──────────────────────────┐   ┌──────────────────────────┐
            │  snd-usb-audio.ko        │   │  Kernel USB core +       │
            │  → ALSA capture device   │   │  USB-serial generic /    │
            │  (e.g. /dev/snd/...)     │   │  libusb-style raw access │
            └──────────────────────────┘   └──────────────────────────┘
                       │                              │
                       │ ALSA PCM                     │ raw USB bulk read/write
                       ▼                              ▼
            ┌──────────────────────────┐   ┌──────────────────────────────────┐
            │  PulseAudio              │   │  ipodplayer_ps "PS_IPODPLAYER"   │
            │  (system mode)           │   │  /home/naviwork/system/bin/      │
            │  → Stereo_out sink       │◀──│  - statically-linked Apple iAP   │
            │  → speakers              │   │    SDK (closed source)           │
            └──────────────────────────┘   │  - speaks D-Bus to BlueZ (BT     │
                                           │    iAP-over-Bluetooth path)      │
                                           │  - reads /dev/i2c-N for MFi      │
                                           │    Authentication Coprocessor    │
                                           │  - publishes library / now-      │
                                           │    playing / transport state on  │
                                           │    POSIX mqueues                 │
                                           └──────────────────────────────────┘
                                                       ▲
                                                       │ I2C
                                              ┌────────┴────────┐
                                              │ MFi Auth Copro  │  (presumed on board;
                                              │ Apple chip      │   addr 0x10/0x11
                                              │ (unconfirmed)   │   typical)
                                              └─────────────────┘
                                                       │
                                                       │ DENSO IPC bus
                                                       │ (POSIX mqueues, napl)
                                                       ▼
            ┌────────────────────────────────────────────────────────────────┐
            │  UI: iPod browse screens, now-playing, cover art,              │
            │      status-bar source indicator                               │
            │      (drawn by hmictrl_proc + display_ps                       │
            │       into EmgdHmi pixmap canvas)                              │
            └────────────────────────────────────────────────────────────────┘
```

---

## 2. Layer 1 — Service Unit `nav_ipodplayer.service`

**File:** `/tmp/dsu-slot-a/lib/systemd/system/nav_ipodplayer.service`

```ini
[Unit]
Description=PS_IPODPLAYER Service
#Requires=nav_dmn2.target
Requires=nav_pre.target
OnFailure=nav_smngpret.service
DefaultDependencies=no
#After=dbus.service udev.service pulseaudio.service
After=dbus.service udev.service

[Service]
Type=simple

StandardInput=null
StandardOutput=null
StandardError=null
LimitSTACK=393216
LimitMSGQUEUE=8192000

#ExecStartPre=/bin/sh -c '/bin/echo "/home/naviwork/log/core" > /proc/sys/kernel/core_pattern'
#ExecStart=/bin/sh -c 'ulimit -c unlimited; /home/naviwork/system/bin/ipodplayer_ps "PS_IPODPLAYER"'
#ExecStart=/bin/bash /lib/systemd/system/pulse_retrychk.sh /home/naviwork/system/bin/ipodplayer_ps PS_IPODPLAYER
ExecStart=/home/naviwork/system/bin/ipodplayer_ps "PS_IPODPLAYER"

TimeoutSec=90
SendSIGKILL=yes
```

**Pulled in by:** `/tmp/dsu-slot-a/lib/systemd/system/nav_pre.target.wants/nav_ipodplayer.service` (symlink).

### 2.1 Notable properties

| Property | Value | Forensic meaning |
|---|---|---|
| `After=dbus.service udev.service` | **unique among all `nav_*.service`** | The only DENSO PS daemon with explicit dbus + udev ordering. dbus = BlueZ signals for iAP-over-Bluetooth (HFP+ media control / iAP-BT); udev = USB hotplug for Lightning/30-pin device appearance. No other PS daemon needs either. |
| Commented `pulseaudio.service` in `After=` | dropped at some point | Originally the daemon waited for PA. Production version doesn't — likely because PA was racing later, and ipodplayer_ps gained internal retry logic. Compare the `pulse_retrychk.sh` wrapper (also commented out, line 21) which other audio-touching daemons explicitly use. |
| `LimitSTACK=393216` | **384 KB — small** | Same as `tel_proc`. Half the size of `audio_ps`/`camera_ps`/`multimedia_ps` (524288 = 512 KB). Suggests a single primary worker thread + small dispatcher pool; no Qt event loop, no large gst-pipeline machinery. The iAP protocol parser is single-threaded; library browse responses are synchronous. |
| `LimitMSGQUEUE=8192000` | 8 MB | **32× the default 256 KB.** Same value as `tel_proc`, `audio_ps`, `multimedia_ps`. Heavy IPC traffic — iPod library can have 100k+ songs, returned in paged mqueue messages; now-playing metadata + cover art shovels per-track-change. |
| `Requires=nav_pre.target` | early-tier nav service | Brought up before the UI daemons so iPod state is available when UI initializes. Same ordering as `tel_proc`, `audio_ps`, `multimedia_ps`. |
| `OnFailure=nav_smngpret.service` | system-pre-reset cascade | A crash in ipodplayer_ps trips the **same global reset cascade** as a UI daemon crash. DENSO treats source-input loss as system-critical. |
| `DefaultDependencies=no` | bypasses sysinit ordering | Started explicitly by smng / napl tier, not by standard systemd dependency graph |
| `Type=simple` + no `Restart=` | crash = OnFailure fires | Unlike `abs_clock.service` which respawns; ipodplayer_ps is allowed to die once and trip the reset. Same model as `tel_proc`. |
| **No `LD_LIBRARY_PATH`** | inherits systemd default | Notable. `audio_ps`, `tel_proc` derivatives often set this. ipodplayer_ps relies on default loader path — implies the Apple iAP SDK is statically linked, not a separate `.so` dropped in `/home/naviwork/system/lib/`. |
| **No `Group=`** | inherits root | No video group needed (no rendering). No audio group (PA in system mode runs as `pulse` user but ipodplayer_ps writes to PA via socket, not /dev/snd directly). |
| stdio | null/null/null | Headless |
| `PS_IPODPLAYER` argv | DENSO napl PS naming | Process registers with smng under this name; smng can target it for signals/queries |

### 2.2 Why dbus + udev specifically

**`udev`:** iPod and iPhone are hot-pluggable. The daemon needs to know **when** a device appears on USB so it can begin the iAP detection / authentication handshake. The standard pattern is: open a Netlink udev socket (`AF_NETLINK / NETLINK_KOBJECT_UEVENT`) or subscribe to udev D-Bus signals, watch for `ACTION=add` on `SUBSYSTEM=usb` with `idVendor=05ac`, then open the device. The `After=udev.service` directive ensures the udev daemon is up before ipodplayer_ps tries to register for events.

**`dbus`:** Two plausible consumers — and the binary almost certainly does both:
- **BlueZ signals** — iAP also runs over Bluetooth (iAP2 over BT-RFCOMM, the "iAP-BT" path used when an iPhone is connected wirelessly). When an A2DP+AVRCP+iAP-BT-capable phone bonds, BlueZ publishes the iAP RFCOMM channel; ipodplayer_ps subscribes to `org.bluez.Adapter` device-added signals to learn the RFCOMM endpoint.
- **PulseAudio D-Bus** — PA exposes its sinks/sources over a per-session D-Bus interface; ipodplayer_ps can control the iPod USB-Audio source's volume and route assignment through this.

Both fit. We won't know definitively until we trace the running binary with `dbus-monitor --system` on hardware.

---

## 3. Layer 2 — Transport: USB + Kernel Modules

### 3.1 USB serial modules shipped

`/tmp/dsu-slot-a/lib/modules/2.6.37.6-…/kernel/drivers/usb/serial/`:

| Module | Role | Used by iAP? |
|--------|------|--------------|
| `cdc-acm.ko` | CDC-ACM serial-class devices | Possibly — iAP2-over-USB does present a serial-class interface on some chipsets, but the conformant path is vendor-class bulk |
| `ftdi_sio.ko` | FTDI USB-serial chips | No (third-party serial cables) |
| `pl2303.ko`, `cp210x.ko`, `ch341.ko` | Other USB-serial bridge chips | No |
| `usbnet.ko` + `cdc_ether.ko` | USB CDC Ethernet class | No (iPhone tethering — not iAP) |

**Notably absent:** `ipheth.ko` — the mainline kernel module for iPhone USB tethering. Its absence here is **not** evidence either way for iAP (different code path) but does confirm the head unit was never designed to use the iPhone as an internet bridge.

### 3.2 USB Audio Class — the music PCM path

| Module | Role |
|--------|------|
| `snd-usb-audio.ko` | USB Audio Class driver — creates ALSA capture/playback devices for USB audio peripherals |
| `snd-usbmidi-lib.ko` | USB MIDI subclass support |

**This is how iPod/iPhone audio actually reaches the speakers.** Modern iPhones (Lightning, since iPhone 5/2012) present a USB Audio Class **source** to the host — when iAP negotiates the audio session, the phone enables its USB-Audio interface descriptor, the kernel `snd-usb-audio.ko` claims it, an ALSA capture device appears, and PulseAudio's `module-alsa-source` (or a dynamic loopback module) routes the capture into the `Stereo_out` sink.

The PulseAudio system config at `/tmp/dsu-slot-a/etc/pulse/system.pa` has the comment:
```
# Changes:
#       2012-03-23:
#       - Define virtual sinks for MPP, Ipod, Bluetooth and Voice / Beep
```
…confirming iPod is treated as a **distinct audio source** in the PA topology, even though the actual virtual-sink/loopback lines below that comment have been mostly stripped from production. The live config we extracted defines only `Stereo_out`, `Monaural_out`, `Mic_in`, `BTA_in` — and ends with `### Enable Virtual Sinks ###` with no further content. The iPod-routing loopback is either set up dynamically by `ipodplayer_ps` (via `pactl load-module module-loopback source=... sink=Stereo_out`) or by `audio_ps` on demand.

### 3.3 iAP2 transport endpoint

The iAP2 protocol (Lightning, 2014+) runs over a **vendor-class USB interface** distinct from USB Audio Class. The endpoint is bulk-in/bulk-out. ipodplayer_ps almost certainly:

1. Discovers the iPhone via udev (`idVendor=05ac`),
2. Opens it through libusb's raw interface (`/dev/bus/usb/BBB/DDD`),
3. Claims the iAP2 vendor interface,
4. Speaks the iAP2 framed binary protocol (link-layer + session-layer + control messages),
5. Uses the MFi Authentication Coprocessor (§4) to satisfy the authentication challenge from the iPhone,
6. Once authenticated, requests the device to enable USB Audio Class for music playback and negotiates Music Library Access (MLA) for browse.

No part of this protocol speaks through a `tty` device — there is no `/dev/ttyACM*` or `/dev/ttyUSB*` involved in the iAP2 control path. The "iAP runs over USB serial" framing is a holdover from iAP1 (30-pin dock), which used pins 12/13 for UART/RS-232.

For iAP1 (older iPods, 30-pin), the path was: dock connector pins → USB-serial bridge chip (or direct UART on the head unit) → `/dev/ttyXXX` → ipodplayer_ps. The Q60 head unit USB-A port carries **USB only** — the iAP1 serial path would require a Lightning-to-30-pin adapter and is largely a legacy concern at this point.

---

## 4. Layer 3 — MFi Authentication Coprocessor (the critical unknown)

### 4.1 What it is

Every certified iAP2 accessory (head unit, dock, speaker) is required by Apple to contain an **Apple Authentication Coprocessor** — a small Apple-supplied IC that performs the cryptographic challenge/response Apple uses to attest that the accessory is MFi-licensed. The chip's market name is the "Apple Authentication Coprocessor 2.0C" (MFi2) or "3.0" (MFi3, current); it ships pre-provisioned with per-unit RSA keys signed by Apple's root CA.

Mechanically, it is an **I2C slave** on the accessory board, typical 7-bit addresses `0x10` or `0x11`. The host (here, ipodplayer_ps on the head unit) sends signing requests over I2C; the chip returns signed nonces; ipodplayer_ps forwards those into the iAP2 protocol to the iPhone, which validates against Apple's CA.

**Without this chip — or without `ipodplayer_ps`'s ability to talk to it — iAP2 authentication fails and the iPhone refuses the iAP session.** USB Audio Class falls back to passive playback in some cases (modern iPhones will charge and stream audio over USB-Audio without iAP), but **library browse, transport control, and metadata are gated behind iAP2 auth**.

### 4.2 Evidence in the rootfs

| Search | Result |
|---|---|
| `find -iname "*mfi*"` | None |
| `find -iname "*iap*"` | None |
| `find -iname "*apple*"` | Only `appledisplay.ko` (Cinema Display driver) and `Apple_Terminal` terminfo entry — both irrelevant |
| Modules.alias for VID 05AC | Only `appledisplay` (PIDs 0x9218-0x921D) and `asix` (USB ethernet adapter PID 0x1402) — **no iPhone PIDs** |
| `i2c-dev.ko` in modules | **Not shipped** — only bus drivers `i2c-ocores.ko` and `i2c-xiic.ko` |
| Apple-specific I2C client driver | None |
| `lib/firmware/` | Empty — no Apple firmware blobs |
| udev rules for `idVendor=05ac` | None |

The absence of `i2c-dev.ko` is interesting. Without it, no userspace `/dev/i2c-N` character device exists, so ipodplayer_ps cannot use the standard `ioctl(I2C_SLAVE)` / `read()` / `write()` userspace I2C API. Two options:

1. **DENSO ships a custom `i2c-dev.ko` on the naviwork partition** that gets `insmod`ed at boot by some script we haven't extracted yet. This is the most likely answer — DENSO has done exactly this for `bt_hci.ko` and `bt_dfu.ko` (see [forensic-phone-stack.md](forensic-phone-stack.md) §2.2).
2. **The MFi chip is wired to a non-Linux I2C bus** (e.g. a dedicated SCU/MSIC I2C bus owned by firmware, accessed via an out-of-band IPC mechanism — Crossville Lapis Tunnel Creek does have an Intel SCU IPC channel). This would be unusual but not impossible.

### 4.3 What we know we don't know

| Unknown | How to resolve |
|---|---|
| Is the MFi chip physically present on the Q60 DCU board? | Visual board inspection + I2C address scan on hardware |
| What I2C bus / address? | `i2cdetect -y N` for each N once `i2c-dev.ko` is loaded |
| What MFi version (2.0C vs 3.0)? | Read chip's WHO_AM_I register over I2C |
| Does ipodplayer_ps depend on a vendor i2c-dev driver from naviwork? | `ls /home/naviwork/system/lib/modules/` on hardware |

**This is the single biggest blocker for rebuild Option C** (open-source libimobiledevice path) — without the MFi chip, an open-source stack cannot pass iAP2 authentication. With the MFi chip but without the right userspace driver, Option B (keep DENSO binary) is also at risk.

---

## 5. Layer 4 — D-Bus + udev consumption

Recap of the unique `After=dbus.service udev.service` directive:

| Subscriber path | Purpose |
|---|---|
| **D-Bus → BlueZ signals** | Detect iAP-over-Bluetooth-RFCOMM channel availability when an iPhone bonds; iAP2-BT is the wireless path for the same library/transport features as USB. BlueZ 4.x exposes RFCOMM channels per-bonded-device on `org.bluez.Adapter` and `org.bluez.Device`. |
| **D-Bus → PulseAudio** | Programmatically load/unload `module-loopback` (or `module-alsa-source`) to route the iPhone's USB Audio Class capture device into the `Stereo_out` sink. Probably also controls per-source volume. |
| **udev → USB hotplug** | Detect iPhone/iPod USB device-add (`ACTION=add SUBSYSTEM=usb idVendor=05ac`), trigger iAP detection state machine, open the bulk-vendor interface for iAP2 control. Detect device-remove to tear down playback state and notify UI. |

The decision to depend on dbus/udev rather than embedding everything inside the DENSO bus is pragmatic: BlueZ + udev + PulseAudio are all *already* on the system for other reasons (HFP phone, USB storage automount, audio routing), and reusing them is cheaper than re-implementing.

---

## 6. Layer 5 — UI Integration

There is no separate iPod app process. Following the established pattern (see [forensic-clock-service.md](forensic-clock-service.md) §3, [forensic-phone-stack.md](forensic-phone-stack.md) §7):

- **Source-selector "iPod" tile** on the main Audio/Source screen — owned by `hmictrl_proc`
- **iPod browse screens** (Artists / Albums / Songs / Playlists / Genres / Composers / Audiobooks / Podcasts) — sub-screens of the monolithic UI screen-tree owned by `hmictrl_proc`. Library data arrives via paged mqueue messages from ipodplayer_ps; each browse-level fetch is an mqueue round-trip.
- **Now-playing screen** (title / artist / album / progress bar / transport controls) — owned by `hmictrl_proc`. Metadata pushed by ipodplayer_ps on each track change.
- **Cover art** — almost certainly delivered as JPEG bytes over mqueue (cover art images on iPods are typically 300×300 to 600×600 JPEG; well under the 8 MB mqueue limit). Decoded and blitted into the EmgdHmi pixmap canvas by `display_ps` or `hmictrl_proc`.
- **Status-bar source indicator** ("iPod" or device name) — part of the always-on chrome owned by `display_ps`.
- **Transport-control hard buttons** (steering wheel next/prev/play-pause, hard buttons on the lower screen) — CAN events handled by `ioapf_proc` → mqueue → ipodplayer_ps → iAP2 control command to the phone.

Same pattern as `multimedia_ps` for USB/SD music playback. The iPod stack is structurally a sibling of `multimedia_ps`, differing only in the **transport** (iAP2 + USB Audio Class instead of direct filesystem reads of MP3/AAC from USB mass storage).

The current factory USB-storage handling for non-iPod USB devices is documented in [`usbautomount.sh`](../tmp/dsu-slot-a/etc/udev/rules.d/usbautomount.sh) (DENSO 2012, full Japanese-comment script that mounts FAT32 USB drives onto `/android/data/system/tmp/`). That path feeds `multimedia_ps`, not `ipodplayer_ps`.

---

## 7. MFi Licensing Analysis (rebuild-critical)

### 7.1 What MFi licensing actually requires

To ship a product that **claims iPod/iPhone compatibility, displays the "Made for iPhone" mark, or uses the iAP2 protocol's authenticated features**, the manufacturer must:

1. Sign Apple's MFi license agreement (per-company, NDA-protected).
2. Source MFi Authentication Coprocessor chips from authorized distributors (Apple controls the supply).
3. Use Apple's MFi-licensee-only iAP2 SDK (under NDA, never publicly available).
4. Submit hardware for MFi certification testing (lab + Apple sign-off).
5. Pay per-unit royalties on shipped devices.

**For a personal one-off rebuild like ours, none of this is realistic.** Apple does not license MFi to individuals or hobbyists, and the SDK + chip supply chain is gated on the corporate license.

### 7.2 What Apple does NOT prevent (the gray-zone path)

The `libimobiledevice` project (open-source, GPL, started ~2008) reverse-engineered:
- iAP1's pairing/auth protocol (broken by Apple in later iOS)
- The **USB multiplexing protocol** (`usbmuxd`) that Apple's iTunes uses to talk to iOS over USB
- Various lockdown / AFC / MobileSync interfaces

`libimobiledevice` **does not implement iAP2 authentication**. iAP2 requires the MFi coprocessor's signed response to a challenge — that is the entire point of the chip. There is no software workaround; the private key material is in silicon.

What `libimobiledevice` **can** do:
- Detect an iOS device appearing on USB
- Use the **non-authenticated** USB Audio Class path (modern iPhones expose audio on USB without requiring iAP auth — they just won't expose library/control)
- Talk to the phone over `usbmuxd` for non-iAP services (file transfer, screen mirroring with proper iOS support, etc.)

For a head unit, this means: **with libimobiledevice you can play whatever audio is currently playing on the phone, but you cannot browse the library, you cannot control transport from the head unit, and you cannot fetch metadata for now-playing display.** The user must operate the phone directly.

### 7.3 What this means for our rebuild

| Option | What we get | What we lose | Effort |
|---|---|---|---|
| **A. Drop iPod/iPhone-USB entirely** | Bluetooth A2DP+AVRCP works fully (already on our path via BlueZ/oFono); USB-storage music browse works (Files-on-USB pattern) | Plugging an iPhone in by USB only charges it, no audio over USB | Zero |
| **B. Keep DENSO `ipodplayer_ps` running** | Full iAP feature parity; uses factory MFi chip; legal | Tied to naviwork partition; opaque crash behavior; cannot debug; binary may have hard-coded assumptions about other PS daemons | Medium — requires we keep dbus, BlueZ, PA, the MFi i2c-dev, and naviwork ext4 alive, AND not contend with the daemon for IPC |
| **C. Implement iAP2 on libimobiledevice + something** | Open-source; full control | **Cannot pass MFi auth without the SDK + chip access** → library browse / transport unavailable. Audio-only fallback works. Possible legal exposure if redistributed widely (Apple has historically tolerated, but never blessed). | High — and the deliverable is functionally inferior to (B) |

**Recommendation: A for v1, plan B for v2.** Most users connect iPhones via Bluetooth in 2026 anyway — A2DP+AVRCP gives them library browse and transport on the phone screen, audio in the car, and the head unit displays track metadata via AVRCP. The USB-iPod use case is a 2010s legacy feature; dropping it is acceptable for a v1 rebuild. If demand exists later, investigate keeping `ipodplayer_ps` alive in a constrained sandbox.

---

## 8. Plan B''' Kill Set Implications

Per [project_planB_kill_set.md](../../../.claude/projects/-Users-dpitek-Developer-q60-rebuild/memory/project_planB_kill_set.md), the current kill set is `navi_ps` + `dispapf_proc`. iPod plan additions depend on chosen option:

### Option A (drop iPod entirely)
- **Mask `nav_ipodplayer.service`** — prevent contention for USB device claiming and PA loopback modules
- Document in the kill set as "iPod playback unsupported; use Bluetooth A2DP"
- No changes to `bluetoothd`, `ofonod`, `pulseaudio.service`

### Option B (keep DENSO binary)
- **Do NOT mask `nav_ipodplayer.service`**
- **Must keep `dbus.service`, `udev.service`, `bluetooth.service`, `pulseaudio.service` alive** (already required for phone)
- **Must keep the naviwork ext4 partition mounted** (binary lives there)
- **Must NOT kill `audio_ps`** (PA routing partner for the iPod audio path)
- **Must investigate any naviwork-side `i2c-dev.ko` loader script** and preserve it
- Risk: ipodplayer_ps publishes UI events via the DENSO mqueue bus to UI daemons we are replacing. We will need to either subscribe to those mqueues ourselves (and reverse-engineer the message shapes) or ignore iPod-related mqueue traffic. **Subscribing is the only way to actually display iPod info in our UI.**

### Option C (libimobiledevice)
- **Mask `nav_ipodplayer.service`**
- Add `usbmuxd` + `libimobiledevice` to Slot B userspace
- Audio-only playback; no UI changes beyond detecting "iPhone connected"

---

## 9. Open Questions (resolvable only with naviwork partition + live hardware)

1. **MFi coprocessor presence and address.** Is the chip physically on the DCU board? What I2C bus? What address? `i2cdetect -l && i2cdetect -y N` for each bus on hardware.
2. **MFi access mechanism.** Does ipodplayer_ps open `/dev/i2c-N` (standard userspace I2C), or does it call into a naviwork-only kernel driver, or does it use Intel SCU IPC (Tunnel Creek MSIC)? `strace -f -e trace=open,openat -p $(pidof ipodplayer_ps)` on hardware.
3. **iAP version.** iAP1 (legacy 30-pin), iAP2 (Lightning), or both? Look for both code paths in the binary via `strings`.
4. **USB Audio Class confirmation.** When an iPhone is plugged in on hardware, does `arecord -l` show a USB Audio capture device? Does `pactl list short sources` include it?
5. **mqueue protocol details.** What queue names does ipodplayer_ps use? What is the library-browse message shape? Library-paged-response format? Required to implement Option B subscriber path.
6. **D-Bus consumer breakdown.** `dbus-monitor --system` on hardware while ipodplayer_ps is running — confirm BlueZ subscription, confirm PA subscription. Are there other D-Bus services involved?
7. **Bluetooth iAP path.** Does ipodplayer_ps handle iAP-over-Bluetooth too, or does that get delegated to `tel_proc`? (The dbus dependency suggests yes; need to confirm.)
8. **CarPlay absolute confirmation.** Look at the head unit's option/firmware code in `/etc` and on naviwork. Highly unlikely but worth one grep.
9. **Naviwork-side MFi i2c loader.** Is there a `Wants=` or `BindsTo=` that brings in a vendor i2c-dev loader before `nav_ipodplayer.service`? Examine `nav_pre.target.wants/` and any unit files we haven't grep'd.

All resolvable in ~1 hour once the naviwork ext4 is mounted and the car is on the bench powered up.

---

## 10. Cross-references

- [forensic-clock-service.md](forensic-clock-service.md) — symmetric architecture pattern: headless backend daemon + UI region rendered by hmictrl_proc/display_ps, never a standalone "app"
- [forensic-phone-stack.md](forensic-phone-stack.md) — DENSO vendor kernel driver pattern (`bt_hci.ko` / `bt_dfu.ko`); BlueZ 4.x D-Bus API; the "DENSO daemon mediates D-Bus ↔ mqueue" architecture that ipodplayer_ps mirrors
- [forensic-daemon-supervision.md](forensic-daemon-supervision.md) — `nav_pre.target` ordering; `OnFailure=nav_smngpret.service` reset cascade semantics; ipodplayer_ps fits the "fatal crash → trip cascade" pattern
- [forensic-denso-ipc.md](forensic-denso-ipc.md) — POSIX mqueue + napl conventions ipodplayer_ps uses to publish library/now-playing state to UI daemons
- [forensic-factory-ui-binary.md](forensic-factory-ui-binary.md) — confirms ipodplayer_ps lives on naviwork partition (line 48), inaccessible to us without that partition; hmictrl_proc + display_ps render all UI including iPod browse screens
- [feature-parity-audit.md](feature-parity-audit.md) — visible iPod features we may or may not preserve depending on chosen option
- [project_planB_kill_set.md](../../../.claude/projects/-Users-dpitek-Developer-q60-rebuild/memory/project_planB_kill_set.md) — current Plan B''' kill set; iPod additions per chosen option in §8 above
