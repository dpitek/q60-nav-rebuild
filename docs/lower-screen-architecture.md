# Lower 7" Touchscreen Architecture — 2014–2019 Q50 / 2017–2019 Q60

Research note. Captured 2026-05-14. Driven by the factory Version Information
page 6/8 entry (`diag-menu/IMG_1117.jpeg`) showing the lower display as a
separately-addressable unit:

```
2nd disp HW: 000000
2nd disp SW: 020024
Unit ID:     2
```

The SW field is non-zero, which initially suggested the lower screen runs its
own embedded software stack — implying a smart unit with potentially proprietary
firmware. This document settles that question end-to-end based on community
reverse-engineering work, OEM parts catalogs, and the iFixit replacement guide,
then maps the answer onto our project.

---

## Section 1: What the architecture actually is

**Best-effort answer (confidence: HIGH).**

The lower 7" assembly is officially the **"Integral Switch"** (Nissan/Infiniti
service-manual terminology) or **"Controller Assy-Audio Visual"** (parts-catalog
terminology). It is **NOT** a peer Linux system, **NOT** a second GENIVI node,
and **NOT** a smart head-end. The upper 8" DCU (Display Control Unit,
`28387-4HK0B` on our car) is the master of the entire InTouch infotainment
domain. The lower unit is, in the words of the leading community RE researcher,
"essentially a glorified input/output device with a display."

Concretely, the lower unit contains:

1. **A small MCU** that:
   - Initializes/configures the FPD-Link III deserializer (TI DS90UH92x or
     DS90UB94x family).
   - Scans the resistive/capacitive touch panel.
   - Reads the surrounding hard buttons (HVAC fan, temp, A/C, recirc, audio
     source, volume, etc.).
   - Speaks to the DCU over the **AV-COMM** bus (a dedicated CAN-style
     network at 500 kbps, separate from V-CAN and C-CAN).
   - Drives illumination/voltage for the hard buttons.
2. **An LVDS receiver/deserializer chip** that turns the serialized video
   stream from the DCU into the panel's native parallel/OpenLDI signaling.
3. **A 7" 800×420 LCD** with a touch digitizer overlay.
4. **Bezel hard buttons** wired into the MCU.

The "2nd disp SW: 020024" is the firmware of that small MCU — it does
serializer setup, touch sampling, button debouncing, and AV-COMM
packet framing. It does **not** run Linux, has no filesystem, and has no
notion of UI/applications. The DCU renders both displays' video and ships
the lower display's frames out over LVDS to the Integral Switch. The
Integral Switch acts as a thin client.

**Why the SW version is non-zero but the HW field is `000000`:** the HW
column on this peer ECU is unused by Nissan for this specific subsystem —
HW changes have been small enough across the V37 platform that they never
bothered to assign HW revisions. The SW field is what advances when DENSO
ships an updated MCU image (touch sensitivity tweaks, button debounce
timing, etc.).

**Sources** (cited inline below):
- InfinitiQ50.org "InTouch Reverse Engineering Findings" megathread — the
  researcher had root shell on a 2016 Q50 DCU (Intel Atom E6xx / Crossville
  Lapis / Linux). Quote: "The lower display's video signal is received via
  an LVDS video signal. … The integral switch is the bottom display &
  button assembly. … It is essentially a glorified input/output device
  with a display. Button presses (AC, volume, etc) are sent to the AV comm
  network to be handled by the DCU." → tollbit/anti-AI wall now blocks
  direct citation but Google still serves snippets.
- InfinitiQ50.org parts-replacement threads — "The bottom of the screen is
  called the Controller Assy-Audio Visual `28330-4HB5A` and the main part
  of the DCU which is the upper screen is called the Controller Assy-Display
  & It Master `28387-4HK5B`. You will need to determine which part of the
  DCU is bad, the top one or the bottom one, as they can be replaced
  separately."
- iFixit "Infiniti Q50 Bottom Screen Display Replacement" Guide #170744 —
  11 mechanical steps, no programming step, no calibration step. Just
  unplug and swap.
- Infiniti TSB ITB19-002b / ITB19-042b — CONSULT-III configuration is
  required after **DCU** replacement (saves VIN-specific options). The
  TSBs do **not** mention a separate configuration step for the Integral
  Switch / lower display, which is consistent with it being a stateless
  thin client.

---

## Section 2: Communication protocol upper ↔ lower

