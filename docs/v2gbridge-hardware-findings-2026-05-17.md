# V2G Bridge — Hardware Test Findings (2026-05-15 → 2026-05-17)

**Platform:** Clarion QY5092 DCU · 2017 Infiniti Q60  
**Kernel:** Wind River Linux 2.6.37.6-35.1_DLK0040-android-intel-crossville\_lapis-fastboot (i386 Atom E6xx Tunnel Creek)  
**GPU:** Intel EMGD 1.5.15.3226 · Tunnel Creek IGD  
**Capture:** LAPIS ML7213 IOH — ioh\_vin V4L2 driver  
**Method:** Static i386 musl binary (`q60nav_v4l2_test`) deployed via debugfs to SD card Slot A, launched at boot via `android-mount.sh` hook.

---

## 1. Boot Hook Pipeline

### Finding
`android-mount.sh` (patched via debugfs) fires on every boot as root before any display or
navigation process starts. Confirmed via `/boot/Q60_HOOK_RAN.TXT` written pre-launch.

Pipeline: `android-mount.sh` → `( sleep 3; sh /opt/q60r1/run.sh ) &` → `/opt/q60r1/v4l2_test`

Execution verified: rc=0, runtime ~7 seconds, logs flushed to `/boot/`.

### Why it matters
Non-destructive root code injection without touching factory Slot B. We have an unconditional,
pre-boot execution primitive. Any future payload — overlay painter, bus sniffer, init patcher —
deploys this way.

### What it enables
- Iterative on-device testing without reflashing
- Patch delivery to a running production unit
- Eventual persistent R1 overlay client installation

---

## 2. V4L2 / IOH-GTT Buffer Allocation

### Finding
`/dev/video0` (ioh\_vin) allocates 3 mmap-able GTT buffers via REQBUFS. Confirmed values:

| Buffer | GTT offset | Size       |
|--------|-----------|------------|
| 0      | `0x000000` | 953,472 B  |
| 1      | `0x0e9000` | 953,472 B  |
| 2      | `0x1d2000` | 953,472 B  |

Format: 800×480 YUYV, pitch=1600. STREAMON succeeds (r=0). Buffers remain live through all
subsequent phases.

### Why it matters
These are the actual GPU-side addresses of the IOH capture ring. They are the same buffers
the DENSO V2G bridge routes into Sprite C. If V2G_ENABLE accepts them, the display path is
complete — no additional buffer allocation needed.

