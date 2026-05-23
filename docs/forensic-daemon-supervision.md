# Forensic Daemon Supervision Analysis — DSU Slot A Factory Rootfs

**Subject:** Will the 4 UI daemons (`navi_ps`, `hmictrl_proc`, `display_ps`, `dispapf_proc`)
stay dead if we SIGTERM them at runtime, and what cascades?

**Rootfs analyzed:** `/tmp/dsu-slot-a/` (extracted Slot A — DSU backup partition)
**OS:** MeeGo 1.2 / Wind River Linux 2.6.37, PID 1 = systemd (`/sbin/init -> ../bin/systemd`)
**Date:** 2026-05-23

---

## Executive Summary

1. **systemd will NOT auto-respawn any of the 4 UI daemons.** None of the four `.service` units
   declare `Restart=`. Default is `Restart=no`. No `WatchdogSec=`, no `StartLimitBurst`. SIGTERM
   = process exits = systemd marks unit `inactive` (or `failed`) and walks away.

2. **There is a poison-pill `OnFailure=` cascade that ends in `poweroff.service`.** Every nav_*.service
   has `OnFailure=nav_smngpret.service` → which runs `systemctl stop nav_smng.service` → whose
   `OnFailure=nav_backup.service` → whose `ExecStartPost=/bin/systemctl start poweroff.service`.
   **A naive `kill -TERM` will trigger this and reboot the unit.**

3. **The cascade is short-circuited by SIGTERM-as-success.** Set `KillSignal=SIGTERM` and
   `SuccessExitStatus=SIGTERM` (or just stop the unit through systemd's own `systemctl stop`,
   which marks `inactive` not `failed`). Even cleaner: **mask the units** before they start.
   The unit files themselves use no special exit handling — the cascade only fires on `failed`.

4. **No custom DENSO userspace supervisor watches them via heartbeats from outside systemd.**
   The `smng` binary IS the orchestrator, but it's a normal systemd-managed service itself
   (`nav_smng.service`, no Restart=), and it runs in parallel with — not above — the children.
   It uses DENSO IPC (`PS_*` channel names) and `OnFailure=` to coordinate, not respawning.

5. **Killing the UI daemons does NOT starve the hardware watchdog.** The kernel module
   `watchdog.ko` (DENSO custom, in `/lib/modules/.../bsp/watchdog/watchdog.ko`) is a kthread
   that kicks a GPIO line itself — userspace has no role. There is no `/dev/watchdog` consumer
   among the 4 UI daemons. Killing them is watchdog-neutral.

