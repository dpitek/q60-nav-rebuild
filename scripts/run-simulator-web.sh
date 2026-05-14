#!/bin/bash
# run-simulator-web.sh — Q60 Nav simulator, browser-accessible.
#
# Architecture (2026-05-14 v2 — Qt VNC plugin was broken):
#   q60nav-amd64 (xcb plugin, system Qt6)
#     ↓ renders to
#   Xvfb (virtual X11 display :99)
#     ↓ captured by
#   x11vnc (VNC server on internal :5900)
#     ↓ bridged by
#   websockify (HTML5 noVNC client on :8080)
#
# Production builds remain i386 (scripts/build-app.sh). The simulator uses
# a separate amd64 binary (scripts/build-app-sim.sh) because:
#   1. Our i386 Qt6 lacks the xcb plugin (FEATURE_xcb=OFF on embedded build)
#   2. The included Qt VNC plugin is broken — accepts TCP but never sends RFB
#
# MapLibre is disabled in the sim build (its static lib is i386-only); the
# nav map shows the placeholder grid. The entire UI shell, settings, controls,
# DTC reader, and navigation flow all work fully in the browser.
#
# Usage:
#   ./scripts/run-simulator-web.sh                # launch + auto-open browser
#   ./scripts/run-simulator-web.sh --no-open      # launch, browse manually
#   ./scripts/run-simulator-web.sh --rebuild      # force simulator image rebuild
#   ./scripts/run-simulator-web.sh --rebuild-app  # rebuild the amd64 q60nav
#   ./scripts/run-simulator-web.sh --port 9000    # override HTTP port
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."

SIM_IMAGE="q60-simulator"
WEB_PORT=8080
WIDTH=1700                # upper(800) + gap(100) + lower(800)
HEIGHT=500
OPEN_BROWSER=1
REBUILD=0
REBUILD_APP=0

while [ $# -gt 0 ]; do
    case "$1" in
        --no-open)     OPEN_BROWSER=0; shift ;;
        --rebuild)     REBUILD=1; shift ;;
        --rebuild-app) REBUILD_APP=1; shift ;;
        --port)        WEB_PORT="$2"; shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

# ── Build (or rebuild) the simulator image ─────────────────────────────────
if [ "$REBUILD" -eq 1 ] || ! docker image inspect "$SIM_IMAGE" &>/dev/null; then
    echo "[sim-web] Building $SIM_IMAGE image (adds Qt6 amd64 + Xvfb + x11vnc + noVNC)..."
    docker build --platform linux/amd64 -t "$SIM_IMAGE" \
        -f "$ROOT/Dockerfile.simulator" "$ROOT"
fi
# Sanity: required tools present
if ! docker run --rm "$SIM_IMAGE" sh -c 'command -v x11vnc >/dev/null && command -v Xvfb >/dev/null && command -v websockify >/dev/null'; then
    echo "[sim-web] $SIM_IMAGE missing required tools — rebuilding..."
    docker build --platform linux/amd64 -t "$SIM_IMAGE" \
        -f "$ROOT/Dockerfile.simulator" "$ROOT"
fi

# ── Build (or rebuild) the amd64 q60nav ────────────────────────────────────
SIM_BIN="$ROOT/output/app-build-sim/bin/q60nav"
if [ "$REBUILD_APP" -eq 1 ] || [ ! -f "$SIM_BIN" ]; then
    echo "[sim-web] Building amd64 q60nav for simulator..."
    "$ROOT/scripts/build-app-sim.sh" clean
fi
echo "[sim-web] Sim binary: $SIM_BIN ($(ls -lh "$SIM_BIN" | awk '{print $5}'))"

# ── Clean up any stale container ───────────────────────────────────────────
docker rm -f q60-sim-web 2>/dev/null || true

# ── Style mount (optional) ─────────────────────────────────────────────────
STYLE_MOUNT=""
if [ -d "$ROOT/rootfs/opt/nav/style" ]; then
    STYLE_MOUNT="-v $ROOT/rootfs/opt/nav/style:/opt/nav/style:ro"
fi

