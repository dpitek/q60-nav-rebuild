#!/bin/bash
# Deploy the R1 diagnostic probe (q60nav_r1_probe) to DCU Slot A.
# Runs once at multi-user.target, logs to /boot/Q60_R1_PROBE.LOG.
# Pure-additive — touches no factory file.
set -e

DEV="${1:-/dev/disk12s2}"
RAWDEV=$(echo "$DEV" | sed 's|/dev/disk|/dev/rdisk|')
DEBUGFS=/opt/homebrew/opt/e2fsprogs/sbin/debugfs

BIN=/tmp/q60-overnight/r1-build/q60nav_r1_probe.static
[ -x "$DEBUGFS" ] || { echo "FATAL: $DEBUGFS missing"; exit 1; }
[ -f "$BIN" ]    || { echo "FATAL: $BIN missing (run build-r1.sh)"; exit 1; }

WRAP=$(mktemp)
cat > "$WRAP" <<'EOF'
#!/bin/sh
chmod 755 /opt/q60r1/probe
exec /opt/q60r1/probe
EOF

UNIT=$(mktemp)
cat > "$UNIT" <<'EOF'
[Unit]
Description=Q60 R1 diagnostic probe (one-shot)
ConditionPathExists=/opt/q60r1/probe

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 8
ExecStart=/bin/sh /opt/q60r1/probe-run.sh
StandardOutput=journal
StandardError=journal
RemainAfterExit=yes
TimeoutSec=60

[Install]
WantedBy=multi-user.target
EOF

trap 'rm -f "$WRAP" "$UNIT"' EXIT

INFO=$(diskutil info /dev/$(echo "$DEV" | sed 's|/dev/||;s|s[0-9]*$||'))
echo "$INFO" | grep -qi "Removable Media:.*Removable" || { echo "FATAL: not removable"; exit 1; }
echo "$INFO" | grep -qE "Disk Size: *6[0-9]\.[0-9]+ GB"  || { echo "FATAL: not the 64GB card"; exit 1; }

diskutil unmount "$DEV" 2>/dev/null || true

CMD=$(mktemp)
cat > "$CMD" <<EOF
cd /
cd opt
mkdir q60r1
cd q60r1
rm probe
write $BIN probe
rm probe-run.sh
write $WRAP probe-run.sh
cd /
cd etc
cd systemd
cd system
rm q60-r1-probe.service
write $UNIT q60-r1-probe.service
cd multi-user.target.wants
rm q60-r1-probe.service
symlink q60-r1-probe.service ../q60-r1-probe.service
EOF
"$DEBUGFS" -w -f "$CMD" "$RAWDEV" 2>&1 | tail -3
rm -f "$CMD"

echo ""
echo "=== Probe deployed — eject and boot ==="
echo "Boot DCU, wait ~30 sec, power off, pull card."
echo "Log: /Volumes/boot/Q60_R1_PROBE.LOG"
diskutil eject /dev/disk12 2>/dev/null || true
