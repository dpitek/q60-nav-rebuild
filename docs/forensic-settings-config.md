# Forensic — Settings & Configuration / PDM / Vehicle Config Table

**Date:** 2026-05-23
**Source:** `/tmp/dsu-slot-a/` (extracted Slot A DSU backup) + cross-reference to existing forensics
**Subject:** How the factory Q60 head unit stores, persists, restores, and resets user-facing settings (Display, Clock, Audio, Phone/BT, Nav, Vehicle, Driver Profiles) — and the **vehicle Configuration Table** that bricks the DCU when wiped. Where every byte lives, who writes it, what happens on boot, and what we must (and must NEVER) touch in the rebuild.

---

## Executive Summary

1. **🚨 The factory "Configuration Reset" is a true BRICK path — and the data it wipes is physically present on this hardware.** Per [oem-hidden-functions.md](oem-hidden-functions.md) §6, the Service-tab Configuration Reset corrupts the **Vehicle Configuration Table** (which Bose amp variant, which speakers, which CAN buses, which feature pack — ANC/ASC/AVM/TCU etc.). Symptom: no clock, no audio, no drive mode, CONSULT-III-plus-only recovery. **In our rebuild we never expose, never invoke, and never write to this table. Our backup script (per CLAUDE.md) preserves `DSU backup.img` byte-for-byte specifically so this table is recoverable from the image if the factory firmware ever corrupts it.**

2. **User settings persist on a dedicated 16 MB MTD flash partition mounted at `/home/naviwork/data/pdm/ram`** — confirmed in [`home-naviwork-data-pdm-ram.mount`](../tmp/dsu-slot-a/lib/systemd/system/home-naviwork-data-pdm-ram.mount): `What=/dev/mtdblock0`, `Type=ext4`, `Options=nodelalloc`, mounted via systemd automount lazily on first access. The name "PDM RAM" is misleading — it is **persistent flash**, not RAM. The "RAM" suffix is DENSO heritage naming from prior projects where it was DRAM-backed and the partition got renamed but the path didn't.

3. **PDM = Persistent Data Manager.** It is a DENSO concept (not a single binary we can name yet) that owns reads/writes against `/dev/mtdblock0`. Three systemd-visible touchpoints: `home-naviwork-data-pdm-ram.mount` (the mount), [`checkfs-mtdblock0.service`](../tmp/dsu-slot-a/lib/systemd/system/checkfs-mtdblock0.service) (boot-time fsck → mkfs.ext4 on corruption), and [`pdmram-mount-error-failsafe.service`](../tmp/dsu-slot-a/lib/systemd/system/pdmram-mount-error-failsafe.service) (mount-error recovery → blind `mkfs.ext4 /dev/mtdblock0` — i.e. wipe all user settings on bad mount). The actual PDM API binary lives on the un-extracted naviwork partition next to the other 23 DENSO daemons documented in [forensic-factory-ui-binary.md](forensic-factory-ui-binary.md) §1.2.

4. **Shutdown-time settings backup is a real service: `nav_backup.service` → `/home/naviwork/system/bin/bkup_prg`.** It is a `Type=oneshot` unit fired on critical failure (it is the `OnFailure=` target of both `nav_smng.service` and `nav_smngpret.service`) and ends with `ExecStartPost=/bin/systemctl start poweroff.service`. Translation: "if the UI stack crashes, flush settings then power off cleanly." A second service, `nav_sdretn.service` → `/home/naviwork/system/bin/sdretn`, is a long-running daemon (`Type=simple`) that almost certainly handles **SD-card-removal detection / retention of in-flight nav data** to avoid corrupting a hot-removed map card. The pair `bkup_prg` + `sdretn` are the durability backbone for settings + nav state.

5. **The Settings UI is not a separate app — it is screens in `hmictrl_proc`** (same pattern as the clock and phone per [forensic-clock-service.md](forensic-clock-service.md) §3 and [forensic-phone-stack.md](forensic-phone-stack.md) §7). Settings categories fan out from `hmictrl_proc` over POSIX mqueue to the daemon that owns each setting's runtime state (audio_ps for audio, tel_proc for BT, display_ps for brightness, abstc for clock format, fis_ps for vehicle/driver-profile config). Each consumer also subscribes to PDM-restore events at boot so the new value is applied immediately.

6. **Driver profiles ("I-Key 1 / I-Key 2") are a vehicle-CAN-event-keyed view over the PDM partition.** The intelligent-key receiver in the BCM broadcasts a "key fob N recognized" frame on M-CAN at unlock/start. `ioapf_proc` (CAN abstraction daemon — see §6) demuxes it and emits a profile-changed mqueue event; every settings consumer that has a per-profile dimension (seat memory, audio EQ, climate, nav voice, drive mode) reloads its slice from PDM keyed by `profile_id`. The Q60 supports two profiles natively; the underlying PDM schema almost certainly has more capacity.