**Bottom line:** Plan B''' is viable. The safest disable strategy is **masking the unit files
on Slot A via debugfs symlink-write** (`ln -sf /dev/null /etc/systemd/system/nav_navi.service`
equivalent), or — if write semantics through debugfs are awkward — replacing the unit's
`ExecStart=` line with `/bin/true` so systemd starts a no-op, treats it as success, and never
fires the failure cascade.

---

## 1. Supervision Inventory

### 1.1 What's present

| Mechanism | Status | Evidence |
|---|---|---|
| **systemd (PID 1)** | **PRIMARY** | `/tmp/dsu-slot-a/sbin/init -> ../bin/systemd` |
| Android init (init.rc) | Inside `/mnt/android/ramdisk.img` only — runs chrooted, no auth over host nav_* | `sbin/android-mount.sh` extracts ramdisk; `sbin/android.sh` does `chroot /android /init` |
| SysV init.d | Vestigial — `/etc/rc.d/rc{0..6}.d/` exist but `/sbin/init` is systemd, so inittab is **ignored** | `/etc/inittab` (legacy), `/etc/init.d/{halt,iptables,sshd,…}` (LSB scripts, not honored at boot) |
| upstart (`/etc/init/*.conf`) | **Not present** | Directory does not exist |
| monit / runit / daemontools | **Not present** | No `/etc/service`, no `/var/service`, no monit configs |
| Custom DENSO userspace supervisor | **Not present as separate process** — smng plays this role inside systemd | See §3 |

### 1.2 systemd unit population

- `/tmp/dsu-slot-a/lib/systemd/system/` — **220 unit files**, including 22 `nav_*.service` units
- `/tmp/dsu-slot-a/etc/systemd/system/` — empty `*.target.wants/` directories (no admin overrides)
- `/tmp/dsu-slot-a/usr/lib/systemd/system/` — does not exist (only `usr/lib/systemd/user/`)
- `default.target → graphical.target`

### 1.3 `target.wants/` directories (the only autostart hooks)

```
basic.target.wants/         emgdhmid.service, iptables.service, pulseaudio.service, udev.service, udisks.service
graphical.target.wants/     nav_before.service, nav_driver.service, nav_init.service, nav_smng.service,
                            nav_systemlogd.service, abs_clock.service, connmand.service, syslogd.service,
                            home-naviwork{,-tmp,-data-pdm-ram}.automount, …
nav_pre.target.wants/       nav_audio, nav_camera, nav_dispapf, nav_display, nav_dmsg_start, nav_dsn,
                            nav_hmictrl, nav_initialscreen, nav_ipodplayer, nav_is, nav_multimedia,
                            nav_napl, nav_navi, nav_rex01, nav_snd, nav_sndamp, nav_soft_vup,
                            nav_tel, nav_vrd01
nav_early.target.wants/     nav_ioapf.service
late-services.target.wants/ android-mount.service, sud-change-elilo.service, android-data-system-tmp.mount
android.target.wants/       android-modules-load.service, android-start.service
```

Critical observation: `nav_pre.target` has **no [Install]** section and is **not WantedBy=
anything**. It is pulled in transitively only because every `nav_*.service` declares
`Requires=nav_pre.target`. That means **disabling individual nav_*.services prevents them
from pulling in the target** — but the target is also pulled by the *other* nav_* services
that we DON'T disable. Removing one daemon's `Requires=nav_pre.target` doesn't break the
others. Good.

---

## 2. The 4 UI Daemons — Per-Unit Forensics

All four sit in `/tmp/dsu-slot-a/lib/systemd/system/`. All four are symlinked into
`nav_pre.target.wants/`. **None have `Restart=`, `RestartSec=`, or `WatchdogSec=`.**

### 2.1 `nav_navi.service` (PS_NAVI / `navi_ps`)
```
Description=PS_NAVI Service
Requires=nav_pre.target
OnFailure=nav_smngpret.service
DefaultDependencies=no
Type=simple
ExecStart=/home/naviwork/system/bin/navi_ps "PS_NAVI"
TimeoutSec=90
SendSIGKILL=yes
```
- Restart policy: **none** (Restart=no by default)
- Type=simple, no After=/Wants= other than `nav_pre.target`
- `OnFailure=nav_smngpret.service` — the cascade entry

### 2.2 `nav_hmictrl.service` (PS_HMIC1 / `hmictrl_proc`)
```
Description=HMI Controller Service
Requires=nav_pre.target
OnFailure=nav_smngpret.service
DefaultDependencies=no
Type=simple
ExecStart=/home/naviwork/system/bin/hmictrl_proc "PS_HMIC1"
TimeoutSec=90
SendSIGKILL=yes
```
- Restart policy: **none**
- Same OnFailure cascade

### 2.3 `nav_display.service` (PS_DISPLAY / `display_ps`)
```
Description=Display Service
Requires=nav_pre.target
OnFailure=nav_smngpret.service
DefaultDependencies=no
Type=simple
ExecStart=/home/naviwork/system/bin/display_ps "PS_DISPLAY"
TimeoutSec=90
SendSIGKILL=yes
```
- Restart policy: **none**
- No `After=emgdhmid.service` — but `nav_pre.target` is reached after smng.service starts,
  which has `After=emgdhmid.service`, so emgdhmid is up by then.

### 2.4 `nav_dispapf.service` (PS_DISPAPF / `dispapf_proc`)
```
Description=Display APF Service
Requires=nav_pre.target
OnFailure=nav_smngpret.service
DefaultDependencies=no
Type=simple
ExecStart=/home/naviwork/system/bin/dispapf_proc "PS_DISPAPF"
TimeoutSec=90
SendSIGKILL=yes
```
- Restart policy: **none**

### 2.5 `emgdhmid.service` (the EMGD DRM master holder — we MUST NOT kill this)
```
Description=emgdhmid Service
DefaultDependencies=yes
Type=simple
RemainAfterExit=yes
ExecStart=-/usr/sbin/emgdhmid
Group=video
UMask=0002
```
- `RemainAfterExit=yes` — once started, marks the unit `active` regardless of process exit
- No Restart=
- Started by `basic.target.wants/emgdhmid.service` — **before graphical.target** (basic
  dependency = early in boot). emgdhmid grabs DRM master before any nav_* daemon launches.
- Required by: `android-start.service` (Requires=), `emgdhmi-test.service` (Requires=),
  `nav_initialscreen.service` (Wants=, After=).
- `nav_smng.service` declares `After=emgdhmid.service` (no Requires=) — so smng waits but
  doesn't propagate failure to emgdhmid.

### 2.6 What dependencies these declare on the rest of the system

| Daemon | Requires= | After= | Wants= |
|---|---|---|---|
| nav_navi | nav_pre.target | — | — |
| nav_hmictrl | nav_pre.target | — | — |
| nav_display | nav_pre.target | — | — |
| nav_dispapf | nav_pre.target | — | — |
| emgdhmid | (none) | (none — DefaultDependencies=yes pulls in basic.target backwards) | — |
| nav_smng | (none) | home-naviwork-tmp.mount, nav_init.service, **emgdhmid.service**, home-naviwork-data-pdm-ram.automount, nav_before.service | — |
| nav_initialscreen | nav_pre.target | emgdhmid.service | emgdhmid.service |
| nav_ioapf | nav_early.target | — | — |

**Critical:** No daemon declares `Requires=emgdhmid.service` (only `After=` or `Wants=`).
Even if we crashed emgdhmid, the nav_* daemons would still attempt to start. The reverse
isn't true: `android-start.service` does `Requires=emgdhmid.service`, so emgdhmid going
down stops android-start (which is fine — that's a different subsystem).

---

## 3. The smng Supervisor (DENSO Start Manager)

### 3.1 Unit
```
# /tmp/dsu-slot-a/lib/systemd/system/nav_smng.service
Description=NAV SMNG Service
After=home-naviwork-tmp.mount nav_init.service emgdhmid.service home-naviwork-data-pdm-ram.automount nav_before.service
OnFailure=nav_backup.service
DefaultDependencies=no
Type=simple
ExecStart=/home/naviwork/system/bin/smng "PS_OS01"
TimeoutSec=260
SendSIGKILL=yes
```
- **In `graphical.target.wants/`** — this is the unit that kicks the whole nav stack to life
- No Restart=
- Single binary: `/home/naviwork/system/bin/smng "PS_OS01"` (lives on naviwork ext4 partition,
  not on Slot A — we cannot read it from the extracted Slot A image)

### 3.2 What smng actually does

The naming `"PS_OS01"` is the DENSO IPC channel/process ID; every nav_* daemon takes a
`"PS_*"` arg. smng coordinates via the in-kernel message queue (`LimitMSGQUEUE=8192000`
appears on every unit) and shared memory (`/dev/shm/LEGRES` created by `nav_init.service`).

**Key insight:** smng does **NOT** fork/spawn the nav_* daemons. Each daemon is a separate
systemd unit with its own `ExecStart=`. smng IPCs to them after they're up. So smng is not
a process supervisor in the classical sense — it's the **state machine orchestrator** that
the daemons consult.

If smng dies, **its `OnFailure=nav_backup.service` fires** — and nav_backup ends in
`ExecStartPost=/bin/systemctl start poweroff.service` (an unconditional poweroff). So smng
is a single point of failure; the system reboots when smng exits abnormally.

### 3.3 The `nav_smngpret` cascade

```
# nav_smngpret.service
Description=SMNG Pre Terminate Service
OnFailure=nav_backup.service
DefaultDependencies=no
Type=oneshot
ExecStart=-/home/naviwork/system/bin/smngpret      # ignore failure here
ExecStartPost=/bin/systemctl stop nav_smng.service # <-- this is the kill switch
RemainAfterExit=yes
TimeoutSec=10
SendSIGKILL=yes
```

**This unit is the chain trigger.** It runs `smngpret` (graceful pre-terminate hook) and
then *forcefully stops* `nav_smng.service`. Stopping smng triggers smng's `OnFailure=nav_backup`,
which triggers poweroff.

Flow when any nav_* enters `failed`:
```
  nav_<x>.service: failed
    └─> OnFailure=nav_smngpret.service
          ├─ ExecStart=smngpret (returns 0 ignored, smngpret may or may not be present)
          └─ ExecStartPost=systemctl stop nav_smng.service
                └─> nav_smng.service: stopped/failed
                      └─> OnFailure=nav_backup.service
                            ├─ ExecStart=bkup_prg     (run final backup)
                            └─ ExecStartPost=systemctl start poweroff.service  💀
```

### 3.4 When does a unit enter `failed` vs. `inactive`?

This is the critical detail that determines whether SIGTERM is safe.

systemd marks a `Type=simple` service `failed` when:
- The main process exits with non-zero status, OR
- The main process is killed by a signal NOT listed in `SuccessExitStatus=`, OR
- The main process dumps core

The DENSO units have NO `SuccessExitStatus=` configured. So **a process killed by SIGTERM
that does not catch and exit(0) will be marked `failed`** in the version of systemd shipped
with MeeGo 1.2 (systemd v37-ish era, this behavior is consistent).

However, **`systemctl stop <unit>` puts the unit through a controlled state transition
that does NOT trigger `OnFailure=`**. systemd sends SIGTERM (or whatever `KillSignal=` is)
to the cgroup, waits for `TimeoutStopSec`, then SIGKILL. The unit goes to `inactive`, not
`failed`. **No cascade.**

This is why the safest action — if we ever had shell access on the running car — would be
`systemctl stop nav_navi.service nav_hmictrl.service nav_display.service nav_dispapf.service`
in a single command. Since we're patching offline via debugfs, we use a different lever (§6).

---

## 4. Cascade Dependency Map

### 4.1 OnFailure= edges in the system

From `grep -rE "^OnFailure=" /tmp/dsu-slot-a/lib/systemd/system/`:

```
ALL nav_*.service                        --OnFailure-->  nav_smngpret.service
nav_smng.service                         --OnFailure-->  nav_backup.service
nav_smngpret.service                     --OnFailure-->  nav_backup.service
nav_backup.service                       --OnFailure-->  poweroff.service
home-naviwork.mount                      --OnFailure-->  poweroff.service
home-naviwork-tmp.mount                  --OnFailure-->  poweroff.service
home-naviwork-data-pdm-ram.mount         --OnFailure-->  pdmram-mount-error-failsafe.service
                                                          └─ ExecStartPost=systemctl start poweroff
pdmram-mount-error-failsafe.service      --OnFailure-->  poweroff.service
local-fs.target                          --OnFailure-->  emergency.target
```

**Every nav_* failure path terminates in `poweroff.service`.** There is no graceful
"restart just the daemon" path anywhere — DENSO designed this as "if nav misbehaves,
reboot the whole car".

### 4.2 PartOf= / BindsTo= — none present

```
grep -rE "^(PartOf|BindsTo)=" /tmp/dsu-slot-a/lib/systemd/system/
  (no output)
```

This is a *huge* relief. `PartOf=` would have caused our SIGTERM of `nav_navi` to also
stop `nav_hmictrl` automatically (or vice versa). `BindsTo=` would have done the same
in failure direction. Neither exists. **Each nav_* is independently stoppable.**

### 4.3 Requires= edges into emgdhmid (reverse search)

```
android-start.service:     Requires=emgdhmid.service
emgdhmi-test.service:      Requires=emgdhmid.service
nav_initialscreen.service: Wants=emgdhmid.service  (NOT Requires)
nav_smng.service:          After=emgdhmid.service  (NOT Requires)
```

If emgdhmid ever entered `failed`, android-start.service and emgdhmi-test.service would
be stopped. nav_smng and nav_initialscreen would not be auto-stopped. **We must not let
emgdhmid die** — but since we're not touching it, this is moot. Recap from prior research:
emgdhmid holds DRM master; killing it cascades to display_ps + navi_ps crash (via DENSO
IPC, not systemd).

### 4.4 Full reverse dependency search results

```
grep -rE "(navi_ps|hmictrl|display_ps|dispapf|emgdhmid)" /tmp/dsu-slot-a/etc/ \
     /tmp/dsu-slot-a/lib/systemd/ /tmp/dsu-slot-a/usr/lib/systemd/
```

The ONLY references to `navi_ps`, `hmictrl_proc`, `display_ps`, `dispapf_proc` by binary
name anywhere in `/etc/`, `/lib/systemd/`, and `/usr/lib/systemd/` are the 4 `ExecStart=`
lines in the 4 corresponding unit files. **Nothing else launches them, references them,
or watches them by name.** They are pure DENSO IPC peers — no systemd-level cross-wiring.

References to `emgdhmid`:
- `emgdhmid.service` (the unit itself)
- `emgdhmi-test.service` Requires + After (test harness, not normally running)
- `android-start.service` Requires + After (Android subsystem dependency)
- `nav_initialscreen.service` Wants + After (soft dep, doesn't propagate failure)
- `nav_smng.service` After (ordering only)

No DENSO unit declares `Requires=emgdhmid.service`. emgdhmid going down does not
auto-stop any nav_*.

---

## 5. Boot Order Timeline (Reconstructed)

```
t=0       kernel hands off to systemd (PID 1)
t≈0.1     sysinit.target.wants/  → checkfs-mtdblock0, systemd-modules-load, systemd-readahead-replay
                                   (modules-load loads watchdog.ko, ohci_hcd, etc — kernel watchdog now ticking)
t≈0.5     basic.target.wants/    → emgdhmid.service starts  ← EMGD CLAIMS DRM, MAPS FB, GRABS LVDS
                                   pulseaudio.service, udev.service, udisks.service, iptables.service
t≈1.0     graphical.target.wants/ → nav_init.service (mkdir /dev/shm/LEGRES)
                                   nav_before.service (run rename.sh — handle pending sw updates)
                                   home-naviwork.automount triggers ext4 mount
                                   nav_driver.service (insmod custom drivers, dac_reset, bt_dfu_inst)
                                   nav_smng.service starts → smng "PS_OS01" running
                                                          → smng's start triggers nav_pre.target by
                                                            reverse pull from the 18 services that Require it
                                                          → all 18 nav_* services start in parallel
                                                          → navi_ps, hmictrl_proc, display_ps, dispapf_proc UP
                                   abs_clock.service     → abstc binary (Restart=on-failure!)
                                   nav_systemlogd.service → systemlogd
                                   syslogd.service, connmand.service
t≈13s     late-services.timer fires → late-services.target activates
                                   → android-mount.service (OUR R1 HOOK PATCH — runs android-mount.sh
                                     which we modified to launch /opt/q60r1/run.sh)
                                   → sud-change-elilo.service
                                   → android-data-system-tmp.mount
t≈14s+    android.target.wants/   → android-modules-load.service
                                   → android-start.service starts /sbin/android.sh which chroots /android /init
                                     (uses nav_ipodplayer.service After= for ordering)
t≈75s     nav_dmsg_start.service's ExecStartPre=/bin/usleep 75000000 finally returns
                                   This is the source of the mysterious 75-second pause in CLAUDE.md.
                                   It is a systemd-spawned process whose ppid IS systemd (PID 1),
                                   which is why earlier instrumentation thought it came from Android init.
```

### Our R1 hook window

`android-mount.service` runs at t≈13s. By then:
- emgdhmid has held DRM master since t≈0.5s (12+ seconds head start)
- All 4 UI daemons are running since t≈1.5–2s
- smng IPC state machine is up

**There is no realistic pre-emption window** where we could take DRM master before
emgdhmid. The R1 strategy must work *alongside* a running emgdhmid (which it does, via
the v2g_bridge sprite path). Plan B''' instead disables the UI daemons at boot — we
patch the unit files so they never start in the first place, then start our Qt app
ourselves.

