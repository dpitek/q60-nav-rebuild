#!/bin/sh
# watchdog-pet.sh — Keep iTCO hardware watchdog alive
# Run by inittab as respawn — if this dies, watchdog fires → reboot
# Pets /dev/watchdog every 20s (well under 30s iTCO timeout)
# q60nav ALSO pets the watchdog; this script is the safety net during startup

WDOG=/dev/watchdog
PET_INTERVAL=20

if [ ! -c "$WDOG" ]; then
    echo "[watchdog] /dev/watchdog not found — iTCO not available" >&2
    # Sleep indefinitely so inittab respawn doesn't loop frantically
    while true; do sleep 60; done
fi

# Open watchdog (arms it) and pet every 20s
exec 3>"$WDOG"
echo "[watchdog] Armed. Petting every ${PET_INTERVAL}s"

while true; do
    echo "V" >&3    # 'V' = controlled ping (magic close = disable)
    sleep "$PET_INTERVAL"
done
