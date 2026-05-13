# Q60 Nav — Backlog
Last reconciled: 2026-05-13 (post PR #1 merge + backlog execution sprint)

Items not in current scope, ordered by priority. Shipped items have been removed —
see git log for the full history of merged enhancements.

---

## ✅ Recently Shipped (reference — do not re-add)

- ASC toggle (drive mode picker + Audio settings)
- VR30DDTT track display (boost / oil / IAT / knock / ignition / AFR)
- ATTESA live torque split (front/rear pie + 60s sparkline)
- G-meter (G-pad + 0-60 / quarter-mile timer)
- Composite "Track" drive mode preset
- Walk-away auto-fold mirrors
- Comfort window close from key fob (JDM)
- One-touch up/down for all 4 windows
- Auto-up windows during rain (wiper-triggered close)
- DTC read + clear with friendly descriptions
- Speed-sensitive auto-lock (user threshold)
- Mirror tilt-on-reverse (angle + per-side toggle)
- Horn chirp / lock confirmation customization
- Welcome lighting choreography customizer
- DRL behavior matrix (BCM Work Support)
- Auto headlight delay (user slider)
- Maintenance reminder reset (one-tap per item)
- TPMS thresholds customizable for track use
- VehicleSettingsView surfacing all BCM unlocks
- SettingsService persistence (JSON, debounced, atomic writes)
- TripLoggerService (per-cycle GPX)
- ParkingService ("navigate to car")

---

## 🔴 Hardware-gated (block until J2534 bench day)

### CAN ID verification — capture session prerequisites
- AV-CAN 0x3F6 and 0x4CE button IDs — UNVERIFIED, need sniff on AV-CAN connector
- Bose wake frame 0x3B3 — placeholder, sniff at amp connector (trunk)
- HVAC writes 0x540 / 0x541 — Q50_LIKELY (r51-ecu derived); confirm before live writes
- ADAS frame 0x47D — UNVERIFIED write path; confirm composition byte-by-byte
- Drive mode command 0x2DC — Q50_LIKELY write
- BCM door lock 0x745 UDS — Q50_LIKELY write; service 0x30 DID 0xBF00
- Key slot detect 0x35B — UNVERIFIED read
- Bose / DSP frame for ASC toggle — Q50_HYPOTHESIZED ID, capture during diagnostic-menu toggle
- BCM Work Support unlocks (mirror dip, auto-lock threshold, horn chirp, welcome
  lighting, DRL matrix, headlight delay) — all Q50_HYPOTHESIZED; gated behind
  `SettingsService.canVerifiedWrites=false` until capture confirms

### Capture session checklist
See `docs/hardware-day-capture-checklist.md` — every J2534 capture target consolidated
so one bench day unblocks ~20 features.

---

## 🟡 Software-track open

### TCU CAN-based signal strength
- NetworkService TCU mode hardcodes 4 bars (RNDIS gives no signal data)
- Real RSSI in Continental BL28NA003 CAN frames — IDs unknown
- Requires CAN sniff during active LTE session

### MapLibre EGL on Intel GMA 3600
- Current path simulated with Mesa softpipe
- DCU GPU: Intel GMA 3600 (PowerVR SGX545 derivative)
- May require pvr_dri or software fallback — needs hardware test
- `OffscreenBackend::activate()` in `MapLibreItem.cpp` still a stub

---

## 🗺️ Map & POI Coverage Expansion

Out of scope for current sprint — each region is a multi-hour tile-build pipeline.

### SC — South Carolina
- Vector tiles via `build-map-tiles.sh` (OSM PBF source) → ~180MB
- POI extract → append to POINT047.DAT (v3 pipeline)
- Style update: add `mbtiles:///opt/nav/tiles/sc.mbtiles`
- Routing: Valhalla tiles for SC region
- 8–10k POI records expected

### GA — Georgia
- Same pipeline as SC; ~290MB tiles; Atlanta metro routing complexity

### VA — Virginia
- Same pipeline; ~260MB tiles; DC fringe — crop with `vaNorthFence` bbox

### Combined SE region (stretch)
- Single `se.mbtiles` covering NC+SC+GA+VA; ~1.1GB combined; cleaner style config

---

## 🏠 Topsail house — proprietary nav formats

Both high-complexity (no SDK exists for Zenrin nav DAT files); defer until factory
nav is fully replaced or someone reverse-engineers the format.

### HOUSE001 address record — 171 Auger Shell Court
- B-tree, 512-byte pages, ~649 pages
- Would enable factory-nav address search

### RDSTM001 routing graph — Auger Shell Court + Parkman Grant Drive
- Add road nodes/links to routing graph
- Would enable factory-nav turn-by-turn

---

## 🔌 Post-v1.0 — major integrations

### Apple CarPlay / Android Auto (open-source path)
- aasdk + OpenAuto on Qt6/Wayland
- DCU has 2 USB host ports; usbmuxd added to start.sh
- ~2-3 weeks effort; flag when boot test confirms USB enumeration
- Audio routes through existing AudioService ALSA/Bose pipeline

### Bluetooth hotspot connectivity + deferred sync
- DCU has no Wi-Fi or cellular; opportunistic sync when phone hotspot available
- `SyncService` with persisted queue at `/var/lib/q60nav/sync-queue.json`
- Priorities: album art > routing updates > full rootfs (slot B OTA)
- ~1 week effort; SyncService skeleton first, items incrementally

### Other post-v1.0
| Feature | Notes |
|---|---|
| OTA update mechanism | Bluetooth sync above, USB-drive fallback |
| Rear camera integration | Already prototyped; refine guides + low-light tuning |
| SiriusXM passthrough | sxmcgs.out/sxmfc.out proxies running; wire AudioView |
| Speed-limit data | OSM tags in Valhalla tiles; expose via NavigationService |
| Multi-region maps | See "Map & POI Coverage Expansion" section above |

---

## 🔥 Remaining Hidden / Unlocked Capabilities

The big "Cool factor 10/9/8" hero features have shipped. Items below are smaller
unlocks — most still need a J2534 capture session to confirm CAN IDs.

### Cool factor 7 — personalization (still open)
- Per-profile audio DSP linked to drive mode (Sport+ drier, Snow heavy bass)
- Full I-Key profile sync (climate + audio source + station + DSP + brightness + units)
- Custom Personal-mode parameters (throttle curve, ATTESA bias, ESC sensitivity)
- Performance run logger / track history (WOT auto-log; max RPM, peak boost, 0-60, peak G)
- Live tachometer w/ shift light + customizable redline (top-strip in Sport+)

### Cool factor 6 — nice-to-have
- Cylinder-by-cylinder knock log (VR30 enhanced PIDs → 6-bar chart)
- Wiper park-position adjust (if BCM honors alt position frame)
- Fuel economy history — 90-day trip chart (easy once TripLogger settles)
- Battery health trend (voltage 0x625 over sessions, start-crank dip estimate)
- Tire wear estimator (wheel-speed deltas + ATTESA bias history)
- "Hide nag screens" mode — flag for user awareness; baseline already does this

### Cool factor 5 — niche
- Hidden diagnostic-menu replicator (touchscreen cal, speaker tests, color bars)
- BCM option dump / restore (JSON snapshot — for safe experimentation)
- Driver attention score (ProAssist raw on Info tab)

---

## ⚠️ NOT implementing — hardware-risky / legally problematic

- ESC/VDC permanent disable
- ECU map flash (wrong hardware path — needs OBD2 tuner cable)
- Undocumented diagnostic writes (could brick a module)
- TPMS pressure spoofing (could mask a real fault)
- Air-bag-system writes (never read or written, permanent rule)

---

## Implementation gates

Before any new write path ships:
1. J2534 capture pass with factory system live, recording every CAN frame around target action.
2. Confirm read paths produce expected values before adding writes.
3. Bench-test writes on a dev DCU (no live vehicle) where possible.
4. UI two-step confirmation for anything affecting safety systems.

All new BCM Work Support writes are gated behind `SettingsService.canVerifiedWrites`
(default false). UI is fully functional; writes are no-op until capture verifies +
user explicitly enables. See `docs/hardware-day-capture-checklist.md`.
