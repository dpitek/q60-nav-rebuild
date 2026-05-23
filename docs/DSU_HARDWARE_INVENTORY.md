# Q60 DSU / DCU Hardware Inventory

**Subject:** Clarion QY5092 Display Control Unit (DCU) — used in 2014–2020 Infiniti V37 platform (Q50, Q60), Q70, QX30/50/60/80
**Compiled:** 2026-05-23
**Sources:** 7 parallel research agents (Clarion physical, Atom E6xx + EKI BIOS, LAPIS ML7213, GMA600/EMGD, reference designs, modding community, OEM docs). Source reports live at `/tmp/dsu-research/01-07-*.md`; full OEM docs at `docs/DSU_OEM_DOCUMENTATION.md`.

---

## 1. Executive summary — the 10 facts that matter

1. **Supplier triangle:** Clarion **builds** the DCU (Saitama plant), **Denso-Ten** handles exchange logistics (`f10ncs.com` portal), **DENSO** holds the V2G overlay patent (US 8,660,782 B2). Don't confuse them with the Q30/QX30 DNNS075 which is a different DENSO unit on the Mercedes MFA platform.
2. **Single FCC ID covers a wide family:** `AX2QY5092` (Clarion, filed 2015-02-13) lists QY-5090/91/92/5111/5116/5123 + PH-3700/3701/3770/3771/3773/3778/3831 as the same RF/mechanical hardware. Firmware-differentiated for regions/MYs.
3. **SoC:** Intel Atom E6xx **Tunnel Creek** (Bonnell core, **family 6 model 0x26**, "Lincroft") — likely E640T or E660T (1.0/1.3 GHz industrial-temp parts). **NO MOVBE, NO SSE4, NO AVX, NO POPCNT, NO AES-NI.** Confirmed against Intel doc 324208/324209 (Spec Update July 2014 Rev 017).
4. **Companion chip:** LAPIS Semiconductor **ML7213 IOH** (PCI vendor `0x10db`). Lineage: Intel EG20T "Topcliff" → OKI Semiconductor (2008 acquisition) → LAPIS Semiconductor (2011 rename) → now ROHM. ML7213 is the in-vehicle infotainment variant of the EG20T family.
5. **Firmware:** **Not** an Insyde product (despite my earlier guess). "EKI v2.30" is a **Clarion internal SKU label** for an Insyde customisation layered on top of **Intel BLDK Core 2.3.6.7 (10/11/2011)** — the Crown Bay reference codebase. Tunnel Creek is **32-bit-only EFI** so the fallback path IS `/EFI/BOOT/BOOTIA32.EFI`.
6. **No Secure Boot enforcement on production units.** Researchers confirmed: `systemd` unit files added on production filesystem → working USB-TTY root shell. The DCUFix repair ecosystem swaps community-flashed microSD cards without signature issues.
7. **Mainline Linux ceiling for this hardware family is kernel 3.4** (Yocto Daisy 1.6.1, April 2014). **No public boot of mainline ≥3.10 on Atom E6xx hardware exists in the open record.** Our 4.19 attempt is genuinely virgin territory.
8. **The Q60 LAPIS SDHCI device IDs `10db:801e/801f/8020` are unique to this platform.** They have never appeared in any mainline driver match table. Our `sdhci-pci-core.c` patch is likely the only public Linux work that has ever bound them.
9. **VBT (Video BIOS Table) is the most likely silent killer for `gma500` on Tunnel Creek.** DENSO/Wind River almost certainly customised the GCT/VBT for the specific 800×480 + 800×420 panels. Without matching VBT, mainline `gma500` bails with *"Found no modes on the lvds, ignoring the LVDS"* — silently. **Fix: `video=LVDS-1:800x480@60` cmdline override.**
10. **Lower 800×420 panel is NOT a second LVDS** off Tunnel Creek (the SoC only has 2 pipes — LVDS + SDVO; LVDS drives the upper). Lower is SDVO-bridged via an external chip (Chrontel CH7036 likely) or MCU-mediated. **Defer to Phase 2.**

---

## 2. Supplier / sourcing

