#!/usr/bin/env bash
# test-spike-local.sh
#
# End-to-end local test of the emgdhmid stub + libemgdhmi shim.
# Runs everything inside a single throwaway i386 Alpine container so the
# binaries we built via Docker can execute (the host is likely arm64
# macOS, which can't run linux/386 ELFs natively).
#
# Output: stdout + stderr captured to ./build/spike-local.log
# Exit:   0 on driver PASS, 1 otherwise

set -euo pipefail

cd "$(dirname "$0")"

BUILD_DIR="${BUILD_DIR:-build}"
LOG="${BUILD_DIR}/spike-local.log"

if [ ! -x "${BUILD_DIR}/emgdhmid_stub" ] || \
   [ ! -f "${BUILD_DIR}/libemgdhmi.so.0" ] || \
   [ ! -x "${BUILD_DIR}/spike_driver" ]; then
    echo "missing artefacts under ${BUILD_DIR}/ — run 'make' first" >&2
    exit 2
fi

mkdir -p "${BUILD_DIR}"
: > "${LOG}"

echo "[test] launching daemon + driver inside linux/386 alpine..." | tee -a "${LOG}"

# Single container, single script — daemon in background, then driver,
# then capture exit code and tear down cleanly.
docker run --rm --platform linux/386 \
    -v "$(pwd):/work" -w /work alpine:3.18 \
    sh -c '
        set -eu
        rm -f /tmp/.emgdhmid_socket
        # Daemon to background, redirecting stderr (its log channel) to file.
        ./'"${BUILD_DIR}"'/emgdhmid_stub > /work/'"${BUILD_DIR}"'/stub.log 2>&1 &
        STUB_PID=$!
        trap "kill $STUB_PID 2>/dev/null || true" EXIT INT TERM

        # Wait up to 3s for the socket to appear.
        i=0
        while [ ! -S /tmp/.emgdhmid_socket ]; do
            i=$((i+1))
            [ $i -ge 30 ] && { echo "stub failed to create socket"; exit 3; }
            sleep 0.1
        done
        echo "[test] socket up after ${i} attempts"

        # Run the driver. It already links against build/libemgdhmi.so.0 via -rpath=$ORIGIN.
        ./'"${BUILD_DIR}"'/spike_driver
        DRC=$?

        # Give the daemon a beat to flush its log.
        sleep 0.1
        kill $STUB_PID 2>/dev/null || true
        wait $STUB_PID 2>/dev/null || true

        echo "[test] driver exit code = $DRC"
        exit $DRC
    ' 2>&1 | tee -a "${LOG}"

DRIVER_RC=${PIPESTATUS[0]}

echo "" | tee -a "${LOG}"
echo "[test] --- stub.log ---" | tee -a "${LOG}"
cat "${BUILD_DIR}/stub.log" 2>/dev/null | tee -a "${LOG}" || true
echo "[test] --- end stub.log ---" | tee -a "${LOG}"
echo "[test] full transcript -> ${LOG}"

exit "${DRIVER_RC}"
