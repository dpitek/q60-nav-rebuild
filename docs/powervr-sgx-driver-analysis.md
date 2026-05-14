# PowerVR SGX 535 Driver Analysis — Is Hardware Acceleration Worth Chasing?

**Target hardware:** Intel Atom E6xx (Tunnel Creek) + PowerVR SGX 535 @ ~200 MHz
**Current state:** Mesa swrast + Qt6 `QT_QUICK_BACKEND=software` + `QSG_RENDER_LOOP=basic`
**Kernel target:** Linux 4.19
**Audience:** solo developer evaluating weeks/months/years of effort

---

## Section 1: State of the art (2026)

What actually exists for the SGX 535 on a non-museum kernel:

| Component | Status | Notes |
|---|---|---|
| `gma500` DRM driver (mainline) | Alive, KMS-only | In tree since 3.3, builds on 4.19. Modesetting + cursor + HDMI/LVDS only. **No 2D accel, no 3D accel.** Last meaningful work on patjak/drm-gma500 wiki dates to **2013**. |
| Intel EMGD (binary stack) | **Dead** | Last official 1.18 (2012). EMGD-Community on GitHub stalled — kernel 3.19 "works", 4.0 "should work, untested". No 4.x/5.x success reports. |
| Imagination open-source PowerVR | Rogue + AXE only | Mesa Vulkan landed 2022 (`pvr`), kernel `drm/imagination` landed in **6.8 (2024)**. **SGX series explicitly excluded.** Imagination has publicly stated "no plans" to open SGX. |
| PowerVR-Series1 GitHub release | Irrelevant | Imagination did open Series 1 source (Midas, PCX1/2) — that's 1990s desktop hardware, nothing to do with SGX. |
| Community RE projects | Effectively dead | A 2010 SGX leak poisoned the well — FSF guidance still classifies leaked code as proprietary. No active "freedreno-for-SGX" effort exists in 2026. Garnet/lyra.cat blog is a hobbyist post, not a project. |
| TI's `omap-gfx` SGX user-space | Not portable | TI shipped SGX user-space blobs for OMAP3/4 (also SGX 535-class), but they target the TI-specific kernel-mode driver and ARM ABI — not Atom/x86. |
| VXD392/393 video decoder (ipvr) | Abandoned | Intel published `ipvr` for Bay Trail's VXD392 in 2014, never upstreamed, bit-rotted. Our E6xx has a different VXD generation anyway. |

**Bottom line:** Every viable path through Imagination, Intel, or community RE has either died, was never open, or targets later silicon.

---

## Section 2: Path A — Resurrect EMGD

**Plan:** Take EMGD 1.18 (kernel 2.6.37 / X.org 1.10), port the kernel-mode `pvrsrvkm.ko` shim to 4.19, keep the user-space blob (`libpvr*.so`, `libIMGegl.so`, the X11 DDX) as-is.

**What blocks a direct port (kernel ABI deltas, 2.6.37 → 4.19):**

1. **DRM core rewrite.** `<drmP.h>` removed (use `<drm/drm_*.h>` granular headers). `drm_driver` struct gutted — `.load/.unload/.firstopen/.lastclose` semantics changed; `gem_init_object`/`gem_free_object` replaced by `drm_gem_object_funcs`. Most EMGD 1.18 binds to functions that simply do not exist in 4.19.
2. **GEM/TTM:** EMGD predates the modern GEM helpers (`drm_gem_handle_create`, prime/dma-buf import-export). To run on KMS Wayland or modern X you need dma-buf — EMGD's buffer manager (`PVRMMap`) doesn't speak it.
3. **`mmap_sem` → `mmap_lock`** (5.x but already churning in 4.x); ioremap signatures changed; `get_user_pages` signature changed twice.
4. **`struct file_operations.unlocked_ioctl`/`compat_ioctl` semantics**, `vm_operations_struct.fault` prototype, `pte_t` accessors — all touched by the EMGD char-device path.
5. **Sysfs/kobject lifecycle** rewrites; **PCI** `pci_enable_msi_range` deprecation; **interrupt handlers** `IRQF_DISABLED` removed.
6. **X.org ABI:** EMGD's X11 DDX targets xserver 1.10. Current Debian Buster (4.19 era) ships xserver 1.20 — incompatible video ABI. You'd be stuck on a frozen X server and would never see Wayland.
7. **GLIBC + C++ ABI** drift breaks the user-space blobs unless you ship a 2012-vintage rootfs userspace alongside the GPU stack — which defeats the point of running a modern OS.

**Who has tried:** The EMGD-Community repo. Last commit metadata visible is multi-year stale. Their own table marks 4.0 as "builds, not tested." No 4.19 build report exists in public.

**Effort estimate:** A skilled kernel-graphics engineer who has done this kind of forward-port before (a real, narrow specialty) — **6 to 12 months** to maybe get a flickering EGL surface on a frozen X stack. Solo dev with no prior kernel-graphics work: **multi-year, low probability of success.** And the prize at the end is a stack chained to a 2012 X server.

