# Forensic — Phone / Bluetooth Hands-Free Stack

**Date:** 2026-05-23
**Source:** `/tmp/dsu-slot-a/` (extracted Slot A DSU backup) + cross-reference to existing forensics
**Subject:** How the factory Q60 head unit implements the in-vehicle phone (HFP) — kernel-to-UI layer breakdown, vendor vs. mainline components, audio routing, and the rebuild path.

---

## Executive Summary

1. **The factory phone is a five-layer standard Linux IVI telephony stack with a DENSO glue daemon on top.** Kernel BT driver → BlueZ 4.x → oFono 0.48 → `tel_proc` (DENSO) → monolithic UI chrome. Nothing exotic. Every layer except the kernel BT driver is open-source and still maintained today.

2. **The Bluetooth chip is on a UART and requires DENSO's vendor HCI driver `bt_hci.ko`.** Mainline `hci_uart.ko` is shipped but unused. The chip also requires firmware download at boot via a separate `bt_dfu.ko` char device (`/dev/bt_dfu`, mode 666) and the init script [`bt_dfu_inst.sh`](../tmp/dsu-slot-a/lib/systemd/system/systemdRelatedFiles/bt_dfu_inst.sh) — which has Japanese error strings (`module がloadできません`), confirming DENSO authorship. This is the only layer with no clean open-source replacement on this specific hardware.

3. **BlueZ 4.96-era (`libbluetooth.so.3.10.3`), `[Headset] HFP=true`, SCO routing via HCI.** Standard 2011 MeeGo/IVI configuration. Car is the HFP-HF (Hands-Free unit); paired phone is HFP-AG (Audio Gateway). Audio comes back through the BT chip into ALSA → PulseAudio → speakers, **not** a direct PCM bypass — the entire call audio path runs in userspace.

4. **oFono 0.48 (`/usr/sbin/ofonod`) sits between BlueZ and DENSO.** It exposes the paired phone as a D-Bus "modem" object with call state, contacts (PBAP), signal strength, operator, battery. This is the standard MeeGo-era telephony framework — same code that ran on Nokia N9.

5. **`tel_proc` is a D-Bus ↔ DENSO-mqueue translator.** `nav_tel.service` runs `/home/naviwork/system/bin/tel_proc "PS_TEL"` with `LimitMSGQUEUE=8192000` (**32× the default** — heavy IPC traffic) and `OnFailure=nav_smngpret.service` (phone crash trips the system-pre-reset cascade — DENSO treats telephony as system-critical). It subscribes to ofono D-Bus signals, republishes events on POSIX mqueues for the UI daemons (`hmictrl_proc` for the incoming-call modal, `display_ps` for status bar icons, `audio_ps` for SCO routing), and translates dial/answer/hang-up requests the other direction.

6. **The "phone app" is not a separate process.** Like the clock (see [forensic-clock-service.md](forensic-clock-service.md)), the dialer / contacts / recent-calls / in-call screens are rendered by `hmictrl_proc` as additional screens in the monolithic UI's screen tree. Mockup of the visible result: [docs/mockups/05-phone-view.svg](mockups/05-phone-view.svg).

