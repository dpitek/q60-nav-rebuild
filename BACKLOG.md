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