| Role | Entity | Notes |
|---|---|---|
| OEM brand | **Infiniti** (Nissan Motor Co.) | V37 chassis: Q50 (2014+), Q60 (2017+) |
| DCU manufacturer | **Clarion Co., Ltd.** (Saitama plant, 7-2 Shintoshin, Chuo-ku, Saitama 330-0081) | Pre-2019: Hitachi subsidiary. 2019: acquired by Faurecia (Forvia today). |
| Exchange logistics | **Denso-Ten** (formerly Fujitsu Ten) | Dealer-side parts portal: `f10ncs.com`. Tech line 1-800-237-5413. Exchange SKUs 28387-XXXXX (distinct from Nissan 25915 catalog). |
| Software platform | Wind River Linux 2.6.37.6-35.1 (`DLK0040`) | DLK0040 = Wind River internal customer program code. Source: GPL compliance request to `opensource@windriver.com`. |
| Graphics middleware | Intel EMGD 1.5.15.3226 | EOL 2014. Built from Intel-released 1.18 GOLD package. Same `1.5.15.3226` EGL build string in EMGD-Community sources. |
| Overlay IP | DENSO V2G | Patent **US 8,660,782 B2**, filed Dec 2010. Maps to `/dev/v2gbridge` ioctls `0xc0047600-02` that we reverse-engineered. |

### Service part numbers (Nissan catalog)

| P/N | Coverage |
|---|---|
| `25915-4HB5A` / `4HB5D` | 2018–2020 Q60 |
| `25915-4HB3A` / `4HB4F` / `4HB5B` / `4HB5C` | 2014–2019 Q50/Q60 family cross-compatible |
| `25915-4GN4B` | 2017 Q60 early MY |
| `25915-9GE1A` | "IT Master" later variant |
| `25915-5NA0A` / `25915-5NL0A` | 2019–2022 follow-on |

### Pricing

- $200–500 used (eBay, current + sold)
- **$635.45 dealer advance-exchange** (TSB ITB19-002b Figure 4)
- $50–100 for community DIY microSD repair kits (DCUFix etc.)

---

## 3. SoC — Intel Atom E6xx Tunnel Creek

### Silicon

- **Codename:** Tunnel Creek (SoC) / Lincroft (CPU core)
- **CPU family.model:** 6.0x26 → Linux `INTEL_FAM6_ATOM_BONNELL_MID`
- **Stepping:** B1 or C0 shipped. CPUID 0x20660 (B1), 0x20661/0x20665 (C0)
- **Microarchitecture:** Bonnell — in-order dual-issue, no speculative exec, no register renaming. Pre-Spectre/Meltdown by design.
- **TDP:** 2.7–3.6 W. **Likely SKU on Q60:** E640T or E660T (industrial temp range).
- **Microcode:** 06-26-01. **No updates ever issued** for Spectre/Meltdown — irrelevant since Bonnell lacks the targeted speculative features.

### CPU features

| Present | Absent |
|---|---|
| x87, MMX, SSE, SSE2, SSE3, SSSE3 | **MOVBE** |
| SMM, NX, VT-x, EM64T (capable but firmware is 32-bit) | SSE4.1, SSE4.2 |
| Hyper-Threading (1 core / 2 threads on all SKUs) | AVX, AVX2, AVX-512 |
| EIST, C-states up to C6 (with Lincroft auto-demote quirk) | AES-NI, POPCNT |

**Compiler implication (already in `project_atom_e6xx_cpu_compat.md` memory):** gcc's `-march=atom` enables MOVBE because it lumps "atom" with later Saltwell. **Use `-march=i686 -mtune=atom -mno-movbe`** (or `-march=core2 -mno-movbe`).

### Tunnel Creek IGD (integrated graphics)

- **PCI ID:** `8086:4108`
- **Marketed as:** GMA 600
- **Underlying engine:** PowerVR SGX 535 (Imagination Technologies)
- **Display engine:** 2 pipes (Pipe A → LVDS port, Pipe B → SDVO port). LVDS max 80 MHz pixel clock; SDVO max 160 MHz.
- **No native HDMI** on Tunnel Creek (Oaktrail Z670 has it; the `oaktrail_hdmi.c` mainline driver does NOT apply to E6xx).
- **OpenGL ES 2.0**, video decode capabilities present in EMGD but NOT exposed by mainline `gma500`.

### Crown Bay reference

