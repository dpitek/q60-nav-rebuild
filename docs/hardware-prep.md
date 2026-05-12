# Q60 Nav Rebuild — Hardware Preparation & First Boot

**Target:** 2017 Infiniti Q60 DCU (Clarion QY5092, Intel Atom E6xx i386, eMMC storage)
**Audience:** You built the software. This is everything between that and a working first boot.

---

## Section 1: Prerequisites

### Software Build Checklist

Confirm all of these before touching hardware (see [`STATUS.md`](../STATUS.md)):

- [ ] `output/bzImage-4.19-q60` — 4.2MB ELF 32-bit i386 kernel
- [ ] `output/q60nav-rootfs.img` — 3GB ext4 rootfs image (1.3GB used)
- [ ] `output/app-build/bin/q60nav` — 199KB ELF 32-bit app binary (inside rootfs)
- [ ] `output/valhalla-tiles/` — 312 routing tile files (~717MB, inside rootfs)
- [ ] `output/vector-tiles/nc.mbtiles` — 464MB vector tiles (inside rootfs)
- [ ] elilo.conf entry verified: `q60nav` entry present, `default=logan1`

**Not required for first boot** (graceful degradation):
- Photon geocoder data (`scripts/download-photon.sh`) — `SearchService` degrades gracefully if absent
- MapLibre EGL wiring (Phase 3) — stub renders placeholder until EGL pbuffer is implemented
- Bose wake ID (`CAN_BOSE_WAKE = 0x3B3`) — placeholder; won't kill the app

### Hardware Required

| Item | Purpose |
|---|---|
| USB-SATA/eMMC adapter (compatible with eMMC chip pinout) | Read/write DCU storage from Mac |
| J2534 PassThru device (e.g., Drew Technologies MongoosePro, Actia XS Evolution) | CAN bus capture and injection |
| OBD-II cable | J2534 to car |
| UART USB adapter, **3.3V logic** (e.g., FTDI FT232RL breakout) | GPS probe, serial console fallback |
| Trim tools, T10/T20 Torx bits | DCU removal |

### Software / Tools on Mac

