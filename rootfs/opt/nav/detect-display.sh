#!/bin/sh
# detect-display.sh — Probe /sys/class/drm for connected connectors
# Outputs one connector name per line, primary first.
# Fallback: prints "LVDS-1" if nothing found or DRM not available.
#
# Designed for busybox sh on the Q60 DCU (Linux 4.19, i386).
# POSIX sh only — no bashisms.
#
# IMPORTANT (factory-version-baseline confirmation 2026-05-14):
# The lower 7" display has its OWN controller firmware (HW=000000 SW=020024)
# per Version Info page 6/8. That likely means the two screens enumerate on
# SEPARATE DRM cards — card0-LVDS-1 (upper, gma500) and card1-XXX-1 (lower,
# whichever bridge driver). The `for entry in "$DRM_BASE"/card*-*` glob below
# already enumerates BOTH cards correctly. We strip the card prefix in the
# output because Weston's [output] section uses the connector name only.

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
