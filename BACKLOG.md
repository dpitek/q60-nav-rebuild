# Q60 Nav — Backlog

Items not targeted for the initial DCU flash. Ordered roughly by priority.

---

## Input / UX

### QML On-Screen Keyboard
- Qt VirtualKeyboard module was NOT built for the i386 target — not available
- Need a custom `QmlKeyboard.qml` component (QWERTY + numeric layouts)
- Wire into `NavCompanionView.qml` `TextInput` focus events
- Wire into any other QML `TextInput` that appears (Settings search, etc.)
- Design: slide-up overlay, matches Q60 dark theme, 44px+ key targets
- Consider: key repeat on backspace hold, haptic feedback via CAN (if supported)

---

## Code / Build

### SettingsView persistence
- All settings changes are in-memory only; no persistence to disk
- Need QSettings or JSON write-back to `/opt/nav/config/config.json`

### Trip logger wiring
- InfoView trip history is static mock
- Wire to GPX log writer triggered on ignition-off (CAN ignition-off frame TBD)

### Destination search / route preview sub-view
- NavigationView currently has stub `handleBack()` / `handleHome()` functions
- Needs `DestinationSearch.qml` + `RoutePreview.qml`
- Wire into NavigationView using a sub-view StackView or Loader

### CAN-based TCU signal strength
- NetworkService TCU mode returns hardcoded 4 bars — RNDIS gives no signal data
- Real RSSI lives in Continental BL28NA003 CAN frames (IDs unknown)
- Requires CAN sniff during active LTE session to identify frame + decode RSSI field

---

## Map & POI Coverage Expansion

### SC — South Carolina
- Vector tiles: build `sc.mbtiles` via `build-map-tiles.sh` (OSM PBF source)
- POI block: extract OSM nodes for SC, append to POINT047.DAT (same v3 pipeline)
- Style update: add `mbtiles:///opt/nav/tiles/sc.mbtiles` source to `q60-dark.json`
- Routing: build Valhalla tiles for SC region
- Notes: ~180MB tiles estimated; 8–10k POI records expected

### GA — Georgia
- Same pipeline as SC
- Notes: ~290MB tiles estimated; Atlanta metro adds routing complexity

### VA — Virginia
- Same pipeline as SC/GA
- Notes: ~260MB tiles; includes DC metro fringe (use `vaNorthFence` bbox to crop if needed)

### Combined SE region (stretch goal)
- Single `se.mbtiles` covering NC+SC+GA+VA — cleaner style config
- Requires re-running NC tile build with expanded bbox
- Estimate: ~1.1GB combined

---

## Navigation & Routing

### HOUSE001 address search for Auger Shell Court
- Add address record to HOUSE001 B3440BE0.DAT (B-tree, 512-byte pages, ~649 pages)
- Enables "171 Auger Shell Court" address search on OEM nav
- Complexity: high — Zenrin B-tree format, no SDK

### RDSTM001 routing graph for Auger Shell Court and Parkman Grant Drive
- Add road nodes and links to routing graph (RDSTM001 topology file)
- Enables turn-by-turn routing to both new streets
- Complexity: high — proprietary format

---

## Hardware / DCU

### CAN ID verification
- AV-CAN 0x3F6 and 0x4CE IDs for joystick/button are UNVERIFIED
- Requires hardware sniff on AV-CAN connector at first boot
- Tool: J2534 adapter + candump or socketcan

### MapLibre EGL on Intel GMA 3600
- Current simulated path uses Mesa softpipe
- DCU GPU: Intel GMA 3600 (PowerVR SGX545 derivative)
- May require pvr_dri or software fallback — needs hardware test

### First-boot profile setup
- WelcomeOverlay triggers on startup; profile selection not yet implemented
- KeyFob profile matching (key slot → profile ID) requires CAN integration

### TCU USB VID:PID
- `tcu-detect.sh` will auto-identify and patch udev rule on first boot
- If `udevadm` sysfs traversal fails, run: `dmesg | grep -i "idVendor\|rndis"` and note the IDs

---

## 🔥 Hidden / Unlocked Capabilities — Beyond Factory

The factory Clarion DCU exposes a fraction of what the Q60 can actually do. The
vehicle is full of dealer-programmable BCM options, hidden diagnostic menus, JDM
features disabled in the US firmware, and CAN PIDs the factory dashboard never
reads. With our own open-source head unit, we can surface them.

Research sources: Infiniti Q50/Q60 forums (infinitiq50.org / infinitiq60.org),
CONSULT-III TSBs (ITB19-002b et al.), EcuTek/UpRev tuning documentation, VR30DDTT
reference threads, and Nissan/Infiniti dealer service-mode procedures. All items
below require a J2534 capture pass first to confirm CAN IDs/payloads.