**Bottom line for the rebuild:** Replace BlueZ 4 → BlueZ 5, oFono 0.48 → oFono current, `tel_proc` → ~1 day of Qt6 C++ consuming ofono D-Bus directly, `module-cork-music-on-phone.so` → PipeWire role-based ducking or PA `module-role-cork`. **Keep `bt_hci.ko` + `bt_dfu.ko` unchanged** — Plan B''' keeps the factory kernel, so the chip keeps working without us writing a single line of kernel code.

---

## 1. Architecture Diagram

```
┌──────────────────────────────────────────────────────────────────────┐
│  UI: dialer / contacts / in-call modal / status bar phone icon       │
│      (drawn by hmictrl_proc + display_ps into EmgdHmi pixmap canvas) │
└──────────────────────────────────────────────────────────────────────┘
                          ▲ POSIX mqueue (DENSO IPC bus)
                          │ call state events, dial requests, etc.
┌──────────────────────────────────────────────────────────────────────┐
│  tel_proc "PS_TEL"   /home/naviwork/system/bin/tel_proc              │
│  (DENSO glue daemon — D-Bus client ↔ mqueue publisher)               │
└──────────────────────────────────────────────────────────────────────┘
                          ▲ system D-Bus
                          │ org.ofono.* signals & methods
┌──────────────────────────────────────────────────────────────────────┐
│  ofonod 0.48   /usr/sbin/ofonod                                      │
│  - HFP-HF plugin (paired phone presented as "modem" D-Bus object)    │
│  - PBAP for phonebook                                                │
└──────────────────────────────────────────────────────────────────────┘
                          ▲ system D-Bus
                          │ org.bluez.* signals & methods
┌──────────────────────────────────────────────────────────────────────┐
│  bluetoothd 4.96   /usr/sbin/bluetoothd  (libbluetooth.so.3.10.3)    │
│  - GAP / SDP / HFP gateway service registration                      │
│  - Pairing / bonding / SDP                                           │
└──────────────────────────────────────────────────────────────────────┘
                          ▲ HCI socket (AF_BLUETOOTH)
┌──────────────────────────────────────────────────────────────────────┐
│  bt_hci.ko     (DENSO vendor HCI driver — UART transport)            │
│  bt_dfu.ko     (firmware download char device, /dev/bt_dfu)          │
└──────────────────────────────────────────────────────────────────────┘
                          ▲ UART (SoC UART → BT chip)
                  ┌───────────────────────┐
                  │   Bluetooth chip      │  (vendor unknown, on board)
                  │   needs FW at boot    │
                  └───────────────────────┘

Parallel audio path (SCO over HCI):
                  BT chip ━━HCI SCO━▶ kernel ━▶ ALSA ━▶ PulseAudio ━▶ speakers
                                                          │
                                                          └─ module-cork-music-on-phone
                                                             auto-pauses media on incoming
```

---

## 2. Layer 1 — Kernel BT driver (DENSO vendor)

### 2.1 Custom modules

| Path | Role | Mainline equivalent | Notes |
|------|------|---------------------|-------|
| `/lib/modules/2.6.37.6-…/kernel/drivers/bt_hci/bt_hci.ko` | DENSO HCI transport over UART | `hci_uart.ko` (present, unused) | The active driver. Chip needs vendor init sequence not in mainline. |
| `/lib/modules/2.6.37.6-…/kernel/drivers/bt_dfu/bt_dfu.ko` | Char device for firmware push | None | Creates `/dev/bt_dfu`. Firmware download path. |

### 2.2 Firmware download init

**File:** `/tmp/dsu-slot-a/lib/systemd/system/systemdRelatedFiles/bt_dfu_inst.sh`

```sh
#!/bin/sh
module="bt_dfu"
device="bt_dfu"
mode="666"

rmmod $module > /dev/null 2>&1
insmod /lib/modules/`uname -r`/kernel/drivers/$module/$module.ko
major=$(awk "\$2==\"$module\" {print \$1}" /proc/devices)
if [ -z "$major" ]
then
    echo "$module がloadできません。"   # ← Japanese: "$module cannot load."
    exit 1
fi
rm -f /dev/$device
mknod /dev/$device c $major 0
chmod 666 /dev/$device
exit 0
```

This script (a) removes the bt_dfu module if present, (b) inserts it fresh, (c) creates `/dev/bt_dfu` char device with the dynamically-assigned major. The actual firmware push (which firmware blob, what protocol) happens in whatever userspace tool opens `/dev/bt_dfu` next — likely a small DENSO binary on the naviwork partition that runs once at boot to flash the chip with its operational firmware blob.

### 2.3 Mainline BT modules (present but inert)

`/lib/modules/.../kernel/drivers/bluetooth/`:
- `bcm203x.ko` — Broadcom USB
- `bfusb.ko` — Digianswer USB
- `bpa10x.ko` — Digianswer USB BPA 100/105
- `btmrvl.ko`, `btmrvl_sdio.ko` — Marvell SDIO
- `btsdio.ko` — Generic SDIO
- `hci_uart.ko` — mainline UART transport
- `hci_vhci.ko` — virtual HCI (testing)

None match the actual Q60 BT chip. They are shipped because Wind River's BSP includes them in the default module set; they never load.

### 2.4 What this means for the rebuild

**Plan B''' keeps the factory kernel** (per [project_strategic_pivot_back_to_r1.md](../../../.claude/projects/-Users-dpitek-Developer-q60-rebuild/memory/project_strategic_pivot_back_to_r1.md)). Therefore `bt_hci.ko` + `bt_dfu.ko` + the DENSO firmware-flash userspace binary keep working unchanged. We do not need to know how the chip works, what its model is, or how its firmware is encoded — we just leave the kernel and the flash-binary alone.

