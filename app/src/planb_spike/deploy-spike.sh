#!/bin/bash
# deploy-spike.sh — Deploy Plan B''' Spike 1 (EGL discovery, non-destructive).
#
# This is a FACTORY-KERNEL deploy. It uses the same android-mount.sh hook
# pipeline as R1, but launches /opt/q60planb/spike1 instead. No daemon mask,
# no DRM master, no painting. Just dlopen + eglInitialize alongside the
# running factory UI, and capture diagnostics.
#
# Pre-req: build-spike.sh has produced /tmp/q60-planb/spike1
# Usage:   sudo bash deploy-spike.sh <disk> (default: disk12s2 = Slot A)
set -e

DEV="${1:-/dev/disk12s2}"
[[ "$DEV" == /dev/* ]] || DEV="/dev/$DEV"
RAWDEV=$(echo "$DEV" | sed 's|/dev/disk|/dev/rdisk|')
DEBUGFS=/opt/homebrew/opt/e2fsprogs/sbin/debugfs

BIN=/tmp/q60-planb/spike8
[ -x "$DEBUGFS" ] || { echo "FATAL: debugfs missing — brew install e2fsprogs"; exit 1; }
[ -f "$BIN" ]    || { echo "FATAL: $BIN missing — run build-spike.sh first"; exit 1; }

DISKID=$(echo "$DEV" | sed 's|/dev/||;s|s[0-9]*$||')
INFO=$(diskutil info "/dev/$DISKID")
echo "$INFO" | grep -qi "Removable Media:.*Removable" || { echo "FATAL: $DISKID not removable"; exit 1; }
echo "$INFO" | grep -qE "Disk Size: *6[0-9]\.[0-9]+ GB"  || { echo "FATAL: not the 64GB SD card"; exit 1; }

diskutil unmount "$DEV" 2>/dev/null || true

# ── run.sh — instrumented wrapper, mounts /boot then launches spike1 ──────────
RUN=$(mktemp)
cat > "$RUN" <<'RUN_EOF'
#!/bin/sh
# Single-instance guard
WLOCK=/tmp/q60-planb-wrap.lock
[ -f "$WLOCK" ] && exit 0
echo $$ > "$WLOCK"

T=/tmp/q60-planb-wrap.log
printf "[wrap-0] START %s pid=%s\n" "$(date)" "$$" > "$T" 2>/dev/null

# Mount /boot (FAT32) — try both mmcblk0p1 (Slot A) and mmcblk1p1 (SD card)
mountpoint -q /boot 2>/dev/null || mount /dev/mmcblk0p1 /boot 2>/dev/null
mountpoint -q /boot 2>/dev/null || mount /dev/mmcblk1p1 /boot 2>/dev/null
printf "[wrap-1] /boot mounted: %s\n" "$(mountpoint /boot 2>&1)" >> "$T"

chmod 755 /opt/q60planb/spike8 2>/dev/null
ls -la /opt/q60planb/ >> "$T" 2>/dev/null

# Plan B''' EGL recipe — /usr/lib FIRST so libc.so.6 / libdl.so.2 don't get
# resolved against /home/naviwork's MeeGo glibc 2.11.90 (our binary is glibc 2.31).
# Naviwork paths come after for libGLESv2 / libemgdhmi.
export LD_LIBRARY_PATH=/usr/lib:/usr/lib/wsegl:/home/naviwork/system/lib:/home/naviwork/system/out:/usr/local/lib
printf "[wrap-1.5] LD_LIBRARY_PATH=%s\n" "$LD_LIBRARY_PATH" >> "$T"
ulimit -c 0

printf "[wrap-2] LAUNCH %s\n" "$(date)" >> "$T"
printf "[wrap-2] LAUNCH %s\n" "$(date)" > /boot/Q60_PLANB_HOOK_RAN.TXT 2>/dev/null

/opt/q60planb/spike8 > /tmp/q60-planb-stdout.log 2>&1
RC=$?

# Boot timing diagnostics — SYNCHRONOUS so they're not killed by cgroup cleanup
# when run.sh exits. systemd-analyze, journalctl, /proc/uptime, etc.
{
    echo "=== /proc/uptime (seconds since boot) ==="
    cat /proc/uptime
    echo
    echo "=== which systemd-analyze ==="
    which systemd-analyze
    echo
    echo "=== systemd-analyze (overview) ==="
    systemd-analyze 2>&1
    echo
    echo "=== systemd-analyze blame (top 30) ==="
    systemd-analyze blame 2>&1 | head -30
    echo
    echo "=== systemd-analyze critical-chain ==="
    systemd-analyze critical-chain 2>&1
    echo
    echo "=== failed units ==="
    systemctl --failed --no-pager 2>&1
    echo
    echo "=== active services (top 40) ==="
    systemctl list-units --type=service --state=active --no-pager 2>&1 | head -40
} > /boot/Q60_BOOT_DIAG.LOG 2>&1

# Journal with microsecond timestamps — first 800 lines covers the slow part
journalctl -b -o short-precise --no-pager 2>&1 | head -800 > /boot/Q60_JOURNAL.LOG
sync

printf "[wrap-3] EXIT rc=%s %s\n" "$RC" "$(date)" >> "$T"
printf "[wrap-3] EXIT rc=%s\n" "$RC" >> /boot/Q60_PLANB_HOOK_RAN.TXT 2>/dev/null

# Always copy spike output to /boot — including partial logs from a crash
cp "$T"                            /boot/Q60_PLANB_WRAP.LOG     2>/dev/null
cp /tmp/q60-planb-stdout.log       /boot/Q60_PLANB_STDOUT.LOG   2>/dev/null
cp /tmp/q60-planb-5.log            /boot/Q60_PLANB_SPIKE5.LOG   2>/dev/null
cp /tmp/q60-planb-5-stage-*.txt    /boot/                       2>/dev/null

# On crash (rc >= 128 = signal), capture the kernel's segfault report
if [ "$RC" -ge 128 ]; then
    dmesg 2>/dev/null | tail -40 > /boot/Q60_PLANB_DMESG_CRASH.LOG
    printf "[wrap-4] CRASH SIG=%s — dmesg tail captured\n" "$((RC - 128))" >> "$T"
    cp "$T" /boot/Q60_PLANB_WRAP.LOG 2>/dev/null
fi
sync
rm -f "$WLOCK"
RUN_EOF

# ── android-mount.sh — clean inject from Slot B factory copy ──────────────────
AMSH_ORIG=$(mktemp)
AMSH_NEW=$(mktemp)

# Read from Slot B (mmcblk0p3) for guaranteed clean factory base
RAWDEV_B_RAW=$(echo "$RAWDEV" | sed 's|s2$|s3|')
"$DEBUGFS" -R "cat /sbin/android-mount.sh" "$RAWDEV_B_RAW" 2>/dev/null > "$AMSH_ORIG" || true
if [ ! -s "$AMSH_ORIG" ]; then
    echo "NOTE: Slot B read failed — falling back to Slot A"
    "$DEBUGFS" -R "cat /sbin/android-mount.sh" "$RAWDEV" 2>/dev/null > "$AMSH_ORIG" || true
fi

python3 - "$AMSH_ORIG" "$AMSH_NEW" <<'PYEOF'
import sys, re
src = open(sys.argv[1]).read()
# Strip any prior Q60 hook (R1 or planb)
src = re.sub(r'\n# >>Q60_HOOK_START<<.*?# >>Q60_HOOK_END<<\n', '\n', src, flags=re.DOTALL)
src = re.sub(r'\n# >>Q60_PLANB_START<<.*?# >>Q60_PLANB_END<<\n', '\n', src, flags=re.DOTALL)
src = re.sub(r'\nnohup sh -c \'.*?\' </dev/null >/dev/null 2>&1 &\n', '\n', src, flags=re.DOTALL)
src = re.sub(r'\n{3,}', '\n\n', src)
hook = "\n# >>Q60_PLANB_START<<\n( sleep 5; sh /opt/q60planb/run.sh ) </dev/null >/dev/null 2>&1 &\n# >>Q60_PLANB_END<<"
lines = src.split('\n')
result = [lines[0]] if lines and lines[0].startswith('#!') else []
if result:
    result.append(hook.strip())
    result.extend(lines[1:])
else:
    result = [hook.strip()] + lines
open(sys.argv[2], 'w').write('\n'.join(result))
PYEOF

if [ ! -s "$AMSH_NEW" ]; then
    cat > "$AMSH_NEW" <<'FB_EOF'
#!/bin/sh
# >>Q60_PLANB_START<<
( sleep 5; sh /opt/q60planb/run.sh ) </dev/null >/dev/null 2>&1 &
# >>Q60_PLANB_END<<
FB_EOF
fi

# ── systemd unit (in case PID 1 is systemd — Agent 3 said it is) ──────────────
UNIT=$(mktemp)
cat > "$UNIT" <<'UNIT_EOF'
[Unit]
Description=Q60 Plan B''' Spike 8 — corrected MapPixmap signature (out pointers)
ConditionPathExists=/opt/q60planb/spike8

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 12
ExecStart=/bin/sh /opt/q60planb/run.sh
StandardOutput=journal
StandardError=journal
TimeoutSec=300

[Install]
WantedBy=multi-user.target
UNIT_EOF

# ── debugfs write ─────────────────────────────────────────────────────────────
CMD=$(mktemp)
cat > "$CMD" <<EOF
cd /
cd opt
mkdir q60planb
cd q60planb
rm spike1
rm spike1b
rm spike1c
rm spike2
rm spike3
rm spike4
rm spike8
write $BIN spike8
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
rm q60-planb-spike1.service
write $UNIT q60-planb-spike1.service
cd multi-user.target.wants
rm q60-planb-spike1.service
symlink q60-planb-spike1.service ../q60-planb-spike1.service
cd /
cd etc
cd systemd
cd system
rm nav_dmsg_start.service
symlink nav_dmsg_start.service /dev/null
cd /
cd lib
cd systemd
cd system
cd nav_pre.target.wants
rm nav_dmsg_start.service
EOF

echo "=== Writing to card ==="
"$DEBUGFS" -w -f "$CMD" "$RAWDEV" 2>&1 | grep -v "^$" | tail -15
rm -f "$CMD" "$RUN" "$AMSH_ORIG" "$AMSH_NEW" "$UNIT"

# ── verify ────────────────────────────────────────────────────────────────────
echo ""
echo "--- /opt/q60planb ---"
"$DEBUGFS" -R "ls /opt/q60planb" "$RAWDEV" 2>&1 | head -8
echo "--- run.sh head ---"
"$DEBUGFS" -R "cat /opt/q60planb/run.sh" "$RAWDEV" 2>&1 | head -5
echo "--- android-mount.sh head ---"
"$DEBUGFS" -R "cat /sbin/android-mount.sh" "$RAWDEV" 2>&1 | head -10

echo "--- nav_dmsg_start mask (should show symlink to /dev/null) ---"
"$DEBUGFS" -R "ls -l /etc/systemd/system/nav_dmsg_start.service" "$RAWDEV" 2>&1 | tail -3
echo "--- nav_pre.target.wants (should NOT contain nav_dmsg_start) ---"
"$DEBUGFS" -R "ls /lib/systemd/system/nav_pre.target.wants" "$RAWDEV" 2>&1 | grep -i dmsg && echo "  !! STILL PRESENT" || echo "  ✓ removed"

echo ""
echo "=== DEPLOYED ==="
echo "Boot speedup: nav_dmsg_start.service masked (-75s wait)"
echo "Boot the car, then read (in order of certainty):"
echo "  /boot/Q60_PLANB_HOOK_RAN.TXT    — hook fired (proves PID 1 ran our hook)"
echo "  /boot/Q60_PLANB_WRAP.LOG        — wrapper trace"
echo "  /boot/Q60_PLANB_SPIKE1.LOG      — main spike log (stages 01-10)"
echo "  /boot/Q60_PLANB_STDOUT.LOG      — spike stdout/stderr"
echo "  /boot/q60-planb-stage-*.txt     — per-stage markers (proof of how far it got)"
echo ""
echo "If /boot is empty: read via debugfs:"
echo "  sudo $DEBUGFS -R 'cat /tmp/q60-planb.log' $RAWDEV"
diskutil eject "/dev/$DISKID" 2>/dev/null || true