---

## 6. Disable Strategy — Recommendations

We deploy via `debugfs` on Slot A while the SD card is in our Mac. We cannot run
`systemctl mask` directly. The options below assume **file-level edits** persisted to
the ext4 partition before boot.

### 6.1 Strategy A (RECOMMENDED): Symlink unit files to `/dev/null` (mask)

`systemctl mask <unit>` is implemented internally as
`ln -sf /dev/null /etc/systemd/system/<unit>`. systemd treats a `/dev/null` symlink at
that path as "unit is masked — refuse to load, refuse to start, error if dependencies
ask for it."

For each of the 4 UI daemons, on Slot A:
```
/etc/systemd/system/nav_navi.service     -> /dev/null
/etc/systemd/system/nav_hmictrl.service  -> /dev/null
/etc/systemd/system/nav_display.service  -> /dev/null
/etc/systemd/system/nav_dispapf.service  -> /dev/null
```

The `/etc/systemd/system/` overrides take precedence over `/lib/systemd/system/`.
The lib copies are untouched (factory-recovery-friendly).

**Caveat:** when systemd tries to load a masked unit, units that `Requires=` it would
normally fail. **But nothing Requires any of the 4 UI daemons.** They are pulled in
by `nav_pre.target.wants/<unit>.service` symlinks — and `target.wants/` is a soft
binding (equivalent to `Wants=`). A masked unit being Wanted (not Required) is a
warning, not a failure. **No cascade.**