- Intel's eval board for E6xx. Documented as Intel docs 324213 (Crown Bay dev kit manual).
- The "2.3.6.7 (10/11/2011)" string in our boot log = **Intel BLDK Core 2.3.6.7** = Crown Bay reference firmware codebase.
- **No coreboot port exists.** U-Boot port exists but requires Intel FSP binary blob + CMC microcode blob.

### Errata of note (Intel doc 324209)

- Voltage supplied to internal RTC violates design spec — BIOS workaround documented
- Display flicker on integrated display engine — BIOS + EMGD workaround
- MWAIT/C-state issues → motivated Linux's `ATM_LNC_C6_AUTO_DEMOTE` flag in `intel_idle`

---

## 4. IOH — LAPIS ML7213 (Topcliff family)

### Lineage

- **2008:** ROHM acquired OKI Semiconductor (1 Oct 2008)
- **2010:** ROHM+OKI announce ML72xx family (15 Sep 2010) — "completely compatible for Intel EG20T PCH"
- **2011:** OKI Semiconductor → **LAPIS Semiconductor** (1 Oct 2011, rename only)
- **ML7213** = IVI (in-vehicle infotainment) variant. ML7223 = media phone. ML7831 = general purpose. Same silicon family.
- **PCI vendor:** `0x10db` (ROHM/OKI/LAPIS — same throughout)

### PCI device inventory (from Q60 factory boot logs)

| BDF | Vendor:Device | Function | Mainline 4.19 driver | Status |
|---|---|---|---|---|
| 00:00.0 | 8086:4114 | Tunnel Creek host bridge | (no driver needed) | ✓ |
| 00:02.0 | 8086:4108 | GMA 600 graphics | `gma500` (`drivers/gpu/drm/gma500/`) | claims ID; LVDS unverified |
| 00:17.0 | 8086:8184 | PCIe bridge → bus 01-02 | generic PCI | ✓ |
| 01:00.0 | 10db:8019 | LAPIS PLX PCIe bridge | generic PCI | ✓ |
| 02:00.0/1/2 | 10db:801a/8032/8033 | Timberdale GPIO | `gpio-pch` / `gpio-ml-ioh` | ✓ upstream |
| 02:02.0/1/2 | 10db:801b/c/d | USB OHCI/EHCI/OHCI | `ohci-pci` / `ehci-pci` | ✓ generic |
| **02:04.0** | **10db:801e** | **LAPIS SDHCI #0 (SD card)** | **NONE — must patch** | ❌ requires patch |
| **02:04.1** | **10db:801f** | **LAPIS SDHCI #1** | **NONE — must patch** | ❌ requires patch |
| **02:04.2** | **10db:8020** | **LAPIS SDHCI #2 (eMMC)** | **NONE — must patch** | ❌ requires patch |
| 02:06.0 | 10db:8021 | SATA (IDE/AHCI) | generic SATA | ✓ |
| 02:08.0-3 | 10db:8022-25 | USB OHCI/EHCI | generic | ✓ |
| 02:0a.1/2/3 | 10db:8027/8028/8029 | PCH UART → ttyPCH0/1/2 | `drivers/tty/serial/pch_uart.c` | ✓ upstream |
| 02:0a.4 | 10db:802a | LAPIS V4L2 camera capture | `ioh_videoin` | ❌ never upstreamed (Phase 3+) |
| 02:0c.* | 10db:802b-31 | Timberdale + 2 video capture | mixed | partial |

### Tomoya MORINAGA — the LAPIS Linux contact

- OKI/LAPIS staff engineer, `tomoya-linux@dsn.okisemi.com`
- Authored essentially all mainline EG20T/ML72xx drivers between 2010–2013
- **Activity stops ~2013.** SourceForge ml7213 project last updated **2013-12-17**: https://sourceforge.net/projects/ml7213/ (canonical vendor patch source, ~535 KB tarball)
- The SourceForge tarball contains the SDHCI patches that were **never upstreamed** — these are the basis of our `sdhci-pci-core.c` patch for `10db:801e/801f/8020`.

### Per-subsystem mainline 4.19 verdict

