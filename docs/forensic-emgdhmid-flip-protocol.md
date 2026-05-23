# Forensic — emgdhmid socket IPC protocol + flip semantics

Date: 2026-05-23
Source: disassembly of `/tmp/dsu-slot-a/usr/sbin/emgdhmid` (57708 bytes, ELF 32-bit i386, gcc 4.5.1, not stripped, BuildID `55ca175f...`).
Tools: `objdump -d`, `objdump -s -j .rodata`, `objdump -t`, `strings -a` via `docker run --platform linux/amd64 ubuntu:22.04`.

---

## TL;DR — the answer that unblocks Plan B'''

**To make a client pixmap visible, you DO NOT send a flip opcode. You send opcode 9 (`ConfigureBuffers`) with a fully populated `EMGDHmiBufferState[2]` array describing which pixmap goes on which plane on which screen.** The "RequestFlip" and "FlipScreen" opcodes are present in the dispatch table but their daemon-side implementations are **NO-OP stubs that always return success (1)** — they do nothing.

The actual screen update path is:

```
client → opcode 9 ConfigureBuffers(screen, EMGDHmiBufferState state[2])
         → EmgdHmiDaemon::ConfigureBuffers()
            → drmcmd(0x31, &screen,        8 bytes)   ; "begin reconfig"
            → drmcmd(0x32, &whole_msg,    16 bytes)   ; "commit buffers"
            → bindSurfaces(state[])                   ; resolve pixmap handles → plane slots
            → displaySurfaces()                       ; drmcmd(0x38, &plane_table, 0x18c bytes)
```

**Why our test app shows nothing:** we created a pixmap (opcode 5) and then called eglSwapBuffers, but we never called opcode 9 `ConfigureBuffers` to install that pixmap into a plane slot on screen 0. The pixmap exists in the daemon's `_Rb_tree<uint64_t, Pixmap*>` map but is not bound to any plane. The factory clients (`display_ps`, `navi_ps`, `hmictrl_proc`) each call `ConfigureBuffers` themselves — last writer wins.

**Visibility model:** single-pixmap-per-plane, multi-plane-per-screen, no z-order field, no client priority field, no procname check. The daemon trusts whoever connects. Whichever client most recently called `ConfigureBuffers` on screen N owns that screen's plane assignment until somebody else overwrites it.

---

## 1. Listening socket — `EmgdHmiDaemonSocket::Init()`

**Address:** `0x804a180`, 282 bytes.

Wire-level facts (from disassembly):

| Property | Value | Evidence |
|---|---|---|
| Address family | `AF_UNIX` (1) | `movl $0x1, (%esp)` before `socket@plt` |
| Socket type | `SOCK_DGRAM` (2) | `movl $0x2, 0x4(%esp)` before `socket@plt` |
| Protocol | 0 | `movl $0x0, 0x8(%esp)` |
| Bound path | `/tmp/.emgdhmid_socket` | inlined `movl` of bytes `2f 74 6d 70 2f 2e 65 6d 67 64 68 6d 69 64 5f 73 6f 63 6b 65 74` at `-0x84(%ebp)`, with `sun_family = 0x1` at `-0x86(%ebp)` |
| `bind()` addrlen | `0x6e` (110) | `movl $0x6e, 0x8(%esp)` before `bind@plt` — standard `sizeof(struct sockaddr_un)` |
| Listen / accept | **NONE** | `objdump -R` shows no `listen`/`accept` PLT entries. Datagram socket. |
| Pre-bind unlink | yes | `unlink("/tmp/.emgdhmid_socket")` immediately before `bind()` |
| FD storage | `this->fd` at offset `+0x8` of `EmgdHmiDaemonSocket` | `mov %eax, 0x8(%edx)` after `socket@plt` |

**Concurrency model:** single-threaded, single-FD, blocking `recvfrom`. There is **no thread pool, no `pthread_create`, no `epoll`/`select`/`poll`**. Every request is processed to completion before the next is read.

**Implication for clients:** because the socket is `SOCK_DGRAM`, the client must `bind()` its OWN sockaddr_un to a unique abstract or pathname address. The daemon uses the source address from `recvfrom` as the destination for its reply `sendto`. Clients that connect via `connect()` on a datagram socket and let the kernel assign an autobind address get an address like `\0XXXXX` (5 random chars); the daemon `sendto`s back to that.