**Success probability:** ~5%. Not "impossible" — "wildly disproportionate."

---

## Section 3: Path B — gma500 + custom 2D acceleration

**Plan:** Stay in mainline. Extend `drivers/gpu/drm/gma500/` with 2D blit/fill/scaled-blit operations driven by the PVR2D blitter block inside SGX.

**Reality check:**

- Patrik Jakobsson's gma500 wiki lists 2D accel as **planned**, status "working but crashes due to MMU problems." That note is **from 2013**. No one finished it. No one has touched it since.
- Alan Cox's 2011 patch series added basic Cedarview KMS. After that, gma500 went into permanent maintenance-only mode.
- To do 2D you need the SGX MMU programming sequences, ring-buffer command submission format, and PVR2D blit opcodes. **None of those are public.** The 2010 leak is the only source and is legally radioactive.
- Even if it worked: PVR2D is a fixed-function 2D blitter (color fill, copy, alpha-blend, scaled blit). It does **not** accelerate the SGX 3D pipeline, so it would not give you OpenGL ES / Qt RHI acceleration — it would just make XRender / Cairo faster, which only helps a Qt6 stack if you're running QtWidgets through X11. With Qt Quick + software backend, **2D blit accel does not help the QQuickItem composition path** — Qt's software backend rasterizes into a CPU framebuffer and then a single full-frame DMA copy happens. There's no per-item blit Qt Quick can hand off to a 2D engine.

**Effort estimate:** Even with a willing kernel hacker, **6+ months** to ship working 2D accel without leaked specs. Without specs, indefinite. And the payoff for our Qt Quick stack is **near zero.**

---

## Section 4: Path C — Reverse engineer from scratch

Comparable efforts as calibration:

| Project | Target | Person-years to usable GLES2 | Notes |
|---|---|---|---|
| freedreno (Adreno) | Qualcomm Adreno 2xx/3xx | ~3 years, 1-2 people | Helped by docs leaked from Code Aurora |
| etnaviv (Vivante) | Vivante GC2000 | ~3 years, 2-3 people | Vivante's userland blob was self-documenting |
| lima (Mali-400) | ARM Mali Utgard | **~7 years**, small team | Mali-400 is roughly SGX 535's contemporary |
| panfrost (Mali Midgard/Bifrost) | Newer Mali | ~3 years | Helped by Collabora funding |
| asahi (Apple AGX) | Apple M1 | ~2 years to GLES3 | Funded full-time work by Alyssa Rosenzweig |

PowerVR SGX is **architecturally harder** than any of these: tile-based deferred rendering, microcode-driven command processor, USSE shader ISA with no public documentation, MMU programming sequences locked inside `pvrsrvkm.ko`. Imagination holds 1,600+ patents and has historically been the most litigious GPU vendor toward open driver projects. The 2010 source leak makes any RE work additionally suspect — clean-room provenance becomes a documentation nightmare.

**Solo developer estimate: 5-10 person-years.** This is not a side project. It is a career.

---

## Section 5: Path D — Live with swrast (status quo)

**Honest performance picture today:**

- Atom E6xx Bonnell, 1 GHz, 1 core, in-order, **MMX/SSE3 only — no SSE4.1, no AVX, no NEON**. Mesa `llvmpipe` JIT generates SSE3 code paths — functional but unoptimized; old `swrast_dri` is even slower.
- 1 GB RAM; CPU and GPU share the memory controller (UMA).
- Reported 8-15 FPS for static UI at 800x480 + 800x420 dual.

