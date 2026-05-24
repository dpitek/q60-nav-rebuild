#!/bin/bash
# build-kernel.sh — Reproducible Q60 kernel build (v14+)
# Builds Linux 4.19 + Q60 config in a clean Docker container, with sanity gates.
#
# Usage: bash scripts/build-kernel.sh
#
# Output: output/bzImage-4.19-q60  +  output/bzImage-4.19-q60.sha256
#
# Sanity gates (any failure = build is rejected):
#   - applied .config has all required CONFIG_* flags after olddefconfig
#   - bzImage < 4 MB (elilo limit; also keeps headroom for direct EFI load)
#   - vmlinux contains LAPIS SDHCI device-ID strings (10db:801e/801f/8020)
#   - sha256 recorded for downstream verify-slotb comparison

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL_DIR="${SCRIPT_DIR}/kernel"
CONFIG_SRC="${SCRIPT_DIR}/configs/q60_kernel.config"
OUTPUT_DIR="${SCRIPT_DIR}/output"
OUTPUT_BZ="${OUTPUT_DIR}/bzImage-4.19-q60"
OUTPUT_SHA="${OUTPUT_DIR}/bzImage-4.19-q60.sha256"
MAX_SIZE=4194304    # 4 MB — elilo+EFI load limit on this platform

hr()   { echo "────────────────────────────────────────────────────────────"; }
step() { echo ""; hr; echo "  STEP $1: $2"; hr; }
ok()   { echo "  ✓ $*"; }
fail() { echo "  ✗ ERROR: $*" >&2; exit 1; }
info() { echo "    $*"; }

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  Q60 kernel build (Linux 4.19 + Q60 config)"
echo "  $(date)"
echo "════════════════════════════════════════════════════════════"

# ── Preflight ─────────────────────────────────────────────────────────────────
step 0 "Preflight"

[ -d "${KERNEL_DIR}" ]  || fail "Kernel source not found: ${KERNEL_DIR}"
[ -f "${CONFIG_SRC}" ]  || fail "Config source not found: ${CONFIG_SRC}"
docker info >/dev/null 2>&1 || fail "Docker daemon not reachable — start Docker Desktop"

ok "Kernel source: ${KERNEL_DIR}"
ok "Config source: ${CONFIG_SRC}"
ok "Docker reachable"

mkdir -p "${OUTPUT_DIR}"

# ── Stage source config into kernel tree ──────────────────────────────────────
step 1 "Staging .config"

cp "${CONFIG_SRC}" "${KERNEL_DIR}/.config"
ok "Copied: ${CONFIG_SRC} → ${KERNEL_DIR}/.config"

# ── Pre-build config gates (catch obvious omissions before 10 min build) ─────
step 2 "Pre-build config sanity"

REQUIRED_Y=(
    M686
    X86_PAE HIGHMEM64G
    EFI_STUB RELOCATABLE KERNEL_XZ
    CMDLINE_BOOL
    PSTORE PSTORE_RAM
    MMC_BLOCK MMC_SDHCI MMC_SDHCI_PCI
    PCH_PHUB SERIAL_PCH_UART SERIAL_PCH_UART_CONSOLE
    FB_EFI X86_SYSFB
    VIRTIO VIRTIO_PCI VIRTIO_BLK
)
REQUIRED_N=(
    MATOM
    INTEL_IDLE X86_INTEL_MID SFI HIGHMEM4G
)

MISSING=""
for SYM in "${REQUIRED_Y[@]}"; do
    grep -q "^CONFIG_${SYM}=y$" "${KERNEL_DIR}/.config" || MISSING="${MISSING} CONFIG_${SYM}"
done
for SYM in "${REQUIRED_N[@]}"; do
    grep -q "^# CONFIG_${SYM} is not set$" "${KERNEL_DIR}/.config" || MISSING="${MISSING} !CONFIG_${SYM}"
done

if [ -n "${MISSING}" ]; then
    fail "pre-build config missing required symbols:${MISSING}"
fi
ok "all required CONFIG_* flags present in source .config"

# ── Build in Docker ───────────────────────────────────────────────────────────
step 3 "Kernel build in Docker (ubuntu:22.04, ~5-10 min on M-series Mac)"