| Subsystem | Driver path | Status |
|---|---|---|
| PHUB (clocks/pinmux parent) | `drivers/misc/pch_phub.c` | ✓ upstream |
| DMA | `drivers/dma/pch_dma.c` | ✓ upstream |
| UART | `drivers/tty/serial/pch_uart.c` | ✓ upstream |
| I2C | `drivers/i2c/busses/i2c-eg20t.c` | ✓ upstream |
| SPI | `drivers/spi/spi-topcliff-pch.c` | ✓ upstream |
| GPIO | `drivers/gpio/gpio-pch.c` + `gpio-ml-ioh.c` | ✓ upstream |
| CAN | `drivers/net/can/pch_can.c` | ✓ upstream (Phase 4 use) |
| GigE | `drivers/net/ethernet/oki-semi/pch_gbe/` | ✓ upstream (no GbE on Q60) |
| **SDHCI** | `drivers/mmc/host/sdhci-pci-core.c` | ❌ **device IDs missing — Q60-specific patch required** |
| V4L2 camera | `ioh_videoin` | ❌ never upstreamed; SourceForge only |

### Known kernel issues catalogued

- **UART clock divisor (48K↔64K)** — Darren Hart, LKML 2011. Affects baud accuracy on some derivatives.
- **8250_pci collision** — resolved by Morinaga's `-ENODEV` patches that prevent generic 8250_pci from binding to LAPIS UARTs.
- **`X86_INTEL_MID` hangs on Tunnel Creek** — Tunnel Creek uses ACPI, not SFI/MID. Linux 4.19 MID code (Penwell-default fallback) hangs at model 0x26. Our memory `project_x86_intel_mid_incompat.md` already documents.
- **SDHCI class mismatch** — LAPIS reports non-standard PCI class `0x000805` (base byte = 0x00, not 0x08). Mainline `sdhci-pci-core.c` catch-all expects `0x0805xx`. Mismatch means even the generic class catch-all doesn't bind. Must add explicit device IDs.

---

## 5. Display subsystem

### Hardware

- **Upper panel:** 800×480 LVDS — primary nav screen
- **Lower panel:** 800×420 LVDS-like — control hub / climate
- **LVDS PHY:** TI DS90UR9xx serializer family (community-attributed; exact part not photo-verified)
- Both fed through TI DS90URxxx serializers per InTouch RE community

### EMGD (factory driver)

- **Version:** 1.5.15.3226 (confirmed via Q60 kernel logs)
- **Origin:** Intel EMGD 1.18 GOLD package — same `1.5.15.3226` EGL build string in EMGD-Community sources
- **Last supported kernel:** Linux 4.0 (verified working on 3.11/3.13/3.15/3.19)
- **EOL:** 2014. No migration path to 4.19. Intel never open-sourced the PowerVR portions (`pvrsrvkm`, firmware).
- **Source availability:** EMGD-Community github mirrors of the 1.18 GOLD release exist; PowerVR kernel module + firmware remain closed.

### Mainline `gma500` (drivers/gpu/drm/gma500/)

- **Claims `8086:4108`:** YES — bound to `oaktrail_chip_ops` in `psb_drv.c`. Mainline-continuous from kernel 3.17 → 7.x.
- **Sole documented Tunnel Creek success story:** Jan Safrata's 2014 dri-devel patch adding `oaktrail_lvds_i2c.c` (LPC GPIO bit-bang at GPIOSUS[3]/[4]), tested on **SECO QuadMo747-E6xx-EXTREME** dev board. **That's the only public report.**
- **KMS framebuffer only.** No HW 3D accel. No HW video decode (MSVDX). No page-flip-with-vblank-sync.
- **No overlay planes exposed** (Sprite B/C unimplemented per patjak/drm-gma500 wiki). Means: no path to V2G-style camera overlay through mainline gma500.

### VBT (Video BIOS Table) — the biggest hidden risk

- Mainline `oaktrail_lvds_get_configuration_mode()` has three fallback stages, all bail to *"Found no modes on the lvds, ignoring the LVDS"* if VBT signature doesn't match.
- DENSO/Wind River almost certainly customised the GCT/VBT for the specific 800×480 + 800×420 panels.
- **Bypass:** `video=LVDS-1:800x480@60` cmdline override (we had this in v15/v16; dropped in v17 since gma500 dropped).

### DENSO V2G overlay

