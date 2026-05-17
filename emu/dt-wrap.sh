#!/bin/sh
# Wrapper to invoke debian dev tools without leaking their libs into factory env.
exec env LD_LIBRARY_PATH=/opt/dev-tools/lib/i386-linux-gnu \
    /opt/dev-tools/lib/i386-linux-gnu/ld-2.31.so \
    /opt/dev-tools/bin/$1 "${@:2}"