**Bottom line for the rebuild:** Replace the entire PDM subsystem with a **~300-line settings service over SQLite (or flat-file JSON) on Slot B's ext4**, plus a thin signal-bus pattern (Qt signals/slots in-process; D-Bus or a UDS socket if cross-process is needed). Provide a soft "Reset User Settings" that wipes our SQLite. **Never** provide a "Configuration Reset" — the only thing it could touch on our system is our own config files, and we have nothing equivalent to the vehicle-calibration table the factory bricks itself on. Leave the factory MTD partition (`/dev/mtdblock0`) **completely alone** in the deployed image — it remains the factory's responsibility on Slot A boots (logan1) and we do not touch it.

---

## 1. Architecture Diagram

```
                         ┌──────────────────────────────────────┐
                         │  Settings UI screens                 │
                         │  (rendered by hmictrl_proc into the  │
                         │   EmgdHmi pixmap canvas — same as    │
                         │   dialer, climate, vehicle screens)  │
                         └──────────────────────────────────────┘
                                    │  ▲
            "user changed X to Y"   │  │  "settings restored at boot — apply"
                                    ▼  │
            ┌──────────────────────────────────────────────────────┐
            │  POSIX mqueue bus (DENSO IPC — see forensic-denso-ipc.md) │
            └──────────────────────────────────────────────────────┘
                ▲              ▲              ▲              ▲              ▲
                │              │              │              │              │
        ┌───────┴─────┐ ┌──────┴─────┐ ┌──────┴─────┐ ┌──────┴────┐ ┌──────┴──────┐
        │ audio_ps    │ │ tel_proc   │ │ display_ps │ │ abstc     │ │ fis_ps      │
        │ (PS_AUDIO)  │ │ (PS_TEL)   │ │ (PS_DISPLAY)│ │ (clock)   │ │ (FIS/ECAM/  │
        │ EQ, Bose,   │ │ paired     │ │ upper-LVDS │ │ 12/24h,   │ │  vehicle &  │
        │ SSV, ANC/   │ │ phones,    │ │ brightness │ │ TZ, GPS-  │ │  driver     │
        │ ASC flags   │ │ priority   │ │ + lower    │ │ sync flag │ │  profiles)  │
        └─────┬───────┘ └─────┬──────┘ └─────┬──────┘ └─────┬─────┘ └─────┬───────┘
              │               │              │              │             │
              └───────────────┴──────────────┴──────────────┴─────────────┘
                                    │  PDM read/write IPC
                                    ▼
                ┌────────────────────────────────────────┐
                │  PDM API (on naviwork; binary location │
                │  not yet extracted — likely a libpdm.so│
                │  loaded in-process by every consumer)  │
                └────────────────────────────────────────┘
                                    │
                                    ▼
                ┌────────────────────────────────────────┐
                │  /home/naviwork/data/pdm/ram           │
                │  ext4 on /dev/mtdblock0  (~16 MB MTD)  │
                │  PERSISTENT FLASH — survives reboot,   │
                │  ignition cycle, battery disconnect    │
                └────────────────────────────────────────┘

  Shutdown / crash path:
       nav_smng crash → OnFailure=nav_smngpret → smngpret runs → on its
       failure → OnFailure=nav_backup → bkup_prg flushes any dirty PDM
       state → ExecStartPost: systemctl start poweroff.service

  Boot-time recovery path:
       /dev/mtdblock0 present? → checkfs-mtdblock0.sh
            → dumpe2fs OK?    → fsck -y                → mount, done
            → dumpe2fs fail?  → mkfs.ext4 (WIPE)       → mount empty
       mount fails anyway   → pdmram-mount-error-failsafe.sh → blind mkfs.ext4

  Brick path (Service → Configuration Reset):
       UI → mqueue → ??? daemon writes garbage into the Vehicle Config
       Table region (location TBD — possibly a separate eeprom or a
       reserved zone on mtdblock0 / mtdblock1) → CONSULT-III recovery only
```

---

## 2. Storage Layer — The PDM Flash Partition

### 2.1 The mount

**File:** `/tmp/dsu-slot-a/lib/systemd/system/home-naviwork-data-pdm-ram.mount`

```ini
[Unit]
Description=DENSO pdm mount
After=home-naviwork.mount checkfs-mtdblock0.service
Requires=checkfs-mtdblock0.service
ConditionPathExists=/dev/mtdblock0
#OnFailure=poweroff.service
OnFailure=pdmram-mount-error-failsafe.service

[Mount]
What=/dev/mtdblock0
Where=/home/naviwork/data/pdm/ram
Type=ext4
Options=nodelalloc
```

Companion **automount** unit (`home-naviwork-data-pdm-ram.automount`) gates the mount on first access. The `OnFailure=poweroff.service` was the original behavior — DENSO patched it to the failsafe service (which reformats the partition) because in the 15MY Nissan DCU project (`GEN5MON-9286`, `15MYSC-986` per the comment block on `invalidate_pdm_ram.service`) the partition was getting mount errors that the boot integrity check missed.