---

## 2. Dispatcher — `EmgdHmiDaemonSocket::DoMsg()`

**Address:** `0x804a730`, 851 bytes.

### Receive

```c
char buf[384];                              // 0x180 bytes
struct sockaddr_un client_addr;
socklen_t client_len = 0x6e;
n = recvfrom(this->fd, buf, 0x180, 0,
             (struct sockaddr*)&client_addr, &client_len);
if (n < 0) { perror("ERROR reading command"); return; }
```

- **Fixed message size: 0x180 bytes (384 bytes) on the wire**, both request and response.
- `recvfrom` blocks. No timeout.

### Opcode extraction

The dispatcher copies the first 36 bytes (`buf[0..0x23]`) into a 9-dword stack scratch (`-0x44(%ebp)..-0x20(%ebp)`) — this is the client identity / framing area that the daemon does NOT interpret (probably opaque header from `libemgdhmi.so`). Then reads:

```
mov -0x210(%ebp), %eax       ; eax = *(uint32_t*)&buf[0x24]
mov %eax, -0x20(%ebp)        ; store opcode
cmp $0xc, %eax
jbe table_dispatch           ; jbe = unsigned <=, so [0..12] valid
jmp default_handler          ; opcode > 12 → falls through to SwitchHz
table_dispatch:
mov -0x2b5c(%ebx,%eax,4), %eax
add %ebx, %eax
jmp *%eax
```

**Opcode field: `*(uint32_t*)&buf[0x24]`** (offset 36).

### Opcode → handler table

Jump table at file offset `0x804fc0c` (decoded against the `__i686.get_pc_thunk.bx` base + 0x8003 = 0x8052768). Entries are 32-bit relative offsets; absolute target = entry + 0x8052768.

| Opcode | `.L` label | Target | Handler (mangled) | Demangled |
|---|---|---|---|---|
| 0 | `.L42` | `0x804aa18` | `_ZN19EmgdHmiDaemonSocket13GetNumScreensE...` | `GetNumScreens` |
| 1 | `.L43` | `0x804a9f8` | `_ZN19EmgdHmiDaemonSocket18GetFramebufferSizeE...` | `GetFramebufferSize` |
| 2 | `.L44` | `0x804a9d8` | `_ZN19EmgdHmiDaemonSocket15GetScreenParamsE...` | `GetScreenParams` |
| 3 | `.L45` | `0x804a9b8` | `_ZN19EmgdHmiDaemonSocket11RequestFlipE...` | `RequestFlip` **(no-op)** |
| 4 | `.L46` | `0x804a998` | `_ZN19EmgdHmiDaemonSocket10FlipScreenE...` | `FlipScreen` **(no-op)** |
| 5 | `.L47` | `0x804a978` | `_ZN19EmgdHmiDaemonSocket12CreatePixmapE...` | `CreatePixmap` |
| 6 | `.L48` | `0x804a958` | `_ZN19EmgdHmiDaemonSocket13DestroyPixmapE...` | `DestroyPixmap` |
| 7 | `.L49` | `0x804a938` | `_ZN19EmgdHmiDaemonSocket18ControlPlaneFormatE...` | `ControlPlaneFormat` |
| 8 | `.L50` | `0x804a918` | `_ZN19EmgdHmiDaemonSocket11QueryPixmapE...` | `QueryPixmap` |
| 9 | `.L51` | `0x804a8f8` | `_ZN19EmgdHmiDaemonSocket16ConfigureBuffersE...` | **`ConfigureBuffers` — the real visibility setter** |
| 10 | `.L52` | `0x804a8d8` | `_ZN19EmgdHmiDaemonSocket10StartVideoE...` | `StartVideo` |
| 11 | `.L53` | `0x804a8c0` | `_ZN19EmgdHmiDaemonSocket9StopVideoE...` | `StopVideo` |
| 12 | `.L54` | `0x804aa38` | `_ZN19EmgdHmiDaemonSocket8SwitchHzE...` | `SwitchHz` (also serves opcode > 12 fallthrough) |

### Reply

Every handler is called as `handler(&buf, &buf)` (in/out same buffer), then unconditionally:

```c
sendto(this->fd, buf, 0x180, 0,
       (struct sockaddr*)&client_addr, client_len);
if (ret != 0x180) perror("ERROR writing response");
```

So the response is always exactly 384 bytes back to the client's source address. Handlers populate response fields at fixed offsets in `buf`. No partial responses, no streaming, no async notifications.

---

## 3. Per-handler payload layouts (from the socket-wrapper functions)

All offsets are into the 384-byte message buffer. `buf+0x00`...`buf+0x23` is opaque client framing. `buf+0x24` is the opcode (4 bytes).

### Opcode 5 — `CreatePixmap` (wrapper `0x804a350`)

```
Request:
  buf[0x28] : uint32_t  width    (formal arg 1)
  buf[0x2c] : uint32_t  height   (formal arg 2)
  buf[0x30] : uint32_t  format   (formal arg 3) — 3 = flipchain path, 5 = PVR2DMemAlloc-only path
Response:
  buf[0x34] : uint32_t  pixmap_handle_lo  (low 32 of returned uint64_t)
  buf[0x38] : uint32_t  pixmap_handle_hi  (high 32)
  buf[0x3c] : uint32_t  status   (0 = OK, 0xfffffffa / -6 = bad arg)
```

The daemon allocates either a `PVR2DCreateFlipChain` (default) or `PVR2DMemAlloc` (format=5) and inserts the pixmap into a `std::map<uint64_t, Pixmap*>` keyed by handle. **The handle is the only identity the client gets.** Just creating a pixmap does NOT make it visible.

### Opcode 6 — `DestroyPixmap` (wrapper `0x804a3c0`)

```
Request:
  buf[0x28] : uint64_t  pixmap_handle (lo at +0x28, hi at +0x2c)
Response:
  buf[0x30] : uint32_t  status
```

### Opcode 7 — `ControlPlaneFormat` (wrapper `0x804a300` → daemon `0x804adc0`)

```
Request:
  buf[0x28] : uint32_t  plane?  (arg 1)
  buf[0x2c] : uint32_t  format? (arg 2)
Daemon:
  drmcmd(0x34, {0, arg1, arg2}, 12 bytes)
```

Thin wrapper around DRM ioctl 0x34. Affects plane pixel format; does not select visibility.

### Opcode 8 — `QueryPixmap`

```
Request:
  buf[0x28] : uint64_t  pixmap_handle
Response:
  buf[0x30] : uint32_t  width
  buf[0x34] : uint32_t  height
  buf[0x38] : uint32_t  format
  buf[0x3c] : uint32_t  status
```

Pure lookup, no side effects.

### Opcode 9 — `ConfigureBuffers` (wrapper `0x804a2a0` → daemon `0x804d3e0`) **★ the real flip**

```
Request:
  buf[0x28] : int32_t   screen_index  (which screen: 0 or 1)
  buf[0x2c] ..buf[0xd3] : EMGDHmiBufferState state[0][N]  (168 bytes of layer descriptors)
  buf[0xd4] ..buf[0x17b]: EMGDHmiBufferState state[1][N]  (168 bytes of layer descriptors)
Response:
  buf[0x17c] : uint32_t  status   (0 = OK)
```

The wrapper builds `EMGDHmiBufferState* state[2] = { &buf[0x2c], &buf[0xd4] }` and passes both arrays + the screen index into the daemon method. The daemon then:

1. Calls `drmcmd(0x31, &screen_index, 8)` — "begin reconfig" notify
2. Re-allocates internal `this->old_planes[]` buffer (mallocs `4` bytes for pointer, then `this->plane_count * 0x1c` for the array itself — 28-byte plane records, count = `this->u70`)
3. Calls `drmcmd(0x32, this+0x6c, 16)` — "commit buffers"
4. Calls `bindSurfaces(state)` — resolves each state[s][n] entry to a plane slot
5. **If bindSurfaces returns 0 (success), calls `displaySurfaces()`** — see §4
6. On success, `memcpy(this+0x20c, state[0], 168)` and `memcpy(this+0x2b4, state[1], 168)` — caches the configured state for next round
7. Returns status to client

**This is the only path that triggers a screen update.** All other opcodes are bookkeeping.

### Opcode 3 — `RequestFlip` (wrapper `0x804a5d0` → daemon `0x804ada0`) ★ NO-OP