Ranked by cool factor (10 = "you'll demo this first," 1 = "nice if free").

---

### ⭐ Cool factor 10 — Hero features

#### Disable ASC (fake exhaust) — one-tap toggle
- Q60 with Bose Performance Series pipes synthesized engine sound through the speakers ("Active Sound Control"). Factory hides the on/off in a deep diagnostic menu (Settings → Seek-up ×3 → press-hold below right scroll arrow ×5s) and gates it behind dealer programming on 2020+.
- We expose a single toggle on the Drive Mode picker AND in Audio settings. State persists per-profile (your "Sport+" can be loud, Eco can be silent).
- CAN target: same BCM/DSP channel as ANC. Need J2534 sniff during the diagnostic-menu toggle to capture the frame.
- Why people want it: tuners charge $50–$150 just to flip this. Goes viral on YouTube/forums.

#### Real-time VR30DDTT track display
- VR30 (3.0L twin-turbo) exposes a rich telemetry set the factory dash never shows. Via OBD2 enhanced PIDs / extended CAN frames: boost pressure, oil temp (VVT temp sensor), trans fluid temp (TCM PID), intake air temp (IAT), ignition advance, knock retard, wastegate position, MAF, AFR.
- Full-screen "Track" overlay (lower-screen Vehicle tab → "Track" sub-tab): 3-row dashboard of live needles + a 60-second scrolling history strip for each.
- Same data EcuTek's ECU Connect app shows — but built in, free, no cable.

#### ATTESA E-TS live torque split (we already have the CAN ID — 0x1CA)
- Factory dash shows nothing. We have the data path already wired.
- UI: real-time front/rear torque % pie chart with last-60s sparkline. Live G-arrow overlay. Saves a session-best "max front bias" stat.
- GT-R fans will lose their minds.

#### G-meter + acceleration history
- Q60 has a 3-axis G-sensor under the center console feeding ATTESA and ABS (well-documented in the ATTESA technical literature).
- Read longitudinal/lateral G via CAN. Render a circular G-pad with current dot + peak-hold rings. Reset per ignition cycle.
- 0–60 / 0–100 / quarter-mile auto-detect using wheel speed (0x284/0x285) + GPS cross-check.

#### Custom "Track" drive mode preset
- Stock has 6 modes. We can compose a 7th: ATTESA write 0x2DC (we have the ID), maxed throttle map, audio profile = ASC off, climate to ON-NOT-AUTO, gauges to Track sub-tab.
- One tap activates everything. State per-profile.

---

### ⭐ Cool factor 9 — Things that make every drive better

#### Walk-away auto-fold mirrors
- Factory has folding mirrors (switch only). Aftermarket modules cost $80–150.
- We send the BCM fold command on the door-lock CAN frame. Free.

#### Comfort window close from key fob (JDM feature, US-disabled)
- US firmware allows open-on-unlock-hold but **disables** close-on-lock-hold. JDM/EU firmware allows it. CONSULT-III can flip the BCM option, but it's not in the menu Doug can reach.
- We synthesize the close commands directly when the fob lock-hold signal arrives on CAN. Bypass the BCM gate.

#### One-touch up/down for ALL windows (factory: driver only)
- Power window CAN commands exist for all 4 doors. Factory firmware only honors "one-touch" on the driver. We honor it on all 4.

#### Auto-up windows during rain (heuristic)
- Wiper signal (0x35D — Q50_LIKELY) + window-position read → if wipers go to auto mode and a window is open more than 1cm, fire close command after 3s grace.
- Strongly user-toggleable; opt-in only.

#### DTC read + clear, with friendly descriptions
- Factory hides all DTCs unless something major triggers a dash light. We surface them on the Info tab with plain-language explanations (e.g. "P0299 = boost low — check intake clamps").
- Clear button (with confirmation). The kind of feature people drive 20 miles to a parts store to use.

---

### ⭐ Cool factor 8 — Quality-of-life unlocks

#### Speed-sensitive auto-lock — user-configurable threshold
- Factory auto-locks at a hardcoded speed (~15 mph). Make it user-selectable: never / 5 / 10 / 15 / 25 mph / always-on.

#### Mirror tilt-on-reverse — angle + which side
- BCM exposes a "how far does the mirror dip in reverse" setting. CONSULT-III flips it. We surface as a slider (0-100%) and per-side toggle.

#### Horn chirp / lock confirmation customization
- Factory cycles 2 modes (hazard-only, hazard+horn) via key fob long-hold; CONSULT-III exposes more (silent, double-chirp, lights-only). We expose all of them.

#### Welcome lighting choreography
- Sequential turn-signal LEDs, ambient lighting wake order, footwell brightness — all CAN-controllable. Build a "Welcome sequence" customizer.

