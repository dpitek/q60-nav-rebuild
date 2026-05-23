# Q60 Nav Rebuild — Hardware Research Log (2026-05-15 → 2026-05-23)

> Live research log — findings from direct hardware testing on a 2017 Infiniti Q60
> Clarion QY5092 DCU. Goal: paint arbitrary content onto the Sprite C overlay plane
> using the factory V2G bridge, without disrupting the nav system.

**Platform:** Wind River Linux 2.6.37 · i386 Atom E6xx (Tunnel Creek) · Intel EMGD 1.5.15.3226  
**Capture IC:** LAPIS ML7213 IOH · ioh_vin V4L2 driver  
**Init system:** `/sbin/init android` (Android init — uses `init.rc`, NOT systemd or SysV init.d)  
**Test method:** musl-static i386 binary deployed via `debugfs` to SD card, launched at boot
via patched `android-mount.sh`.

---

## Finding 1 — Boot Hook Pipeline: Confirmed Working

**What:** `android-mount.sh` (on Slot A ext4, patched via `debugfs`) runs as root on every
boot, before any display or navigation process starts. It launches our test binary
`/opt/q60r1/v4l2_test` with a 3-second delay after mount.

**Confirmed by:** `/boot/Q60_HOOK_RAN.TXT` written with pre-launch timestamp.
Binary exits rc=0, runtime ~7 seconds, logs flushed to `/boot/`.

**Why it matters:** Non-destructive code injection without reflashing or JTAG. We have an
unconditional root execution primitive on every boot.

**What it enables:** Iterative on-device testing. Same pipeline will carry the production
R1 client once the display path is solved.

---

## Finding 2 — V4L2 / IOH-GTT Buffers: Confirmed with Exact Offsets

**What:** `/dev/video0` (ioh_vin) allocates 3 GTT-mapped capture buffers via REQBUFS.

| Buffer | GTT offset   | Size     |
|--------|-------------|----------|
| 0      | `0x000000`  | 953,472 B |
| 1      | `0x0e9000`  | 953,472 B |
| 2      | `0x1d2000`  | 953,472 B |