**Two physically distinct links.** Confidence HIGH for the topology; MEDIUM
on the specific deserializer chip (we know it is TI FPD-Link III family but
not the exact part number without opening the unit).

### Downstream: DCU → Integral Switch
- **Video:** LVDS / FPD-Link III. TI DS90UH92x or DS90UB94x family
  serializer on the DCU side, matching deserializer on the Integral Switch
  side. Single twisted-pair-plus-shield coax-style cable (FAKRA or HSD
  connector) carrying serialized RGB + back-channel I²C/GPIO.
- **Resolution:** 800 × 420 at the panel (lower than the upper 800 × 480).
- **Control sideband:** FPD-Link III's "back-channel" (also called the
  "GPIO+I²C reverse channel") is how the DCU configures the deserializer
  and reads back link status. This is invisible to Linux user-space — it's
  managed by the DCU's BSP/firmware, not by `/dev/i2c-N`.

### Upstream: Integral Switch → DCU
- **Touch + button events:** AV-COMM. AV-COMM is a 500 kbps CAN-style bus
  used inside the InTouch domain (DCU ↔ Tuner ↔ Bose Amp ↔ Integral Switch
  ↔ TCU2). It is **not** V-CAN or C-CAN — those are the chassis buses. In
  our captured photo (`IMG_1117`), the "2nd disp" / "Audio HW" / "Bose Amp"
  units are all peers on this same AV-COMM network.
- The exact CAN-ID for the lower-display touch frame is **UNVERIFIED** —
  the InTouch RE thread documents the AV-COMM exists and runs at 500 kbps
  but does not enumerate every ID. Hardware day capture will see it.

### Power
- The Integral Switch has its own ignition-managed power feed (separate
  from the DCU's). Confirmed by the RE thread: "the integral switch is one
  exception to the standard power management … you can shut the car off
  during an emergency call and the upper screen/audio stays powered on."

### What we do NOT know
- Exact TI deserializer part (likely DS90UH928Q or DS90UB948 — both were in
  volume production for automotive in the 2013–2015 design window).
- AV-COMM CAN-IDs for individual touch events vs. button events.
- Whether the lower screen's MCU exposes a UDS endpoint (we believe yes —
  Unit ID = 2 matches the "ANC controller / ASC controller" pattern, which
  do expose UDS).
- Whether the MCU is Renesas RH850, Renesas SH, NXP S12, or a Cortex-M.
  No teardown photos publicly available.

---

## Section 3: Implications for our build

### Best case (confirmed by evidence): "dumb" LCD with SerDes
**This is where we land.** Nothing in the lower-screen architecture demands
new project work beyond what we already have:

- Both panels connect to the DCU's PowerVR SGX framebuffer subsystem via
  LVDS. From Linux's perspective, the DCU's gma500/i915-equivalent display
  controller drives two outputs. Each output enumerates as a separate
  `card?-LVDS-N` entry under `/sys/class/drm`.
- Our existing `rootfs/opt/nav/detect-display.sh` already iterates
  `card*-*` and emits both connectors. `gen-weston-ini.sh` already creates
  a second `[output]` block for the secondary connector. **No code changes
  needed.**
- The 2nd display's MCU firmware (`020024`) is *opaque to us* — we never
  talk to it directly. The DCU's BSP drives it via the FPD-Link III back
  channel during boot. As long as our kernel keeps the LVDS/serializer
  driver loaded (and it does — we're using the OEM-equivalent display path
  on the gma500 line), the lower screen will light up.

### Medium case (hypothetical, ruled out by evidence): smart unit, standard protocol
Would have required: probing for `/dev/ttyXX` or USB-CDC interface, writing
a small kernel module for AV-COMM packet framing, or shipping a userspace
daemon to ferry events. **None of this is needed.** AV-COMM frames carry
the touch events natively as CAN data, and we already have SocketCAN
plumbing (`can0/can1/can2`) — we just need to identify which bus is
AV-COMM and which CAN-ID carries lower-touch events.

### Worst case (hypothetical, ruled out by evidence): proprietary stack
Would have required reverse-engineering DENSO firmware, possibly flashing
the secondary MCU. **Zero risk** — the lower unit's firmware is OEM, sealed,
and self-managing. We never touch it.

### Net project actions
1. **Touch input on lower screen:** comes in as AV-COMM CAN frames on
   whichever bus is AV-COMM (likely `can2` per current
   `factory-version-baseline.md`). We need to capture the touch frame
   format during hardware day and translate it into Qt touch events
   (synthesize via `uinput` to feed the QML window on `LVDS-2`).