**Fallback option if BT ever breaks under us:** USB BT dongle under the dash → mainline kernel `btusb` claims it → ignore the DENSO chip entirely. Adds hardware but removes kernel-coupling risk.

---

## 3. Layer 2 — BlueZ 4.x

### 3.1 Daemon

| File | Notes |
|------|-------|
| `/usr/sbin/bluetoothd` | The daemon |
| `/usr/lib/libbluetooth.so.3.10.3` (→ `.so.3`) | Library; SONAME 3 = BlueZ 4.x ABI; minor 10.3 ≈ BlueZ 4.96 (late 2011) |
| `/etc/dbus-1/system.d/bluetooth.conf` | D-Bus policy file |
| `/lib/udev/rules.d/97-bluetooth.rules` + `97-bluetooth-hid2hci.rules` | udev rules for BT device hotplug |
| `/lib/systemd/system/bluetooth.target` | Target pulled in by services that need BT up |

### 3.2 `/etc/bluetooth/main.conf` — car-kit config

```ini
[General]
Name = %h-%d                       # adapter name = hostname-id
Class = 0x000100                   # generic computer
DiscoverableTimeout = 0            # always discoverable
PairableTimeout = 0                # always pairable
PageTimeout = 8192                 # half of default 16384
DiscoverSchedulerInterval = 0      # controller default
InitiallyPowered = false           # OFF at boot — tel_proc powers on demand
RememberPowered = false            # do not auto-power based on last state
ReverseServiceDiscovery = true
NameResolving = true
DebugKeys = false
EnableLE = false                   # classic BT only — no BLE
AttributeServer = false            # no GATT
DisablePlugins=hal                 # MeeGo removed hald
```

Five settings are car-kit telltales:
- `DiscoverableTimeout = 0` + `PairableTimeout = 0` — never time out; the user can always pair a new phone
- `InitiallyPowered = false` + `RememberPowered = false` — chip stays off until tel_proc decides to power it (probably gated on ACC-ON + a settings flag)
- `EnableLE = false` + `AttributeServer = false` — no BLE because nothing on this car uses it; smaller attack surface, lower power

### 3.3 `/etc/bluetooth/audio.conf` — call audio routing

```ini
[General]
Enable=Gateway                      # enable HFP-AG service registration
# SCORouting=PCM                    # commented → default is HCI
# AutoConnect=true                  # commented → default true

[Headset]
HFP=true                            # HFP enabled (not just HSP)
MaxConnected=1                      # one phone at a time
FastConnectable=false               # standard page scan
```

**Critical detail:** `Enable=Gateway` enables HFP service registration so the car shows up to phones as a hands-free device. SCO routing default = HCI means **call audio travels over the HCI socket through the kernel into ALSA**, not directly through a PCM-bypass. This means everything is software-routable — PulseAudio can ducking, equalize, redirect to whichever output (speakers vs. headphone-only).

