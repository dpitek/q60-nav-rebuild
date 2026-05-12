#!/bin/bash
# build-geocoder-db.sh — Build SQLite geocoder database from NC Photon JSONL dump
#
# Runs on the Mac host (no Docker needed — uses system python3 + sqlite3).
# Input:  output/photon-data/nc-photon-dump.jsonl  (972MB, ~1.52M records)
# Output: output/geocoder/places.db
#
# Schema:
#   places         — core record table (id, name, city, state, country, lat, lon)
#   places_fts     — FTS5 full-text index (name, city, state)
#   places_rtree   — R-tree spatial index (for /reverse endpoint)
#
# Usage:
#   ./scripts/build-geocoder-db.sh
#
# Idempotent: skips if output/geocoder/places.db already exists.
# To force a rebuild: rm output/geocoder/places.db && ./scripts/build-geocoder-db.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
JSONL="$ROOT/output/photon-data/nc-photon-dump.jsonl"
DB_DIR="$ROOT/output/geocoder"
DB="$DB_DIR/places.db"

# ── Preflight ──────────────────────────────────────────────────────────────

echo "[build-geocoder-db] Checking prerequisites..."

if [ ! -f "$JSONL" ]; then
    echo "ERROR: JSONL dump not found at $JSONL"
    echo "       Expected: output/photon-data/nc-photon-dump.jsonl"
    exit 1
fi

if [ -f "$DB" ]; then
    SIZE=$(du -sh "$DB" | awk '{print $1}')
    echo "[build-geocoder-db] Database already exists ($SIZE) — skipping."
    echo "  Delete output/geocoder/places.db to force a rebuild."
    exit 0
fi

python3 --version >/dev/null 2>&1 || { echo "ERROR: python3 not found"; exit 1; }

mkdir -p "$DB_DIR"

echo "[build-geocoder-db] Building SQLite geocoder DB from JSONL..."
echo "  Input:  $JSONL"
echo "  Output: $DB"
echo "  (this will take ~5-10 minutes for 1.52M records)"
echo ""

# ── Python import ─────────────────────────────────────────────────────────

python3 - "$JSONL" "$DB" << 'PYEOF'
import sys, json, sqlite3, time, os

jsonl_path = sys.argv[1]
db_path    = sys.argv[2]

# Remove partial DB if it exists (shouldn't, but be safe)
if os.path.exists(db_path):
    os.remove(db_path)

con = sqlite3.connect(db_path)
con.execute("PRAGMA journal_mode=WAL")
con.execute("PRAGMA synchronous=NORMAL")
con.execute("PRAGMA cache_size=-65536")   # 64MB cache during build
con.execute("PRAGMA temp_store=MEMORY")

# ── Schema ────────────────────────────────────────────────────────────────

con.executescript("""
CREATE TABLE places (
    id       INTEGER PRIMARY KEY,
    name     TEXT    NOT NULL,
    city     TEXT    DEFAULT '',
    state    TEXT    DEFAULT '',
    country  TEXT    DEFAULT 'us',
    osm_type TEXT    DEFAULT '',
    lat      REAL    NOT NULL,
    lon      REAL    NOT NULL
);

CREATE VIRTUAL TABLE places_fts USING fts5(
    name, city, state,
    content=places, content_rowid=id,
    tokenize="unicode61 remove_diacritics 1 separators ' -.,()'"
);

CREATE VIRTUAL TABLE places_rtree USING rtree(
    id, minlat, maxlat, minlon, maxlon
);
""")
con.commit()

# ── Import loop ───────────────────────────────────────────────────────────
#
# File format: Nominatim JSONL dump (NOT GeoJSON Feature lines)
# Each line is one of:
#   {"type":"NominatimDumpFile","content":{...}}  — header, skip
#   {"type":"CountryInfo","content":[...]}        — country table, skip
#   {"type":"Place","content":[{item1},{item2}...]} — one or more place items
#
# Place item fields of interest:
#   item.name.name          — display name
#   item.address.city       — city (may also be town/village/suburb as fallback)
#   item.address.state      — state name or abbreviation
#   item.country_code       — "us"
#   item.centroid           — [lon, lat]
#   item.osm_key/osm_value  — category (e.g. amenity/restaurant)