- **`/dev/v2gbridge` ioctls** `0xc0047600` (V2G_ENABLE) / `0xc0047601` (V2G_DISABLE) / `0xc0047602` (V2G_DISPLAY_FRAME)
- **DENSO patent US 8,660,782 B2** (filed Dec 2010) — directly maps to this design. Validates V2G as DENSO IP.
- **Zero public reverse-engineering** outside our own R1 work (no GitHub, no LKML, no Hackaday, no other DENSO patents matching).
- **Implication for Phase 3+ camera overlay:** must be rebuilt on V4L2 + DRM atomic from scratch.

---

## 6. Firmware — Insyde on Intel BLDK Core 2.3.6.7

- **NOT** an Insyde product line (Insyde catalog = InsydeH2O, Supervyse OPF, BlinkBoot — none match)
- **"EKI v2.30"** = Clarion internal SKU label for Insyde's customisation of **Intel BLDK Core 2.3.6.7 (10/11/2011)** — the Crown Bay reference codebase
- **32-bit-only EFI** (Tunnel Creek is i386). Fallback path: `/EFI/BOOT/BOOTIA32.EFI` ✓ (our deploy scripts correct)
- **EFI Handover Protocol** supported via `XLF_EFI_HANDOVER_32` (bit 2 of xloadflags at offset 0x236), `handover_offset` at 0x264. Yocto meta-crownbay and Timesys guides confirm working. **Linux 4.19 enables this when `CONFIG_EFI_STUB=y` (no separate Kconfig in 4.19 — baked in).**
- **Known quirks** documented elsewhere:
  - MWAIT/`intel_idle` hangs (Lincroft errata — fix: `intel_idle=disable` + `idle=halt`)
  - `earlyprintk=efi` hangs (broken EFI services)
  - NVRAM/PXE boot-order surprises
  - FSP rev 001 endless-loop bug at `FspInit`

---

## 7. Software stack (factory)

- **Kernel:** Linux 2.6.37.6-35.1 (`DLK0040-android-intel-crossville_lapis-fastboot`)
- **Init:** `/sbin/init android` — Android init.rc style, NOT systemd or SysV
- **Wind River Linux:** `DLK0040` is an internal Wind River customer program code (no public catalog entry)
- **Source availability:** GPL compliance request to `opensource@windriver.com` is the only legitimate path to the kernel source
- **75-second Android init delay** before factory daemons start (per Q60 boot probe) — sourced to a `usleep 75000000` in an init.rc file (path unconfirmed)
- **Key factory daemons:** `emgdhmid` (EMGD HMI), `camera_ps` (V2G bridge manager — NOT emgdhmid), `display_ps`, `navi_ps`, `hmictrl_proc`

---

## 8. Boot security model

- **NO Secure Boot enforcement** — confirmed via community evidence (DCUFix microSD swaps boot fine, USB-TTY root shell achievable via systemd unit file added on production filesystem)
- **No code signing observed** at boot
- **OEM update mechanism:**
  - Dealer-side: CONSULT-III plus reflash via Denso-Ten exchange
  - User-side: USB stick (`InTouch Software Update Procedure v2.0`, hosted at infiniti-techinfo.com/asistgc_1/diskdocs/1/U/H/1UH7.PDF) or microSD swap
  - No OTA on this generation
- **Watchdog:** `ie6xx_wdt` hardware watchdog. 2-strike boot counter in production `start.sh` flips `elilo.conf default=` back to factory on 2 consecutive user-side boot failures.
- **Map updates:** last v13 (2021.5)
- **Last infotainment TSB:** ITB22-013 (deadline 2022-03-31). Infiniti has abandoned the platform.

---

## 9. Storage

- **eMMC** (internal, soldered): 9 partitions
  - p1 (FAT32 boot)
  - p2 = Slot A (factory rootfs — NEVER write)
  - p3 = Slot B (writable)
  - p4 unused
  - p5/6 (Android-related)
  - p7 (pmemdisk — 50 MB persistent ramdisk)
  - p8 (data)
  - p9 (data)
- **microSD card slot** (test path): same layout used as portable "Slot B"
- Both controllers exposed via LAPIS SDHCI (`10db:801e/801f/8020`)

---

## 10. Connectivity

