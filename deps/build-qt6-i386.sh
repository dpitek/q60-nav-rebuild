#!/bin/bash
set -e

SRC=/build/deps/qt6-src/qt-everywhere-src-6.6.3
BUILD_DIR=/build/deps/qt6-build-i386
INSTALL_PREFIX=/build/output/qt6-i386
LOG_DIR="$INSTALL_PREFIX"

echo "=== Qt 6.6.3 i386 Build Script ==="
echo "Source:  $SRC"
echo "Build:   $BUILD_DIR"
echo "Install: $INSTALL_PREFIX"
echo "Started: $(date)"

mkdir -p "$LOG_DIR"

# Verify source exists
if [ ! -f "$SRC/CMakeLists.txt" ]; then
    echo "ERROR: Qt source not found at $SRC"
    exit 1
fi
echo "Source: OK"

# Verify 32-bit toolchain
echo "int main(){}" | gcc -m32 -x c - -o /dev/null || {
    echo "ERROR: 32-bit gcc not available (install gcc-multilib)"
    exit 1
}
echo "32-bit gcc: OK"

# Add i386 architecture and install deps
echo "--- Setting up i386 packages ---"
dpkg --add-architecture i386 2>/dev/null || true
apt-get update -qq

# Qt6.6.3 host (amd64) tools — built by build-qt6-host.sh — required for cross-compile.
# The host build provides Qt6HostInfo which Qt6 cross-compile mode requires.
QT_HOST_PATH=/build/deps/qt6-host

echo "--- Verifying Qt6 host tools ---"
HOSTINFO="$QT_HOST_PATH/lib/cmake/Qt6HostInfo/Qt6HostInfoConfig.cmake"
if [ ! -f "$HOSTINFO" ]; then
    echo "ERROR: Qt6 host build not found at $QT_HOST_PATH"
    echo "Run build-qt6-host.sh first: docker exec q60-host-build bash /build/deps/build-qt6-host.sh"
    exit 1
fi
echo "QT_HOST_PATH: $QT_HOST_PATH (Qt6HostInfo OK)"

# Core i386 build deps (best-effort — ignore failures on missing packages)
PACKAGES=(
    libfontconfig1-dev:i386
    libfreetype6-dev:i386
    libx11-dev:i386
    libx11-xcb-dev:i386
    libxext-dev:i386
    libxfixes-dev:i386
    libxi-dev:i386
    libxrender-dev:i386
    libxkbcommon-dev:i386
    libxkbcommon-x11-dev:i386
    libgl1-mesa-dev:i386
    libgles2-mesa-dev:i386
    libglib2.0-dev:i386
    libdbus-1-dev:i386
    libinput-dev:i386
    libudev-dev:i386
    libssl-dev:i386
    zlib1g-dev:i386
    libpcre2-dev:i386
    libdouble-conversion-dev:i386
    libicu-dev:i386
    libjpeg-dev:i386
    libpng-dev:i386
)

apt-get install -y --no-install-recommends "${PACKAGES[@]}" 2>&1 | \
    tee "$LOG_DIR/apt-install.log" || \
    echo "WARNING: Some i386 packages failed to install — continuing anyway"

echo "--- i386 package setup done ---"

# Point pkg-config at i386 libraries (cross-compile needs target arch paths)
export PKG_CONFIG_LIBDIR=/usr/lib/i386-linux-gnu/pkgconfig:/usr/lib/i386-linux-gnu/pkgconfig/x86
export PKG_CONFIG_PATH=/usr/lib/i386-linux-gnu/pkgconfig
# Prevent pkg-config from falling back to amd64 system paths
export PKG_CONFIG_SYSROOT_DIR=/

# Wipe any stale build dir (CMake cache from a bad config is worse than a clean build)
if [ -d "$BUILD_DIR" ]; then
    echo "Cleaning previous build dir: $BUILD_DIR"
    rm -rf "$BUILD_DIR"
fi
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

echo "--- Configuring Qt 6.6.3 for i386 ---"

# Qt6 cross-compile for i386 on amd64 host:
# - CMAKE_SYSTEM_PROCESSOR=i686 triggers cross-compile mode
# - QT_HOST_PATH must point to a native Qt6 build or be omitted
#   (omitting forces Qt to build host tools from source — slow but correct)
# - We disable anything that needs complex external deps or won't link 32-bit easily