```
Request:
  buf[0x28] : int32_t  arg1     (intended: pixmap to flip?)
  buf[0x2c] : int32_t  arg2     (intended: screen?)
Response:
  buf[0x30] : uint32_t  status (always 1 = success)
  buf[0x34] : uint32_t  zero
```

Daemon implementation in full:
```
0804ada0 <_ZN13EmgdHmiDaemon11RequestFlipEii>:
 804ada0:	55                   	push   %ebp
 804ada1:	b8 01 00 00 00       	mov    $0x1,%eax       ; return 1
 804ada6:	89 e5                	mov    %esp,%ebp
 804ada8:	5d                   	pop    %ebp
 804ada9:	c3                   	ret
```

**That is the entire function. 10 bytes. No DRM call, no map lookup, no state write.** The socket wrapper takes the return value, stores it as a status byte at `buf[0x30]`, zero at `buf[0x34]`, and replies. Client sees "flip succeeded" and observes nothing change on the panel.

### Opcode 4 — `FlipScreen` (wrapper `0x804a410` → daemon `0x804adb0`) ★ NO-OP

```
0804adb0 <_ZN13EmgdHmiDaemon10FlipScreenEii>:
 804adb0:	55                   	push   %ebp
 804adb1:	89 e5                	mov    %esp,%ebp
 804adb3:	5d                   	pop    %ebp
 804adb4:	c3                   	ret    ; returns whatever was in %eax — undefined
```

5 bytes. Even shorter than RequestFlip. Returns garbage.

### Opcode 10 — `StartVideo` (wrapper `0x804a620`)

```
Request:
  buf[0x28]..buf[?] : EMGDHmiVideoContext (struct by value)
```

Sets up the V4L2 → V2G bridge → camera path. Out of scope for our pixmap question, but uses `/dev/v2gbridge` and `/dev/video0`.

### Opcode 12 — `SwitchHz` (wrapper `0x804a6e0` → daemon `0x804aec0`)

```
Request:
  buf[0x28] : int32_t  screen
  buf[0x2c] : int32_t  hz
Daemon:
  drmcmd_master(0x25, ...)  ; SWITCH_HZ — requires DRM master
```

This is one of the few code paths that re-grabs master.

---

## 4. `displaySurfaces()` — the actual screen commit (`0x804ae10`)

160 bytes. Body, paraphrased:

```c
int EmgdHmiDaemon::displaySurfaces() {
    struct {
        uint32_t  zero;       // -0x1a4 .. always 0
        uint32_t  field1;     // = this->u64  (probably "active screen mask" or similar)
        uint32_t  field2;     // = this->u68
        char      plane_table[396];  // = this+0x84  (24 * 16 bytes? 12 * 33? actually 0x18c bytes)
    } req;                                       // total 0x18c bytes
    req.field1   = this->u64;
    req.field2   = this->u68;
    memcpy(req.plane_table, this+0x84, 396);     // copy current plane snapshot
    int r = drmcmd(0x38, &req, 0x18c);
    if (r != 0) fprintf(stderr, "DRM cmd %d failure: %d\n", 0x38, r);
    return r;
}
```

**DRM ioctl 0x38** with **0x18c (396) bytes** of payload is the kernel-side composite/commit. This is the ioctl that actually programs the EMGD overlay/sprite planes. The payload is built from `this->u84` onward — that's the **plane assignment table** populated by `bindSurfaces()` during `ConfigureBuffers`.

**Plane table layout** (from `bindSurfaces` writes — each entry is **64 bytes**, indexed by `screen * planes_per_screen + plane_index`):

| Offset in entry | Meaning (inferred) | Source from BufferState |
|---|---|---|
| +0x00 | plane type (1=HMI, 2=X11, 3=Popup, 4=Video, 6=Empty/passthrough) | hardcoded per branch |
| +0x04 | pixmap memdev handle | `Pixmap.pvr_memdev_handle` (via map lookup) |
| +0x08 | format / colorkey? | `state.field24` |
| +0x0c | y_offset | `state.field14` |
| +0x10 | h | `state.field18` |
| +0x14 | y2 | `y_offset + height` |
| +0x18 | h2 | `y_offset + h` |
| +0x1c | x_offset | `state.field0c` |
| +0x20 | w | `state.field10` |
| +0x24 | x2 | `x_offset + w` |
| +0x28 | w2 | `x_offset + width` |
| +0x2c | (copied) | `state.field04` |
| +0x30..+0x3c | colorkey / blend params | `state.field28..34` |

