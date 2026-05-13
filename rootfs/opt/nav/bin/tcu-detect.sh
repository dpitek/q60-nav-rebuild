#!/bin/sh
# tcu-detect.sh — First-boot Continental TCU auto-detection
# Runs before modem-connect.service on every boot.
#
# What it does:
#   1. Scans /sys/class/net for any interface bound to rndis_host or cdc_ncm
#      (the drivers the Continental BL28NA003 uses over USB)
#   2. If found: writes tcu_mode=true + correct interface name into config.json
#              + patches udev rule with the specific USB VID:PID
#              + touches /opt/nav/.tcu-detected as a record
#   3. If not found: leaves config untouched (stays in modem mode)
#   4. If config already has tcu_mode=true: exits immediately (no-op)
#
# Runs every boot so it self-heals if USB wasn't ready on a previous boot.

set -e

CONFIG=/opt/nav/config/config.json
UDEV_RULES=/etc/udev/rules.d/99-lte-modem.rules
SENTINEL=/opt/nav/.tcu-detected
LOG_TAG="q60-tcu-detect"

log()  { logger -t "$LOG_TAG" "$*"; echo "[tcu-detect] $*"; }
warn() { logger -t "$LOG_TAG" "WARN: $*"; echo "[tcu-detect] WARN: $*"; }

# ── Already configured? ───────────────────────────────────────────────────────
CURRENT_MODE=$(python3 -c "
import json, sys
try:
    c = json.load(open('$CONFIG'))
    print(str(c['modem'].get('tcu_mode', False)).lower())
except Exception as e:
    print('false')
" 2>/dev/null || echo "false")

if [ "$CURRENT_MODE" = "true" ]; then
    log "TCU mode already configured — skipping detection"
    exit 0
fi

log "Scanning for Continental TCU (RNDIS/CDC-NCM USB network interface)..."

# Give USB enumeration a moment if we're very early in boot
sleep 3

# ── Scan net interfaces for RNDIS or CDC-NCM driver ──────────────────────────
TCU_IFACE=""
TCU_DRIVER=""

for SYS_IFACE in /sys/class/net/*/; do
    IFACE=$(basename "$SYS_IFACE")
    [ "$IFACE" = "lo" ] && continue

    DRIVER_LINK="$SYS_IFACE/device/driver"
    if [ -L "$DRIVER_LINK" ]; then
        DRIVER=$(readlink "$DRIVER_LINK" | xargs basename 2>/dev/null || echo "")
        if [ "$DRIVER" = "rndis_host" ] || [ "$DRIVER" = "cdc_ncm" ] || [ "$DRIVER" = "cdc_ether" ]; then
            TCU_IFACE="$IFACE"
            TCU_DRIVER="$DRIVER"
            log "Found TCU interface: $IFACE (driver: $DRIVER)"
            break
        fi
    fi
done

if [ -z "$TCU_IFACE" ]; then
    # Also check dmesg for rndis in case sysfs driver link isn't populated yet
    if dmesg 2>/dev/null | grep -qi "rndis_host\|cdc_ncm.*usb"; then
        warn "RNDIS activity in dmesg but interface not enumerated yet — will retry next boot"
    else
        log "No TCU detected (no rndis_host/cdc_ncm interface). Staying in modem mode."
    fi
    exit 0
fi

# ── Get USB VID:PID for this interface ───────────────────────────────────────
VID=""
PID=""

# udevadm is the cleanest source
if command -v udevadm > /dev/null 2>&1; then
    VID=$(udevadm info -q property "/sys/class/net/$TCU_IFACE" 2>/dev/null \
          | grep "^ID_VENDOR_ID=" | cut -d= -f2 | tr -d '[:space:]')
    PID=$(udevadm info -q property "/sys/class/net/$TCU_IFACE" 2>/dev/null \
          | grep "^ID_MODEL_ID=" | cut -d= -f2 | tr -d '[:space:]')
fi

# Fallback: walk sysfs USB device tree (net/usb0/device → USB interface → USB device)
if [ -z "$VID" ] && [ -L "/sys/class/net/$TCU_IFACE/device" ]; then
    USB_IF=$(readlink -f "/sys/class/net/$TCU_IFACE/device" 2>/dev/null || echo "")
    USB_DEV=$(dirname "$USB_IF")
    VID=$(cat "$USB_DEV/idVendor" 2>/dev/null | tr -d '[:space:]' || echo "")
    PID=$(cat "$USB_DEV/idProduct" 2>/dev/null | tr -d '[:space:]' || echo "")
fi

if [ -n "$VID" ] && [ -n "$PID" ]; then
    log "TCU USB VID:PID = $VID:$PID"
else
    warn "Could not read USB VID:PID — specific udev rule will not be added"
fi

# ── Update config.json ────────────────────────────────────────────────────────
log "Writing TCU config: tcu_mode=true, tcu_interface=$TCU_IFACE"

python3 << PYEOF
import json, sys

config_path = "$CONFIG"
try:
    with open(config_path, 'r') as f:
        config = json.load(f)
except Exception as e:
    print(f"[tcu-detect] ERROR reading config: {e}", file=sys.stderr)
    sys.exit(1)

config['modem']['tcu_mode']      = True
config['modem']['tcu_interface'] = "$TCU_IFACE"

# Preserve comments (they survive as-is since we're using json.dump on the parsed dict)
try:
    with open(config_path, 'w') as f:
        json.dump(config, f, indent=2)
    print("[tcu-detect] config.json updated successfully")
except Exception as e:
    print(f"[tcu-detect] ERROR writing config: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF

# ── Patch udev rule with specific VID:PID ────────────────────────────────────
if [ -n "$VID" ] && [ -n "$PID" ] && [ -f "$UDEV_RULES" ]; then
    log "Patching udev rule for $VID:$PID..."

    # Replace the placeholder commented rule with an active one
    # Pattern: the commented-out "Specific TCU rule" block
    sed -i \
        "s|# SUBSYSTEM==\"usb\", ATTRS{idVendor}==\"????\", ATTRS{idProduct}==\"????\".*|SUBSYSTEM==\"usb\", ATTRS{idVendor}==\"$VID\", ATTRS{idProduct}==\"$PID\", SYMLINK+=\"q60-tcu\", TAG+=\"systemd\", ENV{SYSTEMD_WANTS}=\"modem-connect.service\"|" \
        "$UDEV_RULES"

    udevadm control --reload-rules 2>/dev/null || true
    log "udev rules reloaded with VID:PID $VID:$PID"
fi

# ── Record detection ─────────────────────────────────────────────────────────
cat > "$SENTINEL" << EOF
tcu_detected=$(date -Iseconds)
interface=$TCU_IFACE
driver=$TCU_DRIVER
vid=$VID
pid=$PID
EOF

log "TCU detection complete. Interface: $TCU_IFACE | Driver: $TCU_DRIVER | USB: ${VID:-?}:${PID:-?}"
log "modem-connect.service will now run in TCU mode"
