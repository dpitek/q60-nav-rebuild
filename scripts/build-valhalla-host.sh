#!/bin/bash
# build-valhalla-host.sh — Build native amd64 Valhalla data tools inside q60-toolchain container
# These are used on the BUILD MACHINE (Mac via Docker) to generate tiles from OSM PBF.
# NOT cross-compiled — these run natively in the container to build tiles.
#
# Run from host: docker exec ecstatic_jennings bash /build/scripts/build-valhalla-host.sh
# Or:           docker exec -it ecstatic_jennings bash /build/scripts/build-valhalla-host.sh
set -euo pipefail

VALHALLA_SRC="/build/deps/valhalla"
BUILD_DIR="/build/deps/valhalla-build-host"
INSTALL_PREFIX="/build/deps/valhalla-host"
JOBS=$(nproc)

log() { echo -e "\n\033[1;32m>>> $*\033[0m"; }

log "Installing native amd64 build deps..."
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    libboost-all-dev \
    libprotobuf-dev \
    protobuf-compiler \
    libspatialite-dev \
    libgeos-dev \
    libluajit-5.1-dev \
    libcurl4-openssl-dev \
    zlib1g-dev \
    libxml2-dev \
    curl \
    tcl \
    2>/dev/null
log "Deps installed."

# ── Build SQLite3 from source with SQLITE_ENABLE_LOAD_EXTENSION ──────────────
# Ubuntu's libsqlite3-dev is compiled without SQLITE_ENABLE_LOAD_EXTENSION (security
# hardening). Valhalla's FindSQLite3.cmake hard-fails if that symbol is missing.
# Build a fresh static sqlite3 that has it.
SQLITE_VER="3450300"   # 3.45.3 — 2024 release
SQLITE_YEAR="2024"
SQLITE_SRC="/build/deps/sqlite3-src"
SQLITE_INSTALL="/build/deps/sqlite3-host"

if [ ! -f "${SQLITE_INSTALL}/lib/libsqlite3.a" ]; then
    log "Building SQLite3 from source (SQLITE_ENABLE_LOAD_EXTENSION)..."
    mkdir -p "${SQLITE_SRC}"
    curl -fsSL "https://www.sqlite.org/${SQLITE_YEAR}/sqlite-autoconf-${SQLITE_VER}.tar.gz" \
        | tar -xz -C "${SQLITE_SRC}" --strip-components=1
    cd "${SQLITE_SRC}"
    CFLAGS="-DSQLITE_ENABLE_LOAD_EXTENSION=1" \
        ./configure --prefix="${SQLITE_INSTALL}" \
                    --disable-shared --enable-static \
                    --disable-tcl --disable-editline
    make -j"${JOBS}"
    make install
    log "SQLite3 built: $(ls -lh ${SQLITE_INSTALL}/lib/libsqlite3.a)"
else
    log "SQLite3 already built at ${SQLITE_INSTALL} — skipping."
fi

log "Configuring native Valhalla build..."
mkdir -p "${BUILD_DIR}"

# Patch Valhalla's FindSQLite3.cmake — the cmake check_library_exists test links
# statically against libsqlite3.a without -ldl, so it can't resolve dlopen()
# that sqlite3_enable_load_extension internally uses. The symbol IS in our custom
# sqlite3 (built with SQLITE_ENABLE_LOAD_EXTENSION=1) — force the flag TRUE.
log "Patching FindSQLite3.cmake to bypass -ldl link test..."
SQLITE3_CMAKE="/build/deps/valhalla/cmake/FindSQLite3.cmake"
if grep -q "check_library_exists.*sqlite3_enable_load_extension" "${SQLITE3_CMAKE}"; then
    sed -i 's/check_library_exists.*sqlite3_enable_load_extension.*/set(SQLITE3_LOAD_EXTENSION TRUE)  # patched: symbol present, link test skipped (-ldl transitive dep)/' \
        "${SQLITE3_CMAKE}"
    echo "Patched."
else
    echo "Already patched or pattern not found — skipping."
fi

# Clear any inherited i386 pkg-config paths from Qt6 cross-compile env
unset PKG_CONFIG_LIBDIR
unset PKG_CONFIG_PATH
unset PKG_CONFIG_SYSROOT_DIR
export PKG_CONFIG_LIBDIR=/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/share/pkgconfig

cd "${BUILD_DIR}"
cmake "${VALHALLA_SRC}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="${INSTALL_PREFIX}" \
    -DBUILD_SHARED_LIBS=OFF \
    -DENABLE_PYTHON_BINDINGS=OFF \
    -DENABLE_NODE_BINDINGS=OFF \
    -DENABLE_TESTS=OFF \
    -DENABLE_BENCHMARKS=OFF \
    -DENABLE_HTTP=OFF \
    -DENABLE_SERVICES=OFF \
    -DENABLE_TOOLS=ON \
    -DENABLE_DATA_TOOLS=ON \
    \
    -DCMAKE_LIBRARY_PATH="/usr/lib/x86_64-linux-gnu" \
    -DCMAKE_INCLUDE_PATH="/usr/include" \
    \
    -DZLIB_LIBRARY=/usr/lib/x86_64-linux-gnu/libz.a \
    -DZLIB_INCLUDE_DIR=/usr/include \
    -DProtobuf_LIBRARY=/usr/lib/x86_64-linux-gnu/libprotobuf.a \
    -DProtobuf_LITE_LIBRARY=/usr/lib/x86_64-linux-gnu/libprotobuf-lite.a \
    -DProtobuf_INCLUDE_DIR=/usr/include \
    -DProtobuf_PROTOC_EXECUTABLE=/usr/bin/protoc \
    -DSQLITE3_LIBRARY="${SQLITE_INSTALL}/lib/libsqlite3.a" \
    -DSQLITE3_INCLUDE_DIR="${SQLITE_INSTALL}/include" \
    -GNinja

log "Building (${JOBS} jobs) — this takes ~10-15 min..."
ninja -j"${JOBS}" valhalla_build_tiles valhalla_build_admins valhalla_build_elevation

log "Installing to ${INSTALL_PREFIX}..."
mkdir -p "${INSTALL_PREFIX}/bin"
cp src/mjolnir/valhalla_build_tiles "${INSTALL_PREFIX}/bin/"
cp src/mjolnir/valhalla_build_admins "${INSTALL_PREFIX}/bin/" 2>/dev/null || true
cp src/skadi/valhalla_build_elevation "${INSTALL_PREFIX}/bin/" 2>/dev/null || true

log "Build complete. Binaries:"
ls -lh "${INSTALL_PREFIX}/bin/"

log "Test: valhalla_build_tiles --help"
"${INSTALL_PREFIX}/bin/valhalla_build_tiles" --help 2>&1 | head -5
