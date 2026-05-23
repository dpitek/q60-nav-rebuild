# Forensic — Audio Stack (`audio_ps` / `snd` / `sndamp` / PulseAudio / GStreamer / LAPIS I2S)

**Date:** 2026-05-23
**Source:** `/tmp/dsu-slot-a/` (extracted Slot A DSU backup) + cross-references to existing forensics
**Subject:** How the factory Q60 head unit produces sound — kernel I2S transport, ALSA card layout, system-mode PulseAudio with four hard-wired ALSA endpoints, GStreamer 0.10 + DENSO-licensed TMC codec plugins, the three DENSO daemons (`audio_ps`, `snd`, `sndamp`) that orchestrate music / chimes / amplifier control, and the rebuild path.

---

## Executive Summary

1. **One SoC sound card, four sub-devices, three DENSO daemons, no D-Bus on the audio control plane.** The factory routes all audio through a single ALSA card on the LAPIS ML7213 IOH I2S bus (`snd-ml7213ioh-d3s.ko`), sliced into four sub-devices: stereo sink (s0,0), monaural sink (s0,1), mic source (s0,2), and a BT-audio source (s0,4). PulseAudio 1.1 runs in `--system` mode and binds exactly those four endpoints in [`/etc/pulse/system.pa`](../tmp/dsu-slot-a/etc/pulse/system.pa). Above PA, three small DENSO daemons specialize: `audio_ps` (media + virtual sinks + GStreamer), `snd` (system chimes / beeps), `sndamp` (external amplifier control). They talk to the UI over POSIX mqueue per [forensic-denso-ipc.md](forensic-denso-ipc.md), not D-Bus — the audio stack does not consume `org.pulseaudio` D-Bus from PA either; that interface is loaded (`module-dbus-protocol access=local`) but only as a side channel.

2. **All DENSO codecs are licensed binary GStreamer 0.10 plugins prefixed `TMC_Gst*`.** [`/usr/lib/gstreamer-0.10/`](../tmp/dsu-slot-a/usr/lib/gstreamer-0.10/) contains eight DENSO/TMC plugins (`libTMC_GstAACDec.so`, `libTMC_GstMP3Dec.so`, `libTMC_GstWMADec.so`, `libTMC_GstASFDemux.so`, `libTMC_GstMP4Demux.so`, `libTMC_GstID3Demux.so`, `libTMC_GstAudioConvert.so`, `libTMC_GstReSample.so`) alongside ~106 stock GStreamer plugins. **There is no FFmpeg, no libav, no LAME, no faad.** DENSO ships its own patent-licensed codec set rather than route around the MP3/AAC royalty payments — meaning the rebuild has to bring its own codec answer (modern Linux: GStreamer 1.x + `gst-libav` or `gst-plugins-bad`, or just punt to ffmpeg/libavcodec directly).

3. **`audio_ps` is the only nav daemon with `/usr/lib/wsegl:` in its LD_LIBRARY_PATH that also pilots GStreamer pipelines.** Per [`nav_audio.service`](../tmp/dsu-slot-a/lib/systemd/system/nav_audio.service), the env is `…:/usr/lib:/usr/local/lib:/usr/lib/wsegl:` — same wsegl-hmi path that the 4 UI daemons documented in [forensic-factory-ui-binary.md](forensic-factory-ui-binary.md) need to draw onto the EmgdHmi pixmap canvas. (Five services share this pattern: `nav_audio`, `nav_dsn`, `nav_hmictrl`, `nav_soft_vup`, `nav_systemlogd`. The other two non-UI services that link wsegl — `nav_dsn`, `nav_soft_vup`, `nav_systemlogd` — likely do it to render service-level dialogs.) Audio is the only one of those that also has `GST_REGISTRY_UPDATE=no` set and a `pulse_retrychk.sh` wrapper history → it manages the GStreamer registry and a PulseAudio dependency.  **What `audio_ps` likely renders: source-switch popups, USB-connected toasts, "now playing" overlays, and the video surface for `multimedia_ps` (which has the same wsegl requirement implicitly through its own pixmap path).** `snd` and `sndamp` do NOT have wsegl — they are headless.

4. **The virtual-sink layer is loaded by `audio_ps` at runtime via PA native protocol, not by `system.pa`.** The shipped [`system.pa`](../tmp/dsu-slot-a/etc/pulse/system.pa) ends at the four ALSA endpoints and a comment header `### Enable Virtual Sinks ###` with no virtual sinks defined below it. The header itself (`Define virtual sinks for MPP, Ipod, Bluetooth and Voice / Beep`, dated 2012-03-23) is unambiguous about what was supposed to come next. The four virtual sinks — **MPP** (music player), **Ipod** (iPod-out / USB media), **Bluetooth** (BT A2DP), **Voice/Beep** (nav prompts + system chimes) — are dynamically loaded by `audio_ps` after PA is up. That is why the [`pulse_retrychk.sh`](../tmp/dsu-slot-a/lib/systemd/system/pulse_retrychk.sh) gate exists (commented in current `nav_audio.service` but still on disk): if PA isn't running, audio_ps's `pa_context_connect()` fails and the virtual sink topology never materializes.

5. **`snd` is the chime daemon; `sndamp` is the amplifier control daemon — both are critical, distinct, and small.** Both run with `LimitSTACK=393216` (384 KB), no wsegl path, no GStreamer env, and the same DENSO `Requires=nav_pre.target` + `OnFailure=nav_smngpret.service` cascade as the UI daemons (a crash trips the system-pre-reset poison-pill per [forensic-daemon-supervision.md](forensic-daemon-supervision.md) §1.3). `snd` drives the **Monaural_out** sink (with `rewind_safeguard=17280`, the only sink so configured — a tell for short low-latency PCM events like a touch-beep) for button beeps, blinker clicks, lane-departure warnings, parking-sensor chirps. `sndamp` doesn't talk to PA at all — it talks to the external **Bose amplifier** (or base Nissan amp) over a vehicle-internal control bus (most likely CAN with vehicle-specific frame IDs, possibly MOST or a private I²C/SPI line to the amp). It owns volume curves, speaker mute on call, Bose AudioPilot / Centerpoint / SurroundStage flags, and Speed-Sensitive Volume.

