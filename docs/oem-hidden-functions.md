# Q60 — OEM Hidden / Secret Menus & Functions (Factory DCU)

Catalog of dealer-mode and diagnostic screens unlocked **from the factory
InTouch touchscreen** on the 2014–2019 Q50 / 2017–2019 Q60 (Clarion DCU +
DENSO GENIVI Linux + Android subsystem, per
[InTouch RE thread](https://www.infinitiq50.org/threads/intouch-reverse-engineering-findings-more-to-come.137236/)).
CONSULT-III-plus / J2534-only procedures (BCM Work Support, DCU
reconfiguration, FOTA seed) are flagged where they overlap but are out of
scope.

**Why:** (1) sanity-check factory firmware before flashing slot B, (2) map
each hidden screen to its CAN frame signatures during the J2534 capture
([`hardware-day-capture-checklist.md`](./hardware-day-capture-checklist.md)),
(3) decide what our replacement clones vs. drops.

> **Brick warning.** Three items can hose the DCU to the point only
> CONSULT-III-plus recovers it: **Configuration Reset**, **Reset All
> Settings**, any **Configuration Table** write. Symptom: no clock /
> no audio / no drive mode. Do not touch on the factory unit unless a
> CONSULT-capable shop is on call.
> [Source 1](https://www.infinitiq50.org/threads/factory-reset-in-self-diagnostic-menu.132084/) ·
> [Source 2](https://www.infinitiqx30.org/threads/beware-dcu-factory-reset-problem.26410/)

---

## 1. Master access sequence — InTouch Diagnostic Mode

Single entry point. Every hidden screen lives behind this gate.

| Step | Action |
|---|---|
| 1 | Engine running, transmission in P, audio system **OFF** |
| 2 | Tap **Settings** icon on upper screen |
| 3 | Press steering-wheel / dash **Seek-Up (Track-Up) ▲** physical button **3× within 15s** |
| 4 | On upper screen, press-and-hold for **~3 sec** in the area **just below the right-side page-scroll arrow (`▶`)**. Some users report a slow downward swipe from under the `▶` arrow works more reliably |
| 5 | Diagnostic root menu appears |

Sources: [Q50 diagnostics megathread](https://www.infinitiq50.org/threads/q50-diagnostics-mode.6601/) ·
[Disabling ASC](https://www.infinitiq50.org/threads/disabling-asc-more-than-just-fake-exhaust.102561/) ·
[Q60 fake-exhaust](https://www.infinitiq60.org/threads/how-to-turn-off-fake-exhaust.5657/) ·
[YouTube walkthrough](https://www.youtube.com/watch?v=PE1dPmBPkg4)

**Year variation:** 2020+ (Gen 2 InTouch) uses **Audio**-hold + **Tune** knob
L–R–L (≥7 clicks each); Gen 1 sequence above also still reported working on
some 2020 units. Not our car, included only so YouTube cross-references
don't confuse the capture day.
[Source](https://www.infinitiq50.org/threads/2020-q50-sport-how-do-you-access-system-diagnostics-to-turn-off-active-noise-control.130194/)

---

## 2. Diagnostic root menu — tabs

Aggregated from [Q50](https://www.infinitiq50.org/threads/q50-diagnostics-mode.6601/),
[Q50 Pt 2](https://www.infinitiq50.org/threads/q50-diag-mode-part-2.7025/),
[Q30](https://www.infinitiq30.org/threads/diagnostic-mode-menu.25962/) (same Clarion DCU family):

- **Confirmation / Adjustment** — active tests + tweakable settings
- **Self Diagnosis** — DTC viewer for AV-bus / InTouch subsystems
- **Cause Analysis** — failure-history logs (read-only)
- **Service** — Configuration Reset gateway (DANGER)
- **Vehicle Signal** — live CAN-derived signal monitor
- **Version Info** — software / hardware / map versions

---

## 3. Confirmation / Adjustment — itemized

This is the safe sandbox. Most items are read-only display tests or
reversible toggles.

| Item | What it does | Risk |
|---|---|---|
| **Display Test** | Color bar / grayscale / white / black full-screen | Safe |
| **Touch Panel Test** | Visualizes touch events live (click/drag/pinch). Does NOT recalibrate — calibration is a factory-jig procedure. | Safe |
| **Touch Screen Sensitivity** | 1 (default) → 5 | Reversible |
| **Speaker Test** | Test tone to each speaker individually (LF/RF/LR/RR/center/sub/door) — verifies amp + Bose channel map | Safe |
| **Microphone Sensitivity** | Low / Med (default) / High | Reversible |
| **Camera Test** | Rear view (overlay-grid toggle) + Around-View Monitor (if equipped) | Safe |
| **ANC On/Off** (Bose only) | Active Noise Cancellation — kills the Bose AudioPilot cancellation signal | Reversible |
| **ASC On/Off** (Bose only) | Active Sound Control — kills the synthesized engine note ("fake exhaust"). The reason most owners open this menu. | Reversible |
| **Route Simulation** | OFF by default; nav engine simulates a fake route | Safe |
| **Sirius/XM Test** | Forces tuner to known freq, displays SNR / lock | Safe |
| **Button Test** | Steering-wheel / dash hard buttons report-up check | Safe |

> ANC/ASC controls are Bose-only; non-Bose trims see the page greyed out.
> [Source](https://www.infinitiq50.org/threads/dont-have-anc-asc.135932/)

---

## 4. Self Diagnosis tab

Read-only DTC viewer for AV-COMM, BCM-link, Combination-Meter-link,
Bluetooth, USB hub, Tuner, Mic, Camera, GPS, Map-DB. Per-module clearing
from this tab is UNVERIFIED (forum posts disagree).

## 5. Cause Analysis tab

Timestamped event log of past failures. UNVERIFIED across years —
single-source screenshots only.
[Source](https://www.infinitiq50.org/threads/q50-diagnostics-mode.6601/)

## 6. Service tab — DANGER ZONE

| Item | What | Risk |
|---|---|---|
| **Configuration Reset** | Wipes DCU's vehicle config table | **BRICK** — CONSULT recovery only. No clock / no audio / no drive mode. [Source 1](https://www.infinitiq50.org/threads/factory-reset-in-self-diagnostic-menu.132084/) · [Source 2](https://www.infinitiq50.org/threads/q-50-diagnostic-mode-factory-reset-issue.61353/) |
| **Reset All Settings** | Wipes user prefs | Reversible but tedious |
| **DCU Reboot** | Soft restart | Safe |
| **HDD/eMMC health** | Read-only if present (UNVERIFIED on V37) | Safe |

---

## 7. Vehicle Signal tab — **highest-value page for capture day**

Live monitor; each row = a CAN-derived signal the DCU has subscribed to.
Confirmed rows:

Vehicle Speed · Parking Brake · Reverse · Illumination · Ignition Position
(ACC/ON/START) · Steering Angle · Engine RPM · Fuel Level · Outside Temp ·
VIN. [Source](https://www.infinitiq50.org/threads/q50-diagnostics-mode.6601/page-3)

When a row updates on-screen, the DCU has just decoded a frame on M-CAN
or AV-CAN. See Section 11.

## 8. Version Info tab

Read-only strings the dealer cross-refs to ITB / FOTA bulletins:
Work Instruction Code · Part Number (matches DCU rear-sticker) · Software
Code (e.g. P4248-ITGEN5 2.0) · EEPROM · Hardware · PCB · Circuit Check ·
Color Check · Map DB Version · Build Date. Same 9-display cycle pattern as
the combination-meter trip-reset self-diag.
[Source](https://www.infiniti-qatar.com/ownership/guides/faqs/vehicle-personalization/topic2-q5.html)

## 9. CONSULT-only — boundary callout

NOT in the touchscreen menu; don't waste capture-day time looking:

- BCM Work Support (auto-lock, headlight delay, welcome-light) — TSBs
  ITB17-016, ITB18-077, [ITB19-002b](https://static.nhtsa.gov/odi/tsbs/2020/MC-10171213-0001.pdf)
- DCU Configuration write (Configuration-Reset recovery)
- DAS / IPDM-E / Combination Meter Work Support
- FOTA seed / map activation key

CONSULT path: **Diagnosis (One System) → MULTI AV → ECU Identification /
Work Support**.

---

## 10. Cross-Clarion sequences worth a 5-min try (UNVERIFIED on V37)

Q50/Q60 DCU shares Clarion lineage with Murano R52 / Pathfinder R52 /
Titan / Ariya. Try, label `(UNVERIFIED-on-V37)`, low risk:

- Audio OFF → hold **Setting** + rotate volume CW 40+ clicks (Murano/Pathfinder pattern). [Source](https://forums.nicoclub.com/super-secret-service-menu-t437628.html)
- Audio OFF → hold **Menu** + rotate volume L/R/L ≥7 clicks each (Titan). [Source](https://www.titantalk.com/threads/2019-or-2020-radio-secret-menu-service-menu.430364/)
- Audio OFF → tap upper-right corner ×5 (Ariya Android-style dev menu). [Source](https://www.ariyaforums.com/threads/hidden-menu-how-to-enter-the-diagnostics-menu-in-the-infotainment.1402/)

---

## 11. How to use this during hardware day

J2534 + on-device candump per
[`hardware-day-capture-checklist.md`](./hardware-day-capture-checklist.md).
For each run: mark timestamp **before**, do the thing, mark **after**;
diff between marks isolates the frame signature.

### Capture order (safest → most-touchy; never enter Service tab)

1. **Baseline idle** (60s, key on, audio off, no diag entry)
2. **Entry sequence** — confirms unit is alive; no CAN expected
3. **Vehicle Signal page (60s)** — every CAN ID we must *receive* fires here. **Single highest-value capture.**
4. **Version Info page** — UDS ECU-identification reads to peer modules; gives us the service IDs + sub-functions to replay
5. **Display Test** — should be DCU-local; confirm zero CAN downstream dependency
6. **Touch Panel Test** — DCU-local; confirm
7. **Speaker Test** — each tap → Bose amp on AV-CAN; capture every channel for the full channel-map
8. **Camera Test** — RVC + AVM enable frames on M-CAN; we need these to drive the camera switch from our build
9. **ANC/ASC toggles** (Bose only) — both directions; only documented control path for synth-exhaust
10. **Mic / Touch sensitivity** — likely DCU-local config writes; confirms we don't need to replicate
11. **Button Test** — every steering-wheel button; reveals LIN→CAN gateway frame format
12. **Sirius/XM test** — tuner CAN frames; skip if non-XM
13. **Route Simulation ON, then OFF** — GPS/nav frames if any
14. **Camera grid overlay toggle** — quick sanity
15. **Self-Diagnosis tab open** — UDS DTC reads; expect `0x19 02 09` (read DTC by status mask) pattern
16. **STOP. Do NOT open the Service tab.**

### Per-run log format

```text
run_id:        03-vehicle-signal
duration_s:    62
new_ids_seen:  [CAN IDs not in baseline]
freq_per_id:   [Hz per new ID]
sample_frame:  [first 8-byte payload per new ID]
notes:         [on-screen signal name ↔ frame ID guess]
```

Slots into `tools/can-frame-catalog/` (TBD); becomes the receive-side
decoder table for our replacement firmware.

---

## 12. Replicate vs. drop in our replacement

**Drop:**
- ASC/ANC toggles — we don't run synth-exhaust. If the Bose amp stays, we
  send a static "ASC off" frame at boot, no UI.
- Sirius/XM test — XM tuner is gone.
- Configuration Reset / Reset All Settings — our config is versioned files;
  recovery is `git checkout` + reflash, not CONSULT. Whole danger tab gone.

**Clone (as a debug/service page in our build):**
- Vehicle Signal live monitor · Speaker test · Camera test · Touch Panel
  test · Display test · Version Info (slot A/B + map-DB) · Button Test

---

## Sources

- [Q50 Diagnostics Mode megathread](https://www.infinitiq50.org/threads/q50-diagnostics-mode.6601/) ([page 3](https://www.infinitiq50.org/threads/q50-diagnostics-mode.6601/page-3))
- [Q50 Diag Mode Part 2](https://www.infinitiq50.org/threads/q50-diag-mode-part-2.7025/) · [Secret Menu](https://www.infinitiq50.org/threads/secret-menu.140962/)
- [Disabling ASC](https://www.infinitiq50.org/threads/disabling-asc-more-than-just-fake-exhaust.102561/) · [Q60 fake-exhaust](https://www.infinitiq60.org/threads/how-to-turn-off-fake-exhaust.5657/)
- [Factory-reset bricks](https://www.infinitiq50.org/threads/factory-reset-in-self-diagnostic-menu.132084/) · [Q50 factory-reset issue](https://www.infinitiq50.org/threads/q-50-diagnostic-mode-factory-reset-issue.61353/) · [QX30 same DCU](https://www.infinitiqx30.org/threads/beware-dcu-factory-reset-problem.26410/)
- [Q30 Diagnostic Mode (most detailed screenshots)](https://www.infinitiq30.org/threads/diagnostic-mode-menu.25962/)
- [InTouch Reverse Engineering Findings](https://www.infinitiq50.org/threads/intouch-reverse-engineering-findings-more-to-come.137236/) · [DCU Repair Megathread](https://www.infinitiq50.org/threads/2014-2019-dcu-repair-megathread.140924/)
- [No ANC/ASC on non-Bose](https://www.infinitiq50.org/threads/dont-have-anc-asc.135932/) · [2020 Gen-2 diag access](https://www.infinitiq50.org/threads/2020-q50-sport-how-do-you-access-system-diagnostics-to-turn-off-active-noise-control.130194/)
- [Infiniti Qatar Self-Diagnosis FAQ](https://www.infiniti-qatar.com/ownership/guides/faqs/vehicle-personalization/topic2-q5.html) · [FreshInfiniti walkthrough](http://www.freshinfiniti.com/infiniti-q50-intouch-self-diagnostics/)
- YouTube: [Secret Self-Diag Menu](https://www.youtube.com/watch?v=hZ44RZX0nWU) · [Q50/Q60/QX30/QX50 Self-Diag](https://www.youtube.com/watch?v=PE1dPmBPkg4) · [Shutting off ASC 2020+](https://www.youtube.com/watch?v=EZ_l5dOfzEo) · [Fake Exhaust how-to](https://www.youtube.com/watch?v=9MEY_MkIRBA)
- [ITB19-002b DCU service info (NHTSA PDF)](https://static.nhtsa.gov/odi/tsbs/2020/MC-10171213-0001.pdf)
- Cross-Clarion: [Nicoclub](https://forums.nicoclub.com/super-secret-service-menu-t437628.html) · [Titan](https://www.titantalk.com/threads/2019-or-2020-radio-secret-menu-service-menu.430364/) · [Murano](https://www.nissanmurano.org/threads/secret-diagnostic-menu.190097/) · [Ariya](https://www.ariyaforums.com/threads/hidden-menu-how-to-enter-the-diagnostics-menu-in-the-infotainment.1402/) · [Pathfinder](https://www.pathfindertalk.com/threads/pathfinder-secret-menu-service-menu.35617/)
- [DCUFix — V37 DIY DCU repair](https://dcufix.com/)