#### DRL behavior — on/off, with parking lights, on signal cancel
- BCM Work Support menu exposes these on CONSULT-III. Factory UI has only on/off. We expose the full matrix.

#### Auto headlight delay — adjustable
- Factory has a fixed "lights stay on for X seconds after key off." BCM option to change it. User slider: 0 / 15 / 30 / 60 / 120 / 180 seconds.

#### Maintenance reminder reset built-in
- Oil life %, tire rotation, brake fluid, air filter, cabin filter — factory requires dealer or button-mash combos. Expose all in Settings → Vehicle → Maintenance with one-tap reset.

#### TPMS thresholds customizable for track use
- Factory uses placard pressures (~32 psi cold). Track day = 40+ psi hot. Expose per-corner warning thresholds; save profiles ("Street" / "Track" / "Touring").

---

### ⭐ Cool factor 7 — Personalization

#### Per-profile audio DSP linked to drive mode
- Bose AudioPilot/Centerpoint/SurroundStage/Driver-Stage already toggleable.
- Bind a DSP profile to each drive mode: Sport+ = drier sound, Standard = full Centerpoint, Snow = max bass for road texture cancellation. Auto-switch on mode change.

#### Per-profile climate, audio source, drive mode (full I-Key profile)
- Factory ties some settings to I-Key fob. We extend to everything: last audio source, last station/preset, climate setpoints, drive mode, DSP profile, brightness, units.
- Profile bound to key-fob slot ID (CAN 0x35B — already in our service).

#### Custom Personal-mode parameters
- Factory Personal has 5 knobs. We add: throttle pedal response curve (5 presets), ATTESA preferred bias (full RWD / 90/10 / 80/20 / auto), ESC sensitivity for non-track mode.

#### Performance run logger / Track history
- Every drive that goes WOT, log a "performance run": max RPM, peak boost, 0–60 time, peak G, max ATTESA front split. Browse history; share as image overlay.

#### Live tachometer w/ shift light + customizable redline
- Add a top-strip RPM bar on upper screen during Sport/Sport+ with user-configurable shift light point (default 6500 redline). Color sweep green→yellow→red.

---

### ⭐ Cool factor 6 — Nice-to-have

#### Cylinder-by-cylinder knock log
- VR30 exposes per-cylinder ignition timing and knock retard via enhanced PIDs. Surface a 6-bar chart on track screen.

#### Wiper park-position adjust
- Some Nissan firmware supports two wiper park positions. Expose via Settings → Vehicle if the BCM honors the alt position frame.

#### Fuel economy history — 90-day trip chart
- Already in audit P3, but worth re-flagging — easy to build once TripLogger lands.

#### Battery health trend
- We read voltage (0x625). Track over sessions, estimate state-of-health by start-cranking-dip pattern.

#### Tire wear estimator
- Combine wheel speed deltas (0x284 vs 0x285) under load + ATTESA front-rear bias history → estimate uneven wear. "Front-left wearing 12% faster than rear, consider rotation."

#### "Hide nag screens" mode
- The factory startup-disclaimer screen is annoying. Replace with instant boot to last-used tab. (Already baseline behavior — flag for user awareness.)

---

### ⭐ Cool factor 5 — Niche

#### Hidden diagnostic-menu replicator
- Replicate the factory secret-menu functionality (touchscreen calibration, speaker tests, color bars, etc.) but with proper labels. Useful when reselling the car back to factory firmware in the future.

#### BCM option dump / restore
- Read every BCM Work Support flag, save to JSON, restore on demand. Lets Doug experiment freely without dealer trips to revert.

#### Driver attention score
- ProAssist "Driver Attention Alert" already monitors steering inputs for fatigue. Surface the raw score on Info tab.

---

### ⚠️ Hardware-risky / illegal-in-some-jurisdictions — NOT implementing
- ESC/VDC permanent disable (legally problematic, dangerous)
- ECU map flash (wrong hardware path — needs OBD2 tuner cable; not a DCU job)
- Diagnostic mode write commands that aren't documented (could brick a module)
- TPMS pressure spoofing (could mask a real fault)
- Air-bag-system writes (we don't even read these; permanent rule)

---

### Implementation gates

**Before any of the above ships:**
1. J2534 capture pass with the factory system live, recording every CAN frame around each target action (door lock, drive mode switch, ASC toggle via diagnostic menu, etc.).
2. Confirm read paths produce expected values before adding writes.
3. Bench-test writes on a dev DCU (no live vehicle) where possible.
4. Two-step confirmation in UI for anything that affects safety systems or vehicle state changes (lights on, doors lock, etc.).

**Cool factor 10 items are the "demo first" features. Build the J2534 capture
session around them so the visible payoff matches the verification effort.**
