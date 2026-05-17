#!/bin/bash
# Build the R1 Sprite C overlay client — both static-musl (for DCU deployment)
# and dynamic-glibc (for emulator + LD_PRELOAD-shim testing).
set -e

DIR=$(dirname "$0")
OUT=/tmp/q60-overnight/r1-build
mkdir -p "$OUT"
cp "$DIR/q60nav_sprite_c.c" "$OUT/"
cp "$DIR/q60nav_r1_probe.c" "$OUT/"

echo "=== static-musl builds (DCU deployment binaries) ==="
docker run --rm --platform linux/386 \
  -v "$OUT":/build \
  alpine:latest sh -c '
apk add --no-cache gcc musl-dev binutils >/dev/null 2>&1
cd /build
gcc -static -no-pie -O2 -Wall -o q60nav_sprite_c.static q60nav_sprite_c.c
objcopy --remove-section=.note.ABI-tag --strip-all q60nav_sprite_c.static
gcc -static -no-pie -O2 -Wall -o q60nav_r1_probe.static q60nav_r1_probe.c
objcopy --remove-section=.note.ABI-tag --strip-all q60nav_r1_probe.static
ls -la q60nav_sprite_c.static q60nav_r1_probe.static
' 2>&1 | tail -4

echo ""
echo "=== dynamic-glibc (emulator test binary, ~16 KB) ==="
docker run --rm --platform linux/386 \
  -v "$OUT":/build \
  i386/debian:bullseye bash -c '
(apt-get update && apt-get install -y --no-install-recommends gcc libc6-dev binutils) >/dev/null 2>&1
cd /build
gcc -O2 -Wall -o q60nav_sprite_c.dyn q60nav_sprite_c.c
objcopy --remove-section=.note.ABI-tag q60nav_sprite_c.dyn
ls -la q60nav_sprite_c.dyn
' 2>&1 | tail -3

echo ""
echo "=== Built ==="
ls -la "$OUT/q60nav_sprite_c"*
echo "Deploy with: bash $(dirname "$0")/deploy-r1.sh /dev/disk12s2"
