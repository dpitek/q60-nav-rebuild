#!/bin/bash
# =============================================================================
# Valhalla 3.4.0 — Cross-compile for Intel Atom E6xx (i686/i386, Bonnell)
# Runs inside q60-toolchain Docker container (Ubuntu 22.04 amd64)
# Mount: /build → /Users/dpitek/q60-rebuild  (persistent across runs)
# Sysroot lives on the mount so deps survive container restarts.
# Target: 32-bit, no prime_server, no Python, no NodeJS
# Output: /build/output/valhalla-i386/
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration — all paths under /build (the host mount) for persistence
# ---------------------------------------------------------------------------
MARCH_FLAGS="-m32 -march=bonnell -mtune=bonnell"
JOBS=$(nproc)
BUILD_ROOT="/build"
DEPS_DIR="${BUILD_ROOT}/deps"
VALHALLA_SRC="${DEPS_DIR}/valhalla"
INSTALL_PREFIX="${BUILD_ROOT}/output/valhalla-i386"
SYSROOT_PREFIX="${BUILD_ROOT}/deps/sysroot-i386"   # persistent sysroot on host mount
BUILD_CACHE="${DEPS_DIR}/.build-cache"
TMP_SRC="/tmp/dep-src"                              # ephemeral source downloads

export CC="gcc"
export CXX="g++"
export CFLAGS="${MARCH_FLAGS} -O2 -pipe"
export CXXFLAGS="${MARCH_FLAGS} -O2 -pipe -std=c++17"
export LDFLAGS="${MARCH_FLAGS}"
export PKG_CONFIG_PATH="${SYSROOT_PREFIX}/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="${SYSROOT_PREFIX}/lib/pkgconfig"

mkdir -p "${SYSROOT_PREFIX}/lib" "${SYSROOT_PREFIX}/include" \
         "${SYSROOT_PREFIX}/lib/pkgconfig" \
         "${BUILD_CACHE}" \
         "${INSTALL_PREFIX}" \
         "${TMP_SRC}"

log()  { echo -e "\n\033[1;36m>>> $*\033[0m"; }
die()  { echo -e "\033[1;31mFATAL: $*\033[0m" >&2; exit 1; }
built(){ [[ -f "${BUILD_CACHE}/$1.done" ]]; }
mark() { touch "${BUILD_CACHE}/$1.done"; }

# ---------------------------------------------------------------------------
# Step 0: apt packages
# ---------------------------------------------------------------------------
log "Installing apt build dependencies (i386 multiarch + build tools)..."
dpkg --add-architecture i386 2>/dev/null || true
apt-get update -qq 2>/dev/null
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    gcc-multilib g++-multilib \
    autoconf automake libtool \
    wget curl unzip \
    nasm \
    python3 \
    2>/dev/null

# Pull in i386 dev libs via apt
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    libc6-dev:i386 \
    zlib1g-dev:i386 \
    libxml2-dev:i386 \
    libluajit-5.1-dev:i386 \
    2>/dev/null || log "Some i386 apt packages unavailable — will build from source"

log "apt step done."

# ---------------------------------------------------------------------------
# Helper: download with retry
# ---------------------------------------------------------------------------
dl() {
    local dest="${@: -1}"   # last arg is dest
    [[ -f "${dest}" ]] && return 0
    for url in "${@:1:$(($#-1))}"; do
        log "Downloading $(basename ${dest}) from ${url}..."
        wget -q --timeout=120 --tries=5 --retry-connrefused \
             --waitretry=5 -O "${dest}" "${url}" && return 0
        rm -f "${dest}"
        log "  ... failed, trying next URL"
    done
    die "All download URLs failed for: ${dest}"
}

# ---------------------------------------------------------------------------
# Step 1: zlib (needed by protobuf, curl, etc.)
# ---------------------------------------------------------------------------
if ! built "zlib"; then
    log "Building zlib 1.3.1 for i386..."
    cd "${TMP_SRC}"
    dl "https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz" zlib.tar.gz
    tar -xf zlib.tar.gz
    cd zlib-1.3.1
    # zlib configure doesn't support --host, use env vars
    CFLAGS="${CFLAGS}" \
    ./configure --prefix="${SYSROOT_PREFIX}" --static
    make -j${JOBS}
    make install
    mark "zlib"
    log "zlib done."
fi