cmake "$SRC" \
    -GNinja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" \
    \
    -DCMAKE_C_COMPILER=gcc \
    -DCMAKE_CXX_COMPILER=g++ \
    -DCMAKE_C_FLAGS="-m32 -march=bonnell -mtune=bonnell" \
    -DCMAKE_CXX_FLAGS="-m32 -march=bonnell -mtune=bonnell" \
    -DCMAKE_EXE_LINKER_FLAGS="-m32" \
    -DCMAKE_SHARED_LINKER_FLAGS="-m32" \
    -DCMAKE_MODULE_LINKER_FLAGS="-m32" \
    \
    -DQT_HOST_PATH="${QT_HOST_PATH}" \
    -DQT_HOST_PATH_CMAKE_DIR="${QT_HOST_PATH}/lib/cmake" \
    \
    -DBUILD_SHARED_LIBS=ON \
    \
    -DQT_BUILD_TESTS=OFF \
    -DQT_BUILD_EXAMPLES=OFF \
    -DQT_BUILD_BENCHMARKS=OFF \
    -DQT_BUILD_DOCS=OFF \
    \
    -DFEATURE_dbus=OFF \
    -DFEATURE_accessibility=OFF \
    -DFEATURE_sql=OFF \
    -DFEATURE_testlib=OFF \
    \
    -DFEATURE_opengl=ON \
    -DFEATURE_opengles2=OFF \
    -DFEATURE_opengl_desktop=ON \
    \
    -DQT_QPA_DEFAULT_PLATFORM=linuxfb \
    -DFEATURE_linuxfb=ON \
    -DFEATURE_wayland=OFF \
    -DFEATURE_xcb=ON \
    \
    -DFEATURE_network=ON \
    -DFEATURE_ssl=ON \
    -DFEATURE_serialbus=ON \
    -DFEATURE_socketcan=ON \
    \
    -DFEATURE_widgets=ON \
    -DFEATURE_quick=ON \
    -DFEATURE_quickcontrols2=ON \
    \
    -DFEATURE_reduce_relocations=OFF \
    \
    -DBUILD_qtwebengine=OFF \
    -DBUILD_qtmultimedia=OFF \
    -DBUILD_qtbluetooth=OFF \
    -DBUILD_qtlocation=OFF \
    -DBUILD_qt3d=OFF \
    -DBUILD_qtcharts=OFF \
    -DBUILD_qtdatavis3d=OFF \
    -DBUILD_qtpdf=OFF \
    -DBUILD_qtquick3d=OFF \
    -DBUILD_qtquick3dphysics=OFF \
    -DBUILD_qtgraphs=OFF \
    -DBUILD_qtcoap=OFF \
    -DBUILD_qtmqtt=OFF \
    -DBUILD_qtvirtualkeyboard=OFF \
    -DBUILD_qtdoc=OFF \
    -DBUILD_qtspeech=OFF \
    -DBUILD_qtremoteobjects=OFF \
    -DBUILD_qtscxml=OFF \
    -DBUILD_qtstatemachine=OFF \
    -DBUILD_qtwayland=OFF \
    2>&1 | tee "$LOG_DIR/cmake-configure.log"

echo "--- Configure complete: $(date) ---"
echo "--- Starting ninja build with $(nproc) parallel jobs ---"

ninja -j$(nproc) 2>&1 | tee "$LOG_DIR/ninja-build.log"

echo "--- Build complete: $(date) ---"
echo "--- Installing to $INSTALL_PREFIX ---"

ninja install 2>&1 | tee "$LOG_DIR/ninja-install.log"

echo "=== Install complete: $(date) ==="
echo "=== Verifying output ==="

LIBCORE="$INSTALL_PREFIX/lib/libQt6Core.so.6"
if [ -f "$LIBCORE" ]; then
    file "$LIBCORE"
    echo "SUCCESS: libQt6Core.so.6 present"
else
    echo "WARNING: libQt6Core.so.6 not found — scanning..."
    find "$INSTALL_PREFIX/lib" -name "libQt6Core*" -exec file {} \; 2>/dev/null | head -10
fi

echo "=== Qt 6.6.3 i386 build DONE: $(date) ==="