echo "[sim-web] HTTP port:    $WEB_PORT  →  http://localhost:$WEB_PORT/"
echo "[sim-web] Frame size:   ${WIDTH}x${HEIGHT}  (upper 800 + gap + lower 800)"
echo ""

docker run --rm -d \
    --platform linux/amd64 \
    --name q60-sim-web \
    -p ${WEB_PORT}:8080 \
    \
    -v "$SIM_BIN:/opt/nav/bin/q60nav:ro" \
    -v "$ROOT/app/src/qml:/opt/nav/qml:ro" \
    ${STYLE_MOUNT} \
    \
    -e QT_QUICK_CONTROLS_STYLE=Basic \
    -e Q60_SIM=1 \
    -e QT_LOGGING_RULES="q60nav.*=true" \
    \
    "$SIM_IMAGE" \
    bash -c "
        set -e
        # Drop the cross-compile env vars baked into q60-toolchain — the sim
        # binary is amd64 native, no -m32.
        unset CFLAGS CXXFLAGS LDFLAGS

        # Xvfb — virtual X11 display
        Xvfb :99 -screen 0 ${WIDTH}x${HEIGHT}x24 -nolisten tcp &
        sleep 1

        # Wait for X socket
        for i in \$(seq 1 30); do
            [ -S /tmp/.X11-unix/X99 ] && break
            sleep 0.2
        done

        # Launch q60nav (amd64) with the xcb platform plugin
        DISPLAY=:99 QT_QPA_PLATFORM=xcb /opt/nav/bin/q60nav &
        APP_PID=\$!
        sleep 2

        # Hide the X cursor + position windows nicely — best-effort, ignore failures
        DISPLAY=:99 xset s off 2>/dev/null || true
        DISPLAY=:99 xset -dpms 2>/dev/null || true

        # x11vnc — capture Xvfb framebuffer, serve VNC on internal :5900
        # -forever : keep running after client disconnect
        # -shared  : allow multiple simultaneous clients
        # -listen localhost : only websockify reaches it
        # -nopw    : no password (it's behind websockify which is host-local)
        # -quiet   : keep log tidy
        x11vnc -display :99 -forever -shared -nopw -listen localhost \
               -rfbport 5900 -quiet -bg

        sleep 1

        # noVNC index.html — auto-redirect from bare URL
        cat > /usr/share/novnc/index.html <<'HTML'
<!DOCTYPE html>
<html><head>
<meta charset='utf-8'><title>Q60 Nav Simulator</title>
<meta http-equiv='refresh' content='0; url=vnc.html?autoconnect=1&resize=scale'>
</head><body style='background:#0a0a0a;color:#8e8e93;font-family:sans-serif;text-align:center;padding-top:40px'>
<p>Loading <a style='color:#0a84ff' href='vnc.html?autoconnect=1&resize=scale'>Q60 Nav simulator</a>&hellip;</p>
</body></html>
HTML

        echo '[sim-web] websockify launching on :8080 → 127.0.0.1:5900'
        exec websockify --web=/usr/share/novnc 8080 127.0.0.1:5900
    "

# ── Wait for HTTP bridge to come up ────────────────────────────────────────
echo "[sim-web] Waiting for HTTP bridge..."
for i in $(seq 1 30); do
    if nc -z localhost ${WEB_PORT} 2>/dev/null; then
        echo "[sim-web] HTTP bridge ready (${i}s)"
        break
    fi
    if [ $i -eq 30 ]; then
        echo "[sim-web] WARNING: port ${WEB_PORT} did not open in 30s"
        echo "          docker logs q60-sim-web"
        exit 1
    fi
    sleep 1
done

URL="http://localhost:${WEB_PORT}/"
echo ""
echo "[sim-web] Simulator running:"
echo "          $URL"
echo ""
echo "[sim-web] Useful commands:"
echo "          docker logs -f q60-sim-web   # follow app stdout"
echo "          docker stop q60-sim-web      # stop the simulator"
echo ""

if [ "$OPEN_BROWSER" -eq 1 ]; then
    sleep 1
    open "$URL" 2>/dev/null || echo "[sim-web] Open manually: $URL"
fi