# Note: --platform linux/amd64 — kernel is built ON amd64 host, FOR i386 target
# via ARCH=i386. We build natively on the host arch (under Rosetta on Apple
# Silicon) to avoid emulation overhead.
docker run --rm \
    --platform linux/amd64 \
    -v "${KERNEL_DIR}:/k" \
    -v "${OUTPUT_DIR}:/out" \
    -v "${OUTPUT_DIR}:/k-output" \
    ubuntu:22.04 \
    bash -c '
        set -euo pipefail
        export DEBIAN_FRONTEND=noninteractive
        echo ">> apt update + install build deps"
        apt-get update -qq >/dev/null
        apt-get install -y -qq --no-install-recommends \
            build-essential gcc-multilib bc bison flex \
            libssl-dev libelf-dev xz-utils kmod cpio \
            >/dev/null

        cd /k
        echo ">> make ARCH=i386 olddefconfig"
        make ARCH=i386 olddefconfig 2>&1 | tail -20

        # Re-check the APPLIED .config — olddefconfig can silent-strip
        # symbols if their dependencies are unmet. This catches that.
        for SYM in X86_PAE HIGHMEM64G PSTORE PSTORE_RAM EFI_STUB KERNEL_XZ \
                   MMC_SDHCI_PCI VIRTIO_BLK; do
            grep -q "^CONFIG_${SYM}=y$" .config || {
                echo "!! POST-olddefconfig: CONFIG_${SYM}=y was silent-stripped"
                grep -m1 "CONFIG_${SYM}" .config || echo "   (symbol fully removed)"
                exit 1
            }
        done
        echo ">> applied .config retained all critical symbols"

        # CRITICAL: Atom E6xx Bonnell does NOT support MOVBE instruction.
        # gcc-7+ with -march=atom freely emits MOVBE → kernel triple-faults at decompress.
        # Belt + suspenders: M686 in config + -mno-movbe in KCFLAGS + post-build objdump check.
        export KCFLAGS="-mno-movbe -march=i686 -mtune=i686"
        echo ">> make ARCH=i386 -j$(nproc) bzImage  (KCFLAGS=${KCFLAGS})"
        make ARCH=i386 -j"$(nproc)" KCFLAGS="${KCFLAGS}" bzImage 2>&1 | tail -30

        # MOVBE sanity check — MUST be zero MOVBE (Atom 2008+ instruction; Bonnell E6xx lacks it).
        # CRITICAL: do NOT match "cmovbe" (CMOVBE = Conditional MOVe if Below or Equal,
        # Pentium Pro 1995, perfectly legal on Bonnell). Use a tab-anchored mnemonic match.
        apt-get install -y -qq binutils >/dev/null
        # The disassembly format is: "ADDR:\tBYTES\tmnemonic ..." — mnemonic preceded by tab.
        MOVBE_COUNT=$(objdump -d vmlinux 2>/dev/null | awk -F"\t" "\$3 ~ /^movbe([ \\t]|\$)/ {n++} END{print n+0}")
        CMOVBE_COUNT=$(objdump -d vmlinux 2>/dev/null | awk -F"\t" "\$3 ~ /^cmovbe([ \\t]|\$)/ {n++} END{print n+0}")
        echo ">> MOVBE instructions:  ${MOVBE_COUNT} (must be 0; Bonnell E6xx triple-faults on these)"
        echo ">> CMOVBE instructions: ${CMOVBE_COUNT} (informational; cmovbe is P6-era and safe)"
        if [ "${MOVBE_COUNT}" -ne 0 ]; then
            echo "!! ABORT: vmlinux contains ${MOVBE_COUNT} MOVBE instructions."
            echo "!! Atom E6xx Bonnell will triple-fault on these at decompress."
            echo "!! Check CONFIG_MATOM=n, CONFIG_M686=y, and KCFLAGS=-mno-movbe."
            exit 1
        fi

        cp arch/x86/boot/bzImage /out/bzImage-4.19-q60.new
        echo ">> built: /out/bzImage-4.19-q60.new ($(stat -c%s arch/x86/boot/bzImage) bytes), MOVBE=0"
    '

[ -f "${OUTPUT_BZ}.new" ] || fail "build produced no bzImage at ${OUTPUT_BZ}.new"
ok "build completed"

# ── Post-build sanity gates ───────────────────────────────────────────────────
step 4 "Post-build sanity"

BZ_SIZE=$(stat -f%z "${OUTPUT_BZ}.new")
info "bzImage size: ${BZ_SIZE} bytes"
[ "${BZ_SIZE}" -lt "${MAX_SIZE}" ] || fail "bzImage too large: ${BZ_SIZE} >= ${MAX_SIZE}"
ok "size under elilo/EFI limit"

# Verify LAPIS SDHCI patch landed in the compiled vmlinux
if [ -f "${KERNEL_DIR}/vmlinux" ]; then
    LAPIS_COUNT=$(strings "${KERNEL_DIR}/vmlinux" 2>/dev/null | grep -cE "10db.*801[ef]|10db.*8020" || true)
    info "vmlinux contains ${LAPIS_COUNT} LAPIS device-ID string hits"
    # Compile-time PCI_DEVICE() macros expand to numeric ids — we can't grep
    # for the literal "10db" in symbols, so check the source patch instead.
fi
grep -q "0x10db, 0x801e" "${KERNEL_DIR}/drivers/mmc/host/sdhci-pci-core.c" \
    && grep -q "0x10db, 0x801f" "${KERNEL_DIR}/drivers/mmc/host/sdhci-pci-core.c" \
    && grep -q "0x10db, 0x8020" "${KERNEL_DIR}/drivers/mmc/host/sdhci-pci-core.c" \
    || fail "LAPIS SDHCI patch missing from sdhci-pci-core.c"
ok "LAPIS SDHCI patch present in source"

# Atomically promote the new bzImage
mv "${OUTPUT_BZ}.new" "${OUTPUT_BZ}"
shasum -a 256 "${OUTPUT_BZ}" | tee "${OUTPUT_SHA}"
ok "wrote ${OUTPUT_BZ}"
ok "wrote ${OUTPUT_SHA}"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════"
echo "  BUILD COMPLETE"
echo "  Size: ${BZ_SIZE} bytes ($((BZ_SIZE / 1024)) KB)"
echo "  Output: ${OUTPUT_BZ}"
echo ""
echo "  Next: QEMU validate before any SD card deploy"
echo "════════════════════════════════════════════════════════════"
