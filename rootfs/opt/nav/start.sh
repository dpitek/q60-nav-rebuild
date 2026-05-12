#!/bin/sh
# Q60 Nav — startup script
# Runs after CAN bus is up (via udev) and Wayland compositor starts

set -e
LOG=/var/log/nav.log
exec >> $LOG 2>&1

echo "[$(date)] Starting Q60 Nav boot sequence..."

# =============================================================================
# BOOT SAFETY: FAT32 boot counter
# If we fail to reach successful app launch twice in a row, auto-restore logan1
# =============================================================================
COUNT_FILE="/boot/q60_boot_attempts"
count=$(cat "$COUNT_FILE" 2>/dev/null || echo 0)

if [ "$count" -ge 2 ]; then
    echo "[$(date)] BOOT SAFETY: $count failed attempts detected. Restoring logan1..."
    sed -i 's/^default=.*/default=logan1/' /boot/elilo.conf
    rm -f "$COUNT_FILE"
    sync
    echo "[$(date)] elilo.conf restored to default=logan1. Rebooting to original firmware."
    reboot -f
fi

echo $((count + 1)) > "$COUNT_FILE"
sync
echo "[$(date)] Boot attempt $((count + 1)) recorded."

# =============================================================================
# ARM iTCO WATCHDOG
# Open /dev/watchdog to arm hardware watchdog (30s timeout)
# q60nav will pet it via /dev/watchdog while running
# =============================================================================
if [ -e /dev/watchdog ]; then
    echo "[$(date)] iTCO watchdog armed (30s timeout)"
    # Writing to watchdog arms it; q60nav must keep writing to prevent reset
else
    echo "[$(date)] WARNING: /dev/watchdog not found — no hardware watchdog"
fi

# =============================================================================
# CAN BUSES
# =============================================================================
for iface in can0 can1; do
    ip link show $iface up 2>/dev/null || {
        ip link set $iface type can bitrate 500000 restart-ms 100
        ip link set $iface up
        echo "[$(date)] Brought up $iface"
    }
done
ip link show can2 up 2>/dev/null || {
    ip link set can2 type can bitrate 250000 restart-ms 100
    ip link set can2 up
    echo "[$(date)] Brought up can2 (250kbps)"
}

# =============================================================================
# DENSO PROXY DAEMONS — keep existing hardware interfaces alive
# =============================================================================
/opt/denso/bin/sxmcgs.out &
/opt/denso/bin/sxmfc.out &
/opt/denso/bin/radiofc.out &
/opt/denso/bin/sound.out &
/opt/denso/bin/vcan.out &
echo "[$(date)] DENSO proxy daemons started"

# =============================================================================
# WAYLAND COMPOSITOR
# =============================================================================
timeout 10 sh -c 'until [ -S /run/wayland-0 ]; do sleep 0.5; done' || {
    echo "[$(date)] WARNING: Wayland compositor not ready, falling back to fb"
    export QT_QPA_PLATFORM=linuxfb
}

# =============================================================================
# LAUNCH Q60NAV
# Clear boot counter on successful launch
# =============================================================================
export WAYLAND_DISPLAY=wayland-0
export QT_QPA_PLATFORM=wayland
export QT_QUICK_BACKEND=software
export QSG_RENDER_LOOP=basic
export XDG_RUNTIME_DIR=/run

# ── Mesa / MapLibre GL (software renderer) ────────────────────────────────
# Required for HeadlessFrontend EGL pbuffer via Mesa swrast.
# libEGL.so + swrast_dri.so must be present at these paths (from Qt6 build
# or Mesa package). If absent, MapLibreItem falls back to placeholder grid.
export LD_LIBRARY_PATH=/opt/nav/lib:/usr/lib/i386-linux-gnu:$LD_LIBRARY_PATH
export LIBGL_DRIVERS_PATH=/opt/nav/lib/dri
export EGL_PLATFORM=surfaceless          # headless EGL — no display server needed
export MESA_GL_VERSION_OVERRIDE=3.3      # swrast may report GL 2.1; mbgl needs 3.x
export MESA_GLSL_VERSION_OVERRIDE=330
export GALLIUM_DRIVER=softpipe           # force softpipe (Atom has no llvmpipe support)

echo "[$(date)] All pre-launch checks passed. Clearing boot counter."
rm -f "$COUNT_FILE"
sync

echo "[$(date)] Launching q60nav..."
exec /opt/nav/bin/q60nav
