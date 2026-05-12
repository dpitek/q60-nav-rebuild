#!/bin/bash
# build-app.sh — Cross-compile q60nav + valhalla-httpd for i686 Atom inside Docker
# Usage: ./scripts/build-app.sh [clean]
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
BUILD_DIR="$ROOT/output/app-build"
OUTPUT="$ROOT/output/q60nav"
QT6_PREFIX="$ROOT/output/qt6-i386"

# Verify Qt i386 is built
if [ ! -f "$QT6_PREFIX/lib/libQt6Core.so.6" ]; then
    echo "ERROR: Qt 6 i386 not found at $QT6_PREFIX"
    echo "Run the Qt6 i386 source build first."
    exit 1
fi

echo "[build-app] Qt6 i386 found at $QT6_PREFIX"

# Clean if requested
if [ "$1" = "clean" ]; then
    rm -rf "$BUILD_DIR"
    echo "[build-app] Build dir cleaned"
fi

mkdir -p "$BUILD_DIR" "$OUTPUT"

docker run --rm \
    -v "$ROOT:/build" \
    -e CROSS_COMPILE_I686=1 \
    -e QT6_I386_PREFIX=/build/output/qt6-i386 \
    q60-toolchain \
    bash -c "
        set -e
        export PKG_CONFIG_PATH=/usr/lib/i386-linux-gnu/pkgconfig:/build/output/qt6-i386/lib/pkgconfig
        export CMAKE_PREFIX_PATH=/build/output/qt6-i386

        # ── valhalla-httpd ────────────────────────────────────────────────────
        echo '[build-app] Compiling valhalla-httpd.c...'
        gcc -m32 -march=bonnell -mtune=bonnell -O2 \
            -o /build/rootfs/opt/valhalla/bin/valhalla-httpd \
            /build/rootfs/opt/valhalla/valhalla-httpd.c
        file /build/rootfs/opt/valhalla/bin/valhalla-httpd

        # ── q60nav Qt app ─────────────────────────────────────────────────────
        mkdir -p /build/output/app-build && cd /build/output/app-build

        cmake /build/app \
            -GNinja \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_C_COMPILER=gcc \
            -DCMAKE_CXX_COMPILER=g++ \
            -DCMAKE_C_FLAGS='-m32 -march=bonnell -mtune=bonnell' \
            -DCMAKE_CXX_FLAGS='-m32 -march=bonnell -mtune=bonnell' \
            -DCMAKE_EXE_LINKER_FLAGS='-m32' \
            -DCMAKE_PREFIX_PATH=/build/output/qt6-i386 \
            -DCROSS_COMPILE_I686=1 \
            2>&1 | tee /build/output/q60nav/cmake.log

        ninja -j\$(nproc) 2>&1 | tee /build/output/q60nav/build.log

        echo '[build-app] Build complete'
        file /build/output/app-build/q60nav
        ls -lh /build/output/app-build/q60nav
    "

echo "[build-app] Done — binary at $BUILD_DIR/q60nav"
file "$BUILD_DIR/q60nav" 2>/dev/null || true
