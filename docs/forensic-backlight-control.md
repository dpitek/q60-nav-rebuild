# Forensic — LVDS Backlight / Panel Power Control

**Date:** 2026-05-23
**Mission:** Find what enables the upper LVDS backlight on the Q60 DCU (Clarion QY5092, Atom E6xx, EMGD 1.5.15.3226, MeeGo 1.2 + Wind River, kernel 2.6.37, systemd PID 1) so our Plan B''' spike can either wait for it or trigger it earlier than t≈75 s.

---

## TL;DR

**Backlight is controlled by `display_ps` (or `dispapf_proc` / `hmictrl_proc`), via standard Linux `/sys/class/gpio/` after `setgpio.ko` pin-muxes the panel-enable lines at boot.**

The 75-second visibility delay is **NOT** caused by `nav_dmsg_start.service`'s `usleep 75000000` — that's a dmesg-capture timer (red herring). The real gate is the systemd dependency chain:

```
sysinit  →  home-naviwork.mount  →  nav_before  →  nav_init  →  nav_smng  →  nav_pre.target  →  display_ps / dispapf_proc / hmictrl_proc  →  panel-on
```

`display_ps` etc. live on `/home/naviwork/system/bin/*` (separate ext4 partition NOT extracted into Slot A), so the panel-on byte sequence cannot be conclusively recovered without mounting that filesystem. **This is the next-step gap** — see "Open question" below.

**To enable from our spike at t≈15 s (estimated, not yet verified):**

```sh
# Step 1 — make sure setgpio.ko is loaded (it is, via /etc/modules-load.d/modules.conf)
lsmod | grep setgpio   # confirm pin-mux is configured

# Step 2 — find the panel-enable GPIO by walking /sys/class/gpio
ls /sys/class/gpio/                          # gpiochip0=IOH ML7213, gpiochip1=Tunnel Creek
cat /sys/class/gpio/gpiochip*/label
cat /sys/class/gpio/gpiochip*/base
cat /sys/class/gpio/gpiochip*/ngpio

# Step 3 — export + drive every plausible panel-enable line and watch the screen
for n in <list-from-step-2>; do
  echo $n > /sys/class/gpio/export 2>/dev/null
  echo out > /sys/class/gpio/gpio$n/direction 2>/dev/null
  echo 1   > /sys/class/gpio/gpio$n/value    2>/dev/null
done
# Then visually note which combo lights the panel.
```

We do NOT yet know which GPIO line is panel-enable — that's what the on-car spike must discover. The `setgpio` driver exports the standard `gpiolib` interface (it calls `gpio_request`, `__gpio_set_value`, `gpio_direction_output`), so `/sys/class/gpio/` is the universally correct surface once the module is loaded.

---

## Evidence

### 1. `/sys/class/backlight/` is empty — confirmed at runtime (spike 3)
No standard Linux backlight class. Control is GPIO-based, not PWM-class-based. EMGD 1.5.x does not register a backlight class device.

### 2. `/sys/class/drm/` only shows `card0`, `ttm`, `version` — no connectors
EMGD doesn't expose KMS connectors, so there is no `/sys/class/drm/card0-LVDS-1/enabled` lever either.

### 3. setgpio.ko is the GPIO bootstrap — but NOT a runtime control surface

Path: `/lib/modules/2.6.37.6-35.1_DLK0040-android-intel-crossville_lapis-fastboot/kernel/bsp/setgpio/setgpio.ko`

Loaded at boot via `/etc/modules-load.d/modules.conf`:
```
ohci_hcd
setgpio    ← here
watchdog
bt_hci
cdc_tcu
capture_ctl
net_adp
```

ABI inspection (`objdump -t` + `strings`):
- **No** `register_chrdev`, `misc_register`, `class_create`, `device_create`, `proc_create`, `sysfs_create_*`.
- **No** `unlocked_ioctl`, `fops`, or netlink hooks.
- Functions: `setgpio_init`, `setgpio_exit`, `setgpio_ioh_pinmux`, `setgpio_get_ioh_base`, `setqos_ioh_param`, `setgpio_tc_enable`, `setgpio_get_tc_base`, `setgpio_control`, `setgpio_ctl_set_value`, `setgpio_ctl_direction_input`, `setgpio_ctl_direction_output`.
- Embedded REGDATA table (in `.rodata`): writes `GPIO_USE_SEL0..3_register` on the Tunnel Creek LPC GPIO block to pin-mux the GPIOs into GPIO mode (vs alternate function), then configures direction/initial value.
- Imports standard gpiolib symbols: `gpio_request`, `__gpio_set_value`, `gpio_direction_input`, `gpio_direction_output`, `gpio_free`.

Strings call out the GPIO controllers it programs:
- **Tunnel Creek SoC GPIOs:** `TC_GPIO_0..4`, `TC_GPIOSUS_0..8`
- **LAPIS ML7213 IOH (I/O Hub) GPIOs:** `IOH_GPIO0_0..5`, `IOH_GPIO1_0..3`, `IOH_GPIO1_10`, `IOH_GPIO3_12..14`

Comments inside strings: `Core Well GPIO Enable`, `Resume Well GPIO Enable` — Intel chipset terms for power-domain partitioning. These are pin-mux settings, not panel control.

**Conclusion:** setgpio.ko's only job is to pin-mux + initial-state these GPIOs at insmod time. After it loads, all subsequent control happens via the standard kernel gpiolib (`/sys/class/gpio/exportN`, `/sys/class/gpio/gpioN/value`, etc.) or via in-kernel callers (other drivers / firmware).

### 4. emgdhmid does NOT control backlight

Path: `/usr/sbin/emgdhmid` (the EMGD HMI daemon, DRM-master holder, "do not kill")

Full strings scan for backlight/panel/igd_port/igd_dc/sysfs/gpio: **only two `/dev/*` paths exist** —
```
/dev/v2gbridge
/dev/video0
```

No panel-enable, no GPIO, no I2C, no backlight ioctls. emgdhmid is the EGL/HMI compositor master — it composites surfaces but does NOT power the panel.

Same scan on `libemgdsrv_init.so.1.5.15.3226` and `libemgdsrv_um.so.1.5.15.3226`: zero hits on backlight/panel/pwm/lvds/lcd terms. EMGD configures display modes but leaves panel-power assertion to platform code.

### 5. The 75-second timer is a DMESG CAPTURE delay, not a panel gate

`/lib/systemd/system/nav_dmsg_start.service`:
```
[Service]
Type=simple
#Wait timer Android start up 75sec
ExecStartPre=/bin/usleep 75000000
ExecStart=-/bin/sh /lib/systemd/system/systemdRelatedFiles/dmesg_start.sh
```

The comment "Wait timer Android start up 75sec" tells us this is a passive observer: it waits for Android-side init to finish before snapshotting dmesg. **The panel is on by then; the timer doesn't cause anything to happen.**

This is the **only `*sleep N*` of any consequence** in `/lib/systemd/system/*.service`:
```
emgdhmi-test.service:    ExecStartPre=/bin/usleep 20000      (20 ms)
nav_dmsg_start.service:  ExecStartPre=/bin/usleep 75000000   (75 s — dmesg cap)
pulseaudio-usbsink:      ExecStartPre=/bin/sleep 3           (audio)
pulseaudio.service:      ExecStart=/bin/usleep 3000000       (audio)
```

### 6. The real dependency chain to first paint

```
graphical.target.wants/
  ├─ nav_before.service          (oneshot, RemainAfterExit; runs rename.sh)
  ├─ nav_init.service            (oneshot; mkdir /dev/shm/LEGRES)
  ├─ nav_driver.service          (oneshot; bt_dfu_inst.sh, dac_reset.sh)
  ├─ nav_smng.service            (smng "PS_OS01"  — orchestrator; on /home/naviwork)
  └─ basic.target.wants/
       └─ emgdhmid.service       (the EMGD compositor; needs DRM master)

nav_early.target.wants/
  └─ nav_ioapf.service           (ioapf_proc "PS_IOAPF" — I/O App Framework; on /home/naviwork)

nav_pre.target.wants/
  ├─ nav_dispapf.service         (dispapf_proc "PS_DISPAPF" — display App Framework)
  ├─ nav_display.service         (display_ps "PS_DISPLAY"   — display Process Server)
  ├─ nav_hmictrl.service         (hmictrl_proc "PS_HMIC1"   — HMI Controller)
  ├─ nav_navi.service            (navi_ps      "PS_NAVI"    — navigation Process Server)
  ├─ nav_camera.service          (camera_ps    "PS_CAMERA"  — rearview camera / V2G bridge mgr)
  ├─ nav_initialscreen.service   (fis_ps       "PS_FIS"     — first/initial screen)
  └─ ... (audio, multimedia, ipod, etc.)
```

**Key fact:** every nav_pre-target process binary is at `/home/naviwork/system/bin/*` — a SEPARATE PARTITION (mountpoint `home-naviwork.mount`, mounted on demand via `home-naviwork.automount`). That partition is NOT in our Slot A extraction. We cannot grep those binaries here.

The candidate that turns on the panel is one of:
- **`display_ps`** (most likely — named "PS_DISPLAY", clearly owns the display) — OR —
- **`dispapf_proc`** (display Application Framework) — its sibling — OR —
- **`ioapf_proc`** (I/O Application Framework — fires in `nav_early`, BEFORE display_ps) — could own the raw I/O including GPIO writes.

`ioapf_proc` is the most architecturally natural place for panel-enable GPIO writes (it's an "I/O" framework and fires earlier than the display stack). `display_ps` probably issues a "turn on panel" RPC into ioapf_proc.

### 7. Spike 3 observation lines up

Per the mission brief: "killing all 4 painters (navi/dispapf/display/hmictrl) appears to delay or prevent panel-on." That's consistent with `display_ps` (or `dispapf_proc`) being the panel-power actor — killing them never lets the panel-on signal fire.

### 8. Dual-screen state

`portorder = 2,4,0,0,0` → upper LVDS (800×480) is port 2; lower (800×420) is SDVO port 4.

- **Upper LVDS** runs straight off the Tunnel Creek IGD LVDS interface — likely a single panel-enable GPIO (rail enable + backlight enable, may be the same line or two).
- **Lower display** is SDVO — going through an external transmitter chip (likely the LAPIS ML7213 IOH SDVO port, or a discrete SDVO-to-LVDS bridge on the carrier board). That chip has its OWN enable and probably its OWN backlight control (possibly I2C-managed, not GPIO).

For our Plan B''' spike, we only need the UPPER panel up to see the nav. Don't worry about the lower screen — different code path.