To verify: `Requires=` references in *any* unit for `nav_navi`, `nav_hmictrl`,
`nav_display`, `nav_dispapf` = **zero matches.** Only `nav_pre.target.wants/` symlinks
reference them, and that's a Wants= relationship.

### 6.2 Strategy B: Neuter `ExecStart=` to `/bin/true`

Edit each of the 4 unit files in `/lib/systemd/system/` to replace:
```
ExecStart=/home/naviwork/system/bin/navi_ps "PS_NAVI"
```
with:
```
ExecStart=/bin/true
```

Pros: systemd starts the unit, `/bin/true` exits 0 immediately, unit goes to `inactive`
state (or for Type=simple, "deactivating (running)" → "inactive (dead)"). **No
`OnFailure=` because exit 0 is success.** Dependencies wait the standard amount.

Cons: edits factory unit files (less clean than masking via /etc overlay), the unit
is briefly "active" so smng might IPC to it and timeout.

### 6.3 Strategy C: Binary rename via debugfs (fails-open)

Rename `/home/naviwork/system/bin/navi_ps` → `/home/naviwork/system/bin/navi_ps.disabled`
on the naviwork ext4 partition.

When systemd tries to run it, `execv()` returns ENOENT. systemd marks the unit `failed`.
**This triggers the OnFailure cascade — POWEROFF.** **DO NOT USE THIS STRATEGY.**

