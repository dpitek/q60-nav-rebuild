#!/usr/bin/env bash
# =============================================================================
# build-maplibre-i386.sh
# Cross-compile MapLibre Native (tag qt-v2.0.1) for i386/Bonnell — Linux platform
# Target: MeeGo-based embedded Linux, Mesa swrast (no hardware GPU)
# Strategy: Build core library (no Qt platform — Qt bindings need Qt installed on target)
# =============================================================================
set -euo pipefail

OUTPUT_DIR=/build/output/maplibre-i386
mkdir -p "$OUTPUT_DIR"

BUILD_LOG="$OUTPUT_DIR/build.log"
exec > >(tee -a "$BUILD_LOG") 2>&1

echo "============================================================"
echo " MapLibre i386 Build — $(date -u)"
echo "============================================================"

# ---------------------------------------------------------------------------
# 1. Architecture setup
# ---------------------------------------------------------------------------
echo "[1/7] Setting up i386 architecture..."
dpkg --add-architecture i386
apt-get update -qq

# ---------------------------------------------------------------------------
# 2. Install i386 dependencies
# ---------------------------------------------------------------------------
echo "[2/7] Installing i386 build dependencies..."
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    gcc-multilib \
    g++-multilib \
    libgl1-mesa-dev:i386 \
    libgles2-mesa-dev:i386 \
    libegl1-mesa-dev:i386 \
    libglvnd-dev:i386 \
    libicu-dev:i386 \
    libuv1-dev:i386 \
    libcurl4-openssl-dev:i386 \
    libssl-dev:i386 \
    libpng-dev:i386 \
    libjpeg-dev:i386 \
    libsqlite3-dev:i386 \
    zlib1g-dev:i386 \
    libx11-dev:i386 \
    cmake \
    ninja-build \
    pkg-config \
    git \
    python3

echo "[2/7] Dependencies installed."

# ---------------------------------------------------------------------------
# 3. Verify i386 compile smoke test
# ---------------------------------------------------------------------------
echo "[3/7] Verifying i386 toolchain..."
cat > /tmp/smoke32.c << 'SMOKE'
#include <stdio.h>
int main() { printf("i386 OK\n"); return 0; }
SMOKE
gcc -m32 -march=bonnell -mtune=bonnell -o /tmp/smoke32 /tmp/smoke32.c
file /tmp/smoke32
/tmp/smoke32

# Verify pkg-config finds i386 libs
export PKG_CONFIG_PATH=/usr/lib/i386-linux-gnu/pkgconfig
export PKG_CONFIG_LIBDIR=/usr/lib/i386-linux-gnu/pkgconfig
echo "libuv: $(pkg-config --modversion libuv 2>/dev/null || echo NOT_FOUND)"
echo "libcurl: $(pkg-config --modversion libcurl 2>/dev/null || echo NOT_FOUND)"
echo "openssl: $(pkg-config --modversion openssl 2>/dev/null || echo NOT_FOUND)"
echo "[3/7] Toolchain OK."

# ---------------------------------------------------------------------------
# 4. Source check
# ---------------------------------------------------------------------------
SRC=/build/deps/maplibre-gl-native

if [ -d "$SRC/.git" ] || [ -f "$SRC/CMakeLists.txt" ]; then
    echo "[4/7] Source already present at $SRC — skipping clone."
else
    echo "[4/7] Cloning maplibre-native @ qt-v2.0.1..."
    git clone \
        --depth 1 \
        --branch qt-v2.0.1 \
        --recurse-submodules \
        --shallow-submodules \
        https://github.com/maplibre/maplibre-native.git \
        "$SRC"
    echo "[4/7] Clone complete."
fi

# ---------------------------------------------------------------------------
# 4b. Apply i386 source patches
# ---------------------------------------------------------------------------
# Patch 1: http_file_source.cpp — toString(long) deleted on i386 (long=32bit, toString(int) works)
HTTP_SRC="$SRC/platform/default/src/mbgl/storage/http_file_source.cpp"
if grep -q 'util::toString(responseCode)' "$HTTP_SRC"; then
    sed -i 's/util::toString(responseCode)/util::toString(static_cast<int>(responseCode))/g' "$HTTP_SRC"
    echo "[4b] Patched http_file_source.cpp: toString(long) -> toString(int) for i386"
fi

# Patch 2: glfw CMakeLists to make glfw OPTIONAL (glfw3-dev not available for i386)
# ---------------------------------------------------------------------------
echo "[4b] Patching platform/glfw/CMakeLists.txt to make glfw3 optional..."
GLFW_CMAKE="$SRC/platform/glfw/CMakeLists.txt"
if grep -q 'glfw3 REQUIRED' "$GLFW_CMAKE"; then
    sed -i 's/pkg_search_module(GLFW glfw3 REQUIRED)/pkg_search_module(GLFW glfw3)/' "$GLFW_CMAKE"
    # Wrap the executable in a conditional
    sed -i 's/^add_executable(\n    mbgl-glfw/if(GLFW_FOUND)\nadd_executable(\n    mbgl-glfw/' "$GLFW_CMAKE" || true
    # Simpler approach: prepend a guard at the top after the pkg_search_module
    python3 - "$GLFW_CMAKE" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()
# Replace REQUIRED with optional check
content = content.replace('pkg_search_module(GLFW glfw3 REQUIRED)', 'pkg_search_module(GLFW glfw3)')
# Wrap the rest of the file in if(GLFW_FOUND) after the find lines
lines = content.split('\n')
new_lines = []
found_exec = False
guard_inserted = False
for line in lines:
    if not found_exec and line.strip().startswith('add_executable(') and not guard_inserted:
        new_lines.append('if(GLFW_FOUND)')
        guard_inserted = True
        found_exec = True
    new_lines.append(line)