**What you lose without 3D accel:**
- `Qt Quick 3D` (we don't use it)
- Real-time shader effects, `ShaderEffect`, `OpacityMask`, animated gradients (we shouldn't use them)
- Transparent overlays composited per-pixel by GPU (fine — Qt software backend does it on CPU)
- Smooth >30 FPS animations on large surfaces

**What still works fine on swrast:**
- Static text, icons, list rendering
- Slow fades, simple opacity transitions
- 1-2 Hz UI updates (gauges, status), which is 90% of automotive HMI
- HW video decode is a separate IP block and is gone anyway (VXD never had a working Linux driver)

**Workarounds that materially help:**
1. **`QT_QUICK_BACKEND=software`** — already enabled. Good call.
2. **`QSG_RENDER_LOOP=basic`** — already enabled. Avoids the threaded renderer overhead.
3. **`Item.layer.enabled: true`** sparingly to cache expensive items as textures (helps even on swrast — the cached bitmap re-blits cheaper than re-rasterizing).
4. **Avoid `clip: true`** anywhere you can — it forces an extra pass.
5. **`Image.asynchronous: true` + `sourceSize`** to pre-decode at target size, not full-res.
6. **Dirty-rect partial updates** via Qt's `QQuickWindow::setPersistentSceneGraph(false)` is not what you want — actually keep persistence on and make sure your scene mutates minimally.
7. **DRM atomic with separate planes per screen** — you already have two displays; put each on its own CRTC/plane so a redraw on one screen doesn't force a recomposite on the other. gma500 supports two CRTCs.
8. **Pin compositor + Qt thread to the CPU**, set scheduler to `SCHED_FIFO` for the renderer thread. Single-core Bonnell HATES context switches.
9. **Reduce target frame rate** to 30 FPS or even 20 FPS for ambient UI; spike to higher only on user interaction.

Realistic ceiling on swrast with all of the above: **20-30 FPS for typical HMI workloads, 60 FPS for static screens, 5-10 FPS during full-screen transitions.** Identical to what high-end factory infotainment from this era actually delivered.

---

## Section 6: Value assessment — concrete FPS estimates

What an SGX 535 driver would actually get you, if by some miracle one existed and worked:

- **Raw GPU spec:** 1 USSE pipe at 200 MHz → ~2.4 GFLOPS, **250 Mpixels/sec fillrate**, 7 Mtri/sec.
- **Our framebuffer load:** 800×480 + 800×420 = 720K pixels per frame. Even at 60 FPS that's 43 Mpix/s of pure overdraw budget — **the SGX could in theory composite our UI ~6× over at 60 FPS** if it could do nothing but blit.
- **Realistic with Qt6 + GLES2 driver:** UI scene graph is rebuilt and re-uploaded each frame. The bottleneck shifts from CPU rasterization to **bus + state-setup overhead**, and on a 200 MHz GPU sharing DDR2-800 with a 1 GHz CPU, you'd realistically see **30-45 FPS** for our workload. Better than swrast, but **not transformatively better.**
- **Power/thermal:** SGX 535 was iPhone-3GS-class. It draws ~250 mW. Engaging it isn't free for our coastal sealed enclosure thermal budget, but it's negligible relative to the dual TFTs.

| Path | Best-case FPS | Effort | Probability of success | Result quality |
|---|---|---|---|---|
| A — Resurrect EMGD | 30-45 | 6-12 mo specialist / multi-year solo | ~5% | Stuck on X.org 1.10, no Wayland |
| B — gma500 + 2D | swrast +10-20% effective | 6+ mo, needs leaked specs | ~10% | Helps QtWidgets, not Qt Quick |
| C — Reverse engineer | 30-45 (eventually) | 5-10 person-years | <2% | Could be open, modern |
| D — Stay on swrast | 8-30 (current) | done | 100% | Functional now |

**The ceiling for SGX 535 hardware acceleration is "okay, slightly better than swrast." It is not "transformative."** This is not a Pi 4 vs. Pi Zero gap — it's an old slow GPU competing with software rasterization on the same memory bus.

---

## Section 7: Recommendation

**No. Do not pursue a PowerVR SGX 535 driver. Not in any form.**

Rationale, in priority order:

1. **The prize is small.** SGX 535 is a 2007 mobile-class GPU at 200 MHz sharing DDR2 with the CPU. Even with a perfect driver you'd see ~3-4× over swrast — not 10×, not 50×. For a 1-2 Hz HMI workload, the user-perceptible difference is marginal.
2. **The cost is enormous.** Path A is a 6-12 month kernel-graphics specialist project with single-digit success probability. Path C is a career. Path B doesn't even solve the right problem for Qt Quick.
3. **Every path is legally tainted or technically dead.** The 2010 SGX leak is the only public source of architectural detail. Touching it kills any chance of upstreaming or commercial use. Imagination has publicly declined to open SGX. Intel orphaned EMGD 13 years ago.
4. **Software rasterization is shipping.** It works. Performance is in the same envelope as the factory DCU, which itself almost certainly used a barely-accelerated EMGD stack — there's no evidence the factory was meaningfully faster.
5. **The real lever is software-side optimization.** Every workaround in Section 5 is bounded, measurable, and worth a weekend each. The cumulative win from those (layer caching, dual-plane DRM, scheduler tuning, dirty-rect discipline) probably reaches 80% of what hardware accel would buy you, at 1% of the effort.

**If you're going to spend effort on graphics, spend it on:**
- Per-CRTC plane assignment via DRM atomic so the two screens don't share recompositing cost
- `SCHED_FIFO` for the Qt render thread + CPU isolation
- Aggressive `Item.layer.enabled` audit + asset pre-sizing
- Profile with `QSG_RENDERER_DEBUG=render` to find the actual hot rectangles

**Reconsider only if:** someone independently funds an SGX RE project to first GLES2 (won't happen — Imagination, Intel, and the FOSS GPU community have all moved on), or you decide to replace the DCU hardware entirely. If you ever go down that road, an i.MX 8M Mini with Vivante GC7000 + open `etnaviv` driver is the pragmatic landing zone — but that's a different project, not a driver project.

**TL;DR: ship swrast, optimize Qt, move on. The driver rabbit hole is a graveyard.**