### 6.4 Recommended deployment (Strategy A + safety net)

```
# Conceptually, via debugfs commands against the ext4 superblock of Slot A:
cd /etc/systemd/system/
symlink nav_navi.service     /dev/null
symlink nav_hmictrl.service  /dev/null
symlink nav_display.service  /dev/null
symlink nav_dispapf.service  /dev/null

# Then ALSO edit /lib/systemd/system/nav_smng.service to add SuccessExitStatus=SIGTERM
# in case anything kills smng during our app's startup — prevents the poweroff cascade.
```

If `debugfs` cannot create symlinks reliably (it can, via `symlink` command), the
fallback is to write override unit files containing only:
```
[Service]
ExecStart=
ExecStart=/bin/true
```
to `/etc/systemd/system/nav_navi.service.d/disable.conf` (drop-in directory pattern).
The empty `ExecStart=` clears the inherited one; the second `ExecStart=/bin/true`
replaces it. systemd reads the override at boot.

**Verify with emulator before car deploy** — that's table stakes per ONBOARDING.md.

---

## 7. Watchdog Implications

### 7.1 Hardware watchdog mechanism

`/tmp/dsu-slot-a/lib/modules/2.6.37.6-.../kernel/bsp/watchdog/watchdog.ko` is a custom
DENSO kernel module. Its strings show:
```
watchdog_task_init    kthread_create    set_cpus_allowed_ptr    sched_setscheduler
gpio_direction_output gpio_get_value    msleep                 watchdog_restart
```

