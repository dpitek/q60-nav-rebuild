#!/bin/bash
# deploy-thorough.sh — Full redeploy: correct binary name + instrumented wrapper.
#
# Root-cause fix:
#   Previous deploys wrote binary as "sprite_test"; hook called "v4l2_test" — ENOENT.
#   New wrapper writes to /tmp FIRST so traces survive even if /boot mount fails.
set -e

DEV="${1:-/dev/disk12s2}"
RAWDEV=$(echo "$DEV" | sed 's|/dev/disk|/dev/rdisk|')
DEBUGFS=/opt/homebrew/opt/e2fsprogs/sbin/debugfs

BIN=/tmp/q60-overnight/r1-build/q60nav_v4l2_test.static
[ -x "$DEBUGFS" ] || { echo "FATAL: debugfs missing"; exit 1; }
[ -f "$BIN" ]    || { echo "FATAL: $BIN missing"; exit 1; }

# Sanity: 64GB removable card only
INFO=$(diskutil info /dev/$(echo "$DEV" | sed 's|/dev/||;s|s[0-9]*$||'))
echo "$INFO" | grep -qi "Removable Media:.*Removable" || { echo "FATAL: not removable"; exit 1; }
echo "$INFO" | grep -qE "Disk Size: *6[0-9]\.[0-9]+ GB"  || { echo "FATAL: not the 64GB card"; exit 1; }

diskutil unmount "$DEV" 2>/dev/null || true

# ── run.sh: instrumented wrapper ──────────────────────────────────────────────
# Writes to /tmp (always writable) before attempting /boot mount.
RUN=$(mktemp)
cat > "$RUN" <<'RUN_EOF'
#!/bin/sh
# Single-instance guard — v4l2_test manages its own lock internally,
# but also prevent the shell wrapper from running twice concurrently.
WLOCK=/tmp/q60-wrap.lock
[ -f "$WLOCK" ] && exit 0
echo $$ > "$WLOCK"

T=/tmp/q60t.log
printf "[0] START %s pid=%s\n" "$(date)" "$$" > "$T" 2>/dev/null

ls -la /opt/q60r1/ >> "$T" 2>/dev/null
chmod 755 /opt/q60r1/v4l2_test 2>/dev/null

# Mount /boot
mount /dev/mmcblk0p1 /boot 2>/dev/null; MRC=$?
[ "$MRC" -ne 0 ] && mount /dev/mmcblk1p1 /boot 2>/dev/null
printf "[mount] rc=%s\n" "$MRC" >> "$T" 2>/dev/null

printf "[5] write-test %s\n" "$(date)" > /boot/Q60_HOOK_RAN.TXT 2>/dev/null
cp "$T" /boot/Q60_TRACE_EARLY.TXT 2>/dev/null

printf "[6] LAUNCH %s\n" "$(date)" >> "$T" 2>/dev/null
printf "[6] LAUNCH\n" >> /boot/Q60_HOOK_RAN.TXT 2>/dev/null

# Capture stdout separately — v4l2_test writes its real log to /tmp directly
/opt/q60r1/v4l2_test > /tmp/q60-stdout.log 2>&1
V4RC=$?

printf "[7] EXIT rc=%s %s\n" "$V4RC" "$(date)" >> "$T" 2>/dev/null
printf "[7] EXIT rc=%s\n" "$V4RC" >> /boot/Q60_HOOK_RAN.TXT 2>/dev/null

# Copy wrapper trace (do NOT copy /tmp/q60-stdout.log over Q60_R1_V4L2.LOG —
# the binary wrote that directly to /boot via its own fopen+system(cp) call)
cp "$T"                  /boot/Q60_TRACE_FULL.TXT  2>/dev/null
cp /tmp/q60-stdout.log   /boot/Q60_STDOUT.LOG      2>/dev/null

printf "[DONE] %s\n" "$(date)" >> /boot/Q60_HOOK_RAN.TXT 2>/dev/null
sync
rm -f "$WLOCK"
RUN_EOF

# ── android-mount.sh: always use Slot B (factory) as base to avoid legacy cruft ──
# Previous deploys left a nohup block after the >>Q60_HOOK_END<< marker — strips here.
AMSH_ORIG=$(mktemp)
AMSH_NEW=$(mktemp)

# Read from SLOT B (mmcblk0p3, rdisk12s3) — guaranteed clean factory copy.
# Fall back to Slot A if Slot B read fails.
RAWDEV_B=$(echo "$DEV" | sed 's|s2$|s3|')
RAWDEV_B_RAW=$(echo "$RAWDEV_B" | sed 's|/dev/disk|/dev/rdisk|')
"$DEBUGFS" -R "cat /sbin/android-mount.sh" "$RAWDEV_B_RAW" 2>/dev/null > "$AMSH_ORIG" || true
if [ ! -s "$AMSH_ORIG" ]; then
    echo "NOTE: Slot B read failed — falling back to Slot A"
    "$DEBUGFS" -R "cat /sbin/android-mount.sh" "$RAWDEV" 2>/dev/null > "$AMSH_ORIG" || true
fi

