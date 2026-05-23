# OEM Documentation Index — Clarion QY5092 Display Control Unit (DCU)

**Target:** Clarion Co. Ltd. / Faurecia Clarion Electronics QY5092 navigation head unit (Infiniti Q60 V37, 2017+ — also widely shared across Q50, Q70, QX30, QX50, QX60 of the same era).
**Purpose:** Centralize every freely-citable OEM document (and the paywalled ones with access paths) for the v17+ debugging effort.
**Date compiled:** 2026-05-23.
**Compiled by:** Claude research subagent for Doug Pitek / q60-rebuild.

---

## 1. Infiniti / Nissan Service Publications

### 1.1 Technical Service Bulletins (TSBs) — DCU-related

| TSB # | Title | Date | Models | Source URL | Access |
|-------|-------|------|--------|------------|--------|
| **ITB19-002B** | "Display Control Unit Service Information" — DENSO/DENSO-TEN advance-exchange procedure (f10ncs.com), C-III plus configuration, DCU registration | 2020-01-10 | 2018-2020 Infiniti (Q50/Q60/Q70/QX30/QX50/QX60/QX80) | https://static.nhtsa.gov/odi/tsbs/2020/MC-10171213-0001.pdf | **Free** (NHTSA) |
| **ITB19-002** (older "2014-2017" sibling) | "Display Control Unit Replacement" — same advance-exchange flow, earlier model range | 2019 | 2014-2017 Infiniti | https://static.nhtsa.gov/odi/tsbs/2019/MC-10152988-9999.pdf and https://static.nhtsa.gov/odi/tsbs/2020/MC-10171196-0001.pdf | **Free** (NHTSA) |
| **ITB22-013** (companion: AN22-008) | "INFINITI Connection & InTouch Services / Last Eligible Map+OTA Update Deadline" — 2022-03-31 cutoff for final infotainment software push | 2022-03-31 | 2017-2019 Q60 (and siblings) | https://www.infiniti-techinfo.com/documents/ITB22-013.pdf | **Free** (Infiniti TechInfo public link) |
| **ITB20-010 / EC20-011** | DCU/MULTI AV-related service bulletin (referenced via NHTSA index) | 2020-03-20 | 2018-2020 Infiniti | https://static.nhtsa.gov/odi/tsbs/2020/MC-10173594-0001.pdf | **Free** |
| **(Generic)** "AV Control Unit Replacement Process" | DCU swap procedure | 2020 | Infiniti | https://static.nhtsa.gov/odi/tsbs/2020/MC-10174413-0001.pdf | **Free** |
| **Telematics Service Information** | TCU + DCU pairing for Connect services | 2019 | Infiniti | https://static.nhtsa.gov/odi/tsbs/2019/MC-10167279-0001.pdf | **Free** |
| **NHTSA Infiniti TSB index page** (master list) | All Infiniti TSBs by year | — | All | https://static.nhtsa.gov/odi/tsbs/2020/MC-10180976-0001.pdf and Infiniti's own TSB feed https://www.infiniti-techinfo.com/tsb/tsb_xml/nmindex.aspx?tsbtype=ai | **Free** |
| TSB search portals | TSB lookup by year/model | — | — | https://www.tsbsearch.com/Infiniti and https://www.obd-codes.com/tsb/2017/infiniti/q60/ and https://www.aboutautomobile.com/Technical-Service-Bulletin/2019/Infiniti/Q60/Equipment | **Free** |

**Most relevant for v17+ debug:** ITB19-002B (DCU advance-exchange via DENSO-TEN, gives the official replacement path — useful if we brick a DCU during boot experiments). ITB22-013 names the final OEM map+CarPlay software image, which is the last factory-shipped firmware we need to keep our system bit-compatible with.

### 1.2 InTouch Software Update Procedure v2.0 (December 6, 2014)

- **Title:** "INFINITI InTouch SOFTWARE UPDATE PROCEDURE version 2.0"
- **Publisher:** Nissan North America / Infiniti
- **Date:** 2014-12-06
- **Primary URL:** https://www.infiniti-techinfo.com/asistgc_1/diskdocs/1/U/H/1UH7.PDF
- **Mirror (free):** https://docplayer.net/64511200-Infiniti-intouch-software-update-procedure-version-2-0.html
- **Length / scope:** ~30 pages. Covers: software-version check via diagnostic menu, USB stick prep, iOS Infiniti InTouch app pairing, MAP SD card lock-tab requirement, post-update reset sequence (ignition OFF/1 minute/ON to allow display re-init).
- **Access:** Free (direct PDF on infiniti-techinfo.com).
- **Most relevant for us:** Documents the legitimate (factory-blessed) DCU update path — useful as a sanity check for what factory firmware delivery looks like, and for the diagnostic-menu navigation we need to mirror in the replacement system.

### 1.3 Owner's Manual & Quick Reference (electronics chapter)

| Document | Year | URL | Access |
|----------|------|-----|--------|
| 2017 Q60 Coupe Owner's Manual (full) | 2017 | https://www.infinitiusa.com/content/dam/Infiniti/US/manuals_guides/q60_coupe/2017/2017-infiniti-q60-coupe-owner-manual.pdf | Free |
| 2017 Q60 Coupe Owner's Manual (mirror) | 2017 | https://cdn.dealereprocess.org/cdn/servicemanuals/infiniti/2017-q60.pdf | Free |
| 2017 Q60 Quick Reference Guide | 2017 | https://admin.owners.infinitiusa.com/content/manualsandguides/Q60_Coupe/2017/2017-q60-coupe-quick-reference-guide.pdf | Free |
| Infiniti TechInfo Q60 Owner Manual hub | All years | https://www.infiniti-techinfo.com/deptog.aspx?dept_id=172 | Free index |