It's a **kernel kthread** that toggles a GPIO line to kick an external hardware watchdog
IC. **No userspace consumer.** No `/dev/watchdog` character device exposed (the
`makedev.d` entry creates the node, but no userspace program writes to it; modules-load
loads `watchdog` first, blacklist.conf blacklists `i8xx_tco` — explicitly avoiding the
generic Intel watchdog so the DENSO one wins).

### 7.2 Conclusion

**Killing the 4 UI daemons has zero impact on watchdog petting.** The kernel kthread
keeps running regardless of userspace process state. Our Qt app does NOT need to pet
`/dev/watchdog`. Unless we cause a kernel hang or kthread death (e.g., by replacing the
kernel with one that lacks `watchdog.ko`), the hardware watchdog stays satisfied.

This is fully consistent with the prior CLAUDE.md note that "Hardware watchdog confirmed
loaded in production captures" — confirmed loaded means the kernel module is loaded; the
kthread is running; userspace is not in the loop.

(For Phase 1 diagnostic boot, where we replace the entire kernel with 4.19 and the
DENSO watchdog.ko is absent, this analysis is moot — Phase 1 uses `ie6xx_wdt` only,
which IS userspace-pet-able and has its own pet daemon at `rootfs/opt/nav/watchdog-pet.sh`.
But that's a different phase. For Plan B''' running on the factory 2.6.37 kernel with
factory drivers, the GPIO-kicked DENSO watchdog removes userspace from the loop.)

