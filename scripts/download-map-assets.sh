#!/bin/bash
# download-map-assets.sh — Download offline MapLibre sprites and glyph PBFs
#
# Populates:
#   rootfs/opt/nav/style/sprites/   sprite.json, sprite.png, sprite@2x.json, sprite@2x.png
#   rootfs/opt/nav/style/fonts/     Noto Sans Bold/*.pbf, Noto Sans Regular/*.pbf
#
# Sources:
#   Sprites: openmaptiles/osm-bright-gl-style v1.11 release zip
#   Fonts:   openmaptiles/fonts v2.0 release (noto-sans.zip)
#
# Idempotent — skips downloads if files already present.
# Runs on the Mac host (no Docker needed) — requires: curl, unzip
#
# Usage: ./scripts/download-map-assets.sh
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
SPRITES_DIR="$ROOT/rootfs/opt/nav/style/sprites"
FONTS_DIR="$ROOT/rootfs/opt/nav/style/fonts"
TMP_DIR="$(mktemp -d)"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

echo "[download-map-assets] Starting..."
echo "  Sprites → $SPRITES_DIR"
echo "  Fonts   → $FONTS_DIR"
echo ""

# ── Sprites ────────────────────────────────────────────────────────────────
mkdir -p "$SPRITES_DIR"

if [ -f "$SPRITES_DIR/sprite.json" ] && [ -f "$SPRITES_DIR/sprite.png" ] \
   && [ -f "$SPRITES_DIR/sprite@2x.json" ] && [ -f "$SPRITES_DIR/sprite@2x.png" ]; then
    echo "[sprites] Already present — skipping download."
else
    echo "[sprites] Downloading osm-bright v1.11 sprites..."
    SPRITE_ZIP="$TMP_DIR/osm-bright-v1.11.zip"
    curl -fL --max-time 60 \
        "https://github.com/openmaptiles/osm-bright-gl-style/releases/download/v1.11/v1.11.zip" \
        -o "$SPRITE_ZIP"

    echo "[sprites] Extracting..."
    unzip -j "$SPRITE_ZIP" \
        "sprite.json" "sprite.png" "sprite@2x.json" "sprite@2x.png" \
        -d "$SPRITES_DIR/"

    # Validate
    python3 -c "
import json, sys
try:
    d = json.load(open('$SPRITES_DIR/sprite.json'))
    print(f'[sprites] sprite.json OK — {len(d)} icons')
except Exception as e:
    print(f'[sprites] ERROR: sprite.json invalid: {e}'); sys.exit(1)
"
    python3 -c "
with open('$SPRITES_DIR/sprite.png','rb') as f: sig=f.read(8)
if sig == b'\x89PNG\r\n\x1a\n': print('[sprites] sprite.png OK')
else: import sys; print('[sprites] ERROR: sprite.png bad signature'); sys.exit(1)
"
    echo "[sprites] Done."
fi

echo ""

# ── Fonts ───────────────────────────────────────────────────────────────────
BOLD_DIR="$FONTS_DIR/Noto Sans Bold"
REGULAR_DIR="$FONTS_DIR/Noto Sans Regular"

BOLD_COUNT=0
REGULAR_COUNT=0
[ -d "$BOLD_DIR" ]    && BOLD_COUNT=$(ls "$BOLD_DIR"/*.pbf 2>/dev/null | wc -l | tr -d ' ')
[ -d "$REGULAR_DIR" ] && REGULAR_COUNT=$(ls "$REGULAR_DIR"/*.pbf 2>/dev/null | wc -l | tr -d ' ')

if [ "$BOLD_COUNT" -ge 256 ] && [ "$REGULAR_COUNT" -ge 256 ]; then
    echo "[fonts] Noto Sans Bold ($BOLD_COUNT pbf) and Regular ($REGULAR_COUNT pbf) already present — skipping download."
else
    echo "[fonts] Downloading openmaptiles/fonts v2.0 noto-sans.zip (~62MB)..."
    mkdir -p "$FONTS_DIR"
    FONTS_ZIP="$TMP_DIR/noto-sans.zip"
    curl -fL --max-time 300 \
        "https://github.com/openmaptiles/fonts/releases/download/v2.0/noto-sans.zip" \
        -o "$FONTS_ZIP" --progress-bar

    echo "[fonts] Extracting Noto Sans Bold and Regular..."
    EXTRACT_DIR="$TMP_DIR/noto-fonts"
    mkdir -p "$EXTRACT_DIR"
    unzip -q "$FONTS_ZIP" -d "$EXTRACT_DIR"

    # Copy only the two fonts used by the style
    rm -rf "$BOLD_DIR" "$REGULAR_DIR"
    cp -r "$EXTRACT_DIR/Noto Sans Bold"    "$FONTS_DIR/"
    cp -r "$EXTRACT_DIR/Noto Sans Regular" "$FONTS_DIR/"

    BOLD_COUNT=$(ls "$BOLD_DIR"/*.pbf 2>/dev/null | wc -l | tr -d ' ')
    REGULAR_COUNT=$(ls "$REGULAR_DIR"/*.pbf 2>/dev/null | wc -l | tr -d ' ')
    echo "[fonts] Noto Sans Bold:    $BOLD_COUNT pbf files"
    echo "[fonts] Noto Sans Regular: $REGULAR_COUNT pbf files"

    if [ "$BOLD_COUNT" -lt 256 ] || [ "$REGULAR_COUNT" -lt 256 ]; then
        echo "[fonts] WARNING: expected 256 pbf files per font, got fewer."
        echo "        MapLibre will show blank labels for missing glyph ranges."
    else
        echo "[fonts] Done."
    fi
fi

echo ""
echo "[download-map-assets] Complete."
echo ""
echo "Summary:"
echo "  Sprites: $(ls "$SPRITES_DIR" | wc -l | tr -d ' ') files in $SPRITES_DIR"
echo "  Fonts:   $(du -sh "$FONTS_DIR" | cut -f1) total in $FONTS_DIR"
echo ""
echo "These files are inside rootfs/ and will be baked into the image by package-rootfs.sh."
