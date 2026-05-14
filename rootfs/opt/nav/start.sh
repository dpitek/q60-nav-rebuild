#!/bin/sh
# Q60 Nav — startup script
# Runs after CAN bus init, Wayland compositor start, and rcS tmpfs setup.
#
# IMPORTANT: do NOT use `set -e` at the top — every fallible command must be
# guarded individually. A failure anywhere here means q60nav never launches,
# the boot counter increments, and after 2 attempts slot A gets restored.
# We tolerate hardware-missing failure modes (bench boots, missing CAN, no
# DENSO daemons) and still reach the q60nav exec.

LOG=/var/log/nav.log
exec >> "$LOG" 2>&1

echo "[$(date)] Starting Q60 Nav boot sequence..."

# =============================================================================
# BOOT SAFETY: FAT32 boot counter (gracefully degrade if /boot not writable)
# If we fail to reach successful app launch twice in a row, auto-restore logan1
# =============================================================================
COUNT_FILE="/boot/q60_boot_attempts"
count=0

if mountpoint -q /boot 2>/dev/null && [ -w /boot ]; then
    count=$(cat "$COUNT_FILE" 2>/dev/null || echo 0)

    if [ "$count" -ge 2 ]; then
        echo "[$(date)] BOOT SAFETY: $count failed attempts detected. Restoring logan1..."
        if [ -w /boot/elilo.conf ]; then
            sed -i 's/^default=.*/default=logan1/' /boot/elilo.conf 2>/dev/null
            rm -f "$COUNT_FILE"
            sync
            echo "[$(date)] elilo.conf restored to default=logan1. Rebooting to original firmware."
            reboot -f
        else
            echo "[$(date)] BOOT SAFETY: /boot/elilo.conf not writable — cannot auto-restore; clearing counter."
            rm -f "$COUNT_FILE" 2>/dev/null
        fi
    fi

    echo $((count + 1)) > "$COUNT_FILE" 2>/dev/null
    sync 2>/dev/null
    echo "[$(date)] Boot attempt $((count + 1)) recorded."
else
    echo "[$(date)] /boot not writable — boot counter disabled (persistent revert disabled)"
fi

# =============================================================================
# Hardware watchdog
# q60nav opens /dev/watchdog itself (see WatchdogService in main.cpp) and
# pets it on a 5s QTimer. start.sh does not arm it — the kernel watchdog
# driver is loaded by rcS modprobe (ie6xx_wdt), but the timer only starts
# when something open()s the device. Letting q60nav own the fd keeps the
# armed-but-unfed window tight.
# =============================================================================
if [ -e /dev/watchdog ]; then
    echo "[$(date)] /dev/watchdog present — q60nav will own watchdog feeding"
else
    echo "[$(date)] WARNING: /dev/watchdog not found — no hardware watchdog (kernel module not loaded?)"
fi

# =============================================================================
# CAN BUSES — graceful fallback if interfaces missing (bench boot)
# CAN drivers come from pch_can / mcp251x (rcS modprobe). Bus bitrates:
#   can0 = 500 kbps HS-CAN (powertrain, BCM, HVAC)
#   can1 = 500 kbps AV-CAN (Bose, SXM, SW buttons)
#   can2 = 125 kbps MS-CAN (body bus) — NOT 250 kbps
# S05-capture-bootstrap may have already brought these up; if so the
# `ip link show ... up` test returns truthy and we skip.
# =============================================================================
bring_up_can() {
    local iface=$1 rate=$2
    if ! ip link show "$iface" >/dev/null 2>&1; then
        echo "[$(date)] $iface not present (bench boot?) — skipping"
        return
    fi
    if ip link show "$iface" up >/dev/null 2>&1; then
        echo "[$(date)] $iface already up — skipping"
        return
    fi
    ip link set "$iface" type can bitrate "$rate" restart-ms 100 2>/dev/null && \
        ip link set "$iface" up 2>/dev/null && \
        echo "[$(date)] Brought up $iface @ ${rate}bps" || \
        echo "[$(date)] WARNING: $iface bring-up failed — proceeding anyway"
}
bring_up_can can0 500000
bring_up_can can1 500000
bring_up_can can2 125000

