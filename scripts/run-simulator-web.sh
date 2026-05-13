#!/bin/bash
# run-simulator-web.sh — Q60 Nav simulator, browser-accessible.
#
# Same i386 q60nav binary as run-simulator.sh, but the VNC server is wrapped
# in a noVNC/websockify bridge so the dual-screen UI is reachable at
# http://localhost:8080 in any browser — no VNC client install needed.
#
# Full interactivity: mouse clicks, scroll wheel, keyboard input all forward
# through the WebSocket → TCP VNC → Qt event loop.
#
# Requirements:
#   - Docker Desktop running
#   - scripts/build-app-worktree.sh has produced output/app-build/bin/q60nav
#   - Worktree-aware: reuses the main repo's Qt6/MapLibre prebuilts if the
#     worktree doesn't have its own
#
# Usage:
#   ./scripts/run-simulator-web.sh                # launch + auto-open browser
#   ./scripts/run-simulator-web.sh --no-open      # launch, browse manually
#   ./scripts/run-simulator-web.sh --rebuild      # force simulator image rebuild
#   ./scripts/run-simulator-web.sh --port 9000    # override HTTP port
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKTREE_ROOT="$SCRIPT_DIR/.."
MAIN_ROOT="/Users/dpitek/Developer/q60-rebuild"

SIM_IMAGE="q60-simulator"
WEB_PORT=8080
VNC_PORT=5900             # internal; not exposed to host
WIDTH=1700                # upper(800) + gap(100) + lower(800)
HEIGHT=500
OPEN_BROWSER=1
REBUILD=0

# ── Args ──────────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
    case "$1" in
        --no-open)  OPEN_BROWSER=0; shift ;;
        --rebuild)  REBUILD=1; shift ;;
        --port)     WEB_PORT="$2"; shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

# ── Locate binary ──────────────────────────────────────────────────────────
if [ -f "$WORKTREE_ROOT/output/app-build/bin/q60nav" ]; then
    BINARY="$WORKTREE_ROOT/output/app-build/bin/q60nav"
elif [ -f "$MAIN_ROOT/output/app-build/bin/q60nav" ]; then
    BINARY="$MAIN_ROOT/output/app-build/bin/q60nav"
else
    echo "[sim-web] ERROR: q60nav binary not found"
    echo "          Run scripts/build-app-worktree.sh first."
    exit 1
fi
echo "[sim-web] Binary: $BINARY ($(ls -lh "$BINARY" | awk '{print $5}'))"

# ── Locate Qt6 + assets ────────────────────────────────────────────────────
QT6_PREFIX="$MAIN_ROOT/output/qt6-i386"
if [ ! -f "$QT6_PREFIX/lib/libQt6Core.so.6" ]; then
    echo "[sim-web] ERROR: Qt6 i386 not found at $QT6_PREFIX"
    exit 1
fi

# ── Build simulator image if needed ────────────────────────────────────────
if [ "$REBUILD" -eq 1 ] || ! docker image inspect "$SIM_IMAGE" &>/dev/null; then
    echo "[sim-web] Building $SIM_IMAGE image (adds noVNC + websockify)..."
    docker build --platform linux/amd64 -t "$SIM_IMAGE" \
        -f "$WORKTREE_ROOT/Dockerfile.simulator" "$WORKTREE_ROOT"
fi

# Re-check that novnc is present in the image (in case an older build is cached
# without the new packages).
if ! docker run --rm "$SIM_IMAGE" sh -c 'command -v websockify >/dev/null && ls /usr/share/novnc/vnc.html >/dev/null 2>&1'; then
    echo "[sim-web] Existing $SIM_IMAGE lacks noVNC — rebuilding..."
    docker build --platform linux/amd64 -t "$SIM_IMAGE" \
        -f "$WORKTREE_ROOT/Dockerfile.simulator" "$WORKTREE_ROOT"
fi

# ── Clean up any stale container ───────────────────────────────────────────
docker rm -f q60-sim-web 2>/dev/null || true

# ── Optional asset mounts ──────────────────────────────────────────────────
TILE_MOUNT=""
if [ -f "$MAIN_ROOT/output/vector-tiles/nc.mbtiles" ]; then
    TILE_MOUNT="-v $MAIN_ROOT/output/vector-tiles/nc.mbtiles:/opt/nav/tiles/nc.mbtiles:ro"