# ---------------------------------------------------------------------------
# Step 2: Protobuf 3.21.12
# We need TWO things:
#   a) libprotobuf.a compiled as i386 (for linking Valhalla)
#   b) protoc binary (native x86_64) for code generation
# Strategy: build protobuf twice — once native (for protoc), once i386 (for lib)
# ---------------------------------------------------------------------------
if ! built "protoc-host"; then
    log "Building native protoc (host x86_64) for code generation..."
    cd "${TMP_SRC}"
    dl "https://github.com/protocolbuffers/protobuf/releases/download/v21.12/protobuf-cpp-3.21.12.tar.gz" protobuf.tar.gz
    tar -xf protobuf.tar.gz
    cd protobuf-3.21.12
    mkdir -p build-host && cd build-host
    # Explicitly unset cross-compile env so this is a pure native x86_64 build
    env -u CFLAGS -u CXXFLAGS -u LDFLAGS \
        ../configure --prefix="${SYSROOT_PREFIX}/host" \
        --disable-shared --enable-static
    env -u CFLAGS -u CXXFLAGS -u LDFLAGS make -j${JOBS}
    env -u CFLAGS -u CXXFLAGS -u LDFLAGS make install
    # Symlink protoc to a known path
    ln -sf "${SYSROOT_PREFIX}/host/bin/protoc" /usr/local/bin/protoc 2>/dev/null || true
    mark "protoc-host"
    log "Native protoc done: $("${SYSROOT_PREFIX}/host/bin/protoc" --version 2>/dev/null)"
fi

PROTOC_BIN="${SYSROOT_PREFIX}/host/bin/protoc"
[[ -x "${PROTOC_BIN}" ]] || PROTOC_BIN="$(which protoc 2>/dev/null)" || die "protoc not found"

if ! built "protobuf-i386"; then
    log "Building protobuf 3.21.12 for i386..."
    cd "${TMP_SRC}/protobuf-3.21.12"
    mkdir -p build-i386 && cd build-i386
    ../configure --prefix="${SYSROOT_PREFIX}" \
        --host=i686-linux-gnu \
        --build=x86_64-linux-gnu \
        --disable-shared --enable-static \
        --with-pic \
        --with-protoc="${PROTOC_BIN}" \
        --with-zlib \
        --with-zlib-include="${SYSROOT_PREFIX}/include" \
        --with-zlib-lib="${SYSROOT_PREFIX}/lib" \
        CFLAGS="${CFLAGS}" CXXFLAGS="${CXXFLAGS}" LDFLAGS="${LDFLAGS} -L${SYSROOT_PREFIX}/lib"
    # Build only the library targets, not protoc (it's cross-compiling i386)
    make -j${JOBS} -C src libprotobuf.la libprotobuf-lite.la
    make -j${JOBS} -C src install-libLTLIBRARIES install-nobase_includeHEADERS
    # Copy pkgconfig
    cp -f protobuf.pc "${SYSROOT_PREFIX}/lib/pkgconfig/" 2>/dev/null || \
        cp -f src/protobuf.pc "${SYSROOT_PREFIX}/lib/pkgconfig/" 2>/dev/null || true
    mark "protobuf-i386"
    log "protobuf i386 done."
fi

# ---------------------------------------------------------------------------
# Step 3: Boost 1.82
# ---------------------------------------------------------------------------
if ! built "boost"; then
    log "Building Boost 1.82 for i386..."
    cd "${TMP_SRC}"
    dl "https://archives.boost.io/release/1.82.0/source/boost_1_82_0.tar.gz" boost.tar.gz
    tar -xf boost.tar.gz
    cd boost_1_82_0
    ./bootstrap.sh --prefix="${SYSROOT_PREFIX}" \
        --with-libraries=filesystem,regex,date_time,thread,system,iostreams,program_options

    cat > /tmp/boost-user-config.jam <<'JAM'
using gcc : i386 : g++ :
  <cflags>"-m32 -march=bonnell -mtune=bonnell -O2"
  <cxxflags>"-m32 -march=bonnell -mtune=bonnell -O2 -std=c++17"
  <linkflags>"-m32 -march=bonnell -mtune=bonnell"
  ;
JAM

    ./b2 --user-config=/tmp/boost-user-config.jam \
        toolset=gcc-i386 \
        address-model=32 \
        instruction-set=atom \
        variant=release \
        link=static \
        threading=multi \
        --prefix="${SYSROOT_PREFIX}" \
        -j${JOBS} \
        install
    mark "boost"
    log "Boost done."
fi

