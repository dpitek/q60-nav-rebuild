#!/bin/bash
# Plan B deploy (Wayland + ivi-shell variant):
# inject q60nav binary, Qt 5.15 libs, weston-q60 unit, q60nav.service into the
# factory Slot A ext4 (/dev/mmcblkXp2 on the boot SD) without mounting.
# Uses debugfs from e2fsprogs — proven 2026-05-16 on macOS via Docker.
#
# Inputs (absolute paths on host):
#   $1  /dev/rdiskNs2  — Slot A raw device on the bench SD (BSD device path)
#                       or /dev/loopNpM equivalent under Linux
#   $2  q60nav build dir — must contain:
#        ./q60nav
#        ./qt5libs/libQt5*.so.5*
#        ./plugins/platforms/libqwayland-generic.so
#        ./plugins/wayland-shell-integration/libivi-shell.so   (optional but recommended)
#
# Outputs on Slot A:
#   /opt/q60nav/q60nav
#   /opt/q60nav/lib/libQt5*.so.5*
#   /opt/q60nav/plugins/platforms/libqwayland-generic.so
#   /opt/q60nav/plugins/wayland-shell-integration/libivi-shell.so
#   /etc/q60/weston.ini
#   /etc/systemd/system/weston-q60.service
#   /etc/systemd/system/q60nav.service
#   symlinks under multi-user.target.wants/
#
# The factory's emgdhmid.service is NOT disabled by this script — do that in a
# separate step (`systemctl disable emgdhmid.service`) once integration is verified.

set -e

DEV="$1"
SRCDIR="$2"

[ -n "$DEV" ]    || { echo "Usage: $0 /dev/rdiskNs2 /path/to/q60nav-build"; exit 1; }
[ -n "$SRCDIR" ] || { echo "Usage: $0 /dev/rdiskNs2 /path/to/q60nav-build"; exit 1; }
[ -b "$DEV" ] || [ -c "$DEV" ] || { echo "ERROR: $DEV is not a block/char device"; exit 1; }
[ -f "$SRCDIR/q60nav" ] || { echo "ERROR: $SRCDIR/q60nav not found"; exit 1; }

WESTON_INI=$(mktemp)
WESTON_UNIT=$(mktemp)
Q60NAV_UNIT=$(mktemp)
CMD=$(mktemp)
trap 'rm -f "$WESTON_INI" "$WESTON_UNIT" "$Q60NAV_UNIT" "$CMD"' EXIT

# weston.ini: ivi-shell + hmi-controller + v2g sprite plugin.
# Do NOT autolaunch from [ivi-launcher]; q60nav.service starts the client so
# systemd handles restart/logging.
cat > "$WESTON_INI" <<'IEOF'
[core]
shell=ivi-shell.so
modules=hmi-controller.so

[ivi-shell]
ivi-module=hmi-controller.so

[hmi-controller]
cursor-theme=
IEOF

cat > "$WESTON_UNIT" <<'WEOF'
[Unit]
Description=Weston compositor for Q60 (EMGD + ivi-shell + v2g sprite)
After=basic.target
Wants=basic.target
ConditionPathExists=/dev/dri/card0

[Service]
Type=simple
User=root
Environment=XDG_RUNTIME_DIR=/run/user/0
Environment=WAYLAND_DISPLAY=wayland-0
ExecStartPre=/bin/mkdir -p /run/user/0
ExecStart=/usr/bin/weston-launch -- -i0 --current-mode \
          --shell=ivi-shell.so \
          --modules=hmi-controller.so \
          --config=/etc/q60/weston.ini \
          --log=/tmp/weston-q60.log
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
WEOF

# QT_IVI_SURFACE_ID must match the factory app's surface id — captured by the
# IPC probe (see rc.local.denso-ipc-capture). 1000 is a placeholder; the deploy
# script accepts an override via Q60_IVI_SURFACE_ID env var at install time.
IVI_ID="${Q60_IVI_SURFACE_ID:-1000}"
cat > "$Q60NAV_UNIT" <<QEOF
[Unit]
Description=q60nav upper-screen application
After=weston-q60.service
Requires=weston-q60.service

[Service]
Type=simple
User=root
Environment=XDG_RUNTIME_DIR=/run/user/0
Environment=WAYLAND_DISPLAY=wayland-0
Environment=QT_QPA_PLATFORM=wayland
Environment=QT_WAYLAND_SHELL_INTEGRATION=ivi-shell
Environment=QT_IVI_SURFACE_ID=$IVI_ID
Environment=QT_QUICK_BACKEND=software
Environment=QT_PLUGIN_PATH=/opt/q60nav/plugins
Environment=LD_LIBRARY_PATH=/opt/q60nav/lib
ExecStart=/opt/q60nav/q60nav --fullscreen
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
QEOF