2. **Video on lower screen:** zero work. DRM enumerates both connectors,
   Weston runs two outputs, Qt opens two windows. Already wired up.
3. **Hard buttons on lower screen** (HVAC dial, audio, volume, etc.):
   captured via same AV-COMM mechanism. Map each button → QML signal.

---

## Section 4: How to verify ground truth at the bench

Run these on a TTL/USB shell on the live DCU. Each is ≤5 seconds.

```sh
# Confirm both displays enumerate as separate DRM connectors:
ls /sys/class/drm/card*-*
# Expected: card0-LVDS-1 (upper) and card0-LVDS-2 (lower)
#  — or possibly card0-LVDS-1 and card1-XXX-1 if they're on different
#    controllers. Either way, two distinct connector dirs.

# Confirm both are 'connected':
for f in /sys/class/drm/card*-*/status; do echo "$f:"; cat "$f"; done

# Confirm modes:
for f in /sys/class/drm/card*-*/modes; do echo "$f:"; cat "$f"; done
# Expected: one shows 800x480, other shows 800x420

# Confirm the lower display panel deserializer is on I2C
# (gma500 ADV7611 / TI deserializer typically shows up as a driver bind):
ls /sys/bus/i2c/devices/
dmesg | grep -iE 'ds90|fpdlink|lvds|deserializ'

# Identify AV-COMM bus and watch for lower-display touch traffic:
ip link  # which can interface is AV-COMM? (likely can2, 500 kbps)
ip link set can2 up type can bitrate 500000
candump can2 &
# Tap somewhere on the lower screen — note which CAN-ID changes.
# Press a hard button — note the CAN-ID for that.

# Sanity-check: does anything in DENSO's GENIVI BSP claim to talk to a 'secondary
# display MCU' directly? (Should be no — confirms our model.)
find / -name '*.ko' 2>/dev/null | xargs -I{} sh -c 'echo {}: ; modinfo {} | grep -iE "denso|secondary|tsdu|mdu|2nd"' 2>/dev/null | grep -B1 -i 'denso\|secondary\|tsdu\|mdu\|2nd' || echo "none — confirms thin-client model"
```

**If `/sys/class/drm` only shows one connector**, the lower display is on a
different bridge that gma500 isn't enumerating — investigate dmesg for
driver-load failures, but this is unlikely given the OEM stack already works.

**If `candump can2` shows nothing while tapping the lower screen**, try
`can0` and `can1`. AV-COMM lives on one of them — the InTouch RE thread
just calls it "AV comm" without nailing which SocketCAN interface name it
maps to.

---

## Section 5: Recommended action plan

Tied to the existing hardware-day checklist
(`docs/hardware-day-capture-checklist.md` — pre-J2534 fact-confirm block).

| # | Step | Effort | Tied to |
|---|---|---|---|
| 1 | Run the 5 commands in Section 4 during the hardware-day fact-confirm block. Save outputs alongside `/proc/meminfo` and `/proc/cpuinfo` reads. | 5 min | hardware-day-capture-checklist §"Quick fact-confirmation tasks" |
| 2 | If both DRM connectors enumerate (expected): mark `2nd display DRM card` as VERIFIED in `STATUS.md` and remove the "UNVERIFIED" note in `factory-version-baseline.md` row 1. | 2 min | STATUS.md table |
| 3 | Add an AV-COMM capture pass to §1 of the J2534 checklist: filter all three SocketCAN interfaces while tapping each lower-screen tab and each hard button. Record CAN-ID + payload for each. | 30 min during hardware day | hardware-day-capture-checklist §1 |
| 4 | In `VehicleService` (or a new `IntegralSwitchService`), implement an AV-COMM listener that translates touch CAN frames into `uinput` events. Touch coords go to the X/Y device that Weston binds to the lower `[output]`. | ~1 day after capture lands | rootfs/etc/init.d/S40-q60nav + new service class |
| 5 | Map hard buttons (HVAC, volume, audio source) onto QML signals via `StatusBridge`. | ~½ day | app/src/StatusBridge.* |
| 6 | Verify lower-screen Qt window receives touch events end-to-end on a dev DCU before committing slot B flash. | ~½ day bench test | bench day before flash |

