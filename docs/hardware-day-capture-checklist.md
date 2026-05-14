# Q60 — Hardware Day J2534 Capture Checklist

Single-session capture plan that unblocks every currently-gated feature.
**Bring:** J2534 adapter (Tactrix OpenPort 2.0 or PassThru), laptop with candump
or SocketCAN bridge, factory DCU (live, not flashed), USB-A→USB-C, OBD2 splitter,
notepad.

**Pre-condition:** Q60 in factory firmware (slot A). DO NOT flash slot B until
this session completes.

## Companion docs
- [`oem-hidden-functions.md`](./oem-hidden-functions.md) — OEM diagnostic /
  service / engineering menus reachable from the factory touchscreen. Each
  hidden screen fires unique CAN frames — capture them alongside the J2534
  plan below. Section 11 of that doc has the exact walkthrough order.

## Quick fact-confirmation tasks (do these first — 30 seconds each)

Before any write captures, run these once-and-done reads from a TTL/USB
shell on the live DCU. They resolve every research-flagged UNVERIFIED
item in STATUS.md (RAM count, display connector names, GPS UART path,
CAN driver, etc.) in under a minute:

```sh
cat /proc/meminfo  | head -5            # RAM (resolves 1GB-vs-2GB DDR2 question)
cat /proc/cpuinfo  | grep -E "model|MHz"
ls /sys/class/drm/                       # LVDS / DSI connector names
ls /dev/tty*                             # GPS UART (ttyPCH0..3 vs ttyS0)
ls /sys/class/net/                       # CAN buses (can0/can1/can2 if present)
dmesg | grep -iE "can|watchdog|memory|usable"  # driver load + watchdog model
```

Save each to a text file and `scp` to your laptop — these become the
ground truth that overrides every "LIKELY"/"UNVERIFIED" label in the repo.

---

## On-device capture (belt + suspenders)

The DCU rootfs includes `/etc/init.d/S05-capture-bootstrap` which can run
`candump` on all 3 buses in parallel, writing to `/data/q60nav/captures/`.
Disabled by default. To enable for the capture session:

```sh
# From a console (USB-UART) or SSH on the DCU:
/etc/init.d/S05-capture-bootstrap enable
reboot
# After capture session:
/etc/init.d/S05-capture-bootstrap disable
# Pull logs off via USB stick / file copy:
cp /data/q60nav/captures/*.log /mnt/usb/
```

Logs are rotated automatically — last 8 sessions kept. The on-device dump is
useful as a backstop if the J2534 capture misses a frame, but the J2534-side
captures remain the source of truth (richer metadata, no risk of disk-full).

---

## 0. Session bootstrap (15 min)

| # | Action | Recording | Notes |
|---|---|---|---|
| 0.1 | Connect OBD2 → J2534, splitter to keep DCU active | — | Ignition ACC |
| 0.2 | `candump -L can0,can1,can2 > /tmp/capture-baseline.log &` | All three buses 60s idle | Identifies idle traffic baseline |
| 0.3 | Note VIN, build date, firmware version from factory Info screen | snapshot | Audit trail |
| 0.4 | Confirm laptop sees ALL three buses: V-CAN (can0), C-CAN (can1), AV-CAN (can2) | bus list | If any missing, stop — check wiring |

---

## 1. CAN ID verification — read-path confirmations (20 min)

Already flagged as Q50_LIKELY; capture confirms one-by-one. Filter `candump` to the
target ID, then trigger the action and watch for the expected change.

