#!/bin/bash
# build-spike.sh — Build the Plan B''' spike binary.
#
# Output: /tmp/q60-planb/spike1 (i386 ELF, dynamic glibc 2.31)
#
# Why dynamic glibc: needs to dlopen the factory libEGL.so.1 (MeeGo glibc 2.11.90).
# Per project memory, modern Debian bullseye binaries (glibc 2.31) dlopen the
# factory libs cleanly. libdl/libm/librt for the spike itself.
#
# Why bullseye and not bookworm: bookworm dropped i386 from official mirrors.
set -e

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="/tmp/q60-planb"
mkdir -p "$OUT"

cp "$SRC_DIR/q60_planb_spike6_memcpy_paint.c"   "$OUT/"
cp "$SRC_DIR/q60_planb_spike7_memcpy_fixed.c"   "$OUT/"
cp "$SRC_DIR/q60_planb_spike8_correct_map.c"    "$OUT/"
cp "$SRC_DIR/q60_planb_spike9_pvr2d_deref.c"    "$OUT/"
cp "$SRC_DIR/q60_planb_spike10_kill_rebind.c"   "$OUT/"
# Earlier spikes 1-5 archived to docs/archive/spikes-2026-05-23/ — proved EGL works
# but GL paint into pixmap surface doesn't reach scanout (use memcpy + ConfigureBuffers).

echo "=== building i386 spikes (Debian bullseye i386, glibc 2.31) ==="
docker run --rm --platform linux/386 \
  -v "$OUT":/build \
  i386/debian:bullseye bash -c '
set -e
(apt-get update && apt-get install -y --no-install-recommends \
  gcc libc6-dev binutils libegl1-mesa-dev) >/dev/null
cd /build
for sf in q60_planb_spike6_memcpy_paint.c q60_planb_spike7_memcpy_fixed.c q60_planb_spike8_correct_map.c q60_planb_spike9_pvr2d_deref.c q60_planb_spike10_kill_rebind.c; do
  out=$(echo "$sf" | sed -E "s/q60_planb_(spike[0-9a-z]+)_.*/\1/")
  echo "--- building $out from $sf ---"
  gcc -O2 -Wall -Wextra -o "$out" "$sf" -ldl
  objcopy --remove-section=.note.ABI-tag "$out"
  ls -la "$out"
done
' 2>&1 | tail -12

echo ""
echo "=== Built ==="
ls -la "$OUT"/spike6 "$OUT"/spike7 "$OUT"/spike8 "$OUT"/spike9 "$OUT"/spike10
echo ""
echo "Deploy with: sudo bash $SRC_DIR/deploy-spike.sh <disk> (e.g. disk4s2)"
