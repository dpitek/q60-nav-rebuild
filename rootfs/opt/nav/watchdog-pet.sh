#!/bin/sh
# watchdog-pet.sh — Sole hardware watchdog keeper for Q60 Nav
# Respawned by inittab. This is the ONLY process that holds /dev/watchdog.
# q60nav does NOT open /dev/watchdog — it relies on this keeper.
#
# Design:
#   - ie6xx_wdt (Atom E6xx) with 30s timeout
#   - Pet every 20s — inside 30s window, tolerates one missed cycle
#   - Clean shutdown (SIGTERM): writes 'V' → magic close disables watchdog
#   - Crash/kill: fd closes without 'V' → watchdog fires → hardware reboot
#   - Inittab respawn within 30s re-arms with a fresh timeout window

WDOG=/dev/watchdog
PET_INTERVAL=20

if [ ! -c "$WDOG" ]; then
    # ie6xx_wdt not loaded or absent — idle without tight respawn loop
    sleep 3600
    exit 0
fi

# Open watchdog — arms the 30s hardware countdown from here
exec 3>"$WDOG"

# On SIGTERM (clean shutdown): magic-close to disable watchdog before fd closes
trap 'printf V >&3; exec 3>&-; exit 0' TERM INT

# Pet loop: any non-V byte resets the countdown
while true; do
    printf '1' >&3
    sleep "$PET_INTERVAL"
done