### 3.4 `/etc/bluetooth/rfcomm.conf`

All entries commented. No persistent RFCOMM bindings — channels are negotiated dynamically per pairing.

### 3.5 Pairing storage

`/tmp/dsu-slot-a/opt/var/lib/bluetooth/` — present but empty in the backup (likely populated on a paired DCU; cleared in the backup or never paired). Pairing keys live here per BT controller MAC.

---

## 4. Layer 3 — oFono 0.48

### 4.1 Components

| File | Role |
|------|------|
| `/usr/sbin/ofonod` | The telephony daemon |
| `/etc/ofono/phonesim.conf` | Phone simulator config (dev tool — irrelevant in production) |
| `/etc/dbus-1/system.d/ofono.conf` | D-Bus policy |
| `/usr/share/doc/ofono-0.48/` | Docs — confirms version 0.48 (released ~Q4 2011) |
| `/usr/share/man/man8/ofonod.8.gz` | Manpage |

### 4.2 What oFono does in this stack

oFono is the standard Linux telephony framework (originally Nokia/Intel for MeeGo, now community-maintained). On a phone, it talks to a cellular modem; on a car, it uses the **HFP plugin** to talk to a paired phone over BT-HFP and presents that phone as a standard ofono modem object on D-Bus.

D-Bus interfaces ofono publishes per paired phone:
- `org.ofono.Modem` — modem online/offline, features supported
- `org.ofono.VoiceCallManager` — list of active calls, Dial(), HangupAll()
- `org.ofono.VoiceCall` (per call) — state (incoming/dialing/active/held/disconnected), line ID
- `org.ofono.NetworkRegistration` — operator name, signal strength
- `org.ofono.Phonebook` — PBAP-downloaded contacts (vCard format)
- `org.ofono.CallVolume` — speaker/mic volume, mute
- `org.ofono.Handsfree` — HFP-specific state (battery charge, voice recognition trigger)
- `org.ofono.MessageManager` — SMS (if the phone supports HFP+ MAP)

`tel_proc` is an ofono D-Bus client.

### 4.3 Why this matters

oFono is **still actively maintained** (version 1.34+ as of 2025) and its D-Bus API has been stable for over a decade. Migrating from 0.48 → current is mostly painless because the client-facing API surface barely changed. The hard part (HFP-HF state machine, AT command parsing, SCO setup race conditions) is already done.

---

## 5. Layer 4 — Audio routing (PulseAudio 1.1)

### 5.1 BT modules shipped with PA

`/tmp/dsu-slot-a/usr/lib/pulse-1.1/modules/`:
| Module | Role |
|--------|------|
| `libbluetooth-ipc.so` | IPC to bluetoothd |
| `libbluetooth-util.so` | utilities (SDP parsing, etc.) |
| `libbluetooth-sbc.so` | SBC audio codec (A2DP) |
| `module-bluetooth-discover.so` | Auto-discover BT devices |
| `module-bluetooth-device.so` | Per-device source/sink module |
| `module-bluetooth-proximity.so` | Proximity-based audio routing (unused here) |
| **`module-cork-music-on-phone.so`** | **Auto-pause media on incoming call** |

The last module is the killer one — that's the "music ducks when a call comes in" behavior. It listens for ofono call-state signals on D-Bus, and when a call goes active it sends a `cork` request to media-role sinks (music playback). When the call ends, it un-corks. This is **system-policy behavior implemented in the audio stack**, not in tel_proc or the UI.

### 5.2 Call audio path

```
Phone (HFP-AG) → BT chip → bt_hci.ko (SCO frames over HCI) → kernel SCO socket
    → BlueZ → PA module-bluetooth-device (creates source + sink) → ALSA → speakers/mic
```

Mic capture path is the mirror: ALSA capture → PA → BlueZ → bt_hci.ko → BT chip → Phone.

