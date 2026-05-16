#!/bin/sh
# Create fake DRM/PVR-discovery paths that libdrm looks at.
# These are normally created by the kernel but we don't have a kernel module.
# Bind-mount tmpfs at /proc/dri and populate.

mkdir -p /run/fake-proc-dri/0
echo -n "emgd" > /run/fake-proc-dri/0/name

mkdir -p /run/fake-sys-pci-drm
echo -n "card0" > /run/fake-sys-pci-drm/name

# Hide /proc/dri  (no-op if it doesn't exist) and mount our fake over /proc/dri
mkdir -p /proc/dri 2>/dev/null
mount -t tmpfs tmpfs /proc/dri 2>/dev/null || true
mkdir -p /proc/dri/0
echo -n "emgd" > /proc/dri/0/name

# /sys/bus/pci/devices/0000:00:02.0/drm
mkdir -p /sys/bus/pci/devices/0000:00:02.0/drm 2>/dev/null
echo -n "card0" > /sys/bus/pci/devices/0000:00:02.0/drm/name 2>/dev/null || true

echo "[setup-fakes] /proc/dri/0/name = $(cat /proc/dri/0/name 2>/dev/null)"
echo "[setup-fakes] done"