---

## 8. Evidence Index — File Paths

### Critical unit files (the 4 UI daemons)
- `/tmp/dsu-slot-a/lib/systemd/system/nav_navi.service`
- `/tmp/dsu-slot-a/lib/systemd/system/nav_hmictrl.service`
- `/tmp/dsu-slot-a/lib/systemd/system/nav_display.service`
- `/tmp/dsu-slot-a/lib/systemd/system/nav_dispapf.service`

### Cascade machinery
- `/tmp/dsu-slot-a/lib/systemd/system/nav_smng.service` (the supervisor unit)
- `/tmp/dsu-slot-a/lib/systemd/system/nav_smngpret.service` (cascade trigger)
- `/tmp/dsu-slot-a/lib/systemd/system/nav_backup.service` (cascade terminator → poweroff)

### Display stack
- `/tmp/dsu-slot-a/lib/systemd/system/emgdhmid.service` (DRM master holder — DO NOT TOUCH)
- `/tmp/dsu-slot-a/lib/systemd/system/emgdhmi-test.service` (test, normally inactive)
- `/tmp/dsu-slot-a/usr/sbin/emgdhmid` (the binary, ELF32 i386)

### Target topology
- `/tmp/dsu-slot-a/lib/systemd/system/default.target -> graphical.target`
- `/tmp/dsu-slot-a/lib/systemd/system/graphical.target`
- `/tmp/dsu-slot-a/lib/systemd/system/nav_pre.target`
- `/tmp/dsu-slot-a/lib/systemd/system/nav_pre.target.wants/` (contains 19 nav_*.service symlinks)
- `/tmp/dsu-slot-a/lib/systemd/system/basic.target.wants/emgdhmid.service` (early start)
- `/tmp/dsu-slot-a/lib/systemd/system/graphical.target.wants/nav_smng.service` (kicks the stack)

### Watchdog
- `/tmp/dsu-slot-a/lib/modules/2.6.37.6-35.1_DLK0040-android-intel-crossville_lapis-fastboot/kernel/bsp/watchdog/watchdog.ko`
- `/tmp/dsu-slot-a/etc/modules-load.d/modules.conf` (auto-loads `watchdog` module)
- `/tmp/dsu-slot-a/etc/modprobe.d/blacklist.conf` (blacklists `i8xx_tco`)

### Android-init boot hook (our R1 injection point)
- `/tmp/dsu-slot-a/sbin/android-mount.sh` (we patched this for R1)
- `/tmp/dsu-slot-a/lib/systemd/system/android-mount.service` (calls it, runs at late-services.target+1s)
- `/tmp/dsu-slot-a/lib/systemd/system/late-services.timer` (OnStartupSec=13s)