---

## 6. Layer 5 — `tel_proc` (DENSO glue daemon)

### 6.1 Service unit

**File:** `/tmp/dsu-slot-a/lib/systemd/system/nav_tel.service`

```ini
[Unit]
Description=Tel Process Service
Requires=nav_pre.target
OnFailure=nav_smngpret.service
DefaultDependencies=no

[Service]
Type=simple

StandardInput=null
StandardOutput=null
StandardError=null
LimitSTACK=393216
LimitMSGQUEUE=8192000

ExecStart=/home/naviwork/system/bin/tel_proc "PS_TEL"

TimeoutSec=90
SendSIGKILL=yes
```

**Pulled in by:** `/lib/systemd/system/nav_pre.target.wants/nav_tel.service`.

### 6.2 Notable properties

| Property | Value | Forensic meaning |
|---|---|---|
| `LimitMSGQUEUE=8192000` | 8 MB | **32× the default 256 KB.** Heavy POSIX mqueue traffic — tel_proc shovels per-event messages to multiple UI daemons in parallel |
| `LimitSTACK=393216` | 384 KB | Small — no Qt event loop, no large thread pool |
| `OnFailure=nav_smngpret.service` | system-pre-reset cascade | DENSO treats phone-stack crash as a **system-critical event** (same as the 4 UI daemons). A phone crash trips the same "reset everything" path as a UI crash. |
| `Requires=nav_pre.target` | early-tier nav service | Brought up before the UI daemons so call state is available when the UI initializes |
| `DefaultDependencies=no` | bypasses standard ordering | Started by smng explicitly, not by sysinit ordering |
| stdio | null/null/null | Headless |
| `Type=simple` + no `Restart=` | one-shot crash = `OnFailure` fires | Unlike abs_clock which respawns, tel_proc is allowed to die once and trigger the reset cascade |
| `PS_TEL` argv | DENSO napl PS naming | Process is registered with smng under that PS name; smng can target it for signals/queries |
| Commented `core_pattern` | core dump capture in dev builds | Production drops core; dev builds wrote cores to `/home/naviwork/log/core` |

### 6.3 Inferred behavior

(Binary lives on naviwork ext4, not yet extracted. Behavior inferred from service config + ofono+BlueZ D-Bus API + DENSO IPC conventions in [forensic-denso-ipc.md](forensic-denso-ipc.md).)

**At startup:**
1. napl registration as `PS_TEL` with smng
2. Open POSIX mqueues for publish (call events to UI) and subscribe (UI commands to tel_proc)
3. Connect to system D-Bus
4. Register for ofono and BlueZ signals
5. Wait for ACC-ON + settings-enabled flag → call BlueZ `Adapter.SetProperty(Powered, true)` to power the chip

**Per ofono event → mqueue translation:**
- `org.ofono.VoiceCallManager.CallAdded` → mqueue msg to hmictrl_proc → draws incoming-call modal
- `org.ofono.VoiceCall.PropertyChanged(State=active)` → mqueue msg to display_ps → status bar phone icon updates; mqueue msg to audio_ps → confirm SCO route up
- `org.ofono.NetworkRegistration.PropertyChanged(Strength=…)` → mqueue msg to display_ps → bar count updates
- `org.ofono.Phonebook.Import` complete → mqueue msg to hmictrl_proc → contacts screen refreshes

**Per UI command → ofono method call:**
- mqueue msg from hmictrl_proc "dial +15555551234" → `org.ofono.VoiceCallManager.Dial("+15555551234", "")`
- mqueue msg from hmictrl_proc "answer" → `org.ofono.VoiceCall.Answer()` on the incoming call
- mqueue msg from hmictrl_proc "hangup" → `org.ofono.VoiceCall.Hangup()`

### 6.4 Why DENSO bothered writing `tel_proc` at all

