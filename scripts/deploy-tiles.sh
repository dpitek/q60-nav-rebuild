#!/usr/bin/env bash
# deploy-tiles.sh — Deploy Valhalla routing tiles + config to Q60 eMMC image
# Target partition: mmcblk0p8 (3GB nav app partition, mounted at /opt/nav)
#
# Usage:
#   ./deploy-tiles.sh                    # interactive — prompts for mount point
#   ./deploy-tiles.sh /mnt/q60-p8        # explicit mount point
#   ./deploy-tiles.sh --dry-run /mnt/...  # print actions without executing
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="$PROJECT_ROOT/output"

VALHALLA_TILES_SRC="$OUTPUT_DIR/valhalla-tiles"
VALHALLA_CONFIG_SRC="$OUTPUT_DIR/valhalla-config.json"
VECTOR_TILES_SRC="$OUTPUT_DIR/vector-tiles"

TARGET_NAV_DIR="/opt/nav"
VALHALLA_TILES_DEST="$TARGET_NAV_DIR/valhalla_tiles"
VALHALLA_CONFIG_DEST="$TARGET_NAV_DIR/valhalla-config.json"
VECTOR_TILES_DEST="$TARGET_NAV_DIR/vector_tiles"

DRY_RUN=false
MOUNT_POINT=""

# --- Arg parsing ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    -*) echo "Unknown option: $1"; exit 1 ;;
    *) MOUNT_POINT="$1"; shift ;;
  esac
done

if [[ -z "$MOUNT_POINT" ]]; then
  echo "Enter the mount point for mmcblk0p8 (e.g. /mnt/q60-p8):"
  read -r MOUNT_POINT
fi

# Resolve paths relative to mount point for scp/rsync to device image
# If MOUNT_POINT is "/" we're writing to the live device (dangerous — confirm)
if [[ "$MOUNT_POINT" == "/" ]]; then
  echo "WARNING: mount point is /. This will overwrite the live system."
  echo "Type 'yes-live' to continue:"
  read -r confirm
  [[ "$confirm" == "yes-live" ]] || { echo "Aborted."; exit 1; }
fi

run() {
  if $DRY_RUN; then
    echo "[DRY-RUN] $*"
  else
    "$@"
  fi
}

echo ""
echo "=== Q60 Nav Tile Deployment ==="
echo "  Source:      $OUTPUT_DIR"
echo "  Mount point: $MOUNT_POINT"
echo "  Dry run:     $DRY_RUN"
echo ""

# --- Preflight checks ---
echo "--- Preflight ---"

if [[ ! -d "$VALHALLA_TILES_SRC" ]]; then
  echo "ERROR: Valhalla tiles not found at $VALHALLA_TILES_SRC"
  echo "       Run: valhalla_build_tiles -c $VALHALLA_CONFIG_SRC /tmp/north-carolina-latest.osm.pbf"
  exit 1
fi

TILE_COUNT=$(find "$VALHALLA_TILES_SRC" -name "*.gph" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$TILE_COUNT" -eq 0 ]]; then
  echo "ERROR: No .gph tiles found in $VALHALLA_TILES_SRC — build may have failed"
  exit 1
fi
echo "  Valhalla tiles: $TILE_COUNT .gph files"

TILES_SIZE=$(du -sh "$VALHALLA_TILES_SRC" 2>/dev/null | cut -f1)
echo "  Valhalla tile size: $TILES_SIZE"

if [[ -d "$VECTOR_TILES_SRC" ]]; then
  VT_SIZE=$(du -sh "$VECTOR_TILES_SRC" 2>/dev/null | cut -f1)
  echo "  Vector tile size: $VT_SIZE"
fi

# Check available space on mount point
AVAIL_KB=$(df -k "$MOUNT_POINT" 2>/dev/null | tail -1 | awk '{print $4}')
AVAIL_MB=$((AVAIL_KB / 1024))
echo "  Partition available: ${AVAIL_MB}MB"
if [[ "$AVAIL_MB" -lt 500 ]]; then
  echo "WARNING: Less than 500MB free on $MOUNT_POINT — tiles may not fit"
fi

echo ""
echo "--- Deploying Valhalla tiles ---"
DEST_TILES="$MOUNT_POINT$VALHALLA_TILES_DEST"
run mkdir -p "$DEST_TILES"
run rsync -av --delete "$VALHALLA_TILES_SRC/" "$DEST_TILES/"
echo "  -> $DEST_TILES"

echo ""
echo "--- Deploying Valhalla config ---"
DEST_CONFIG="$MOUNT_POINT$VALHALLA_CONFIG_DEST"
run cp "$VALHALLA_CONFIG_SRC" "$DEST_CONFIG"
# Patch tile_dir path in config to match device path (already /opt/nav/valhalla_tiles)
echo "  -> $DEST_CONFIG"

echo ""
echo "--- Deploying vector tiles ---"
if [[ -d "$VECTOR_TILES_SRC" ]] && [[ -n "$(ls -A "$VECTOR_TILES_SRC" 2>/dev/null)" ]]; then
  DEST_VT="$MOUNT_POINT$VECTOR_TILES_DEST"
  run mkdir -p "$DEST_VT"
  run rsync -av --delete "$VECTOR_TILES_SRC/" "$DEST_VT/"
  echo "  -> $DEST_VT"
else
  echo "  SKIP: no vector tiles built yet (run tilemaker separately)"
fi

echo ""
echo "--- Symlink: /opt/nav/valhalla_tiles -> $VALHALLA_TILES_DEST ---"
SYMLINK_PATH="$MOUNT_POINT/opt/nav/valhalla_tiles"
if [[ -L "$SYMLINK_PATH" ]]; then
  echo "  Symlink already exists — skipping"
elif [[ -d "$SYMLINK_PATH" ]]; then
  echo "  Real dir exists at $SYMLINK_PATH — no symlink needed"
else
  run ln -s "$VALHALLA_TILES_DEST" "$SYMLINK_PATH"
  echo "  -> symlink created"
fi

echo ""
echo "--- Final partition usage ---"
if ! $DRY_RUN; then
  df -h "$MOUNT_POINT" 2>/dev/null || true
  echo ""
  echo "  Nav dir breakdown:"
  du -sh "$MOUNT_POINT$TARGET_NAV_DIR"/* 2>/dev/null || true
fi

echo ""
echo "=== Deployment complete ==="
echo ""
echo "On-device startup command:"
echo "  valhalla_service $TARGET_NAV_DIR/valhalla-config.json 1"
echo ""
echo "Verify routing (from device):"
echo "  curl -s http://localhost:8002/status | python3 -m json.tool"
