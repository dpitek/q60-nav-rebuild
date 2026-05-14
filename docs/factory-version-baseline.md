# Factory Version Baseline — Doug's 2017 Q60 DCU

Captured 2026-05-14 by walking into the InTouch Diagnostic Mode → Version
Information (8 pages) on the **live factory unit** (slot A, logan1). Source
photos: `diag-menu/IMG_111{1..9}.jpeg` + `IMG_112{0..2}.jpeg`.

This is the **authoritative reference** for what firmware versions the
factory DCU expects on each peer ECU. Use it to:

1. Decode UDS responses we capture during hardware day (responses may vary
   by SW version, so knowing the exact baseline matters).
2. Cross-reference our slot B replacement's behavior against the factory
   when running side-by-side comparisons.
3. Detect if Nissan ever updates a peer ECU's firmware (the version string
   here is the snapshot we built against).

---

## DCU itself

| Field | Value |
|---|---|
| Nissan Part No. | `283874HK0B` |
| Onload Model ID | `103103082760` (also `1031-03082760` in the Phone subscreen) |
| Atom SW Version | `00020904` |
| SH SW Version | `07A2` (Renesas SuperH companion processor for nav functions) |
| Spare Part No. | `5CH2D` |
| Unit ID | 16 |

### OS layer

| Field | Value |
|---|---|
| OS Version | **`97.4002`** (DENSO GENIVI Linux) |
| BIOS SW Version | `030700000200` |
| Data-Is Version | `00005` (InfoStream service data) |
| Data-VRMODEL | `US001` (voice recognition US English models) |
| Data-SPEECH | `US003` (speech synthesis voice data) |
| Data-Sonar | `US002` (sonar/AVM data) |
| Data-Parkassist | `----` (**not loaded — Park Assist hardware likely absent**) |
| Data-Kwidata | `US003` |
| Data-Digitalassist | `00014` |
| Data-IME | `----` (no Input Method Editor data) |
| Data-Mail | `00001` |
| Data-Playlist+DB | `US001` |

### Navigation subsystem

| Field | Value |
|---|---|
| Navi Software Version | `306` |
| Voice Recog Engine | `Ver. 1.10` |
| Voice Synth Engine | `Ver. 1.10` |
| Synth Voice Data | `00010000` |
| Voice Recog Grammar | `00010014` |
| Data Recorder Version | `00006007` |
| **Map Version** | **`15/01/26/01`** — Jan 26 2015 — **11+ years stale** |

### Beacon (Japan-market traffic receiver) — NOT EQUIPPED

| Field | Value |
|---|---|
| Beacon HW Version | `FFFFFF` |
| Beacon SW Version | `FFFFFF` |

→ Our build doesn't reference Beacon. No change.

---

## Peer ECUs on the bus

Each row is a **separate ECU** with its own UDS endpoint. The "Unit ID"
column is what the diag menu reports — distinct from CAN bus addressing
but useful for matching diagnostic queries.

| ECU | HW version | SW version | Unit ID | Bus | Project impact |
|---|---|---|---|---|---|
| **DCU 2nd Display** | `000000` | `020024` | 2 | LVDS+control | **The lower 7" panel has its own MCU.** Probably a SerDes link with a small controller. Our Weston config assumes one DRM card — need to probe ALL `/sys/class/drm/card*`. |
| **DCU Audio (Atom-side)** | `153901` | `100521` | 5 | internal | The DCU's audio subsystem (not the Bose amp). |
| **Bose Amp** | `000048` | `010000` | 1 | AV-CAN | The trunk-mounted amp our `wakeBosse()` targets. Confirms it exists; capture the Bose wake frame at this SW version. |
| **Combination Meter** | `000000` | `041303` | 1 | M-CAN | UDS Read DID responses are tied to this firmware. Capture format here. |
| **TCU2 (telematics)** | `443039` | `473232` | 2 | USB-RNDIS | Telematics modem; confirms `NetworkService.tcuMode` is the right code path. |
| **ANC controller** | (Part `0.0.72`) | `1.0.0` (also reported as `010000`) | 2 | M-CAN, UDS | **Separate ECU, NOT BCM.** 3 mics + tach + door inputs. |
| **ASC controller** | (same controller as ANC) | `010000` | 2 | M-CAN, UDS | **Separate ECU, NOT BCM.** Our "ASC toggle" should target THIS endpoint, not BCM 0x745. |

---

## Vehicle config triple

From the ANC/ASC Diagnosis screen "Show signal input route" page
(IMG_1122):

```
Config Results: CV37, VQ30T, H
```

- **CV37** = V37 chassis, Coupe body (Q60). Confirms platform.
- **VQ30T** = Clarion's internal config tag for "3.0L+ turbo VQ-family
  powertrain". The actual engine in Doug's car is the **VR30DDTT** (3.0L
  twin-turbo V6). Clarion appears to use VQ-family naming as a generic
  bucket for this engine class — not the precise Nissan engine code.
- **H** = High trim (Sport or Red Sport 400)

If we later add a `factoryConfigTriple` Q_PROPERTY to SettingsService, the
value is `"CV37,VQ30T,H"`.

---

## GPS receiver (from Sensor Information screen, IMG_1111)

```
GPS GMT = 26/05/14 12:43:48   Status = 00
HDOP = 6   GDOP = 2   ALMANAC = 1   DIMENSION = 3   (3D fix)
8 sats locked at SNR 20-33
[07]=16:CA, [14]=13:CA — two more in code-acquisition phase
Vgps = 0 (vehicle stationary)
Dgps = 900
```

Implications:
- **GPS is a real UART NMEA receiver** baked into the DCU, not derived
  from CAN. Our `S10-gpsd` probing `/dev/ttyPCH0..3` is the correct path.
- 3D fix achievable on a stationary car — no warm-up issue.
- HDOP 6 is moderate (good = <2, acceptable = 2-5, fair = 5-10) — likely
  because the photo was taken indoors.

---

## What this baseline doesn't tell us

These remain UNVERIFIED — pending shell access via TTL/USB during the
hardware-day J2534 capture session:

- **RAM count** — need `cat /proc/meminfo`
- **CPU exact part / speed** — need `cat /proc/cpuinfo`
- **eMMC partition table** — need `gdisk -l /dev/mmcblk0`
- **Boot Guard fuses** (we believe none; need direct verification)
- **/sys/class/drm/ listing** — to confirm the 2nd display's actual
  DRM card name

---

## Sources

All photos in `diag-menu/` taken from Doug's live factory unit, 2026-05-14.
- `IMG_1111.jpeg` — GPS / Sensor Information
- `IMG_1112.jpeg` — Version Information page 1/8 (DCU base)
- `IMG_1113.jpeg` — Version Information page 2/8 (OS + data)
- `IMG_1114.jpeg` — Version Information page 3/8 (apps data)
- `IMG_1115.jpeg` — Version Information page 4/8 (Navigation)
- `IMG_1116.jpeg` — Version Information page 5/8 (Map + Beacon)
- `IMG_1117.jpeg` — Version Information page 6/8 (Audio + 2nd display)
- `IMG_1118.jpeg` — Version Information page 7/8 (Bose Amp + Meter)
- `IMG_1119.jpeg` — Version Information page 8/8 (TCU2 + ANC/ASC)
- `IMG_1120.jpeg` — Phone subscreen (handsfree volume + mic test)
- `IMG_1121.jpeg` — ANC/ASC Diagnosis page 1 (controller info, live ON/OFF buttons)
- `IMG_1122.jpeg` — ANC/ASC Diagnosis page 2 (signal input route, config triple)