def extract_city(addr):
    """Return best city string from address dict."""
    if not addr:
        return ''
    for key in ('city', 'town', 'village', 'suburb', 'hamlet', 'municipality'):
        v = addr.get(key)
        if v and isinstance(v, str):
            return v.strip()
    return ''

BATCH      = 50000
places_buf = []
fts_buf    = []
rtree_buf  = []
total      = 0
skipped    = 0
t0         = time.time()

def flush(con, places_buf, fts_buf, rtree_buf):
    con.executemany(
        "INSERT INTO places (name, city, state, country, osm_type, lat, lon) "
        "VALUES (?,?,?,?,?,?,?)",
        places_buf
    )
    con.executemany(
        "INSERT INTO places_fts(rowid, name, city, state) VALUES (?,?,?,?)",
        fts_buf
    )
    con.executemany(
        "INSERT INTO places_rtree(id, minlat, maxlat, minlon, maxlon) "
        "VALUES (?,?,?,?,?)",
        rtree_buf
    )
    con.commit()

row_id = 0

with open(jsonl_path, 'r', encoding='utf-8') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            skipped += 1
            continue

        obj_type = obj.get('type', '')

        # Skip header / country info lines
        if obj_type in ('NominatimDumpFile', 'CountryInfo'):
            continue

        if obj_type != 'Place':
            skipped += 1
            continue

        items = obj.get('content', [])
        if not isinstance(items, list):
            skipped += 1
            continue

        for item in items:
            if not isinstance(item, dict):
                skipped += 1
                continue

            # Extract name
            name_obj = item.get('name', {})
            if not isinstance(name_obj, dict):
                skipped += 1
                continue
            name = (name_obj.get('name') or '').strip()
            if len(name) < 2:
                skipped += 1
                continue

            # Extract coordinates from centroid [lon, lat]
            centroid = item.get('centroid')
            if not centroid or not isinstance(centroid, list) or len(centroid) < 2:
                skipped += 1
                continue
            try:
                lon = float(centroid[0])
                lat = float(centroid[1])
            except (TypeError, ValueError):
                skipped += 1
                continue

            # Validate coordinates
            if not (-90.0 <= lat <= 90.0) or not (-180.0 <= lon <= 180.0):
                skipped += 1
                continue

            # Extract address fields
            addr    = item.get('address', {}) if isinstance(item.get('address'), dict) else {}
            city    = extract_city(addr)
            state_v = addr.get('state', '')
            if isinstance(state_v, list):
                state_v = state_v[0] if state_v else ''
            state   = str(state_v).strip()

            country  = (item.get('country_code') or 'us').strip()
            osm_type = (item.get('osm_value') or item.get('osm_key') or '').strip()

            row_id += 1
            places_buf.append((name, city, state, country, osm_type, lat, lon))
            fts_buf.append((row_id, name, city, state))
            rtree_buf.append((row_id, lat, lat, lon, lon))
            total += 1

            if total % BATCH == 0:
                flush(con, places_buf, fts_buf, rtree_buf)
                places_buf.clear()
                fts_buf.clear()
                rtree_buf.clear()

            if total % 100000 == 0:
                elapsed = time.time() - t0
                rate    = total / elapsed if elapsed > 0 else 0
                print(f"  {total:>9,} records imported  ({rate:,.0f}/s, {elapsed:.0f}s elapsed)")
                sys.stdout.flush()

# Flush remainder
if places_buf:
    flush(con, places_buf, fts_buf, rtree_buf)

# ── Finalize ──────────────────────────────────────────────────────────────

print(f"\n  Import complete: {total:,} records, {skipped:,} skipped")
print("  Running VACUUM (compacts DB — may take 1-2 min)...")
sys.stdout.flush()

con.execute("PRAGMA journal_mode=DELETE")
con.execute("VACUUM")
con.close()

db_size = os.path.getsize(db_path)
elapsed = time.time() - t0
print(f"  VACUUM done.")
print(f"  DB size:  {db_size / 1024 / 1024:.1f} MB")
print(f"  Records:  {total:,}")
print(f"  Elapsed:  {elapsed:.0f}s")
PYEOF

echo ""
echo "[build-geocoder-db] Done."
ls -lh "$DB"
echo ""
echo "Next step: ./scripts/build-geocoder-server.sh"