| # | Target | ID | Bus | Trigger | Expected delta |
|---|---|---|---|---|---|
| 1.1 | Ignition state | 0x292 | C-CAN | OFF → ACC → IGN → CRANK | byte0 bits 0-2 step |
| 1.2 | Door open | 0x358 | C-CAN | Open/close each of 4 doors + trunk | byte0 bits 0-4 toggle per door |
| 1.3 | Wiper state | 0x35D | C-CAN | Off → slow → fast → one-shot | byte2 0→1→2→3 |
| 1.4 | Key slot | 0x35B | C-CAN | Insert/remove key (both fobs) | byte changes per fob |
| 1.5 | TPMS per-corner | 0x385 | C-CAN | Sit 10 min, log natural pressure variance | 4 bytes for 4 tires |
| 1.6 | Cruise + coolant | 0x551 | C-CAN | Engage cruise, vary coolant | byte0 cruise bits, byte6 coolant 0.5°C/LSB-40 |
| 1.7 | Oil life | 0x54C | C-CAN | Static read | 0.0–100.0 % |
| 1.8 | Drive mode broadcast | 0x266 | C-CAN | Cycle all 6 factory modes | Active mode byte |
| 1.9 | ATTESA torque split | 0x1CA | C-CAN | Drive 30s straight, then slight throttle stab | Front/rear % change |
| 1.10 | BCM extended (battery/defrost) | 0x625 | C-CAN | Rear defrost on/off; static voltage | byte1 defrost flag, byte2 V×0.1 |

---

## 2. CAN write-path confirmations — SAFE writes only (30 min)

These need the **factory ECU** to fire the frame. We watch from C-CAN/V-CAN to learn
the format, then replicate.

### 2.1 HVAC writes (0x540 / 0x541)
- **Action**: Turn factory climate dial. Cycle: temp up 1°F, temp down 1°F, fan +1, fan -1, mode AUTO→FACE→FEET→DEFROST, AC on/off, recirc on/off.
- **Capture**: filter `0x540 0x541`. Record byte-by-byte for each step.
- **Validate**: bytes that change correlate with each control change.

### 2.2 Drive mode command (0x2DC)
- **Action**: Press drive-mode select button, cycle Standard → Snow → Eco → Sport → Sport+ → Personal.
- **Capture**: 0x2DC + any responder frames within 100ms.
- **Validate**: each press produces a distinct payload.

### 2.3 BCM door lock (UDS 0x745)
- **Action**: Lock/unlock from interior switch and key fob.
- **Capture**: 0x745 request + 0x74D response. Note service 0x30, DID 0xBF00 payload.
- **Validate**: positive 0x70 response for both lock and unlock.

### 2.4 Bose wake frame
- **Action**: Power cycle infotainment (key on, off, on) with engine off. Listen for amp wake "thunk."
- **Capture**: AV-CAN (can2) immediately preceding the thunk. Look for low-frequency one-shot frame.
- **Tentative target**: 0x3B3 — confirm or replace.

### 2.5 AV-CAN button/joystick IDs
- **Action**: Press every infotainment button (volume, source, joystick 4-way + center, scroll, mode).
- **Capture**: AV-CAN — note IDs 0x681 (known), 0x3F6, 0x4CE (unverified candidates).
- **Validate**: each button maps to a distinct (ID, payload) pair.

### 2.6 ADAS aid frame (0x47D) — read-only this session
- **Action**: Toggle BSW, LDW, FCW one at a time from factory steering wheel button.
- **Capture**: filter 0x47D. Note byte-by-byte changes.
- **DO NOT WRITE YET** — we need to compose the frame and confirm response, second bench day.

---

## 3. Hidden capability captures (45 min)

The "demo first" features. Capture is required before our flagged code can fire writes.

### 3.1 ASC (fake exhaust) toggle — Cool factor 10
- **Action**: Enter factory diagnostic menu: Settings → press SEEK-UP ×3 → press-hold below right scroll arrow ×5s. ASC toggle should appear.
- **Capture**: AV-CAN + V-CAN around the moment of toggle.
- **Target**: BCM/DSP frame — likely AV-CAN. Note ID + payload.
- **Validate**: toggle changes one specific frame.

### 3.2 BCM Work Support unlocks (Cool factor 8 bundle)

For each: trigger via factory menu (where available) OR via CONSULT-III-style probe.
All target the same BCM via UDS 0x720/0x745 service 0x2E (write DID) or 0x31 (routine).

