# Forensic — Music Library / USB Media Browser (`multimedia_ps`)

**Date:** 2026-05-23
**Source:** `/tmp/dsu-slot-a/` (extracted Slot A DSU backup) + `/tmp/dsu-naviwork-bin/multimedia_ps` (extracted naviwork binary, 14,808 B stripped) + cross-reference to existing forensics
**Subject:** How the factory Q60 head unit indexes and browses music on an inserted USB stick (artist/album/genre/playlist/track tree, metadata, cover art) — daemon shape, USB hotplug path, tag-parsing pipeline, IPC contract to the UI, and the rebuild path.

---

## Executive Summary

1. **`multimedia_ps "PS_MULTIMEDIA"` is the library/indexer daemon, paired with `audio_ps "PS_AUDIO"` as the playback engine.** They are sister processes — same dependency set, same stack/mqueue limits, same `OnFailure=nav_smngpret.service` cascade — but split by role. `multimedia_ps` enumerates files on inserted media and builds the browse tree; `audio_ps` runs the GStreamer 0.10 pipeline that actually decodes a selected track. They coordinate over POSIX mqueues per the [forensic-denso-ipc.md](forensic-denso-ipc.md) `/PS_*_main` convention.

2. **USB hotplug is DENSO-custom, not udisks-driven.** [`/etc/udev/rules.d/10-local.rules`](../tmp/dsu-slot-a/etc/udev/rules.d/10-local.rules) ignores stock udisks rules and instead routes `sd[b-z]` add/change/remove events into [`/etc/udev/rules.d/insert.sh`](../tmp/dsu-slot-a/etc/udev/rules.d/insert.sh) → [`usbautomount.sh`](../tmp/dsu-slot-a/etc/udev/rules.d/usbautomount.sh). The script **only mounts VFAT partitions** (`PARTITION_QUERY="vfat"` hard-coded), under **`/android/data/system/tmp/sdXN`** (not `/media/`, not `/mnt/`), with options `utf8,rw`. **udisks is installed but inert** for USB media — it's there for compatibility, not actually used.

3. **`multimedia_ps` has `LimitSTACK=524288` (512 KB) and `LimitMSGQUEUE=8192000` (8 MB).** The 512 KB stack is **double** `tel_proc`'s 384 KB and equal to `audio_ps`/`abstc`'s 512 KB. The 8 MB POSIX mqueue ceiling (32× default) is identical to every other heavy-IPC daemon (`tel_proc`, `audio_ps`, `navi_ps`, `hmictrl_proc`, `display_ps`, `dispapf_proc`). This places `multimedia_ps` in the **second-tier daemon weight class** (between abs_clock at one end and navi_ps at the other) and confirms its IPC traffic is heavy enough that DENSO bumped the queue ceiling 32×.

4. **The browse-tree + cover-art parser is GStreamer 0.10 + TagLib + libsqlite3.** Slot A ships [`libTMC_GstID3Demux.so`](../tmp/dsu-slot-a/usr/lib/gstreamer-0.10/libTMC_GstID3Demux.so) + [`libTMC_GstASFDemux.so`](../tmp/dsu-slot-a/usr/lib/gstreamer-0.10/libTMC_GstASFDemux.so) + [`libTMC_GstMP4Demux.so`](../tmp/dsu-slot-a/usr/lib/gstreamer-0.10/libTMC_GstMP4Demux.so) (DENSO-replaced GST demuxers, presumably hardened/optimized for in-vehicle use), plus stock GST [`libgsttaglib.so`](../tmp/dsu-slot-a/usr/lib/gstreamer-0.10/libgsttaglib.so), [`libgstid3demux.so`](../tmp/dsu-slot-a/usr/lib/gstreamer-0.10/libgstid3demux.so), [`libgstapetag.so`](../tmp/dsu-slot-a/usr/lib/gstreamer-0.10/libgstapetag.so), [`libgstisomp4.so`](../tmp/dsu-slot-a/usr/lib/gstreamer-0.10/libgstisomp4.so), [`libtag.so.1.6.1`](../tmp/dsu-slot-a/usr/lib/libtag.so.1.6.1) (TagLib 1.6.1), [`libsqlite3.so.0.8.6`](../tmp/dsu-slot-a/usr/lib/libsqlite3.so.0.8.6), and [`libgsttag-0.10.so.0.24.0`](../tmp/dsu-slot-a/usr/lib/libgsttag-0.10.so.0.24.0). The DBM-vs-SQLite question is answered: **multimedia_ps links `libsqlite3.so.0`** (confirmed via `strings /tmp/dsu-naviwork-bin/multimedia_ps`). The index is a SQLite DB, not gdbm/Berkeley.

5. **No MTP support — USB Mass Storage only.** Slot A has `/lib/udev/rules.d/60-libmtp.rules` (a stock SYMLINK-only rules file matching ~3000 MTP device IDs) but **no `libmtp.so`** anywhere on Slot A and **no `mtp-tools` / `jmtpfs` / `gphoto2` binaries**. The libmtp rules file is dead infrastructure shipped by the Wind River BSP. iPhone/Android phones connected via USB show up as MSC if they expose one (most modern phones do not), otherwise they fail silently. iPod USB is handled by a **separate daemon** (`ipodplayer_ps`, see `nav_ipodplayer.service`) — not multimedia_ps.

