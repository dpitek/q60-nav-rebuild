#!/bin/bash
# install-jre-rootfs.sh — Extract OpenJDK 11 headless i386 JRE into rootfs/
#
# Runs on Mac; dpkg-deb extraction happens inside the q60-toolchain Docker
# container (macOS does not have dpkg).
#
# What it does:
#   1. Downloads openjdk-11-jre-headless_*.deb (i386) from a Debian mirror
#   2. Extracts it into rootfs/ via dpkg-deb inside Docker
#   3. Installs libz1 and libstdc++6 (i386) as shared-lib dependencies
#   4. Creates /usr/bin/java → /usr/lib/jvm/java-11-openjdk-i386/bin/java symlink
#
# Idempotent: if rootfs/usr/lib/jvm/java-11-openjdk-i386/ already exists,
# skips the download/extract step and only re-creates the symlink.
#
# Estimated uncompressed size: ~120-140MB
#
# Usage:
#   ./scripts/install-jre-rootfs.sh
#
# Manual fallback (if mirror is unavailable):
#   1. Download i386 .deb manually from:
#        https://packages.debian.org/bullseye/i386/openjdk-11-jre-headless/download
#      or:
#        https://ftp.debian.org/debian/pool/main/o/openjdk-11/
#   2. Place the .deb in /tmp/jre-i386.deb on the build host
#   3. Run this script — it will use the pre-downloaded file if present at /tmp/jre-i386.deb

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
ROOTFS="$ROOT/rootfs"

# Debian Bullseye (11) — stable LTS, ships OpenJDK 11 headless for i386
# Check https://packages.debian.org/bullseye/i386/openjdk-11-jre-headless/download
# for the current version string if this URL becomes stale.
DEBIAN_MIRROR="https://ftp.debian.org/debian"
DEBIAN_SUITE="bullseye"
JRE_PKG="openjdk-11-jre-headless"
JRE_ARCH="i386"

# Dependency packages (runtime shared libs required by the JVM)
# zlib1g provides libz.so.1; libstdc++6 provides libstdc++.so.6
# NOTE: Debian Bullseye uses zlib1g (not libz1 which was removed after Buster)
DEP_PKGS="zlib1g libstdc++6"

JVM_DIR="$ROOTFS/usr/lib/jvm/java-11-openjdk-i386"
JAVA_LINK="$ROOTFS/usr/bin/java"

# ── Helpers ──────────────────────────────────────────────────────────────────

log() { echo "[install-jre] $*"; }

die() {
    echo ""
    echo "ERROR: $*" >&2
    echo ""
    echo "Manual download instructions:"
    echo "  1. Browse to:"
    echo "       https://ftp.debian.org/debian/pool/main/o/openjdk-11/"
    echo "     and download the file matching:"
    echo "       openjdk-11-jre-headless_11.*_i386.deb"
    echo "  2. Also download (i386 versions):"
    echo "       zlib1g      from https://ftp.debian.org/debian/pool/main/z/zlib/"
    echo "       libstdc++6  from https://ftp.debian.org/debian/pool/main/g/gcc-10/"
    echo "  3. Place them in /tmp/ as:"
    echo "       /tmp/jre-i386.deb"
    echo "       /tmp/libz1-i386.deb"
    echo "       /tmp/libstdc++6-i386.deb"
    echo "  4. Re-run this script — it will detect and use the pre-downloaded files."
    exit 1
}

check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        die "Docker not found. Install Docker Desktop for Mac and ensure it is running."
    fi
    if ! docker image inspect q60-toolchain >/dev/null 2>&1; then
        die "Docker image 'q60-toolchain' not found. Build it first (see Dockerfile or build-toolchain.sh)."
    fi
}

# ── Main ─────────────────────────────────────────────────────────────────────

log "Target rootfs: $ROOTFS"

check_docker

# ── Idempotency check ─────────────────────────────────────────────────────────
if [ -d "$JVM_DIR" ]; then
    log "JVM directory already exists at $JVM_DIR"
    log "Skipping download/extract — re-creating /usr/bin/java symlink only."

    docker run --rm \
        -v "$ROOT:/build" \
        q60-toolchain \
        bash -c "
            set -e
            ln -sf /usr/lib/jvm/java-11-openjdk-i386/bin/java /build/rootfs/usr/bin/java
            echo '[install-jre] Symlink updated: /usr/bin/java -> /usr/lib/jvm/java-11-openjdk-i386/bin/java'
        "
    log "Done."
    exit 0
fi

# ── Download + extract inside Docker ─────────────────────────────────────────
log "Downloading and extracting JRE via Docker (q60-toolchain)..."
log "This will use ~120-140MB of disk space in rootfs/."

