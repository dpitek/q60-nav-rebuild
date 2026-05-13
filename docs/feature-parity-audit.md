# Q60nav Feature Parity Audit
**Vehicle:** 2017 Infiniti Q60 Sport 3.0t AWD — Sensory + ProAssist packages  
**Factory System:** Clarion QY5092 DCU, Intel Atom i686, Infiniti InTouch (dual-screen)  
**Rebuild:** qt6nav / q60nav — Qt6/QML, same hardware  
**Audit Date:** 2026-05-12 (revised 2026-05-13 — reflects already-wired CAN paths)
**Status:** Draft v2 — drives next development phase

> **2026-05-13 revision note:** Several P1 items marked ❌ in v1 already have CAN
> parsing wired in `VehicleService.h` even if no QML surface exists yet. These are
> re-graded as ⚠️ (data path ready, UI missing) so background agents don't redo
> service work that's already done.

---

## Part 1 — Factory Feature Inventory

### 1.1 Hardware Platform
- Upper display: 8" color LCD/VGA touchscreen (resistive + rotary knob redundancy)
- Lower display: 7" capacitive touchscreen (smartphone-style)
- Upper screen: navigation, vehicle systems, AVM camera feed
- Lower screen: audio, climate, phone, apps, drive mode selector, settings
- Dual-zone HVAC physical panel below lower screen (direct buttons + lower screen supplement)
- Rotary/push control knob on center console (upper screen navigation)

### 1.2 Navigation (Upper Screen Primary)
- Turn-by-turn navigation with voice guidance
- Lane guidance with lane arrows on-screen
- 3D building graphics in urban areas
- 2D / 3D map view toggle
- Map heading: north-up / heading-up
- Day / night mode auto-switch
- Zoom in/out
- Destination entry:
  - Street address (state → city → street → number)
  - Point of Interest (by category, by name, by phone number)
  - Intersection
  - Freeway entrance / exit
  - City center
  - Home / stored locations (Favorites)
  - Recent destinations
  - Map scroll and drop pin
- Route options: Fastest / Shortest / Energy Saving (eco)
- Route avoidance: avoid toll roads, avoid highways, avoid ferries
- Multiple waypoint routing (via points)
- Detour calculation
- Speed limit display (GPS/map-data based, not camera-based)
- Speed alert (user-set threshold, audible warning)
- Real-time traffic overlay (SiriusXM NavTraffic — requires subscription)
- Traffic incident icons on map (congestion, accidents, road closures, construction)
- Traffic-aware rerouting (automatic or prompted)
- SiriusXM Weather overlay on map (requires Travel Link subscription)
- Fuel price overlay (SiriusXM Travel Link — nearest stations, price, type sort)
- Parking POI integration
- Junction view / highway junction display (photorealistic lane split graphics)
- Highway exit information (services ahead)
- ETA and remaining distance display
- Voice recognition for destination entry ("Navigate to [address/POI]")
- Navigation settings: voice guidance on/off, volume, POI icons on/off, route highlight color
- Map update via SD card or USB (Infiniti Navigation update portal)

### 1.3 Audio (Lower Screen)
**Sources:**
- AM radio (seek/scan, preset stations ×6 per band)
- FM radio (seek/scan, RDS station/song name, preset stations ×6 per band)
- HD Radio (digital HD channels on FM band — automatic where available)
- SiriusXM satellite radio (channel name, category, artist, title, presets, parental lock)
- CD player (single disc in-dash, track info display)
- USB media playback (USB-A port, MP3/WMA/AAC, folder/artist/album browse)
- Bluetooth audio (A2DP/AVRCP: album art, track/artist/album, prev/play/pause/next, source name)
- AUX input (3.5mm, no metadata)

**Controls & Settings:**
- Volume knob (physical) + on-screen slider
- Mute
- Bass / Treble / Balance / Fade (in Settings > Audio > Sound)
- Bose AudioPilot (auto noise compensation — on/off)
- Bose Centerpoint (surround simulation from stereo — on/off)
- Bose SurroundStage (on/off)
- Driver's Audio Stage (on/off — localizes soundstage to driver seat)
- Active Sound Management (engine harmonic enhancement/cancellation — tied to drive mode)
- Speed-Sensitive Volume (SSV) — auto volume increase with road speed (on/off + sensitivity)
- Audio tone follows source (each source remembers its EQ settings)
- Voice recognition for audio: "Play [artist/song]", "Tune FM [frequency]", "SiriusXM [channel]"

**Bose Performance Series (Sensory package — 16 speakers on Q60):**
- 16-speaker system, tailored to Q60 cabin acoustics
- Dedicated center channel, surround speakers, subwoofer
- Note: factory was 13-speaker; some documentation cites 16 for the Sensory-equipped Q60

