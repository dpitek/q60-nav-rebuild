#!/bin/sh
# modem-connect.sh — LTE bring-up script
# Called by modem-connect.service on boot (and by modem-reconnect.service on link loss).
#
# Two modes (set via /opt/nav/config/config.json → "modem.tcu_mode"):
#
#   tcu_mode=true  — Q60 2021-2022, Continental BL28NA003
#     TCU self-manages the LTE connection.  DCU sees a USB RNDIS adapter.
#     This script just brings up the interface and requests DHCP.
#     No ModemManager required.
#
#   tcu_mode=false — Q60 2017-2020 (dead 3G, needs external modem) or aftermarket
#     Full ModemManager flow: detect modem → unlock SIM → connect → DHCP.
#     Modem USB VID:PID: comment in the correct rule in 99-lte-modem.rules.
#
# To identify which Q60 you have:
#   lsusb | grep -i "continental\|sierra\|quectel\|telit\|huawei"
#   2021-2022 Continental BL28NA003: VID unknown — appears as RNDIS net device
#   Check 'dmesg | grep rndis' or 'ip link' after boot

set -e

CONFIG=/opt/nav/config/config.json
LOG_TAG="q60-modem"

log() { logger -t "$LOG_TAG" "$*"; echo "[modem-connect] $*"; }

# ── Read config ──────────────────────────────────────────────────────────────
TCU_MODE=$(python3 -c "import json; c=json.load(open('$CONFIG')); print(str(c['modem'].get('tcu_mode', False)).lower())" 2>/dev/null || echo "false")
TCU_IFACE=$(python3 -c "import json; c=json.load(open('$CONFIG')); print(c['modem'].get('tcu_interface','usb0'))" 2>/dev/null || echo "usb0")
MODEM_IFACE=$(python3 -c "import json; c=json.load(open('$CONFIG')); print(c['modem'].get('interface','wwan0'))" 2>/dev/null || echo "wwan0")
APN=$(python3 -c "import json; c=json.load(open('$CONFIG')); print(c['modem'].get('apn',''))" 2>/dev/null || echo "")
PIN=$(python3 -c "import json; c=json.load(open('$CONFIG')); print(c['modem'].get('pin',''))" 2>/dev/null || echo "")

# ════════════════════════════════════════════════════════════════════════════════
# TCU MODE — Continental BL28NA003 (2021-2022 Q60)
# TCU handles all cellular management.  We just claim DHCP on the RNDIS interface.
# ════════════════════════════════════════════════════════════════════════════════
if [ "$TCU_MODE" = "true" ]; then
    log "TCU mode: Continental BL28NA003 — interface: $TCU_IFACE"

    # Wait for TCU RNDIS interface to appear (it takes a few seconds after USB enum)
    RETRIES=20
    while [ $RETRIES -gt 0 ]; do
        ip link show "$TCU_IFACE" > /dev/null 2>&1 && break
        log "Waiting for $TCU_IFACE... ($RETRIES)"
        sleep 2
        RETRIES=$((RETRIES - 1))
    done

    if ! ip link show "$TCU_IFACE" > /dev/null 2>&1; then
        log "ERROR: TCU interface $TCU_IFACE not found. Check USB connection + tcu_interface in config.json."
        log "       Run 'ip link' to see available interfaces."
        exit 1
    fi

    ip link set "$TCU_IFACE" up 2>/dev/null || true
    log "Requesting DHCP from TCU on $TCU_IFACE..."

    udhcpc -i "$TCU_IFACE" -t 10 -T 3 -q 2>/dev/null || \
    dhclient -v "$TCU_IFACE" 2>/dev/null || \
    log "WARN: DHCP failed — TCU may not be ready yet (reconnect will retry)"

    sleep 2
    # Probe the DHCP gateway — no external IP required
    GW=$(ip route | awk '/default/ {print $3; exit}')
    if [ -n "$GW" ] && ping -c 1 -W 5 "$GW" > /dev/null 2>&1; then
        IP=$(ip -4 addr show "$TCU_IFACE" 2>/dev/null | grep 'inet ' | awk '{print $2}')
        log "TCU online. IP: $IP (LTE via InfinitiConnect)"
    else
        log "WARN: No gateway response yet — TCU may still be registering on network"
    fi

    log "modem-connect (TCU mode) done"
    exit 0
fi

# ════════════════════════════════════════════════════════════════════════════════
# MODEM MODE — External / aftermarket LTE modem via ModemManager
# ════════════════════════════════════════════════════════════════════════════════
log "Modem mode: external LTE modem — interface: $MODEM_IFACE  APN: ${APN:-<not set>}"

# ── Wait for ModemManager to detect modem ───────────────────────────────────
RETRIES=30
while [ $RETRIES -gt 0 ]; do
    MODEM_INDEX=$(mmcli -L 2>/dev/null | grep -o '/Modems/[0-9]*' | grep -o '[0-9]*' | head -1)
    [ -n "$MODEM_INDEX" ] && break
    log "Waiting for modem... ($RETRIES retries left)"
    sleep 2
    RETRIES=$((RETRIES - 1))
done

if [ -z "$MODEM_INDEX" ]; then
    log "ERROR: No modem detected after 60 seconds. Check USB connection + udev rules."
    exit 1
fi

log "Modem detected at index $MODEM_INDEX"

# ── Unlock SIM if PIN set ────────────────────────────────────────────────────
if [ -n "$PIN" ]; then
    log "Sending SIM PIN..."
    mmcli -m "$MODEM_INDEX" --pin="$PIN" || log "WARN: PIN unlock failed (may already be unlocked)"
fi

# ── Enable modem ─────────────────────────────────────────────────────────────
mmcli -m "$MODEM_INDEX" --enable || true
sleep 2

# ── Connect ──────────────────────────────────────────────────────────────────
if [ -n "$APN" ]; then
    log "Connecting with APN: $APN"
    mmcli -m "$MODEM_INDEX" --simple-connect="apn=$APN,ip-type=ipv4"
else
    log "Connecting without APN (carrier may auto-assign)"
    mmcli -m "$MODEM_INDEX" --simple-connect="ip-type=ipv4"
fi

# ── Bring up network interface ───────────────────────────────────────────────
sleep 3
ip link set "$MODEM_IFACE" up 2>/dev/null || true

if ip link show "$MODEM_IFACE" > /dev/null 2>&1; then
    log "Running DHCP on $MODEM_IFACE..."
    udhcpc -i "$MODEM_IFACE" -t 10 -T 3 -q 2>/dev/null || \
    dhclient -v "$MODEM_IFACE" 2>/dev/null || \
    log "WARN: DHCP failed — interface may use static IP from bearer"
fi

# ── Verify — probe gateway only, no external IP ──────────────────────────────
sleep 2
GW=$(ip route | awk '/default/ {print $3; exit}')
if [ -n "$GW" ] && ping -c 1 -W 5 "$GW" > /dev/null 2>&1; then
    IP=$(ip -4 addr show "$MODEM_IFACE" 2>/dev/null | grep 'inet ' | awk '{print $2}')
    log "LTE connected. IP: $IP"
else
    log "WARN: No gateway response — data path may still be initialising"
fi

# ── Write signal info for NetworkService to read ─────────────────────────────
mmcli -m "$MODEM_INDEX" --output-keyvalue 2>/dev/null > /run/q60-modem-status || true

log "modem-connect done"
