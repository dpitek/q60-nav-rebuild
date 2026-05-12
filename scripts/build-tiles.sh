#!/usr/bin/env bash
# build-tiles.sh — Build Valhalla routing tiles from NC OSM PBF
# Uses the official Valhalla Docker image (no host-tool build required).
# Output lands at <repo-root>/output/valhalla-tiles/
#
# Usage:
#   ./build-tiles.sh                  # use existing PBF
#   ./build-tiles.sh --fresh-pbf      # re-download NC PBF first
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

PBF_PATH="/tmp/north-carolina-latest.osm.pbf"
TILES_OUT="$PROJECT_ROOT/output/valhalla-tiles"
CONFIG_TEMPLATE="$PROJECT_ROOT/output/valhalla-config.json"
BUILD_CONFIG="/tmp/valhalla-build.json"

VALHALLA_IMAGE="ghcr.io/valhalla/valhalla:latest"   # arm64 + amd64, use native

FRESH_PBF=false
[[ "${1:-}" == "--fresh-pbf" ]] && FRESH_PBF=true

# ─── Prerequisites ────────────────────────────────────────────────────────────
if $FRESH_PBF || [[ ! -f "$PBF_PATH" ]]; then
    echo "Downloading NC OSM PBF (~400MB)..."
    curl -L --progress-bar -o "$PBF_PATH" \
        "https://download.geofabrik.de/north-america/us/north-carolina-latest.osm.pbf"
fi

PBF_SIZE=$(stat -f%z "$PBF_PATH" 2>/dev/null || stat -c%s "$PBF_PATH")
echo "PBF: $PBF_PATH ($(numfmt --to=iec $PBF_SIZE 2>/dev/null || echo "${PBF_SIZE}B"))"

# ─── Ensure Valhalla image is available ───────────────────────────────────────
if ! docker image inspect "$VALHALLA_IMAGE" &>/dev/null; then
    echo "Pulling Valhalla image..."
    docker pull "$VALHALLA_IMAGE"
fi

mkdir -p "$TILES_OUT"

# ─── Build config with local tile_dir ─────────────────────────────────────────
# The official image expects config at /conf/valhalla.json
# tile_dir must be writable inside the container — we mount TILES_OUT to /tiles
python3 -c "
import json, sys
with open('$CONFIG_TEMPLATE') as f:
    cfg = json.load(f)
cfg['mjolnir']['tile_dir'] = '/tiles'
cfg['mjolnir']['admin'] = '/tiles/admins.db'
cfg['mjolnir']['timezone'] = '/tiles/tz_world.sqlite'
cfg['mjolnir']['concurrency'] = 4
cfg['mjolnir']['logging']['type'] = 'std_out'
print(json.dumps(cfg, indent=2))
" > "$BUILD_CONFIG"

echo ""
echo "=== Building Valhalla routing tiles ==="
echo "Source:  $PBF_PATH"
echo "Output:  $TILES_OUT"
echo "Started: $(date)"
echo ""

# ─── Step 1: Build admin database ─────────────────────────────────────────────
echo "--- Step 1/3: Building admin DB (turn restrictions, country codes) ---"
docker run --rm \
    -v "$TILES_OUT:/tiles" \
    -v "$(dirname "$PBF_PATH"):/pbf:ro" \
    -v "$BUILD_CONFIG:/conf/valhalla.json:ro" \
    "$VALHALLA_IMAGE" \
    valhalla_build_admins \
        -c /conf/valhalla.json \
        /pbf/north-carolina-latest.osm.pbf \
    2>&1 || echo "WARNING: Admin build failed or not available — continuing"

# ─── Step 2: Build routing tiles ──────────────────────────────────────────────
echo ""
echo "--- Step 2/3: Building routing tiles (20-45 min for NC) ---"
docker run --rm \
    -v "$TILES_OUT:/tiles" \
    -v "$(dirname "$PBF_PATH"):/pbf:ro" \
    -v "$BUILD_CONFIG:/conf/valhalla.json:ro" \
    "$VALHALLA_IMAGE" \
    valhalla_build_tiles \
        -c /conf/valhalla.json \
        /pbf/north-carolina-latest.osm.pbf \
    2>&1

echo ""
echo "--- Step 3/3: Extracting tile tarball (for efficient device deployment) ---"
# Create a tarball so deploy-tiles.sh can extract directly to p8
cd "$TILES_OUT"
TARBALL="$PROJECT_ROOT/output/valhalla-tiles.tar.gz"
tar -czf "$TARBALL" . && echo "Created: $TARBALL ($(du -sh "$TARBALL" | cut -f1))"

echo ""
echo "=== Tile build complete: $(date) ==="
TILE_COUNT=$(find "$TILES_OUT" -name "*.bin" -o -name "*.gph" 2>/dev/null | wc -l | tr -d ' ')
echo "  Tile count: $TILE_COUNT"
echo "  Total size: $(du -sh "$TILES_OUT" | cut -f1)"
echo ""
echo "Next: ./deploy-tiles.sh <mount-point>"