# ---------------------------------------------------------------------------
# Step 4: SQLite3 3.42
# ---------------------------------------------------------------------------
if ! built "sqlite3"; then
    log "Building SQLite3 3.42 for i386..."
    cd "${TMP_SRC}"
    dl "https://www.sqlite.org/2023/sqlite-autoconf-3420000.tar.gz" sqlite3.tar.gz
    tar -xf sqlite3.tar.gz
    cd sqlite-autoconf-3420000
    ./configure --prefix="${SYSROOT_PREFIX}" \
        --host=i686-linux-gnu \
        --build=x86_64-linux-gnu \
        --enable-static --disable-shared \
        CFLAGS="${CFLAGS}" LDFLAGS="${LDFLAGS}"
    make -j${JOBS}
    make install
    mark "sqlite3"
    log "SQLite3 done."
fi

# ---------------------------------------------------------------------------
# Step 5: PROJ 9.2.1 (SpatiaLite dependency)
# ---------------------------------------------------------------------------
if ! built "proj"; then
    log "Building PROJ 9.2.1 for i386..."
    cd "${TMP_SRC}"
    dl "https://download.osgeo.org/proj/proj-9.2.1.tar.gz" proj.tar.gz
    tar -xf proj.tar.gz
    cd proj-9.2.1
    mkdir -p build-i386 && cd build-i386
    cmake .. \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="${SYSROOT_PREFIX}" \
        -DCMAKE_C_FLAGS="${CFLAGS}" \
        -DCMAKE_CXX_FLAGS="${CXXFLAGS}" \
        -DCMAKE_EXE_LINKER_FLAGS="${LDFLAGS}" \
        -DCMAKE_SHARED_LINKER_FLAGS="${LDFLAGS}" \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_TESTING=OFF \
        -DBUILD_APPS=OFF \
        -DENABLE_CURL=OFF \
        -DENABLE_TIFF=OFF \
        -DPROJ_NETWORK=OFF \
        -DSQLITE3_INCLUDE_DIR="${SYSROOT_PREFIX}/include" \
        -DSQLITE3_LIBRARY="${SYSROOT_PREFIX}/lib/libsqlite3.a" \
        -DZLIB_INCLUDE_DIR="${SYSROOT_PREFIX}/include" \
        -DZLIB_LIBRARY="${SYSROOT_PREFIX}/lib/libz.a"
    make -j${JOBS}
    make install
    mark "proj"
    log "PROJ done."
fi

# ---------------------------------------------------------------------------
# Step 6: SpatiaLite 5.1.0
# Configured --disable-geos to avoid that dep chain
# ---------------------------------------------------------------------------
if ! built "spatialite"; then
    log "Building SpatiaLite 5.0.1 for i386..."
    cd "${TMP_SRC}"
    # Pre-staged on host mount to avoid container DNS issues
    if [[ -f "${DEPS_DIR}/spatialite-5.0.1.tar.gz" ]]; then
        cp "${DEPS_DIR}/spatialite-5.0.1.tar.gz" spatialite.tar.gz
    else
        dl \
            "https://www.gaia-gis.it/gaia-sins/libspatialite-5.0.1.tar.gz" \
            spatialite.tar.gz
    fi
    tar -xf spatialite.tar.gz
    cd libspatialite-5.0.1
    ./configure --prefix="${SYSROOT_PREFIX}" \
        --host=i686-linux-gnu \
        --build=x86_64-linux-gnu \
        --enable-static --disable-shared \
        --disable-geos \
        --disable-proj \
        --disable-rttopo \
        --disable-minizip \
        --disable-freexl \
        --disable-libxml2 \
        --disable-examples \
        --disable-tests \
        CFLAGS="${CFLAGS} -I${SYSROOT_PREFIX}/include -I/usr/include/libxml2" \
        CPPFLAGS="-I${SYSROOT_PREFIX}/include -I/usr/include/libxml2" \
        LDFLAGS="${LDFLAGS} -L${SYSROOT_PREFIX}/lib -L/usr/lib/i386-linux-gnu" \
        LIBS="-lxml2 -lsqlite3 -lz -lm" \
        PKG_CONFIG="i686-linux-gnu-pkg-config" \
        PKG_CONFIG_PATH="${PKG_CONFIG_PATH}:/usr/lib/i386-linux-gnu/pkgconfig" \
        PKG_CONFIG_LIBDIR="/usr/lib/i386-linux-gnu/pkgconfig:${SYSROOT_PREFIX}/lib/pkgconfig"
    make -j${JOBS}
    make install
    mark "spatialite"
    log "SpatiaLite done."