6. **`multimedia_ps` is GUI-capable, unlike `abstc` or `tel_proc`.** It links `libemgdhmi.so.0`, `libEGL.so.1`, `libGLES_CM.so.1`, `libEMGD2d.so`, `libEMGDegl.so`, `libsvgr.so` (DENSO sprite renderer). It can draw to the EmgdHmi pixmap canvas directly. This is consistent with cover-art rendering being **owned by multimedia_ps** (decode JPEG/PNG from tag → blit to the now-playing strip's reserved sprite region) rather than handed off to `hmictrl_proc` / `display_ps`. Same pattern as `camera_ps` per [forensic-v2g-camera-handoff.md](forensic-v2g-camera-handoff.md) — backend daemon owns the pixels for its region; UI daemons own the chrome around it.

**Bottom line for the rebuild:** Replace `multimedia_ps` with a Qt6 `MediaLibrary` C++ service using **QtMultimedia + TagLib + Qt SQL (sqlite)** consuming a standard mainline udev/udisks2 auto-mount. ~3 days of work for full parity (artist/album/genre/playlist browse + cover art + on-insert auto-index). The factory's choice to mount under `/android/data/system/tmp/` is a DENSO Android-compat artifact we drop — mount under `/run/media/` or `/media/` like every modern Linux system.

---

## 1. Architecture Diagram

```
┌──────────────────────────────────────────────────────────────────────┐
│  UI: Music browse screens (Artist/Album/Genre/Playlist/Track lists, │
│      now-playing strip, cover art region)                            │
│      Browse tree + transport state owned by hmictrl_proc;            │
│      cover-art pixels owned by multimedia_ps directly                │
└──────────────────────────────────────────────────────────────────────┘
                          ▲ POSIX mqueue (DENSO IPC bus)
                          │ "browse Artists root"     → /multimedia_ps_main
                          │ "list Albums for Artist X" → /multimedia_ps_main
                          │ "play track id 12345"     → /audio_ps_main
                          │ events: "scan progress 42%", "now playing meta", "art ready"
┌──────────────────────────────────────────────────────────────────────┐
│  multimedia_ps "PS_MULTIMEDIA"  /home/naviwork/system/bin/multimedia_ps │
│  - Watches /tmp/.usbautomount/automount_list (touched by udev script)│
│  - On new mount: walk tree, demux tags via GStreamer 0.10, insert    │
│    rows into a SQLite DB cached on naviwork ext4                     │
│  - Serves browse queries (SQL → mqueue reply) to UI                  │
│  - Extracts embedded cover art, blits via libemgdhmi/EGL/svgr        │
└──────────────────────────────────────────────────────────────────────┘
                          ▲ POSIX mqueue (sibling traffic)
                          ▼ "track selected, decode this path"
┌──────────────────────────────────────────────────────────────────────┐
│  audio_ps "PS_AUDIO"  /home/naviwork/system/bin/audio_ps             │
│  - GStreamer 0.10 pipeline: filesrc → (TMC demuxer) → decoder → PA   │
│  - PulseAudio sink Stereo_out (plughw:0,0,0) S24-32LE                │
└──────────────────────────────────────────────────────────────────────┘
                          ▲ ALSA / PulseAudio
                          │
                  ┌───────────────────────┐
                  │  Bose 16-spkr / DAC   │
                  └───────────────────────┘

Parallel ingest path (USB insert):
  USB stick ━▶ kernel sd[b-z] ━▶ udev SUBSYSTEM=="block",ACTION=="add" ━▶
  /etc/udev/rules.d/insert.sh ━▶ usbautomount.sh (vfat-only) ━▶
  mount -t vfat -o utf8,rw /dev/sdb1 /android/data/system/tmp/sdb1 ━▶
  multimedia_ps notices new entry in /tmp/.usbautomount/automount_list ━▶
  walk + tag-parse + SQLite insert ━▶ mqueue "library ready" ━▶ UI refresh
```

---

## 2. Layer 1 — USB hotplug and mount

### 2.1 The DENSO udev override

**File:** `/tmp/dsu-slot-a/etc/udev/rules.d/10-local.rules`

```
# UDEV rules for USB storage device
# Copyright (C) DENSO Corp.
# rev.20121203 redefine whole configurations

SUBSYSTEM=="block", ACTION=="change", KERNEL=="sd[b-z]", ATTR{size}!="0", RUN+="/bin/bash /etc/udev/rules.d/insert.sh %r/%k", GOTO="am_end"
SUBSYSTEM=="block", ACTION=="change", KERNEL=="sd[b-z]", ATTR{size}=="0", RUN+="/bin/bash /etc/udev/rules.d/remove.sh %r/%k", GOTO="am_end"
SUBSYSTEM=="block", ACTION=="add",    KERNEL=="sd[b-z]", RUN+="/bin/bash /etc/udev/rules.d/insert.sh %r/%k", GOTO="am_end"
SUBSYSTEM=="block", ACTION=="remove", KERNEL=="sd[b-z]", RUN+="/bin/bash /etc/udev/rules.d/remove.sh %r/%k", GOTO="am_end"

LABEL="am_end"
```

Three forensic facts here:

- **`sd[b-z]`** — `sda` is excluded (that's the internal eMMC). Only externally-attached USB block devices trigger automount.
- **Both `add` and `change`** events are caught. `change` with `ATTR{size}!="0"` covers the SD-card-with-newly-inserted-media path; `change` with `ATTR{size}=="0"` covers media-eject without device-removal.
- **`GOTO="am_end"`** short-circuits any subsequent udev rule processing for the same event. Stock udisks rules (80-udisks.rules) never get to run on `sd[b-z]`.

`udisks-daemon` is enabled (`/lib/systemd/system/udisks.service`) but it never sees these block devices — the DENSO rule fires first and skips udisks's drive-enumeration. udisks is alive only for whatever other consumers (none, in practice) might query it via D-Bus.

### 2.2 The mount script

**File:** `/tmp/dsu-slot-a/etc/udev/rules.d/usbautomount.sh` (rev `20130712n`, ~190 LoC)

Key constants:
```sh
PARTITION_QUERY="vfat"
MOUNTPATH_BASE="/android/data/system/tmp"
REC_DIR="/tmp/.usbautomount"
REC_FILE="automount_list"
```

Behavior:
1. **Race-locks** via `$REC_DIR/lock` file with 100 ms sleep loop — prevents concurrent insert/remove from corrupting the record file.
2. **Filesystem filter:** `blkid -t TYPE=vfat -o device | grep "$1"` — if the partition isn't VFAT (FAT16/FAT32), `common_exit 0` (silent ignore). **NTFS, exFAT, ext4, HFS+ USB drives are silently dropped on the floor.**
3. **Waits up to 60 s** for `/android/data/system/tmp` to be a real mount (loops 600 × 100 ms checking `mount | grep`). This is the Android tmpfs that needs to be up before we mount under it.
4. `mkdir -p /android/data/system/tmp/sdb1; mount -t vfat -o utf8,rw /dev/sdb1 /android/data/system/tmp/sdb1`
5. Appends `/dev/sdb1 /android/data/system/tmp/sdb1 vfat` to `$REC_FILE` — this is **how multimedia_ps discovers the new mount**: by polling/inotify-watching that record file.

Errors echo to `/dev/kmsg` (not syslog) — visible in `dmesg` after boot. No exit code goes back to udev.

### 2.3 The unmount script

`usbautoremove.sh` (rev `20130411n`) mirrors: looks up the device in `$REC_FILE`, `umount -l` (lazy — twice with retry), `rmdir`, removes the record entry. Lazy unmount means **multimedia_ps doesn't need to release the SQLite/tag handles before the user yanks the stick** — the kernel keeps the mount alive for any process still holding open files, but new accesses fail. Practical for car-kit UX where users pull sticks unannounced.

### 2.4 Why `/android/data/system/tmp/` is the mount target

This is a vestige of the **Android-init-script-managed userdata partition** that the DENSO build inherits (per [CLAUDE.md](../CLAUDE.md): `/sbin/init android` runs the init.rc tree). The DSU rootfs sets up `/android/data/system/tmp` as a tmpfs early in boot, and DENSO chose it as the USB-media parent so the Android side of the system has the same view. **Plan B''' kills the Android init path entirely, so this convention is dropped on rebuild** — see §8.

---

## 3. Layer 2 — `multimedia_ps` daemon

### 3.1 Service unit

**File:** `/tmp/dsu-slot-a/lib/systemd/system/nav_multimedia.service`

```ini
[Unit]
Description=PS_MULTIMEDIA Service
Requires=nav_pre.target
OnFailure=nav_smngpret.service
DefaultDependencies=no

[Service]
Type=simple
StandardInput=null
StandardOutput=null
StandardError=null
LimitSTACK=524288
LimitMSGQUEUE=8192000

ExecStart=/home/naviwork/system/bin/multimedia_ps "PS_MULTIMEDIA"

TimeoutSec=90
SendSIGKILL=yes
```

**Wanted-by:** `/lib/systemd/system/nav_pre.target.wants/nav_multimedia.service`.

### 3.2 Notable properties

| Property | Value | Forensic meaning |
|---|---|---|
| `LimitSTACK=524288` | 512 KB | Tied with `abs_clock`/`audio_ps`; **double** `tel_proc`/`ipodplayer_ps` (384 KB). Implies a larger thread pool than the phone stack — consistent with parallel tag-extraction workers. |
| `LimitMSGQUEUE=8192000` | 8 MB | 32× default. Same as the other heavy-IPC daemons — browse tree updates can be megabytes for large libraries. |
| `OnFailure=nav_smngpret.service` | system-pre-reset cascade | One of **20 services** that trip the smng reset cascade per [forensic-daemon-supervision.md](forensic-daemon-supervision.md). Music-library crash = full UI reset. DENSO treats it as critical. |
| `Requires=nav_pre.target` | early-tier nav service | Started **before** UI daemons so the library is reachable by the time hmictrl_proc opens the audio panel. |
| `DefaultDependencies=no` | bypasses standard ordering | Managed by smng explicitly. |
| stdio | null | Headless; logs via the DENSO `liboslog.so` / `libabendlog.so` chain. |
| no `Restart=` | one crash → OnFailure | Like the UI daemons and unlike abs_clock. No respawn — falls through to system reset. |
| `argv0=PS_MULTIMEDIA` | smng PS-name | Registered with smng under that name; `mq_open("/multimedia_ps_main", …)` for inbox (per [forensic-denso-ipc.md](forensic-denso-ipc.md) §1). |

### 3.3 The binary

| | |
|---|---|
| Path on target | `/home/naviwork/system/bin/multimedia_ps` |
| Path on host | `/tmp/dsu-naviwork-bin/multimedia_ps` |
| Size | **14,808 B** (stripped) — essentially a thin shell |
| Format | ELF 32-bit LSB, Intel 80386, dynamically linked, GNU/Linux 2.6.25 |
| BuildID | `89b4816fdf251a6f6488dfd0a63031ef0778865d` |
| Hard-coded mqueue | `/multimedia_ps_main` (matches [forensic-denso-ipc.md](forensic-denso-ipc.md) `/PS_*_main` convention exactly) |
| Hard-coded PS string | `PS_AUD01` (curious — see §3.5) |
| Direct entry points | `PMNG_main_initialize`, `PMNG_main_loadCompleted`, `PMNG_main_startUnload`, `PMNG_main_unloadCompleted`, `PMNG_main_finalize` |

The 14 KB shell is the standard DENSO **napl/pmng wrapper** pattern: `main()` calls `PMNG_main_initialize`, opens the mqueue, enters the `Btasrif_Recv_Main` loop. All actual logic lives in the linked libraries.

### 3.4 Library set (from binary `strings`)

| Library | Role |
|---|---|
| `libsqlite3.so.0` | **Music library DB backend** — confirms SQLite, not gdbm/Berkeley |
| `libifout.so` | DENSO IPC outbound (per [forensic-denso-ipc.md](forensic-denso-ipc.md)) |
| `libifin_os.so` | DENSO IPC inbound shim |
| `libioc.so` | I/O coordinator |
| `libpmng.so` | Process management (the napl wrapper) |
| `libplnch.so` | Process launcher |
| `libsmng_cmn.so` | smng client common |
| `libabendlog.so` | "Abend" (abnormal-end) crash logger |
| `libpriv.so` | Privilege helpers |
| `liboslog.so` | OS-level logger |
| `libpdm.so` | **Persistent Data Manager** (SQLite-wrapping settings cache — proven SQLite consumer per `pdm_*_sqliteRet*` exports) |
| `libism.so` | Inter-state machine |
| `libvsi.so` | Vehicle Signal Interface |
| `libwccm.so` / `libwcp.so` / `libwcm.so` / `libwcna.so` | WiFi connection/network management (irrelevant to music — multimedia_ps links them defensively as part of the WiFi-Direct / DLNA-future plumbing) |
| `libbtavm.so` | **BT A/V Manager** — A2DP source switching (when phone is the audio source instead of USB) |
| `libabm.so` | Audio bus manager |
| `libsound.so` | Sound HAL |
| `libstsmng.so` | State/source manager |
| `libsvgr.so` | **DENSO SVGR sprite renderer** — overlay/sprite blitter for cover art |
| `libemgdhmi.so.0` | EmgdHmi pixmap canvas (per [forensic-libemgdhmi-api.md](forensic-libemgdhmi-api.md)) |
| `libEGL.so.1`, `libGLES_CM.so.1`, `libEMGD2d.so`, `libEMGDegl.so` | EGL/GLES rendering path |
| `libims.so` | Input message service |
| `libstc_if.so` | "STC" interface (likely satellite/streaming compositor) |
| `libdrl.so`, `libvlm.so`, `libdu_opn.so`, `libcam.so` | DENSO Reset Logger, Vehicle Log Manager, "Daughter Unit OPN", camera (drag-along — used by every UI-capable daemon) |
| `libkeyutils.so.1` | Kernel keyring access (TBD purpose) |
| `librt.so.1`, `libpthread.so.0`, `libstdc++.so.6` | Standard runtime — threads + C++ STL |
| `libz.so.1` | zlib — probably gzip-decompressing embedded ID3 frames |
| `libdrm.so.2`, `libemgdsrv_*.so`, `libioucm.so` | DRM + EMGD server transitive deps |

**Notable absences:**
- No `libgstreamer-0.10.so.0` directly — so multimedia_ps probably uses GST via dlopen-of-individual-demuxers, OR shells out to `gst-launch-0.10`, OR (most likely) uses `libsound.so` / `libabm.so` as a DENSO abstraction over GST. The actual tag-parsing happens **inside `audio_ps`** which links the GST pipeline; multimedia_ps may request audio_ps to scan via mqueue.
- No `libtag.so.1` direct link — same: tag extraction may be delegated to audio_ps's GST pipeline (`taginject`/`taglib` element output piped back via mqueue), OR multimedia_ps dlopens libtag at runtime.
- No `libdbus*` — DENSO IPC is mqueue, not D-Bus (per [forensic-denso-ipc.md](forensic-denso-ipc.md) §4).
- No `libmtp.so` — confirms USB-MSC-only (see §4).
- No `libjpeg.so` / `libpng.so` direct link — cover art rendering may go through `libsvgr.so` (which transitively pulls these) or through GST's `libgstpng.so` / `libgstjpeg.so` plugins.

### 3.5 The `PS_AUD01` string

Both `multimedia_ps` and `audio_ps` binaries contain the hard-coded string `PS_AUD01`. The systemd `ExecStart` passes `PS_MULTIMEDIA` and `PS_AUDIO` respectively as argv[1]. The `PS_AUD01` is likely **the smng-side family identifier** (the "audio family" of services, of which both daemons are members), used for shared-state queries — distinct from the per-daemon inbox name (`/multimedia_ps_main` vs. `/audio_ps_main`). DENSO uses this two-level naming to let smng query "is audio subsystem alive" without caring which specific PS process answers.

### 3.6 multimedia_ps vs. audio_ps — division of labor

Both daemons have **identical library sets** except multimedia_ps has `libism.so` (state machine) and `libstc_if.so` (STC interface) where audio_ps has equivalent stubs. The split is by **lifecycle phase**, not capability:

| Concern | multimedia_ps | audio_ps |
|---|---|---|
| USB mount detection | **owns** | — |
| File tree walk | **owns** | — |
| Tag extraction (ID3/MP4/ASF/etc) | **owns** (via GST or libtag) | — |
| SQLite library DB | **owns** | reads (track lookup) |
| Cover-art extraction + blit | **owns** | — |
| Browse queries from UI | **owns** (serves) | — |
| Playback request "play track N" | forwards to audio_ps | **owns** |
| GStreamer decode pipeline | — | **owns** |
| PulseAudio sink output | — | **owns** |
| Source switching (USB ↔ BT ↔ FM) | participates (via libstsmng) | **owns** (via libabm) |

This is consistent with `audio_ps` having no `Environment=GST_REGISTRY_UPDATE=no` only at its own service file (we see this in [`nav_audio.service`](../tmp/dsu-slot-a/lib/systemd/system/nav_audio.service) but **not** in [`nav_multimedia.service`](../tmp/dsu-slot-a/lib/systemd/system/nav_multimedia.service)) — audio_ps is the primary GST consumer; multimedia_ps may not invoke the full pipeline directly.

---

## 4. Layer 3 — Tag parsing and supported formats

### 4.1 Tag/metadata libraries on Slot A

| Library | Purpose | Version |
|---|---|---|
| `libtag.so.1.6.1` | TagLib C++ (ID3v1/v2, APE, MP4 atoms, FLAC, Vorbis comments, ASF, WAV INFO) | 1.6.1 (2010) |
| `libtag_c.so.0.0.0` | TagLib C bindings | 0.0.0 |
| `libgsttag-0.10.so.0.24.0` | GStreamer 0.10 tag base library | 0.10.x.24 |
| `libid3demux.so` *(stock GST plugin)* | ID3v1/v2 demuxer | GST 0.10 |
| `libapetag.so` *(stock GST plugin)* | APE tag demuxer | GST 0.10 |
| `libgsttaglib.so` *(stock GST plugin)* | TagLib-backed unified tag reader | GST 0.10 |
| `libFLAC.so.8.2.0` + `libvorbis.so.0.4.4` + `libogg.so.0.7.0` | FLAC/Vorbis/Ogg via stock GST | recent |
| `libsqlite3.so.0.8.6` | DB backend | SQLite 3 (0.8.6 SONAME) |
| `libdb-4.8.so` | Berkeley DB 4.8 | present but unused by multimedia_ps |
| `libgdbm.so.3.0.0` | GDBM | present but unused |

### 4.2 DENSO-replaced GStreamer plugins (`libTMC_*`)

| TMC plugin | Replaces | Why DENSO replaced it |
|---|---|---|
| `libTMC_GstID3Demux.so` | `libgstid3demux.so` | Hardening / vehicle-spec quirks (handles bad UTF-8, embedded CRLF in tags, oversized art frames without OOM) |
| `libTMC_GstASFDemux.so` | `libgstasf.so` (mainline `asfdemux`) | WMA / ASF support — mainline asfdemux has historically been buggy on malformed streams |
| `libTMC_GstMP4Demux.so` | `libgstisomp4.so` | M4A / MP4 container parsing |
| `libTMC_GstAACDec.so` | mainline AAC decoders | LC-AAC decode |
| `libTMC_GstMP3Dec.so` | `libgstmad.so` / `libgstmpegaudioparse.so` | MP3 decode |
| `libTMC_GstWMADec.so` | (no mainline equivalent under WMA patents) | WMA decode — required for parity with factory feature list ([feature-parity-audit.md](feature-parity-audit.md) §1.3 lists "MP3/WMA/AAC") |
| `libTMC_GstAudioConvert.so` | `libgstaudioconvert.so` | Sample-format conversion |
| `libTMC_GstReSample.so` | `libgstaudioresample.so` | Sample-rate conversion |

The "TMC" prefix is probably **Toyota/Toshiba Multimedia Component** (or DENSO's internal "TMC" automotive-grade media component group). These plugins are the actual decode chain `audio_ps` uses for playback.

### 4.3 Supported audio format matrix

Derived from the GStreamer 0.10 plugin set present on Slot A:

| Format | Container | Decoder | Tag reader | Library scan supported? |
|---|---|---|---|---|
| MP3 | bare / ID3v1 / ID3v2 | `libTMC_GstMP3Dec.so` | `libTMC_GstID3Demux.so` | ✅ |
| AAC | ADTS | `libTMC_GstAACDec.so` | (in-stream) | ✅ |
| M4A (AAC in MP4) | MP4/ISO-BMFF | `libTMC_GstAACDec.so` via `libTMC_GstMP4Demux.so` | MP4 metadata atoms | ✅ |
| WMA | ASF | `libTMC_GstWMADec.so` via `libTMC_GstASFDemux.so` | ASF metadata | ✅ |
| WAV | RIFF | `libgstwavparse.so` (stock) | INFO chunk via `libtag` | ✅ (factory undocumented but supported by plugin set) |
| FLAC | Ogg / native | `libgstflac.so` (stock) | Vorbis comments | ⚠️ stock plugin present, factory feature list doesn't mention FLAC — **maybe disabled by policy** |
| Ogg Vorbis | Ogg | `libgstvorbis.so` + `libgstogg.so` (stock) | Vorbis comments | ⚠️ same — plugin present, feature doc silent |
| ALAC | MP4 | not present | — | ❌ |
| AIFF | AIFF | not present | — | ❌ |
| Opus | Ogg | not present (Opus didn't exist in GST 0.10 era) | — | ❌ |

**Factory-documented:** MP3, WMA, AAC (per [feature-parity-audit.md](feature-parity-audit.md) §1.3 "USB media playback (USB-A port, MP3/WMA/AAC, folder/artist/album browse)").

**Plugin-present but undocumented:** WAV, FLAC, Vorbis. Probably hard-disabled by multimedia_ps's file-extension whitelist; user wouldn't notice because almost nobody puts FLAC on a USB stick they hand to a 2017 Infiniti.

### 4.4 Cover art

No explicit `libcoverart.so` / `libalbumart.so` on Slot A. The path is one of:

1. **Embedded ID3 APIC frame** → `libTMC_GstID3Demux.so` exposes it as a GstSample with caps `image/jpeg` or `image/png` → multimedia_ps reads bytes from sample → decodes via `libgstjpeg.so` / `libgstpng.so` (stock GST plugins, present) → blits via `libsvgr.so` to a reserved sprite region in the EmgdHmi canvas → UI's now-playing strip sees the sprite.

2. **External `folder.jpg` / `cover.png` / `AlbumArt*.jpg`** in the track's directory — multimedia_ps reads the file directly, decodes, blits same path.

3. **No art** → multimedia_ps publishes a sentinel and UI draws a placeholder (the generic music-note icon visible in the factory now-playing screen).

The blit-direct approach (multimedia_ps owns the cover art pixels in the canvas) is **inferred** from multimedia_ps linking the EGL stack directly. Alternative — multimedia_ps writes a tmp file like `/tmp/.musicart/current.jpg` and sends a file-path event; UI loads/draws — is **possible** but inconsistent with linking libemgdhmi/libsvgr. The blit-direct approach is also faster (no second decode in the UI process) and avoids tmpfs pressure.

**Open question:** which one it actually is, resolvable by `strace -e openat -p $(pidof multimedia_ps)` on a paused factory unit while opening the now-playing screen.

---

## 5. Layer 4 — Library DB (SQLite)

`multimedia_ps` **definitely** uses `libsqlite3.so.0` — confirmed in binary `strings`. The DB schema and location are not visible from Slot A because the DB lives on the persistent naviwork partition (probably `/home/naviwork/data/` or `/home/naviwork/var/`).

**Inferred schema** (standard car-kit music library pattern, 4-table normalized):

```sql
CREATE TABLE tracks (
  id INTEGER PRIMARY KEY,
  path TEXT NOT NULL,           -- absolute path under mountpoint
  device_id INTEGER,            -- FK to devices (which USB stick)
  title TEXT, artist_id INTEGER, album_id INTEGER, genre_id INTEGER,
  track_num INTEGER, duration_ms INTEGER,
  bitrate INTEGER, samplerate INTEGER, channels INTEGER,
  format TEXT,                  -- 'mp3' | 'wma' | 'm4a' | 'aac'
  art_blob_id INTEGER,          -- FK to art table or NULL
  scanned_at INTEGER
);
CREATE TABLE artists (id INTEGER PRIMARY KEY, name TEXT UNIQUE);
CREATE TABLE albums  (id INTEGER PRIMARY KEY, name TEXT, artist_id INTEGER, year INTEGER, art_blob_id INTEGER);
CREATE TABLE genres  (id INTEGER PRIMARY KEY, name TEXT UNIQUE);
CREATE TABLE devices (id INTEGER PRIMARY KEY, label TEXT, uuid TEXT, last_seen INTEGER);
CREATE TABLE art     (id INTEGER PRIMARY KEY, format TEXT, blob BLOB);  -- or path to tmpfile
CREATE TABLE playlists      (id INTEGER PRIMARY KEY, name TEXT, device_id INTEGER);
CREATE TABLE playlist_items (playlist_id INTEGER, track_id INTEGER, position INTEGER);
```

**Open question — Confirmed unknown:** schema, file path, whether DB is per-device or global, whether it survives across boots (probably yes, on naviwork ext4; otherwise re-scan cost on every ACC-ON would be visible in user-perceived wait times). Resolvable by `ls /home/naviwork/data/*.db` and `sqlite3 <db> '.schema'` once naviwork is extracted.

**Indexing trigger:** `multimedia_ps` notices a new line in `/tmp/.usbautomount/automount_list`, walks the tree, parses tags, INSERTs rows. Likely uses **a worker thread pool** (hence 512 KB stack — enough for a `pthread_create(stack=128KB) × 4 workers`). Bulk INSERTs probably wrapped in a single transaction per album to avoid SQLite WAL/journal thrash.

---

## 6. Layer 5 — IPC contract (multimedia_ps ↔ UI ↔ audio_ps)

Per [forensic-denso-ipc.md](forensic-denso-ipc.md):

| Queue | Owner | Direction | Notes |
|---|---|---|---|
| `/multimedia_ps_main` | multimedia_ps | inbox | UI sends browse queries; audio_ps sends "I'm playing track X" status |
| `/audio_ps_main` | audio_ps | inbox | multimedia_ps forwards "play this track id" + path; UI sends transport (play/pause/next/prev/seek) |
| `/hmictrl_proc_main` | hmictrl_proc | inbox | multimedia_ps publishes browse-list results + scan-progress events |
| `/display_ps_main` | display_ps | inbox | multimedia_ps publishes now-playing strip updates + cover-art-ready notifications |

**Drain implication for Plan B''':** Because Plan B''' kills `navi_ps` + `dispapf_proc` (per [project_planB_kill_set.md](../../../.claude/projects/-Users-dpitek-Developer-q60-rebuild/memory/project_planB_kill_set.md)) but **keeps** `hmictrl_proc` + `display_ps` + `audio_ps` + `multimedia_ps` alive, the music browse → UI publish path is unaffected by Plan B''' as currently scoped. The two killed daemons are navigation-only. **If we additionally replace the audio library UI with our own Qt6 panel** (which is the Plan B'''' direction), we will need to either keep the factory hmictrl/display drawing the audio panel OR also kill them and impersonate their inboxes.

---

## 7. Daemon supervision table

Comparative table for the heavy nav daemons (extends the one in [forensic-clock-service.md](forensic-clock-service.md) §1.1 and [forensic-phone-stack.md](forensic-phone-stack.md) §6.2):

| Service | argv0 | LimitSTACK | LimitMSGQUEUE | OnFailure | Restart | UI-capable |
|---|---|---|---|---|---|---|
| `nav_multimedia.service` | `PS_MULTIMEDIA` | 524288 | 8192000 | smngpret | (none) | **yes** (links EGL/EMGD) |
| `nav_audio.service` | `PS_AUDIO` | 524288 | 8192000 | smngpret | (none) | yes (links EGL/EMGD) |
| `nav_ipodplayer.service` | `PS_IPODPLAYER` | 393216 | 8192000 | smngpret | (none) | no (LD_LIBRARY_PATH lacks wsegl) |
| `nav_tel.service` | `PS_TEL` | 393216 | 8192000 | smngpret | (none) | no |
| `abs_clock.service` | `abstc` direct | 524288 | (default) | (commented out) | on-failure / 100ms | no |
| `nav_hmictrl.service` | `PS_HMICTRL` | … | 8192000 | smngpret | (none) | **yes** (the chrome owner) |

`multimedia_ps` is **structurally identical** to `audio_ps` and **strictly larger** than the phone daemon (`tel_proc`) on stack budget — consistent with parallel scan workers and in-memory blob staging for cover art.

---

## 8. Rebuild Implications

### 8.1 Replacement plan

| Factory layer | Replacement | Effort | Notes |
|---|---|---|---|
| DENSO udev `10-local.rules` + `usbautomount.sh` + `usbautoremove.sh` | **udisks2 + systemd-mount** (mainline) under `/run/media/$USER/`; OR a tiny ~30-line custom udev rule that mounts under `/media/usb<N>` | half-day | Drop the `/android/data/system/tmp/` convention; drop the VFAT-only restriction (modern users have exFAT sticks) |
| `multimedia_ps` (library indexer) | **Qt6 `MediaLibrary` C++ service** in our monolithic nav app: `QFileSystemWatcher` on `/media/` → `QtConcurrent::run(walkAndTag)` → `TagLib::FileRef` per file → `QSqlDatabase("QSQLITE")` inserts | ~2 days | TagLib still maintained; QtSql works fine on i386 + glibc |
| `audio_ps` (playback) | **QMediaPlayer (Qt6) + GStreamer 1.x backend** OR PipeWire role-based playback | ~1 day | Mainline GStreamer 1.x has same demuxers + decoders, plus Opus/FLAC parity |
| `libsvgr.so` cover-art blit path | **`QQuickImageProvider`** in QML — feed JPEG/PNG bytes; QML Image renders | trivial | No more shared-memory hand-off — direct memory transfer in-process |
| `libTMC_GstID3Demux.so` etc. | **stock GStreamer 1.x demuxers** (or TagLib bypasses GST entirely for the scan path) | none | Lose the DENSO hardening — accept the risk; TagLib + GST 1.x have had a decade of hardening since 2012 |
| `nav_ipodplayer.service` (iPod-USB) | **libimobiledevice + libgpod** if we care; OR drop entirely (iPod-USB is a 2010-era feature, ~zero current users) | 0–2 days | Recommend: ship without; revisit if users complain |
| SQLite DB on naviwork ext4 | **SQLite on Slot B** (`/var/lib/q60nav/library.db`) | trivial | Survives boots, easy to inspect with `sqlite3` |
| Index trigger via `automount_list` polling | **D-Bus signal from udisks2 / inotify on `/media/`** | trivial | Modern, race-free |

Total: **~3–4 days** for full music-library parity in the rebuild — substantially smaller than the phone stack rebuild because we ship far less DENSO-specific glue.

### 8.2 Format support expectations after rebuild

| Format | Factory | Rebuild |
|---|---|---|
| MP3 | ✅ | ✅ |
| AAC / M4A | ✅ | ✅ |
| WMA | ✅ | ⚠️ (mainline GST has `wmadec` only with `gst-plugins-ugly` + ffmpeg, license-encumbered — accept WMA loss or ship ugly) |
| WAV | (probably) | ✅ |
| FLAC | (plugin present, unclear if exposed) | ✅ |
| Ogg Vorbis | (plugin present, unclear if exposed) | ✅ |
| Opus | ❌ | ✅ (modern GST has it; modern phones export Opus) |
| ALAC | ❌ | ✅ free with ffmpeg |
| exFAT-formatted USB | ❌ (vfat-only) | ✅ (kernel exfat or fuse-exfat) |
| NTFS-formatted USB | ❌ | ✅ (ntfs-3g) |
| ext4-formatted USB | ❌ | ✅ trivially |

**Net rebuild gain:** Opus, ALAC, modern filesystems, and the cosmetic disappearance of the "vfat-only" silent-drop behavior. **Net loss:** WMA (acceptable — WMA on USB in 2026 is a fringe use case).

### 8.3 Kill set additions for Plan B'''

Per [project_planB_kill_set.md](../../../.claude/projects/-Users-dpitek-Developer-q60-rebuild/memory/project_planB_kill_set.md), current Plan B''' kills `navi_ps` + `dispapf_proc` only. **For the music-library rebuild specifically:**

- **Phase 1 (immediate):** No additions. Music browse stays on factory daemons; we focus on display gate + nav UI replacement first.
- **Phase 2 (when we ship our own music UI):** Add `nav_multimedia.service` and `nav_audio.service` to the mask list (`systemctl mask`); drain `/multimedia_ps_main` and `/audio_ps_main` from Qt with the same drain-thread pattern as the 4 UI inboxes. Both services trip `OnFailure=nav_smngpret.service` if they die without being masked, so masking is mandatory — we cannot just `kill -9`.
- **Phase 2 also requires:** disabling the DENSO `/etc/udev/rules.d/10-local.rules` (rename to `.bak` or replace with our own) so our udisks/inotify path owns USB mounting unilaterally.

---

## 9. Open Questions

Resolvable only with the naviwork ext4 mounted + live-device probes:

1. **SQLite DB path and schema.** Where is the library DB on disk? Per-device or global? Is there a WAL? `ls /home/naviwork/data/*.db` + `sqlite3 .schema`.
2. **Cover-art delivery mechanism.** Direct blit via `libsvgr.so` (inferred), or tmpfile path + UI reads? `strace -e trace=openat,write,mmap -p $(pidof multimedia_ps)` while inserting a USB stick with album art.
3. **Scan worker count and threading model.** 4 workers? 8? `gdb --batch -ex 'info threads' -p $(pidof multimedia_ps)` during a scan.
4. **Playlist support.** Does multimedia_ps read .m3u/.pls/.wpl files from USB, or only build "all songs by artist" virtual lists? Factory feature audit says "folder/artist/album browse" — silent on playlist files. Probably reads M3U if present (cheap to support); confirm by inserting test stick.
5. **iPod browse split.** Is iPod artist/album browse handled by `ipodplayer_ps` separately or does it forward into multimedia_ps's tree? `nav_ipodplayer.service` has its own daemon, so likely separate.
6. **A2DP-source music metadata.** AVRCP track metadata from a paired phone playing music — does multimedia_ps consume this, or does `tel_proc` (which manages the BT connection), or is it `libbtavm.so` injecting directly into the now-playing display? Confirm by playing music from a phone and inspecting mqueue traffic.
7. **Library refresh policy.** Full re-scan on every insert? Incremental based on file mtime? Hash-based dedupe across multiple sticks? Measurable by reinsert timing on a large stick.
8. **Cover-art cache.** Is decoded JPEG cached as decoded RGB in the DB, or re-decoded per now-playing-display? Affects perceived screen-update lag.

---

## 10. Cross-references

- [forensic-clock-service.md](forensic-clock-service.md) — same backend-daemon + UI-region pattern; abstc lacks EGL so the comparison highlights why multimedia_ps **does** link EGL (cover art)
- [forensic-phone-stack.md](forensic-phone-stack.md) — sister analysis; tel_proc has 384 KB stack vs. multimedia_ps's 512 KB — direct evidence of multimedia_ps's thread-pool indexing model
- [forensic-daemon-supervision.md](forensic-daemon-supervision.md) — `OnFailure=nav_smngpret.service` cascade applies; multimedia_ps is one of 20 services in the cascade
- [forensic-denso-ipc.md](forensic-denso-ipc.md) — `/multimedia_ps_main` mqueue convention; `libifout.so` outbound; drain semantics; argv0 → queue-name mapping
- [forensic-factory-ui-binary.md](forensic-factory-ui-binary.md) — confirms hmictrl_proc + display_ps own browse-tree chrome; multimedia_ps owns its own pixel region (cover art)
- [forensic-libemgdhmi-api.md](forensic-libemgdhmi-api.md) — EmgdHmi canvas surface model used by multimedia_ps for cover-art blits
- [forensic-v2g-camera-handoff.md](forensic-v2g-camera-handoff.md) — analogous backend-owns-pixels pattern (camera_ps); reinforces inference that cover art is direct-blit not tmpfile-handoff
- [feature-parity-audit.md](feature-parity-audit.md) §1.3 — visible music-library features we must preserve (MP3/WMA/AAC, folder/artist/album browse, AVRCP album art)
- [CLAUDE.md](../CLAUDE.md) — Android-init explanation for why mountpoint is `/android/data/system/tmp/`
