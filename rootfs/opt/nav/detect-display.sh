#!/bin/sh
# detect-display.sh — Probe /sys/class/drm for connected connectors
# Outputs one connector name per line, primary first.
# Fallback: prints "LVDS-1" if nothing found or DRM not available.
#
# Designed for busybox sh on the Q60 DCU (Linux 4.19, i386).
# POSIX sh only — no bashisms.

set -e

DRM_BASE="/sys/class/drm"

if [ ! -d "$DRM_BASE" ]; then
    # No DRM subsystem — return safe default
    echo "LVDS-1"
    exit 0
fi

connected=""

for entry in "$DRM_BASE"/card*-*; do
    [ -e "$entry/status" ] || continue
    status=$(cat "$entry/status" 2>/dev/null) || continue
    if [ "$status" = "connected" ]; then
        name=$(basename "$entry" | sed 's/card[0-9]*-//')
        if [ -z "$connected" ]; then
            connected="$name"
        else
            connected="$connected
$name"
        fi
    fi
done

if [ -z "$connected" ]; then
    # No connected connectors detected — safe fallback
    echo "LVDS-1"
else
    echo "$connected"
fi