fi

# ---------------------------------------------------------------------------
# Step 7a: GEOS 3.11.3 (required by Valhalla's adminbuilder for polygon ops)
# ---------------------------------------------------------------------------
if ! built "geos"; then
    log "Building GEOS 3.11.3 for i386..."
    cd "${TMP_SRC}"
    if [[ -f "${DEPS_DIR}/geos-3.11.3.tar.bz2" ]]; then
        cp "${DEPS_DIR}/geos-3.11.3.tar.bz2" geos.tar.bz2
    else
        dl "https://download.osgeo.org/geos/geos-3.11.3.tar.bz2" geos.tar.bz2
    fi
    tar -xf geos.tar.bz2
    cd geos-3.11.3
    mkdir -p build-i386 && cd build-i386
    cmake .. \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="${SYSROOT_PREFIX}" \
        -DCMAKE_C_FLAGS="${CFLAGS}" \
        -DCMAKE_CXX_FLAGS="${CXXFLAGS}" \
        -DCMAKE_EXE_LINKER_FLAGS="${LDFLAGS}" \
        -DCMAKE_SHARED_LINKER_FLAGS="${LDFLAGS}" \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_TESTING=OFF \
        -DGEOS_BUILD_DEVELOPER=OFF
    make -j${JOBS}
    make install
    mark "geos"
    log "GEOS done."
fi

# ---------------------------------------------------------------------------
# Step 7: cURL (Valhalla uses it for HTTP tile fetching)
# ---------------------------------------------------------------------------
if ! built "curl"; then
    log "Building curl 8.4.0 for i386..."
    cd "${TMP_SRC}"
    dl "https://curl.se/download/curl-8.4.0.tar.gz" curl.tar.gz
    tar -xf curl.tar.gz
    cd curl-8.4.0
    ./configure --prefix="${SYSROOT_PREFIX}" \
        --host=i686-linux-gnu \
        --build=x86_64-linux-gnu \
        --enable-static --disable-shared \
        --without-libpsl \
        --without-ca-bundle \
        --without-ca-path \
        --disable-ldap \
        --disable-ldaps \
        --without-ssl \
        CFLAGS="${CFLAGS}" LDFLAGS="${LDFLAGS}"
    make -j${JOBS}
    make install
    mark "curl"
    log "curl done."
fi

# ---------------------------------------------------------------------------
# Step 8: Valhalla CMake build
# ---------------------------------------------------------------------------
log "=== Starting Valhalla 3.4.0 CMake build for i386 ==="

VALHALLA_BUILD="${DEPS_DIR}/valhalla-build-i386"
mkdir -p "${VALHALLA_BUILD}"
cd "${VALHALLA_BUILD}"

