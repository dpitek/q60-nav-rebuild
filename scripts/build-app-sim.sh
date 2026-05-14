#!/bin/bash
# build-app-sim.sh — Build q60nav as an amd64 Linux binary for the simulator.
#
# WHY this exists: our i386 Qt6 build does not include the xcb platform
# plugin (we built with FEATURE_xcb=OFF for embedded). The Qt VNC plugin we
# do have is broken — it accepts TCP connections but never sends the RFB
# protocol greeting. To get a working browser-based simulator, we rebuild
# q60nav natively for amd64 using Ubuntu's system Qt6 packages (qt6-base-dev,
# qt6-qpa-plugins, etc.) which include a working xcb plugin. The simulator
# then uses Xvfb + x11vnc + websockify, the standard noVNC stack.
#
# This binary is for SIMULATOR USE ONLY. The production DCU binary is still
# built with scripts/build-app.sh (i386 + Bonnell + -DWITH_MAPLIBRE=ON).
#
# Output: output/app-build-sim/bin/q60nav  (ELF 64-bit x86-64, no MapLibre)
#
# Usage:
#   ./scripts/build-app-sim.sh [clean]
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
BUILD_DIR="$ROOT/output/app-build-sim"

if [ "$1" = "clean" ]; then
    rm -rf "$BUILD_DIR"
    echo "[build-sim] Build dir cleaned"
fi

mkdir -p "$BUILD_DIR" "$BUILD_DIR/bin"

echo "[build-sim] Building q60nav-amd64 for browser-accessible simulator..."

docker run --rm \
    --platform linux/amd64 \
    -v "$ROOT:/build" \
    -v "$BUILD_DIR:/build-out" \
    -e CFLAGS= -e CXXFLAGS= -e LDFLAGS= \
    q60-simulator \
    bash -c "
        set -e
        unset CFLAGS CXXFLAGS LDFLAGS
        cd /build-out

        # Use system Qt6 (amd64) which includes the working xcb plugin.
        # Critical: -DWITH_MAPLIBRE=OFF because our libmbgl-core.a is i386 and
        # cannot link into an amd64 binary. The placeholder map renders.
        cmake /build/app \
            -GNinja \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_C_COMPILER=gcc \
            -DCMAKE_CXX_COMPILER=g++ \
            -DCMAKE_PREFIX_PATH=/usr/lib/x86_64-linux-gnu/cmake \
            -DQT_NO_PACKAGE_VERSION_CHECK=TRUE \
            -DQT_NO_PACKAGE_VERSION_INCOMPATIBLE_WARNING=TRUE \
            -DOPENGL_opengl_LIBRARY=/usr/lib/x86_64-linux-gnu/libOpenGL.so \
            -DOPENGL_glx_LIBRARY=/usr/lib/x86_64-linux-gnu/libGLX.so \
            -DOPENGL_INCLUDE_DIR=/usr/include \
            -DWITH_MAPLIBRE=OFF \
            2>&1 | tail -20

        echo '[build-sim] Compiling...'
        ninja -j\$(nproc) 2>&1 | tail -10

        file bin/q60nav
        ls -lh bin/q60nav
    "

echo ""
echo "[build-sim] Done. Binary: $BUILD_DIR/bin/q60nav"
file "$BUILD_DIR/bin/q60nav" 2>/dev/null || true