### What it enables
- Pass exact GTT offsets into V2G_ENABLE struct sweeps (was the root cause of "GTT mapping
  requested for 0 buffers" in earlier test runs)
- Write our own pixels into `g_buf[0]` (mmap'd) then flip via V2G_ENABLE

---

## 3. IGD_ALTER_OVL2 — Confirmed Working, No DRM Master Required

### Finding
`IGD_ALTER_OVL2` (`0xc0c8646f`, `_IOWR('d', 0x6f, 200)`) returns r=0, rtn=0 for:
- `plane=5` (Sprite C)
- `plane=3` (primary overlay)

Confirmed without DRM master (as authenticated DRM client only). Source annotation in
`emgd_drv.c` explicitly downgrades this ioctl from `DRM_MASTER` to `DRM_AUTH`:

> "so that libva wayland can call alter\_ovl without going through X server"

### Why it matters
We can configure the overlay plane geometry, surface address, format, and enable flag without
contending with `emgdhmid` for DRM master. The IGD overlay hardware is ready to display.

### What it enables
- Set source rect, dest rect, pixel format, GTT surface address for Sprite C
- Change overlay parameters at will — scale, position, blend mode
- Combine with V2G_ENABLE to activate the live camera-feed path

---

## 4. DRM_SET_MASTER — Succeeds as Root Without Killing emgdhmid

### Finding
`DRM_SET_MASTER` (`_IO('d', 0x1e)`) returns r=0 as root even while `emgdhmid` (pid=131) is
running and holds the display. The kernel allows a root process to forcibly take master.

`IGD_GMM_ALLOC_REGION` was attempted after obtaining master — returns rtn=−2 regardless.
This appears to be an EMGD internal failure unrelated to master state, not a blocker.

### Why it matters
Eliminates the need to kill any factory process to take the DRM privileged path. Earlier
iteration killed `emgdhmid` — this crashed `display_ps`, `navi_ps`, and `hmictrl_proc`
(all hold DRM fds). SET_MASTER as root is the correct, non-destructive path.

### What it enables
- Call `IGD_GMM_ALLOC_SURFACE` (DRM_MASTER gated) cleanly
- Full DRM master access for any MASTER-gated ioctl
- Future option: legitimate master takeover between nav system events

---

## 5. Nav Crash Root Cause — Resolved

### Finding
Earlier test killed `emgdhmid` (pid=131). This unexpectedly crashed the entire navigation
UI because `display_ps`, `navi_ps`, and `hmictrl_proc` (pid=309) all hold open file
descriptors to `/dev/dri/card0`. When emgdhmid dies and its master fd closes, the kernel
revokes master — cascading into display teardown on all dependent processes.

`hmictrl_proc` is truncated in `/proc/PID/comm` — likely `hmictrl_process` or similar —
and is also part of the DRM chain.

### Why it matters
Killing emgdhmid is off the table permanently. It's not needed anyway — SET_MASTER as root
works without it.

### What it enables
- Safe testing across arbitrary reboots without nav system disruption
- Confirmed process dependency map: emgdhmid → display_ps → navi_ps → hmictrl_proc

---

## 6. Valid EMGD Overlay Planes

### Finding
Kernel messages during V2G_ENABLE attempts confirm which planes the EMGD driver accepts:

| Plane | Identity              | Valid |
|-------|-----------------------|-------|
| 3     | Primary overlay       | ✅    |
| 5     | Sprite C              | ✅    |
| 0,1,2,4,6,7,8 | Various     | ❌    |

`emgdhmid`'s EMGD portorder: `portorder = 2,4,0,0,0` → port 2 = LVDS (main 7" display),
port 4 = SDVO (secondary). The "screen" parameter in the V2G_ENABLE struct is believed to
map to these port numbers, not 0-based indices.

### Why it matters
Narrowing the parameter space. Sweeps that omit planes 3 and 5 and port numbers 2/4 are
wasting boot cycles.

### What it enables
- Targeted struct sweeps: plane ∈ {3, 5}, screen ∈ {0, 1, 2, 4}
- Eliminates ~30 invalid combinations per boot

---

## 7. V2G_ENABLE — Current Status and errno Pattern

### Finding
`V2G_ENABLE_BRIDGE` = `0xc0047600` = `_IOWR('v', 0, 4)`. Confirmed from `emgdhmid`
disassembly. Passes a **pointer** to a 4-byte struct (not a direct integer).

`V2G_DISABLE_BRIDGE` = `0xc0047601` = `_IOWR('v', 1, 4)`. Returns r=0 always. ✅

errno pattern from boots 1–2:

| Argument type         | errno  | Interpretation                                              |
|-----------------------|--------|-------------------------------------------------------------|
| Direct integer value  | 14 (EFAULT) | Kernel dereferences it as a pointer — confirms struct pointer required |
| Pointer to struct     | 22 (EINVAL) | Kernel reads struct OK; `enable_direct_display_tnc()` rejects content |

The internal function `v2g: enable_direct_display_tnc() returned -22!` appears in kernel
messages for every pointer-based attempt. The failure is INSIDE the display configuration
logic, not at the ioctl dispatch layer.

### Why it matters
We've moved past two gatekeeping layers (ioctl auth, struct copy). The only remaining
blocker is the content of the struct that `enable_direct_display_tnc()` validates.

### What it enables
- Next boot tests the exact emgdhmid value (`0x00010001` as pointer)
- Tests ioctl size variants (driver may read more than 4 bytes)
- Tests `_IOW` vs `_IOWR` cmd variant
- Tests EMGD port numbers (2, 4) as the screen field

---

## 8. emgdhmid Disassembly — Confirmed Call Signature

### Finding
Disassembly of `/system/bin/emgdhmid` shows V2G_ENABLE is called with:

```
ioctl(fd_v2gbridge, 0xc0047600, ptr)
where *ptr = { uint16_t = 1, uint16_t = 1 } = uint32_t 0x00010001
```

Both fields are 1. Field identity (which is screen, which is plane) is ambiguous from the
binary alone since both values are equal. EMGD portorder and kernel plane validation suggest
one field is a display/screen index and the other is a plane identifier.

### Why it matters
This is the ground truth from the process that successfully enables the bridge in normal
operation. If `0x00010001` as a struct pointer doesn't work for us, the difference is
environmental (DRM master state, V4L2 stream state, prior ALTER_OVL2 call).

### What it enables
- `ptr→{0x00010001}` is the highest-priority test in the next boot (D layout, item 0)
- Port-number variants: `0x00020001`, `0x00040001`, `0x00010002`, `0x00010004`

---

## 9. Slow Boot — 75-Second Factory Delay Identified

### Finding
`/proc` scan found:

```
pid=229  cmdline=/bin/usleep [arg truncated by NUL bug]
State: S (sleeping)
PPid: 1
```

75,000,000 µs = 75 seconds. `ppid=1` means init spawned it directly (not a subshell).
This is the dominant factor in the observed slow boot — navigation system appears fully
operational after this delay expires.

The NUL-separator bug in the previous scanner prevented reading the full argument. Fixed in
current build: NUL bytes replaced with spaces before `strstr`, full cmdline now logged.
Parent chain and `/etc/init.d/` scan also added to identify the owning script.

### Why it matters
75 seconds is not a hardware constraint — it's a factory-baked initialization holdoff,
probably to wait for camera bus or modem initialization. It's a software parameter that
can be patched out or reduced.

### What it enables
- Identify exact init script in next boot via `/etc/init.d/` scan
- Once identified: either reduce the value (e.g. 5s) or conditionalize it
- Estimated boot improvement: 60–70 seconds

---

## 10. android-mount.sh Double-Invocation — Fixed

### Finding
Prior deploy left a legacy `nohup` block OUTSIDE the `>>Q60_HOOK_START/END<<` markers in
`android-mount.sh`. The Python `re.sub` only stripped the marked section, leaving the nohup
block intact. This caused double-invocation: the nohup block fired AND the hook block fired.

Root cause: early deploys used `nohup ... &` style injection directly in the script body
rather than delimited markers. Subsequent deploys preserved it.

Fix: deploy script now reads from Slot B (factory-clean copy on mmcblk0p3) as base, applies
multiple `re.sub` patterns to strip all legacy artifacts before injecting the clean hook.

### Why it matters
Double invocation created race conditions in log files and unpredictable binary behavior.
Clean single-invocation is confirmed in current boots.

### What it enables
- Reliable single-execution guarantee for future payload deployments
- Slot B read as clean baseline is now a permanent practice in `deploy-thorough.sh`

---

## 11. Binary Delivery Infrastructure

### Confirmed stack

| Component | Value |
|-----------|-------|
| Build container | `docker --platform linux/386 alpine` |
| Compiler | `gcc -static -no-pie -O2` |
| Post-process | `objcopy --remove-section=.note.ABI-tag --strip-all` |
| Binary size | ~115 KB |
| Deploy tool | `debugfs` from `e2fsprogs` (Homebrew) |
| Slot | Slot A `/dev/disk12s2` (ext4) |
| Factory slot | Slot B `/dev/disk12s3` (read-only reference) |
| Boot partition | `/dev/disk12s1` (FAT32, mounted as `/boot`) |
| Log paths | `/boot/Q60_HOOK_RAN.TXT`, `/boot/Q60_R1_V4L2.LOG`, `/boot/Q60_KMSG.LOG` |

Kernel ring buffer captured via `syslog(SYSLOG_ACTION_READ_ALL)` syscall (NR=103 on i386
2.6.37). Writes 128 KB ring to `/tmp/Q60_KMSG.LOG` then copies to `/boot` at exit.

### Why it matters
Entire toolchain is reproducible from macOS without a cross-compiler or JTAG. Any developer
with the SD card and Homebrew e2fsprogs can deploy.

### What it enables
- Sub-5-minute deploy-test cycle once the ioctl arg is confirmed
- Same pipeline for the production R1 client once V2G_ENABLE is solved

---

## 12. V2G_DISPLAY_FRAME — Newly Discovered Third Ioctl

### Finding
`_IOWR('v', 2, 4)` = `0xc0047602` triggers `v2g_display_frame()` in the kernel driver.
Discovered when the cmd-sweep F-layout hit cmd=2 and the kernel logged:
```
v2g_display_frame() buf # (196609) out of range !
```
Valid buffer indices are 0, 1, 2 (matching the 3 V4L2 GTT buffers). The initial call used
the wrong arg `(g_nbufs<<16)|1u = 196609`; fixed in the next binary.

### Theory
`V2G_DISPLAY_FRAME(buf_index)` may register IOH DMA buffers with the V2G bridge,
incrementing the buffer count that `enable_direct_display_tnc()` checks. If the count
was 0 because `V2G_DISPLAY_FRAME` was never called (only `V2G_ENABLE` was), calling
`DISPLAY_FRAME(0)`, `DISPLAY_FRAME(1)`, `DISPLAY_FRAME(2)` before `V2G_ENABLE` might
unblock the entire path.

### Status
Testing next boot. Sequence in binary v5:
1. V4L2 REQBUFS + STREAMON (P2)
2. DISPLAY_FRAME(0), DISPLAY_FRAME(1), DISPLAY_FRAME(2)  
3. V2G_ENABLE with `{plane=5, screen=0}` etc.

---

## 13. camera_ps — The Actual V2G Bridge Manager

### Finding
`emgdhmid` does NOT manage `/dev/v2gbridge` during normal operation. It only holds DRM
master for EMGD initialization. The process that actually opens and manages the V2G
bridge is `camera_ps` — the factory rearview camera daemon.

`camera_ps` process maps + fds are now captured in P0 survey. Its GTT surface addresses
(if visible in `/proc/camera_ps_pid/maps`) could reveal the live overlay surface we could
write to directly.

### Impact
Earlier reasoning about emgdhmid's role in V2G was wrong. `camera_ps` is the correct
subject for understanding production V2G_ENABLE call sequences and context.

---

## 14. Android Init — 75s Delay Source

### Finding
```
init (pid=1) cmdline=[/sbin/init android]
```
The factory system uses **Android init** — not systemd or SysV init.d. Android init reads
`init.rc` files, typically at `/init.rc` or `/system/init.rc`. The 75s usleep (ppid=1) is
launched directly by this init system.

The init.d scan (`/etc/init.d/`, `/etc/rc.d/`) found only 500ms sleeps — not the 75s one.
The source is an Android `init.rc` file not yet scanned.

Next boot adds scan of `/init.rc`, `/system/init.rc`, `/etc/init/*.rc` to find it.

---

## 15. Open Questions — Ranked by Blocking Impact

| # | Question | Blocking? | Next test |
|---|----------|-----------|-----------|
| 1 | Does V2G_DISPLAY_FRAME(0/1/2) prime the IOH DMA buffer count? | **YES** | F-sweep in next boot with correct indices |
| 2 | Does YUYV pixel write + ALTER_OVL2 show on screen? | **YES (alt path)** | P6.5 red pixel test in next boot |
| 3 | Which init.rc file owns the 75s usleep? | No — boot speed | init.rc scan in next boot |
| 4 | What are camera_ps's GTT surface addresses? | Maybe | P0 deep-inspect in next boot |
| 5 | Does GMM_ALLOC rtn=−2 have a fixable parameter? | Probably not | Try type=1/2, flags=1 |

---

## Summary Table — What Works, What Doesn't

| Operation | Result | Notes |
|-----------|--------|-------|
| Boot hook fires | ✅ rc=0 | Every boot since deploy |
| V4L2 REQBUFS/STREAMON | ✅ r=0 | 3 buffers, GTT offsets captured |
| IGD_ALTER_OVL2 plane=5 | ✅ r=0 rtn=0 | Sprite C configured |
| IGD_ALTER_OVL2 plane=3 | ✅ r=0 rtn=0 | Primary overlay configured |
| DRM_SET_MASTER (root) | ✅ r=0 | No kill required |
| V2G_DISABLE | ✅ r=0 | Always works |
| V2G_ENABLE (any struct) | ❌ IOH DMA count=0 | `enable_direct_display_tnc()` −22 — architectural gate |
| IGD_GMM_ALLOC | ❌ rtn=−2 | EMGD internal error; not blocking |
| Nav system stability | ✅ | No crashes since emgdhmid kill removed |
| V2G_DISPLAY_FRAME(0/1/2) | 🔄 next boot | May prime IOH DMA buffer count |
| YUYV pixel write + ALTER_OVL2 | 🔄 next boot | Alt display path if V2G stays blocked |