| Bus | Speed | Vendor | Role |
|---|---|---|---|
| AV-CAN | 500 kbit/s | LAPIS PCH CAN | DCU ↔ NAVI ctrl ↔ AV ctrl ↔ AC amp ↔ TCU. Separate from chassis CAN. |
| Chassis CAN | (vehicle) | (gateway via BCM) | BCM in passenger kick panel |
| LVDS | TI DS90URxxx | (2 ports — upper + lower panel) | upper LVDS native; lower is SDVO-bridged externally |
| USB (host) | OHCI/EHCI | LAPIS ML7213 | front-panel USB ports |
| Audio | HDA | Intel Tunnel Creek | PCI 8086:8182 |
| WiFi/BT | (FCC confidential) | unknown | block diagram FOIA-required |

---

## 11. Mainline Linux support matrix

| Component | mainline 4.19 | Notes |
|---|---|---|
| Atom E6xx CPU (Bonnell, model 0x26) | ✓ | use `CONFIG_M686=y`, **NOT** `MATOM` |
| `intel_idle` Lincroft C-states | ✓ (with auto-demote) | safer: `intel_idle=disable` + `idle=halt` |
| Tunnel Creek IGD / GMA 600 (8086:4108) | ✓ claims ID | LVDS modeset on Q60 specific panels **UNVERIFIED**; need VBT bypass via `video=LVDS-1:800x480@60` |
| ACPI | ✓ | Tunnel Creek is ACPI-based (not SFI) |
| LAPIS PCH UART | ✓ | `pch_uart` driver |
| LAPIS PCH GPIO | ✓ | `gpio-pch` / `gpio-ml-ioh` |
| LAPIS PCH I2C | ✓ | `i2c-eg20t` |
| LAPIS PCH SPI | ✓ | `spi-topcliff-pch` |
| LAPIS PCH DMA | ✓ | `pch_dma` |
| LAPIS PCH PHUB | ✓ | `pch_phub` (parent clocks/pinmux) |
| LAPIS PCH CAN | ✓ | Phase 4 |
| LAPIS USB OHCI/EHCI | ✓ | generic `ohci-pci`, `ehci-pci` |
| Intel HDA audio | ✓ | `snd-hda-intel` |
| EFI stub direct boot | ✓ | `CONFIG_EFI_STUB=y`; PE/COFF loadable |
| EFI Handover Protocol (xloadflags 0x236) | ✓ | baked into 4.19 with EFI_STUB |
| ramoops / pstore | ✓ | volatile DRAM on Q60 — power-cycle loses it |
| ext4, VFAT, NLS | ✓ | standard |
| **LAPIS ML7213 SDHCI (10db:801e/f, 8020)** | **❌** | **never upstreamed — Q60 patch required** |
| `ioh_videoin` (V4L2 rearview camera) | ❌ | vendor patches only (SourceForge) |
| DENSO V2G overlay | ❌ | proprietary, no source |
| EMGD 1.5.15 graphics | ❌ | EOL 2014, kernel ≤ 4.0 only |

**Reference ceiling:** Linux 3.4 + EMGD 1.18 from **Yocto Daisy 1.6.1** (April 2014) is the highest publicly-attested known-good config on this exact silicon family. Anything ≥3.10 is greenfield.

---

## 12. Service / repair ecosystem

- **DCUFix** (dcufix.com/guides) — pre-flashed microSD repair kits, $50–100. Fixes bootloop / blank-screen failure mode by swapping the OS-image microSD.
- **Go-Parts** — repair guides 2007–2024
- **Denso-Ten advance exchange** — $635.45 per TSB ITB19-002b Figure 4
- **TSBs (publicly hosted at NHTSA):**
  - ITB13-026i — 2014–2017 DCU replacement
  - ITB19-002b — 2018–2020 DCU service info
  - ITB22-013 — last infotainment update push (deadline 2022-03-31)
- **No federal recall** specific to 2017 Q60 DCU. Backup-camera recalls (R21A9, 19V654) hit 2018–2021 MYs only.

---

## 13. OEM documentation references

(Full inventory in `docs/DSU_OEM_DOCUMENTATION.md`.)