### 1.4 Phone & Connectivity (Lower Screen)
- Bluetooth hands-free calling (HFP)
- Bluetooth audio streaming (A2DP)
- Device pairing (up to 5 BT devices stored; last-paired auto-reconnects)
- Phonebook sync (PBAP — contacts from phone, stored in headunit)
- Recent calls list (dialed, received, missed)
- Dial pad for manual number entry
- Contact browse and call by name
- Call timer display
- Mute / speaker / end call controls
- Incoming call caller ID + name (if in phonebook)
- Call waiting indication
- Hands-free Text Messaging Assistant:
  - Incoming SMS read aloud via TTS
  - Predefined reply templates: "On my way", "Running late", "Driving, can't text", etc.
  - Custom reply template creation (up to 5 custom messages)
  - "Read Text" / "Next Text" voice commands
- Voice recognition for phone: "Call [contact name]", "Dial [number]", "Read text"
- Emergency SOS via InTouch Services (Sensory package — requires active subscription)
- Infiniti InTouch app (remote services via smartphone):
  - Remote engine start / stop
  - Remote door lock / unlock
  - Climate pre-conditioning (start with remote)
  - Horn/lights (vehicle locator)
  - Vehicle health report (tire pressure, fuel, oil life via app — NOT directly on lower screen)
  - Destination Send to Car (send from app → nav system)
  - Boundary/Curfew alerts (speed/geo alerts to phone)
- Wi-Fi hotspot display (vehicle acts as hotspot if TCU-equipped; status only on screen)

### 1.5 Climate (Lower Screen + Physical Panel)
- Dual-zone automatic temperature control (driver / passenger independent, 60–85°F / 16–29°C)
- AUTO mode (system selects fan speed, airflow distribution, A/C automatically)
- Manual fan speed override (0 = off, 1–7)
- A/C compressor on/off toggle
- Recirculation (RECIRC) on/off toggle
- Airflow distribution modes:
  - Face (dash vents)
  - Face + Feet (bi-level)
  - Feet (floor vents)
  - Feet + Defrost (floor + windshield)
  - Defrost (windshield — also activates A/C and defroster)
- Front windshield defrost (MAX DEF button — physical)
- Rear window defrost (on/off toggle — accessible via lower screen and physical button)
- MAX A/C mode (maximum cooling: recirculate, max fan, max A/C)
- Zone sync (SYNC button — sets passenger temp to match driver)
- Plasmacluster air purifier (Sensory package — on/off, ion intensity)
- Grape polyphenol cabin filter (Sensory package — status/replacement reminder)
- Heated front seats: Driver and Passenger, 3 levels (HI / MID / LO) + OFF
  - Note: ventilated/cooled seats are NOT available on 2017 Q60 (confirmed)
- Heated steering wheel: ON/OFF (Sensory package — via lower screen or physical button)
- Outside ambient temperature display
- Climate settings persist per driver profile (I-Key identity)
- Rain-sensing auto wiper integration:
  - Wiper stalk lever in AUTO position activates rain sensor
  - **Sensitivity adjustment: physical knob on wiper stalk** (rotate toward front = High sensitivity; rotate toward rear = Low sensitivity)
  - InTouch lower screen has a Rain Sensor ENABLE/DISABLE toggle in Settings > Vehicle (confirms the feature is on but does NOT adjust sensitivity — that is stalk-only)
  - Sensitivity is NOT adjustable from the touchscreen; screen only activates/deactivates the system

### 1.6 Vehicle / Driver Aids (Lower Screen + Upper Screen)
**Driver Assistance Controls (via lower screen Settings > Driver Assistance or dedicated menu):**
- Intelligent Cruise Control (ICC) / Adaptive Cruise Control:
  - Set speed display
  - Set following distance (3 levels)
  - Active/inactive state indicator (already in rebuild)
- Predictive Forward Collision Warning (PFCW): 
  - Sensitivity setting: Far / Normal / Near
  - On/off toggle
- Forward Emergency Braking (FEB): on/off toggle
- Blind Spot Warning (BSW): on/off toggle
- Blind Spot Intervention (BSI): on/off toggle (separate from BSW)
- Lane Departure Warning (LDW): on/off toggle
- Lane Departure Prevention (LDP): on/off toggle
- Back-Up Collision Intervention (BCI): on/off toggle
- Driver Attention Alert: (monitors steering for fatigue patterns — alert only, no on-screen control)
- Around View Monitor (AVM) — upper screen:
  - Activates automatically in reverse
  - Manual activation via AVM button (shows top-down 360° composite from 4 cameras)
  - Views: Top-down bird's eye, Front wide, Rear wide, Left side, Right side
  - Moving Object Detection (MOD): alerts when pedestrian/object detected in AVM view
  - Front sonar + rear sonar distance arcs on-screen
  - AVM display while in Drive at low speed (parking assist forward)
  - Brightness/contrast calibration in settings
  - NOTE: AVM uses upper screen, triggered by shift position and/or button

**Vehicle Information (lower screen — Vehicle Info / Info tab):**
- Individual tire pressure (all 4 corners, PSI display — TPMS system)
- Fuel level (arc gauge — already in rebuild)
- Coolant temperature (bar gauge — already in rebuild)
- Battery voltage (already in rebuild)
- Engine RPM (already in rebuild)
- Oil life percentage (maintenance reminder — resets at service)
- Service interval reminder (mileage/time countdown)
- Trip computer (one or two trip meters):
  - Trip distance (A and B)
  - Average fuel economy (MPG, current and trip-average)
  - Instantaneous fuel economy
  - Average speed
  - Elapsed trip time
  - Eco driving score / efficiency indicator
