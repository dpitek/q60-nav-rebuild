# Forensic — Clock Service (`abs_clock` / `abstc`)

**Date:** 2026-05-23
**Source:** `/tmp/dsu-slot-a/` (extracted Slot A DSU backup) + cross-reference to existing forensics
**Subject:** What component implements the "clock" on the factory Q60 head unit, where the binary lives, what it links, how it interacts with the UI, and what it means for the rebuild.

---

## Executive Summary

1. **There is no user-facing "clock app."** The factory ships a **headless time-abstraction daemon** (`abstc`, started by `abs_clock.service`) plus an **on-screen clock region** drawn as part of the monolithic UI chrome by `display_ps` / `hmictrl_proc`. They are two distinct things and neither is an "app" in any framework sense.

2. **`abstc` does not render anything.** Its `LD_LIBRARY_PATH` from [`abs_clock.service`](../tmp/dsu-slot-a/lib/systemd/system/abs_clock.service) is `/home/naviwork/system/bin:/home/naviwork/system/lib:/home/naviwork/system/out:/usr/lib:/usr/local/lib:/usr/` — **no `/usr/lib/wsegl`**. Compare to the 4 UI daemons in [forensic-factory-ui-binary.md](forensic-factory-ui-binary.md) which all require wsegl-hmi for EGL surface registration. `abstc` cannot reach a framebuffer; it's purely backend.