| # | Feature | How to trigger factory-side | Capture filter |
|---|---|---|---|
| 3.2a | Speed-sensitive auto-lock threshold | Factory has no UI — probe BCM service 0x22 DID 0x0DXX range; record reads | 0x745 / 0x74D |
| 3.2b | Mirror tilt-on-reverse angle | BCM Work Support menu via CONSULT-III; service 0x2E DID candidate range 0x0E00–0x0E20 | 0x745 / 0x74D |
| 3.2c | Horn chirp / lock confirmation mode | Long-hold fob lock 5s — factory cycles modes. Capture the BCM ack frame. | 0x745 / 0x74D / 0x60D |
| 3.2d | Welcome lighting choreography | Approach car with fob — observe sequential turn signal LEDs + ambient light wake. Capture BCM broadcasts in 2s window before/after door unlock. | 0x60D / V-CAN |
| 3.2e | DRL behavior matrix | BCM Work Support menu (CONSULT-III); service 0x2E DID 0x0F00 range | 0x745 / 0x74D |
| 3.2f | Auto headlight delay | BCM Work Support menu; service 0x2E DID 0x0E80 range | 0x745 / 0x74D |
| 3.2g | TPMS threshold per-corner | TPMS ECU at 0x731 (UDS); read current thresholds via 0x22 | 0x731 / 0x739 |

### 3.3 Maintenance reminder reset (Cool factor 8)
- **Action**: Use factory button-combo or CONSULT-III routine for each:
  - Oil life reset
  - Tire rotation reminder reset
  - Brake fluid reset
  - Air filter reset
  - Cabin filter reset
- **Capture**: ECM 0x7E0 + BCM 0x745 — UDS service 0x31 routine controls.
- **Validate**: each reset = distinct routine ID (RID) under service 0x31.

### 3.4 Cool factor 9 — DTC read + clear
- **Action**: Use generic OBD2 scanner to read all DTCs, then clear.
- **Capture**: 0x7DF / 0x7E0 / 0x7E8 — UDS service 0x19 (read DTC) + 0x14 (clear DTC).
- **Validate**: full DTC list + clear ack. Record any non-standard ECU response addresses.

### 3.5 Cool factor 9 — Auto-up windows during rain
- **No write capture needed** — uses existing wiper signal 0x35D (1.3) + window position read.
- **Action**: Trigger one-touch UP on each window from factory switch.
- **Capture**: filter window controller — likely BCM 0x60D extended payload. Note byte for window position.

---

## 4. Wrap-up (15 min)

| # | Action |
|---|---|
| 4.1 | `pkill candump` on all buses |
| 4.2 | `tar czf q60-capture-$(date +%Y%m%d).tar.gz /tmp/capture-*.log` |
| 4.3 | Copy capture tarball to Mac via USB stick (`/Volumes/.../q60-captures/`) |
| 4.4 | Save VIN-specific BCM option dump if CONSULT-III access available |
| 4.5 | Restore factory state — verify no rogue writes occurred (compare baseline log) |

---

## Post-capture — what gets unblocked

Once captures are decoded and frame formats committed to `VehicleService`:

1. Flip `SettingsService::setCanVerifiedWrites(true)` per-feature (or global).
2. Update each `Q50_HYPOTHESIZED` flag to `CONFIRMED` in `STATUS.md` CAN table.
3. Rebuild and re-deploy slot B.
4. Bench-test each write on a dev DCU before flashing into live vehicle.

Features unlocked by this single session:
- ASC toggle (live, not just UI)
- Walk-away mirror fold (already shipped UI; gate flips)
- Comfort window close (gate flips)
- One-touch all windows (gate flips)
- Auto-up rain windows (gate flips)
- DTC read + clear (live)
- Speed-sensitive auto-lock (live)
- Mirror tilt-on-reverse (live)
- Horn chirp customization (live)
- Welcome lighting choreography (live)
- DRL behavior matrix (live)
- Auto headlight delay (live)
- Maintenance reminder reset (live, 5 routines)
- TPMS thresholds custom (live)
- ADAS aid composition (second pass — read this session, write next)
- HVAC live writes (gate flips)
- Bose amp wake (gate flips)

---

## Tools / reference

- `candump` from can-utils — `apt install can-utils`
- SocketCAN over J2534 — `slcand` bridge (Tactrix OpenPort path)
- UDS service quick-ref: 0x10 session, 0x14 clear DTC, 0x19 read DTC, 0x22 read DID,
  0x2E write DID, 0x30 input control, 0x31 routine control, 0x3E tester present
- CONSULT-III TSB references: ITB19-002b (BCM Work Support), ITB14-014 (UDS DIDs)
- opendbc / carhack — Q50 / 370Z cross-reference