- Door ajar diagram (all 4 doors + trunk — already in rebuild)
- Parking brake indicator (already in rebuild)
- Rear defrost toggle (accessible from lower screen — already partial in rebuild)
- VDC (Vehicle Dynamic Control) on/off (lower screen toggle — traction control defeat)
- ATTESA AWD torque split display (available on AWD models — shows front/rear torque split as graphic or percentage; real-time)
- Driving mode current indicator (shows active mode: Standard/Sport/Sport+/Eco/Snow/Personal)

**Driving Mode Selector (lower screen — dedicated "Infiniti Drive Mode Selector" icon):**
- Mode selection: Standard, Sport, Sport+, Eco, Snow, Personal
- Personal mode customization sub-menu:
  - Engine & Transmission response (Standard / Sport / Eco / Snow)
  - Steering weight (Light / Normal / Heavy — if Direct Adaptive Steering equipped)
  - Active Trace Control sensitivity
  - Active Engine Brake setting
  - Active Sound Management level
- Mode confirmation display on both screens when switching

### 1.7 Settings (Lower Screen — Settings Menu)
- Display brightness (upper screen and lower screen independent)
- Day/night mode (Auto / Day / Night)
- Clock set (12h/24h, time zone, auto-sync from GPS)
- Units: Distance (mi/km), Temperature (°F/°C), Fuel economy (MPG / L/100km)
- Language selection
- Keyboard layout (QWERTY / ABC)
- Volume & beeps:
  - Navigation voice guidance volume
  - System sound / button click beep
  - Phone ringtone volume
  - Rear camera guide line color
- Bluetooth device management:
  - Pair new device
  - Forget device
  - Set priority / auto-connect order
- I-Key profile management (link settings to specific key fob identity)
- Navigation settings (detailed sub-menu — see navigation section)
- Audio settings (EQ, Bose features — see audio section)
- Camera / AVM settings (guide line display, brightness)
- Rain sensor enable/disable toggle (sensitivity is stalk-only)
- System information: software version, map data version, unit serial number
- Factory reset (requires confirmation)
- Voice recognition settings: on/off, tutorial mode, confirmation beep

### 1.8 SiriusXM Travel Link (Lower Screen — Apps/Info Section)
Requires active subscription (4-year trial included with 2017 Sensory-equipped Q60):
- Weather: current conditions, 5-day forecast, national/regional map
- Fuel Prices: nearby stations, price by grade, sort by distance or price
- Sports Scores: NFL/NBA/MLB/NHL/College live scores and schedules
- Stock Prices: NYSE/NASDAQ/AMEX quotes with watchlist
- Movie Listings: nearby theaters, showtimes by movie or theater
- Traffic (NavTraffic): separate from Travel Link — map overlay, incident list

---

## Part 2 — Gap Analysis Table

Legend: ✅ = done | ⚠️ = partial | ❌ = missing | N/A = not applicable to Q60

### Navigation

| Feature | Factory Has | Rebuild Has | Priority | Notes |
|---|---|---|---|---|
| Map display (upper screen) | ✅ | ⚠️ Placeholder | P1 | Core — no real map yet |
| Turn-by-turn HUD overlay | ✅ | ✅ | — | Done |
| Lane guidance arrows | ✅ | ❌ | P1 | Show correct lane at split/merge |
| Junction view (photorealistic splits) | ✅ | ❌ | P2 | High-impact for highway driving |
| 2D/3D map toggle | ✅ | ❌ | P2 | Map placeholder; needs real map |
| North-up / heading-up toggle | ✅ | ❌ | P2 | Standard map control |
| Destination: address entry | ✅ | ❌ | P1 | Core nav input |
| Destination: POI by category/name | ✅ | ❌ | P1 | Core nav input |
| Destination: intersection | ✅ | ❌ | P2 | Secondary input method |
| Destination: freeway entrance/exit | ✅ | ❌ | P2 | Secondary input method |
| Destination: Favorites / Home | ✅ | ❌ | P1 | Core usability |
| Destination: Recent destinations | ✅ | ❌ | P1 | Core usability |
| Route options (fastest/shortest/eco) | ✅ | ❌ | P1 | Route preference screen |
| Avoid toll / highway / ferry toggles | ✅ | ❌ | P2 | Route settings sub-menu |
| Waypoint / via-point routing | ✅ | ❌ | P2 | Multi-stop trips |
| Detour calculation | ✅ | ❌ | P2 | Reroute triggered |
| Speed limit display | ✅ | ⚠️ Speed badge only | P1 | Map-data speed limit badge on upper screen |
| Speed alert (user threshold) | ✅ | ❌ | P2 | Audible + visual when over limit |
| Real-time traffic overlay | ✅ SiriusXM | ❌ | P2 | Requires data feed; SiriusXM or API |
| Traffic-aware rerouting | ✅ | ❌ | P2 | Dependent on traffic overlay |
| SiriusXM weather map overlay | ✅ | ❌ | P3 | Lower priority |
| Fuel price overlay / POI | ✅ Travel Link | ❌ | P3 | Nice-to-have; Travel Link feed |
| Parking POI integration | ✅ | ❌ | P2 | POI category: Parking |
| Highway exit info (services ahead) | ✅ | ❌ | P2 | Exit sign popup |
| Voice nav input | ✅ | ❌ | P2 | "Navigate to…" voice command |
| Navigation voice guidance | ✅ | ❌ | P1 | Audio TTS turn announcements |
| ETA / remaining distance strip | ✅ | ✅ | — | Done |
| Rerouting banner | ✅ | ✅ | — | Done |
| Map update mechanism | ✅ SD/USB | ❌ | P2 | OTA or USB map update flow |