3. **`abstc` is the time-source normalizer.** It is the canonical publisher of "what time is it" across the DENSO IPC bus — consuming hardware RTC, GPS time messages off CAN, and any user manual time set; emitting normalized current-time events to whichever UI/log/telematics process subscribes via POSIX mqueue. The 384 KB stack limit (`LimitSTACK=524288` actually = 512 KB; abstc's effective working set is much smaller) and `Type=simple` plain daemon shape confirm a small backend, not a UI app.

4. **It is the only nav-adjacent service with `Restart=on-failure`.** Per [forensic-daemon-supervision.md](forensic-daemon-supervision.md) §6, `abs_clock.service` is the **only** service in this neighborhood that respawns automatically (every 100ms) on crash. All four UI daemons have no Restart directive and instead trip `OnFailure=nav_smngpret.service` (the system-pre-reset cascade). That asymmetry tells us DENSO treats clock loss as recoverable (re-init from RTC), but UI loss as fatal.

5. **The on-screen clock is rendered by the UI daemon stack, not by `abstc`.** It's a region of the monolithic Qt/EGL-on-EmgdHmi-pixmap chrome described in [forensic-factory-ui-binary.md](forensic-factory-ui-binary.md), subscribed to abstc's time stream over IPC. No separate window, no separate process, no app lifecycle.

**Bottom line for the rebuild:** the clock is not a port target. Replace it with a `QTimer`-driven QML label in our monolithic Qt6 nav app reading `clock_gettime(CLOCK_REALTIME)`, and let the time source itself be either (a) a tiny systemd timer that reads `/dev/rtc0` + listens for CAN time frames + `settimeofday()`, or (b) keep `abstc` alive and ignore its IPC bus.

---

## 1. Service Unit — `abs_clock.service`

**File:** `/tmp/dsu-slot-a/lib/systemd/system/abs_clock.service`

```ini
[Unit]
Description=ABS Clock Service
After=home-naviwork.mount home-naviwork-tmp.mount
Wants=home-naviwork.mount home-naviwork-tmp.mount

[Service]
Type=simple
Environment=LD_LIBRARY_PATH=/home/naviwork/system/bin:/home/naviwork/system/lib:/home/naviwork/system/out:/usr/lib:/usr/local/lib:/usr/
TimeoutSec=90
SendSIGKILL=yes
Restart=on-failure
RestartSec=100ms

StandardInput=null
StandardOutput=null
StandardError=null
LimitSTACK=524288

ExecStart=/home/naviwork/system/bin/abstc
```

**Wanted-by:** `/tmp/dsu-slot-a/lib/systemd/system/graphical.target.wants/abs_clock.service` (symlink). Despite the "graphical" target naming, this is a MeeGo-era systemd v37 categorization and does not mean the unit itself renders.

### 1.1 Notable properties

| Property | Value | Forensic meaning |
|---|---|---|
| `Type=simple` | long-running daemon | Not a one-shot, not a forking daemon — runs in foreground under systemd supervision |
| `Restart=on-failure` + `RestartSec=100ms` | aggressive respawn | **Only nav-adjacent service with this behavior** — DENSO accepts churn over loss-of-time |
| `LimitSTACK=524288` | 512 KB | Small process, no UI thread pool, no Qt event loop |
| `StandardInput/Output/Error=null` | no terminal | Headless daemon; logs go via syslog if at all |
| `SendSIGKILL=yes` | force-kill on timeout | Treated as expendable on shutdown |
| `LD_LIBRARY_PATH` | naviwork paths + `/usr/lib` only | **No `/usr/lib/wsegl`** → no EGL backend → cannot draw |
| `After=home-naviwork.mount` | gated on ext4 mount | Binary lives on the separate naviwork partition |
| Commented `#Environment=napl_debug=1` | DENSO `napl` framework | Same process abstraction layer used by all `*_ps` / `*_proc` daemons |
| Commented `#OnFailure=nav_smngpret.service` | disabled in production | Originally was tied into smng-reset cascade; explicitly disabled |
| Commented `#ExecStart=/home/naviwork/system/bin/napl "PS_OS02"` | indirection mode disabled | Could be launched via napl with PS-name "PS_OS02"; production uses direct binary path |

The commented `napl "PS_OS02"` line is the smoking gun: `abstc` is part of the DENSO PS family but launches directly rather than via the `napl` supervisor wrapper. PS_OS02 sits next to `smng`'s PS_OS01 in the OS-services tier — confirming abstc is plumbing, not application.

---

## 2. Binary — `/home/naviwork/system/bin/abstc`

**Status:** not yet extracted. Lives on the naviwork ext4 partition (`LABEL=homenaviwork`) which is not present in the Slot A DSU backup we have mounted. Same situation as the 4 UI daemons documented in [forensic-factory-ui-binary.md](forensic-factory-ui-binary.md).

**Inferred from service unit + DENSO IPC contract** (per [forensic-denso-ipc.md](forensic-denso-ipc.md)):

- ELF i386, glibc-linked (Slot A is glibc, not bionic)
- Links `libnapl.so` (DENSO process-abstraction framework — also used by smng, navi_ps, hmictrl_proc, display_ps, dispapf_proc, tel_proc, etc.)
- Links `librt.so.1` for `mq_open / mq_send / mq_receive / clock_gettime` (per forensic-denso-ipc.md)
- Likely links `libpthread.so.0` (any napl process is multi-threaded)
- Does **not** link EGL / GLES / OpenVG / EmgdHmi (no wsegl in path)
- Opens `/dev/rtc0` for hardware RTC reads
- Opens CAN socket(s) — listens for time-of-day frames from the vehicle bus (GPS time arrives this way on Q60-class Nissan/Infiniti — see [DSU_OEM_DOCUMENTATION.md](DSU_OEM_DOCUMENTATION.md))
- Creates a POSIX mqueue (probably `/abstc_time` or `/abs_clock_evt` — naming TBD without binary disassembly) and publishes time-tick events
- Subscribers: any UI daemon that needs to display the clock (display_ps for status bar; hmictrl_proc for the Settings → Clock screen), plus log daemons that need timestamps before the system clock is set

**To confirm structure once naviwork ext4 is extracted:**
```bash
file abstc
readelf -d abstc | grep NEEDED
strings abstc | grep -E '^/(dev|home|tmp|var)/|mq_|PS_|abstc'
strace -e trace=clock_gettime,settimeofday,openat -p $(pidof abstc)  # on hardware
```

---

## 3. Why the on-screen clock is not `abstc`

Three pieces of evidence:

1. **No EGL/wsegl in `abstc`'s LD path.** As established above, `abstc` literally cannot dlopen `libwsegl-hmi.so` because the search path excludes `/usr/lib/wsegl`. The EmgdHmi pixmap → EGL window surface chain documented in [forensic-factory-ui-binary.md](forensic-factory-ui-binary.md) requires that path.

2. **No `Group=video` on the service.** All UI daemons that touch `/dev/dri/card0` are `Group=video`. `abs_clock.service` has no `Group=` directive at all → inherits root group → not video-capable. (DRM render-node permissions on this kernel require either `Group=video` or DRM_AUTH ioctl tokens from the master.)

3. **Architecture symmetry.** Every visible HMI region (map, status bar, climate strip, audio strip, lower-screen widgets) is rendered by the monolithic 4-daemon UI stack drawing into the EmgdHmi 800×960 stacked virtual canvas. The clock is just a small rectangle of that canvas, redrawn whenever the consumer daemon (`display_ps` likely owns the upper-status-bar layer; `hmictrl_proc` owns the Settings → Clock & Units screen) receives a tick event from abstc.

The factory feature audit at [feature-parity-audit.md](feature-parity-audit.md) lists "Clock set (12h/24h, time zone, auto-sync from GPS)" as a **settings screen** under Settings & Vehicle — i.e., a sub-screen of the main UI tree, not a standalone application.

---

## 4. Rebuild Implications

### 4.1 The clock is not a port target

In the Plan B''' replacement (per [project_planB_triple_prime.md](../../../.claude/projects/-Users-dpitek-Developer-q60-rebuild/memory/project_planB_triple_prime.md)), the entire UI chrome is replaced by our Qt6/QML app drawn into the same EmgdHmi pixmap canvas. The on-screen clock collapses to:

```qml
Text {
    text: Qt.formatTime(timeBackend.currentTime, settings.use24Hour ? "HH:mm" : "h:mm AP")
    font: Style.statusBarFont
}
// Backend pings the QML via signal every 1000ms; QTimer + clock_gettime(CLOCK_REALTIME)
```

Exactly the pattern in the mockup at [docs/mockup/index.html](mockup/index.html) (`setInterval(updateClock, 1000)`).

### 4.2 Two options for the time source

**Option A — Replace `abstc` with our own minimal time daemon.**
- Open `/dev/rtc0` at boot; `settimeofday()` from RTC; set hwclock back to RTC on clean shutdown
- Open CAN socket; subscribe to GPS-time frames (Nissan G-CAN frame IDs documented in [DSU_OEM_DOCUMENTATION.md](DSU_OEM_DOCUMENTATION.md))
- On GPS-time event: validate (sanity check vs. RTC delta), call `clock_settime(CLOCK_REALTIME, ...)`
- ~150 LoC of C or Rust. No IPC bus needed — everyone reads `clock_gettime()` directly.

**Option B — Keep `abstc` alive and consume its IPC.**
- Pros: preserves any CAN-time-set logic we don't yet understand; zero new code
- Cons: requires us to reverse-engineer the abstc mqueue protocol (queue name, message struct) before we can subscribe; ties us to the naviwork partition layout; conflicts with [project_planB_kill_set.md](../../../.claude/projects/-Users-dpitek-Developer-q60-rebuild/memory/project_planB_kill_set.md) being clean about what we leave running

**Recommendation: Option A.** Cleaner, smaller blast radius, no naviwork dependency, easier to debug. The CAN time-frame integration is a well-documented vehicle-bus convention, not DENSO-proprietary.

### 4.3 What stays in the kill set

`abs_clock.service` is **not** in the current Plan B''' kill set per [project_planB_kill_set.md](../../../.claude/projects/-Users-dpitek-Developer-q60-rebuild/memory/project_planB_kill_set.md) — we kill `navi_ps` and `dispapf_proc` only. If we go with Option A (own time daemon), we should **add `abs_clock.service` to the mask list** so the factory `abstc` does not respawn and contend with us for RTC/CAN access. If Option B, leave it alone (and accept the `Restart=on-failure` churn risk flagged in [forensic-daemon-supervision.md](forensic-daemon-supervision.md) §6.4).

---

## 5. Open Questions (resolvable only with naviwork partition extracted)

1. **mqueue protocol.** What is the queue name `abstc` opens (e.g. `/abstc_time_evt`)? What is the message struct (likely a `time_t` + flags byte, but unconfirmed)?
2. **CAN frame subscription.** Which exact CAN IDs does abstc subscribe to? Direct `socket(PF_CAN, SOCK_RAW, CAN_RAW)` or through a DENSO CAN-abstraction lib?
3. **GPS time path.** Does GPS time arrive via CAN from the GPS antenna module, or does abstc directly own `/dev/ttyXXX` for the GPS NMEA stream? Per the IPC findings the NMEA path is more likely owned by `navi_ps`, with GPS-time forwarded via mqueue.
4. **Time-zone source.** How does abstc know the current TZ? `/etc/localtime` symlink, or a vehicle-config table writable from the Settings screen?
5. **Subscriber list.** Who else reads from the abstc mqueue besides the UI daemons? `nav_systemlogd.service`? `audio_ps`?

These are all answerable in ~30 minutes once the naviwork ext4 is mounted and we can `strings abstc | grep -E 'mq_|/dev/|CAN'` + `readelf -d abstc`.

---

## 6. Cross-references

- [forensic-daemon-supervision.md](forensic-daemon-supervision.md) — full systemd unit graph, Restart semantics, smng cascade
- [forensic-denso-ipc.md](forensic-denso-ipc.md) — POSIX mqueue + napl conventions
- [forensic-factory-ui-binary.md](forensic-factory-ui-binary.md) — proof that rendering requires wsegl-hmi
- [feature-parity-audit.md](feature-parity-audit.md) — visible clock/units feature set we must preserve
- [DSU_OEM_DOCUMENTATION.md](DSU_OEM_DOCUMENTATION.md) — vehicle-bus time-of-day frame conventions