---

## Open question (the gap)

The byte-level sequence that turns the panel on (which GPIO number, what value, what timing, whether there's an I2C side-channel) lives in `display_ps` or `ioapf_proc` on `/home/naviwork/system/bin/`. To close this gap:

**Option A — extract /home/naviwork from the live system:**
```sh
# On the DCU, before /home/naviwork is busy:
tar czf /tmp/naviwork-bin.tgz /home/naviwork/system/bin /home/naviwork/system/lib
# Then ship to host and grep:
strings /home/naviwork/system/bin/display_ps | grep -iE 'gpio|backlight|panel|/sys/class|/dev/setgpio|i2c|bl_'
strings /home/naviwork/system/bin/ioapf_proc | grep -iE 'gpio|backlight|panel|/sys/class|/dev/setgpio|i2c|bl_'
```

**Option B — live observation on a working car boot:**
```sh
# Watch every /sys/class/gpio write while the panel comes on
# (run from android-mount.sh hook, before nav_pre.target fires):
inotifywait -mr /sys/class/gpio --format '%T %w%f %e' --timefmt '%T' &
strace -f -e trace=write -p $(pgrep ioapf_proc) 2>&1 | grep -i gpio &
```

**Option C — discovery spike (recommended — fastest):**
Modify our Plan B''' spike to enumerate `/sys/class/gpio/`, export every GPIO, drive it high, and visually watch when the panel lights up. Document the line that worked, then in the production version assert just that one. See "TL;DR step 3" above.

---

## What our spike should do RIGHT NOW

1. **Don't fight the existing order.** Wait for `setgpio.ko` to be loaded (it's in modules-load.d, fires from `systemd-modules-load.service` which is in `sysinit.target.wants` — happens within the first 1-2 seconds of systemd start, well before our spike's t≈14 s).
2. **Confirm at runtime** what `/sys/class/gpio/` looks like: which `gpiochip*` entries exist, their `label` and `base`/`ngpio`, what's already `export`ed by setgpio's table.
3. **Run the discovery spike (option C above)** — write GPIO values high one-by-one until the panel lights. This is a 10-minute experiment.
4. Once the panel-enable line is identified, the production spike just does:
   ```sh
   echo <N> > /sys/class/gpio/export
   echo out > /sys/class/gpio/gpio<N>/direction
   echo 1   > /sys/class/gpio/gpio<N>/value
   ```
   at t≈3 s and we get visible output 60+ seconds earlier than the factory.

---

## Caveats

- **DO NOT** assume the panel-enable is a single GPIO. It may be a sequence: VDD enable → wait → backlight PWM enable → wait → LVDS data enable. The factory likely has 50-200 ms of choreography. If a single GPIO toggle gives a partial image (e.g., dim, no backlight, image but pink due to LVDS sync timing), there are MORE pins to drive.
- **DO NOT** drive every GPIO simultaneously the first time. Drive them one at a time, watch for the panel response, then catalog. Random GPIO writes on this board can also (un)mute audio, reset the BT module, switch the camera input, or worse — toggle a reset line that crashes another chip. Do this with logs streaming.
- **DO NOT** assume an unloaded setgpio leaves the GPIOs in safe defaults. The kernel boots with pads in their EFI/BIOS-set state; setgpio sets them to "GPIO mode" + a known direction. If our test kernel doesn't load setgpio, the panel-enable pad may still be in an alt-function (e.g., LPC chip-select) and writing to `/sys/class/gpio/` won't reach it. **Spike pre-flight: confirm `lsmod | grep setgpio` returns a row before attempting GPIO writes.**

---

## Sources

- `/tmp/dsu-slot-a/lib/modules/2.6.37.6-35.1_DLK0040-android-intel-crossville_lapis-fastboot/kernel/bsp/setgpio/setgpio.ko` (objdump + strings)
- `/tmp/dsu-slot-a/etc/modules-load.d/modules.conf`
- `/tmp/dsu-slot-a/lib/systemd/system/*.service` (full systemd unit scan)
- `/tmp/dsu-slot-a/lib/systemd/system/nav_pre.target.wants/`, `nav_early.target.wants/`, `graphical.target.wants/`
- `/tmp/dsu-slot-a/usr/sbin/emgdhmid` + `/usr/lib/libemgd*.so.*` (strings)
- `/tmp/dsu-slot-a/lib/systemd/system/systemdRelatedFiles/Display_Tools/{drawbuf,drawbufd,display_color.sh}` (EMGD HMI test client — sanity check on EGL surface API)
- Cross-refs: `docs/forensic-emgd-init.md`, `docs/forensic-daemon-supervision.md`, `docs/forensic-factory-ui-binary.md`
