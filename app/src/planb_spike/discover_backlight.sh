#!/bin/sh
# discover_backlight.sh
#
# Single-purpose: identify which /sys/class/gpio pin(s) the factory toggles
# to enable LVDS backlight on the Q60. Run once. Result tells us how to
# enable panels at t=15s in future spikes instead of waiting for nav_smng.
#
# Approach:
#   1. Snapshot value+direction of every exported GPIO at t=14s (panels off)
#   2. Poll every 2 seconds for 90 seconds (covering panel-on at ~75s)
#   3. On any change, log timestamp + GPIO# + old_value -> new_value
#   4. Final snapshot at t=90s for comparison
#   5. Also tail dmesg lines mentioning panel/lvds/backlight/lcd/gpio
#
# Does NOT kill any factory daemon. Pure observation.

WLOCK=/tmp/q60-disc.lock
[ -f "$WLOCK" ] && exit 0
echo $$ > "$WLOCK"

LOG=/tmp/q60-bl-discover.log
TRANSITIONS=/tmp/q60-bl-transitions.log

# Mount /boot
mountpoint -q /boot 2>/dev/null || mount /dev/mmcblk0p1 /boot 2>/dev/null
mountpoint -q /boot 2>/dev/null || mount /dev/mmcblk1p1 /boot 2>/dev/null

echo "=== Q60 backlight GPIO discovery ===" > "$LOG"
echo "start uptime=$(cat /proc/uptime)" >> "$LOG"
echo "" >> "$LOG"

# Helper: snapshot all exported GPIOs to a string "gpioN=v ..."
snapshot() {
    for d in /sys/class/gpio/gpio[0-9]*; do
        [ -d "$d" ] || continue
        n=$(basename "$d" | sed 's/gpio//')
        v=$(cat "$d/value" 2>/dev/null)
        dir=$(cat "$d/direction" 2>/dev/null)
        echo "${n}:${dir}:${v}"
    done
}

echo "--- T=14 initial state ---" >> "$LOG"
snapshot >> "$LOG"
echo "" >> "$LOG"

# Save initial state for diffing
PREV=$(snapshot)
echo "=== transitions (timestamp gpio old -> new) ===" > "$TRANSITIONS"

# Poll for 90 seconds (45 iterations × 2s)
i=0
while [ "$i" -lt 45 ]; do
    sleep 2
    UP=$(awk '{print $1}' /proc/uptime)
    NOW=$(snapshot)
    if [ "$NOW" != "$PREV" ]; then
        # Find which lines changed
        DIFF=$(diff <(echo "$PREV") <(echo "$NOW") | grep '^[<>]' || true)
        if [ -n "$DIFF" ]; then
            echo "" >> "$TRANSITIONS"
            echo "[uptime=${UP}s]" >> "$TRANSITIONS"
            echo "$DIFF" >> "$TRANSITIONS"
        fi
        PREV="$NOW"
    fi
    i=$((i + 1))
done

echo "" >> "$LOG"
echo "--- T=104 final state ---" >> "$LOG"
snapshot >> "$LOG"
echo "" >> "$LOG"

echo "=== dmesg lines (panel/lvds/backlight/lcd/pwm/setgpio) ===" >> "$LOG"
dmesg 2>/dev/null | grep -iE "(panel|lvds|backlight|lcd|pwm|setgpio|brightness)" >> "$LOG"

echo "" >> "$LOG"
echo "=== loaded modules ===" >> "$LOG"
lsmod 2>/dev/null | head -20 >> "$LOG"

# Copy everything to /boot
cp "$LOG" /boot/Q60_BL_DISCOVER.LOG 2>/dev/null
cp "$TRANSITIONS" /boot/Q60_BL_TRANSITIONS.LOG 2>/dev/null
sync

rm -f "$WLOCK"