The strings `"No plane available for HMI buffer on pipe %d !"`, `"No plane available for X11 buffer on pipe %d !"`, `"No plane available for Popup buffer on pipe %d !"`, `"No plane available for Video on screen %d !"`, and `"Invalid plane type (%d) in new state[%d][%d] !"` all live in `bindSurfaces`. They establish that:

- Each screen has a fixed pool of plane slots typed by role (HMI / X11 / Popup / Video).
- The state array tells `bindSurfaces` what role each entry plays; it looks up the matching plane on the matching pipe.
- The 2D index `[screen][plane_slot]` is real (literal printf "state[%d][%d]"). The first index is screen 0 or 1; the second is the plane slot within that screen's config.

---

## 5. CreatePixmap — what actually happens (`0x804c6d0`)

840 bytes. Two paths depending on `format` arg:

**Path A (`format != 5`, default):**
```c
PVR2DCreateFlipChain(this->pvr_ctx, 4, 1, 4,    // flags, numbuf=1, format=4 (RGBA8888)
                     width, height,
                     &chain_handle, &chain_pos, &num_buffers);
PVR2DGetFlipChainBuffers(...);
```
Creates a single-buffer PVR2D flip chain. The "flip chain" abstraction is per-pixmap, not per-screen — each pixmap has its own swap chain. The buffer's memdev handle is stored at `Pixmap+0x10`.

**Path B (`format == 5`):**
```c
size = align_up(width * 4, 128) * height;
PVR2DMemAlloc(this->pvr_ctx, size, 0x1000, 0, &mem_info);
PVR2DMemExport(this->pvr_ctx, 0, mem_info, &export_handle);
```
Single linear allocation, no chain. Used for one-shot buffers.

Either way, the resulting handle is inserted into the daemon's `std::map<uint64_t, Pixmap*>` and returned to the client. **No display assignment happens here.**

---

## 6. Default visible pixmap — there isn't one

There is **no hardcoded splash image, no first-client-wins logic, no procname check, no privilege check, no z-order field, no init-time "show this" call** anywhere in emgdhmid.

At daemon startup (`main` → `EmgdHmiDaemonC2` → `initScreenParams` + `initDRM`):
1. `drmOpen("emgd", "PCI:00:02:00")`, immediately `drmDropMaster` (Agent 6 finding — confirmed).
2. `initScreenParams()` (4615 bytes — big) parses `/etc/emgdhmid-screens` (not present in slot A — must be runtime-provisioned by `nav_init`) to learn screen geometry.
3. `drmcmd_master(0x2c, ...)` — CONFIG_BUFFS (initial empty buffer config).
4. `drmcmd_master(0x25, ...)` — SWITCH_HZ.
5. `SrvInit()` (PVR services).
6. `getDisplayHandle()` per screen.
7. Create the socket. Enter `DoMsg()` loop.

**At this point, nothing is on the panel.** Whatever was on the LVDS before emgdhmid started (BIOS splash, prior kernel framebuffer) is still showing because emgdhmid hasn't pushed a new plane table. The first thing that lights up the panel is whatever client first calls `ConfigureBuffers` — in the factory system that's `display_ps` or `fis_ps` (the "initial screen" service).

In the factory boot sequence:
- emgdhmid logs `v2g: Enable Overlay Bridge on screen 1779026867` at t≈7.0s — that's the first `ConfigureBuffers` from a client (probably `fis_ps`).
- emgdhmid logs `v2g: Enable Sprite C Bridge on screen 0` at t≈16.3s — that's `navi_ps` or `display_ps` claiming Sprite C.

**There is no "default client" or "fallback pixmap". The panel is dark until somebody calls ConfigureBuffers.**

---

## 7. Plane / layer model — flat, last-writer-wins