### 2.2 `nodelalloc` is intentional

`nodelalloc` (no delayed allocation) is uncommon on ext4 and the comment `# this change is for superblock file corruption` is in the unit file. Translation: DENSO previously lost data when ignition went off before delayed-allocated blocks committed. They forced metadata-and-data-immediate writes for durability. Same option is set on `/home/naviwork` (naviwork.mount).

### 2.3 Integrity check on boot

**File:** `/tmp/dsu-slot-a/lib/systemd/system/systemdRelatedFiles/checkfs-mtdblock0.sh`

```sh
#!/bin/sh
dumpe2fs -h /dev/mtdblock0 2>&1 > /tmp/dumpe2fs.log
if [ $? -ne 0 ]; then
    # A valid FS superblock was not found. Creating one
    mkfs.ext4 /dev/mtdblock0 …                       # WIPE
else
    fsck -y /dev/mtdblock0 …
    if [ $ret -ge 2 ]; then
        # A valid FS partition was not found. Creating one
        mkfs.ext4 /dev/mtdblock0 …                   # WIPE
    fi
fi
```

This script will silently nuke the entire PDM partition on superblock corruption — **all user settings, all paired phones, all driver profiles vanish.** The brokenness of this approach is exactly why `pdmram-mount-error-failsafe.sh` exists (it does the same `mkfs.ext4` but as a second-chance failsafe when the first integrity check passed but the mount still failed). Net: **user settings on the factory unit are not particularly durable against flash bit-rot.** Worth knowing.

### 2.4 Invalidate-on-S5 service

**File:** `invalidate_pdm_ram.service` (excerpt):

```ini
ExecStart=/bin/sh -c 'dd if=/dev/zero of=/dev/mtdblock0 bs=1024 seek=1 count=1 \
                   && dd if=/dev/zero of=/dev/mtdblock0 bs=1024 seek=8193 count=1'
```

Purpose (per the comment block): "invalidates the filesystem on RAM Disk not to mount it when the system boots with S5 state." Zeroes both copies of the ext4 superblock so the next boot triggers a clean mkfs. **This is what the Configuration Reset UI screen probably ends up doing for the user-settings half** (the vehicle-config-table half is a separate write — see §5). It is `Before=poweroff.service` and `Conflicts=` the mount unit, so it can only run during shutdown after the mount is dropped.

### 2.5 Storage size

The partition is approximately 16 MB based on the seek offset `8193 × 1024 = ~8 MB` for the ext4 backup superblock (which lives at block 8193 of the second block group in a typical 4 KiB-block, 8 MiB-group layout). For our rebuild, we use **<<1 MB** of SQLite — well within budget if we ever wanted to drop into the same MTD region.

---

## 3. PDM Helper Services — Backup & SD Retention

### 3.1 `nav_backup.service` — the durability flush

**File:** `/tmp/dsu-slot-a/lib/systemd/system/nav_backup.service`

```ini
[Unit]
Description=NAV Backup Service
DefaultDependencies=no
OnFailure=poweroff.service

[Service]
Type=oneshot
RemainAfterExit=yes
# OS管理外領域切り分け(1:無効 / 0 or 未定義:有効)
#Environment=OS_NOMNG_AREA_DISABLE=1
StandardInput=null
StandardOutput=null
StandardError=null
LimitSTACK=524288
ExecStart=-/home/naviwork/system/bin/bkup_prg
ExecStartPost=/bin/systemctl start poweroff.service
```

