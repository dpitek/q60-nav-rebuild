#!/bin/bash
# Deploy R1 Sprite C overlay test to DCU Slot A.
# Pure-additive — drops /opt/q60r1/sprite_test + a systemd one-shot unit.
# Watch the LCD for a red rectangle during the 10-second active window.
set -e

DEV="${1:-/dev/disk12s2}"
RAWDEV=$(echo "$DEV" | sed 's|/dev/disk|/dev/rdisk|')
DEBUGFS=/opt/homebrew/opt/e2fsprogs/sbin/debugfs

BIN=/tmp/q60-overnight/r1-build/q60nav_sprite_c.static

[ -x "$DEBUGFS" ] || { echo "FATAL: $DEBUGFS missing"; exit 1; }
[ -f "$BIN" ]    || { echo "FATAL: build R1 client first ($BIN)"; exit 1; }

# Wrapper script — chmod's binary at run-time so debugfs sif quirks don't matter
WRAP=$(mktemp)
cat > "$WRAP" <<'EOF'
#!/bin/sh
chmod 755 /opt/q60r1/sprite_test
exec /opt/q60r1/sprite_test
EOF

# Systemd unit — one-shot, 5 sec settle delay, then run
UNIT=$(mktemp)
cat > "$UNIT" <<'EOF'
[Unit]
Description=Q60 R1 Sprite C overlay test (one-shot)
ConditionPathExists=/opt/q60r1/sprite_test

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 8
ExecStart=/bin/sh /opt/q60r1/run.sh
StandardOutput=journal
StandardError=journal
RemainAfterExit=yes
TimeoutSec=120

[Install]
WantedBy=multi-user.target
EOF

trap 'rm -f "$WRAP" "$UNIT"' EXIT

# Sanity: must be the 64GB removable SD
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
rm sprite_test
write $BIN sprite_test
rm run.sh
write $WRAP run.sh
cd /
cd etc
cd systemd
cd system
rm q60-r1-spritec.service
write $UNIT q60-r1-spritec.service
cd multi-user.target.wants
rm q60-r1-spritec.service
symlink q60-r1-spritec.service ../q60-r1-spritec.service
EOF
"$DEBUGFS" -w -f "$CMD" "$RAWDEV" 2>&1 | tail -5
rm -f "$CMD"

echo ""
echo "--- verify ---"
"$DEBUGFS" -R 'ls /opt/q60r1' "$RAWDEV" 2>&1 | head -2
"$DEBUGFS" -R 'stat /etc/systemd/system/multi-user.target.wants/q60-r1-spritec.service' "$RAWDEV" 2>&1 | grep -E "Type|Fast link" | head -2

echo ""
echo "=== R1 deployed — eject and boot ==="
echo "On boot:"
echo "  - factory boots normally (we touch nothing factory)"
echo "  - 8 sec after multi-user.target, our test runs"
echo "  - For ~10 sec, V2G bridge is enabled — watch LCD for any visual change"
echo "  - Log written to /boot/Q60_R1.LOG"
diskutil eject /dev/disk12 2>/dev/null || true
