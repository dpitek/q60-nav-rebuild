# Q60 DSU Emulator

Docker-based emulator for the Clarion QY5092 DCU's userland — runs i386 factory
binaries under QEMU on any host (tested arm64 Mac). Built to **iterate at
developer speed** instead of the 2-5 minute boot-test cycle.

## What it gives us

- A way to execute factory daemons (`emgdhmid`, `hmictrl_proc`, PS_* family)
  outside the actual DCU.
- Visibility into their ioctl/syscall flow via the LD_PRELOAD shim
  (`shim/q60_iohook.c`).
- A test bed for our own R1 (Sprite C overlay) client code before deploying to
  hardware.

## What it does NOT cover

- `/dev/v2gbridge`, `/dev/dri/card0` real hardware (no kernel modules); the
  shim fakes these.
- Real LCD output, CAN bus, audio. Pure userland trace only.

## Setup

The rootfs is extracted from Doug's DSU backup (read-only loopback) and is
**not committed** to this repo — it contains proprietary DENSO / Intel EMGD
binaries. To build locally:

```bash
# 1. Attach DSU backup readonly
hdiutil attach -nomount -readonly "/path/to/DSU backup.img"   # → /dev/diskN

# 2. Extract Slot A + /home/naviwork via debugfs (native macOS, no sudo for the
#    extract itself since loopback files inherit owner)
DEBUGFS=/opt/homebrew/opt/e2fsprogs/sbin/debugfs
mkdir -p /tmp/q60-emu/{slot-a,naviwork}
$DEBUGFS -R "rdump / /tmp/q60-emu/slot-a"  /dev/disk6s2    # Slot A
$DEBUGFS -R "rdump / /tmp/q60-emu/naviwork" /dev/disk6s8   # /home/naviwork

# 3. chmod mode-000 files (etc/shadow + VR backup blobs) so tar can read them
find /tmp/q60-emu -perm 000 -type f -exec chmod 600 {} \;

# 4. Tar the trees (BSD tar, --no-xattrs to avoid macOS extended-attribute
#    weirdness)
cd /tmp/q60-emu
tar --no-xattrs --no-mac-metadata -cf slot-a.tar -C slot-a .
tar --no-xattrs --no-mac-metadata -cf naviwork.tar -C naviwork .

# 5. Copy build.sh + Dockerfile.q60 from this repo into /tmp/q60-emu/, then:
bash build.sh
```

## What's in this directory

| File | What it does |
|---|---|
| `Dockerfile.q60` | Builds `q60-dsu:latest` — factory rootfs in a `scratch` base, linux/386 platform. |
| `Dockerfile.q60-dev` | Extends with `strace`, `coreutils`, `ltrace` from a debian:bullseye-i386 build stage. Tools kept in `/opt/dev-tools/` so they don't shadow factory libs. |
| `build.sh` | Builds the image from `slot-a.tar` + `naviwork.tar` (placed alongside). |
| `shim/q60_iohook.c` | LD_PRELOAD shim. Intercepts `open()` for `/dev/v2gbridge`, `/dev/dri/card0`, `/dev/video0`, etc. Synthesizes responses for standard DRM ioctls (`DRM_IOCTL_VERSION`, `GET_UNIQUE`, `SET_VERSION`, `GET_MAGIC`). |
| `setup-fakes.sh` | Runtime setup of fake `/proc/dri/0/name` + `/sys/bus/pci/...` paths (best-effort under Docker's read-only `/proc`). |
| `dt-wrap.sh` | Wrapper to invoke debian dev tools without polluting factory binaries' library path. |

## Build the shim (i386 glibc — matches factory rootfs's libc)

```bash
docker run --rm --platform linux/386 -v $(pwd)/shim:/build \
    i386/debian:bullseye bash -c '
        apt-get update >/dev/null
        apt-get install -y --no-install-recommends gcc libc6-dev binutils >/dev/null
        cd /build
        gcc -shared -fPIC -m32 -O2 -Wall \
            -o q60_iohook.so q60_iohook.c -ldl -lpthread
        objcopy --remove-section=.note.ABI-tag q60_iohook.so
    '
```

Result: `shim/q60_iohook.so` — a ~16 KB i386 ELF shared library, no
`.note.ABI-tag`, dependencies on `libc.so.6`, `libpthread.so.0`, `libdl.so.2`
(all present in the factory rootfs).

## Run a factory daemon with the shim

```bash
docker run --rm --platform linux/386 \
    -v $(pwd)/shim:/shim:ro \
    q60-dsu:latest /bin/sh -c '
    cp /shim/q60_iohook.so /q60_iohook.so
    chmod 755 /q60_iohook.so
    LD_PRELOAD=/q60_iohook.so /usr/sbin/emgdhmid 2>/tmp/emgd.err &
    PID=$!
    sleep 8
    kill -KILL $PID 2>/dev/null
    cat /tmp/q60_iohook.log    # the ioctl trace
    echo --- emgd stderr ---
    cat /tmp/emgd.err
'
```

## Findings from initial runs (2026-05-16)

`emgdhmid` executes standard `libdrm` initialization:

```
open64("/dev/dri/card0") → FAKE fd
ioctl(DRM_IOCTL_VERSION)      → smart: returns "emgd 1.0.0"
ioctl(DRM_IOCTL_SET_VERSION)  → smart: accepted
ioctl(DRM_IOCTL_GET_UNIQUE)   → smart: returns "PCI:0000:00:02.0"
close
```

After the standard DRM dance, `emgdhmid` proceeds to **EMGD-specific
`drmCommandWriteRead`** calls (commands 9, 37, 44, etc.). Our shim returns
`OK 0` with zeroed response buffers, which `emgdhmid` interprets as "the kernel
didn't actually fill in a reply" and logs `"DRM cmd N failure: -1"`.

To progress further, the shim needs realistic response stubs for each
EMGD-specific ioctl. See `docs/plan-r1-sprite-c-design.md` for the relevant
struct definitions extracted from the EMGD source tree (cloned at
`/tmp/emgd/` during R1 research).

## Use case going forward

The shim is also a **harness for our own R1 client code**. Build q60nav with
`-DEMU_BUILD` and a tiny mock-aware path that prefers the shim's faked devices,
and we can verify our ioctl sequence is exactly right BEFORE deploying to the
DCU.