6. **There is a USB sound-card path with a very specific consumer device baked into `system.pa`.** [`pulseaudio-usbsink.service`](../tmp/dsu-slot-a/lib/systemd/system/pulseaudio-usbsink.service) is path-triggered by `/dev/usbaudio0` and `pactl load-module module-remap-sink master=alsa_output.usb-C-Media_Electronics_Inc._SB_Easy_Record_SB_Connect_Hi-Fi_090804000001-00-HiFi.analog-stereo`. **C-Media SB Easy Record / SB Connect Hi-Fi** is a $20 USB DAC/ADC, not an automotive part — this looks vestigial from a factory bring-up / test rig and almost certainly does nothing in a customer-shipped DCU. Flagged as an open question (see §9.1).

7. **The BlueZ `audio.conf` SCO routing default is HCI, but `BTA_in` exists at `plughw:0,0,4` — a hardware-wired PCM path off the BT chip into the LAPIS I2S subdevice may exist in parallel.** Per [forensic-phone-stack.md](forensic-phone-stack.md) §3.3, `audio.conf` has `# SCORouting=PCM` commented → default HCI → kernel-mediated SCO. But the factory PA config opens a fourth ALSA source named `BTA_in` (BT-Audio In) on a sub-device that the kernel sound card layout reserves. This suggests the hardware route exists (BT chip's PCM pin → ML7213 I2S input 4) even if BlueZ routes call audio through HCI by default; or that `BTA_in` is used specifically for **A2DP** ingest (music streaming from phone), not HFP call audio. **forensic-phone-stack.md may need correction depending on live verification** — see §9.2.

**Bottom line for the rebuild:** Replace PulseAudio 1.1 → PipeWire (or PA 16+), GStreamer 0.10 + TMC plugins → GStreamer 1.x + `gst-libav`, `audio_ps` → ~1 day of Qt6 `MediaController` C++ wrapping `QMediaPlayer` + role-based sink routing, `snd` → ~half-day of `QSoundEffect` or libcanberra firing canned WAVs on UI events, **`sndamp` is the hardest piece by an order of magnitude** because the Bose amp protocol is undocumented — that work is gated on live CAN-bus reverse-engineering on the car.

---

## 1. Architecture Diagram

```
┌────────────────────────────────────────────────────────────────────────────────┐
│ UI: now-playing strip, audio source picker, EQ screen, volume knob (HW + UI)   │
│ (hmictrl_proc + display_ps draw into EmgdHmi pixmap canvas)                    │
└────────────────────────────────────────────────────────────────────────────────┘
            ▲  POSIX mqueue (/audio_ps_main, /snd_main, /sndamp_main)
            │  play/pause/next/volume requests; now-playing + track-change events
┌──────────────────────────┐  ┌───────────────────────┐  ┌─────────────────────┐
│ audio_ps "PS_AUDIO"      │  │ snd "PS_SND"          │  │ sndamp "PS_SNDAMP"  │
│ LimitSTACK 512KB         │  │ LimitSTACK 384KB      │  │ LimitSTACK 384KB    │
│ LD_LIBRARY_PATH +wsegl   │  │ no wsegl              │  │ no wsegl            │
│ GST_REGISTRY_UPDATE=no   │  │ headless              │  │ headless            │
│  - Media pipelines (Gst) │  │  - Touch beeps        │  │  - CAN to amp       │
│  - PA virtual sinks      │  │  - Blinker clicks     │  │  - Volume curves    │
│  - Source switching      │  │  - LDW/PDC chirps     │  │  - Bose AudioPilot  │
│  - Popup rendering       │  │  - Nav prompts (?)    │  │  - SSV              │
└──────────────────────────┘  └───────────────────────┘  └─────────────────────┘
            │                              │                       │
            │ PA native (Unix socket)      │ libasound direct       │ raw socket
            ▼                              ▼                       ▼ to CAN /
┌────────────────────────────────────────────────────┐         private bus
│ PulseAudio 1.1 (--system mode)                     │         ─────────────►
│ system.pa: 2 sinks + 2 sources hard-wired         │         External
│   sink   Stereo_out    plughw:0,0,0  s24-32le     │         Bose / Nissan
│   sink   Monaural_out  plughw:0,0,1  s24-32le      │         amplifier
│                        rewind_safeguard=17280      │
│   source Mic_in        plughw:0,0,2  s24-32le      │         (speaker drive
│   source BTA_in        plughw:0,0,4  s24-32le      │          + mute + EQ
│                                                    │           DSP)
│ Virtual sinks (loaded by audio_ps at runtime):     │
│   MPP, Ipod, Bluetooth, Voice/Beep                 │
│                                                    │
│ module-cork-music-on-phone.so → ducks MPP on call  │
│ module-bluetooth-device.so    → A2DP sink/source   │
│ module-remap-sink             → USB DAC (vestigial?)│
└────────────────────────────────────────────────────┘
            ▼ ALSA (libasound2)
┌────────────────────────────────────────────────────┐
│ Kernel sound modules                               │
│   snd-ml7213ioh-d3s.ko (LAPIS ML7213 IOH I2S)      │  ← primary card
│      └─ deps: ioh_i2s.ko (transport)               │
│                ioh_i2s_dma.ko (DMA engine)         │
│                snd-pcm, snd-timer, snd-page-alloc  │
│   snd-usb-audio.ko (USB DAC if /dev/usbaudio0)     │  ← path-triggered
│   snd-aloop.ko    (loopback — test/debug)          │
│   snd-timbi2s.ko  (Timberdale — unused on this HW) │  ← present, dormant
│   snd-intel8x0.ko (AC97 — unused on Tunnel Creek)  │  ← present, dormant
└────────────────────────────────────────────────────┘
            ▼ I2S serial frames                       ▲ HCI SCO (kernel-mediated)
┌──────────────────────────────────┐         ┌─────────────────────────────┐
│ LAPIS ML7213 IOH I2S controller  │         │ bt_hci.ko + BlueZ + ofono   │
│ (PCI 10DB:8033 — see modules.alias)│       │ HFP call audio via PA       │
│  sub 0 stereo out                │         │ A2DP music via PA sinks      │
│  sub 1 mono out                  │         │ See forensic-phone-stack.md │
│  sub 2 mic in                    │         └─────────────────────────────┘
│  sub 4 BT-audio in (hard-wired?) │
└──────────────────────────────────┘
            ▼                                     ▲
       To Bose amp inputs                  From cabin mic
       (analog or digital line)
```

---

## 2. Layer 1 — Kernel sound drivers

### 2.1 Primary card: LAPIS ML7213 IOH I2S

**Path:** `/tmp/dsu-slot-a/lib/modules/2.6.37.6-…/kernel/sound/drivers/snd-ml7213ioh-d3s.ko`

**PCI alias** (from `modules.alias`):
```
alias pci:v000010DBd00008033sv*sd*bc*sc*i* ioh_i2s
```
Vendor `0x10DB` = **LAPIS Semiconductor** (formerly OKI). Device `0x8033` = ML7213 I/O Hub I2S controller. This is the same LAPIS ML7213 IOH that also hosts the SDHCI controllers documented in [`project_lapis_sdhci_binding.md`](../../../.claude/projects/-Users-dpitek-Developer-q60-rebuild/memory/project_lapis_sdhci_binding.md) — i.e., LAPIS owns most of the non-graphics IO on Tunnel Creek.

**Dependency chain** (from `modules.dep`):
```
snd-ml7213ioh-d3s.ko  → ioh_i2s.ko  + snd-pcm + snd-timer + snd-page-alloc
ioh_i2s.ko            → (root)
ioh_i2s_dma.ko        → (root, init_nr_desc_per_channel=1024 per commented pulseaudio.service line)
```

The DMA engine (`ioh_i2s_dma.ko`) is split out as a separate module because the LAPIS ML7213 IOH DMA controller is shared with other LAPIS IPs (SDHCI, GbE) — it provides a generic DMA engine that snd-ml7213ioh registers as a slave with.

**Card layout exposed to ALSA:** one card (card 0), four sub-devices:
| Sub | Direction | Width | Purpose |
|---:|-----------|-------|---------|
| 0 | playback | s24-32le stereo | Music / nav prompts / call audio | (→ Bose amp main stereo) |
| 1 | playback | s24-32le mono | System chimes, beeps, blinker, warnings | (→ Bose amp chime channel) |
| 2 | capture | s24-32le | Cabin microphone | (← mic preamp) |
| 4 | capture | s24-32le | BT-audio in (hardware-wired PCM from BT chip?) | (← BT chip PCM out) |

Sub-device 3 is unallocated (or reserved for a future input — possibly auxiliary). `s24-32le` = 24-bit samples in 32-bit containers, little-endian; standard high-quality I2S word format for automotive DSP.

### 2.2 Other sound modules present but unused

| Module | Why shipped | Why unused |
|--------|-------------|------------|
| `snd-timbi2s.ko` | Wind River BSP includes Timberdale (the Intel/Atom MID reference platform's I2S) | The hardware is LAPIS ML7213, not Timberdale — no PCI match |
| `snd-intel8x0.ko` | Wind River BSP default for legacy Intel AC97 codecs | Tunnel Creek has no AC97 — no PCI match |
| `snd-usb-audio.ko` | Standard USB Audio Class driver | Only loads if `/dev/usbaudio0` appears (path-triggered service) |
| `snd-aloop.ko` | ALSA loopback (test) | No service ever loads it; available for in-field debug |
| `snd-hda-*.ko` (codec set) | Wind River shipping every HDA codec | No HDA controller on this hardware |

### 2.3 Module load order (production)

There is **no explicit `modprobe snd-ml7213ioh-d3s`** in any service unit shipped on Slot A. The module loads via **udev coldplug** when the PCI bus walk hits the `10db:8033` device. Confirmation: [`/etc/modules-load.d/modules.conf`](../tmp/dsu-slot-a/etc/modules-load.d/modules.conf) lists `bt_hci`, `setgpio`, `watchdog`, etc., but not the sound modules. The commented-out lines in [`pulseaudio.service`](../tmp/dsu-slot-a/lib/systemd/system/pulseaudio.service) (`#ExecStartPre=-/sbin/modprobe ioh_i2s_dma init_nr_desc_per_channel=1024` etc.) confirm there was a development phase where PA explicitly loaded the modules — and they removed it because udev was already doing it. The `init_nr_desc_per_channel=1024` value is preserved as a historical clue that the default DMA descriptor pool was too small for the four-substream concurrency PA expects.

---

## 3. Layer 2 — PulseAudio 1.1 (system mode)

### 3.1 Service unit shape

[`pulseaudio.service`](../tmp/dsu-slot-a/lib/systemd/system/pulseaudio.service):
```ini
[Unit]
Description=Pulseaudio Daemon
After=dbus.service udev.service

[Service]
Type=oneshot
Restart=on-failure
RestartSec=100ms              # workaround for "pulseaudio cannot bootup" — comment in file
ExecStart=/bin/usleep 3000000  # ← explicit 3-second sleep before PA starts
ExecStart=/usr/bin/pulseaudio --system -D
RemainAfterExit=yes
```

The 3-second `usleep` before PA launches and the `Restart=on-failure` + 100 ms respawn are both verbatim "workaround for pulseaudio.daemon cannot bootup issue" per the file's own comments. **PA had a bring-up race during development** — the LAPIS I2S card needed time to fully enumerate after the PCI scan; PA was starting before `/dev/snd/pcmC0D0p` existed and failing to open it. The 3-second sleep + respawn loop is the band-aid. This is the same kind of timing artifact we see on the BT firmware-flash path in [forensic-phone-stack.md](forensic-phone-stack.md) §2.2.

A second band-aid: [`pulse_retrychk.sh`](../tmp/dsu-slot-a/lib/systemd/system/pulse_retrychk.sh) — a wrapper script that polls `systemctl status pulseaudio.service` in a `usleep 300000` loop until PA is `0/SUCCESS`, then execs the daemon passed as `$1` with PS-name `$2`. It is **commented out** in current `nav_audio.service` (line 23) but its existence on disk + the matching commented-out `ulimit -c unlimited` ExecStart variant says `audio_ps` was once started via this wrapper specifically because it could not safely launch until PA was up. The fact that DENSO removed the wrapper but kept the 3-second sleep suggests they eventually nailed down the ordering with the systemd `After=` graph instead.

### 3.2 Sink/source topology — what is loaded at boot

[`/etc/pulse/system.pa`](../tmp/dsu-slot-a/etc/pulse/system.pa) (effective config, comments stripped):
```
load-module module-esound-protocol-unix
load-module module-dbus-protocol access=local
load-module module-native-protocol-unix

load-module module-alsa-sink   sink_name=Stereo_out    device=plughw:0,0,0 format=s24-32le tsched=0
load-module module-alsa-sink   sink_name=Monaural_out  device=plughw:0,0,1 format=s24-32le tsched=0 rewind_safeguard=17280
load-module module-alsa-source source_name=Mic_in      device=plughw:0,0,2 format=s24-32le tsched=0
load-module module-alsa-source source_name=BTA_in      device=plughw:0,0,4 format=s24-32le tsched=0

### Enable Virtual Sinks ###
# ← file ends here. No virtual sinks defined.
```

Notable absences:
- **No `module-udev-detect`** — every device is hard-wired. PA does not autodetect; if you renumber the ALSA cards, system.pa breaks.
- **No `module-suspend-on-idle`** — sinks never suspend. Important for the chime path: `snd` must be able to fire a 50 ms beep with no warm-up latency.
- **No `module-stream-restore` / `module-device-restore`** — volume state is owned elsewhere (almost certainly `sndamp` or a per-source state in `audio_ps`), not by PA.
- **No `module-position-event-sounds`** — explicitly commented out; DENSO does not use freedesktop event sounds.

What `tsched=0` means: PA uses ALSA's **interrupt-driven** scheduling, not timer-based. Lower wakeup latency, higher interrupt rate — automotive-correct trade. `rewind_safeguard=17280` on the mono chime sink: 17280 samples ≈ 360 ms at 48 kHz — PA's rewind-on-cork-uncork distance is capped, meaning a queued chime won't "skip backwards" if a new event interrupts. Specifically tuned for the chime use case where every event is a short impulse.

### 3.3 Virtual sinks loaded by `audio_ps` (inferred)

The header comment in `system.pa` at line 20-22 names them:
```
# 2012-03-23:
# - Define virtual sinks for MPP, Ipod, Bluetooth and Voice / Beep
```

Mapping to UI features (per [feature-parity-audit.md](feature-parity-audit.md)):

| Virtual sink | Backed by | Routed to physical sink | UI source name |
|--------------|-----------|------------------------|----------------|
| **MPP** (Music Player) | GStreamer pipeline in audio_ps decoding USB / iPod-out / SD-card files | Stereo_out | "USB" / "iPod" / "SD" |
| **Ipod** | DENSO `ipodplayer_ps` (separate nav_ipodplayer.service) → audio_ps virtual sink | Stereo_out | "iPod" |
| **Bluetooth** | `module-bluetooth-device.so` A2DP sink (created automatically by BlueZ pairing); audio_ps remaps it under this name | Stereo_out | "Bluetooth Audio" |
| **Voice/Beep** | snd writes here for chimes; ofono call-progress tones go here; nav voice prompts go here | Monaural_out (chimes) / Stereo_out (voice prompts) | (invisible — system) |

The reason these are virtual rather than direct: a virtual sink decouples the **role** (what the audio is for) from the **device** (which speaker drives it). audio_ps can swap the underlying physical sink for any virtual one (e.g., route Voice/Beep to Stereo_out when the chime should pan-center, to Monaural_out when it's a short impulse). This is exactly the pattern PipeWire formalized as roles a decade later.

The `module-cork-music-on-phone.so` plugin (per [forensic-phone-stack.md](forensic-phone-stack.md) §5.1) works against the **MPP** virtual sink — that's why MPP exists as a discrete sink and not just a stream tag.

### 3.4 USB-sink remap (vestigial?)

[`pulseaudio-usbsink.service`](../tmp/dsu-slot-a/lib/systemd/system/pulseaudio-usbsink.service):
```ini
[Unit]
After=pulseaudio.service graphical.target

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 3
ExecStart=-/usr/bin/pactl load-module module-remap-sink \
  sink_name=audio_out_usb remix=no \
  master=alsa_output.usb-C-Media_Electronics_Inc._SB_Easy_Record_SB_Connect_Hi-Fi_090804000001-00-HiFi.analog-stereo \
  channels=2 master_channel_map=front-left,front-right channel_map=front-left,front-right
```

Path-triggered by [`pulseaudio-usbsink.path`](../tmp/dsu-slot-a/lib/systemd/system/pulseaudio-usbsink.path) on `PathExists=/dev/usbaudio0`. The `master=` argument **hard-codes a specific consumer device**: **C-Media Electronics SB Easy Record / SB Connect Hi-Fi**, USB serial number `090804000001`. That is a $20 USB audio interface, almost certainly used as a **factory bring-up / engineering rig** — a developer plugged that exact device in to test the USB audio path against a known-good DAC, the rule got baked into a unit file, and nobody removed it. Customer DCUs almost certainly never have a USB sound card attached and this path never fires. The leading `-` in `ExecStart=-/usr/bin/pactl` swallows the failure if the device isn't present, so it costs nothing at boot in production. Flagged as open question §9.1 — worth confirming on live hardware whether `/dev/usbaudio0` ever appears in customer use.

The `udev` rule [`ifup_audio0.sh`](../tmp/dsu-slot-a/etc/udev/rules.d/ifup_audio0.sh) — **separate, unrelated** despite the name — sets `audio0` as a **network interface** at `169.254.11.1/24` with MTU 5040. The "audio" name is a misnomer; this is the **DENSO inter-board IP link** for audio metadata / control, not the audio data path. See [DSU_OEM_DOCUMENTATION.md](DSU_OEM_DOCUMENTATION.md) for the inter-board link-local network. The audio data itself goes over I2S, not over `audio0`.

---

## 4. Layer 3 — GStreamer 0.10 + DENSO TMC codec plugins

### 4.1 GStreamer presence

[`/usr/lib/libgstreamer-0.10.so.0`](../tmp/dsu-slot-a/usr/lib/libgstreamer-0.10.so.0) — the legacy GStreamer 0.10 series, **end-of-life since 2014**. The split-out libs (`libgstaudio-0.10`, `libgstvideo-0.10`, `libgstpbutils-0.10`, `libgstrtp-0.10`, etc.) all version `0.10.x` — no GStreamer 1.x anywhere on Slot A. This pins the audio pipeline to the gst-0.10 API surface (which is *not* source-compatible with 1.x).

[`/usr/lib/gstreamer-0.10/`](../tmp/dsu-slot-a/usr/lib/gstreamer-0.10/) contains **114 plugins**: 8 DENSO/TMC + ~106 stock. The full stock set covers `pulse`, `alsa`, `flac`, `ogg`, `vorbis`, `speex`, `theora`, `oss4audio`, `videoconvert`, `playbin`, `decodebin`/`decodebin2`, `souphttpsrc`, etc. — i.e., the standard `gst-plugins-base` + `gst-plugins-good` set. No `gst-plugins-bad`, no `gst-plugins-ugly`, no `gst-libav` (which would imply ffmpeg). The DENSO plugins fill the patent-encumbered gap.

### 4.2 The 8 DENSO/TMC plugins

| Plugin | Likely function | What it replaces |
|--------|-----------------|------------------|
| `libTMC_GstMP3Dec.so` | MP3 decoder | mad / mpg123 / libav |
| `libTMC_GstAACDec.so` | AAC-LC + HE-AAC decoder | faad2 / fdk-aac / libav |
| `libTMC_GstWMADec.so` | WMA 7/8/9 decoder | libav (was never FOSS for WMA Pro) |
| `libTMC_GstASFDemux.so` | ASF/WMV container demux | libav (asfdemux) |
| `libTMC_GstMP4Demux.so` | MP4/M4A container demux | isomp4 |
| `libTMC_GstID3Demux.so` | ID3v1/v2 metadata parser | id3demux |
| `libTMC_GstAudioConvert.so` | Sample-format converter | audioconvert |
| `libTMC_GstReSample.so` | Sample-rate converter | audioresample |

**`TMC`** = "Toyota Motor Corp" is the obvious guess but unlikely (this is a Nissan car); more probably **"Telecom Multimedia Codec"** or an internal DENSO product code. Either way these are **licensed binary blobs** carrying MPEG-LA / MP3 royalty pass-through. DENSO almost certainly bought a per-unit license from a codec vendor (likely Coding Technologies / Dolby for AAC, Fraunhofer or Thomson for MP3, Microsoft for WMA) and wrapped each in a thin GStreamer element shim.

**Why two of them duplicate stock plugins** (`audioconvert`, `audioresample`): the TMC variants are likely optimized for the Atom E6xx Bonnell core (with explicit SSE3-only paths, possibly hand-tuned fixed-point) and avoid the stock plugins' floating-point fast paths that perform poorly on this CPU. They also probably integrate with the TMC decoders' internal sample format conventions to avoid intermediate copies.

### 4.3 What this means

The rebuild **cannot ship the TMC plugins** — they're licensed binaries with no source, no headers, no published ABI. Even if we copied them off `/home/naviwork/` (where they may also exist — needs confirmation), we'd have no right to redistribute. The rebuild has to fund its own codec answer:

- **GStreamer 1.x + `gst-libav`**: ffmpeg is LGPL, decoder set is comprehensive, and the patent risk is **the operator's problem** in many jurisdictions. For a one-off personal-use Q60 build this is fine.
- **Direct libavcodec**: skip GStreamer entirely and decode in our Qt app via `QMediaPlayer` (which on Linux uses `gst-libav` under the hood anyway) or a custom thin wrapper.

There's no value in trying to keep gst-0.10 alive in 2026.

---

## 5. The Three DENSO Daemons — Compared

### 5.1 Side-by-side comparison

| Property | `audio_ps "PS_AUDIO"` | `snd "PS_SND"` | `sndamp "PS_SNDAMP"` |
|----------|----------------------|----------------|---------------------|
| Service unit | `nav_audio.service` | `nav_snd.service` | `nav_sndamp.service` |
| `LimitSTACK` | 524288 (512 KB) | 393216 (384 KB) | 393216 (384 KB) |
| `LimitMSGQUEUE` | 8192000 (8 MB) | 8192000 (8 MB) | 8192000 (8 MB) |
| `LD_LIBRARY_PATH` includes `/usr/lib/wsegl` | **YES** | No | No |
| `GST_REGISTRY_UPDATE=no` | **YES** | No | No |
| Requires | `nav_pre.target` | `nav_pre.target` | `nav_pre.target` |
| OnFailure | `nav_smngpret.service` | `nav_smngpret.service` | `nav_smngpret.service` |
| Restart= | (none — crash = poison-pill) | (none) | (none) |
| `pulse_retrychk.sh` wrapper (historical) | **YES** (commented out) | No | No |
| Talks PA native protocol | Yes (inferred — loads virtual sinks) | Yes (writes to Monaural_out) | **No** |
| Talks GStreamer | Yes | No (or trivially) | No |
| Renders UI elements via wsegl | **Yes** (popups: source switch, USB-connected, now-playing toasts) | No | No |
| Talks to external amp | No | No | **Yes** (CAN or private bus) |
| Subscribes to CAN | Possibly (volume knob, source button) | Possibly (blinker tick) | **Yes** (vehicle speed for SSV, AMP feedback) |
| Inferred binary size | Large (GStreamer + PA + EGL) | Small (< 100 KB) | Medium (CAN + state machines) |
| Replacement effort | ~1 day Qt6 `MediaController` | ~½ day `QSoundEffect` + WAVs | **Hard** — reverse-engineer amp protocol on car |

### 5.2 `audio_ps` deep-inference

The wsegl-in-path observation is the load-bearing finding. Five services share that path (`nav_audio`, `nav_dsn`, `nav_hmictrl`, `nav_soft_vup`, `nav_systemlogd`). Of those, only `nav_audio` and `nav_hmictrl` (and implicitly `nav_display` / `nav_navi` / `nav_dispapf` via other paths) are user-visible during normal operation. **What audio_ps draws** is constrained by the popup-buffer typing from [forensic-factory-ui-binary.md](forensic-factory-ui-binary.md) §2.3 (the `EMGD_POPUP_BUFFER=3` type, 800×480, ARGB8888):

1. **Source-switch overlay** — the brief "USB" / "Bluetooth" / "FM" badge that appears when the user changes audio source
2. **Now-playing toast** — track-change notifications, especially for Bluetooth AVRCP metadata updates
3. **USB-connected / device-recognized toasts**
4. **Possibly the video surface for `multimedia_ps`** — if a video file is being played from USB, `multimedia_ps` likely owns the decoder but audio_ps owns the audio plumbing and may own the popup-layer "Video" badge

Architecturally `audio_ps` is the **audio policy manager + media pipeline + audio-related notification renderer**, not just a PA wrapper.

### 5.3 `snd` deep-inference

Headless, tiny stack, no GStreamer registry env. Its job is firing low-latency PCM blasts:

- Touch-screen tap feedback beep
- Button click feedback (steering wheel buttons echo back via CAN → ioapf_proc → snd?)
- Blinker tick (if implemented in HU rather than dash; most Nissans implement it in dash, so this may be ambient-condition fallback)
- LDW (Lane Departure Warning) alert
- PDC (Parking Distance Control) chirp
- BSW (Blind Spot Warning) chime
- Forward Collision Warning
- Seatbelt-not-fastened reminder

The **Monaural_out** sink with `rewind_safeguard=17280` is essentially built for `snd`'s usage pattern: short PCMs that should never overlap, never be cancelled mid-playback, and never warm up the DAC (sink not suspended). Whether nav voice prompts ("Turn right in 200 feet") go through `snd` or through `audio_ps` is an open question — they're routed to the **Voice/Beep** virtual sink which is most cleanly owned by audio_ps, but pragmatically they may be handed off to `snd` for the no-warm-up benefit. See §9.3.

### 5.4 `sndamp` deep-inference — the hardest piece

No wsegl, no GStreamer, no PA contact, but the same nav_pre.target gating and OnFailure cascade as audio_ps. What's left? **Talking to the amplifier.** Inferred responsibilities:

1. **Volume control** — the physical volume knob's CAN frame arrives at `ioapf_proc`, which republishes it on mqueue; `sndamp` receives that, converts it to whatever amp-control protocol the Bose / base Nissan amp speaks, and sends.
2. **Speaker mute on call** — when `tel_proc` signals call-active, `sndamp` mutes the music speakers and unmutes only the speakers carrying call audio (typically driver-side front).
3. **Bose feature toggles** — AudioPilot (auto noise compensation), Centerpoint (surround simulation), SurroundStage (front stage widening), Driver-Stage (driver-focused mode) all live as Bose-amplifier-internal DSP flags. The UI toggle in Settings → Audio routes through `sndamp` to flip an amp config bit.
4. **Speed-Sensitive Volume (SSV)** — reads vehicle speed (probably from CAN via ioapf_proc), maps to a volume offset curve, applies on top of user volume.
5. **Channel balance/fade and EQ** — Bass/Treble/Balance/Fade sliders all set per-channel gains in the amp's DSP.
6. **Amp fault handling** — overcurrent, overtemp, speaker-disconnect detection feedback.

**Protocol uncertainty:** The Bose Performance Series in the 2017 Q60 (16 speakers) has its own DSP and amp module. The amp's control interface to the head unit is **almost certainly CAN** (vehicle-specific frame IDs on the "infotainment-CAN" sub-bus that also carries volume knob, source button, etc.) — possibly with a small auxiliary serial line for boot-time amp firmware handshake. **MOST bus** is a possibility for some Nissan/Infiniti products of this era but unlikely on the 2017 Q60. Without sniffing the actual CAN traffic with the factory `sndamp` running, we are guessing.

This is the **single hardest factory daemon to replace** in the entire rebuild. Plan: keep `sndamp` alive (don't mask it) for as long as possible, intercept its mqueue inputs from our app, and only replace it when we have a verified CAN-protocol document for the Bose amp.

---

## 6. Layer 4 — Bluetooth audio interaction with this stack

The phone stack is fully documented in [forensic-phone-stack.md](forensic-phone-stack.md). Audio-specific points:

1. **Call audio (HFP)** travels via `bt_hci.ko` → BlueZ → PA `module-bluetooth-device.so` → routed by `audio_ps` to the Voice/Beep virtual sink → Monaural_out (or Stereo_out depending on car wiring). The `audio.conf` `# SCORouting=PCM` is commented → default HCI → all SCO frames travel through the kernel SCO socket, not via a hardware PCM bypass.
2. **Music audio (A2DP)** flows: phone → bt_hci → BlueZ → `module-bluetooth-device.so` creates an A2DP sink (SBC codec via `libbluetooth-sbc.so`) → `audio_ps` remaps it as the **Bluetooth** virtual sink → routes to Stereo_out.
3. **AVRCP track metadata** (artist/album/track) arrives over a BlueZ D-Bus interface that `tel_proc` (probably) consumes and republishes over mqueue to audio_ps and then to the UI for the now-playing strip.
4. **Caller mic** comes via the **Mic_in** ALSA source (plughw:0,0,2) — the cabin mic, not the BT chip — and is encoded to SCO frames by PA → BlueZ → bt_hci → phone.
5. **`BTA_in` source on plughw:0,0,4** is the question mark. If it exists as a real ALSA capture device, the LAPIS I2S subdevice 4 must be physically wired to the BT chip's PCM output. That would mean either (a) DENSO planned for SCO-via-PCM but never enabled it, leaving the wire in place; or (b) `BTA_in` is the A2DP music path bypassing kernel SCO entirely, with the BT chip doing the SBC decode in its own DSP and emitting PCM on a hard line. **Either way, `forensic-phone-stack.md` needs a correction**: the doc claims "the entire call audio path runs in userspace" (§3.3) — that's true for HFP SCO under the current `audio.conf` default, but the **hardware** evidently supports a parallel PCM path that the software just doesn't use. See §9.2.

---

## 7. Rebuild Implications

### 7.1 Component-by-component replacement plan

| Factory component | Plan B''' replacement | Effort | Notes |
|---|---|---|---|
| `snd-ml7213ioh-d3s.ko` + `ioh_i2s.ko` + `ioh_i2s_dma.ko` | **Unchanged** — keep factory kernel | None | Plan B''' keeps the kernel; PCI alias claims the card automatically at udev coldplug |
| `snd-usb-audio.ko` (USB-DAC path) | **Unchanged** | None | Still loads if `/dev/usbaudio0` appears |
| ALSA card layout (4 subdevices) | **Unchanged** | None | Card 0, sub 0/1/2/4 stays |
| **PulseAudio 1.1 system mode** | **PipeWire** OR PulseAudio 16+ | ~½ day | Replace `system.pa` with PipeWire's `default.conf` declaring the 4 ALSA endpoints; PA-protocol shim handles legacy clients |
| `system.pa` 4 hard-wired sinks/sources | PipeWire ALSA monitor with explicit per-device config | ½ day | Same plughw paths, same s24-32le, same rewind_safeguard |
| Virtual sinks (MPP/Ipod/Bluetooth/Voice/Beep) | **PipeWire roles** (`Music`, `Notification`, `Phone`, `Game`) + Wireplumber routing policy | 1 day | Modern roles map cleanly to the legacy virtual-sink concept |
| `module-cork-music-on-phone.so` | PipeWire role-based ducking via Wireplumber Lua policy | trivial | Standard pattern |
| `module-remap-sink` for USB C-Media DAC | **Drop** | None | Vestigial; remove unless live verification shows otherwise |
| `pulseaudio-usbsink.service` + `.path` | **Drop** | None | Same |
| `pulse_retrychk.sh` workaround | **Drop** | None | Modern systemd ordering + PipeWire socket-activation makes this obsolete |
| 3-second `usleep` before PA | **Drop** | None | systemd `After=sound.target` does the job |
| **GStreamer 0.10** | **GStreamer 1.22+** (or skip entirely) | ½ day | Distro package |
| **TMC_Gst* codec plugins** | `gst-libav` (ffmpeg) | None | Drop-in replacement; covers MP3/AAC/WMA/FLAC/OGG/etc. |
| **audio_ps (DENSO)** | Qt6 `MediaController` C++ class wrapping `QMediaPlayer` + role hints | ~1 day | Drives PipeWire roles directly via Qt Multimedia; no DENSO mqueue layer |
| audio_ps source-switch popup rendering | QML `Popup` in monolithic Qt app | trivial | Part of the main UI tree, not a separate process |
| audio_ps virtual-sink loading | PipeWire static config | None | Declarative, not runtime |
| audio_ps GStreamer registry mgmt | N/A | None | Modern gst manages its own registry; `GST_REGISTRY_UPDATE=no` was a startup-latency trick |
| **snd (DENSO)** | Qt6 `ChimeService` firing `QSoundEffect` from canned WAVs | ½ day | Routed to PipeWire `Notification` role; libcanberra fallback option |
| Chime WAV assets | **Need to extract from `/home/naviwork`** | gated on partition extract | Could also synthesize own chimes; user-facing parity question |
| **sndamp (DENSO)** | **OPEN — leave running initially; reverse-engineer amp protocol on car** | **HIGH** | Single hardest replacement; gated on CAN sniffing of factory `sndamp` traffic to/from amp |
| Bose AudioPilot / Centerpoint / SurroundStage toggles | Map to amp control frames via sndamp replacement | gated on protocol | UI settings store the user prefs; sndamp-replacement applies |
| Speed-Sensitive Volume | CAN speed read → volume offset curve → amp control | gated on protocol | Mechanic is simple; depends on amp protocol |
| Volume knob handling | CAN frame → MediaController → PipeWire master volume | trivial | Already separate from sndamp's amp-side curves |

### 7.2 Kill set additions for Plan B'''

Per [`project_planB_kill_set.md`](../../../.claude/projects/-Users-dpitek-Developer-q60-rebuild/memory/project_planB_kill_set.md), the current kill set is `navi_ps` + `dispapf_proc`. Audio plan additions:

- **Add `nav_audio.service` to mask list** — we're replacing audio_ps with our Qt MediaController; do not let it run and contend for PA / GStreamer / wsegl-popup buffers
- **Add `nav_snd.service` to mask list** — we're replacing snd with our ChimeService; do not let it write to Monaural_out concurrently
- **LEAVE `nav_sndamp.service` ALIVE initially** — until we have the amp protocol mapped, sndamp is the only thing that can talk to the Bose amp; killing it leaves the speakers without proper volume / mute / EQ control
- **LEAVE `pulseaudio.service` alive** until we ship PipeWire — when we do, replace the unit's `ExecStart=` to launch pipewire instead, and drop both `pulseaudio-usbsink.*` units
- **LEAVE `nav_multimedia.service` alive** initially — multimedia_ps is the video decoder side; until we have a Qt video path proven, don't break video playback even if we're not using it

### 7.3 What we lose without naviwork extraction

Without the actual `audio_ps`, `snd`, `sndamp` binaries on disk, we don't know:

1. **Exact mqueue message structs.** Drain-and-ACK works (per [forensic-denso-ipc.md](forensic-denso-ipc.md) §1) without us knowing the payloads, so if we mask the daemons this doesn't matter. If we ever want to intercept (e.g., keep sndamp alive but proxy its inputs), we'd need to disassemble.
2. **The amp protocol.** Critical for sndamp replacement. **Cannot be inferred from rootfs alone — must come from the binary OR from CAN-bus capture on the live car.**
3. **Which exact GStreamer pipelines audio_ps builds.** Almost certainly `filesrc ! tmcid3demux ! tmcmp3dec ! tmcaudioconvert ! pulsesink` style. Not load-bearing for the rebuild — we own our pipelines.
4. **Whether nav voice prompts go through audio_ps (Voice virtual sink) or through snd (Monaural_out direct).** Affects whose code path renders voice guidance — see §9.3.
5. **The exact Bose feature → amp-control-flag mapping.** Need amp protocol first; the mapping is then mechanical.

### 7.4 Risks

1. **Bose amp goes silent if `sndamp` crashes or is masked before its replacement is ready.** Mitigation: keep sndamp alive until replacement is fully validated. Accept that we cannot turn the Bose-specific features off in the UI until then.
2. **PipeWire on a 2 GB DDR2 / Atom E6xx system has more overhead than PA 1.1.** Worth benchmarking before commit; PA 16 system mode is the fallback.
3. **`gst-libav` may not be patent-safe** for distribution. For a personal-use one-off DCU this is fine; for any redistribution scenario, codec licensing has to be re-solved.
4. **The vestigial USB-C-Media DAC path may NOT be vestigial.** If for some reason DENSO uses it as the production line-out for a customer feature we haven't found yet, dropping it breaks something. Live verification needed (§9.1).
5. **The 3-second sleep workaround may still be needed** on the factory kernel even with PipeWire, depending on PCI bus walk timing. Watch for sound-card-not-found errors in early-boot logs.

---

## 8. Cross-references to feature parity

Per [feature-parity-audit.md](feature-parity-audit.md), the visible audio features we must preserve:

| Feature | Owner today | Owner in rebuild |
|---------|-------------|------------------|
| USB media playback (MP3/WMA/AAC, folder/artist/album browse) | audio_ps + GStreamer + TMC codecs | Qt MediaController + GStreamer 1 + gst-libav |
| Bluetooth audio (A2DP/AVRCP album art/track/artist/album) | audio_ps + BlueZ + tel_proc | Qt MediaController + BlueZ 5 (direct DBus or Qt BluetoothManager) |
| Bose AudioPilot / Centerpoint / SurroundStage / Driver-Stage | sndamp → Bose amp DSP flags | sndamp-replacement → Bose amp (gated on protocol) |
| Speed-Sensitive Volume | sndamp + CAN speed | Qt CAN service + sndamp-replacement |
| Volume knob | ioapf_proc → audio_ps + sndamp | Qt CAN service → MediaController (PA volume) + amp-control (sndamp-replacement) |
| Navigation voice volume (separate from media) | audio_ps virtual sink Voice | PipeWire Notification role + per-role volume in Qt |
| System sound / button click beeps | snd → Monaural_out | Qt ChimeService → PipeWire Notification |
| Phone ringtone volume | audio_ps Bluetooth + Voice sinks | Qt MediaController role volumes |
| Mute on call | module-cork-music-on-phone.so | Wireplumber role-cork policy |

---

## 9. Open Questions

### 9.1 USB-C-Media DAC — vestigial or real?

The `pulseaudio-usbsink.service` hard-codes the C-Media SB Easy Record / SB Connect Hi-Fi USB DAC by serial number. This is almost certainly a developer's bring-up rig that survived into production. **To confirm:** on a live customer DCU, check whether `/dev/usbaudio0` ever appears. If it never appears, drop the units and forget about it. If it does, we need to find out what plugs into it (rear-seat AUX? OEM accessory?).

### 9.2 BTA_in @ plughw:0,0,4 — what is it actually for?

`system.pa` opens this ALSA source for capture, format s24-32le. The LAPIS I2S card exposes a fourth subdevice. Possibilities:

- **(a)** Hardware-wired PCM path from BT chip → ML7213 I2S sub 4. Software just doesn't use it. The PCB trace exists but DENSO routes call audio over HCI in software.
- **(b)** A2DP music path: BT chip does SBC decode internally, emits PCM on a hardline, captures via `BTA_in`, plays back to Stereo_out. Bypasses kernel SCO entirely.
- **(c)** Reserved for future use (auxiliary mic for noise cancellation? second mic for beamforming?).

**To confirm:** on live HW, `arecord -D plughw:0,0,4` while a BT phone is connected and playing music. If we hear music → option (b). If we hear silence with a paired/streaming phone → option (a). If the device doesn't exist → not wired at all.

**Action if (b) confirmed:** correct [forensic-phone-stack.md](forensic-phone-stack.md) §3.3 to note that A2DP audio bypasses kernel-mediated PA-routing on this hardware.

### 9.3 Voice guidance — through audio_ps or snd?

Nav prompts ("Turn right in 200 feet") need to mute music briefly, play the prompt, restore music. Two paths:

- **audio_ps:** synthesize/play through Voice virtual sink → corks MPP via module-role-cork → Stereo_out → restore.
- **snd:** play through Monaural_out → no music cork (mono chime sink doesn't trigger MPP cork) → simpler, lower latency, but voice prompt overlaps with music.

Factory behavior almost certainly mutes/ducks music during prompts → suggests audio_ps path. Live confirmation trivial.

### 9.4 Bose amp protocol

The hardest question and the one we can't answer from the rootfs. Need a CAN-bus capture on the car with factory `sndamp` running, performing volume / mute / EQ / Bose-feature-toggle actions, and correlating CAN traffic with each action. **This is gated work for after Phase 1 boots and we can plug in a CAN sniffer.**

Worth investigating in parallel: Nissan/Infiniti technical service bulletins for the 2017 Q60 Bose system, aftermarket adapter products (Maestro / iDataLink modules) which often document the amp protocol indirectly via what they support.

### 9.5 Are the TMC codec plugins also on `/home/naviwork/`?

Just because they're on Slot A doesn't preclude them being on naviwork too — DENSO might ship duplicates. Not load-bearing because we're replacing them with `gst-libav` regardless; mentioned for completeness.

### 9.6 Why is `module-cork-music-on-phone.so` not explicitly loaded in `system.pa`?

PA modules are loaded by `system.pa` directives; this one isn't. Either (a) `audio_ps` loads it at runtime via the native protocol when registering its virtual sinks, or (b) PA auto-loads it via a build-time default not visible in the config. Almost certainly (a) given the virtual-sink loading pattern. Confirmation requires `strings audio_ps | grep module-cork`.

### 9.7 Does `snd` link `libcanberra` or roll its own?

If it links libcanberra it's a thin wrapper around `ca_context_play()`. If it rolls its own, it's libasound + a WAV decoder. Affects how easily we can replace it (libcanberra → swap the libcanberra calls for QSoundEffect; custom → reimplement). Not load-bearing.

---

## 10. Cross-references

- [forensic-clock-service.md](forensic-clock-service.md) — symmetric example of a tiny backend daemon (abstc) with no UI rendering
- [forensic-phone-stack.md](forensic-phone-stack.md) — full BT stack; call-audio routing; module-cork-music-on-phone; needs §3.3 correction pending §9.2
- [forensic-daemon-supervision.md](forensic-daemon-supervision.md) — `nav_pre.target` ordering, `OnFailure=nav_smngpret.service` cascade, smng mqueue heartbeat, kill-set considerations
- [forensic-denso-ipc.md](forensic-denso-ipc.md) — POSIX mqueue conventions; `/audio_ps_main`, `/snd_main`, `/sndamp_main` queue names; drain contract for masked daemons
- [forensic-factory-ui-binary.md](forensic-factory-ui-binary.md) — wsegl-hmi EGL+pixmap rendering pattern; EMGD_POPUP_BUFFER=3 for audio_ps source-switch / now-playing toasts
- [feature-parity-audit.md](feature-parity-audit.md) — visible audio feature set we must preserve (Bose features, SSV, EQ, sources)
- [project_planB_kill_set.md](../../../.claude/projects/-Users-dpitek-Developer-q60-rebuild/memory/project_planB_kill_set.md) — kill set updates: mask `nav_audio` and `nav_snd`; LEAVE `nav_sndamp` alive
- [project_lapis_sdhci_binding.md](../../../.claude/projects/-Users-dpitek-Developer-q60-rebuild/memory/project_lapis_sdhci_binding.md) — same LAPIS ML7213 IOH owns the I2S sound card; reinforces that LAPIS is the dominant non-graphics IO controller on Tunnel Creek
- [DSU_OEM_DOCUMENTATION.md](DSU_OEM_DOCUMENTATION.md) — vehicle-bus integration (CAN frames for volume / source / steering wheel; Bose amp wiring)
