#!/bin/sh
# run-q60qt.sh — On-device wrapper for q60nav Plan B''' Qt deployment.
#
# Mirrors app/src/planb_spike/deploy-spike.sh wrapper: mount /boot, stop the
# minimal "kill set" of factory daemons (nav_navi + nav_dispapf), then launch
# our Qt binary configured for eglfs + the eglfs_emgdhmi integration plugin.
#
# Logs land on /boot (FAT32) so they survive a power cycle and are readable
# on the host without booting the DCU.

WLOCK=/tmp/q60-qt-wrap.lock
[ -f "$WLOCK" ] && exit 0
echo $$ > "$WLOCK"

T=/tmp/q60-qt-wrap.log
printf "[wrap-0] START %s pid=%s\n" "$(date)" "$$" > "$T" 2>/dev/null

# Mount /boot (FAT32) for log retrieval.
mountpoint -q /boot 2>/dev/null || mount /dev/mmcblk0p1 /boot 2>/dev/null
mountpoint -q /boot 2>/dev/null || mount /dev/mmcblk1p1 /boot 2>/dev/null
printf "[wrap-1] /boot mounted: %s\n" "$(mountpoint /boot 2>&1)" >> "$T"

printf "[wrap-2] LAUNCH %s\n" "$(date)" > /boot/Q60_PLANB_QT_HOOK_RAN.TXT 2>/dev/null

# ── Wait for the factory nav_pre.target to finish bringing the panel up.
# Spike4 proved 80s after boot is safely past the EMGD backlight-on side-effect.
while [ "$(awk '{print int($1)}' /proc/uptime)" -lt 80 ]; do
    sleep 3
done

# ── Stop the minimum daemons that own the HMI plane (kill_set).
# DO NOT stop display_ps, hmictrl_proc, emgdhmid — those hold the backlight
# and DRM master orchestration we depend on.
systemctl stop nav_navi.service nav_dispapf.service >>"$T" 2>&1
sleep 1

# ── LD path so we load:
#    - libc.so.6 / libdl.so.2 / libpthread.so.0 from /usr/lib (modern glibc 2.31
#      build) — NOT from /home/naviwork's MeeGo 2.11.90
#    - libEGL/libGLES_CM/libemgdhmi from /usr/lib (factory)
#    - libwsegl-hmi from /usr/lib/wsegl
#    - Qt6 + plugins from /opt/q60qt/lib + /opt/q60qt/plugins
export LD_LIBRARY_PATH=/opt/q60qt/lib:/usr/lib:/usr/lib/wsegl:/home/naviwork/system/lib:/home/naviwork/system/out:/usr/local/lib

# ── Qt 6 platform: eglfs + our EMGD HMI integration plugin.
# Qt looks for plugins/<TYPE>/lib<name>.so under each path in QT_PLUGIN_PATH.
export QT_PLUGIN_PATH=/opt/q60qt/plugins
export QT_QPA_PLATFORM=eglfs
export QT_QPA_EGLFS_INTEGRATION=eglfs_emgdhmi
export QT_QPA_EGLFS_PHYSICAL_WIDTH=152
export QT_QPA_EGLFS_PHYSICAL_HEIGHT=91

# Helpful debug envs (cheap, copy to /boot if anything goes wrong)
export QT_LOGGING_RULES="qt.qpa.*=true;qt.qml.*=true"
export QT_DEBUG_PLUGINS=1

ulimit -c 0
printf "[wrap-3] LAUNCH q60nav LD_LIBRARY_PATH=%s\n" "$LD_LIBRARY_PATH" >> "$T"
printf "[wrap-3] QT_PLUGIN_PATH=%s\n" "$QT_PLUGIN_PATH" >> "$T"

# Run Qt app — stdout to /tmp, stderr captured separately.
/opt/q60qt/q60nav > /tmp/q60-qt-stdout.log 2> /tmp/q60-qt-stderr.log
RC=$?
printf "[wrap-4] EXIT rc=%s %s\n" "$RC" "$(date)" >> "$T"
printf "[wrap-4] EXIT rc=%s\n" "$RC" >> /boot/Q60_PLANB_QT_HOOK_RAN.TXT 2>/dev/null

# ── Always copy logs to /boot.
cp "$T"                       /boot/Q60_PLANB_QT_WRAP.LOG       2>/dev/null
cp /tmp/q60-qt-stdout.log     /boot/Q60_PLANB_QT_STDOUT.LOG     2>/dev/null
cp /tmp/q60-qt-stderr.log     /boot/Q60_PLANB_QT_STDERR.LOG     2>/dev/null

# On signal-exit, capture kernel oops/segfault diagnostic.
if [ "$RC" -ge 128 ]; then
    dmesg 2>/dev/null | tail -60 > /boot/Q60_PLANB_QT_DMESG_CRASH.LOG
    printf "[wrap-5] CRASH SIG=%s — dmesg captured\n" "$((RC - 128))" >> "$T"
    cp "$T" /boot/Q60_PLANB_QT_WRAP.LOG 2>/dev/null
fi

# Restart the kill_set so the factory nav recovers when we exit (test runs only).
systemctl start nav_navi.service nav_dispapf.service >>"$T" 2>&1

sync
rm -f "$WLOCK"
exit $RC