| Question | Answer |
|---|---|
| Single visible per screen, or composite? | **Composite of up to N typed planes per screen** (HMI / X11 / Popup / Video). EMGD hardware composites them — there is no software blit in emgdhmid. The plane table sent via drmcmd 0x38 is what the hardware reads. |
| Z-order field? | **None** in the wire format or the internal plane record. Z-order is implicit by plane type — Video is bottom (Sprite background), HMI is overlay, Popup is top — and is baked into the EMGD hardware's plane ordering, not configurable per-call. |
| Per-client ownership? | **None.** No client-id tracking. The daemon does not record which client created which pixmap. `DestroyPixmap` works for any client given any handle — there is no "you can only destroy your own pixmap" check. |
| Privilege check? | **None.** No `getsockopt(SO_PEERCRED)`, no `geteuid`, no procname compare. Whoever talks to the socket can do anything. |
| What stops two clients fighting? | **Nothing in emgdhmid.** Last `ConfigureBuffers` wins. In the factory system, the smng supervisor orders client startup so that display_ps owns screen 0 and hmictrl_proc owns screen 1, and they don't trample each other. |
| DRM_IOCTL_MODE_SETPLANE / atomic? | **Not used.** This is EMGD's pre-atomic 1.5.x stack on a 2.6.37 kernel. All plane programming flows through the EMGD-specific `drmcmd 0x38` ioctl, not mainline KMS APIs. |

---

## 8. Why our Plan B''' app sees nothing — the fix

Our current pipeline:
1. `emgdHmiGetNativeDisplay` → magic cookie (no socket call yet, just blesses the handle)
2. `emgdHmiCreatePixmap` → opcode 5, returns handle 0x37 → daemon has it in the map ✓
3. `eglCreatePixmapSurface(..., 0x37)` → succeeds locally in libEGL ✓
4. `eglMakeCurrent + glClear + eglSwapBuffers` → renders into the PVR2D backing buffer ✓
5. **(Missing) → opcode 9 ConfigureBuffers binding handle 0x37 to a plane slot on screen 0**
6. Daemon never calls `displaySurfaces` → drmcmd 0x38 never fires → hardware plane registers never updated → panel still shows whatever was there before.

**The fix is to send a `ConfigureBuffers` (opcode 9) message** with a state array that has one entry: `{ type=1 HMI, pixmap_handle=0x37, x=0, y=0, w=800, h=480 }` plus zeros for everything else. The exact field layout of `EMGDHmiBufferState` matters and the easiest path is to call `libemgdhmi.so.0`'s wrapper — it presumably exposes an `emgdHmiConfigureBuffers(display, screen, state[])` or equivalent. If the libemgdhmi we're linking against doesn't expose it (or we're calling the wrong sequence), we have two options:

1. **Strings-grep libemgdhmi.so for the wrapper symbol** (`nm -D /usr/lib/libemgdhmi.so.0.1.0 | grep -i config`). Find what factory clients call. Mimic that.
2. **Skip libemgdhmi and talk to `/tmp/.emgdhmid_socket` directly**:
   - `socket(AF_UNIX, SOCK_DGRAM, 0)`, `bind` to a unique path (e.g., `/tmp/.q60nav_emgd_client`),
   - `sendto` a 384-byte buffer with `buf[0x24] = 9`, `buf[0x28] = 0` (screen index), `buf[0x2c..]` = filled state array,
   - `recvfrom` the 384-byte reply, check status at `buf[0x17c]`.

   The hard part is filling `EMGDHmiBufferState`. Best path: `LD_PRELOAD` a shim that traces what `display_ps` writes into its message buffer right before the `sendto` to `/tmp/.emgdhmid_socket`, then replay that for our pixmap handle.

**Sanity check on Agent 6's note:** Agent 6 referred to "EMGDHMIAPI_GETFRAMEBUFFERSIZE" and "EMGDHMIAPI_REQUESTFLIP" opcodes. Those names match opcodes 1 and 3 in our table. But the prior advice that REQUESTFLIP "triggers a flip" is wrong — that opcode is a stub. The real flip is ConfigureBuffers (opcode 9). Agent 6 didn't trace the daemon implementation, only the client-side string. Mystery solved.

---

## 9. String evidence — for the record

