#!/bin/bash
# build-app-worktree.sh — build q60nav from a git worktree, reusing the main
# worktree's heavy outputs (Qt6 i386, MapLibre, sysroot, sysroot deps).
#
# Bind-mounts the main worktree's `output/` and `deps/` directories into the
# Docker container under the same paths used by the standard build, so the
# cross-compile finds Qt6 and MapLibre prebuilts without copying gigabytes.
#
# Usage: ./scripts/build-app-worktree.sh [clean]
set -e

WORKTREE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN_ROOT="/Users/dpitek/Developer/q60-rebuild"

if [ ! -f "$MAIN_ROOT/output/qt6-i386/lib/libQt6Core.so.6" ]; then
    echo "ERROR: Qt6 i386 not found at $MAIN_ROOT/output/qt6-i386"
    exit 1
fi

# Build dirs live in the main worktree's output to keep ccache hot
BUILD_DIR="$MAIN_ROOT/output/app-build-${WORKTREE_ROOT##*/}"
mkdir -p "$BUILD_DIR"
mkdir -p "$WORKTREE_ROOT/rootfs/opt/valhalla/bin"

if [ "$1" = "clean" ]; then
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
    echo "[build-app-worktree] Build dir cleaned"
fi

echo "[build-app-worktree] Worktree: $WORKTREE_ROOT"
echo "[build-app-worktree] Reusing outputs from: $MAIN_ROOT"
echo "[build-app-worktree] Build dir: $BUILD_DIR"

docker run --rm \
    -v "$WORKTREE_ROOT:/build" \
    -v "$MAIN_ROOT/output:/build-shared/output:ro" \
    -v "$MAIN_ROOT/deps:/build-shared/deps:ro" \
    -v "$BUILD_DIR:/build-shared/app-build" \
    -e CROSS_COMPILE_I686=1 \
    -e QT6_I386_PREFIX=/build-shared/output/qt6-i386 \
    q60-toolchain \
    bash -c "
        set -e
        export PKG_CONFIG_PATH=/usr/lib/i386-linux-gnu/pkgconfig:/build-shared/output/qt6-i386/lib/pkgconfig
        export CMAKE_PREFIX_PATH=/build-shared/output/qt6-i386

        # Ensure i386 deps are installed (mirror of build-app.sh apt block,
        # cached by Docker layer typically — but Ubuntu base only has amd64,
        # so this re-fetches each run; harmless).
        dpkg --add-architecture i386 2>/dev/null || true
        apt-get update -qq 2>/dev/null
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
            libgl1-mesa-dev:i386 libgl-dev:i386 \
            libxkbcommon-dev:i386 libxkbcommon-x11-dev:i386 \
            libfontconfig1-dev:i386 libfreetype6-dev:i386 \
            libglib2.0-0:i386 libglib2.0-dev:i386 \
            libpcre2-dev:i386 libicu-dev:i386 \
            libdouble-conversion-dev:i386 libegl1-mesa-dev:i386 \
            libuv1-dev:i386 libpng-dev:i386 libjpeg-dev:i386 \
            2>/dev/null || true

        # valhalla-httpd
        echo '[build-app-worktree] Compiling valhalla-httpd.c...'
        gcc -m32 -march=i686 -mtune=bonnell -O2 \
            -o /build/rootfs/opt/valhalla/bin/valhalla-httpd \
            /build/rootfs/opt/valhalla/valhalla-httpd.c
        file /build/rootfs/opt/valhalla/bin/valhalla-httpd

        # q60nav
        cd /build-shared/app-build

        cmake /build/app \
            -GNinja \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_C_COMPILER=gcc \
            -DCMAKE_CXX_COMPILER=g++ \
            -DCMAKE_C_FLAGS='-m32 -march=i686 -mtune=bonnell' \
            -DCMAKE_CXX_FLAGS='-m32 -march=i686 -mtune=bonnell' \
            -DCMAKE_EXE_LINKER_FLAGS='-m32' \
            -DCMAKE_PREFIX_PATH=/build-shared/output/qt6-i386 \
            -DQT_HOST_PATH=/build-shared/deps/qt6-host \
            -DCROSS_COMPILE_I686=1 \
            -DCMAKE_LIBRARY_PATH=/usr/lib/i386-linux-gnu \
            -DCMAKE_INCLUDE_PATH=/usr/include \
            -DOPENGL_opengl_LIBRARY=/usr/lib/i386-linux-gnu/libOpenGL.so \
            -DOPENGL_glx_LIBRARY=/usr/lib/i386-linux-gnu/libGLX.so \
            -DOPENGL_INCLUDE_DIR=/usr/include \
            2>&1 | tee /tmp/cmake.log

        echo '[build-app-worktree] Building...'
        ninja 2>&1 | tee /tmp/ninja.log

        ls -la bin/q60nav
        file bin/q60nav
    "

# Copy the built binary out of the build dir to a worktree-local output spot
mkdir -p "$WORKTREE_ROOT/output/app-build/bin"
cp -f "$BUILD_DIR/bin/q60nav" "$WORKTREE_ROOT/output/app-build/bin/q60nav"
echo "[build-app-worktree] Binary copied to $WORKTREE_ROOT/output/app-build/bin/q60nav"
