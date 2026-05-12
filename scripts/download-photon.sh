#!/bin/bash
# download-photon.sh — Download and index Photon offline geocoder for NC region
#
# Run this on your Mac (not on the device) before packaging the rootfs image.
# Takes 10-20 minutes for the indexing step — go get coffee.
#
# What it does:
#   1. Downloads the latest stable photon.jar from komoot/photon on GitHub
#   2. Downloads the NC OpenStreetMap PBF extract from Geofabrik
#   3. Runs the Photon indexer (Java) — creates photon_data/ with Lucene index
#   4. Outputs: output/photon-data/photon.jar + output/photon-data/photon_data/
#
# Device deployment (package-rootfs.sh handles this automatically):
#   /opt/photon/photon.jar
#   /opt/photon/photon_data/     (Lucene index, ~500MB-1GB for NC)
#
# Prerequisites:
#   - Java 11+ on this Mac: brew install openjdk@11
#   - curl
#   - ~3GB free disk space (PBF ~300MB, index ~500-900MB)
#
# Usage:
#   ./scripts/download-photon.sh
#   ./scripts/download-photon.sh --skip-download   # reuse existing PBF

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
OUTPUT_DIR="$ROOT/output/photon-data"
PBF_CACHE="$ROOT/output/nc-osm-cache"
PBF_FILE="$PBF_CACHE/north-carolina-latest.osm.pbf"
JAR_OUTPUT="$OUTPUT_DIR/photon.jar"
DATA_OUTPUT="$OUTPUT_DIR/photon_data"

GEOFABRIK_URL="https://download.geofabrik.de/north-america/us/north-carolina-latest.osm.pbf"
PHOTON_GITHUB_API="https://api.github.com/repos/komoot/photon/releases/latest"

SKIP_DOWNLOAD=0
for arg in "$@"; do
    [ "$arg" = "--skip-download" ] && SKIP_DOWNLOAD=1
done

# ── Sanity checks ─────────────────────────────────────────────────────────────

echo "[photon-setup] Checking prerequisites..."

if ! command -v java >/dev/null 2>&1; then
    echo ""
    echo "ERROR: Java not found. Install it first:"
    echo "  brew install openjdk@11"
    echo "  echo 'export PATH=\"/opt/homebrew/opt/openjdk@11/bin:\$PATH\"' >> ~/.zshrc"
    echo "  source ~/.zshrc"
    exit 1
fi

JAVA_VERSION=$(java -version 2>&1 | head -1)
echo "[photon-setup] Found: $JAVA_VERSION"

if ! command -v curl >/dev/null 2>&1; then
    echo "ERROR: curl not found. Install: brew install curl"
    exit 1
fi

# ── Directories ───────────────────────────────────────────────────────────────

mkdir -p "$OUTPUT_DIR" "$PBF_CACHE"

# ── Step 1: Download Photon JAR ───────────────────────────────────────────────

if [ -f "$JAR_OUTPUT" ]; then
    echo "[photon-setup] photon.jar already exists at $JAR_OUTPUT — skipping JAR download"
    echo "[photon-setup] Delete it and re-run to force re-download"
else
    echo "[photon-setup] Fetching latest Photon release info from GitHub..."
    RELEASE_JSON=$(curl -fsSL "$PHOTON_GITHUB_API")

    # Extract download URL for photon-*.jar (not javadoc/sources)
    JAR_URL=$(echo "$RELEASE_JSON" | \
        grep '"browser_download_url"' | \
        grep 'photon-[0-9]' | \
        grep -v 'javadoc\|sources' | \
        head -1 | \
        sed 's/.*"browser_download_url": *"\([^"]*\)".*/\1/')

    PHOTON_VERSION=$(echo "$RELEASE_JSON" | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')

    if [ -z "$JAR_URL" ]; then
        echo "ERROR: Could not find photon JAR URL from GitHub API response."
        echo "Check https://github.com/komoot/photon/releases manually."
        exit 1
    fi

    echo "[photon-setup] Downloading Photon $PHOTON_VERSION..."
    echo "[photon-setup] URL: $JAR_URL"
    curl -fL --progress-bar -o "$JAR_OUTPUT" "$JAR_URL"
    echo "[photon-setup] JAR saved to $JAR_OUTPUT ($(du -sh "$JAR_OUTPUT" | cut -f1))"
fi

# ── Step 2: Download NC PBF ───────────────────────────────────────────────────

if [ "$SKIP_DOWNLOAD" -eq 1 ] && [ -f "$PBF_FILE" ]; then
    echo "[photon-setup] --skip-download: reusing existing PBF at $PBF_FILE"
elif [ -f "$PBF_FILE" ]; then
    echo "[photon-setup] NC PBF already cached at $PBF_FILE — skipping"
    echo "[photon-setup] Delete it and re-run to fetch a fresh extract"
else
    echo "[photon-setup] Downloading NC OSM extract from Geofabrik (~300MB)..."
    echo "[photon-setup] URL: $GEOFABRIK_URL"
    curl -fL --progress-bar -o "$PBF_FILE" "$GEOFABRIK_URL"
    echo "[photon-setup] PBF saved ($(du -sh "$PBF_FILE" | cut -f1))"
fi

# ── Step 3: Run Photon indexer ────────────────────────────────────────────────

if [ -d "$DATA_OUTPUT" ]; then
    echo ""
    echo "[photon-setup] $DATA_OUTPUT already exists."
    echo "[photon-setup] Delete it and re-run to re-index."
    echo "[photon-setup] Skipping indexing step."
else
    echo ""
    echo "[photon-setup] Starting Photon indexer — this takes 10-20 minutes..."
    echo "[photon-setup] PBF: $PBF_FILE"
    echo "[photon-setup] Output: $DATA_OUTPUT"
    echo ""

    # Photon indexer: -nominatim-import reads a PBF and builds its Lucene index
    # Output goes into photon_data/ relative to the working directory,
    # so we run from OUTPUT_DIR so the index lands where we want it.
    cd "$OUTPUT_DIR"
    java -Xms512m -Xmx2g -jar "$JAR_OUTPUT" \
        -nominatim-import "$PBF_FILE" \
        -languages en

    # Photon creates photon_data/ in cwd — verify it landed correctly
    if [ ! -d "$DATA_OUTPUT" ]; then
        echo ""
        echo "ERROR: Indexing completed but $DATA_OUTPUT not found."
        echo "Check for photon_data/ in the current directory: $(pwd)"
        exit 1
    fi

    cd "$ROOT"
    echo ""
    echo "[photon-setup] Indexing complete!"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "================================================================"
echo "  Photon geocoder ready for packaging"
echo "================================================================"
echo ""
echo "  JAR:   $JAR_OUTPUT  ($(du -sh "$JAR_OUTPUT" 2>/dev/null | cut -f1 || echo 'missing'))"
echo "  Data:  $DATA_OUTPUT  ($(du -sh "$DATA_OUTPUT" 2>/dev/null | cut -f1 || echo 'missing'))"
echo ""
echo "  Run package-rootfs.sh to bundle into the rootfs image."
echo "  On device: /opt/photon/photon.jar + /opt/photon/photon_data/"
echo ""
echo "  NOTE: The photon_data/ Lucene index is architecture-independent —"
echo "  built on Mac, runs on i386 device without modification."
echo ""