| Doc | Source | Access |
|---|---|---|
| Intel Atom E6xx Datasheet (doc 324208) | Arrow/Mouser/Versalogic mirrors | Free |
| Intel Atom E6xx Spec Update (doc 324209, July 2014 Rev 017) | Arrow mirror | Free |
| Intel EG20T Datasheet (doc 324211) | Versalogic mirror | Free |
| Intel Crown Bay Dev Kit Manual (doc 324213) | Intel Embedded Design Center | Free |
| ROHM ML7213/7223 datasheet | rohm.com/documents/11405/851226/ml7213_7223-e.pdf | Free (marketing-grade; register manual NDA-only) |
| ML7213 SourceForge vendor patches | sourceforge.net/projects/ml7213/ | Free, last 2013-12-17 |
| Infiniti TSB ITB19-002b | static.nhtsa.gov/odi/tsbs/2020/MC-10171213-0001.pdf | Free |
| Infiniti TSB ITB22-013 | infiniti-techinfo.com | Free |
| InTouch Software Update Procedure v2.0 | infiniti-techinfo.com/asistgc_1/diskdocs/1/U/H/1UH7.PDF | Free |
| Infiniti FSM Section AV (wiring diagrams) | infiniti-techinfo.com | **$20/day paywall** — cheapest paywalled path to authoritative wiring |
| DENSO V2G patent US 8,660,782 B2 | Google Patents | Free |
| FCC AX2QY5092 filing | fccid.io/AX2QY5092, fcc.report/FCC-ID/AX2QY5092 | Free (label/external photos; internal photos auto-released Oct 2015; schematics permanently confidential, needs FCC FOIA) |
| Wind River BSP source (DLK0040) | opensource@windriver.com (GPL compliance request) | Free (request required) |
| Imagination PowerVR SGX 535 docs | (NDA via Imagination) | Closed |

---

## 14. Open questions / known unknowns

1. **WiFi/BT silicon vendor** — FCC long-term-confidential block-diagram exhibit. Would require FOIA.
2. **Exact LVDS serializer part** — community-attributed as DS90UR906/924/UH925 but not photo-verified.
3. **AV-CAN DBC** — no public DBC file. Racelogic Q50 PDF covers chassis CAN, not AV-CAN.
4. **Lower panel interface** — SDVO-bridged via Chrontel CH7036 candidate, but unconfirmed. Could also be MCU-mediated with parallel RGB.
5. **75-second Android init delay** — confirmed in factory boot but exact init.rc path uncertain (`/init.rc` vs `/system/init.rc` vs `/etc/init/*.rc`).
6. **DCU boot-order behavior** — whether UEFI on this DCU actually loads `/EFI/BOOT/BOOTIA32.EFI` from microSD (Test A on 2026-05-23 suggests it does NOT — same "two black screens" with or without SD card). DCUFix community has working microSD-based fixes, so SOME microSD boot path exists but its specifics are unclear.
7. **VBT format** — DENSO/Wind River customisation almost certain but exact GCT/VBT layout unknown without firmware dump.

---

## 15. Implications for the Q60 nav rebuild project

1. **We are first to attempt mainline ≥3.10 on Atom E6xx.** No reference patches to copy. Closest known-good config is Yocto Daisy 1.6.1 (Linux 3.4 + EMGD 1.18).
2. **The LAPIS SDHCI patch is project-critical.** No mainline alternative.
3. **`gma500` LVDS modeset is the single biggest open hardware-driver question** — needs VBT bypass + on-hardware test to confirm.
4. **The DCU may not load our `BOOTIA32.EFI` from microSD** (per Test A). The microSD boot path the community uses (DCUFix) must differ from the standard UEFI fallback. **Investigating the DCUFix card layout is the next priority.**
5. **No serial cable access** means our diagnostic vector must be persistent-storage-based (ramoops doesn't survive ignition cycles on this hardware).
6. **The InfinitiQ50.org "InTouch Reverse Engineering" thread** mentions a USB-TTY root patch on a sibling DCU. If still working on the Q60 firmware, would give us shell access without any kernel work.
7. **Faurecia/Forvia owns Clarion now** and Infiniti TSBs route through Denso-Ten — no upstream support escalation path remains.

---

*Source reports: `/tmp/dsu-research/01-clarion-qy5092-physical.md`, `02-atom-e6xx-bios.md`, `03-lapis-ml7213.md`, `04-display-emgd-gma600.md`, `05-reference-designs.md`, `06-community-modding.md`, `07-oem-documentation.md`. Detailed OEM doc inventory: `docs/DSU_OEM_DOCUMENTATION.md`.*