fi

STYLE_MOUNT=""
if [ -d "$WORKTREE_ROOT/rootfs/opt/nav/style" ]; then
    STYLE_MOUNT="-v $WORKTREE_ROOT/rootfs/opt/nav/style:/opt/nav/style:ro"
fi

# Worktree QML wins; falls back to main if missing.
QML_MOUNT="-v $WORKTREE_ROOT/app/src/qml:/opt/nav/qml-src:ro"

echo "[sim-web] HTTP port:    $WEB_PORT  →  http://localhost:$WEB_PORT/vnc.html?autoconnect=1&resize=scale"
echo "[sim-web] Frame size:   ${WIDTH}x${HEIGHT}  (upper-800 + gap + lower-800)"
echo ""

# ── Launch container ───────────────────────────────────────────────────────
docker run --rm -d \
    --platform linux/amd64 \
    --name q60-sim-web \
    -p ${WEB_PORT}:8080 \
    \
    -v "$BINARY:/opt/nav/bin/q60nav:ro" \
    -v "$QT6_PREFIX/lib:/opt/nav/lib:ro" \
    -v "$QT6_PREFIX/plugins:/opt/nav/plugins:ro" \
    -v "$QT6_PREFIX/qml:/opt/nav/qt-qml:ro" \
    ${QML_MOUNT} \
    ${STYLE_MOUNT} \
    ${TILE_MOUNT} \
    \
    -e QT_QUICK_BACKEND=software \
    -e QSG_RENDER_LOOP=basic \
    -e QT_QUICK_CONTROLS_STYLE=Basic \
    -e QT_PLUGIN_PATH=/opt/nav/plugins \
    -e QML_IMPORT_PATH=/opt/nav/qml-src:/opt/nav/qt-qml \
    -e QML2_IMPORT_PATH=/opt/nav/qml-src:/opt/nav/qt-qml \
    -e LD_LIBRARY_PATH=/opt/nav/lib:/usr/lib/i386-linux-gnu \
    -e LIBGL_DRIVERS_PATH=/usr/lib/i386-linux-gnu/dri \
    -e EGL_PLATFORM=surfaceless \
    -e MESA_GL_VERSION_OVERRIDE=3.3 \
    -e MESA_GLSL_VERSION_OVERRIDE=330 \
    -e GALLIUM_DRIVER=softpipe \
    -e Q60_SIM=1 \
    -e QT_LOGGING_RULES="q60nav.*=true" \
    \
    "$SIM_IMAGE" \
    bash -c "
        set -e

        # Xvfb: Qt VNC plugin needs a DISPLAY to initialize font / input even
        # though it serves its own TCP VNC socket.
        Xvfb :99 -screen 0 ${WIDTH}x${HEIGHT}x24 -nolisten tcp &
        XVFB_PID=\$!
        sleep 0.5

        # Launch q60nav with the VNC platform plugin on port ${VNC_PORT}
        # (internal — only websockify reaches it).
        DISPLAY=:99 \\
        QT_QPA_PLATFORM='vnc:size=${WIDTH}x${HEIGHT}:port=${VNC_PORT}' \\
        /opt/nav/bin/q60nav &
        APP_PID=\$!

        # Wait for the VNC server to start listening
        for i in \$(seq 1 30); do
            if (echo > /dev/tcp/127.0.0.1/${VNC_PORT}) 2>/dev/null; then
                echo '[sim-web] VNC server ready on internal :${VNC_PORT}'
                break
            fi
            sleep 0.2
        done

        # websockify: serves the noVNC HTML5 client + WebSocket bridge to
        # 127.0.0.1:${VNC_PORT}. Foreground process so docker logs follow it.
        echo '[sim-web] websockify launching on :8080 → 127.0.0.1:${VNC_PORT}'
        exec websockify --web=/usr/share/novnc 8080 127.0.0.1:${VNC_PORT}
    "

# ── Wait for the web port to open ──────────────────────────────────────────
echo "[sim-web] Waiting for HTTP bridge to come up..."
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

URL="http://localhost:${WEB_PORT}/vnc.html?autoconnect=1&resize=scale"
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
    open "$URL" 2>/dev/null || echo "[sim-web] Open the URL manually: $URL"
fi