Format: 800×480 YUYV, pitch=1600. STREAMON r=0. Buffers remain live across all test phases.
`g_buf[0]` (mmap'd from QUERYBUF) is directly writable — pixel data placed there can
potentially be shown via ALTER_OVL2 if IOH GTT ≡ EMGD GTT address space.

**Why it matters:** These are the GPU-side addresses of the IOH capture ring — the exact
buffers the DENSO V2G bridge routes to Sprite C. They're also the fallback surface for
ALTER_OVL2-based direct rendering.

---

## Finding 3 — IGD_ALTER_OVL2: Works, No DRM Master Required

**What:** `IGD_ALTER_OVL2` (`0xc0c8646f`) returns r=0, rtn=0 for plane=5 (Sprite C) and
plane=3 (primary overlay) — as a non-master DRM client.

This ioctl is `DRM_AUTH` not `DRM_MASTER` per EMGD source comment:
> "so that libva wayland can call alter\_ovl without going through X server"

**Why it matters:** Overlay plane geometry, surface address, pixel format, and enable flag
can be set without contending for DRM master. **This is the primary alt path to Sprite C**
if V2G_ENABLE remains blocked.

**What it enables:** Sprite C configuration at will. If the V4L2 GTT addresses are in
EMGD's GTT space, writing YUYV pixels to `g_buf[0]` then calling ALTER_OVL2 with
`surf_off=0x000000` would paint directly to Sprite C.

---

## Finding 4 — DRM_SET_MASTER: Succeeds as Root, No Process Kill Needed

**What:** `DRM_SET_MASTER` returns r=0 as root while `emgdhmid` (pid varies) is running.
The kernel grants master to root forcibly.

**Why it matters:** Earlier approach killed `emgdhmid` — this crashed `display_ps`,
`navi_ps`, and `hmictrl_proc` (all hold DRM fds, crash when master is revoked).
Root SET_MASTER avoids that entirely. **Never kill emgdhmid.**

---

## Finding 5 — Valid EMGD Overlay Planes

**What:** Kernel messages during V2G_ENABLE sweeps reveal which planes the driver accepts:

| Plane | Identity         | Valid |
|-------|-----------------|-------|
| 3     | Primary overlay  | ✅    |
| 5     | Sprite C         | ✅    |
| 0,1,2,4,6,7,8 | —      | ❌    |

EMGD portorder: `portorder = 2,4,0,0,0` — port 2 = LVDS (main 7" display), port 4 = SDVO.
The V2G_ENABLE "screen" field takes the EMGD port number (2 or 4), not a 0-based index.

---

## Finding 6 — V2G_ENABLE: Struct Layout Confirmed from Kernel Messages

**What:** `V2G_ENABLE_BRIDGE` = `0xc0047600` = `_IOWR('v', 0, 4)`. Takes a pointer.

The kernel messages during sweeps directly revealed the struct layout:
```
v2g: Enable Sprite C Bridge on screen 0   ← plane=5 was in s[0], screen=0 was in s[1]
v2g: Enable Overlay Bridge on screen 2    ← confirms {uint32_t plane, uint32_t screen}
```

**Confirmed struct:** `{ uint32_t plane, uint32_t screen }` — **8 bytes total**.
The driver reads 8 bytes via internal `copy_from_user` even though the cmd encodes 4.

`V2G_DISABLE_BRIDGE` = `0xc0047601` — always r=0. ✅

| Argument type       | errno         | Meaning                                     |
|---------------------|--------------|---------------------------------------------|
| Direct integer      | 14 (EFAULT)  | Kernel dereferences as pointer              |
| Pointer to struct   | 22 (EINVAL)  | Kernel reads struct; `enable_direct_display_tnc()` rejects content |

---

## Finding 7 — V2G Root Blocker: IOH DMA Buffer Count = 0

**What:** `enable_direct_display_tnc() returned -22!` is always accompanied by:
```
v2g: GTT mapping requested for 0 buffers:
```

The V2G bridge checks the IOH DMA engine's active GTT buffer count **before** configuring
Sprite C. This count stays 0 even after V4L2 REQBUFS + STREAMON unless:
1. A real camera signal is present (car in reverse), OR
2. `V2G_DISPLAY_FRAME` is called first to register the buffers

**Why it matters:** This is the hard architectural gate. V2G_ENABLE is not a configuration
call — it's a bridge-activation call that requires the IOH DMA engine to have active frames.

**V2G_DISPLAY_FRAME** = `0xc0047602` = `_IOWR('v', 2, 4)`. Takes a buffer index (0, 1, or 2).
Discovered when the F-sweep (cmd sweep) triggered `v2g_display_frame()`. The theory:
calling DISPLAY_FRAME(0/1/2) registers each buffer with the bridge, incrementing the count
that `enable_direct_display_tnc()` checks. **Next boot tests this.**

---

## Finding 8 — camera_ps is the V2G Bridge Manager (Not emgdhmid)

**What:** Deep process inspection revealed that `camera_ps` (pid varies) — not `emgdhmid` —
is the factory process that manages the V2G bridge for the rearview camera. `emgdhmid`
only holds DRM master; it does not interact with `/dev/v2gbridge` during normal operation.

**Why it matters:** Our understanding of the factory flow was wrong. `camera_ps` is the
process to study for understanding how production V2G_ENABLE calls succeed (with live
camera DMA). Its fd table and GTT surface addresses are captured in P0 survey.

---

## Finding 9 — emgdhmid Call Signature (from Disassembly)

**What:** `emgdhmid` calls:
```c
ioctl(fd_v2gbridge, 0xc0047600, ptr)
// *ptr = { uint16_t=1, uint16_t=1 } = uint32_t 0x00010001
```

This matches our confirmed layout as `{ plane=1, screen=1 }` — both fields are 1.
(plane=1 is invalid per kernel messages; this call in emgdhmid context apparently works
due to camera_ps having already primed the DMA engine.)

---

## Finding 10 — Slow Boot: 75-Second Android Init Delay

**What:**
```
pid=273   /bin/usleep 75000000   (75 seconds)
State: S (sleeping)
PPid: 1   (init launched it directly)
```
`init (pid=1) cmdline=[/sbin/init android]` — **Android init**, not systemd.

The 75s sleep is spawned directly by Android init. It is **NOT** in:
- `/etc/init.d/` or `/etc/rc.d/` (scanned, only 500ms sleeps found there)
- `/etc/systemd/system/` (init is not systemd)

**Source:** An Android init.rc file — `/init.rc`, `/system/init.rc`, or `/etc/init/*.rc`.
**Next boot** adds init.rc scan to identify exact source.

**Impact:** ~70-second reduction in boot time once patched. Not a hardware constraint.

---

## Finding 11 — android-mount.sh Double-Invocation: Identified and Fixed

**What:** Prior deploys injected both a `>>Q60_HOOK_START/END<<` marked block AND a legacy
`nohup v4l2_test &` line outside the markers. The strip regex only matched the markers,
leaving the nohup block. Result: binary launched twice per boot.

**Fix:** Deploy script now reads from Slot B (factory-clean mmcblk0p3) as base, then
applies multiple `re.sub` patterns stripping all legacy artifacts before injecting fresh hook.

---

## Finding 12 — Binary Delivery Infrastructure: Reproducible from macOS

| Component     | Detail                                              |
|---------------|-----------------------------------------------------|
| Build         | `docker --platform linux/386 alpine`, `gcc -static -no-pie -O2` |
| Post-process  | `objcopy --remove-section=.note.ABI-tag --strip-all` |
| Binary size   | ~115–120 KB                                          |
| Deploy        | `debugfs` from `e2fsprogs` (Homebrew) — pure additive ext4 write |
| Target        | Slot A `/dev/disk12s2` (Slot B = factory reference) |
| Boot log      | `/boot/Q60_R1_V4L2.LOG`, `Q60_KMSG.LOG`, `Q60_HOOK_RAN.TXT` |
| Kernel kmsg   | `syslog(SYSLOG_ACTION_READ_ALL)` syscall (NR=103, i386 2.6.37) |

No cross-compiler, no JTAG, no reflash. Deploy cycle: build → `sudo bash deploy-thorough.sh` → eject card → boot → read logs. End-to-end under 5 minutes.

---

## Current Status

| Operation                  | Result          |
|----------------------------|-----------------|
| Boot hook fires            | ✅ every boot   |
| V4L2 REQBUFS + STREAMON    | ✅ 3 buffers    |
| IGD_ALTER_OVL2 plane=5     | ✅ r=0 rtn=0    |
| IGD_ALTER_OVL2 plane=3     | ✅ r=0 rtn=0    |
| DRM_SET_MASTER (root)      | ✅ r=0          |
| V2G_DISABLE                | ✅ r=0          |
| Nav system stability       | ✅ no crashes   |
| V2G_ENABLE (any struct)    | ❌ IOH DMA count=0 |
| IGD_GMM_ALLOC              | ❌ rtn=−2       |
| V2G_DISPLAY_FRAME(0,1,2)   | 🔄 next boot    |
| YUYV pixel write → ALTER   | 🔄 next boot    |
| init.rc 75s source         | 🔄 next boot    |

**Two open tracks:**
1. **V2G path** — V2G_DISPLAY_FRAME may prime the IOH DMA count → unblock V2G_ENABLE
2. **Direct ALTER_OVL2** — write YUYV pixels to mmap'd V4L2 buf[0], call ALTER_OVL2 with GTT offset 0x000000. Bypasses V2G_ENABLE entirely if IOH GTT = EMGD GTT address space.

---

*See also: `docs/plan-r1-v2gbridge-research.md` (architecture), `docs/r1-privilege-findings.md` (DRM ioctl permissions), `docs/v2gbridge-hardware-findings-2026-05-17.md` (full detail)*

---

## Architecture Pivot (2026-05-22)

After the R1 overlay research sprint, the approach changed: instead of painting over the
factory nav via V2G, we're **replacing the factory nav entirely** with Linux 4.19 + Qt6 +
Weston. The R1 findings above remain valid hardware facts and will inform Phase 2+.

**Phase plan:**
| Phase | Goal | State |
|---|---|---|
| 1 | gma500 display gate — does mainline claim LVDS on Crossville Lapis? | 🔄 |
| 2 | Qt6 + Weston rendering on real hardware | ⏳ |
| 3 | Navigation services (Valhalla, geocoder, map tiles) | ⏳ |
| 4 | CAN integration + production polish | ⏳ |

---

## Finding 13 — Phase 1 First Car Boot: Two Black Screens (2026-05-23)

**What:** First boot of the Phase 1 diagnostic image resulted in both LVDS displays staying
black. No Phase 1 logs written to `/boot/` (no `Q60_DISPLAY_GATE.TXT`, `Q60_DIAG_STAGES.LOG`,
etc.).

**Diagnosis:**

| Clue | Interpretation |
|---|---|
| `elilo.conf` still shows `default=q60nav` | rcS never ran — it restores `default=logan1` as its first action after mounting /boot |
| No Phase 1 logs on SD card | init never started on the 4.19 kernel |
| `vmlinuz-4.19-q60` present (3.1 MB, May 22) | Kernel was on the card; elilo loaded it |
| disk4s3 = no ext4 label | No partition had `q60diag` label → kernel couldn't mount root → immediate panic |

**Root causes (both fixed):**

1. **Rootfs never deployed** — `deploy-phase1-sd.sh` defaults to `disk6`; card was at `disk4`.
   disk4s3 still had old factory Linux content with no `q60diag` ext4 label. The kernel
   attempted `root=LABEL=q60diag`, found nothing, panicked before init.

2. **Deploy script UPDATE path stripped root=** — The Python UPDATE path replaced the entire
   `append=` line with a version that omitted `root=LABEL=q60diag`. If run as-is after the
   above was fixed, next boot would also fail (no root device).

**Fix:** Added `root=LABEL=q60diag` to `new_append` in `scripts/deploy-phase1-sd.sh` (line 149).

**Next:** `sudo bash scripts/deploy-phase1-sd.sh -y disk4` → car boot → read Phase 1 logs.

**Why it matters:** First real hardware test of the Linux 4.19 + gma500 path. When it works,
`Q60_DISPLAY_GATE.TXT` will show `PASS` (gma500 bound, /dev/fb0 present) or `FAIL/PARTIAL`
with DRM state details. Either result unblocks Phase 2 planning.

---

## Finding 14 — v14 Consolidated Rebuild (2026-05-23)

**What:** Second Phase 1 car boot also produced two black screens with zero markers on /boot.
Diagnosis revealed THREE independent bugs that all needed to be fixed simultaneously:

| # | Bug | Root cause | Fix |
|---|---|---|---|
| 1 | Wrong kernel actually loading | UEFI removable-media fallback loads `/EFI/BOOT/BOOTIA32.EFI`, deploy script only wrote `vmlinuz-4.19-q60` + `elilo.conf` — neither used. Old May 18 v13 kernel had been booting all along. | Deploy script now also writes kernel to `BOOTIA32.EFI` |
| 2 | Three of five v13 boot fixes missing from May 22 pivot kernel | Architecture-pivot kernel config regen lost: LAPIS SDHCI vendor entries, `X86_PAE`+`HIGHMEM64G`, `PHYSICAL_ALIGN=0x1000000` | All re-applied in v14 config; LAPIS patch back in `sdhci-pci-core.c`; build script reconstructed at `scripts/build-kernel.sh` |
| 3 | `root=LABEL=q60diag` doesn't work in 4.19 without initrd | Mainline 4.19 `name_to_dev_t` only handles PARTUUID/PARTLABEL/device-path — no LABEL= lookup | Embedded cmdline now `root=/dev/mmcblk0p3`; elilo.conf updated to match |

**Additional bugs found during QEMU validation (would have caused silent rcS failure even on
fixed hardware):**

| Bug | Effect | Fix |
|---|---|---|
| rcS used `mountpoint -q` — not compiled into this busybox | Every mount-success check silently failed → rcS thought all mounts failed → no /boot logs written even when mount worked | Replaced with `grep -q ' /boot ' /proc/mounts` (portable) |
| rcS Stage 0 mounted pstore before sysfs was up | Side-effect interaction | Moved to Stage 1.5 after sysfs mount |
| rcS only wrote BOOT_STAGE markers at Stage 11 — atomic | If rcS hung partway, ZERO evidence on SD card | New `stage_marker()` writes `/boot/BOOT_STAGE_NN.TXT` at every stage, syncing after each |

**Emulator validation (Phases 3–4 PASS):**
- QEMU happy-path boot: all 11 BOOT_STAGE markers landed; `Q60_DISPLAY_GATE.TXT` = FAIL (correct
  — no GMA600 in QEMU); failsafe `elilo.conf default=logan1` restore confirmed
- QEMU `--no-root` test: kernel panic + reboot loop, 0 markers — reproduces today's car
  failure mode exactly, proving the new diagnostic mechanism catches this

**v14 artifacts:**
- `output/bzImage-4.19-q60` — 3.30 MB, sha256 `b00f1545...`
- `output/q60-diag-rootfs-phase1.img` — 512 MB ext4 q60diag, rcS sha256 `e253298d...`
- `scripts/build-kernel.sh` — NEW, reproducible builds
- `scripts/qemu-prep-disk.sh`, `qemu-boot-test.sh`, `qemu-deploy-dryrun.sh` — NEW emulator harness
- `scripts/patch-rootfs-rcS.sh` — NEW, in-place rcS injection
- `scripts/deploy-phase1-sd.sh` — fixed: writes BOOTIA32.EFI; no more hardcoded disk6 default

**Critical lesson re-confirmed:** all bugs were present today; fixing them one at a time would
have produced identical black-screen symptoms across multiple boots. Parallel debugging in
QEMU (60-second iteration cycles vs car's 2-3 minute cycles) is what made this tractable.

**Next:** `sudo bash scripts/deploy-phase1-sd.sh -y disk4` → car boot → read Phase 1 logs.
v14 should produce either `PASS`, `PARTIAL`, or `FAIL` with rich diagnostic detail — never
again "no markers at all."

---

## Finding 15 — v15 RCA: MOVBE compiler bug (2026-05-23)

**What:** v14 was about to deploy with `CONFIG_MATOM=y` in the kernel config.
gcc-11 with `-march=atom` freely emits the **MOVBE** instruction
(Move-with-Byte-swap, Atom 2008+). **Atom E6xx "Bonnell" — model 0x26 — does NOT
have MOVBE.** Every emitted MOVBE is an illegal opcode that triple-faults the CPU
at kernel decompress. v14's vmlinux contained **1174 MOVBE instruction sites** —
this kernel could not boot on the Q60.

**Why we missed it for the v14 deploy:** the May 22 architecture pivot regenerated
the kernel config from scratch and re-enabled `CONFIG_MATOM=y`. The earlier memory
finding [`project_atom_e6xx_cpu_compat.md`](../.claude/projects/-Users-dpitek-Developer-q60-rebuild/memory/project_atom_e6xx_cpu_compat.md)
explicitly warned about this — it was lost in the regen and not caught by the
build sanity checks.

**Why QEMU validation didn't catch it:** QEMU's `-cpu n270` (Bonnell-ish) is
configured to support MOVBE (modern QEMU emulates all common Atom features).
The MOVBE-laden v14 kernel booted fine in QEMU while it would have triple-faulted
on the real Q60. **This is the hard limit of emulator-based validation for this
target — different ISA support between QEMU's "n270" and real E6xx silicon.**

**v15 fixes (all four together):**

| Fix | Where |
|---|---|
| `# CONFIG_MATOM is not set` + `CONFIG_M686=y` | `configs/q60_kernel.config:228,247` |
| `KCFLAGS="-mno-movbe -march=i686 -mtune=i686"` | `scripts/build-kernel.sh` Docker invocation |
| Post-build objdump check (must be 0 MOVBE) | `scripts/build-kernel.sh` STEP 4 sanity gate |
| Added `MATOM` to REQUIRED_N list, `M686` to REQUIRED_Y list | `scripts/build-kernel.sh` |

**Result:** v15 vmlinux has **0 MOVBE** instructions (560 CMOVBE — Conditional MOVe
if Below or Equal, Pentium Pro 1995-era, perfectly legal on Bonnell). sha256
`fd94dea1b1f86d30a74dbae46f36ae1ea6894b41d352153a872feb52f8444690`.

**Other v15 adjustments surfaced by comprehensive audit:**
- Added `lpj=1296800` to embedded cmdline (factory pre-calibrated loops-per-jiffy)
- Added `printk.devkmsg=on` (let userspace see all kernel messages)

## Maximum-diagnostic rcS (v15)

The Phase 1 init script now produces ~200 files per boot, all on the FAT32 /boot
partition (macOS-readable). Doug's directive: leave no diagnostic ignored.

**Per-stage markers (`/boot/BOOT_STAGE_*.TXT`):** S1 → S17, written + fsync'd after
each stage so a hang at stage N leaves all N-1 markers behind as forensic evidence.

**Forensic dumps (`/boot/diag/`):**

| Subdir | Contents |
|---|---|
| `proc/` | 26 `/proc/*` snapshots — cmdline, cpuinfo, iomem, ioports, interrupts, modules, filesystems, partitions, devices, fb, mounts, version, swaps, dma, loadavg, buddyinfo, zoneinfo, vmstat, misc, stat, locks, diskstats, cgroups, kallsyms-head, config (if `CONFIG_IKCONFIG_PROC=y`) |
| `pci/` | Every PCI device's full config space (256-byte hex), driver binding, BARs, IRQ, vendor/device/class/subsystem IDs, modalias, uevent. Plus `_SUMMARY.txt` in compact lspci-style format. |
| `drm/` | DRM/framebuffer state, EDID hex dump per connector, gma500 binding detail, dmesg lines filtered for `gma500\|psb\|oaktrail\|4108\|GMA600\|LVDS\|drm\|fb0\|framebuffer\|emgd\|i915\|efifb` |
| `block/` | Block device enumeration + per-partition size/start/uevent |
| `mmc/` | MMC host controllers — every sysfs attribute. Plus `_sdhci_pci_bound.txt` showing which devices bound to the sdhci-pci driver (validates LAPIS patch worked) |
| `cpu/` | CPU topology, cpuidle states, MTRR/microcode/loops-per-jiffy from dmesg |
| `watchdog/` | All watchdog device state |
| `dmesg/` | Pre-DRM, post-DRM, final, and sysrq-triggered dumps |
| `pstore/` | Prior-boot panic captures (ramoops, dmesg-ramoops). READ FIRST if non-empty |

**R1 baseline check** (`/boot/diag/_R1_BASELINE_CHECK.txt`): rcS compares actual PCI
device enumeration against the expected set from R1's factory 2.6.37 boot logs:

| BDF | Expected | Meaning |
|---|---|---|
| 00:00.0 | 8086:4114 | Tunnel Creek host bridge |
| 00:02.0 | 8086:4108 | GMA 600 graphics |
| 00:17.0 | 8086:8184 | PCIe bridge → bus 01-02 |
| 01:00.0 | 10db:8019 | PLX/LAPIS PCIe bridge |
| 02:04.0 | 10db:801e | LAPIS SDHCI #0 (SD card) — REQUIRES OUR sdhci-pci-core.c PATCH |
| 02:04.1 | 10db:801f | LAPIS SDHCI #1 |
| 02:04.2 | 10db:8020 | LAPIS SDHCI #2 (eMMC) |
| 02:0a.1 | 10db:8027 | LAPIS PCH UART (ttyPCH0) |

A `✓` next to each = present + driver bound; `✗` = missing entirely; `?` = present
but unexpected IDs. This tells us in one file whether the v15 kernel sees all
expected hardware.

## Lesson confirmed

**QEMU is not a hardware validation tool for this target.** It can catch:
- Shell bugs in rcS
- Missing/wrong kernel cmdline arguments
- Marker/failsafe mechanism correctness
- Build-script bugs

It cannot catch:
- ISA mismatches (MOVBE was the killer; QEMU's n270 hides it)
- LAPIS SDHCI binding
- GMA600 LVDS modeset
- EKI v2.30 EFI quirks
- Tunnel Creek MTRR/MWAIT quirks

Going forward: use comprehensive research + memory files + R1 baseline + diagnostic
boot for hardware decisions. Use QEMU only as a script-bug filter before a car boot.

**v15 artifacts:** `bzImage-4.19-q60` sha `fd94dea1...` · 3.28 MB · 0 MOVBE.
`rootfs/etc/init.d/rcS` sha `b6ec3ca5...` · 504 lines · 17 stages.