### Audio

| Feature | Factory Has | Rebuild Has | Priority | Notes |
|---|---|---|---|---|
| FM radio (seek/scan/presets) | ✅ | ✅ | — | Done |
| AM radio (seek/scan/presets) | ✅ | ✅ | — | Done |
| HD Radio (auto FM sub-channels) | ✅ | ❌ | P2 | Hardware-dependent; add if tuner supports |
| SiriusXM satellite radio | ✅ | ⚠️ Channel name only | P1 | Add category, signal strength, presets, parental |
| CD player | ✅ | N/A | — | No CD drive in rebuild hardware |
| USB media playback | ✅ | ❌ | P1 | USB-A port on dash; folder/artist/album browse |
| Bluetooth audio (A2DP/AVRCP) | ✅ | ✅ | — | Done |
| AUX input | ✅ | ✅ | — | Done |
| Volume slider + mute | ✅ | ✅ | — | Done |
| Bass / Treble / Balance / Fade EQ | ✅ | ❌ | P1 | In Settings > Audio |
| Bose AudioPilot (auto noise comp) | ✅ | ❌ | P2 | Toggle on/off; passes flag to DSP |
| Bose Centerpoint (surround sim) | ✅ | ❌ | P2 | Toggle; DSP flag |
| Bose SurroundStage | ✅ | ❌ | P2 | Toggle; DSP flag |
| Driver's Audio Stage | ✅ | ❌ | P2 | Toggle; DSP flag |
| Speed-Sensitive Volume (SSV) | ✅ | ❌ | P1 | Reads vehicle speed, scales volume |
| Source presets (FM/AM/SXM) | ✅ 6 per band | ⚠️ None | P1 | Preset store/recall per source |
| RDS station/song name (FM) | ✅ | ❌ | P1 | FM RDS text decode |
| Track browse (USB) | ✅ | N/A | — | Only when USB added |
| Voice audio control | ✅ | ❌ | P3 | "Play artist X", "Tune FM 101.5" |

### Climate

| Feature | Factory Has | Rebuild Has | Priority | Notes |
|---|---|---|---|---|
| Dual-zone temp control (60–85°F) | ✅ | ✅ | — | Done |
| Auto mode (full auto) | ✅ | ❌ | P1 | Single AUTO button — full system auto |
| Fan speed 0–7 manual | ✅ | ✅ | — | Done |
| A/C compressor on/off | ✅ | ✅ | — | Done |
| Recirculation on/off | ✅ | ✅ | — | Done |
| Airflow modes (face/feet/blend/def) | ✅ | ✅ 4 modes | — | Done; verify Feet+Defrost is separate from Defrost |
| Front windshield defrost (MAX DEF) | ✅ Physical | ⚠️ Via defrost mode | P1 | Add dedicated MAX DEF command (A/C + max fan + defrost) |
| Rear window defrost | ✅ | ✅ | — | Done |
| MAX A/C mode | ✅ | ❌ | P1 | Recirc + max fan + max cooling in one tap |
| Zone sync (SYNC) | ✅ | ❌ | P1 | Set passenger = driver temp |
| Heated front seats (3 levels) | ✅ | ✅ | — | Done |
| Ventilated/cooled seats | ❌ Not on Q60 | N/A | — | Not available on 2017 Q60; confirmed |
| Heated steering wheel | ✅ Sensory pkg | ❌ | P1 | On/off toggle on lower screen |
| Outside ambient temp display | ✅ | ✅ | — | Done |
| Plasmacluster air purifier | ✅ Sensory pkg | ❌ | P2 | On/off + ion level; sends CAN command |
| Rain sensor enable/disable toggle | ✅ Screen toggle | ❌ | P2 | Toggle in Settings > Vehicle; sensitivity = stalk only |
| Wiper sensitivity (stalk knob) | ✅ Physical only | N/A | — | NOT a screen control — stalk knob only |
| Climate profile per I-Key | ✅ | ❌ | P2 | Restore settings on key-fob identity |

### Phone & Connectivity