docker run --rm \
    -v "$ROOT:/build" \
    q60-toolchain \
    bash -c "
        set -e

        JRE_DEB=/tmp/jre-i386.deb
        LIBZ_DEB=/tmp/libz1-i386.deb
        LIBSTDCPP_DEB=/tmp/libstdc++6-i386.deb
        ROOTFS=/build/rootfs

        # ── Resolve latest package version from Debian mirror ────────────────
        MIRROR='$DEBIAN_MIRROR'
        SUITE='$DEBIAN_SUITE'

        echo '[install-jre] Fetching package index...'
        PKG_INDEX=\$(curl -fsSL \"\${MIRROR}/dists/\${SUITE}/main/binary-i386/Packages.gz\" \
            | zcat 2>/dev/null) \
            || { echo 'ERROR: Could not fetch Debian package index.'; exit 1; }

        resolve_deb_url() {
            local pkg=\"\$1\"
            local url
            url=\$(echo \"\$PKG_INDEX\" \
                | awk -v p=\"\$pkg\" '
                    /^Package: / { cur=\$2 }
                    cur==p && /^Filename: / { print \$2; exit }
                ')
            if [ -z \"\$url\" ]; then
                echo \"ERROR: Could not find package '\$pkg' in Debian \${SUITE}/i386 index.\" >&2
                exit 1
            fi
            echo \"\${MIRROR}/\${url}\"
        }

        # ── Download JRE (use pre-downloaded file if available) ──────────────
        if [ -f \"\$JRE_DEB\" ]; then
            echo '[install-jre] Using pre-downloaded JRE .deb at '\$JRE_DEB
        else
            JRE_URL=\$(resolve_deb_url '$JRE_PKG')
            echo '[install-jre] Downloading: '\$JRE_URL
            curl -fsSL --progress-bar -o \"\$JRE_DEB\" \"\$JRE_URL\" \
                || { echo 'ERROR: Download failed. See manual instructions above.'; exit 1; }
        fi

        # ── Download zlib1g (provides libz.so.1) ─────────────────────────────
        # Debian Bullseye replaced libz1 with zlib1g
        if [ -f \"\$LIBZ_DEB\" ]; then
            echo '[install-jre] Using pre-downloaded zlib1g .deb'
        else
            LIBZ_URL=\$(resolve_deb_url 'zlib1g')
            echo '[install-jre] Downloading: '\$LIBZ_URL
            curl -fsSL --progress-bar -o \"\$LIBZ_DEB\" \"\$LIBZ_URL\" \
                || echo '[install-jre] WARNING: zlib1g download failed — check manually'
        fi

        # ── Download libstdc++6 ───────────────────────────────────────────────
        if [ -f \"\$LIBSTDCPP_DEB\" ]; then
            echo '[install-jre] Using pre-downloaded libstdc++6 .deb'
        else
            LIBSTDCPP_URL=\$(resolve_deb_url 'libstdc++6')
            echo '[install-jre] Downloading: '\$LIBSTDCPP_URL
            curl -fsSL --progress-bar -o \"\$LIBSTDCPP_DEB\" \"\$LIBSTDCPP_URL\" \
                || echo '[install-jre] WARNING: libstdc++6 download failed — check manually'
        fi

        # ── Extract packages into rootfs ──────────────────────────────────────
        echo '[install-jre] Extracting JRE into rootfs...'
        dpkg-deb --extract \"\$JRE_DEB\" \"\$ROOTFS\"

        if [ -f \"\$LIBZ_DEB\" ]; then
            echo '[install-jre] Extracting libz1 into rootfs...'
            dpkg-deb --extract \"\$LIBZ_DEB\" \"\$ROOTFS\"
        else
            echo '[install-jre] WARNING: zlib1g not available — JVM may fail to start'
            echo '             Expected at: rootfs/lib/i386-linux-gnu/libz.so.1'
        fi

        if [ -f \"\$LIBSTDCPP_DEB\" ]; then
            echo '[install-jre] Extracting libstdc++6 into rootfs...'
            dpkg-deb --extract \"\$LIBSTDCPP_DEB\" \"\$ROOTFS\"
        else
            echo '[install-jre] WARNING: libstdc++6 not available — JVM may fail to start'
            echo '             Expected at: rootfs/usr/lib/i386-linux-gnu/libstdc++.so.6'
        fi

        # ── Verify JVM landed where expected ─────────────────────────────────
        JVM_BIN=\"\$ROOTFS/usr/lib/jvm/java-11-openjdk-i386/bin/java\"
        if [ ! -f \"\$JVM_BIN\" ]; then
            echo \"ERROR: Expected JVM binary not found at \$JVM_BIN\"
            echo '       Check the extracted .deb structure:'
            find \"\$ROOTFS/usr/lib/jvm\" -name 'java' -type f 2>/dev/null | head -5
            exit 1
        fi
        echo '[install-jre] JVM binary confirmed at '\$JVM_BIN

        # ── Create /usr/bin/java symlink ──────────────────────────────────────
        mkdir -p \"\$ROOTFS/usr/bin\"
        ln -sf /usr/lib/jvm/java-11-openjdk-i386/bin/java \"\$ROOTFS/usr/bin/java\"
        echo '[install-jre] Symlink created: /usr/bin/java -> /usr/lib/jvm/java-11-openjdk-i386/bin/java'

        # ── Size report ───────────────────────────────────────────────────────
        echo ''
        echo '--- JRE footprint ---'
        du -sh \"\$ROOTFS/usr/lib/jvm\" 2>/dev/null || true
        du -sh \"\$ROOTFS/usr/bin/java\" 2>/dev/null || true
        echo '---------------------'
    " || die "Docker run failed — see messages above."

log ""
log "JRE installed successfully."
log ""
log "Verification:"
log "  JVM dir:    $JVM_DIR"
log "  Symlink:    $JAVA_LINK -> /usr/lib/jvm/java-11-openjdk-i386/bin/java"
log "  libz:       $ROOTFS/lib/i386-linux-gnu/libz.so.1  (from zlib1g)"
log "  libstdc++:  $ROOTFS/usr/lib/i386-linux-gnu/libstdc++.so.6"
log ""
log "Run scripts/package-rootfs.sh to include it in the rootfs image."
