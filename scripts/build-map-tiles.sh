#!/usr/bin/env bash
# build-map-tiles.sh — Build MapLibre vector tiles (co.mbtiles) from CO OSM PBF
# Uses tilemaker Docker image. Output: output/vector-tiles/co.mbtiles
#
# The style file (rootfs/opt/nav/style/q60-dark.json) references:
#   "url": "mbtiles:///opt/nav/tiles/co.mbtiles"
#
# Zoom range: z0–z14 (sufficient for in-car navigation, ~350-600MB for CO)
# Format: OpenMapTiles-compatible vector tiles (MVT inside MBTiles SQLite)
#
# Usage:
#   ./build-map-tiles.sh              # build from existing PBF
#   ./build-map-tiles.sh --fresh-pbf  # re-download CO PBF first
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

PBF_PATH="/tmp/colorado-latest.osm.pbf"
VECTOR_OUT="$PROJECT_ROOT/output/vector-tiles"
MBTILES_OUT="$VECTOR_OUT/co.mbtiles"
TILEMAKER_IMAGE="ghcr.io/systemed/tilemaker:master"

FRESH_PBF=false
[[ "${1:-}" == "--fresh-pbf" ]] && FRESH_PBF=true

# ─── Prerequisites ────────────────────────────────────────────────────────────
if $FRESH_PBF || [[ ! -f "$PBF_PATH" ]]; then
    echo "Downloading CO OSM PBF (~400MB)..."
    curl -L --progress-bar -o "$PBF_PATH" \
        "https://download.geofabrik.de/north-america/us/colorado-latest.osm.pbf"
fi

# Pull tilemaker image (multi-arch, works on arm64)
if ! docker image inspect "$TILEMAKER_IMAGE" &>/dev/null; then
    echo "Pulling tilemaker image..."
    docker pull "$TILEMAKER_IMAGE"
fi

mkdir -p "$VECTOR_OUT"

# ─── Write tilemaker config (OpenMapTiles schema subset) ─────────────────────
TILEMAKER_CFG="$VECTOR_OUT/tilemaker-config.json"
cat > "$TILEMAKER_CFG" << 'ENDCFG'
{
    "layers": {
        "water":            { "minzoom": 0,  "maxzoom": 14 },
        "waterway":         { "minzoom": 10, "maxzoom": 14 },
        "landcover":        { "minzoom": 0,  "maxzoom": 14 },
        "landuse":          { "minzoom": 8,  "maxzoom": 14 },
        "transportation":   { "minzoom": 4,  "maxzoom": 14 },
        "transportation_name": { "minzoom": 10, "maxzoom": 14 },
        "place":            { "minzoom": 3,  "maxzoom": 14 },
        "poi":              { "minzoom": 13, "maxzoom": 14 },
        "building":         { "minzoom": 14, "maxzoom": 14 }
    },
    "settings": {
        "name": "Q60Nav CO",
        "version": "1.0",
        "description": "Colorado vector tiles for Q60 navigation",
        "attribution": "OpenStreetMap contributors",
        "minzoom": 0,
        "maxzoom": 14,
        "basezoom": 14,
        "include_ids": false,
        "combine_below": 13,
        "compress": "gzip",
        "mvt_extent": 4096,
        "buffer": 64
    }
}
ENDCFG

# ─── Write tilemaker Lua process script (OpenMapTiles-compatible) ─────────────
TILEMAKER_LUA="$VECTOR_OUT/process.lua"
cat > "$TILEMAKER_LUA" << 'ENDLUA'
-- Minimal OpenMapTiles-compatible process.lua for Q60Nav
-- Generates layers: water, landcover, landuse, transportation, transportation_name, place, poi, building

-- ── Helpers ──────────────────────────────────────────────────────────────────
function Set(t)
    local s = {}
    for _,v in ipairs(t) do s[v] = true end
    return s
end

-- ── Node processing ───────────────────────────────────────────────────────────
function node_function()
    local place = Find("place")
    local amenity = Find("amenity")
    local shop = Find("shop")
    local name = Find("name")

    if place ~= "" and name ~= "" then
        local layer = Layer("place", false)
        AttributeNumeric("rank", 5)
        if     place == "city"     then AttributeNumeric("rank", 1)
        elseif place == "town"     then AttributeNumeric("rank", 2)
        elseif place == "village"  then AttributeNumeric("rank", 3)
        elseif place == "suburb"   then AttributeNumeric("rank", 4)
        end
        Attribute("name", name)
        Attribute("class", place)
        MinZoom(3)
    end

    if amenity ~= "" or shop ~= "" then
        local class = amenity ~= "" and amenity or shop
        Layer("poi", false)
        Attribute("name", name)
        Attribute("class", class)
        MinZoom(13)
    end
