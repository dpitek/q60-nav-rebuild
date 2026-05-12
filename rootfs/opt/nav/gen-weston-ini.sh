#!/bin/sh
# gen-weston-ini.sh — Dynamically generate /etc/xdg/weston/weston.ini
# based on connected DRM connectors detected at boot time.
#
# - Calls detect-display.sh to enumerate connected connectors
# - Writes to /tmp/weston.ini, then copies to /etc/xdg/weston/weston.ini
# - Falls back to /etc/xdg/weston/weston.ini.default if DRM unavailable
#
# POSIX sh only. Runs on busybox. Designed for Q60 DCU (Linux 4.19, i386).

set -e

DETECT=/opt/nav/detect-display.sh
WESTON_INI=/etc/xdg/weston/weston.ini
WESTON_DEFAULT=/etc/xdg/weston/weston.ini.default
TMP_INI=/tmp/weston.ini

# ── Fallback: no DRM subsystem present ──────────────────────────────────────
if [ ! -d /sys/class/drm ]; then
    echo "[gen-weston-ini] No /sys/class/drm — using static default"
    if [ -f "$WESTON_DEFAULT" ]; then
        cp "$WESTON_DEFAULT" "$WESTON_INI"
        echo "[gen-weston-ini] Copied $WESTON_DEFAULT -> $WESTON_INI"
    else
        echo "[gen-weston-ini] WARNING: $WESTON_DEFAULT not found, leaving $WESTON_INI unchanged"
    fi
    exit 0
fi

# ── Run connector probe ──────────────────────────────────────────────────────
if [ ! -x "$DETECT" ]; then
    echo "[gen-weston-ini] WARNING: $DETECT not executable — using static default"
    [ -f "$WESTON_DEFAULT" ] && cp "$WESTON_DEFAULT" "$WESTON_INI"
    exit 0
fi

connectors=$("$DETECT")

if [ -z "$connectors" ]; then
    echo "[gen-weston-ini] No connectors detected — using static default"
    [ -f "$WESTON_DEFAULT" ] && cp "$WESTON_DEFAULT" "$WESTON_INI"
    exit 0
fi

primary=$(echo "$connectors" | sed -n '1p')
secondary=$(echo "$connectors" | sed -n '2p')

echo "[gen-weston-ini] Primary connector: $primary"
[ -n "$secondary" ] && echo "[gen-weston-ini] Secondary connector: $secondary"

# ── Write weston.ini to /tmp first ──────────────────────────────────────────
cat > "$TMP_INI" << WESTON_EOF
[core]
# DRM backend for Intel GMA 500 (PowerVR SGX 535 stub) on Atom E6xx
# Mesa software render via llvmpipe/swrast since no PowerVR driver
backend=drm-backend.so
repaint-window=16
idle-time=0
require-input=false

[output]
# Primary display — 8" display (800x480)
# Connector auto-detected at boot: $primary
name=$primary
mode=800x480
transform=normal
WESTON_EOF

if [ -n "$secondary" ]; then
    cat >> "$TMP_INI" << WESTON_EOF

[output]
# Secondary display — 7" display (800x480)
# Connector auto-detected at boot: $secondary
name=$secondary
mode=800x480
transform=normal
WESTON_EOF
fi

cat >> "$TMP_INI" << 'WESTON_EOF'

[shell]
# No desktop shell — q60nav is the only client
panel-position=none
locking=false
startup-animation=none

[keyboard]
# No physical keyboard
WESTON_EOF

# ── Copy to live location ────────────────────────────────────────────────────
mkdir -p /etc/xdg/weston
cp "$TMP_INI" "$WESTON_INI"
echo "[gen-weston-ini] Wrote $WESTON_INI (primary=$primary${secondary:+, secondary=$secondary})"