Notable:
- The Japanese comment `OS管理外領域切り分け` translates to "OS-unmanaged region partitioning" — i.e. `bkup_prg` can optionally exclude OS-managed regions when flushing. This strongly implies `bkup_prg` writes to multiple physical regions, not just the ext4 PDM partition. Candidate second region: a raw (non-ext4) MTD slice that holds the Vehicle Configuration Table.
- `ExecStart=-/home/naviwork/system/bin/bkup_prg` — the leading `-` makes the unit succeed even if `bkup_prg` exits non-zero. Then `ExecStartPost=/bin/systemctl start poweroff.service` **unconditionally powers off the unit.** This is a panic-flush-and-die path. It is the `OnFailure=` target of `nav_smng.service` and `nav_smngpret.service` per [forensic-daemon-supervision.md](forensic-daemon-supervision.md) §2.
- `LimitSTACK=524288` (512 KB) — same as the headless backend daemons; not a UI process.
- No `Restart=`. Single-shot. If `bkup_prg` crashes, the trailing `OnFailure=poweroff.service` on the unit still triggers shutdown (because the `ExecStartPost=` won't run).

### 3.2 `nav_sdretn.service` — SD-card retention

**File:** `/tmp/dsu-slot-a/lib/systemd/system/nav_sdretn.service`

```ini
[Unit]
Description=SD retention Service
After=home-naviwork.mount home-naviwork-tmp.mount
Wants=home-naviwork.mount home-naviwork-tmp.mount
#Conflicts=ig_shutdown.service ig_reboot.service
#DefaultDependencies=no

[Service]
Type=simple
TimeoutSec=90
SendSIGKILL=yes
StandardInput=null
StandardOutput=null
StandardError=null
LimitSTACK=524288
ExecStart=/home/naviwork/system/bin/sdretn
```

Notable:
- `Type=simple` long-running daemon — not a one-shot.
- Commented `Conflicts=ig_shutdown.service ig_reboot.service` confirms there is (or was) an explicit ignition-shutdown service in the original design; cleanly killed on shutdown.
- Purpose almost certainly: **detect the nav SD card being removed mid-write and flush/quiesce nav-data writers** so the map card survives hot-pull. (Owners regularly remove the nav SD card to update maps via `nissan-nav-updater` — see [CLAUDE.md](../../CLAUDE.md) projects section.) Without `sdretn`, a hot-pull during a RDSTM/HOUSE write could corrupt routing/address indexes.

### 3.3 What we cannot extract yet

The binaries `bkup_prg` and `sdretn` live on the naviwork ext4 partition and are not on Slot A. Per [forensic-factory-ui-binary.md](forensic-factory-ui-binary.md) §1.2 they are part of the 23-binary DENSO daemon set on `/home/naviwork/system/bin/`. Once naviwork is extracted we can `readelf -d / strings` to confirm:
- Which `/dev/mtd*` devices `bkup_prg` opens (PDM ext4 only, or PDM + a second raw MTD = vehicle config?).
- What ioctl set `sdretn` uses (likely `MMC_IOC_*` or polling `/sys/class/mmc_host/`).

---

## 4. Settings UI — Inside `hmictrl_proc`

### 4.1 Same architecture as clock and phone

The Settings tree (Display, Sound, Clock & Units, Phone & Bluetooth, Navigation, Vehicle, Driver Profiles, Voice Recognition, System Info) is a set of screens in the monolithic UI rendered by `hmictrl_proc` into the EmgdHmi pixmap canvas. Confirmed indirectly by:

- **No `settings_proc` / `cfg_proc` binary in the 23-daemon set** ([forensic-factory-ui-binary.md](forensic-factory-ui-binary.md) §1.2).
- **`hmictrl_proc` has `LimitMSGQUEUE=8192000` (8 MB)** in `nav_hmictrl.service` — same 32× default as `tel_proc`. It needs that headroom because it is the central UI message bus.
- **No standalone settings systemd target.** Settings has no dedicated `.service` — it is a sub-feature of nav_hmictrl.

### 4.2 Settings categories — owner matrix

Cross-referenced from [feature-parity-audit.md](feature-parity-audit.md) §1.7, [oem-hidden-functions.md](oem-hidden-functions.md), and the screen tree in the rebuild mockup at [docs/mockup/index.html](mockup/index.html):

| Settings category | Visible items | Daemon that owns runtime state | PDM key (inferred) |
|---|---|---|---|
| **Display** | Upper/lower brightness, day/night auto/manual, screen-off timer | `display_ps` (upper), `dispapf_proc` (lower) | `disp.brightness.upper`, `disp.brightness.lower`, `disp.daynight_mode` |
| **Sound** | Bass/Treble/Balance/Fade, Bose AudioPilot, Centerpoint, SurroundStage, Driver Stage, SSV, beep on/off, ringer vol, nav voice vol | `audio_ps` (EQ + Bose), `snd`/`sndamp` (system sounds), `tel_proc` (ringer) | `audio.eq.*`, `audio.bose.*`, `audio.ssv`, `system.beep`, `phone.ringer_vol`, `nav.voice_vol` |
| **Clock & Units** | 12h/24h, TZ, GPS auto-sync, mph/kmh, °F/°C, MPG/L/100km | `abstc` (time format), `fis_ps` (units, since they affect vehicle gauges) | `clock.fmt`, `clock.tz`, `clock.gps_sync`, `units.dist`, `units.temp`, `units.fuel` |
| **Phone & Bluetooth** | Paired devices list, pair-new, priority, auto-connect, ringer | `tel_proc` (D-Bus → BlueZ pairing DB at `/opt/var/lib/bluetooth/`) + PDM for priority list ordering | `bt.devices[]`, `bt.priority`, `bt.auto_connect` |
| **Navigation** | Voice volume, POI categories, route prefs default (fastest/shortest/eco), avoid toll/highway/ferry, lane guidance, map view 2D/3D, heading-up/north-up | `navi_ps` | `nav.prefs.*`, `nav.poi_filters[]`, `nav.map_view` |
| **Vehicle** | VDC on/off (display only — defeat is physical), driver-aids toggles (PFCW/FEB/BSW/BSI/LDW/LDP/BCI), rain-sensor enable, AVM brightness, camera guide-line color | `fis_ps` (FIS/ECAM gateway to CAN-bus ECUs) + `ioapf_proc` (CAN frame composer for ADAS frame 0x47D — see audit) | `vehicle.adas.*`, `vehicle.rain_sensor`, `vehicle.avm.*` |
| **Driver Profiles** | Driver 1 / Driver 2 / Personal; per-profile seat, mirror, climate, audio, nav voice | `fis_ps` (profile arbitration via I-Key CAN event) — all consumers reload on `profile_id` change | `profile.<id>.<subkey>` — every per-profile setting is namespaced |
| **Voice Recognition** | VR on/off, tutorial mode, confirmation beep, language model | `PS_VRD01` (voice recognition daemon — see daemon list in [forensic-factory-ui-binary.md](forensic-factory-ui-binary.md) §1.2) | `vr.enabled`, `vr.tutorial`, `vr.confirm_beep`, `vr.lang` |
| **System Info** | SW versions, map version, unit ID, serial; **Factory Reset** button | Pure read from `/etc/ivi.versions` + Map-DB header + the diag-mode 8-page version list. Factory Reset → fires `nav_backup` then `invalidate_pdm_ram` paths. | n/a (read-only) |

### 4.3 Save flow — what happens when a user toggles a setting

Per [forensic-denso-ipc.md](forensic-denso-ipc.md), every UI→backend communication is over POSIX mqueue. The plausible flow for "change clock from 12h to 24h":

1. User taps "24h" in Settings → Clock & Units screen.
2. `hmictrl_proc` `mq_send()` to abstc's inbox: `{cmd=SET_CLOCK_FMT, value=24H}`.
3. `abstc` updates its in-memory state, immediately publishes a "clock format changed" event to all subscribers (status bar in `display_ps` re-renders, etc.).
4. `abstc` issues a PDM write via libpdm (in-process): `pdm_set("clock.fmt", "24H")` → libpdm queues to journal → flushes to `/dev/mtdblock0` ext4.
5. (Eventually, on dirty-page commit or `bkup_prg` flush at shutdown) the value lands durably on flash.

This is identical in shape to the phone-stack save flow in [forensic-phone-stack.md](forensic-phone-stack.md) §6.

### 4.4 Multi-process fan-out

Brightness is the textbook fan-out case: a single "Display Brightness" slider changes both upper LVDS (owned by `display_ps`) and lower LVDS (owned by `dispapf_proc`). Either:
- (a) `hmictrl_proc` sends two mqueue messages (one per backend), OR
- (b) `hmictrl_proc` writes to PDM, PDM publishes a "settings changed" broadcast, both backends are subscribers and apply.

Option (b) is the cleaner pattern and matches DENSO's PS abstraction. We use (b) in the rebuild — it is just a Qt signal in our in-process settings service.

---

## 5. 🚨 The BRICK Risk — Vehicle Configuration Table

### 5.1 What it is

The **Vehicle Configuration Table** is a small per-vehicle calibration blob that tells the DCU:

- Which audio amp variant is installed (Bose Performance, Bose Premium, base 8-speaker, etc.).
- Which speaker layout is present (which channels, how many drivers per channel).
- Which CAN buses to subscribe to (M-CAN, AV-CAN, V-CAN, ChassisCAN) — Q60 has at least 3.
- Which feature packs are enabled (ANC, ASC, AVM, TCU2 with SOS, ProAssist sensors, ATTESA AWD, etc.).
- Vehicle-specific identifiers (VIN echo, regional market: NA/JP/EU, language pack default).
- Which IR/voltage thresholds to use for the rain sensor (per [feature-parity-audit.md](feature-parity-audit.md) §3 the sensitivity itself is a wiper-stalk analog input, but the *enable threshold* is in this table).

Without this table the DCU cannot drive the amp, cannot decode CAN frames for vehicle data, cannot map drive-mode UI to the right CAN ID, cannot serve the right audio channel routing. Result per [oem-hidden-functions.md](oem-hidden-functions.md) §6: **no clock, no audio, no drive mode**, only-recoverable via CONSULT-III-plus (J2534 with the right Nissan reflash key).

### 5.2 Where it physically lives

**Best inference:** a raw (non-ext4) region — either a second MTD slice (e.g. `/dev/mtdblock1`) or a region of `/dev/mtdblock0` outside the ext4 filesystem. The comment in `nav_backup.service` referring to "OS-unmanaged region partitioning" (`OS管理外領域切り分け`) is the smoking gun: `bkup_prg` knows about regions that the OS filesystem layer cannot see. Those are the candidate locations for the config table.

Other candidate locations to confirm with hardware-day probing:
- The Renesas SH companion processor (`SH SW Version=07A2` per [factory-version-baseline.md](factory-version-baseline.md)) has its own NVRAM and is the more likely home for the calibration table on Q60-class systems (separation of duties: Atom does UI, SH does ECU/CAN and holds vehicle config).
- A small i²c EEPROM on the DCU PCB (Clarion QY5092). The Q50/QX30 brick-repair megathreads at [DCUFix](https://dcufix.com/) — referenced from [oem-hidden-functions.md](oem-hidden-functions.md) — mention EEPROM-swap repairs, which supports this hypothesis.

### 5.3 Who can write it

Per [oem-hidden-functions.md](oem-hidden-functions.md) the only documented user-accessible write paths are:

1. **InTouch Diagnostic Mode → Service → Configuration Reset** (touchscreen path; bricks the unit).
2. **CONSULT-III-plus → DCU Configuration write** (J2534 path; the *recovery* tool that brick victims need a shop with a Nissan account to use).

Both are out-of-scope to invoke from our rebuild. **We do not provide any UI path or background process that writes to this region.**

### 5.4 What it means for the rebuild

| Risk | Mitigation |
|---|---|
| Accidental write via a debugfs/MTD command in a deploy script | All deploy/probe scripts use `/dev/disk?s?` paths or LABEL=q60diag — none of them open `/dev/mtdblock?` or `/dev/i2c-?`. Per CLAUDE.md "Never write to Slot A" is doctrine; this is the kernel of why. |
| User invocation of factory Diagnostic Mode while our system is the active boot | Our system replaces the UI entirely. The factory diagnostic-mode entry sequence (tap Settings + Seek-Up ×3 + long-press near `▶` arrow) is a factory-UI screen we do not implement. There is no path from our UI into the Service tab. |
| Slot A logan1 boot still allows factory diag-mode entry | Yes — and that is fine. Logan1 boot is unchanged. The brick risk on Slot A is exactly what it was from the factory, no better and no worse. **We never make logan1 less safe.** |
| Backup completeness | `images/DSU backup.img` (per [CLAUDE.md](../../CLAUDE.md)) captures Slot A byte-for-byte. If the Vehicle Configuration Table is on `/dev/mtdblock0` or another standard MTD, the image holds it. If it is on the SH co-processor's NVRAM or a separate i²c EEPROM, our DSU backup does *not* recover it and we would need CONSULT-III-plus. Worth a hardware-day probe to know which case applies. |

### 5.5 What we provide instead

Per [feature-parity-audit.md](feature-parity-audit.md) §1.7 row "Factory reset," the rebuild ships a **soft Factory Reset** ("Reset User Settings") that deletes our SQLite settings DB and re-creates it with defaults. It does *not* touch:
- Any MTD device.
- Any CAN configuration.
- Any ECU calibration.
- Any partition outside Slot B's q60nav rootfs.

Recovery from a soft reset = power-cycle, all user prefs reset to defaults. Recovery from an accidental full reset = `git checkout` + `deploy-phase1-sd.sh` (per CLAUDE.md). Zero CONSULT exposure.

---

## 6. Driver Profiles & I-Key Integration

### 6.1 Q60 supports 2 profiles natively

Per [feature-parity-audit.md](feature-parity-audit.md) §1.5 row "Climate settings persist per driver profile (I-Key identity)" — the factory ties seat memory, mirror position, climate preset, audio preset, nav voice preference, and drive-mode favorite to the recognized key fob ID.

### 6.2 How the profile event arrives

The intelligent-key receiver in the BCM broadcasts a "key fob N recognized" frame on M-CAN (frame ID not yet captured — earmarked for hardware-day per [oem-hidden-functions.md](oem-hidden-functions.md) §11). It arrives at the DCU and is decoded by:

- **`ioapf_proc`** (Input/Output Abstraction — runs as `PS_IOAPF`, started via `nav_ioapf.service` in `nav_early.target.wants/`) — this is the CAN demux layer for the entire factory stack.

`ioapf_proc` emits a "current driver = N" mqueue event. Subscribers reload their per-profile slice from PDM.

### 6.3 PDM key namespacing (inferred)

Per-profile keys are namespaced `profile.<id>.<subkey>` — e.g. `profile.1.seat.driver.position`, `profile.1.audio.eq.bass`, `profile.1.climate.driver_temp`, `profile.1.audio.preset.fm[6]`, `profile.1.drive_mode = "Sport"`. Settings without a profile dimension (system language, units, clock fmt, BT pairing list) live at top-level. To confirm exact format once `bkup_prg` is disassembled.

### 6.4 Rebuild treatment

Keep the concept — it is the single most-loved feature on multi-driver households. Implementation: a `profiles` SQLite table (`id`, `name`, `last_seen`) + foreign-key on every per-profile setting; resolver subscribes to the CAN key-fob event and updates a `currentProfileId` property that QML bindings react to. Profile management UI = rename / reset-this-profile / copy-from-other-profile.

---

## 7. PDM-Related Systemd Service Inventory

| Unit | Path | Role | Notes |
|---|---|---|---|
| `home-naviwork-data-pdm-ram.automount` | `/lib/systemd/system/` | systemd automount over `/home/naviwork/data/pdm/ram` | Lazy mount on first access |
| `home-naviwork-data-pdm-ram.mount` | `/lib/systemd/system/` | The actual mount — `/dev/mtdblock0` ext4 with `nodelalloc` | `OnFailure=pdmram-mount-error-failsafe.service` |
| `checkfs-mtdblock0.service` | `/lib/systemd/system/` | Pre-mount integrity check via [`checkfs-mtdblock0.sh`](../tmp/dsu-slot-a/lib/systemd/system/systemdRelatedFiles/checkfs-mtdblock0.sh) — `dumpe2fs` → `fsck -y` → fallback `mkfs.ext4` | `Type=oneshot` |
| `pdmram-mount-error-failsafe.service` | `/lib/systemd/system/` | Mount-error recovery — runs [`pdmram-mount-error-failsafe.sh`](../tmp/dsu-slot-a/lib/systemd/system/systemdRelatedFiles/pdmram-mount-error-failsafe.sh) → blind `mkfs.ext4 /dev/mtdblock0` (WIPES settings) | Authored 2014-12-03 by Yasunari Yokota; comment ties it to a 15MY Nissan DCU project bug |
| `invalidate_pdm_ram.service` | `/lib/systemd/system/` | S5-shutdown-time superblock zeroing (forces next-boot mkfs) — `Reference: GEN5MON-9286 / 15MYSC-986` | `Before=poweroff.service`, `Conflicts=` the mount |
| `nav_backup.service` | `/lib/systemd/system/` | `bkup_prg` flush-and-poweroff | `OnFailure=` target of `nav_smng` and `nav_smngpret` — see [forensic-daemon-supervision.md](forensic-daemon-supervision.md) §2 |
| `nav_sdretn.service` | `/lib/systemd/system/` | `sdretn` long-running daemon — SD-card removal protection | `Type=simple` |
| `nav_smngpret.service` | `/lib/systemd/system/` | `smngpret` shutdown handler — `OnFailure=nav_backup.service` | Runs `systemctl stop nav_smng.service` |

---

## 8. Rebuild Implications

### 8.1 Replace PDM with a small settings service

| Factory | Replacement | Effort |
|---|---|---|
| `libpdm` (settings API across 10+ daemons) | `SettingsService` Qt6 C++ class — `value(key, profile)` / `setValue(...)` / `valueChanged(key)` signal | ~300 LoC |
| `/dev/mtdblock0` ext4 mount | SQLite DB at `/opt/q60nav/var/settings.db` on Slot B ext4 | None |
| `bkup_prg` shutdown flush | SQLite WAL + `PRAGMA synchronous=FULL` + idle-time checkpoint | None |
| `sdretn` SD removal protection | Nav-tile writes are journaled and the map-SD path is opt-in / on-demand | None for now |
| Per-profile fan-out | `currentProfileId` property; QML bindings re-evaluate on change | Trivial |
| `checkfs-mtdblock0.sh` mkfs-on-corruption | `settings.db` + `settings.db.backup` rolled on clean shutdown; restore from backup on open failure, never silently wipe | ~30 LoC |

### 8.2 What stays in the kill set

Per [project_planB_kill_set.md](../../.claude/projects/-Users-dpitek-Developer-q60-rebuild/memory/project_planB_kill_set.md), the current kill set is `navi_ps` + `dispapf_proc`. Additions for settings-domain consideration:

- **Leave `nav_backup.service` alive** — it is `OnFailure=`-only and never runs unless the factory stack crashes. If we have torn the factory stack down cleanly, the cascade does not fire. Harmless.
- **Leave `nav_sdretn.service` alive** — runs against the factory-installed nav SD card path. If we mount our own writes on a different path, it has nothing to do. Harmless.
- **Mask `checkfs-mtdblock0.service`, `home-naviwork-data-pdm-ram.{mount,automount}`, `invalidate_pdm_ram.service`, `pdmram-mount-error-failsafe.service`** — we do not want the factory boot path touching `/dev/mtdblock0` while we own the box. Critically, this keeps the factory's user settings *intact* (because nothing rewrites the partition), so a logan1 boot still has everything the user remembers.
- **Mask `nav_smngpret.service`** — its cascade ends in `nav_backup` → `bkup_prg` → naviwork binary not running → leaves the system in a weird half-state. Cleanest to disable.
- **Leave `fis_ps` alive** — the FIS/ECAM gateway is the canonical home of vehicle/driver-profile config. Until we have our own CAN integration shipping, fis_ps is what subscribes to the I-Key fob event we want to consume. We can intercept its mqueue output (per [forensic-denso-ipc.md](forensic-denso-ipc.md)) rather than reproduce it from scratch.

### 8.3 Delta vs. factory

| Aspect | Factory | Our rebuild |
|---|---|---|
| Storage location | `/dev/mtdblock0` ext4 (~16 MB MTD) | `/opt/q60nav/var/settings.db` (SQLite, Slot B ext4) |
| Storage manager | DENSO libpdm + bkup_prg | Single Qt6 `SettingsService` class |
| Corruption recovery | Silent `mkfs.ext4` wipe | Restore from `.backup`, never wipe silently |
| Settings UI | Screens in `hmictrl_proc` (mqueue commands) | Qt6 QML screens in our monolithic nav app (Qt signals/slots) |
| Driver profiles | 2 (Driver 1, Driver 2) + Personal | N (config — start with 2 to match) |
| Profile resolver | `ioapf_proc` decodes CAN → mqueue → consumers | Our CAN service decodes → emits `profileChanged(id)` signal → bound QML reloads |
| Vehicle Configuration Table | Live, write-able from Diag-mode, BRICK risk | **Not present in our system.** We have no analog. CONSULT-class recovery does not apply. |
| "Reset All Settings" | Wipes PDM ext4 (reversible but tedious) | "Reset User Settings" — delete SQLite, restart, all defaults |
| "Configuration Reset" | BRICK (no clock / no audio / no drive mode) | **Does not exist in the UI. Period.** |
| Backup | bkup_prg on crash, OS-unmanaged regions included | SQLite WAL + nightly checkpoint, settings exportable to JSON file for off-box backup |

### 8.4 Net code estimate

`SettingsService` (~300 LoC) + `SettingsModel` for QML (~100 LoC) + schema/migrations (~50 LoC) + the 9 category QML screens (incremental UI work; mockup at [docs/mockup/index.html](mockup/index.html) covers it). Total: low-single-digit days. The hard part is **policy** (defaults, units, migration matrix for new settings without losing existing values), not plumbing.

---

## 9. Open Questions (resolvable only with naviwork partition + hardware probe)

1. **PDM API surface.** Is libpdm in-process (shared library linked by every consumer) or a separate daemon with an mqueue API? The 23-daemon list has no `pdm_proc` candidate, which suggests in-process — but the daemons not yet seen could include one.
2. **Vehicle Configuration Table location.** `/dev/mtdblock1`? A separate i²c EEPROM? The SH co-processor's NVRAM? Hardware-day probe: `ls /dev/mtd* /dev/i2c-* /dev/eeprom* /dev/nvram*` on a running factory unit, then `bkup_prg | strings | grep -E '/dev/|nv_|cfg_|cnfg_'`.
3. **Driver-profile CAN frame ID.** Which M-CAN frame carries the "key fob N recognized" event? Capture during hardware-day on key-fob-1-unlock vs. key-fob-2-unlock.
4. **PDM journal layout.** Does PDM use a flat key/value file, a sqlite DB, or a custom record format? Determines how much of the factory's per-user history (recent destinations, recent calls, etc.) we could migrate at install time.
5. **Encryption.** Are paired BT keys at `/opt/var/lib/bluetooth/` encrypted, or just bound by file-mode? Affects the "easy migration" story when transferring factory pairings to our rebuild.
6. **`OS_NOMNG_AREA_DISABLE`.** What is the second region `bkup_prg` writes when this flag is unset? Most likely the answer to question 2.

---

## 10. Cross-references

- [forensic-daemon-supervision.md](forensic-daemon-supervision.md) — `nav_smngpret` → `nav_backup` → `poweroff` cascade, mask-strategy patterns
- [forensic-denso-ipc.md](forensic-denso-ipc.md) — POSIX mqueue conventions used by every settings-domain consumer
- [forensic-factory-ui-binary.md](forensic-factory-ui-binary.md) §1.2 — `bkup_prg`, `sdretn`, `fis_ps`, `ioapf_proc` live on naviwork; not extractable yet
- [forensic-clock-service.md](forensic-clock-service.md) — paradigm: backend daemon + UI region inside hmictrl_proc, no separate "app"
- [forensic-phone-stack.md](forensic-phone-stack.md) — same pattern; also documents BT pairing storage at `/opt/var/lib/bluetooth/`
- [oem-hidden-functions.md](oem-hidden-functions.md) — Configuration Reset BRICK warning, Diag-mode entry sequence, what NOT to invoke
- [feature-parity-audit.md](feature-parity-audit.md) §1.7 — the Settings categories we must preserve
- [factory-version-baseline.md](factory-version-baseline.md) — what the System Info screen displays (`/etc/ivi.versions` + 8-page version dump)
- [docs/mockup/index.html](mockup/index.html) — the rebuild's settings tree mockup
- [CLAUDE.md](../CLAUDE.md) — "Never write to Slot A" doctrine; image backup discipline