log "Configuring CMake..."
export LIB_DIR="${SYSROOT_PREFIX}"
cmake "${VALHALLA_SRC}" \
    -GNinja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="${INSTALL_PREFIX}" \
    \
    -DCMAKE_C_COMPILER=gcc \
    -DCMAKE_CXX_COMPILER=g++ \
    -DCMAKE_C_FLAGS="${CFLAGS} -I${SYSROOT_PREFIX}/include" \
    -DCMAKE_CXX_FLAGS="${CXXFLAGS} -I${SYSROOT_PREFIX}/include" \
    -DCMAKE_EXE_LINKER_FLAGS="${LDFLAGS} -L${SYSROOT_PREFIX}/lib -L/usr/lib/i386-linux-gnu -Wl,--start-group -lxml2 -lz -lm -Wl,--end-group" \
    -DCMAKE_SHARED_LINKER_FLAGS="${LDFLAGS} -L${SYSROOT_PREFIX}/lib -L/usr/lib/i386-linux-gnu" \
    \
    -DBOOST_ROOT="${SYSROOT_PREFIX}" \
    -DBOOST_LIBRARYDIR="${SYSROOT_PREFIX}/lib" \
    -DBOOST_INCLUDEDIR="${SYSROOT_PREFIX}/include" \
    -DBoost_USE_STATIC_LIBS=ON \
    -DBoost_NO_SYSTEM_PATHS=ON \
    \
    -DProtobuf_INCLUDE_DIR="${SYSROOT_PREFIX}/include" \
    -DProtobuf_LIBRARY="${SYSROOT_PREFIX}/lib/libprotobuf.a" \
    -DProtobuf_LITE_LIBRARY="${SYSROOT_PREFIX}/lib/libprotobuf.a" \
    -DProtobuf_PROTOC_EXECUTABLE="${PROTOC_BIN}" \
    \
    -DSQLITE3_INCLUDE_DIR="${SYSROOT_PREFIX}/include" \
    -DSQLITE3_LIBRARY="${SYSROOT_PREFIX}/lib/libsqlite3.a" \
    -DSQLITE3_LIBRARIES="${SYSROOT_PREFIX}/lib/libsqlite3.a" \
    "-DSQLITE3_LOAD_EXTENSION:BOOL=1" \
    \
    -DSPATIALITE_INCLUDE_DIR="${SYSROOT_PREFIX}/include" \
    -DSPATIALITE_LIBRARY="${SYSROOT_PREFIX}/lib/libspatialite.a" \
    -DSPATIALITE_LIBRARIES="${SYSROOT_PREFIX}/lib/libspatialite.a" \
    "-DSPATIALITE_VERSION_GE_4_2_0:BOOL=1" \
    \
    -DZLIB_INCLUDE_DIR="${SYSROOT_PREFIX}/include" \
    -DZLIB_LIBRARY="${SYSROOT_PREFIX}/lib/libz.a" \
    \
    -DCURL_INCLUDE_DIR="${SYSROOT_PREFIX}/include" \
    -DCURL_LIBRARY="${SYSROOT_PREFIX}/lib/libcurl.a" \
    \
    -DLUA_INCLUDE_DIR=/usr/include/luajit-2.1 \
    -DLUA_LIBRARIES=/usr/lib/i386-linux-gnu/libluajit-5.1.a \
    \
    -DGEOS_INCLUDE_DIR="${SYSROOT_PREFIX}/include" \
    -DGEOS_LIBRARY="${SYSROOT_PREFIX}/lib/libgeos.a" \
    \
    -DENABLE_SERVICES=OFF \
    -DENABLE_HTTP=OFF \
    -DENABLE_PYTHON_BINDINGS=OFF \
    -DENABLE_TESTS=OFF \
    -DENABLE_BENCHMARKS=OFF \
    -DENABLE_CCACHE=OFF \
    -DENABLE_COMPILER_WARNINGS=OFF \
    -DENABLE_WERROR=OFF \
    -DENABLE_SINGLE_FILES_WERROR=OFF \
    -DENABLE_TOOLS=ON \
    -DENABLE_DATA_TOOLS=ON \
    -DENABLE_STATIC_LIBRARY_MODULES=OFF \
    2>&1 | tee "${BUILD_ROOT}/output/cmake-configure.log"

log "Building valhalla_service and valhalla_build_tiles..."
ninja -j${JOBS} valhalla_service valhalla_build_tiles \
    2>&1 | tee "${BUILD_ROOT}/output/cmake-build.log"

# ---------------------------------------------------------------------------
# Step 9: Install and verify
# ---------------------------------------------------------------------------
log "Installing..."
ninja install 2>&1 | tee -a "${BUILD_ROOT}/output/cmake-build.log" || true
# Also copy from build tree if install doesn't work
for BIN in valhalla_service valhalla_build_tiles; do
    SRC=$(find "${VALHALLA_BUILD}" -name "${BIN}" -type f 2>/dev/null | head -1)
    DST="${INSTALL_PREFIX}/bin/${BIN}"
    if [[ -f "${SRC}" && ! -f "${DST}" ]]; then
        mkdir -p "${INSTALL_PREFIX}/bin"
        cp "${SRC}" "${DST}"
    fi
done

log "=== Build complete — verifying binaries ==="
FAILURES=0
for BIN in valhalla_service valhalla_build_tiles; do
    BIN_PATH="${INSTALL_PREFIX}/bin/${BIN}"
    if [[ -f "${BIN_PATH}" ]]; then
        echo ""
        echo "--- ${BIN} ---"
        file "${BIN_PATH}"
        ls -lh "${BIN_PATH}"
    else
        echo "WARNING: ${BIN} NOT FOUND. Searching build tree..."
        find "${VALHALLA_BUILD}" -name "${BIN}" -type f 2>/dev/null | head -5
        FAILURES=$((FAILURES+1))
    fi
done

echo ""
if [[ ${FAILURES} -eq 0 ]]; then
    log "SUCCESS — all binaries built at ${INSTALL_PREFIX}/bin/"
else
    log "PARTIAL — ${FAILURES} binary/binaries missing"
fi

ls -lh "${INSTALL_PREFIX}/bin/" 2>/dev/null || echo "(bin dir empty)"