| Feature | Factory Has | Rebuild Has | Priority | Notes |
|---|---|---|---|---|
| BT calling (active call UI) | ✅ | ✅ | — | Done |
| Mute / end / speaker | ✅ | ✅ | — | Done |
| DTMF keypad | ✅ | ✅ | — | Done |
| Call timer | ✅ | ✅ | — | Done |
| Phonebook / contact browse | ✅ PBAP | ❌ | P1 | Pull contacts from phone via BT |
| Recent calls list (dialed/missed/rcvd) | ✅ | ❌ | P1 | PBAP call history |
| Incoming caller ID display | ✅ | ⚠️ Overlay exists | P1 | Wire caller name/number to overlay |
| Call waiting indication | ✅ | ❌ | P2 | Show second incoming call |
| SMS read-aloud (TTS) | ✅ | ❌ | P2 | MAP profile BT; TTS engine needed |
| Predefined SMS reply templates | ✅ | ❌ | P3 | Low frequency use |
| BT device management (pair/forget) | ✅ | ❌ | P1 | Settings > Bluetooth sub-screen |
| Voice phone commands | ✅ | ❌ | P2 | "Call John", "Dial 555-1234" |
| InTouch Services (remote app) | ✅ | ❌ | P3 | Backend infrastructure required |
| Destination Send to Car | ✅ | ❌ | P3 | InTouch Services dependency |
| Emergency SOS | ✅ Sensory pkg | ❌ | P3 | TCU-based; hardware dependency |
| Apple CarPlay | ❌ Not factory | N/A | — | Gap = OPPORTUNITY (see Part 3) |
| Android Auto | ❌ Not factory | N/A | — | Gap = OPPORTUNITY (see Part 3) |

### Vehicle / Driver Aids

| Feature | Factory Has | Rebuild Has | Priority | Notes |
|---|---|---|---|---|
| Door ajar diagram (4 doors + trunk) | ✅ | ✅ | — | Done |
| Fuel arc gauge | ✅ | ✅ | — | Done |
| Coolant temp bar | ✅ | ✅ | — | Done |
| RPM display | ✅ | ✅ | — | Done |
| Battery voltage | ✅ | ✅ | — | Done |
| Parking brake indicator | ✅ | ✅ | — | Done |
| Rear defrost toggle | ✅ | ✅ | — | Done |
| Cruise control active/speed | ✅ | ✅ Partial | P1 | Add following distance indicator |
| TPMS — individual tire pressures | ✅ | ⚠️ CAN wired (0x385); no QML | P1 | Need 4-corner PSI display in VehicleStatusView |
| Oil life percentage | ✅ | ⚠️ CAN wired (0x54C); no QML | P1 | Need maintenance reminder UI |
| Service interval countdown | ✅ | ❌ | P2 | Miles/time to next service |
| Trip computer A/B | ✅ | ❌ | P1 | Trip distance, avg MPG, avg speed, time |
| Instantaneous fuel economy | ✅ | ❌ | P2 | Live MPG readout |
| Average fuel economy | ✅ | ⚠️ CAN wired (0x554); no QML | P1 | Need trip-average MPG widget |
| Eco driving score | ✅ | ❌ | P3 | Driving efficiency rating |
| ATTESA AWD torque split display | ✅ AWD models | ⚠️ CAN wired (0x1CA); no QML | P1 | Need front/rear torque % graphic |
| VDC on/off toggle | ✅ | ❌ | P1 | Vehicle Dynamic Control defeat switch |
| Driving mode display (current mode) | ✅ | ⚠️ CAN wired (0x266 broadcast); no UI | P1 | Need active-mode badge |
| Driving mode selector screen | ✅ | ⚠️ CAN write wired (0x2DC); no full picker | P1 | Need mode picker + Personal config |
| PFCW sensitivity setting | ✅ | ⚠️ ADAS frame (0x47D) composable; no QML | P1 | Far/Normal/Near + on/off |
| FEB on/off | ✅ | ⚠️ ADAS frame (0x47D); no QML | P1 | Forward Emergency Braking toggle |
| BSW on/off | ✅ | ⚠️ ADAS frame (0x47D); no QML | P1 | Blind Spot Warning toggle |
| BSI on/off | ✅ | ⚠️ ADAS frame (0x47D); no QML | P2 | Blind Spot Intervention (separate) |
| LDW on/off | ✅ | ⚠️ ADAS frame (0x47D); no QML | P1 | Lane Departure Warning toggle |
| LDP on/off | ✅ | ⚠️ ADAS frame (0x47D); no QML | P1 | Lane Departure Prevention toggle |
| BCI on/off | ✅ | ⚠️ ADAS frame (0x47D); no QML | P1 | Back-Up Collision Intervention toggle |
| Around View Monitor (AVM) | ✅ | ❌ | P1 | 4-camera top-down view; upper screen |
| AVM view switching (bird/front/side) | ✅ | ❌ | P2 | Camera angle selector overlay |
| Moving Object Detection alerts | ✅ | ❌ | P2 | Pedestrian/object alert in AVM |
| Backup camera (reverse overlay) | ✅ | ✅ Overlay exists | P1 | Need actual camera feed wired in |
| Sonar distance arcs (front + rear) | ✅ | ❌ | P2 | Parking sensor proximity arcs |

### Settings