# Strip ALL Q60 hook artifacts, then inject fresh hook after shebang.
python3 - "$AMSH_ORIG" "$AMSH_NEW" <<PYEOF
import sys, re

with open(sys.argv[1]) as f:
    src = f.read()

# Remove Q60_HOOK_START/END block (any prior deploy)
src = re.sub(r'\n# >>Q60_HOOK_START<<.*?# >>Q60_HOOK_END<<\n', '\n', src, flags=re.DOTALL)

# Remove any legacy nohup v4l2_test/probe/sprite_c block left by earlier deploys
src = re.sub(r'\nnohup sh -c \'.*?\' </dev/null >/dev/null 2>&1 &\n', '\n', src, flags=re.DOTALL)
src = re.sub(r'\n# Q60 R1 hook.*?\n', '\n', src, flags=re.DOTALL)

# Collapse consecutive blank lines
src = re.sub(r'\n{3,}', '\n\n', src)

# Insert hook after first shebang line
hook = """\n# >>Q60_HOOK_START<<\n( sleep 3; sh /opt/q60r1/run.sh ) </dev/null >/dev/null 2>&1 &\n# >>Q60_HOOK_END<<"""
lines = src.split('\n')
result = [lines[0]] if lines[0].startswith('#!') else []
if result:
    result.append(hook.strip())
    result.extend(lines[1:])
else:
    result = [hook.strip()] + lines

with open(sys.argv[2], 'w') as f:
    f.write('\n'.join(result))
PYEOF

# Fallback: if original was empty (permission issue), build minimal version
# that runs hook then exec's the real script from factory slot B (/dev/mmcblk0p3)
if [ ! -s "$AMSH_NEW" ]; then
    echo "WARN: could not read android-mount.sh from card — hook-only wrapper"
    cat > "$AMSH_NEW" <<'FB_EOF'
#!/bin/sh
# >>Q60_HOOK_START<<
( sleep 3; sh /opt/q60r1/run.sh ) </dev/null >/dev/null 2>&1 &
# >>Q60_HOOK_END<<
FB_EOF
fi

# ── systemd unit — no RemainAfterExit (prevents caching across reboots) ───────
UNIT=$(mktemp)
cat > "$UNIT" <<'UNIT_EOF'
[Unit]
Description=Q60 R1 v4l2 diagnostic (one-shot)
ConditionPathExists=/opt/q60r1/v4l2_test

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 8
ExecStart=/bin/sh /opt/q60r1/run.sh
StandardOutput=journal
StandardError=journal
TimeoutSec=120

[Install]
WantedBy=multi-user.target
UNIT_EOF

# ── debugfs write all at once ─────────────────────────────────────────────────
CMD=$(mktemp)
cat > "$CMD" <<EOF
cd /
cd opt
mkdir q60r1
cd q60r1
rm v4l2_test
write $BIN v4l2_test
rm run.sh
write $RUN run.sh
cd /
cd sbin
rm android-mount.sh
write $AMSH_NEW android-mount.sh
cd /
cd etc
cd systemd
cd system
rm q60-r1-v4l2.service
write $UNIT q60-r1-v4l2.service
cd multi-user.target.wants
rm q60-r1-v4l2.service
symlink q60-r1-v4l2.service ../q60-r1-v4l2.service
rm q60-r1-probe.service
rm q60-r1-spritec.service
EOF

echo "=== Writing to card ==="
"$DEBUGFS" -w -f "$CMD" "$RAWDEV" 2>&1 | grep -v "^$" | tail -15
rm -f "$CMD" "$RUN" "$AMSH_ORIG" "$AMSH_NEW" "$UNIT"

# ── verify ────────────────────────────────────────────────────────────────────
echo ""
echo "--- /opt/q60r1 ---"
"$DEBUGFS" -R "ls /opt/q60r1" "$RAWDEV" 2>&1 | head -8
echo ""
echo "--- run.sh (first 5 lines) ---"
"$DEBUGFS" -R "cat /opt/q60r1/run.sh" "$RAWDEV" 2>&1 | head -5
echo ""
echo "--- android-mount.sh (first 8 lines) ---"
"$DEBUGFS" -R "cat /sbin/android-mount.sh" "$RAWDEV" 2>&1 | head -8
echo ""
echo "--- systemd symlink ---"
"$DEBUGFS" -R "stat /etc/systemd/system/multi-user.target.wants/q60-r1-v4l2.service" "$RAWDEV" 2>&1 | grep -E "Type|Fast link" | head -2

echo ""
echo "=== DEPLOYED ==="
echo "After boot, check card for (in order of certainty):"
echo "  /boot/Q60_HOOK_RAN.TXT    — hook fired (written BEFORE binary exec)"
echo "  /boot/Q60_TRACE_EARLY.TXT — /tmp trace before launch"
echo "  /boot/Q60_R1_V4L2.LOG     — v4l2_test output"
echo "  /boot/Q60_TRACE_FULL.TXT  — complete trace + v4l2_test exit code"
echo ""
echo "If /boot is empty: read ext4 trace via:"
echo "  sudo \$DEBUGFS -R 'cat /tmp/q60t.log' $RAWDEV"
diskutil eject /dev/disk12 2>/dev/null || true
