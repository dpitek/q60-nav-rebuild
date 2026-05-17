#!/bin/sh
# DENSO IPC capture probe — inject via debugfs into factory Slot A as a one-shot.
# Hooked from late-services.target.wants/android-mount.service (same pattern as
# the 2026-05-16 hardware-ground-truth probe).
# Captures pipe inventory + strace of each daemon for 5 min while operator
# exercises the factory UI; writes results to FAT32 (mmcblk0p1, /boot) so they
# can be retrieved by reading the SD on the bench.

set +e
LOG=/boot/Q60_IPC_$(date +%Y%m%d-%H%M%S)
mkdir -p "$LOG"
exec >"$LOG/00-trace.log" 2>&1

echo "=== DENSO IPC capture — $(date) ==="
echo "Output dir: $LOG"

echo "--- /tmp inventory ---"
ls -la /tmp/*.cmd /tmp/*.rsp /tmp/*.sock 2>/dev/null > "$LOG/01-pipes-inventory.txt"
ls -la /var/run/*.cmd /var/run/*.sock 2>/dev/null >> "$LOG/01-pipes-inventory.txt"
cat "$LOG/01-pipes-inventory.txt"

echo "--- display device probe ---"
ls -la /dev/dri/ /dev/fb* 2>&1 > "$LOG/02-display-devs.txt"
fbset >> "$LOG/02-display-devs.txt" 2>&1 || true
cat /proc/fb >> "$LOG/02-display-devs.txt" 2>/dev/null || true
fuser /dev/dri/card0 >> "$LOG/02-display-devs.txt" 2>&1 || true
fuser /dev/fb0 >> "$LOG/02-display-devs.txt" 2>&1 || true

echo "--- emgdhmid + weston configuration ---"
{
    echo "=== systemd unit ==="
    for path in /lib/systemd/system /etc/systemd/system /usr/lib/systemd/system; do
        for u in emgdhmid.service weston.service weston-launch.service; do
            [ -f "$path/$u" ] && echo "--- $path/$u ---" && cat "$path/$u"
        done
    done
    echo "=== weston configs ==="
    find /etc /opt /usr/share -name "weston.ini" 2>/dev/null | while read f; do
        echo "--- $f ---"; cat "$f"
    done
    echo "=== modprobe emgd ==="
    find /etc/modprobe.d -name "*emgd*" 2>/dev/null | while read f; do
        echo "--- $f ---"; cat "$f"
    done
    echo "=== emgdhmid runtime env ==="
    pid=$(pidof emgdhmid 2>/dev/null || pidof emgdhmid.out 2>/dev/null)
    if [ -n "$pid" ]; then
        echo "pid=$pid"
        ls -la /proc/$pid/exe
        cat /proc/$pid/cmdline | tr '\0' ' '; echo
        cat /proc/$pid/environ | tr '\0' '\n'
        echo "=== ldd of emgdhmid exe ==="
        target=$(readlink /proc/$pid/exe)
        ldd "$target" 2>&1 || echo "ldd unavailable"
    fi
    echo "=== weston runtime if present ==="
    pid=$(pidof weston 2>/dev/null)
    if [ -n "$pid" ]; then
        echo "weston pid=$pid"
        cat /proc/$pid/cmdline | tr '\0' ' '; echo
        cat /proc/$pid/environ | tr '\0' '\n'
    fi
} > "$LOG/02b-emgdhmid-weston.txt" 2>&1

echo "--- daemon inventory ---"
for d in sxmcgs radiofc sound vcan emgdhmid weston; do
    for ext in "" .out .exe; do
        pid=$(pidof "${d}${ext}" 2>/dev/null) || continue
        echo "=== ${d}${ext} (pid $pid) ===" >> "$LOG/03-daemons.txt"
        ls -la /proc/$pid/exe >> "$LOG/03-daemons.txt" 2>&1
        ls -la /proc/$pid/fd >> "$LOG/03-daemons.txt" 2>&1
        cat /proc/$pid/cmdline | tr '\0' ' ' >> "$LOG/03-daemons.txt" 2>&1
        echo "" >> "$LOG/03-daemons.txt"
        cp /proc/$pid/maps "$LOG/04-${d}${ext}-maps.txt" 2>/dev/null
    done
done

echo "--- D-Bus topology ---"
{
    echo "=== bus sockets ==="
    find /var/run /tmp -name "*dbus*" 2>/dev/null
    find /var/run/dbus /tmp/dbus* 2>/dev/null | head -20
    echo "=== ListNames (system) ==="
    dbus-send --system --print-reply --dest=org.freedesktop.DBus / \
        org.freedesktop.DBus.ListNames 2>&1 || echo "system bus ListNames failed"
    echo "=== ListNames (session via /run/user/0) ==="
    XDG_RUNTIME_DIR=/run/user/0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/0/bus \
        dbus-send --session --print-reply --dest=org.freedesktop.DBus / \
        org.freedesktop.DBus.ListNames 2>&1 || echo "session bus ListNames failed"
    echo "=== AMB introspect ==="
    dbus-send --system --print-reply --dest=org.automotive.Manager / \
        org.freedesktop.DBus.Introspectable.Introspect 2>&1 || echo "AMB not present on system bus"
} > "$LOG/02c-dbus.txt" 2>&1

echo "--- starting 5-minute strace window ---"
for d in sxmcgs radiofc sound vcan emgdhmid; do
    for ext in "" .out; do
        pid=$(pidof "${d}${ext}" 2>/dev/null) || continue
        strace -ttf -s 512 -e trace=read,write,open,openat,connect \
            -p "$pid" -o "$LOG/strace-${d}${ext}.log" &
    done
done

echo "OPERATOR: exercise each function NOW — tune radio, change SXM, vol up/down, switch source, navigate"
sleep 300
killall strace 2>/dev/null

echo "--- which units launch what ---"
systemctl list-units --type=service --no-pager > "$LOG/05-systemd-units.txt" 2>&1
ls -la /etc/systemd/system/late-services.target.wants/ >> "$LOG/05-systemd-units.txt" 2>/dev/null
ls -la /etc/systemd/system/multi-user.target.wants/ >> "$LOG/05-systemd-units.txt" 2>/dev/null

echo "--- weston / EMGD environment ---"
ps aux | grep -E "(weston|emgd|xorg|X)" > "$LOG/06-display-procs.txt" 2>&1
env > "$LOG/07-env.txt" 2>&1

echo "=== capture complete $(date) ==="
sync