```
$ strings emgdhmid | grep -iE "(flip|plane|layer|active|prio|z.order|HMI|popup|X11)"
PVR2DCreateFlipChain
PVR2DGetFlipChainBuffers
PVR2DDestroyFlipChain
failure in PVR2DCreateFlipChain (%d x %d): %d
failure in PVR2DGetFlipChainBuffers: %d
Invalid Popup dimensions !
No plane available for HMI buffer on pipe %d !
No plane available for X11 buffer on pipe %d !
No plane available for Popup buffer on pipe %d !
No plane available for Video on screen %d !
Invalid plane type (%d) in new state[%d][%d] !
EMGDHMI_FAKE_NAVI_VIDEO
EMGDHMI_USE_CONSTANT_BUFFERS
EMGDHMI_DUMP_CONSTANT_BUFFERS
```

No occurrences of "z-order", "priority", "visible", "active", "default", "splash", "boot logo", "logo" anywhere in the binary. The daemon truly has no such concept.

---

## 10. Recommended next probes

1. **Disassemble `libemgdhmi.so.0.1.0`** (~30 KB, also in `/tmp/dsu-slot-a/usr/lib/`). Find the client-side wrapper that builds the opcode-9 message. Its function name will tell us what to call from our app. Field layout of `EMGDHmiBufferState` is also derivable from there.
2. **Capture a live `strace -e sendto,recvfrom -s 400 -x` of `display_ps`** on running hardware. Get the exact 384-byte payload of an opcode-9 message. That's the gold standard — copy it, swap in our pixmap handle, replay.
3. **Try `LD_PRELOAD`-shim over emgdhmid's `recvfrom`** to log every incoming message. Each handler is small enough that even raw hexdumps will show the field layout.
4. **Inspect `/etc/emgdhmid-screens` on running hardware** via `cat` (file is runtime-provisioned, format `screen %d %d x %d @ %d, %d`). Confirms which port maps to which screen index.

---

## Appendix — key addresses

| Symbol | Address | Size |
|---|---|---|
| `EmgdHmiDaemonSocket::Init` | `0x804a180` | 0x11a |
| `EmgdHmiDaemonSocket::DoMsg` | `0x804a730` | 0x353 |
| `EmgdHmiDaemonSocket::ConfigureBuffers` (wrapper) | `0x804a2a0` | 0x55 |
| `EmgdHmiDaemonSocket::RequestFlip` (wrapper) | `0x804a5d0` | 0x4d |
| `EmgdHmiDaemonSocket::CreatePixmap` (wrapper) | `0x804a350` | 0x6d |
| `EmgdHmiDaemon::ConfigureBuffers` (daemon) | `0x804d3e0` | 0x196 |
| `EmgdHmiDaemon::RequestFlip` (daemon, **stub**) | `0x804ada0` | 0x0a |
| `EmgdHmiDaemon::FlipScreen` (daemon, **stub**) | `0x804adb0` | 0x05 |
| `EmgdHmiDaemon::displaySurfaces` | `0x804ae10` | 0xa4 |
| `EmgdHmiDaemon::bindSurfaces` | `0x804ce40` | 0x596 |
| `EmgdHmiDaemon::CreatePixmap` (daemon) | `0x804c6d0` | 0x349 |
| `EmgdHmiDaemon::DestroyPixmap` (daemon) | `0x804ccf0` | 0x144 |
| `EmgdHmiDaemon::QueryPixmap` | `0x804ca20` | 0x2cb |
| `EmgdHmiDaemon::initDRM` | `0x804ac70` | 0xf6 |
| `EmgdHmiDaemon::initScreenParams` | `0x804afd0` | 0x1207 |
| `EmgdHmiDaemon::drmcmd_master` | `0x804aa90` | 0xbb |
| `EmgdHmiDaemon::drmcmd` | `0x804ab50` | 0xa3 |
| Dispatch jump table (13 entries) | `0x804fc0c` | 0x34 |

Opcode → DRM ioctl mapping seen so far:
| Operation | drmcmd nr | size |
|---|---|---|
| `ConfigureBuffers` step 1 (begin) | 0x31 | 8 |
| `ConfigureBuffers` step 2 (commit) | 0x32 | 16 |
| `ControlPlaneFormat` | 0x34 | 12 |
| `displaySurfaces` (the actual hw commit) | **0x38** | **396** |
| `SwitchHz` (master-required) | 0x25 | 8 |
| `CONFIG_BUFFS` init (master-required) | 0x2c | 0x250 |

---

End of report.
