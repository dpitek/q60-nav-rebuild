#!/bin/bash
# build-photon-db.sh — Build Photon geocoder database from NC OSM via Nominatim
#
# Requires:
#   - mediagis/nominatim:4.4 Docker image (already pulled)
#   - output/nc-osm-cache/north-carolina-latest.osm.pbf (already downloaded)
#   - output/photon-data/photon.jar (already downloaded)
#   - Java 21+ on Mac (openjdk@25 at /opt/homebrew/opt/openjdk@25)
#
# Steps:
#   1. Run Nominatim in Docker to import NC PBF into PostgreSQL (~30-45 min)
#   2. Dump Photon JSON from Nominatim DB
#   3. Import JSON into Photon OpenSearch database
#
# Output: output/photon-data/photon_data/  (~500MB)
#
# Usage: ./scripts/build-photon-db.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
PBF="$ROOT/output/nc-osm-cache/north-carolina-latest.osm.pbf"
PHOTON_JAR="$ROOT/output/photon-data/photon.jar"
PHOTON_DATA="$ROOT/output/photon-data"
JAVA=/opt/homebrew/opt/openjdk@25/bin/java
NOM_CONTAINER="q60nav-nominatim"
NOM_VOLUME="q60nav-nominatim-data"

echo "[build-photon-db] === Photon database build pipeline ==="

# ── Pre-flight ─────────────────────────────────────────────────────────────
[ -f "$PBF" ]         || { echo "ERROR: $PBF not found"; exit 1; }
[ -f "$PHOTON_JAR" ]  || { echo "ERROR: $PHOTON_JAR not found"; exit 1; }
[ -x "$JAVA" ]        || { echo "ERROR: Java not found at $JAVA"; exit 1; }

# ── Idempotency ────────────────────────────────────────────────────────────
if [ -d "$PHOTON_DATA/photon_data" ]; then
    echo "[build-photon-db] photon_data/ already exists — skipping"
    echo "  To rebuild: rm -rf $PHOTON_DATA/photon_data"
    exit 0
fi

# ── Step 1: Start Nominatim and import NC PBF ──────────────────────────────
echo ""
echo "[build-photon-db] Step 1: Nominatim import (~30-45 min)..."
echo "  PBF: $PBF ($(ls -lh "$PBF" | awk '{print $5}'))"

# Clean up any previous run
docker rm -f "$NOM_CONTAINER" 2>/dev/null || true
docker volume rm "$NOM_VOLUME" 2>/dev/null || true

docker run -d \
    --name "$NOM_CONTAINER" \
    -e PBF_PATH=/nominatim/data/region.osm.pbf \
    -e REPLICATION_URL="" \
    -e NOMINATIM_PASSWORD=photon \
    -p 18080:8080 \
    -v "$PBF:/nominatim/data/region.osm.pbf:ro" \
    -v "$NOM_VOLUME:/var/lib/postgresql/14/main" \
    mediagis/nominatim:4.4

echo "[build-photon-db] Nominatim container started (ID: $(docker ps -q -f name=$NOM_CONTAINER))"
echo "  Waiting for import to complete (poll every 30s)..."

# Wait for Nominatim to be ready (import done = HTTP 200 on /status)
ELAPSED=0
MAX_WAIT=3600  # 60 min timeout
while [ $ELAPSED -lt $MAX_WAIT ]; do
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:18080/status" 2>/dev/null || echo "000")
    if [ "$STATUS" = "200" ]; then
        echo "[build-photon-db] Nominatim ready after ${ELAPSED}s"
        break
    fi
    sleep 30
    ELAPSED=$((ELAPSED + 30))
    echo "  ...${ELAPSED}s elapsed, status=$STATUS"
done

if [ "$STATUS" != "200" ]; then
    echo "ERROR: Nominatim did not become ready within ${MAX_WAIT}s"
    docker logs "$NOM_CONTAINER" | tail -20
    exit 1
fi

# ── Step 2: Dump Photon JSON from Nominatim ────────────────────────────────
echo ""
echo "[build-photon-db] Step 2: Dumping Photon JSON from Nominatim..."
DUMP_FILE="$PHOTON_DATA/nc-photon-dump.jsonl"

cd "$PHOTON_DATA"
$JAVA -jar photon.jar dump-nominatim-db \
    -host 127.0.0.1 \
    -port 15432 \
    -user nominatim \
    -password photon \
    -database nominatim \
    -output-file "$DUMP_FILE" 2>&1 | tee "$PHOTON_DATA/dump.log" || {

    # Try the container's internal PostgreSQL port via docker exec
    echo "  Direct connect failed — trying via docker exec..."
    docker exec "$NOM_CONTAINER" \
        java -jar /photon/photon.jar dump-nominatim-db \
            -host 127.0.0.1 -port 5432 \
            -user nominatim -password nominatim \
            -database nominatim \
            -output-file /tmp/nc-photon-dump.jsonl
    docker cp "$NOM_CONTAINER:/tmp/nc-photon-dump.jsonl" "$DUMP_FILE"
}

echo "[build-photon-db] Dump complete: $(ls -lh "$DUMP_FILE" | awk '{print $5}')"

# ── Step 3: Import into Photon OpenSearch DB ───────────────────────────────
echo ""
echo "[build-photon-db] Step 3: Importing into Photon database..."

cd "$PHOTON_DATA"
$JAVA -jar photon.jar import \
    -import-file "$DUMP_FILE" \
    -data-dir "$PHOTON_DATA" \
    -j 2 2>&1 | tee "$PHOTON_DATA/import.log"

echo ""
echo "[build-photon-db] === DONE ==="
echo "  Data: $PHOTON_DATA/photon_data/"
du -sh "$PHOTON_DATA/photon_data/" 2>/dev/null

# ── Cleanup ────────────────────────────────────────────────────────────────
echo ""
echo "[build-photon-db] Stopping Nominatim container..."
docker rm -f "$NOM_CONTAINER" 2>/dev/null || true
docker volume rm "$NOM_VOLUME" 2>/dev/null || true
echo "[build-photon-db] Cleanup done. Run ./scripts/package-rootfs.sh to rebuild image."
