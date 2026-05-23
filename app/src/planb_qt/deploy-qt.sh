#!/bin/bash
# deploy-qt.sh — Deploy Plan B''' Qt binary + eglfs_emgdhmi plugin to the
# test SD card (factory-kernel boot path). Mirrors deploy-spike.sh but
# stages a much bigger tree:
#
#   /opt/q60qt/q60nav                                    — main app
#   /opt/q60qt/run-q60qt.sh                              — wrapper
#   /opt/q60qt/lib/libQt6*.so.6                          — Qt runtime
#   /opt/q60qt/plugins/platforms/libqeglfs.so            — Qt eglfs platform
#   /opt/q60qt/plugins/egldeviceintegrations/libqeglfs-emgdhmi-integration.so
#                                                        — our integration
#   /opt/q60qt/plugins/...                               — other Qt plugins
#                                                          (image fmts, qml)
#
# Inject the android-mount.sh hook to launch run-q60qt.sh, just like the
# spike does.
#
# Pre-req: ./scripts/build-app.sh has produced
#   output/app-build/bin/q60nav
#   output/app-build/src/eglfs_emgdhmi/libqeglfs-emgdhmi-integration.so
#
# Usage: sudo bash deploy-qt.sh <disk> (default disk4s2)
set -e

DEV="${1:-/dev/disk4s2}"
[[ "$DEV" == /dev/* ]] || DEV="/dev/$DEV"
RAWDEV=$(echo "$DEV" | sed 's|/dev/disk|/dev/rdisk|')
DEBUGFS=/opt/homebrew/opt/e2fsprogs/sbin/debugfs

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# After cmake/ninja the binaries land at the top of app-build/ (q60nav) and
# under src/eglfs_emgdhmi/ (plugin). Find them dynamically so the script
# survives layout changes.
BIN="$(find "$ROOT/output/app-build" -name 'q60nav' -type f 2>/dev/null | head -1)"
PLUGIN="$(find "$ROOT/output/app-build" -name 'libqeglfs-emgdhmi-integration*.so' 2>/dev/null | head -1)"
QT_LIB="$ROOT/output/qt6-i386/lib"
QT_PLUG="$ROOT/output/qt6-i386/plugins"
RUN_SH="$ROOT/app/src/planb_qt/run-q60qt.sh"

[ -x "$DEBUGFS" ] || { echo "FATAL: debugfs missing — brew install e2fsprogs"; exit 1; }
[ -f "$BIN" ]     || { echo "FATAL: $BIN missing — run scripts/build-app.sh first"; exit 1; }
[ -f "$PLUGIN" ]  || { echo "FATAL: $PLUGIN missing"; exit 1; }
[ -d "$QT_LIB" ]  || { echo "FATAL: $QT_LIB missing"; exit 1; }
[ -d "$QT_PLUG" ] || { echo "FATAL: $QT_PLUG missing"; exit 1; }
[ -f "$RUN_SH" ]  || { echo "FATAL: $RUN_SH missing"; exit 1; }

DISKID=$(echo "$DEV" | sed 's|/dev/||;s|s[0-9]*$||')
INFO=$(diskutil info "/dev/$DISKID")
echo "$INFO" | grep -qi "Removable Media:.*Removable" || { echo "FATAL: $DISKID not removable"; exit 1; }
echo "$INFO" | grep -qE "Disk Size: *6[0-9]\.[0-9]+ GB"  || { echo "FATAL: not the 64GB SD card"; exit 1; }

diskutil unmount "$DEV" 2>/dev/null || true

# ── Stage 1: read clean android-mount.sh from Slot B for hook injection ──────
AMSH_ORIG=$(mktemp)
AMSH_NEW=$(mktemp)
RAWDEV_B_RAW=$(echo "$RAWDEV" | sed 's|s2$|s3|')
"$DEBUGFS" -R "cat /sbin/android-mount.sh" "$RAWDEV_B_RAW" 2>/dev/null > "$AMSH_ORIG" || true
if [ ! -s "$AMSH_ORIG" ]; then
    "$DEBUGFS" -R "cat /sbin/android-mount.sh" "$RAWDEV" 2>/dev/null > "$AMSH_ORIG" || true
fi

python3 - "$AMSH_ORIG" "$AMSH_NEW" <<'PYEOF'
import sys, re
src = open(sys.argv[1]).read() if sys.argv[1] else ''
# Strip prior Q60 hooks
src = re.sub(r'\n# >>Q60_HOOK_START<<.*?# >>Q60_HOOK_END<<\n', '\n', src, flags=re.DOTALL)
src = re.sub(r'\n# >>Q60_PLANB_START<<.*?# >>Q60_PLANB_END<<\n', '\n', src, flags=re.DOTALL)
src = re.sub(r'\n# >>Q60_PLANB_QT_START<<.*?# >>Q60_PLANB_QT_END<<\n', '\n', src, flags=re.DOTALL)
src = re.sub(r'\n{3,}', '\n\n', src)
hook = "\n# >>Q60_PLANB_QT_START<<\n( sleep 5; sh /opt/q60qt/run-q60qt.sh ) </dev/null >/dev/null 2>&1 &\n# >>Q60_PLANB_QT_END<<"
lines = src.split('\n')
if lines and lines[0].startswith('#!'):
    out = [lines[0], hook.strip()] + lines[1:]
else:
    out = [hook.strip()] + lines
open(sys.argv[2], 'w').write('\n'.join(out))
PYEOF

if [ ! -s "$AMSH_NEW" ]; then
    cat > "$AMSH_NEW" <<'FB_EOF'
#!/bin/sh
# >>Q60_PLANB_QT_START<<
( sleep 5; sh /opt/q60qt/run-q60qt.sh ) </dev/null >/dev/null 2>&1 &
# >>Q60_PLANB_QT_END<<
FB_EOF
fi

# ── Stage 2: build debugfs command file. mkdirs + writes for every artifact ──
CMD=$(mktemp)
{
  echo "cd /"
  echo "cd opt"
  echo "mkdir q60qt"
  echo "cd q60qt"
  echo "rm q60nav"
  echo "write $BIN q60nav"
  echo "rm run-q60qt.sh"
  echo "write $RUN_SH run-q60qt.sh"
  echo "mkdir lib"
  echo "cd lib"

  # Qt6 core libs (only what we link against — saves space)
  for libname in libQt6Core.so.6 libQt6Gui.so.6 libQt6Quick.so.6 \
                 libQt6QuickControls2.so.6 libQt6Qml.so.6 libQt6Network.so.6 \
                 libQt6Positioning.so.6 libQt6OpenGL.so.6 libQt6QmlModels.so.6 \
                 libQt6QmlWorkerScript.so.6 libQt6QuickTemplates2.so.6 \
                 libQt6EglFSDeviceIntegration.so.6 libQt6EglFsKmsSupport.so.6 ; do
      f="$QT_LIB/$(echo $libname | sed 's|\.so\.6|.so.6.6.3|')"
      if [ -f "$f" ]; then
          echo "rm $libname"
          echo "write $f $libname"
      fi
  done

  # Runtime libs bundled by build-app.sh into output/app-build/runtime-libs/.
  # These cover Qt6 deps (icu, brotli, pcre, glib, freetype, fontconfig,
  # png16, xkbcommon) PLUS the GLVND shims (libGLX, libOpenGL, libGLdispatch)
  # that Qt6 i386 build links to but the factory rootfs doesn't ship.
  RT_BUNDLE="$ROOT/output/app-build/runtime-libs"
  if [ -d "$RT_BUNDLE" ]; then
      for src in "$RT_BUNDLE"/*; do
          [ -f "$src" ] || continue
          bn=$(basename "$src")
          echo "rm $bn"
          echo "write $src $bn"
      done
  else
      echo "# WARNING: $RT_BUNDLE missing — re-run scripts/build-app.sh"
  fi

  echo "cd /"
  echo "cd opt"
  echo "cd q60qt"
  echo "mkdir plugins"
  echo "cd plugins"

  # Qt eglfs platform plugin
  echo "mkdir platforms"
  echo "cd platforms"
  if [ -f "$QT_PLUG/platforms/libqeglfs.so" ]; then
      echo "rm libqeglfs.so"
      echo "write $QT_PLUG/platforms/libqeglfs.so libqeglfs.so"
  fi
  echo "cd .."

  # Our eglfs_emgdhmi integration
  echo "mkdir egldeviceintegrations"
  echo "cd egldeviceintegrations"
  echo "rm libqeglfs-emgdhmi-integration.so"
  echo "write $PLUGIN libqeglfs-emgdhmi-integration.so"
  echo "cd .."

  # Image format plugins — needed by Qt Quick for any icons/textures
  echo "mkdir imageformats"
  echo "cd imageformats"
  for f in "$QT_PLUG/imageformats/"*.so; do
      [ -f "$f" ] || continue
      bn=$(basename "$f")
      echo "rm $bn"
      echo "write $f $bn"
  done
  echo "cd .."

  # Hook injection
  echo "cd /"
  echo "cd sbin"
  echo "rm android-mount.sh"
  echo "write $AMSH_NEW android-mount.sh"
} > "$CMD"

# Add a systemd unit fallback in case PID 1 is systemd (Agent 3 confirms it is).
UNIT=$(mktemp)
cat > "$UNIT" <<'UNIT_EOF'
[Unit]
Description=Q60 Plan B''' Qt — eglfs + emgdhmi integration

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 12
ExecStart=/bin/sh /opt/q60qt/run-q60qt.sh
StandardOutput=journal
StandardError=journal
TimeoutSec=600

[Install]
WantedBy=multi-user.target
UNIT_EOF

{
  echo "cd /"
  echo "cd etc"
  echo "cd systemd"
  echo "cd system"
  echo "rm q60-planb-qt.service"
  echo "write $UNIT q60-planb-qt.service"
  echo "cd multi-user.target.wants"
  echo "rm q60-planb-qt.service"
  echo "symlink q60-planb-qt.service ../q60-planb-qt.service"
} >> "$CMD"

# ── Stage 3: debugfs write ───────────────────────────────────────────────────
echo "=== Writing to card ($DEV) ==="
"$DEBUGFS" -w -f "$CMD" "$RAWDEV" 2>&1 | grep -v "^$" | tail -25
rm -f "$CMD" "$AMSH_ORIG" "$AMSH_NEW" "$UNIT"

# ── Stage 4: verify ──────────────────────────────────────────────────────────
echo ""
echo "--- /opt/q60qt ---"
"$DEBUGFS" -R "ls /opt/q60qt" "$RAWDEV" 2>&1 | head -10
echo "--- /opt/q60qt/plugins/egldeviceintegrations ---"
"$DEBUGFS" -R "ls /opt/q60qt/plugins/egldeviceintegrations" "$RAWDEV" 2>&1 | head -5
echo "--- android-mount.sh head ---"
"$DEBUGFS" -R "cat /sbin/android-mount.sh" "$RAWDEV" 2>&1 | head -12

echo ""
echo "=== DEPLOYED ==="
echo "Boot the car (or qemu test), then read on host:"
echo "  /Volumes/boot/Q60_PLANB_QT_HOOK_RAN.TXT   — hook fired"
echo "  /Volumes/boot/Q60_PLANB_QT_WRAP.LOG       — wrapper trace"
echo "  /Volumes/boot/Q60_PLANB_QT_STDOUT.LOG     — Qt stdout (qDebug)"
echo "  /Volumes/boot/Q60_PLANB_QT_STDERR.LOG     — Qt stderr (QT_DEBUG_PLUGINS)"
echo ""
diskutil eject "/dev/$DISKID" 2>/dev/null || true