- `diskutil` (built-in) — identify eMMC partitions
- `dd` (built-in) — raw partition write
- `./scripts/deploy-to-image.sh` — orchestrates all write operations
- J2534 software: [OpenJ2534](https://github.com/openobd/j2534) or manufacturer PassThru app
  - Alternative: [socketcand](https://github.com/linux-can/socketcand) + `candump` if using a SocketCAN-capable adapter (e.g., CANable)
- Serial: `screen /dev/tty.usbserial-XXXX 115200` for UART probe

---

## Section 2: eMMC Flash Procedure

### Step 1 — Remove the DCU from the car

The Q60 DCU lives in the center console stack, behind the infotainment display.

1. Disconnect negative battery terminal. Wait 60 seconds (capacitor discharge).
2. Remove center console upper trim panel (two T20 screws under the cupholder lift tray, two T10 behind the shift surround).
3. Disconnect the display panel connector before pulling the trim fully free.
4. The DCU is a metal box bolted behind the display — two T20 bolts on each side.
5. Disconnect the main wiring harness (one large multi-pin connector, one antenna coax) and the GPS antenna cable.
6. Remove the unit. The eMMC chip or module is on the main PCB — consult the service manual for your specific DCU revision for exact location and adapter pinout.

> **Note:** The eMMC is likely a BGA-soldered NAND chip or a socketed module (varies by DCU revision). If socketed, it can be removed without soldering. If BGA, you'll need a clip-on adapter or a rework station. Identify before committing.

### Step 2 — Identify the eMMC via `diskutil list`

Connect the eMMC to your Mac via the USB adapter. Then:

```bash
diskutil list
```

Look for a disk with:
- Size: ~4–8GB total
- Partition scheme: Linux-style (no Apple_HFS or APFS)
- Multiple Linux partitions, one FAT32

Expected layout (from `docs/boot-safety.md`):

| Partition | Type | Size | Contents |
|---|---|---|---|
| p1 | FAT32 | ~127MB | Boot: elilo.efi, elilo.conf, kernels |
| p2 | Linux | ~3GB | **Slot A — factory logan1 root (NEVER WRITE)** |
| p3 | Linux | ~3GB | Slot B — q60nav root (write target) |
| p5 | Linux | — | Slot A android root (NEVER WRITE) |
| p6 | Linux | — | Slot B android root |
| p7 | Linux | ~50MB | pmemdisk shared mem |
| p8 | Linux | ~3GB | Nav app partition |
| p9 | Linux | ~1GB | User data |

> The disk will appear as `/dev/diskN`. Slot B root is `/dev/diskNs3`. The FAT32 boot partition will auto-mount as `/Volumes/boot 1` (or similar).

### Step 3 — Mount the FAT32 boot partition

macOS should auto-mount it. Verify:

```bash
ls /Volumes/
```

You should see `boot 1` (or `boot`). If not:

```bash
diskutil mount /dev/diskNs1
```

### Step 4 — Run the deploy script (safe mode — no `--test` yet)

```bash
# Set SLOT_B_DEV to your actual slot B partition device
SLOT_B_DEV=/dev/disk4s3 ./scripts/deploy-to-image.sh
```

What this does:
1. Writes `output/bzImage-4.19-q60` → `/Volumes/boot 1/vmlinuz-4.19-q60`
2. Adds the `q60nav` entry to `/Volumes/boot 1/elilo.conf` (if not already present)
3. **Keeps `default=logan1`** — the car will still boot factory on next power-on
4. Writes `output/q60nav-rootfs.img` to `/dev/rdiskNs3` (raw device, faster) via `dd`

> The rootfs write will take several minutes. Do not unplug the adapter.

If the FAT32 volume isn't at `/Volumes/boot 1`, override:

```bash
BOOT_VOL="/Volumes/yourname" SLOT_B_DEV=/dev/disk4s3 ./scripts/deploy-to-image.sh
```

### Step 5 — Verify the written image

```bash
./scripts/deploy-to-image.sh --verify
```

This mounts the rootfs image in Docker (read-only) and confirms:
- `/opt/nav/bin/q60nav` present
- `/opt/valhalla/bin/` present
- Routing tiles and vector tiles present
- Qt6 libs present
- Disk usage within expected range

Fix any missing items before continuing.

### Step 6 — Eject safely

```bash
diskutil eject /dev/diskN
```

Wait for the LED on the USB adapter to stop (if it has one). Do not yank.

---

## Section 3: First Boot (Safe Mode — factory logan1)

At this point, `elilo.conf` still says `default=logan1`. Reinstall the DCU and power on normally.

**Goal of this boot:** Confirm the DCU survived the procedure and that slot A is untouched.

1. Reconnect all harness connectors and antenna cables. Reconnect the battery.
2. Turn the ignition to ACC.
3. Factory nav system should start normally — same as before.
4. Verify that the infotainment display, HVAC controls, and backup camera all operate normally.
5. If anything is wrong at this stage, the issue is physical (connector not seated, etc.) — nothing was written to slot A.

**Optional: Check boot counter file**

If you have serial console access (Section 6 UART probe), you can verify `/boot/q60_boot_attempts` does not exist at this point (it shouldn't — it's only created by `start.sh` when q60nav boots).

---

## Section 4: First Q60nav Boot (`--test` flag)

> **Read the boot counter logic below before proceeding.** Know the recovery path before you flip the switch.

### Step 1 — Re-remove DCU and flip elilo.conf

With the eMMC re-connected to your Mac:

```bash
./scripts/deploy-to-image.sh --test
```

This runs the same deploy as before (re-writes kernel and rootfs) and then:

```bash
sed -i '' 's/^default=.*/default=q60nav/' /Volumes/boot\ 1/elilo.conf
```

Confirm the change:

```bash
grep "^default=" /Volumes/boot\ 1/elilo.conf
# Expected: default=q60nav
```

Eject and reinstall the DCU.

### Step 2 — Power on

Turn ignition to ACC. The boot sequence is:

1. elilo reads `elilo.conf` → boots `vmlinuz-4.19-q60` with `root=/dev/mmcblk0p3`
2. Kernel hands off to SysV init → runs `rcS`, udev, kernel modules
3. Init scripts run in order: `S10-gpsd` → `S20-valhalla` → `S25-photon` → `S30-weston` → `S50-q60nav`
4. `S50-q60nav` calls `/opt/nav/start.sh`, which:
   - Increments `/boot/q60_boot_attempts`
   - Arms the iTCO hardware watchdog (30s timeout)
   - Brings up `can0` (500kbps), `can1` (500kbps), `can2` (250kbps)
   - Starts DENSO proxy daemons (SXM, radio, sound, vCAN)
   - Waits up to 10s for Wayland compositor socket (`/run/wayland-0`)
   - On success: clears boot counter and execs `/opt/nav/bin/q60nav`

### Step 3 — What to expect on screen

- `S30-weston` launches `gen-weston-ini.sh`, which probes `/sys/class/drm/card*-*` for connected connectors, writes `/etc/xdg/weston/weston.ini`, then starts Weston
- Weston compositor starts (brief black screen is normal)
- `q60nav` opens the `ControlHubView` as the default screen with the nav system in the background

### Step 4 — If the boot fails

**Boot counter auto-revert logic** (from `start.sh`):

```
/boot/q60_boot_attempts  (on FAT32 p1 — readable from Mac)

  count = 0 → first attempt, write count=1, continue booting
  count = 1 → second attempt, write count=2, continue booting
  count >= 2 → REVERT: set elilo.conf default=logan1, delete counter, reboot
```

The counter is incremented early in `start.sh`, before any services start. It is only cleared if `q60nav` successfully reaches `exec`. This means:

- A kernel panic, init crash, Weston failure, or app crash before `exec` all count as failed boots
- After **2 consecutive failures**, the system auto-reverts to `logan1` and reboots into factory nav — no intervention needed
- The boot counter file is on FAT32 (`/boot/q60_boot_attempts`) — you can read/delete it from the Mac via USB adapter

**If you see the factory nav come back on its own:** That's the auto-revert working. Inspect `/var/log/nav.log` (on the ext4 slot B partition via USB adapter) to see where it failed.

### Step 5 — Manual recovery

If the system is stuck and you want to force factory nav without waiting for 2 boot cycles:

```bash
# With eMMC mounted on Mac
./scripts/deploy-to-image.sh --restore
```

This is equivalent to:

```bash
sed -i '' 's/^default=.*/default=logan1/' /Volumes/boot\ 1/elilo.conf
```

Eject and power cycle. Done.

---

## Section 5: J2534 CAN Verification

### CAN ID Confidence Table

| Frame | ID | Confidence | Notes |
|---|---|---|---|
| Steering angle | 0x002 | CONFIRMED | opendbc nissan_common, carhack 370Z |
| Steering torque | 0x185 | CONFIRMED | opendbc nissan_common |
| RPM | 0x1F9 | CONFIRMED | carhack 370Z, Leaf AZE0 |
| Speed | 0x280 | CONFIRMED | carhack 370Z, Leaf AZE0 |
| Wheel speeds (front) | 0x284 | CONFIRMED | Leaf AZE0, nissan_xterra |
| Wheel speeds (rear) | 0x285 | CONFIRMED | Leaf AZE0, nissan_common |
| Brake / TCS | 0x354 | CONFIRMED | nissan_xterra, X-Trail |
| Gear selector | 0x421 | CONFIRMED | carhack 370Z, Leaf AZE0 |
| Outside temp | 0x510 | CONFIRMED | Leaf AZE0 VCM_HMI_GeneralData2 |
| HVAC status read | 0x54A, 0x54B | CONFIRMED read | Leaf AZE0 DBC |
| HVAC write (temp/mode) | 0x540 | Q50_LIKELY write | r51-ecu (R51 Pathfinder, same Denso amp) |
| HVAC write (fan) | 0x541 | Q50_LIKELY write | r51-ecu |
| Odometer / P-brake | 0x5C5 | CONFIRMED | Leaf AZE0 |
| BCM status | 0x60D | CONFIRMED | carhack 370Z, Leaf AZE0 |
| Seat heat write | 0x625 | UNVERIFIED | Leaf AZE0 (read path only confirmed) |
| AV buttons (SW + panel) | 0x681 | Q50_LIKELY | Leaf AV-CAN DBC |
| Bose amp wake | 0x3B3 | UNVERIFIED | Placeholder — sniff required |
| Bose volume | 0x3B4 | UNVERIFIED | Placeholder — sniff required |

**Buses:**
- `can0` — HS-CAN, 500kbps (powertrain, BCM, HVAC)
- `can1` — AV-CAN, 500kbps isolated (Bose, SXM, steering wheel buttons)
- `can2` — TBD, likely MS-CAN 125kbps body bus

### Setup

1. Connect J2534 device to OBD-II port (under dash, driver's side)
2. Connect J2534 USB/Ethernet to laptop
3. Turn ignition to ACC (engine off is fine for most read IDs)
4. Open J2534 software and connect to **HS-CAN, 500kbps** (ISO 15765-4 or raw CAN)

Software options:
- Manufacturer PassThru app (varies by J2534 device)
- [python-j2534](https://github.com/Chadys/j2534-python) for scripted capture
- [socketcand](https://github.com/linux-can/socketcand) bridge if using CANable/PEAK adapter (exposes SocketCAN interface on Mac via TCP)

### HVAC Write Path Verification (0x540 / 0x541)

Priority: High. Do not enable HVAC writes from q60nav until confirmed.

**Procedure:**

1. Connect J2534 to OBD-II, start logging on HS-CAN (500kbps), filter for 0x540 and 0x541
2. Turn ignition to ACC
3. Use the factory HVAC controls: adjust driver zone temp up, then down
4. Observe frames on 0x540. Expected byte layout (from r51-ecu / VehicleService.h):

```
0x540 — Climate command frame
  byte 0: mode flags
    bit 0 = system on (1=on)
    bit 1 = A/C compressor
    bit 2 = recirculation
    bits 3-4 = airflow mode (0=face, 1=feet, 2=blend, 3=defrost)
    bit 5 = auto mode
    bit 6 = dual-zone
  byte 1: driver zone temp raw  (raw = tempC * 9/5 + 73)
  byte 2: passenger zone temp raw
  bytes 3-7: 0x00
```

5. Adjust fan speed. Observe 0x541:

```
0x541 — Fan speed frame
  byte 0 bits[0:2]: fan speed 0-7
  byte 0 bit 7: manual fan override
  bytes 1-7: 0x00
```

6. Compare captured frames against the byte layout above. If the bit positions match, the r51-ecu source is valid for the Q60 and HVAC writes can be enabled.

7. Test the initialization sequence: the A/C Auto Amp expects three 0x540 frames with `byte0=0x00` at 100ms intervals before accepting commands. Confirm it ACKs with 0x54A after the init.

**If the byte layout differs:** Update `VehicleService.cpp` — `hvacTempRaw()`, `hvacModeFlags()`, and `sendFanFrame()`. Do not merge HVAC writes until verified.

### Bose Wake Sniff Procedure

The `CAN_BOSE_WAKE = 0x3B3` is a placeholder and must not be used for writes until confirmed.

1. Locate the Bose amplifier in the trunk (multi-pin green connector on the amp body)
2. Tap the AV-CAN wire at the amp connector — you need a non-destructive tap (poke probe or dedicated T-tap)
3. Connect the tap to a second J2534 channel (or a separate SocketCAN adapter) running at 500kbps
4. Turn ignition to ACC. Note all frames transmitted on AV-CAN
5. Turn audio on and off — look for a frame that appears when audio activates and disappears when it's off
6. Cross-reference against `can1` (`CAN_AV_BTNS = 0x681`) traffic to correlate timing
7. The wake frame is expected near 0x3B3–0x3B5 range — confirm the exact ID and byte pattern before updating `VehicleService.h`

---

## Section 6: GPS UART Probe

The DCU has a GPS antenna input. The receiver is most likely connected to a UART on the Atom SoC.

### Default assumption

`S10-gpsd` configures GPSD on `/dev/ttyS0` at the default baud rate. Verify this before relying on it.

### Probe procedure

Connect your 3.3V UART adapter to the DCU's UART header (check the PCB — there's typically a debug/GPS UART header near the GPS antenna connector). **Do not use 5V logic on this board.**

With the DCU powered on and booted into the new rootfs:

```bash
# Try common baud rates for NMEA GPS receivers
cat /dev/ttyS0   # standard baud
```

If you have terminal access, try each baud rate in `screen`:

```bash
screen /dev/tty.usbserial-XXXX 4800
screen /dev/tty.usbserial-XXXX 9600
screen /dev/tty.usbserial-XXXX 38400
screen /dev/tty.usbserial-XXXX 115200
```

Look for NMEA sentences:

```
$GPRMC,123519,A,4807.038,N,01131.000,E,022.4,084.4,230394,003.1,W*6A
$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*47
```

If you see NMEA: record the device path and baud rate.

### Update gpsd init script if needed

If the GPS is on a different device than `/dev/ttyS0`:

```bash
# Edit rootfs/etc/init.d/S10-gpsd
# Change the device and baud rate arguments to gpsd
```

Re-run `scripts/package-rootfs.sh` and re-flash.

### If no NMEA on any ttyS device

Check whether the GPS receiver is USB-connected:

```bash
# On the running DCU (via serial console or SSH if configured)
lsusb
dmesg | grep -i gps
dmesg | grep -i serial
dmesg | grep ttyACM
```

A USB GPS will appear as `/dev/ttyACM0` or `/dev/ttyUSB0`. Update `S10-gpsd` accordingly.

Also check I2C — some embedded GPS modules use I2C:

```bash
i2cdetect -y 0
i2cdetect -y 1
```

---

## Section 7: Display / Weston Verification

### What happens at boot

`S30-weston` calls `gen-weston-ini.sh` before starting Weston. That script:
1. Scans `/sys/class/drm/card*-*` for connectors with `status == connected`
2. Writes `/etc/xdg/weston/weston.ini` with the detected connector name
3. Falls back to `LVDS-1` if nothing is detected

### Where to check

After boot (via serial console or by reading logs via USB adapter):

```bash
cat /var/log/weston.log
dmesg | grep drm
dmesg | grep -i connector
```

The DRM driver for the Atom E6xx integrated graphics is `gma500` or `poulsbo`. Look for lines like:

```
[drm] connector 0: LVDS-1
[drm] connector 1: HDMI-A-1
```

And in `weston.log`:

```
[weston] Using connector: LVDS-1
```

### If the display doesn't come up

1. Check `dmesg | grep drm` for driver init errors
2. Check `/var/log/weston.log` for compositor errors
3. `S30-weston` falls back to `fbdev` if Weston fails — look for the fallback message in `/var/log/nav.log`
4. If fbdev fallback kicks in, `q60nav` sets `QT_QPA_PLATFORM=linuxfb` — the app will render but with no compositor

### Manual weston.ini override

If `gen-weston-ini.sh` detects the wrong connector:

```bash
# Mount the slot B rootfs via USB adapter
# Edit /etc/xdg/weston/weston.ini directly
# Replace the connector name with the correct one from dmesg
```

Or re-flash after updating `rootfs/etc/xdg/weston/weston.ini.default` (the static fallback).

---

## Section 8: Emergency Recovery

### Scenario 1: Stuck in boot loop, waiting for auto-revert

Do nothing. After 2 failed boots, `start.sh` writes `default=logan1` to `elilo.conf` and reboots. Factory nav comes back automatically. Boot counter logic is on FAT32 — resilient to rootfs corruption.

### Scenario 2: Force immediate recovery from Mac

```bash
# With eMMC mounted via USB adapter
./scripts/deploy-to-image.sh --restore
```

This edits `elilo.conf` in-place:

```bash
sed -i '' 's/^default=.*/default=logan1/' /Volumes/boot\ 1/elilo.conf
```

Eject, reinstall, power on. Back to factory nav in under 5 minutes.

Also clear the boot counter if present:

```bash
rm -f /Volumes/boot\ 1/q60_boot_attempts
```

### Scenario 3: DCU won't mount via USB adapter

If the eMMC adapter fails to enumerate:

1. Try a different USB port (some hubs drop power)
2. Check `diskutil list` — the disk may appear but with no partitions if the partition table is corrupt
3. If the boot partition (p1, FAT32) is unreadable, use `testdisk` to recover it — the partition layout is documented in `docs/boot-safety.md`

For a completely unresponsive chip (bad solder joint, etc.), JTAG is the last resort:

- The Atom E6xx JTAG header is typically a 10-pin or 20-pin ARM/Intel standard header on the PCB
- Use a JTAG debugger (Lauterbach, J-Link, or OpenOCD-compatible) to connect directly to the SoC
- At minimum, serial console (UART) access may allow recovery without full JTAG

### Scenario 4: Need to read logs off a failed boot

The slot B rootfs (`/dev/mmcblk0p3`) is ext4. On Mac, you can't mount ext4 natively, but:

```bash
# Use Docker
docker run --rm --privileged \
  -v /dev/disk4s3:/dev/disk4s3 \
  ubuntu:22.04 \
  bash -c "mkdir /mnt/slotb && mount /dev/disk4s3 /mnt/slotb && cat /mnt/slotb/var/log/nav.log"
```

Key log files to check:

| File | Contents |
|---|---|
| `/var/log/nav.log` | `start.sh` output, boot counter state, service startup |
| `/var/log/weston.log` | Weston compositor init, connector detection |
| `/var/log/syslog` | Kernel + init messages (if syslogd is running) |

### Permanent safety net

**Slot A (`mmcblk0p2`) is never written.** `deploy-to-image.sh` never touches p2 or p5. As long as the boot partition's `logan1` entry is intact (and it is — the deploy script only modifies `default=`, not the entry itself), factory nav is always recoverable.

---

*Last updated: 2026-05-12 — based on STATUS.md, deploy-to-image.sh, start.sh, VehicleService.h, docs/boot-safety.md*