# =============================================================================
# DENSO PROXY DAEMONS — guarded so missing binaries don't block boot
# These are factory closed-source proxies that may or may not be present on
# a fresh slot B (the rootfs builder skips them if absent). q60nav still
# runs without them — it just won't have SXM/sound passthrough.
# =============================================================================
launch_denso() {
    local bin=$1
    if [ -x "$bin" ]; then
        "$bin" >/dev/null 2>&1 &
        echo "[$(date)] Launched $bin (PID $!)"
    fi
}
launch_denso /opt/denso/bin/sxmcgs.out
launch_denso /opt/denso/bin/sxmfc.out
launch_denso /opt/denso/bin/radiofc.out
launch_denso /opt/denso/bin/sound.out
launch_denso /opt/denso/bin/vcan.out

# =============================================================================
# WAYLAND COMPOSITOR
# =============================================================================
if timeout 10 sh -c 'until [ -S /run/wayland-0 ]; do sleep 0.5; done' 2>/dev/null; then
    echo "[$(date)] Wayland ready at /run/wayland-0"
    export WAYLAND_DISPLAY=wayland-0
    export QT_QPA_PLATFORM=wayland
else
    echo "[$(date)] WARNING: Wayland not ready within 10s — falling back to linuxfb"
    export QT_QPA_PLATFORM=linuxfb
fi

# =============================================================================
# LAUNCH Q60NAV
# =============================================================================
export QT_QUICK_BACKEND=software
export QSG_RENDER_LOOP=basic
export XDG_RUNTIME_DIR=/run

# ── Mesa / MapLibre GL (software renderer) ────────────────────────────────
# Required for HeadlessFrontend EGL pbuffer via Mesa swrast.
# libEGL.so + swrast_dri.so must be present at these paths.
export LD_LIBRARY_PATH=/opt/nav/lib:/usr/lib/i386-linux-gnu:$LD_LIBRARY_PATH
export LIBGL_DRIVERS_PATH=/opt/nav/lib/dri
export EGL_PLATFORM=surfaceless
export MESA_GL_VERSION_OVERRIDE=3.3
export MESA_GLSL_VERSION_OVERRIDE=330
export GALLIUM_DRIVER=softpipe           # Atom Bonnell lacks SSE4 — softpipe (not llvmpipe)

# ── Per-process limits ────────────────────────────────────────────────────
# Cap virtual address space at 512MB to give the rest of the system breathing
# room. q60nav typically holds ~200MB RSS; the cap prevents a runaway leak
# from triggering OOM-kill on other processes (Valhalla, Weston, daemons).
ulimit -v 524288 2>/dev/null || true
# Disable core dumps (eMMC writes + uninvited storage burn)
ulimit -c 0 2>/dev/null || true

echo "[$(date)] All pre-launch checks passed."

# Boot-counter clearer: 30s liveness probe. If q60nav is still alive, we're
# past the startup-crash window — clear the counter so a benign future reboot
# doesn't trip the slot-A revert.
(
    sleep 30
    if pgrep -x q60nav >/dev/null 2>&1 && mountpoint -q /boot 2>/dev/null && [ -w /boot ]; then
        rm -f "$COUNT_FILE" 2>/dev/null
        sync
        echo "[$(date)] q60nav survived 30s — boot counter cleared"
    elif ! pgrep -x q60nav >/dev/null 2>&1; then
        echo "[$(date)] q60nav DIED within 30s — boot counter left intact (attempt $((count + 1)))"
    fi
) &

echo "[$(date)] Launching q60nav..."
exec /opt/nav/bin/q60nav