if guard_inserted:
    new_lines.append('endif()  # GLFW_FOUND')
with open(path, 'w') as f:
    f.write('\n'.join(new_lines))
print(f"Patched {path}")
PYEOF
fi
echo "[4b] glfw patch applied."

# ---------------------------------------------------------------------------
# 5. CMake configure
# ---------------------------------------------------------------------------
echo "[5/7] Running CMake configure (Linux platform, no Qt — core + EGL renderer)..."

BUILD_DIR=/tmp/maplibre-build-i386
mkdir -p "$BUILD_DIR"

# PKG_CONFIG_PATH must be set as environment variable BEFORE cmake runs
# cmake's set(ENV{PKG_CONFIG_PATH}...) in toolchain file is not reliable
export PKG_CONFIG_PATH=/usr/lib/i386-linux-gnu/pkgconfig:/usr/lib32/pkgconfig
export PKG_CONFIG_LIBDIR=/usr/lib/i386-linux-gnu/pkgconfig

cmake -S "$SRC" -B "$BUILD_DIR" \
    -G Ninja \
    \
    -DCMAKE_SYSTEM_NAME=Linux \
    -DCMAKE_SYSTEM_PROCESSOR=i686 \
    -DCMAKE_C_COMPILER=gcc \
    -DCMAKE_CXX_COMPILER=g++ \
    -DCMAKE_C_FLAGS="-m32 -march=bonnell -mtune=bonnell" \
    -DCMAKE_CXX_FLAGS="-m32 -march=bonnell -mtune=bonnell" \
    -DCMAKE_EXE_LINKER_FLAGS="-m32" \
    -DCMAKE_SHARED_LINKER_FLAGS="-m32" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$OUTPUT_DIR" \
    \
    -DMBGL_WITH_QT=OFF \
    -DMBGL_WITH_OPENGL=ON \
    -DMBGL_WITH_EGL=ON \
    -DMBGL_WITH_WERROR=OFF \
    -DMBGL_WITH_COVERAGE=OFF \
    -DMBGL_WITH_SANITIZER=OFF \
    \
    -DCMAKE_FIND_ROOT_PATH="/usr/lib/i386-linux-gnu;/usr/lib32;/lib/i386-linux-gnu" \
    -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=BOTH \
    -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH \
    -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH \
    \
    2>&1

echo "[5/7] CMake configure complete."

# ---------------------------------------------------------------------------
# 6. Build — target only mbgl-core (skip node/glfw test runners)
# ---------------------------------------------------------------------------
echo "[6/7] Building mbgl-core ($(nproc) jobs)..."

cmake --build "$BUILD_DIR" \
    --config Release \
    --target mbgl-core \
    --parallel "$(nproc)" \
    2>&1

echo "[6/7] Build complete."

# ---------------------------------------------------------------------------
# 7. Package output — manually copy since mbgl-core is STATIC (no install target for core alone)
# ---------------------------------------------------------------------------
echo "[7/7] Collecting output artifacts..."

mkdir -p "$OUTPUT_DIR/lib" "$OUTPUT_DIR/include"

# Copy the static core library
find "$BUILD_DIR" -name "libmbgl-core.a" -exec cp {} "$OUTPUT_DIR/lib/" \;
find "$BUILD_DIR" -name "libmbgl-vendor-*.a" -exec cp {} "$OUTPUT_DIR/lib/" \;

# Copy public headers
cp -r "$SRC/include/"* "$OUTPUT_DIR/include/" 2>/dev/null || true

echo ""
echo "============================================================"
echo " BUILD COMPLETE — Output verification"
echo "============================================================"

find "$OUTPUT_DIR/lib" -name "*.a" -o -name "*.so*" 2>/dev/null | sort | while read f; do
    echo "  $(file "$f")"
done

COREA="$OUTPUT_DIR/lib/libmbgl-core.a"
if [ -f "$COREA" ]; then
    echo ""
    echo "TARGET LIBRARY: $COREA"
    file "$COREA"
    python3 -c "
import struct, sys
with open('$COREA', 'rb') as f:
    sig = f.read(8)
# ar archive signature
if sig == b'!<arch>\n':
    print('Format: ar static library (correct)')
    # Read first object file header to check arch
    f2 = open('$COREA', 'rb')
    f2.read(8)  # skip !<arch>
    hdr = f2.read(60)
    name = hdr[:16].strip()
    size = int(hdr[48:58].strip())
    obj_data = f2.read(min(size, 20))
    # ELF check
    if obj_data[:4] == b'\x7fELF':
        ei_class = obj_data[4]
        e_machine = struct.unpack('<H', obj_data[18:20])[0]
        machines = {3:'i386', 62:'x86_64', 40:'ARM', 183:'AArch64'}
        print(f'ELF class: {ei_class} (1=32bit, 2=64bit)')
        print(f'Machine: {e_machine} = {machines.get(e_machine, \"unknown\")}')
        print('RESULT:', 'PASS - 32-bit i386' if ei_class==1 and e_machine==3 else 'FAIL - wrong arch')
    else:
        print('First object is not ELF — may be a fat/thin ar archive')
        print('Sig:', obj_data[:16])
else:
    print('Not an ar archive — unexpected format')
    print('Sig:', sig)
" 2>/dev/null || true
    ls -lh "$COREA"
else
    echo "WARNING: libmbgl-core.a not found"
    find "$BUILD_DIR" -name "*.a" 2>/dev/null | head -10
fi

echo ""
echo "Build log: $BUILD_LOG"
echo "Done: $(date -u)"