### 75-second mystery source
- `/tmp/dsu-slot-a/lib/systemd/system/nav_dmsg_start.service`
  contains `ExecStartPre=/bin/usleep 75000000` — this is the 75s delay
  attributed to Android init in prior captures. Source = systemd, ppid=1.

### Init reality
- `/tmp/dsu-slot-a/sbin/init -> ../bin/systemd` (PID 1 is systemd, not Android init)
- `/tmp/dsu-slot-a/etc/inittab` — present but **unread** (systemd ignores it)
- `/tmp/dsu-slot-a/etc/rc.d/rc{0..6}.d/` — present but **unused** (vestigial LSB)
- No `/init.rc` or `/system/init.rc` on Slot A — Android init.rc lives inside
  `/mnt/android/ramdisk.img` (on a different partition) and only runs chrooted

---

## 9. Closing Notes — What Could Still Bite Us

1. **smng IPC timeouts.** When the 4 UI daemons don't answer smng's IPC, smng may
   internally enter an error state that triggers its own exit. smng's exit → its
   `OnFailure=nav_backup.service` → poweroff. **Mitigation: also mask `nav_smng.service`**
   (it's the orchestrator for things we're replacing — disable it cleanly). Without smng,
   other surviving nav_* services (nav_audio, nav_camera, nav_tel, etc.) will lose
   coordination. We accept that — Plan B''' replaces the entire UI subsystem, audio/
   camera/tel handling moves to our app.

   If we want to keep some factory services running (e.g., nav_audio), we need to also
   mask `nav_smng.service` (so it doesn't OnFailure-poweroff) AND mask the
   `nav_smngpret.service` cascade trigger.

2. **`smng` ExecStart returns 0 paths.** If smng cleanly exits 0 when it can't reach its
   peers, the unit goes to `inactive` (not `failed`) and no cascade fires. We don't know
   smng's exit-code behavior without reading the binary (which lives on naviwork, not
   Slot A). **Assume worst case: mask the cascade chain pre-emptively.**

3. **`nav_initialscreen` and other surviving nav_*.** If we only mask the 4 UI daemons
   and leave `nav_initialscreen`, `nav_audio`, `nav_camera`, etc. running, those will
   try to IPC with the 4 we killed, fail, and **enter `failed` state themselves**,
   triggering the cascade. **The safe minimum mask set is all 19 nav_*.service files plus
   nav_smng.service plus nav_smngpret.service plus nav_backup.service.** That kills the
   entire DENSO nav stack cleanly. emgdhmid stays up; our Qt app + factory EMGD stack
   is enough.

4. **`abs_clock.service` has `Restart=on-failure`.** This is the only nav-adjacent service
   that respawns. It's not one of our 4 targets but it does IPC with smng. If smng goes
   away, abstc might fail and restart in a loop. Negligible at boot (just CPU churn), but
   add `nav_abs_clock.service` (or equivalent) to the mask list if it becomes a problem.

5. **`OnFailure=` is not synchronous in older systemd.** systemd v37 may queue OnFailure
   actions slightly differently than modern systemd; behavior described here is the
   documented contract, but expect minor surprises in edge cases. **Always emulator-test
   first.**

6. **`/etc/systemd/system/` symlink writes via debugfs** — verify the symlinks are
   created correctly on the ext4 partition (debugfs has a `symlink` command). If the
   symlink semantics through debugfs are inconsistent, fall back to writing actual
   override files: `/etc/systemd/system/<unit>.service` as a regular file with content
   `# masked\n` is treated as a syntactically-empty unit that systemd will refuse to
   start. Or use the drop-in `.d/` directory pattern (§6.4).

---

**Recommendation for next step:** patch the ext4 of Slot A to mask the 19 nav_*.service
files plus nav_smng.service plus nav_smngpret.service plus nav_backup.service. Leave
emgdhmid alone. Deploy. Boot in car. Confirm in `journalctl` (or `/var/log/messages`,
since this is MeeGo era) that none of the 19 services started and no poweroff cascade
fired. Then bring up the Qt app via our existing `/opt/q60r1/run.sh` hook.
