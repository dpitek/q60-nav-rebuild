# R1 — DRM privilege requirements discovered

Date: 2026-05-16
Source: `/tmp/emgd/drm/emgd/drm/emgd_drv.c` (EMGD-Community upstream source)

## The ioctl-permission table

```c
DRM_IOCTL_IGD_GMM_ALLOC_REGION  → DRM_MASTER | DRM_UNLOCKED
DRM_IOCTL_IGD_GMM_ALLOC_SURFACE → DRM_MASTER | DRM_UNLOCKED
DRM_IOCTL_IGD_ALTER_OVL         → DRM_MASTER | DRM_UNLOCKED
DRM_IOCTL_IGD_ALTER_OVL2        → DRM_AUTH | DRM_UNLOCKED  (downgraded from MASTER
                                  per source comment: "so that libva wayland can
                                  call alter_ovl without going through X server")
DRM_IOCTL_IGD_APPCTX_ALLOC      → DRM_AUTH | DRM_UNLOCKED
```

## What this means for R1

On the actual DCU, `hmictrl_proc` opens `/dev/dri/card0` first and becomes the
sole DRM master. When our q60nav client opens the device, we are a non-master,
non-authenticated client.

- **GMM_ALLOC_REGION (DRM_MASTER)** — our client can't call this. Kernel returns
  -EACCES.
- **ALTER_OVL2 (DRM_AUTH)** — our client needs to obtain a magic token from
  hmictrl_proc and authenticate (`drmGetMagic` → IPC to master →
  `drmAuthMagic`). Doable but requires a side-channel to hmictrl_proc.

## Why `emgdhmid` works without being master

`emgdhmid` doesn't use `GMM_ALLOC_REGION`. It uses the V4L2 / IOH camera-capture
path which has its own buffer allocator outside the DRM_MASTER gate. For
overlay attach, it uses `ALTER_OVL2` (the AUTH-only variant) and presumably
gets auth via the v2gbridge misc-device which has its own access-control
(Group=video gate).

## Implications for our buffer allocation

Three workable paths to get a paintable GTT-mapped buffer:

1. **V4L2/IOH path (matches emgdhmid)** — open `/dev/video0`, REQBUFS,
   QUERYBUF, mmap. Then use those buffers with ALTER_OVL2. We don't write
   camera frames into them; we write our own pixels.
2. **PVRSRV Display Class swap-chain** — link against `libemgdsrv_um.so`,
   call `PVRSRVCreateDCSwapChain` which allocates buffers without needing
   DRM master. Then attach via ALTER_OVL2.
3. **Replace hmictrl_proc entirely** — disable the factory unit, our client
   becomes DRM master, has unrestricted access. Bigger architectural change.

## Recommended first hardware test

Run with `--skip-alter` first. The log will report whether `GMM_ALLOC_REGION`
succeeds or fails with EACCES — confirming or refuting the DRM master block.