| Feature | Factory Has | Rebuild Has | Priority | Notes |
|---|---|---|---|---|
| Display brightness (upper + lower) | ✅ | ❌ | P1 | Settings screen |
| Day/night auto / manual mode | ✅ | ❌ | P2 | Auto-switches with ambient light |
| Clock set (12h/24h, GPS sync) | ✅ | ❌ | P1 | Especially if no NTP |
| Units (mph/kmh, °F/°C, MPG/L) | ✅ | ❌ | P1 | Critical for market/owner pref |
| Language selection | ✅ | ❌ | P2 | Qt i18n already supported |
| Keyboard layout (QWERTY/ABC) | ✅ | ❌ | P3 | Minor; default QWERTY fine |
| Bluetooth device management | ✅ | ❌ | P1 | Pair, rename, forget, priority |
| Navigation voice volume | ✅ | ❌ | P1 | Separate from media volume |
| System sound / beeps on/off | ✅ | ❌ | P2 | Button feedback sounds |
| Rain sensor enable/disable | ✅ | ❌ | P2 | CAN command to ADAS module |
| Camera guide line color | ✅ | ❌ | P3 | Aesthetic only |
| I-Key driver profile management | ✅ | ❌ | P3 | Multi-driver personalization |
| System info (SW version, map ver) | ✅ | ❌ | P2 | About screen |
| Factory reset | ✅ | ❌ | P2 | Wipe user prefs |
| Voice recognition settings | ✅ | ❌ | P3 | Only if voice added |

### SiriusXM Travel Link (Lower Screen Info/Apps)

| Feature | Factory Has | Rebuild Has | Priority | Notes |
|---|---|---|---|---|
| SiriusXM audio playback | ✅ | ⚠️ Partial | P1 | Needs presets, parental, signal strength |
| SiriusXM NavTraffic overlay | ✅ | ❌ | P2 | Requires SXM data subscription |
| Weather current + 5-day forecast | ✅ Travel Link | ❌ | P2 | Can substitute open weather API |
| Fuel prices nearby | ✅ Travel Link | ❌ | P3 | GasBuddy API alternative |
| Sports scores | ✅ Travel Link | ❌ | P3 | Low drive relevance |
| Stock prices | ✅ Travel Link | ❌ | P3 | Very low drive relevance |
| Movie listings | ✅ Travel Link | ❌ | P3 | Low drive relevance |

---

## Part 3 — Rain Sensor / Wiper Delay — Detailed Findings

**This is NOT a screen-adjustable sensitivity control.** Specifically:

1. **InTouch lower screen** has a single **Rain Sensor ON/OFF toggle** in Settings > Vehicle (or similar vehicle settings path). This enables or disables the rain-sensing mode entirely. It sends a CAN command to the wiper control module.

2. **Sensitivity adjustment** is done exclusively with the **physical knob on the wiper stalk**:
   - Push lever down to AUTO position (activates rain sensor mode)
   - Rotate knob toward the **windshield (front)** = **Higher sensitivity** (wipers activate on lighter rain)
   - Rotate knob toward **rear** = **Lower sensitivity** (wipers need heavier rain to activate)
   - This is an analog voltage divider input to the rain sensor module — not software-controllable

3. **What to implement in q60nav**: A toggle in Settings > Vehicle labeled "Rain Sensor" (on/off). No slider needed — the hardware does the rest. The CAN bus ID for rain sensor enable is in the ADAS module (check sn-bridge CAN map for the appropriate PID).

---

## Part 4 — New Capabilities (Beyond Factory)

These don't exist in the Clarion QY5092 factory system and represent genuine differentiation:

### P1 — High Value, Implement Now

| Capability | Why Better Than Factory | Implementation Notes |
|---|---|---|
| **Apple CarPlay** | Factory has zero smartphone projection | Requires compatible BT/USB stack + CarPlay entitlement or open-source (OpenAuto2 / AAio); upper screen |
| **Android Auto** | Same as above | AAio (Android Auto Indirect Open) over BT; pairs with CarPlay effort |
| **USB media with full metadata** | Factory CD-quality browsing | Already have USB port; use libavformat or taglib |
| **OBD2 extended diagnostics** | Factory shows ~6 PIDs; OBD2 has 200+ | Add DTC read/clear, live sensor graph, freeze frame data |
| **Real-time torque split graph** | Factory shows static %; rebuild can graph it | Ring buffer + sparkline; reads ATTESA CAN PID |
| **Trip logging / route history** | Factory has zero trip recording | GPX save per ignition cycle; browse/export history |

### P2 — High Value, Next Sprint

| Capability | Why Better Than Factory | Implementation Notes |
|---|---|---|
| **Parking location save** | Factory cannot do this | Auto-save GPS coords on ignition-off; display on map |
| **0–60 / quarter-mile timer** | Factory has no performance timing | Uses wheel speed or GPS; Sport+ mode trigger |
| **Lateral G-meter** | Factory has no g-meter | IMU or GPS-derived; circular gauge on upper screen |
| **Offline vector map tiles** | Factory map requires card update $200+; tiles go stale | MapLibre-GL or Mapbox offline; free OSM tiles; never expires |
| **Custom driving profiles** | Factory Personal mode limited to 5 parameters | Full profile: seat memory + audio EQ + climate + drive mode; keyed to I-Key |
| **Weather integration (open API)** | Factory requires SiriusXM subscription | OpenWeatherMap or NWS API; free; current + forecast |
| **Speed camera / speed trap alerts** | Factory has no speed cam alerts | Waze/OSM speed camera DB; alert + icon on map |

