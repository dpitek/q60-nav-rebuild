#!/bin/bash
# Qt 5.15.18 LTS i386 build — Plan B replacement for build-qt6-i386.sh.
# Target: factory Clarion DCU (Linux 2.6.37 / glibc 2.13 era, Atom E6xx Tunnel Creek).
# Single-pass configure → make → make install; no separate host-tools build needed.

set -e

SRC=/build/deps/qt5-src/qt-everywhere-src-5.15.18
BUILD_DIR=/build/deps/qt5-build-i386
INSTALL_PREFIX=/build/output/qt5-i386
LOG_DIR="$INSTALL_PREFIX"

echo "=== Qt 5.15.18 i386 Build (Plan B) ==="
echo "Source:  $SRC"
echo "Build:   $BUILD_DIR"
echo "Install: $INSTALL_PREFIX"
echo "Started: $(date)"

mkdir -p "$LOG_DIR"

if [ ! -f "$SRC/configure" ]; then
    echo "ERROR: Qt 5.15 source not found at $SRC"
    echo "Fetch: https://download.qt.io/archive/qt/5.15/5.15.18/single/qt-everywhere-opensource-src-5.15.18.tar.xz"
    exit 1
fi

echo "int main(){}" | gcc -m32 -x c - -o /dev/null || {
    echo "ERROR: 32-bit gcc not available (install gcc-multilib)"
    exit 1
}

echo "--- Setting up i386 packages ---"
dpkg --add-architecture i386 2>/dev/null || true
apt-get update -qq
# NB: Mesa deps deliberately omitted. Plan B renders software through Qt Quick's
# raster backend; output buffers go to Weston as wl_shm (shared-memory) surfaces.
# Weston (running on factory EMGD GLES/EGL blobs) composites — we never touch GL.
# qtwayland is BUILT (not skipped). q60nav becomes an ivi-shell client.
PACKAGES=(
    libfontconfig1-dev:i386
    libfreetype6-dev:i386
    libxkbcommon-dev:i386
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
    libasound2-dev:i386
    libpulse-dev:i386
    libgstreamer-plugins-base1.0-dev:i386
    libwayland-dev:i386
    libwayland-egl-backend-dev:i386
)
apt-get install -y --no-install-recommends "${PACKAGES[@]}" 2>&1 | \
    tee "$LOG_DIR/apt-install.log" || \
    echo "WARNING: Some i386 packages failed — continuing"

export PKG_CONFIG_LIBDIR=/usr/lib/i386-linux-gnu/pkgconfig:/usr/lib/i386-linux-gnu/pkgconfig/x86
export PKG_CONFIG_PATH=/usr/lib/i386-linux-gnu/pkgconfig
export PKG_CONFIG_SYSROOT_DIR=/

if [ -d "$BUILD_DIR" ]; then
    echo "Cleaning previous build dir: $BUILD_DIR"
    rm -rf "$BUILD_DIR"
fi
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

echo "--- Configuring Qt 5.15.18 for i386 ---"

# linux-g++-32 mkspec ships with Qt 5 and already emits -m32 — no manual flag plumbing.
# We enable DBus (AudioService BlueZ AVRCP path) and linuxfb (factory framebuffer paint).
"$SRC/configure" \
    -prefix "$INSTALL_PREFIX" \
    -opensource -confirm-license \
    -release \
    -shared \
    -platform linux-g++-32 \
    \
    -c++std c++17 \
    -no-pch \
    -ltcg \
    \
    -nomake examples -nomake tests -nomake tools \
    \
    -qt-zlib -qt-libpng -qt-libjpeg -qt-pcre -qt-doubleconversion -qt-harfbuzz \
    \
    -dbus-linked \
    -openssl-linked \
    -fontconfig \
    -xkbcommon \
    \
    -no-opengl \
    -no-egl \
    -no-eglfs \
    -no-feature-vulkan \
    -no-xcb \
    -no-directfb \
    -qpa wayland \
    -linuxfb \
    \
    -gstreamer 1.0 \
    \
    -skip qt3d -skip qtactiveqt -skip qtandroidextras \
    -skip qtcharts -skip qtcoap -skip qtconnectivity \
    -skip qtdatavis3d -skip qtdoc -skip qtgamepad \
    -skip qtgraphicaleffects -skip qtlottie -skip qtmqtt \
    -skip qtnetworkauth -skip qtopcua -skip qtpurchasing \
    -skip qtquick3d -skip qtquicktimeline -skip qtremoteobjects \
    -skip qtscript -skip qtscxml -skip qtsensors -skip qtspeech \
    -skip qtsvg -skip qttools -skip qttranslations \
    -skip qtvirtualkeyboard -skip qtwebchannel -skip qtwebengine \
    -skip qtwebglplugin -skip qtwebsockets -skip qtwebview \
    -skip qtwinextras -skip qtx11extras -skip qtxmlpatterns \
    2>&1 | tee "$LOG_DIR/configure.log"

echo "--- Configure complete: $(date) ---"
echo "--- make -j$(nproc) ---"
make -j"$(nproc)" 2>&1 | tee "$LOG_DIR/make.log"

echo "--- make install ---"
make install 2>&1 | tee "$LOG_DIR/make-install.log"

echo "=== Install complete: $(date) ==="
LIBCORE="$INSTALL_PREFIX/lib/libQt5Core.so.5"
if [ -f "$LIBCORE" ]; then
    file "$LIBCORE"
    echo "SUCCESS: libQt5Core.so.5 present"
else
    echo "WARNING: libQt5Core.so.5 not found — scanning..."
    find "$INSTALL_PREFIX/lib" -name "libQt5Core*" -exec file {} \; 2>/dev/null | head -10
fi