end

-- ── Way processing ────────────────────────────────────────────────────────────
highway_classes = {
    motorway = "motorway", motorway_link = "motorway",
    trunk = "trunk", trunk_link = "trunk",
    primary = "primary", primary_link = "primary",
    secondary = "secondary", secondary_link = "secondary",
    tertiary = "tertiary", tertiary_link = "tertiary",
    residential = "minor", unclassified = "minor",
    living_street = "minor", service = "service",
    track = "track", path = "path", footway = "path",
    cycleway = "path", pedestrian = "path", steps = "path",
}

highway_minzoom = {
    motorway = 4, trunk = 6, primary = 8,
    secondary = 10, tertiary = 11, minor = 12,
    service = 13, track = 13, path = 13,
}

function way_function()
    local highway  = Find("highway")
    local waterway = Find("waterway")
    local natural  = Find("natural")
    local landuse  = Find("landuse")
    local leisure  = Find("leisure")
    local building = Find("building")
    local name     = Find("name")

    -- Transportation
    if highway ~= "" then
        local class = highway_classes[highway]
        if class then
            local mz = highway_minzoom[class] or 12
            Layer("transportation", true)
            Attribute("class", class)
            MinZoom(mz)
            if name ~= "" and (class == "motorway" or class == "trunk" or
                               class == "primary" or class == "secondary") then
                Layer("transportation_name", true)
                Attribute("name", name)
                Attribute("class", class)
                MinZoom(mz + 2)
            end
        end
    end

    -- Waterways
    if waterway ~= "" and (waterway == "river" or waterway == "stream" or
                            waterway == "canal") then
        Layer("waterway", true)
        Attribute("class", waterway)
        Attribute("name", name)
        MinZoom(10)
    end

    -- Water areas
    if natural == "water" or natural == "lake" then
        Layer("water", false)
        MinZoom(0)
    end

    -- Landcover
    if natural == "wood" or natural == "forest" or
       landuse == "forest" or landuse == "wood" then
        Layer("landcover", false)
        Attribute("class", "wood")
        MinZoom(7)
    elseif natural == "grass" or natural == "meadow" or
           leisure == "park" or landuse == "grass" then
        Layer("landcover", false)
        Attribute("class", "grass")
        MinZoom(8)
    end

    -- Landuse
    if landuse == "residential" then
        Layer("landuse", false)
        Attribute("class", "residential")
        MinZoom(8)
    elseif landuse == "commercial" or landuse == "industrial" then
        Layer("landuse", false)
        Attribute("class", landuse)
        MinZoom(10)
    end

    -- Buildings
    if building ~= "" then
        Layer("building", false)
        MinZoom(14)
    end
end

-- ── Relation processing ───────────────────────────────────────────────────────
function relation_scan_function()
    if Find("type") == "multipolygon" then Accept() end
end

function relation_function()
    -- handled via ways
end
ENDLUA

# ─── Run tilemaker ────────────────────────────────────────────────────────────
echo ""
echo "=== Building vector tiles (MapLibre display) ==="
echo "Source:  $PBF_PATH"
echo "Output:  $MBTILES_OUT"
echo "Started: $(date)"
echo "NOTE: NC at z0-z14 takes 20-60 min and ~400-700MB"
echo ""

docker run --rm \
    -v "$(dirname "$PBF_PATH"):/pbf:ro" \
    -v "$VECTOR_OUT:/out" \
    "$TILEMAKER_IMAGE" \
    --input /pbf/colorado-latest.osm.pbf \
    --output /out/co.mbtiles \
    --config /out/tilemaker-config.json \
    --process /out/process.lua \
    --bbox "-84.3218,33.7529,-75.4601,36.5881" \
    2>&1

echo ""
echo "=== Vector tile build complete: $(date) ==="
if [[ -f "$MBTILES_OUT" ]]; then
    echo "  Output: $MBTILES_OUT ($(du -sh "$MBTILES_OUT" | cut -f1))"
    echo ""
    echo "Next: copy co.mbtiles to rootfs/opt/nav/tiles/ then run package-rootfs.sh"
else
    echo "ERROR: $MBTILES_OUT not created!"
    exit 1
fi
