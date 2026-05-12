#!/bin/bash
# run-simulator.sh — Q60 Nav hardware simulator
#
# Runs the i386 q60nav binary inside a Docker container using Qt's built-in VNC
# platform plugin.  Both screens appear side-by-side on a virtual 1700×500 display.
# Connect from macOS with Screen Sharing or any VNC client at localhost:5900.
#
# Requirements:
#   - Docker Desktop running
#   - ./scripts/build-app.sh must have been run (needs output/app-build/bin/q60nav)
#   - Optional: output/vector-tiles/nc.mbtiles for live map tiles
#
# Usage:
#   ./scripts/run-simulator.sh           # launch + open VNC client
#   ./scripts/run-simulator.sh --no-vnc  # launch only, connect manually
#   ./scripts/run-simulator.sh --rebuild # force rebuild of simulator image
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."

SIM_IMAGE="q60-simulator"
VNC_PORT=5900
VNC_WIDTH=1700
VNC_HEIGHT=500
OPEN_VNC=1
REBUILD=0

# ── Argument parsing ──────────────────────────────────────────────────────────
for arg in "$@"; do
    case "$arg" in
        --no-vnc)  OPEN_VNC=0 ;;
        --rebuild) REBUILD=1  ;;
    esac
done

# ── Check binary exists ───────────────────────────────────────────────────────
BINARY="$ROOT/output/app-build/bin/q60nav"
if [ ! -f "$BINARY" ]; then
    echo "[sim] ERROR: $BINARY not found — run scripts/build-app.sh first"
    exit 1
fi
echo "[sim] Binary: $(ls -lh "$BINARY" | awk '{print $5, $9}')"

# ── Build simulator image if needed ──────────────────────────────────────────
if [ "$REBUILD" -eq 1 ] || ! docker image inspect "$SIM_IMAGE" &>/dev/null; then
    echo "[sim] Building $SIM_IMAGE Docker image (first time ~2 min, then cached)..."
    docker build --platform linux/amd64 -t "$SIM_IMAGE" -f "$ROOT/Dockerfile.simulator" "$ROOT"
    echo "[sim] Image built."
else
    echo "[sim] Using existing $SIM_IMAGE image. (--rebuild to refresh)"
fi

# ── Kill any previous sim container ──────────────────────────────────────────
docker rm -f q60-sim 2>/dev/null || true

# ── Network isolation note ────────────────────────────────────────────────────
# The real DCU is air-gapped because it has no modem/NIC — not via iptables.
# Docker --internal networks and -p port mapping are mutually exclusive (both
# depend on the same NAT rules). We use the default bridge so VNC port mapping
# works, but the app is offline by design: all data is local (MBTiles, Valhalla,
# Nominatim).  DNS is disabled so no hostname resolution is possible even if the
# binary tried to reach out.  This matches DCU behavior at the application layer.
SIM_NET="bridge"  # default Docker bridge — required for -p port mapping

# ── Optional mounts (skip gracefully if artifacts not present) ────────────────
TILE_MOUNT=""
if [ -f "$ROOT/output/vector-tiles/nc.mbtiles" ]; then
    TILE_MOUNT="-v $ROOT/output/vector-tiles/nc.mbtiles:/opt/nav/tiles/nc.mbtiles:ro"
    echo "[sim] Vector tiles: nc.mbtiles mounted"
else
    echo "[sim] WARNING: nc.mbtiles not found — map will render without tiles"
fi

STYLE_MOUNT=""
if [ -d "$ROOT/rootfs/opt/nav/style" ]; then
    STYLE_MOUNT="-v $ROOT/rootfs/opt/nav/style:/opt/nav/style:ro"
    echo "[sim] Map style: mounted"
fi

# ── Launch container ──────────────────────────────────────────────────────────
echo "[sim] Starting q60nav in VNC mode (${VNC_WIDTH}x${VNC_HEIGHT}, port ${VNC_PORT})..."
echo "[sim] Connect with: open vnc://localhost:${VNC_PORT}"
echo ""

docker run --rm \
    --platform linux/amd64 \
    --name q60-sim \
    --network "$SIM_NET" \
    --dns 0.0.0.0 \
    -p ${VNC_PORT}:${VNC_PORT} \
    \
    -v "$BINARY:/opt/nav/bin/q60nav:ro" \
    -v "$ROOT/output/qt6-i386/lib:/opt/nav/lib:ro" \
    -v "$ROOT/output/qt6-i386/plugins:/opt/nav/plugins:ro" \
    -v "$ROOT/output/qt6-i386/qml:/opt/nav/qml:ro" \
    ${STYLE_MOUNT} \
    ${TILE_MOUNT} \
    \
    -e QT_QUICK_BACKEND=software \
    -e QSG_RENDER_LOOP=basic \
    -e QT_QUICK_CONTROLS_STYLE=Basic \
    -e QT_PLUGIN_PATH=/opt/nav/plugins \
    -e QML_IMPORT_PATH=/opt/nav/qml \
    -e QML2_IMPORT_PATH=/opt/nav/qml \
    -e LD_LIBRARY_PATH=/opt/nav/lib:/usr/lib/i386-linux-gnu \
    -e LIBGL_DRIVERS_PATH=/usr/lib/i386-linux-gnu/dri \
    -e EGL_PLATFORM=surfaceless \
    -e MESA_GL_VERSION_OVERRIDE=3.3 \
    -e MESA_GLSL_VERSION_OVERRIDE=330 \
    -e GALLIUM_DRIVER=softpipe \
    -e Q60_SIM=1 \
    -e QT_LOGGING_RULES="q60nav.*=true" \
    -e QT_DEBUG_PLUGINS=0 \
    \
    "$SIM_IMAGE" \
    bash -c "
        # Qt VNC plugin links libX11/libxcb for font+input init — needs a DISPLAY
        # even though it serves its own TCP VNC server. Start a throwaway Xvfb.
        Xvfb :99 -screen 0 ${VNC_WIDTH}x${VNC_HEIGHT}x24 -nolisten tcp &
        sleep 0.5

        DISPLAY=:99 \
        QT_QPA_PLATFORM='vnc:size=${VNC_WIDTH}x${VNC_HEIGHT}:port=${VNC_PORT}' \
        exec /opt/nav/bin/q60nav
    " &

CONTAINER_PID=$!

# ── Wait for VNC port to open ─────────────────────────────────────────────────
echo "[sim] Waiting for VNC server to start..."
MAX_WAIT=30
for i in $(seq 1 $MAX_WAIT); do
    if nc -z localhost ${VNC_PORT} 2>/dev/null; then
        echo "[sim] VNC server ready (${i}s)"
        break
    fi
    if [ $i -eq $MAX_WAIT ]; then
        echo "[sim] WARNING: VNC port not open after ${MAX_WAIT}s — check docker logs q60-sim"
    fi
    sleep 1
done

# ── Open VNC client on Mac ────────────────────────────────────────────────────
if [ "$OPEN_VNC" -eq 1 ]; then
    echo "[sim] Opening VNC client..."
    sleep 1   # brief pause for compositor to render first frame
    open "vnc://localhost:${VNC_PORT}" 2>/dev/null || \
    open -a "Screen Sharing" "vnc://localhost:${VNC_PORT}" 2>/dev/null || \
    echo "[sim] Could not auto-open VNC — connect manually to localhost:${VNC_PORT}"
fi

echo ""
echo "[sim] Running. Press Ctrl+C to stop."
echo "[sim] Logs: docker logs -f q60-sim"
echo ""

# Wait for container to exit
wait $CONTAINER_PID 2>/dev/null || true
echo "[sim] Simulator stopped."