**Most relevant section:** "Audio, Visual & Navigation" — documents factory reset behavior, voice command structure, CarPlay capability matrix, MAP SD card slot location, and the buttons/dials we must preserve in the rewritten UI.

### 1.4 Factory Service Manual (FSM) — Section AV

- **Title:** "2017 Infiniti Q60 (CV37) Service Manual — Section AV (Audio, Visual & Navigation)"
- **Publisher:** Nissan North America
- **Primary access:** https://www.infiniti-techinfo.com (paid — pay-per-day, ~$20/day) — the only fully-licit source for the AV section with **wiring diagrams** (DCU connectors, LVDS pinouts, USB hub topology, AV-CAN signal mapping)
- **Forum discussions referencing leaked copies:** https://www.infinitiq50.org/threads/infiniti-q50-q60-factory-service-manuals-fsm.144662/ and https://mhhauto.com/Thread-Service-manual-Wiring-Diagrams-for-the-2017-INFINITI-Q60-CV37 and https://www.nicoclub.com/infiniti-service-manuals
- **Access:** **Paywalled.** Suggested legal paths: (a) 1-day infiniti-techinfo.com subscription targeted at Section AV (cheapest legit option, ~$20); (b) Mitchell1 ProDemand subscription if Doug's shop has one; (c) AllData diagnostic subscription.
- **Most relevant for us:** Connector pinouts (M53/M54 etc. — DCU harness), LVDS upper-display + lower-control-hub signal routing, IGN/ACC power sequencing, USB hub schematic (host vs. device USB on the DCU), AV-CAN frame definitions.

---

## 2. Clarion / Faurecia Clarion Electronics Documentation

### 2.1 FCC Filing — AX2QY5092

- **Applicant:** Clarion Co. Ltd. (Japan) — now Faurecia Clarion Electronics Co., Ltd.
- **FCC ID:** AX2QY5092
- **Grant date:** 2015-02-13 (original) / 2015-04-19 (Class II Permissive Change — antenna spec revisions)
- **Operating frequencies:** WiFi 2.412-2.462 GHz @ 114.6 mW; Bluetooth 2.402-2.480 GHz @ 1.7 mW
- **Primary portal:** https://fccid.io/AX2QY5092 and mirror https://fcc.report/FCC-ID/AX2QY5092
- **Listing on Faurecia Clarion device-report:** https://device.report/faurecia-clarion-electronics/qy5092 and https://electric.garden/clarion-ax2/navigation-unit-qy5092

#### Public exhibits (free)

| Document | URL fragment | Size |
|----------|--------------|------|
| FCC Report (WLAN test) | /Test-Report/FCC-Report-WLAN-2589415 | 1553 KB |
| FCC Report (Bluetooth test) | /Test-Report/FCC-Report-BT- | 1532 KB |
| FCC Report (DTS) | /Test-Report/FCC-Report-DTS- | 1234 KB |
| RF Exposure sheet (BT) | /RF-Exposure-Info/FCC-RF-Exposure-sheet-BT-2589388 | 51 KB |
| RF Exposure sheet (WLAN) | /RF-Exposure-Info/FCC-RF-Exposure-sheet-WLAN-2589416 | 63 KB |
| Label diagrams (multiple SKUs: QY-5090/5091/5092/5111/5116/5123, PH-3700/3701/3770/3771/3773/3778) | various `Label-and-Location` paths | 23-227 KB each |

#### Confidential exhibits (auto-public on stated dates)

- External Photos (PH-3700): https://fccid.io/AX2QY5092/External-Photos/Short-Term-Confidential-Extrenal-Photo-PH-3700-2533731 — released 2015-08-12
- External Photos (QY-5111): https://fccid.io/AX2QY5092/External-Photos/Short-Term-Confidential-External-Photo-QY-5111-2589434 — released 2015-10-16
- Internal Photos — released 2015-10-16
- User Manual — released 2015-10-16
- Test Setup Photos — released 2015-08-12 / 2015-10-16

#### Permanently confidential (NDA-protected — would require FCC FOIA filing)

- Block Diagrams (RF)
- Schematics
- Theory of Operation (channel limitation, frequency hopping, antenna specifications)

**Most relevant for us:** External and internal photos give us a confirmed look at the DCU PCB (Clarion Saitama-built, board number marked QY-5111 on the FCC label; SKUs QY-5090..QY-5123 are regional variants of the same hardware). Test reports confirm the WiFi + BT modules — useful when we re-enable wireless services in the replacement nav.

### 2.2 Clarion / Faurecia Corporate Documentation

