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
    libsqlite3-dev \
    libspatialite-dev \
    libgeos-dev \
    libluajit-5.1-dev \
    libcurl4-openssl-dev \
    zlib1g-dev \
    libxml2-dev \
    2>/dev/null
log "Deps installed."

log "Configuring native Valhalla build..."
mkdir -p "${BUILD_DIR}"
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