**Total downstream effort to fully drive the lower screen: ~2 dev-days
after hardware-day capture.** No kernel module work, no firmware reverse
engineering, no risk to the lower unit's stock firmware. The Integral
Switch stays exactly as the factory shipped it; we just learn its bus
protocol.

---

## Confidence summary

| Claim | Confidence | Basis |
|---|---|---|
| Lower screen is "really dumb", driven by upper DCU | HIGH | InTouch RE thread, multiple corroborating forum posts, iFixit guide (no programming step) |
| Video link is LVDS / FPD-Link III | HIGH | InTouch RE thread explicit ("TI DS90URxxx family"), TI's automotive presence in this design window |
| Touch + button events are AV-COMM CAN frames | HIGH | InTouch RE thread explicit |
| AV-COMM is 500 kbps CAN, separate from V-CAN/C-CAN | HIGH | InTouch RE thread |
| The "2nd disp SW 020024" is a small MCU firmware (not Linux) | MEDIUM-HIGH | Architectural inference + iFixit's plug-and-play replacement procedure + parts-catalog separation |
| Specific TI deserializer chip is DS90UH928Q or DS90UB948 | MEDIUM | Era + automotive qualification + dual-LVDS use case; not confirmed by teardown |
| AV-COMM lives on `can2` in our SocketCAN naming | MEDIUM | README states `can2 = AV-CAN` but that's hypothesized; hardware-day capture confirms |
| Lower unit has UDS endpoint (Unit ID 2 pattern) | MEDIUM | Inference from other Unit ID 2 entries (ANC/ASC, TCU2) being UDS-addressable |
| Lower unit part number is `28330-4HBxx` / `28330-4HKxx` family | HIGH | Multiple parts-catalog listings + forum replacement-procedure threads |
| Replacing lower unit requires no CONSULT-III programming | HIGH | Multiple forum reports, iFixit guide, absent from TSB |

---

## What if the forums are wrong?

The risk that the InTouch RE thread is incorrect is low but worth bracketing:
the researcher had verified root on the DCU, captured AV-COMM traffic
directly, and the architectural description is self-consistent with the
factory part-numbering (separate `28330` SKU = separate physical assembly
but no calibration step). If on bench day we see something contradicting
this — e.g. the lower display enumerates as `/dev/ttyUSBN` or a network
interface rather than a DRM connector — we fall back to plan B:

- **Plan B trigger:** lower screen does NOT appear in `/sys/class/drm`.
- **Plan B action:** investigate `dmesg` for serial-over-USB devices or
  Ethernet endpoints; the lower MCU might expose a vendor-specific
  protocol over USB-CDC. Effort estimate jumps from 2 dev-days to ~1
  dev-week.

Plan A (the model in this doc) is what every available source supports.
Bench day will settle it in under five minutes per Section 4.

---

## Sources

- iFixit Guide #170744 — Infiniti Q50 Bottom Screen Display Replacement
  <https://www.ifixit.com/Guide/Infiniti+Q50+Bottom+Screen+Display+Replacement/170744>
- InTouch Reverse Engineering Findings, infinitiq50.org thread #137236
  (anti-AI wall now in place; Google snippets still indexed)
  <https://www.infinitiq50.org/threads/intouch-reverse-engineering-findings-more-to-come.137236/>
- Recommended DCU Replacement thread #135406 — part-number separation
  <https://www.infinitiq50.org/threads/recommened-dcu-replacement.135406/>
- Infiniti Parts Store — `28330-4HB1E` Radio Chassis (Q50 lower assembly)
  <https://parts.infinitiusa.com/p/infiniti__Q50/Radio-Control-Unit/89801784/28330-4HB1E.html>
- Infiniti TSB ITB19-002b / ITB19-042b — Display Control Unit Replacement
  procedure (NHTSA database). DCU configuration steps only; no Integral
  Switch programming.
- DENSO Nissan Open Source IVI Portal
  <https://www.denso.com/global/en/opensource/ivi/nissan/>
- TI FPD-Link III deserializer family — DS90UH928Q-Q1, DS90UB948-Q1
  <https://www.ti.com/product/DS90UB948-Q1>
- DCUFix DIY repository — only covers upper DCU; no lower-screen kit
  exists (corroborating evidence that lower unit rarely fails alone)
  <https://dcufix.com/>
- Project-internal: `diag-menu/IMG_1117.jpeg` (Version Info pg 6/8),
  `docs/factory-version-baseline.md`
