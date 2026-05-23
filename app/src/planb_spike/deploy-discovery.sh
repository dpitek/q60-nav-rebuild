#!/bin/bash
# deploy-discovery.sh — One-shot deploy of the backlight GPIO discovery probe.
# No compiled binary — just a shell script in the boot hook. Faster deploy.
# Pure observation: no daemon kills, no paint. Boot once, get GPIO answer.
set -e

DEV="${1:-/dev/disk12s2}"
[[ "$DEV" == /dev/* ]] || DEV="/dev/$DEV"
RAWDEV=$(echo "$DEV" | sed 's|/dev/disk|/dev/rdisk|')
DEBUGFS=/opt/homebrew/opt/e2fsprogs/sbin/debugfs

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
DISC=$SRC_DIR/discover_backlight.sh
[ -x "$DEBUGFS" ] || { echo "FATAL: debugfs missing"; exit 1; }
[ -f "$DISC" ]    || { echo "FATAL: $DISC missing"; exit 1; }

DISKID=$(echo "$DEV" | sed 's|/dev/||;s|s[0-9]*$||')
INFO=$(diskutil info "/dev/$DISKID")
echo "$INFO" | grep -qi "Removable Media:.*Removable" || { echo "FATAL: $DISKID not removable"; exit 1; }
echo "$INFO" | grep -qE "Disk Size: *6[0-9]\.[0-9]+ GB"  || { echo "FATAL: not the 64GB SD card"; exit 1; }

diskutil unmount "$DEV" 2>/dev/null || true

# Patch android-mount.sh to launch our discovery probe
RAWDEV_B_RAW=$(echo "$RAWDEV" | sed 's|s2$|s3|')
AMSH_ORIG=$(mktemp)
AMSH_NEW=$(mktemp)
"$DEBUGFS" -R "cat /sbin/android-mount.sh" "$RAWDEV_B_RAW" 2>/dev/null > "$AMSH_ORIG" || true
if [ ! -s "$AMSH_ORIG" ]; then
    "$DEBUGFS" -R "cat /sbin/android-mount.sh" "$RAWDEV" 2>/dev/null > "$AMSH_ORIG" || true
fi

python3 - "$AMSH_ORIG" "$AMSH_NEW" <<'PYEOF'
import sys, re
src = open(sys.argv[1]).read()
src = re.sub(r'\n# >>Q60_HOOK_START<<.*?# >>Q60_HOOK_END<<\n', '\n', src, flags=re.DOTALL)
src = re.sub(r'\n# >>Q60_PLANB_START<<.*?# >>Q60_PLANB_END<<\n', '\n', src, flags=re.DOTALL)
src = re.sub(r'\nnohup sh -c \'.*?\' </dev/null >/dev/null 2>&1 &\n', '\n', src, flags=re.DOTALL)
src = re.sub(r'\n{3,}', '\n\n', src)
hook = "\n# >>Q60_PLANB_START<<\n( sleep 5; sh /opt/q60planb/discover_backlight.sh ) </dev/null >/dev/null 2>&1 &\n# >>Q60_PLANB_END<<"
lines = src.split('\n')
result = [lines[0]] if lines and lines[0].startswith('#!') else []
if result:
    result.append(hook.strip())
    result.extend(lines[1:])
else:
    result = [hook.strip()] + lines
open(sys.argv[2], 'w').write('\n'.join(result))
PYEOF

CMD=$(mktemp)
cat > "$CMD" <<EOF
cd /
cd opt
mkdir q60planb
cd q60planb
rm discover_backlight.sh
write $DISC discover_backlight.sh
cd /
cd sbin
rm android-mount.sh
write $AMSH_NEW android-mount.sh
EOF

echo "=== Writing discovery probe to card ==="
"$DEBUGFS" -w -f "$CMD" "$RAWDEV" 2>&1 | grep -v "^$" | tail -10
rm -f "$CMD" "$AMSH_ORIG" "$AMSH_NEW"

echo ""
echo "--- discover_backlight.sh head ---"
"$DEBUGFS" -R "cat /opt/q60planb/discover_backlight.sh" "$RAWDEV" 2>&1 | head -10

echo ""
echo "=== DEPLOYED ==="
echo "Boot, wait until 110+ seconds, then plug SD back into Mac. Read:"
echo "  /Volumes/boot/Q60_BL_TRANSITIONS.LOG   — which GPIOs changed, when"
echo "  /Volumes/boot/Q60_BL_DISCOVER.LOG      — full snapshot + dmesg"
diskutil eject "/dev/$DISKID" 2>/dev/null || true
