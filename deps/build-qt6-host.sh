#!/bin/bash
# build-qt6-host.sh — Build Qt6.6.3 natively (amd64) for use as QT_HOST_PATH
# This provides Qt6HostInfo + native moc/rcc/qmake needed by the i386 cross-compile.
# Must complete before build-qt6-i386.sh runs.
#
# Run inside q60-host-build container:
#   bash /build/deps/build-qt6-host.sh
set -e

SRC=/build/deps/qt6-src/qt-everywhere-src-6.6.3
BUILD_DIR=/build/deps/qt6-build-host
INSTALL_PREFIX=/build/deps/qt6-host

echo "=== Qt 6.6.3 native (amd64) host build ==="
echo "Source:  $SRC"
echo "Build:   $BUILD_DIR"
echo "Install: $INSTALL_PREFIX"
echo "Started: $(date)"

if [ ! -f "$SRC/CMakeLists.txt" ]; then
    echo "ERROR: Qt source not found at $SRC"
    exit 1
fi

# Verify Qt6HostInfo not already installed
if [ -f "$INSTALL_PREFIX/lib/cmake/Qt6HostInfo/Qt6HostInfoConfig.cmake" ]; then
    echo "Qt6 host already built at $INSTALL_PREFIX — skipping"
    exit 0
fi

# Clean build dir
if [ -d "$BUILD_DIR" ]; then
    rm -rf "$BUILD_DIR"
fi
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

echo "--- Configuring (amd64 native, qtbase ONLY — provides Qt6HostInfo) ---"
# Build ONLY qtbase to get the host CMake infrastructure and tool binaries.
# No module dep whack-a-mole — qtbase/CMakeLists.txt is standalone.
QTBASE_SRC="$SRC/qtbase"

cmake "$QTBASE_SRC" \
    -GNinja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" \
    \
    -DQT_BUILD_TESTS=OFF \
    -DQT_BUILD_EXAMPLES=OFF \
    -DQT_BUILD_BENCHMARKS=OFF \
    -DQT_BUILD_DOCS=OFF \
    -DFEATURE_dbus=OFF \
    -DFEATURE_sql=OFF \
    -DFEATURE_opengl=OFF \
    -DFEATURE_gui=OFF \
    -DFEATURE_widgets=OFF \
    -DFEATURE_accessibility=OFF \
    -DFEATURE_network=OFF \
    2>&1

echo "--- Building with $(nproc) jobs ---"
ninja -j$(nproc) 2>&1

echo "--- Installing to $INSTALL_PREFIX ---"
ninja install 2>&1

echo "--- Verifying Qt6HostInfo ---"
HOSTINFO="$INSTALL_PREFIX/lib/cmake/Qt6HostInfo/Qt6HostInfoConfig.cmake"
if [ -f "$HOSTINFO" ]; then
    echo "SUCCESS: Qt6HostInfoConfig.cmake present"
else
    echo "ERROR: Qt6HostInfo not found — host build incomplete"
    find "$INSTALL_PREFIX/lib/cmake" -name "*HostInfo*" 2>/dev/null
    exit 1
fi

echo "=== Host Qt6.6.3 build complete: $(date) ==="
