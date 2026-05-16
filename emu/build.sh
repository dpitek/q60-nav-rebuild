#!/bin/bash
# Build the q60-dsu Docker emulator image.
# Uses tarballs + ADD (bypasses macOS xattr probing that breaks COPY of directories).
set -e
cd /tmp/q60-overnight/emu

if [ ! -f slot-a.tar ] || [ slot-a -nt slot-a.tar ]; then
    echo "=== Making slot-a.tar ==="
    tar --no-xattrs --no-mac-metadata -cf slot-a.tar -C slot-a . 2>&1 | tail -3 || true
    ls -lh slot-a.tar
fi

if [ ! -f naviwork.tar ] || [ naviwork -nt naviwork.tar ]; then
    echo "=== Making naviwork.tar ==="
    tar --no-xattrs --no-mac-metadata -cf naviwork.tar -C naviwork . 2>&1 | tail -3 || true
    ls -lh naviwork.tar
fi

echo ""
echo "=== Building q60-dsu image (linux/386 on $(uname -m)) ==="
docker build --platform linux/386 -t q60-dsu:latest -f Dockerfile.q60 . 2>&1 | tail -20

echo ""
echo "=== Image info ==="
docker images q60-dsu:latest --format "{{.Repository}}:{{.Tag}} {{.Size}}"