{
    echo "cd /"
    # /opt/q60nav
    echo "mkdir opt 2>/dev/null || true"
    echo "cd opt"
    echo "mkdir q60nav 2>/dev/null || true"
    echo "cd q60nav"
    echo "rm q60nav 2>/dev/null || true"
    echo "write $SRCDIR/q60nav q60nav"
    echo "sif /opt/q60nav/q60nav mode 100755"

    # lib/
    echo "mkdir lib 2>/dev/null || true"
    echo "cd lib"
    find "$SRCDIR/qt5libs" -maxdepth 1 -type f -name "libQt5*.so.*" 2>/dev/null | while read -r f; do
        b=$(basename "$f")
        echo "rm $b 2>/dev/null || true"
        echo "write $f $b"
        echo "sif /opt/q60nav/lib/$b mode 100755"
    done
    echo "cd .."

    # plugins/platforms (Wayland QPA)
    echo "mkdir plugins 2>/dev/null || true"
    echo "cd plugins"
    echo "mkdir platforms 2>/dev/null || true"
    echo "cd platforms"
    for plug in libqwayland-generic.so libqwayland-egl.so; do
        if [ -f "$SRCDIR/plugins/platforms/$plug" ]; then
            echo "rm $plug 2>/dev/null || true"
            echo "write $SRCDIR/plugins/platforms/$plug $plug"
            echo "sif /opt/q60nav/plugins/platforms/$plug mode 100755"
        fi
    done
    echo "cd .."

    # plugins/wayland-shell-integration (ivi-shell binding)
    echo "mkdir wayland-shell-integration 2>/dev/null || true"
    echo "cd wayland-shell-integration"
    for plug in libivi-shell.so; do
        if [ -f "$SRCDIR/plugins/wayland-shell-integration/$plug" ]; then
            echo "rm $plug 2>/dev/null || true"
            echo "write $SRCDIR/plugins/wayland-shell-integration/$plug $plug"
            echo "sif /opt/q60nav/plugins/wayland-shell-integration/$plug mode 100755"
        fi
    done
    echo "cd /"

    # /etc/q60/weston.ini
    echo "cd etc"
    echo "mkdir q60 2>/dev/null || true"
    echo "cd q60"
    echo "rm weston.ini 2>/dev/null || true"
    echo "write $WESTON_INI weston.ini"
    echo "sif /etc/q60/weston.ini mode 100644"
    echo "cd .."

    # systemd units
    echo "cd systemd"
    echo "cd system"
    for unit_pair in "weston-q60.service:$WESTON_UNIT" "q60nav.service:$Q60NAV_UNIT"; do
        unit_name="${unit_pair%%:*}"
        unit_file="${unit_pair#*:}"
        echo "rm $unit_name 2>/dev/null || true"
        echo "write $unit_file $unit_name"
        echo "sif /etc/systemd/system/$unit_name mode 100644"
    done
    echo "cd multi-user.target.wants"
    for unit_name in weston-q60.service q60nav.service; do
        echo "rm $unit_name 2>/dev/null || true"
        echo "symlink $unit_name ../$unit_name"
    done
} > "$CMD"

echo "--- debugfs command stream ($(wc -l < "$CMD") lines) ---"
echo "(suppressed; passing via tempfile)"

if [ "$(uname)" = "Darwin" ]; then
    docker run --rm --privileged --platform linux/amd64 \
        -v "$DEV":"$DEV" \
        -v "$SRCDIR":"$SRCDIR":ro \
        -v "$CMD":/cmd.debugfs:ro \
        -v "$WESTON_INI":"$WESTON_INI":ro \
        -v "$WESTON_UNIT":"$WESTON_UNIT":ro \
        -v "$Q60NAV_UNIT":"$Q60NAV_UNIT":ro \
        ubuntu:22.04 bash -c "apt-get update -qq && apt-get install -y -qq e2fsprogs >/dev/null && debugfs -w -f /cmd.debugfs $DEV"
else
    debugfs -w -f "$CMD" "$DEV"
fi

echo "=== Deploy complete ==="
echo "After first successful boot of q60nav with the placeholder surface ID,"
echo "capture the factory surface ID from the IPC probe output and re-deploy"
echo "with: Q60_IVI_SURFACE_ID=<id> $0 $DEV $SRCDIR"