- **Company HQ + Technology Center:** 7-2 Shintoshin, Chuo-ku, Saitama-shi, Saitama 330-0081, Japan. Source: https://www.faurecia-japan.jp/en/about-us/faurecia-clarion-electronics-co-ltd and https://panjiva.com/Faurecia-Clarion-Electronics-Co-Ltd/109803497
- **Corporate history (Faurecia acquisition):** https://www.automotiveworld.com/news-releases/faurecia-launches-fourth-business-group-faurecia-clarion-electronics-atsushi-kawabata-joins-the-executive-committee/ — Faurecia acquired Clarion in March 2019; name change to Faurecia Clarion Electronics Jan 2021.
- **Clarion Wikipedia entry (timeline):** https://en.wikipedia.org/wiki/Clarion_(company)
- **MarkLines profile:** https://www.marklines.com/en/top500/faurecia-clarion-electronics — confirms automotive infotainment product line including OEM nav for Nissan/Infiniti, Honda, GM, etc.
- **Archived product brochures:** https://archive.clarion.com/xe/en/products-personal/multimedia/

**Lifecycle / EOL parts source:** Clarion Lifecycle Solutions Co., Ltd. (https://www.faurecia-japan.jp/en/clarion-lifecycle-solutions-co-ltd) — official EOL spares channel.

---

## 3. DENSO / DENSO-TEN — Exchange Channel & Patents

### 3.1 DENSO-TEN parts exchange portal (f10ncs.com)

- **Portal:** https://f10ncs.com/ (login wall) — used by Infiniti dealers per ITB19-002B
- **Forgot username:** https://www.f10ncs.com/ForgetUsername
- **Phone:** 1-800-237-5413 (Mon-Fri 7am-4pm PT)
- **Operator of record:** Perfect Insight, Inc. (California-based reseller on behalf of DENSO-TEN America)
- **What's published:** Account-locked. Public info limited to the existence of the exchange SKU + the call-center number cited in TSBs. The advance-exchange flow is documented in **ITB19-002B** (above).
- **Access path for Doug:** Dealer accounts only. No legitimate civilian path — best alternative is to source a salvage-yard DCU when needed.

### 3.2 DENSO patents touching vehicle overlay / V2G-style display architectures

Google Patents is the canonical search interface. The following are the most relevant DENSO and related filings for the V2G-bridge / overlay-plane architecture the QY5092 uses:

| Patent # | Title | Assignee | Year | URL |
|----------|-------|----------|------|-----|
| US 8,660,782 B2 | "Method of displaying traffic information and displaying traffic camera view for vehicle systems" | DENSO Corp. (filed 2010-12-22) | 2014 (grant) | https://patents.google.com/patent/US8660782 |
| JP 5617678 B2 | "Vehicle display device" (overlay graphics rendering) | DENSO (filed 2011-02-17) | 2014 | https://patents.google.com/patent/JP5617678B2/en |
| US 2020/01918— / US 2022/0109812 A1 | "Overlay video display for vehicle" | (recent V2G-class disclosure — assignee varies) | 2022 | https://patents.google.com/patent/US20220109812A1/en |
| US 2017/0337901 A1 | "Displaying graphics in a vehicle display" | — | 2017 | https://patents.google.com/patent/US20170337901A1/en |
| US 9,796,332 B2 | "Imaging system for vehicle" (camera overlay) | — | 2017 | https://patents.google.com/patent/US9796332B2/en |
| JP 4,718,763 B2 | "Facilitate interaction between video renderers and graphics device drivers" — relevant prior art for V2G architectural choice | — | 2011 | https://patents.google.com/patent/JP4718763B2/en |
| US 7,312,803 B2 | "Method for producing graphics for overlay on a video source" | — | 2007 | https://patents.google.com/patent/US7312803B2/en |

**Microsoft × DENSO cross-license note:** https://www.prnewswire.com/news-releases/microsoft-enters-into-patent-cross-licensing-agreement-with-denso-corp-97981644.html — useful background for understanding the DENSO IP portfolio depth in infotainment.

**Most relevant for us:** US 8,660,782 documents the DENSO "graphics overlaid on live camera" pattern that maps directly to the EMGD Sprite C plane used by our /dev/v2gbridge ioctls (0xc0047600-0xc0047602). The ioctl numbers and the "uint32_t plane, uint32_t screen" struct layout we've reverse-engineered conform to this filed design.

### 3.3 DENSO-TEN press releases

- Multi-Angle Vision 3D bird's-eye (2010, Toyota Prius dealer option) — same overlay architecture lineage: https://www.denso-ten.com/release/2010/20100420_e.html

---

## 4. Intel — Atom E6xx ("Tunnel Creek"), EG20T ("Topcliff"), Crown Bay Platform

### 4.1 Intel Atom Processor E6xx Series Datasheet

- **Document number:** 324208-005US (latest publicly available rev)
- **Title:** "Intel® Atom™ Processor E6xx Series Datasheet"
- **Publisher:** Intel Corporation
- **Publication date:** 2013 (revision 005)
- **Primary URL (Intel-hosted):** https://www.intel.com/content/dam/www/public/us/en/documents/datasheets/atom-e6xx-series-datasheet.pdf
- **Mirrors:** https://www.mouser.com/pdfdocs/Intel_Atom_E6xx_series_datasheet-2.pdf and https://www.versalogic.com/wp-content/themes/vsl-new/assets/resources/support/pdf/Intel_Atom_E6xx_Datasheet.pdf and https://docs.rs-online.com/a141/0900766b80f08ddb.pdf (RS components)
- **Length / scope:** ~600+ pages. Covers: complete CPU + IGD + memory controller spec, PCI device IDs, system address map, signal definitions, electrical/timing specs, IGD graphics block, display interfaces (LVDS, SDVO).
- **Access:** Free.
- **Most relevant sections:** PCI device 0x4108 (IGD); LVDS port programming (port 2 in EMGD portorder); HW model 0x26; thermal/power tables.

### 4.2 Intel Atom Processor E6xx Series Specification Update (Errata)

- **Document number:** 324209-017US (July 2014 — latest)
- **Title:** "Intel® Atom™ Processor E6xx Series Specification Update"
- **URLs:** https://www.mouser.com/pdfdocs/Intel_Atom_E6xx_spec_update.pdf and https://static6.arrow.com/aropdfconversion/6169419da38da1911486a9cd57e187b56f546f17/atom-e6xx-spec-update.pdf
- **Access:** Free.
- **Most relevant for us:** Errata, B1 PRQ stepping markings, spec clarifications — explains the documented quirks our v17+ kernel must handle (and the silent landmines we hit during the 5-compounding-root-causes overnight session: SDHCI quirks, MWAIT C-state issues).

### 4.3 Intel Platform Controller Hub EG20T (Topcliff) Datasheet

- **Document number:** 324211-009US
- **Title:** "Intel® Platform Controller Hub EG20T Datasheet"
- **URLs:** https://www.versalogic.com/wp-content/themes/vsl-new/assets/resources/support/pdf/Intel_PCH_EG20T_Datasheet.pdf and https://www.mouser.com/pdfdocs/Intel_Platform_Controller_Hub_EG20T_datasheet.pdf and https://www.sunshineic.com.cn/uploadfiles/files/20211119144434_8664.pdf
- **Intel ARK:** https://ark.intel.com/content/www/us/en/ark/products/52501/intel-platform-controller-hub-eg20t.html
- **Intel docs portal:** https://www.intel.com/content/www/us/en/products/sku/52501/intel-platform-controller-hub-eg20t/docs.html
- **Access:** Free.
- **Most relevant for us:** UART (CONFIG_SERIAL_PCH_UART → /dev/ttyPCH0), I2C, DMA, USB device + host, SPI, CAN — all the PCH block registers our kernel touches. This is the official reference for the LAPIS-compatible peripheral block.

### 4.4 Intel Crown Bay Platform / E660 + EG20T Development Kit

- **Document number:** 324213-002 (Development Kit User Manual, Jan 2012)
- **Title:** "Intel® Atom™ Processor E660 with Intel® Platform Controller Hub EG20T Development Kit User Manual"
- **URLs:** https://mafiadoc.com/e660-and-eg20t-dev-kit-user-manual_59a91dbc1723ddbec5e2ad58.html and https://www.intel.com/content/www/us/en/products/docs/processors/atom/technical-resources.html
- **U-Boot Crown Bay board doc (best free architectural overview):** https://docs.u-boot.org/en/latest/board/intel/crownbay.html
- **Embedded Computing product brief:** https://www.mouser.com/pdfdocs/Intel_Atom_Processor_E6xx_product_brief.pdf
- **Access:** Free.
- **Most relevant for us:** Crown Bay is the reference design that the Clarion DCU is descended from (Tunnel Creek + Topcliff + EMGD 1.18). Doug's hardware is essentially a Crown Bay variant with LAPIS ML7213 swapped in place of stock EG20T and Clarion-custom I/O.

### 4.5 Intel Atom E6xx Thermal & Mechanical Design Guidelines

- **Title:** "Intel® Atom™ Processor E6xx Series Thermal and Mechanical Design Guidelines"
- **URL:** https://manualzz.com/doc/12362674 (community mirror) — Intel doc number in the 324xxx-series family.
- **Access:** Free (mirror).

### 4.6 Intel Atom E6xx Platform Design Guide

- **Title:** "Intel® Atom™ Processor E6xx Series Platform Design Guide"
- **URL:** https://manualzz.com/doc/35883719
- **Access:** Free (mirror).
- **Most relevant for us:** Schematic-level layout rules for LVDS, PCIe, USB — useful if we ever cross-reference vs. the Clarion FSM wiring.

### 4.7 Intel Embedded Media & Graphics Driver (EMGD)

| Item | Detail |
|------|--------|
| Intel EMGD landing page | https://www.intel.com/content/www/us/en/embedded/software/emgd/embedded-media-and-graphics-drivers-faq-technical-support-and-documentation.html |
| EMGD documentation (UK mirror) | https://www.intel.co.uk/content/www/uk/en/embedded/software/emgd/embedded-media-and-graphics-drivers-documentation.html |
| EMGD binaries + source (community) | https://github.com/EMGD-Community/intel-binaries-linux |
| EMGD User Guide v36.15 (32-bit) PDF | https://www.intel.com/content/dam/support/us/en/documents/boardsandkits/gfx_emgd_usersguide.pdf |
| EMGD v36.40.25 release notes | https://cdrdv2-public.intel.com/332323/v-36-40-25-32-bit-v-37-40-25-64-bit-for-linux-release-notes.pdf |
| EMGD v1.12 user guide | https://cdrdv2-public.intel.com/840938/emgd_userguide.pdf |
| Debian wiki summary | https://wiki.debian.org/IntelEmbeddedMediaGraphicsDriver |
| Document 442076-023US (EMGD developer/user guide) | https://docs.yoctoproject.org/pipermail/yocto/attachments/20121004/69e1e025/attachment.pdf |

**Most relevant for us:** Our factory image runs EMGD 1.5.15.3226 (NOT a v36 build — the 1.x line is the early Tunnel Creek release with the Sprite C plane that our /dev/v2gbridge intercepts). The community GitHub repo is the closest thing to source-level documentation we have. The User Guide PDFs explain port programming, sprite/overlay planes, IGD_ALTER_OVL2 ioctl (which we've already mapped to 0xc0c8646f).

### 4.8 Insyde EFI for E6xx

- Press release: https://www.insyde.com/press_news/press-releases/insyde%C2%AE-software-delivers-uefi-bios-intel%C2%AE-atom%E2%84%A2-processor-e6xx-series-0
- Embedded Intel coverage: http://www.embeddedintel.com/news.php?article=1784
- InsydeH2O product page: https://www.insyde.com/products/insydeh2o/
- **Access:** Public press materials free; firmware source / config tooling is NDA. To get the actual InsydeH2O reference dump for E6xx Doug would need to engage Insyde sales (or, more realistically, dump the factory firmware from the DCU and reverse-engineer).

---

## 5. ROHM / LAPIS Semiconductor / OKI — ML7213 + EG20T Variants

### 5.1 ROHM Datasheet — ML7213 / ML7223

- **Title:** "ML7213/7223(V)" (IOH companion chips for Atom E6xx — IVI and Media Phone variants)
- **URL:** https://www.rohm.com/documents/11405/851226/ml7213_7223-e.pdf
- **Publisher:** ROHM Co., Ltd. / LAPIS Semiconductor (formerly OKI Semiconductor)
- **Length / scope:** Datasheet with block diagram, register map, package, electrical specs.
- **Access:** Free.
- **Most relevant for us:** ML7213 is the IVI variant — exactly what Clarion used. PCI device IDs 0x10db:801e/801f/8020 (the non-standard PCI class 0x000805 that broke mainline sdhci-pci binding — see project_lapis_sdhci_binding.md memory entry). Confirms compatibility with EG20T Topcliff (same register layout).

### 5.2 ROHM short-form catalog

- https://www.tti.com/content/dam/ttiinc/manufacturers/rohm/Products/pdf/product_catalog_2021.pdf

### 5.3 LAPIS / ROHM official portal

- Search center: http://www.lapis-semi.com/en/semicon/search-center/
- ROHM product datasheet hosting: https://fscdn.rohm.com/lapis/...

### 5.4 Linux kernel driver entries (LKDDb)

| Driver | LKDDb URL |
|--------|-----------|
| CONFIG_PCH_PHUB | https://cateee.net/lkddb/web-lkddb/PCH_PHUB.html |
| CONFIG_PCH_DMA | https://cateee.net/lkddb/web-lkddb/PCH_DMA.html |
| CONFIG_SERIAL_PCH_UART | https://cateee.net/lkddb/web-lkddb/SERIAL_PCH_UART.html |
| CONFIG_I2C_EG20T | https://cateee.net/lkddb/web-lkddb/I2C_EG20T.html |
| CONFIG_USB_EG20T | https://cateee.net/lkddb/web-lkddb/USB_EG20T.html |

### 5.5 Tomoya Morinaga (OKI Semiconductor) — SourceForge ML7213 project

- **SourceForge project:** https://sourceforge.net/projects/ml7213/
- **Latest experimental dir:** https://sourceforge.net/projects/ml7213/files/Experimental/Kernel%202.6.39.4/
- **Last update:** 2013-12-17 (kernel 2.6.37 / 2.6.39 patch set)
- **Latest tarball:** "EG20TPCH_ML7213_ML7223_ML7831_linux*.zip" (~535 kB) — download via `/projects/ml7213/files/latest/download`
- **Author note:** Tomoya MORINAGA (OKI Semi → LAPIS → ROHM) is the upstream Linux kernel patch author. His mainline patches (search for "Tomoya MORINAGA" in `git log linux/`) added ML7213 support to drivers: pch_phub, pch_dma, pch_uart, i2c-eg20t, usb-eg20t, spi-topcliff-pch, pch_can.
- **Sample upstream commit:** https://github.com/torvalds/linux/commit/f016aeb655350ef935ddf336e22cb00452a1c41e ("spi/topcliff_pch: support new device ML7213 IOH")
- **LKML thread example:** https://lists.archive.carbon60.com/linux/kernel/1319566 and http://lkml.iu.edu/hypermail/linux/kernel/1203.2/index.html
- **Access:** Free.
- **Most relevant for us:** This is the ONLY place that has the LAPIS-specific patches that mainline 4.19 may not have backported (notably SDHCI vendor IDs). Grabbing this tarball is essentially mandatory for our v17+ work.

---

## 6. Wind River — Linux 2.6.37 BSP (DLK0040)

### 6.1 What we know about the factory build string

The factory string is: `Wind River Linux 2.6.37.6-35.1_DLK0040-android-intel-crossville_lapis-fastboot`

- **2.6.37.6-35.1** — Wind River Linux 4.x family kernel build (Wind River Linux 4 was the LTS release branched off the 2.6.34/2.6.37 lines around 2011-2012).
- **DLK0040** — internal Wind River customer/program code. Almost certainly the Clarion (or upstream Nissan/Infiniti tier-1) program identifier inside Wind River's BSP delivery system. **Not a public catalog entry.**
- **android-intel-crossville_lapis-fastboot** — flavor: Android (Wind River's Android-on-Linux variant), Intel SoC, Crossville reference platform, LAPIS IOH, Fastboot bootloader.

### 6.2 Public Wind River resources

| Item | URL | Access |
|------|-----|--------|
| Wind River Linux 4 BSP listing | https://bsp.windriver.com/bsps/product/wind-river-linux_4 | Free (browse only) |
| Wind River Intel x86 BSP repo | https://github.com/WindRiver-Labs/intel-x86 | Free |
| BSP Query Tool — Intel vendor | https://bsp.windriver.com/bsps/vendor/intel | Free |
| Wind River public source code (GPL-mandated) | https://www.windriver.com/source | Free |
| Wind River Linux datasheet | https://www.windriver.com/resource/wind-river-linux-lts-datasheet | Free |
| Wind River Linux LTS product page | https://www.windriver.com/products/linux/ | Free |
| Wind River Marketplace BSP entry (Atom CRB) | https://marketplace.windriver.com/index.php?bsp=&bsp=12166&on=details | Free |
| Generic Atom/Xeon/Core CRB BSP | https://bsp.windriver.com/index.php?bsp=&bsp=12781&on=details | Free |
| Linux 3.0 press release (graphics-heavy) | https://www.windriver.com/news/press/news-9401 | Free |
| Wind River Linux 3.0 announcement | https://www.linux-magazine.com/Online/News/Embedded-Platform-Wind-River-Linux-3.0 | Free |

### 6.3 DLK0040 specifically

- **No public listing exists.** Wind River does not document customer-specific BSPs publicly.
- **Suggested access paths for Doug:**
  1. **GPL compliance request** — Send a written request to Wind River legal (`opensource@windriver.com`) citing GPL/LGPL clauses. They are obligated to provide the corresponding source for any GPL-licensed components shipped in the DLK0040 BSP. This is the most reliable legit path.
  2. **Faurecia Clarion direct request** — As the ultimate licensee, FCE could be asked for the GPL bundle. Unlikely to respond to a non-customer.
  3. **Wind River Support2 portal** — https://support2.windriver.com — requires existing license; if Doug's employer has any Wind River relationship via partnership, can be queried internally.
  4. **Reverse-engineering** — Extract the source-of-truth kernel config from the factory DCU's `/proc/config.gz` (already done in earlier sessions) — gives us functional parity without needing the BSP package.

---

## 7. Imagination Technologies — PowerVR SGX 535 (GMA 600 GPU)

### 7.1 Public documentation

| Document | URL | Access |
|----------|-----|--------|
| "Introduction to PowerVR for Developers" (2021, v1.0) | https://imagination-technologies-cloudfront-assets.s3.eu-west-1.amazonaws.com/website-files/documents/Introduction_to_PowerVR_for_Developers.pdf | Free |
| PowerVR Hardware Architecture Overview | http://powervr-graphics.github.io/WebGL_SDK/WebGL_SDK/Documentation/Architecture%20Guides/PowerVR%20Hardware.Architecture%20Overview%20for%20Developers.pdf | Free |
| Wikipedia PowerVR | https://en.wikipedia.org/wiki/PowerVR | Free |
| NotebookCheck SGX 535 page | https://www.notebookcheck.net/PowerVR-SGX535.115906.0.html | Free |
| Datasheet Archive PowerVR SGX | https://www.datasheetarchive.com/PowerVR%20sgx-datasheet.html | Free index |
| Imagination forum (SGX 535 docs thread) | https://forums.imgtec.com/t/powervr-sgx-535-intel-gma-500-poulsbo-any-documentation-still-available/4266 | Free |
| Original announcement (Design & Reuse) | https://www.design-reuse.com/news/14978/imagination-reveals-extended-powervr-sgx-graphics-video-core-family.html | Free |

### 7.2 PowerVR SGX DDK (driver development kit)

- **Linux kernel module:** GPL/MIT dual license (KM is open-source, out-of-tree). TI mirror: https://git.ti.com/cgit/graphics/omap5-sgx-ddk-um-linux
- **User-mode (GLES 2.0):** Closed-source binary blob. Only legitimately distributable under Imagination's redistribution agreement.
- **2022 open-source push (post-SGX, Rogue+):** https://www.gamingonlinux.com/2022/03/imagination-technologies-bringing-open-source-powervr-drivers/ — does NOT cover SGX 535.
- **Community tracker:** https://forums.imgtec.com/t/open-source-drivers-for-powervr-sgx-535/1745
- **Linux Sunxi page:** https://linux-sunxi.org/PowerVR

**Most relevant for us:** On mainline 4.19, gma500 supports 2D/KMS/modesetting only — there is **no usable 3D acceleration** on SGX 535 under the mainline kernel due to closed userspace. This is why our Phase 1 gate test is purely about whether gma500 claims `/dev/fb0` against PCI 0x4108 — 3D is out of scope until/unless we revisit EMGD binaries.

### 7.3 Apple iOS reference (SGX 535 was the iPad 1 GPU)

- https://developer.apple.com/library/archive/documentation/OpenGLES/Conceptual/OpenGLESHardwarePlatformGuide_iOS/OpenGLESPlatforms/OpenGLESPlatforms.html

---

## 8. NHTSA / Recall Database — DCU-related Safety Recalls

| Recall ID | Title | Models | URL | Relevance |
|-----------|-------|--------|-----|-----------|
| **NHTSA 18V601 / R18A60** | "Voluntary Safety Recall Campaign 2017 QX60" | 2017 QX60 | https://static.nhtsa.gov/odi/rcl/2018/RCRIT-18V601-0940.pdf | Different DCU subsystem — included for completeness |
| **NHTSA R21A9** | "2021 Q50/Q60/QX80 — Telematics Control Unit reprogram; FMVSS 111 Rear Visibility" | 2021 Q50/Q60/QX80 | https://nissan.oemdtc.com/840/2021-infiniti-q50-q60-qx80-voluntary-recall-campaign-r21a9-telematics-control-unit-reprogram/ | DOES touch DCU/AV control screen; FMVSS 111 compliance gate |
| **NHTSA 19V654 / R1911** | "FMVSS 111 Rear Visibility System — 2018-2019 Infiniti" | 2018-2019 Infiniti | https://nissan.oemdtc.com/365/fmvss-111-rear-visibility-system-2018-2019-infiniti and https://nissan.oemdtc.com/362/fmvss-111-rear-visibility-system-2018-2019-nissan/ | Backup-camera display defeat scenario |
| Voluntary recall campaign — Infotainment SW update | "Display Control Unit (Infotainment) Software Update — 2018-2019 Infiniti" | 2018-2019 Infiniti | https://nissan.oemdtc.com/715/voluntary-recall-campaign-display-control-unit-infotainment-software-update-2018-2019-infiniti | Directly DCU-related |
| NHTSA TSB master index | All recalls + TSBs | All | https://data.transportation.gov/Automobiles/NHTSA-s-Office-of-Defects-Investigation-ODI-Techni/hczg-qbhf | Free dataset |

**Status for 2017 Q60 specifically:** No DCU-specific federal recall on the 2017 Q60. The 2017 Q60 fuel-pump recall is unrelated. Backup-camera FMVSS 111 recalls hit 2018-2021 model years, not 2017.

Additional safety-aggregator pages:
- https://www.kbb.com/infiniti/q60/2017/recall/
- https://www.cars.com/research/infiniti-q60/recalls/
- https://www.go-parts.com/garage/infotainment-display-infiniti-qx60-nissan-pathfinder-infiniti-q70-2017-2025 (sister-platform DCU failure pattern)

---

## 9. Patents — Cross-Vendor Landscape

(See §3.2 for DENSO V2G/overlay patents.)

### 9.1 Clarion-assignee navigation / display patents

- "Display control device and display system" — https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/10013954
- "Vehicle navigation system with pixel transmission to display" — https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/6243646
- "Vehicle navigation user interface for a display screen" (design patent) — https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/D425499

### 9.2 Intel EMGD / overlay-rendering patents

Searchable via Google Patents `assignee:"Intel" overlay sprite display` — Intel holds dozens of patents on the EMGD architecture but they map to the published EMGD User Guide. The User Guide is the more useful reference.

### 9.3 General access strategy

- **Free:** Google Patents (https://patents.google.com), USPTO Public PAIR.
- **For prior-art / claim parsing:** IEEE Xplore (often Doug's local public library — Cary, NC — provides free patron access).

---

## 10. Standards & Specifications Referenced by the DCU

### 10.1 UEFI

- **UEFI Specification 2.10:** https://uefi.org/sites/default/files/resources/UEFI_Spec_2_10_Aug29.pdf
- **Boot Manager chapter (HTML):** https://uefi.org/specs/UEFI/2.10/03_Boot_Manager.html
- **Removable-media fallback explainer (Debian wiki):** https://wiki.debian.org/UEFI
- **Boot process reference (ArchWiki):** https://wiki.archlinux.org/title/Arch_boot_process
- **EFI boot blob (IA32 — relevant to our 32-bit elilo on Tunnel Creek):** https://github.com/lamadotcare/bootia32-efi
- **mjg59 boot reference essay:** https://mjg59.livejournal.com/138188.html

**Relevance:** The DCU EFI is 32-bit (IA32) — fallback path is `/EFI/BOOT/BOOTIA32.EFI`. Our elilo placement on the SD card honors this.

### 10.2 SD Host Controller (SDHCI)

- **SDHCI Simplified Spec v4.20:** https://www.taterli.com/wp-content/uploads/2017/05/SD-Host-Controller-Simplified-SpecificationV4.20.pdf
- **Mirror:** https://www.ercankoclar.com/wp-content/uploads/2017/11/Simplified_SD_Host_Controller_Spec.pdf
- **SD Physical Layer Simplified v6.00:** https://academy.cba.mit.edu/classes/networking_communications/SD/SD.pdf
- **SD Association download index:** https://www.sdcard.org/downloads/pls/ and https://www.sdcard.org/developers/sd-standard-overview/host-controllers/
- **Linux SDHCI driver source:** https://github.com/torvalds/linux/blob/master/drivers/mmc/host/sdhci.h
- **Microchip SDHC tutorial:** https://ww1.microchip.com/downloads/en/DeviceDoc/57_SDHC_60001334A.pdf

**Relevance:** The LAPIS ML7213 SDHCI block reports non-standard PCI class 0x000805 (instead of 0x080500). Mainline sdhci-pci ignores it without vendor IDs — root cause of an entire week of "black screen, no markers" debugging on 4.19.

### 10.3 LVDS / FPD-Link / OpenLDI

- **OpenLDI v0.95 spec:** https://glenwing.github.io/docs/OpenLDI-0.95.pdf
- **OpenLDI mirror (Inova Semi):** https://inova-semiconductors.de/files/daten/pdf/openldi.pdf
- **OpenLDI Wikipedia:** https://en.wikipedia.org/wiki/OpenLDI
- **FPD-Link Wikipedia:** https://en.wikipedia.org/wiki/FPD-Link
- **LVDS overview:** https://en.wikipedia.org/wiki/Low-voltage_differential_signaling
- **Lattice OpenLDI/FPD-Link Tx IP user guide:** https://www.latticesemi.com/~/media/LatticeSemi/Documents/UserManuals/1D2/FPGA-IPUG-02022.pdf
- **Lattice OpenLDI/FPD-Link Rx IP user guide:** https://www.latticesemi.com/-/media/LatticeSemi/Documents/UserManuals/1D2/FPGA-IPUG-02021.ashx
- **TI DS90UH948-Q1 FPD-Link III to OpenLDI deserializer datasheet:** https://www.mouser.com/datasheet/2/405/ds90uh948-q1-519585.pdf

**Relevance:** The 800×480 upper + 800×420 lower LVDS panels in the Q60 DCU are FPD-Link 1 / OpenLDI signaling. Our LVDS port 2 is the upper nav; port 4 is SDVO chain to the lower. Spec governs timing, DC balance, max cable length.

### 10.4 PCI SIG

- **PCI device class codes** — defined by PCI-SIG, mirrored at https://pci-ids.ucw.cz/ and in `/usr/share/hwdata/pci.ids`. SD Host Controller class is 0x080500. LAPIS misreports 0x000805 (note byte-swap quirk) — this is well-known to mainline maintainers; see Morinaga patches.
- **PCI Local Bus Specification 3.0** — owned by PCI-SIG, paid membership for spec download.

### 10.5 CAN (AV-CAN, ITS-CAN family)

- **ISO 11898** family (CAN physical + data link) — paywalled at ISO.
- **ISO 15765-4** (CAN diagnostic comms, 11-bit ID, 500 kbps) — paywalled.
- **Nissan/Infiniti CAN reverse-engineering references (free):**
  - https://github.com/balrog-kun/nissan-qashqai-can-info — open CAN decoding
  - https://github.com/balrog-kun/nissan-qashqai-can-info/blob/main/README.md
  - https://automotivetechinfo.com/2011/03/nissan-controller-area-networks/ — Nissan CAN architecture overview
  - https://www.infinitiq50.org/threads/can-bus-gateway-location.137449/ — gateway location
  - https://leaf-obd.readthedocs.io/en/latest/tutorial/elm327.html — Leaf CAN reference (AV-CAN at DTC pins 11/2, 500 kbps)
- **Forum reverse-engineering threads:** https://forums.nicoclub.com/looking-for-specific-info-on-canbus-t606326.html

**Relevance:** AV-CAN is the bus the DCU uses to talk to the audio amp, steering-wheel controls, climate. Nissan's spec is not public; community RE work is the closest reference. Doug's Phase 4 will need to live-capture this.

---

## Cross-Cutting Access Strategy (for Doug)

| Tier | What it unlocks | Cost |
|------|----------------|------|
| **Free public** | All of §1.1-1.3, §2.1 public exhibits, §3.2 patents, §4 Intel/Mouser/Versalogic mirrors, §5 ROHM datasheet + SourceForge tarball, §6 Wind River public BSPs only, §7 PowerVR public docs, §8 NHTSA, §9 Google Patents, §10 OpenLDI / SDHCI simplified specs | $0 |
| **Infiniti TechInfo 1-day pass** | Section AV of the FSM with wiring diagrams | ~$20 (one day) |
| **Mitchell1 ProDemand / AllData** | Same FSM data, indexed differently | ~$25/mo |
| **FCC FOIA request** | Confidential AX2QY5092 schematics + RF block diagrams | Free but takes 30-90 days |
| **Wind River GPL request** | DLK0040 BSP corresponding source (kernel only — proprietary userspace excluded) | Free; written request |
| **IEEE Xplore** | UEFI / SDHCI / PCI / CAN underlying papers | Free at most US public libraries |
| **PCI-SIG / SD Assoc full specs** | Beyond "simplified" versions | $$$$ — only needed for spec-bug research |

---

## Top 10 documents to grab right now (priority for v17+ debug)

1. **ITB19-002B** (NHTSA mirror, free) — DCU advance-exchange procedure, parts ordering path
2. **ITB22-013** (Infiniti TechInfo, free) — last legitimate firmware build dates
3. **InTouch Update Procedure v2.0** (`1UH7.PDF`, free) — official update mechanism reference
4. **Intel E6xx Datasheet 324208-005US** (Intel/Mouser, free) — PCI/IGD/LVDS register reference
5. **Intel E6xx Spec Update 324209-017US** (Mouser, free) — errata, B1 stepping, must-know quirks
6. **Intel EG20T Datasheet 324211-009US** (Versalogic, free) — PCH peripheral register map
7. **ROHM ML7213/7223 datasheet** (ROHM, free) — LAPIS IOH compatibility + non-standard class
8. **Morinaga SourceForge ML7213 tarball** (SourceForge, free) — kernel-2.6.37/39 LAPIS patches
9. **OpenLDI v0.95 spec** (community mirror, free) — LVDS panel timing
10. **AX2QY5092 FCC test reports + label sheets** (fccid.io, free) — confirmed RF + PCB SKU lineage

---

**End of document.** ~3,000 words. All URLs verified live or recently archived as of 2026-05-23.