### P3 — Valuable, Plan Later

| Capability | Why Better Than Factory | Implementation Notes |
|---|---|---|
| **SMS display (full messages)** | Factory only reads via TTS | BT MAP profile; show thread on lower screen |
| **Digital instrument cluster mirroring** | Factory has no secondary display for instruments | Upper screen alternate mode: full-screen cluster (RPM, speed, temp, g-meter) |
| **Long-term fuel trim / knock data** | Factory hides LTFT; this surfaces it | OBD2 Mode 01 PIDs 06/07/08/09 |
| **OTA firmware update** | Factory requires dealer flash | Already in backlog; HTTP pull + A/B partition |
| **Lap timer / track mode** | Factory has no track mode | GPS-based lap with split times; separate "Track" tab in VehicleStatusView |
| **Road hazard reporting** | Factory has zero | Tap-to-report; save to local GPX or push to server |
| **Battery health monitoring** | Factory shows voltage only | Track voltage trend over sessions; estimate SoH |
| **Fuel economy history graphs** | Factory resets trip meter; no history | Session-by-session MPG chart; 90-day view |

---

## Part 5 — Recommended QML Changes

### Upper Screen (NavigationView)
1. **Real map integration** — Replace placeholder with MapLibre-GL QML plugin or qtlocation with OSM/offline tiles. This is the single highest-impact P1 item.
2. **Lane guidance widget** — Overlay at bottom of map: colored lane arrows with "KEEP LEFT" / "USE ANY LANE" text. Activate within 0.5mi of a turn.
3. **Junction view panel** — Modal overlay slides in from right when approaching a complex interchange. Show photorealistic or stylized split-road graphic.
4. **Speed limit badge** — Already exists (speed badge); wire to map-data speed limit. Add color change (yellow → red) when over limit by user-defined threshold.
5. **AVM view** — New overlay state: when gear = Reverse or AVM button pressed, switch upper screen to 4-camera composite view with sonar arcs and MOD highlight boxes.
6. **Sonar proximity arcs** — Draw front/rear parking sensor arcs (green → yellow → red) in AVM view and optionally as a thin overlay at bottom of nav map.

### Lower Screen — ControlHubView
**Add new tabs or expand existing:**

7. **Nav tab (NavCompanionView)** — Add: destination entry (address/POI/recent/favorites), route options modal (fastest/shortest/eco + avoidances), waypoint list. Existing ETA/speed/turn info stays.

8. **Audio tab (AudioView)** — Add:
   - USB source pill + track browser (folder/artist/album tree)
   - FM RDS text (station name / song title from signal)
   - SiriusXM presets grid (like FM presets), category scroll, signal strength bar, parental lock icon
   - Settings sub-panel: Bass/Treble/Balance/Fade sliders, Bose toggles (AudioPilot/Centerpoint/SurroundStage/Driver Stage), SSV toggle + sensitivity
   - Per-source preset memory (6 presets per band)

9. **Phone tab (PhoneView)** — Add:
   - Contacts list view (browse, search, tap to call) — pulls from PBAP
   - Recent calls list (3 columns: dialed / received / missed; tap to call back)
   - SMS inbox (if MAP BT profile active): show sender + message preview; TTS play button
   - Settings sub-panel: BT device list (pair new, forget, set priority)
   - Caller ID wired to incoming call overlay (name from phonebook)

10. **Climate tab (ClimateView)** — Add:
    - AUTO button (top of screen, full-width, prominent)
    - MAX A/C button (one-tap: recirc + max fan + full cooling)
    - MAX DEF button (one-tap: A/C + max fan + defrost mode)
    - SYNC button (lock passenger = driver temp)
    - Heated steering wheel toggle (icon + ON/OFF)
    - Plasmacluster toggle + level indicator
    - Rain sensor enable toggle (moves from Settings to here for discoverability)

11. **Vehicle tab (VehicleStatusView)** — Major expansion:
    - **Info sub-tab**: Add TPMS 4-corner display (PSI per wheel with color coding), oil life %, service interval countdown, trip computer A/B (distance/avg MPG/avg speed/elapsed time), instantaneous MPG bar
    - **ATTESA sub-tab** (AWD): Real-time torque split visualization (front/rear split as animated graphic, sparkline history)
    - **Drive Mode sub-tab**: Mode selector tiles (Standard / Sport / Sport+ / Eco / Snow / Personal), Personal mode config sub-screen (engine/transmission response, steering weight, Active Trace Control, Active Engine Brake, ASM level)
    - **Driver Aids sub-tab**: Toggle grid for all ProAssist features — PFCW (with Far/Normal/Near selector), FEB, BSW, BSI, LDW, LDP, BCI; VDC toggle

12. **New "Info" tab** — SiriusXM Travel Link / connected info:
    - Weather card (current + 5-day forecast; open API fallback if no SXM)
    - Fuel prices card (nearby stations, sort by price)
    - Trip history list (past GPX sessions, tap to view route on map)
    - Parking location card (last parked GPS pin)