Three reasons:
1. **Protocol impedance.** The UI daemons speak DENSO mqueue + napl. ofono speaks D-Bus. A translator is necessary unless every UI daemon embeds a D-Bus client (which would bloat them and create a D-Bus dependency on the otherwise-D-Bus-free napl stack).
2. **State coalescing.** ofono is event-noisy (many small signals). tel_proc can debounce / batch / filter to reduce IPC pressure on UI daemons.
3. **Policy.** Decide when to actually power the BT chip, when to auto-reconnect to last-paired phone, when to refuse a call (driver-mode lockout), etc. Policy lives in tel_proc, not in ofono.

---

## 7. The "phone app" UI

There is no separate phone app process. Identical pattern to the clock (see [forensic-clock-service.md](forensic-clock-service.md) §3):

- **Dialer / contacts / recent calls / settings** screens are sub-screens of the monolithic UI screen-tree owned by `hmictrl_proc`
- **Status-bar phone icon** (connected/disconnected, signal strength, in-call indicator) is part of the always-on chrome owned by `display_ps`
- **Incoming-call modal** is a popup layer (`EMGD_POPUP_BUFFER=3` per the [forensic-factory-ui-binary.md](forensic-factory-ui-binary.md) pixel-buffer taxonomy) drawn over the active app screen
- **Voice dial trigger** comes from the steering wheel button (a CAN event handled by `ioapf_proc`) → mqueue → tel_proc → ofono `Handsfree.RequestVoiceRecognition()`

Mockup of the visible result: [docs/mockups/05-phone-view.svg](mockups/05-phone-view.svg).

---

## 8. Rebuild Implications

### 8.1 Layer-by-layer replacement plan

