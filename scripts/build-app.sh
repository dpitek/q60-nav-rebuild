#!/bin/bash
# build-app.sh — Cross-compile q60nav + eglfs_emgdhmi plugin + valhalla-httpd
#                for i686 Atom (Plan B''' Qt6 path) inside Docker.
#
# Usage: ./scripts/build-app.sh [clean]
#
# Inputs:
#   $ROOT/output/qt6-i386/                — pre-built Qt 6.6.3 i386 install
#   $ROOT/app/                            — source tree
#
# Outputs:
#   $ROOT/output/app-build/bin/q60nav
#   $ROOT/output/app-build/app/src/eglfs_emgdhmi/libqeglfs-emgdhmi-integration.so
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
BUILD_DIR="$ROOT/output/app-build"
OUTPUT="$ROOT/output/q60nav"
QT6_PREFIX="$ROOT/output/qt6-i386"

# Verify Qt i386 is built
if [ ! -f "$QT6_PREFIX/lib/libQt6Core.so.6" ]; then
    echo "ERROR: Qt 6 i386 not found at $QT6_PREFIX"
    echo "Run the Qt6 i386 source build first (deps/build-qt6-i386.sh)."
    exit 1
fi
if [ ! -f "$QT6_PREFIX/include/QtEglFSDeviceIntegration/6.6.3/QtEglFSDeviceIntegration/private/qeglfsdeviceintegration_p.h" ]; then
    echo "ERROR: QtEglFSDeviceIntegrationPrivate headers missing"
    echo "Qt6 build needs to be built with EglFSDeviceIntegration enabled."
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

        # Ensure i386 OpenGL is available for Qt6Gui cmake detection
        dpkg --add-architecture i386 || true
        apt-get update -qq

        # Runtime + dev deps. Note that both qt6-i386/ (cross target libs) AND
        # qt6-host/ (rcc/moc/qmlcachegen host-tools used during build) are
        # i386 binaries — Qt was built as a one-shot cross install. So ALL
        # the runtime libs we need are i386: libdouble-conversion3:i386,
        # libicu70:i386, libpcre2-16-0:i386, etc.
        echo '[build-app] Installing i386 build + Qt host-tool runtime deps...'
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
            libgl1-mesa-dev:i386 libgl-dev:i386 \
            libxkbcommon-dev:i386 libxkbcommon-x11-dev:i386 \
            libfontconfig1-dev:i386 libfreetype6-dev:i386 \
            libglib2.0-0:i386 libglib2.0-dev:i386 \
            libpcre2-dev:i386 libicu-dev:i386 \
            libdouble-conversion-dev:i386 libdouble-conversion3:i386 \
            libegl1-mesa-dev:i386 \
            libuv1-dev:i386 \
            libpng-dev:i386 libpng16-16:i386 \
            libjpeg-dev:i386 libjpeg-turbo8:i386 \
            libudev-dev:i386 \
            libinput-dev:i386 \
            libmtdev-dev:i386 \
            libdbus-1-dev:i386 \
            libxml2:i386 \
            libicu70:i386 libpcre2-16-0:i386 zlib1g:i386 \
            || { echo 'FATAL: i386 deps install failed'; exit 1; }
        echo '[build-app] i386 deps OK. libdouble-conversion check:'
        ls /usr/lib/i386-linux-gnu/libdouble-conversion* 2>&1 || true

        # ── valhalla-httpd ────────────────────────────────────────────────────
        echo '[build-app] Compiling valhalla-httpd.c...'
        gcc -m32 -march=i686 -mtune=bonnell -O2 \
            -o /build/rootfs/opt/valhalla/bin/valhalla-httpd \
            /build/rootfs/opt/valhalla/valhalla-httpd.c
        file /build/rootfs/opt/valhalla/bin/valhalla-httpd

        # ── q60nav Qt app + eglfs_emgdhmi plugin ─────────────────────────────
        mkdir -p /build/output/app-build && cd /build/output/app-build

        cmake /build/app \
            -GNinja \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_C_COMPILER=gcc \
            -DCMAKE_CXX_COMPILER=g++ \
            -DCMAKE_C_FLAGS='-m32 -march=i686 -mtune=bonnell' \
            -DCMAKE_CXX_FLAGS='-m32 -march=i686 -mtune=bonnell' \
            -DCMAKE_EXE_LINKER_FLAGS='-m32' \
            -DCMAKE_SHARED_LINKER_FLAGS='-m32' \
            -DCMAKE_PREFIX_PATH=/build/output/qt6-i386 \
            -DCROSS_COMPILE_I686=1 \
            -DCMAKE_LIBRARY_PATH=/usr/lib/i386-linux-gnu \
            -DCMAKE_INCLUDE_PATH=/usr/include \
            -DOPENGL_opengl_LIBRARY=/usr/lib/i386-linux-gnu/libOpenGL.so \
            -DOPENGL_glx_LIBRARY=/usr/lib/i386-linux-gnu/libGLX.so \
            -DOPENGL_INCLUDE_DIR=/usr/include \
            -DWITH_MAPLIBRE=OFF \
            2>&1 | tee /build/output/q60nav/cmake.log

        ninja -j\$(nproc) 2>&1 | tee /build/output/q60nav/build.log

        echo '[build-app] Build complete'
        echo '--- q60nav binary ---'
        find /build/output/app-build -name 'q60nav' -type f -exec file {} \; -exec ls -lh {} \;
        echo '--- eglfs_emgdhmi integration plugin ---'
        find /build/output/app-build -name 'libqeglfs-emgdhmi-integration*.so' -exec file {} \; -exec ls -lh {} \;

        # ── Stage 3: bundle i386 system libs we need at runtime on the DCU
        # The factory rootfs (MeeGo 2.11.90 / glibc 2.11.90) is too old for
        # our Qt6 binaries. Pull modern i386 versions of the runtime libs
        # Qt6 needs into output/app-build/runtime-libs/ so deploy-qt.sh
        # can copy them into /opt/q60qt/lib/ on Slot A.
        echo '[build-app] Bundling i386 runtime libs for DCU deployment...'
        RT=/build/output/app-build/runtime-libs
        rm -rf \"\$RT\" && mkdir -p \"\$RT\"
        for libname in \\
            libicuuc.so.70 libicui18n.so.70 libicudata.so.70 \\
            libdouble-conversion.so.3 libpcre2-16.so.0 libbrotlidec.so.1 \\
            libbrotlicommon.so.1 libfontconfig.so.1 libfreetype.so.6 \\
            libxkbcommon.so.0 libglib-2.0.so.0 libgthread-2.0.so.0 \\
            libpcre.so.3 libffi.so.8 \\
            libpng16.so.16 libz.so.1 libgraphite2.so.3 libharfbuzz.so.0 \\
            libuuid.so.1 libexpat.so.1 \\
            libGLX.so.0 libOpenGL.so.0 libGLdispatch.so.0 ; do
            for src in /usr/lib/i386-linux-gnu/\${libname}*; do
                [ -f \"\$src\" ] || continue
                cp -P \"\$src\" \"\$RT/\" 2>/dev/null || true
            done
        done
        # Make sure the SONAME-only entries also get a symlink to .so.X.Y
        # so dynamic linker resolves correctly.
        ls -l \"\$RT\" | head -20
        echo \"runtime-libs bundle: \$(ls \"\$RT\" | wc -l) files\"
    "

echo "[build-app] Done."
Q60NAV_BIN=$(find "$BUILD_DIR" -name 'q60nav' -type f 2>/dev/null | head -1)
PLUGIN=$(find "$BUILD_DIR" -name 'libqeglfs-emgdhmi-integration*.so' 2>/dev/null | head -1)
echo "  binary:  $Q60NAV_BIN"
echo "  plugin:  $PLUGIN"
file "$Q60NAV_BIN" 2>/dev/null || true