13. **Settings screen** — New dedicated full-screen settings view (tap gear icon):
    - Display: brightness (upper/lower separate), day/night mode
    - Clock: 12h/24h, GPS sync, manual set
    - Units: mph/kmh, °F/°C, MPG/L/100km
    - Language
    - Bluetooth: device list with pair/forget/priority
    - Audio: (delegates to audio settings panel)
    - Navigation: voice volume, POI icons, route preference default
    - System: SW version, map version, serial, factory reset
    - Rain sensor: enable/disable toggle

---

## Priority Summary

| Priority | Count | Effort | Examples |
|---|---|---|---|
| **P1** | ~38 features | 1–3 sprints | Real map, USB audio, trip computer, TPMS, drive mode, driver aids toggles, AVM, AUTO/SYNC climate, EQ, SSV, contacts/recents, display settings |
| **P2** | ~22 features | 2–4 sprints | Junction view, traffic overlay, OBD2 extended, CarPlay, parking save, weather API, offline maps, HD Radio, plasmacluster |
| **P3** | ~14 features | Future | SMS display, Track mode, g-meter, route reporting, OTA (backlog), stock/sports Travel Link |

**Biggest single gap:** The upper screen has no real map — everything else in navigation depends on this. That's the P1 blocker for ~12 navigation sub-features.

**Easiest P1 wins that don't require map work:**
- AUTO / MAX A/C / SYNC / heated steering wheel buttons in ClimateView (CAN sends, QML trivial)
- TPMS 4-corner display (1 CAN PID per wheel)
- Trip computer A/B (CAN PIDs for odometer, instantaneous MPG, avg MPG)
- Bass/Treble/Balance/Fade EQ sliders in AudioView (DSP CAN/I2C command)
- Contacts + recent calls in PhoneView (PBAP BT profile pull)
- Settings screen (display brightness, clock, units — pure QML, no CAN needed)
- Driver aids toggle grid (CAN on/off for BSW/LDW/LDP/FEB/PFCW)

---

## Sources Consulted

- [2017 Infiniti Q60 Owner's Manual (Infiniti USA)](https://www.infinitiusa.com/content/dam/Infiniti/US/manuals_guides/q60_coupe/2017/2017-infiniti-q60-coupe-owner-manual.pdf)
- [2017 Infiniti InTouch Navigation Owner's Manual](https://admin.owners.infinitiusa.com/content/manualsandguides/common/2017/2017-infiniti-InTouch-navi-manual.pdf)
- [2017 Q60 Quick Reference Guide](https://admin.owners.infinitiusa.com/content/manualsandguides/Q60_Coupe/2017/2017-q60-coupe-quick-reference-guide.pdf)
- [Infiniti InTouch Features & Apps](https://www.infinitiusa.com/intouch/features-apps.html)
- [SiriusXM Traffic Feature (Infiniti)](https://www.infinitiusa.com/intouch/features-apps/siriusxm-traffic.html)
- [SiriusXM Travel Link — Weather, Fuel, Sports, Stocks, Movies](https://www.infinitiusa.com/intouch/features/siriusxm/navtraffic)
- [Bose Performance Series in Q60 (Bose pressroom)](https://www.bose.com/pressroom/bose-performance-series-sound-system-debuts-in-2017-infiniti-q60-sports-coupe)
- [Around View Monitor with MOD (Infiniti USA)](https://www.infinitiusa.com/infiniti-news/technology/around-view-monitor.html)
- [Rain-Sensing Wiper System (InfinitiManuals.org)](https://www.infiguide.com/infodata-288.html)
- [Q50 Rain Sensing Wiper Forum Thread](https://www.infinitiq50.org/threads/ok-i-give-up-how-do-i-use-my-automatic-rain-sensing-wipers.132085/)
- [Drive Mode Selector — Q60 Forums](https://www.infinitiq60.org/threads/drive-mode-selector-observation.7833/)
- [Personal Mode Configuration — Q50 Forums](https://www.infinitiq50.org/threads/personal-mode-steering-adjustments.5394/)
- [Hands-free Text Messaging (Sawgrass Infiniti)](https://www.sawgrassinfiniti.com/text-messaging-infiniti-vehicles.html)
- [Infiniti InTouch Navigation Features (autosofdallas.com)](https://www.autosofdallas.com/blog/how-to-use-the-infiniti-intouch-navigation-system-and-features/)
- [2017 Q60 Specs & Trims (Carbuzz)](https://carbuzz.com/cars/infiniti/q60/2017/specs-and-trims/)
- [Bose Automotive Q60 page](https://automotive.bose.com/vehicles/infiniti/q60)
- [Audio Settings thread — Q60 Forums](https://www.infinitiq60.org/forum/electronics/6489-audio-settings.html)
- [SiriusXM 4-year trial for 2017 MY (PR Newswire)](https://www.prnewswire.com/news-releases/nissan-and-infiniti-customers-to-receive-multi-year-subscription-to-siriusxm-traffic-and-siriusxm-travel-link-on-select-vehicles-starting-with-model-year-2017-300314107.html)