| Factory | Replacement | Effort | Notes |
|---|---|---|---|
| `bt_hci.ko` + `bt_dfu.ko` + DENSO firmware flasher | **Unchanged** — keep factory kernel | None | Plan B''' keeps the kernel |
| `bluetoothd` 4.96 (`/usr/sbin/bluetoothd`) | **BlueZ 5.x current** | None — distro package | API/D-Bus compatible for our needs |
| `ofonod` 0.48 (`/usr/sbin/ofonod`) | **oFono current** (~1.34+) | None — distro package | HFP-HF plugin unchanged in shape |
| `tel_proc` | **Small Qt6 `PhoneManager` C++ service** consuming ofono D-Bus directly via Qt D-Bus | ~1 day | Drops the DENSO mqueue bus entirely; UI consumes phone state from the same QObject |
| `hmictrl_proc` dialer/contacts/calls screens | **Qt6 QML screens in monolithic nav app** | normal UI work | Mockup at [docs/mockups/05-phone-view.svg](mockups/05-phone-view.svg) |
| `display_ps` phone status-bar widget | **QML status-bar item** in app chrome | trivial | Bind to PhoneManager signals |
| `module-cork-music-on-phone.so` (PA) | **PipeWire role-cork policy** OR PA `module-role-cork` | ~half-day | Standard pattern in modern Linux audio |
| `audio.conf SCO over HCI` | **Same default in BlueZ 5** | None | No change needed |
| Steering wheel voice-trigger button | CAN handler → invoke ofono `RequestVoiceRecognition` | normal CAN work | Part of the broader CAN integration |

### 8.2 What we lose if we don't extract `tel_proc`

Without disassembling the binary we will not know:
1. **Auto-reconnect policy.** When the car wakes up, does it auto-reconnect to last-paired? Or wait for the user? Probably auto — that's standard car-kit behavior — but should be confirmed.
2. **Driver-mode call lockout.** Does tel_proc refuse outgoing dial above some speed? Some Nissan products do this; depends on the CAN-bus vehicle-speed integration.
3. **Phonebook sync trigger.** Is PBAP download on every connect, or only on first pair? Affects perceived connect speed.
4. **Mqueue protocol details.** If we ever want to *keep* tel_proc and intercept it (a "blue-wire" approach), we'd need the queue names and message structs. With our chosen direction (replace tel_proc), we don't need this.

All four are policy questions we can answer ourselves with sensible defaults in the rebuild.

### 8.3 What stays in the kill set

Per [project_planB_kill_set.md](../../../.claude/projects/-Users-dpitek-Developer-q60-rebuild/memory/project_planB_kill_set.md), the current kill set is `navi_ps` + `dispapf_proc`. Telephony plan additions:

- **Add `nav_tel.service` to mask list** — we are replacing tel_proc, do not let it run and contend
- **Leave `bluetoothd` alive** — keep BlueZ 4 running if we don't ship our own; otherwise replace the binary and the .service unit
- **Leave `ofonod` alive** — same logic; we want it running, just possibly newer
- **Leave PulseAudio alive** — same logic; we will reconfigure cork policy rather than replace PA

If/when we ship a newer BlueZ + oFono, we replace the binaries in place on Slot B and leave the systemd unit names unchanged.

### 8.4 Risks

1. **BT chip firmware path.** If the DENSO userspace flasher (whichever binary opens `/dev/bt_dfu` at boot) lives on the naviwork partition and we accidentally kill it via service masking, BT won't initialize. **Action:** identify and preserve the flasher service before masking anything BT-adjacent.
2. **BlueZ 4 → 5 ABI break.** Some D-Bus paths/interfaces changed names (`org.bluez.Adapter` → `org.bluez.Adapter1`, etc.). The change is well-documented but means a clean rewrite of the D-Bus client code, not a port.
3. **HCI SCO over the kernel SCO socket** is occasionally flaky on older kernels under load. The factory kernel is 2.6.37 — if we ever upgrade the kernel later, we should specifically regression-test HFP audio.

---

## 9. Open Questions (resolvable only with naviwork partition + live device tests)

1. **BT chip model and firmware blob.** Where does the firmware come from on disk? `/lib/firmware/`? A blob compiled into the DENSO flasher binary?
2. **Pairing UX.** How does the user enter the BT PIN? Touchscreen keypad? PIN displayed on the LVDS for confirmation? (BlueZ 4 supports SSP — Secure Simple Pairing — and the car-kit pattern is usually "auto-accept any pairing while in pairing mode")
3. **Multiple pairings.** How many phones can be remembered? Modern phones expect 5-10. Need to check tel_proc behavior.
4. **A2DP support.** `audio.conf` enables Gateway (HFP) but is silent on whether A2DP is also enabled. The PA `libbluetooth-sbc.so` module is present, which implies A2DP support exists. Need to confirm in tel_proc behavior.
5. **Voice quality settings.** Wide-band HFP (mSBC codec) vs. narrow-band? Affects perceived call quality on modern phones; depends on BlueZ + chip firmware capabilities.

---

## 10. Cross-references

- [forensic-clock-service.md](forensic-clock-service.md) — symmetric architecture: backend daemon + UI region, not an "app"
- [forensic-daemon-supervision.md](forensic-daemon-supervision.md) — `nav_pre.target` ordering, smng cascade, `OnFailure=nav_smngpret.service` semantics
- [forensic-denso-ipc.md](forensic-denso-ipc.md) — POSIX mqueue + napl conventions used by tel_proc to talk to UI daemons
- [forensic-factory-ui-binary.md](forensic-factory-ui-binary.md) — proof that hmictrl_proc/display_ps own all UI rendering; EmgdHmi pixmap canvas; popup buffer for incoming-call modal
- [feature-parity-audit.md](feature-parity-audit.md) — visible phone features we must preserve
- [docs/mockups/05-phone-view.svg](mockups/05-phone-view.svg) — target UI mockup
- [DSU_OEM_DOCUMENTATION.md](DSU_OEM_DOCUMENTATION.md) — vehicle-bus integration (speed for driver-mode lockout, steering-wheel button events)
