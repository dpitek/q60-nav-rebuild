# Q60 — OEM Boot Security Audit (2014–2019 Clarion InTouch DCU)

Deep-dive into every hardware- or firmware-level security lockdown that could
prevent or complicate flashing our custom Linux 4.19 + Qt6 image to **slot B**
on the factory Clarion InTouch DCU (Intel Atom E6xx "Tunnel Creek" + EG20T
"Topcliff" PCH).

> **TL;DR.** This platform predates every modern fused-silicon root of trust.
> Boot Guard did not exist when this SoC was made. ELILO does not verify
> signatures. The slot A image (`logan1`) is not checksum-gated by silicon —
> the verification, such as it is, lives in the OEM userland (Wayland HMI,
> not the boot chain). The owner's `deploy-to-image.sh` flow is safe assuming
> the eMMC is pulled and edited externally, slot A is preserved untouched, and
> the FAT32 boot-counter fallback in `start.sh` is in place. The realistic
> brick risk is **operator error**, not silicon enforcement.
>
> The map SD card in the armrest is CPRM/VIN-locked, but it is irrelevant to
> boot — it is a userland data card the OEM nav app reads, not part of the
> boot chain.

---

## Section 1 — Confirmed security mechanisms (with evidence)

| # | Mechanism | State on this SoC | Implication for our flash |
|---|-----------|-------------------|---------------------------|
| 1 | **Intel Boot Guard** | **NOT PRESENT.** Boot Guard was introduced with Haswell (4th-gen Core, 2013). Tunnel Creek E6xx is 2010 silicon, two generations earlier. ([Tom's-Hardware-confirmed timeline](https://forums.tomshardware.com/) ; [Eclypsium overview](https://eclypsium.com/blog/the-keys-to-the-kingdom-and-the-intel-boot-process/) ; [Trammell Hudson Boot Guard primer](https://trmm.net/Bootguard/)) | We are free to flash any UEFI binary. No FPF (Field Programmable Fuse) public-key-hash gates our bootloader. |
| 2 | **Intel ME / CSE** | **NOT PRESENT** on Tunnel Creek embedded line — no Management Engine on E6xx. ([Intel community thread on E6xx BIOS](https://community.intel.com/t5/Embedded-Intel-Atom-Processors/Intel-atom-E6xx-tunnel-creek-board-with-BIOS-or-without-BIOS/td-p/257235)) | No ME-backed FPF programming, no Boot Guard ACM. The CPU comes out of reset with no upstream guardian. |
| 3 | **TPM 1.2 / fTPM 2.0** | **NOT PRESENT.** fTPM (Intel PTT) arrived with Haswell-era ME. E6xx has no discrete TPM on the Clarion DCU board (no TPM mentioned in any teardown or RE thread; [InTouch RE thread](https://www.infinitiq50.org/threads/intouch-reverse-engineering-findings-more-to-come.137236/)). | No measured-boot enforcement. PCR rollback not a concern. |
| 4 | **UEFI Secure Boot (db/KEK/PK)** | **DISABLED.** The factory `elilo.efi` is a 2013-vintage 153 KB PE32+ EFI application. ELILO does not validate kernel signatures; the firmware on the DCU does not enforce Secure Boot against the loader (if it did, the loader and the slot A 2.6.37 kernel — neither of which is Microsoft-signed — would not run). | Our `vmlinuz-4.19-q60` does **not** need to be signed. We can drop a raw bzImage into the FAT32 partition. |
| 5 | **ELILO signature check** | **NONE.** ELILO is a config-driven UEFI loader; it does not verify kernel hash, signature, or even existence prior to `chainload`. Source: ELILO design (upstream HP project, no native crypto). | The `default=` field in `elilo.conf` accepts any label defined in the file. There is **no whitelist** of allowed `default=` values; `q60nav` will be honored as readily as `logan1`. |
| 6 | **eMMC boot partition / RPMB** | **Not used as a security boundary.** The factory boot chain reads from the user partition (`/dev/mmcblk0p1` FAT32). Nothing in the documented boot chain references mmcblk0boot0/boot1 or RPMB. ([InTouch RE thread](https://www.infinitiq50.org/threads/intouch-reverse-engineering-findings-more-to-come.137236/)) | Pulling the eMMC over a USB adapter and editing p1 is exactly what the boot-safety.md flow does today. No RPMB key challenge stops external writes. (`mmcblk0boot0`/`boot1` and RPMB partitions may exist physically — they exist on every eMMC — but the firmware does not consult them.) |
| 7 | **Slot A integrity check** | **NONE.** elilo loads `vmlinuz-2.6.37.6-…fastboot` from FAT32 by filename. There is no per-boot checksum, no signed manifest, no A/B verified-boot like Android AVB. (Per kernel cmdline and elilo.conf in `docs/boot-safety.md`.) | A bit-flip on slot A would not be caught by the loader. Conversely, slot B can be written freely. |
| 8 | **Clarion map SD card (armrest)** | **CPRM / device-locked.** The card uses [CPRM (Content Protection for Recordable Media)](https://en.wikipedia.org/wiki/Content_Protection_for_Recordable_Media) with the Cryptomeria (C2) cipher, and is bound to the radio serial / NAV ID — replacement cards are ordered against VIN + radio serial and shipped with an activation code. ([Infiniti OEM parts](https://parts.infinitiusa.com/p/Infiniti_2017_Q50/Memory-Card--Map-SD-CARD-Map/89533423/25920-4GU0C.html) ; [justanswer thread on activation](https://www.justanswer.com/nissan-infiniti/d4xkj-navigation-system-not-working-when-put-sd-card.html) ; [Naviextras Clarion portal](https://clarion.naviextras.com/shop/portal/devicessupport)) | **Boot is independent of this card.** The OEM nav app refuses to load maps without authentication, but slot A boots without the card present and slot B has its own NC OSM tiles in `/opt/nav/tiles`. We can leave the card in or pull it — either is fine. |
| 9 | **DCUFix DIY procedure** | **No unlock tool, no JTAG, no signing key required.** DCUFix's published path is: remove screen → pop microSD inside the upper screen module → image it / replace it with a known-good preloaded card → reassemble. No bench fixtures, no SWD probe, no ROM flasher. ([DCUFix guides](https://dcufix.com/guides/) ; [Q50 forum DCU Repair Megathread](https://www.infinitiq50.org/threads/2014-2019-dcu-repair-megathread.140924/) ; [squarewheels upgrade-paths writeup](https://squarewheelsauto.com/blogs/news/q50-infotainment-upgrade-paths-three-options)) | Five years of community evidence that the system has **no fused lockdown.** A pre-imaged SD card boots normally. Our flow is the same idea, only writing to the eMMC instead of the microSD. |

---

## Section 2 — Suspected / unverified mechanisms

| # | Item | Status | Notes |
|---|------|--------|-------|
| 1 | **Intel Atom E6xx OTP fuses for JTAG disable** | UNVERIFIED. Tunnel Creek datasheet does not document a JTAG-disable fuse, and no Q50/Q60 teardown reports one. Embedded Atom parts of this era typically left XDP/ITP-XDP enabled in production. | Almost certainly irrelevant to us — we don't need JTAG. If we ever do, plan on probing the PCB for an XDP-style header. |
| 2 | **EG20T (Topcliff) PCH security features** | UNVERIFIED. Search returned only generic SECO module marketing ("built-in Secure Boot") which is module-specific BIOS feature, not silicon-fused. ([SECO ALYA](https://edge.seco.com/en/alya.html) ; [Timesys E6xx+EG20T guide](https://linuxlink.timesys.com/docs/gsg/atomeg20t)) | Clarion's BIOS could in principle have Secure Boot enabled with custom keys, but the existence of a working unsigned ELILO and unsigned 2.6.37 kernel in slot A is incompatible with that. Treat as **off**. |
| 3 | **InsydeH2O BIOS lockdown** | UNVERIFIED. [Insyde delivered UEFI BIOS for Atom E6xx](http://www.embeddedintel.com/news.php?article=1784) in 2010, and Clarion likely uses it. Insyde BIOSes can implement Secure Boot, BIOS Region write-protect, and SMM lock. Whether Clarion enabled any of these is unknown. | Mitigation: we do not modify the BIOS image, only the FAT32 boot partition. SPI flash containing BIOS is **not** the eMMC. |
| 4 | **AV-CAN / BCM handshake gating "trust" of the DCU** | UNVERIFIED but **almost certainly false.** The DCU is a *consumer* of vehicle signals (gear, speed, ignition, illumination), not an authenticator to immobilizer/IVDM/IPDM. The immobilizer challenge is between IKey ↔ BCM ↔ ECM, not the DCU. A DCU that boots an unsigned image will still receive frames from BCM/IPDM-E exactly as before. ([CONSULT-only Work Support boundary documented in `docs/oem-hidden-functions.md` §9](./oem-hidden-functions.md#9-consult-only--boundary-callout)) | Mitigation: capture-day J2534 + candump will confirm the DCU is receive-mostly on AV-CAN with only a small set of transmit IDs (HVAC requests, button events). No challenge-response observed in any forum capture. |
| 5 | **PowerVR SGX535 binary blob licensing** | Moot. We use **Mesa swrast** per `docs/feature-parity-audit.md`. Even if the Imagination blob needs a per-device key, we never load it. | N/A. |
| 6 | **Per-VIN signing of factory firmware updates** | UNVERIFIED. Infiniti's USB-stick firmware updates (`P4248-ITGEN5 2.0`) are distributed as generic packages, not VIN-specific. The activation code that's VIN-locked is for the **map** content, not the OS. ([Infiniti InTouch SW update procedure PDF](https://www.infiniti-techinfo.com/asistgc_1/diskdocs/1/U/H/1UH7.PDF)) | We're not using the OEM update path anyway — direct eMMC write bypasses it. |
| 7 | **eMMC user-area write protection bits (CMD28/29 perm-WP)** | UNVERIFIED. We have not observed a forum report of the DCU eMMC having permanent write-protect groups, and DCUFix's microSD-swap workflow implicitly relies on writable storage. The internal eMMC is BGA-soldered; if WP were enabled it would have made the unit unrecoverable for thousands of forum users. | Treat as **off**. Confirm by `mmc extcsd read` on hardware day if practical (see Section 4). |

---

## Section 3 — Bypass / workaround per item

Most of Section 1 is "nothing to bypass." The few items that need a strategy:

- **§1.4 / §1.5 Unsigned ELILO + unsigned kernel** — already aligned with our
  flow; no signing required.
- **§1.7 No slot A integrity** — we *want* this; means our boot-counter
  rewrite of `default=` will be honored without challenge. Mitigation against
  *accidental* slot A corruption is procedural: `deploy-to-image.sh` already
  scopes writes to p1 + p3 + p8 only.
- **§1.8 CPRM map card** — we do not bypass it. We **ignore** it. Our build
  uses [`reference files/nc-osm.pbf`](../reference%20files/nc-osm.pbf) processed
  into Valhalla + vector tiles. The OEM map card stays in the armrest, unread
  by our stack. If we ever want to *read* OEM map content we would need to
  defeat CPRM — out of scope, legally risky, and we don't need to.
- **§2.4 BCM handshake** — if the hardware-day capture *does* surface a
  challenge-response, our build adds the matching responder. Plan B: if the
  BCM truly refuses to talk to an unsigned DCU (we don't believe this is
  real), we fall back to slot A and revisit. The boot-safety flow already
  covers this — no permanent commitment.

---

## Section 4 — Hardware-day verification checklist (BEFORE slot B flash)

Run these on the bench, eMMC out of car, USB adapter on Mac, **before** writing
anything to slot B. All are read-only or already-planned writes.

1. **Image the entire eMMC** to a sparse file on the Mac:
   `sudo dd if=/dev/diskN of=~/q60-emmc-backup.img bs=4M status=progress conv=sparse`
   Verify size matches the eMMC capacity reported by `diskutil info`.
2. **Verify partition table** is GPT (or hybrid) and matches `docs/boot-safety.md`:
   `gpt -r show /dev/diskN` → 9 partitions, p1=FAT32 ~127MB, p2/p3 Linux,
   p5/p6 Linux (android), p7 50MB, p8 3GB, p9 1GB.
3. **Read elilo.conf** off p1 and confirm `default=logan1`, image entries
   match the template in `docs/boot-safety.md`. Confirm no GPG signatures
   (`*.sig` files) sitting next to the kernels.
4. **Mount slot A (p2) read-only** and grep for:
   - `/etc/issue`, `/etc/os-release` (identify distro — expected GENIVI/Yocto)
   - `dropbear` / `sshd` (already known via RE thread)
   - `bootctl` / `efibootmgr` (presence = a newer A/B-aware tooling — not
     expected but worth confirming)
5. **`mmc extcsd read /dev/diskN`** (Linux VM or Docker container) — inspect:
   - `BOOT_WP[173]` — should be 0 (no permanent write protect on boot areas)
   - `USER_WP[171]` — should be 0 (no user-area WP)
   - `BOOT_PARTITION_ENABLE[179]` — confirms whether boot partitions are
     selected (we expect "user area"/0 — i.e. firmware boots from p1, not
     from `mmcblk0boot0`)
   - `RPMB_SIZE_MULT[168]` — informational; we won't touch RPMB
6. **Open the eMMC backup image in a hex editor** and search for `Boot Guard`,
   `KeyManifest`, `BPM`, `IBB` — none should be present (these are Boot Guard
   artifacts). Their absence is final confirmation the platform is
   unprotected at the silicon level.
7. **Inspect `elilo.efi`** with `file` and `objdump -h` to confirm it is the
   stock 2013 build, not a re-signed variant.
8. **Slot A kernel signature check**: `sbverify --list vmlinuz-2.6.37.6-…` —
   expect "no signature table present". This is the final proof that Secure
   Boot is not being enforced.

If any of 5/6/7/8 produce a surprise — STOP and reassess before writing to p3.

---

## Section 5 — Recovery path if slot B flash bricks the unit

Recovery hierarchy from cheapest to most invasive:

### Tier 0 — Automatic (already in place)
Two failed boots → `start.sh` rewrites `default=logan1` and reboots. Per
`docs/boot-safety.md`. No human intervention.

### Tier 1 — Pull eMMC, edit on Mac (5 min)
1. Remove DCU, pop eMMC (or use the USB-eMMC adapter on the already-soldered
   chip if it's BGA — in which case go to Tier 2).
2. Mount p1 (FAT32) on the Mac.
3. `sed -i '' 's/^default=.*/default=logan1/' /Volumes/boot\ 1/elilo.conf`
4. Reinstall. Boots to factory.

**Required tools:** USB-eMMC reader, screwdrivers. Per
[DCUFix tool list](https://dcufix.com/guides/) and the upper-screen teardown
covered in their R52/Y62 guides (the V37 DCU upper-screen housing is the same
family).

### Tier 2 — eMMC is BGA-soldered, no socket
Restore from the `q60-emmc-backup.img` taken in Section 4 step 1 via the same
USB adapter — the eMMC presents as a USB mass-storage device once probed, the
BGA-soldered chip is still accessible via the on-PCB test pads / SD-mode
fallback that DCUFix uses for board-level repairs. Worst case: write the
backup back byte-for-byte. **This is why Section 4 step 1 is non-negotiable.**

### Tier 3 — eMMC truly bricked (write failure mid-flash, bad block)
- **Cable list:** USB-eMMC adapter (Tigard or generic ISP-style), CH341A,
  FT232H (for any ad-hoc SPI/UART), 2.5mm pitch jumper wires.
- **Procedure:** Identify the eMMC test pads (CLK, CMD, DAT0–3, VCC, VCCQ,
  GND) on the DCU PCB, wire to the adapter, present the chip in SD-mode and
  re-write from backup. Documented generically; not Q60-specific. If this
  fails, source a replacement DCU shell from a salvage Q50 (~$300–500 on
  eBay) and move our eMMC chip.
- No JTAG of the SoC is required for eMMC-level recovery.

### Tier 4 — Last resort (we should never reach this)
Dealer CONSULT-III-plus DCU reconfiguration. Required only if the
**configuration table** is wiped (which our flow does not touch — see
`docs/oem-hidden-functions.md` §6).

---

## Section 6 — Specific risks to `deploy-to-image.sh`

| Risk | Likelihood | Mitigation already in place | Residual action |
|------|-----------|----------------------------|-----------------|
| Wrong device selected (overwrite Mac's internal disk) | LOW (script prompts for SLOT_B_DEV) | `set -e`, interactive prompt | Add a `diskutil info` sanity check + an explicit confirm prompt before `dd` |
| Default flipped to `q60nav` prematurely | LOW | Default mode is `deploy` not `test`; flip is opt-in via `--test` | None needed |
| Slot A (p2) accidentally written | NEAR ZERO | Script writes only p1 (kernel + elilo.conf) and p3 (slot B rootfs) and p8 (nav app) | Add a paranoia guard: assert `[ "$SLOT_B_DEV" != "/dev/diskNs2" ]` before dd |
| FAT32 corruption during edit | LOW | `sync` + standard macOS umount | None |
| eMMC write-protect bits set after first boot | NEAR ZERO based on Section 2.7 | None | Verify with `mmc extcsd read` on bench day (Section 4 step 5) |
| Boot-counter never resets → infinite logan1 fallback | LOW | `start.sh` deletes the counter on successful app start | Confirm Qt6 startup path actually reaches the `rm -f $COUNT_FILE` line — add a systemd `WatchdogSec=` style success ping |
| ELILO refuses unknown `default=` label | NONE | ELILO accepts any label present in `elilo.conf` (§1.5) | None |
| Kernel cmdline mismatch crashes slot B before counter increments | MEDIUM (this is the *real* risk) | Counter increments early in `start.sh`, not pre-userland | If the kernel itself panics in initramfs, `start.sh` never runs, counter never fires. Mitigation: keep `q60nav` `append=` minimal and match slot A's known-good `lpj=` / `mem=` values. Already done per `docs/boot-safety.md` template. |

The last row is the only material residual risk. It is mitigated by keeping
the kernel command line conservative and by the **physical eMMC pull as the
universal escape hatch.** Every other "lockdown" we audited turned out to be
absent.

---

## Sources

### Boot Guard / Secure Boot timeline
- [Eclypsium — The Keys to the Kingdom and the Intel Boot Process](https://eclypsium.com/blog/the-keys-to-the-kingdom-and-the-intel-boot-process/)
- [Trammell Hudson — Boot Guard](https://trmm.net/Bootguard/)
- [me_cleaner wiki — Intel Boot Guard](https://github.com/corna/me_cleaner/wiki/Intel-Boot-Guard)
- [Intel Boot Guard processor support article](https://www.intel.com/content/www/us/en/support/articles/000091919/processors.html)
- [mjg59 — Intel Boot Guard, Coreboot and user freedom](https://mjg59.dreamwidth.org/33981.html)

### Tunnel Creek E6xx / EG20T platform
- [Electronic Design — Tunnel Creek Takes A Number (2010)](https://www.electronicdesign.com/technologies/embedded/digital-ics/processors/microcontrollers/article/21791906/tunnel-creek-takes-a-number)
- [Intel community — E6xx Tunnel Creek BIOS thread](https://community.intel.com/t5/Embedded-Intel-Atom-Processors/Intel-atom-E6xx-tunnel-creek-board-with-BIOS-or-without-BIOS/td-p/257235)
- [Insyde delivers UEFI BIOS for E6xx (2010)](http://www.embeddedintel.com/news.php?article=1784)
- [Timesys Getting Started — Atom E6XX + EG20T](https://linuxlink.timesys.com/docs/gsg/atomeg20t)
- [Atom E6xx embedded computing brief (Mouser PDF)](https://www.mouser.com/datasheet/2/612/atom-e6xx-embedded-computing-brief-595555.pdf)

### Q50/Q60 InTouch reverse engineering & repair
- [InTouch Reverse Engineering Findings (Q50 forum thread)](https://www.infinitiq50.org/threads/intouch-reverse-engineering-findings-more-to-come.137236/)
- [2014–2019 DCU Repair Megathread](https://www.infinitiq50.org/threads/2014-2019-dcu-repair-megathread.140924/)
- [DCUFix — Nissan & Infiniti DCU repair guides](https://dcufix.com/guides/)
- [DCUFix homepage](https://dcufix.com/)
- [3 Paths to Upgrade Your Q50 Infotainment — squarewheels](https://squarewheelsauto.com/blogs/news/q50-infotainment-upgrade-paths-three-options)
- [QX30 DCU Factory Reset warning thread (same DCU family)](https://www.infinitiqx30.org/threads/beware-dcu-factory-reset-problem.26410/)
- [Infiniti InTouch Software Update Procedure v2.0 (2014 PDF)](https://www.infiniti-techinfo.com/asistgc_1/diskdocs/1/U/H/1UH7.PDF)

### Map SD card / CPRM
- [Wikipedia — Content Protection for Recordable Media (CPRM)](https://en.wikipedia.org/wiki/Content_Protection_for_Recordable_Media)
- [Infiniti OEM parts — Q50 map SD card 25920-4GU0C](https://parts.infinitiusa.com/p/Infiniti_2017_Q50/Memory-Card--Map-SD-CARD-Map/89533423/25920-4GU0C.html)
- [Justanswer — Q50 nav SD card VIN/activation requirement](https://www.justanswer.com/nissan-infiniti/d4xkj-navigation-system-not-working-when-put-sd-card.html)
- [Naviextras — Clarion device portal](https://clarion.naviextras.com/shop/portal/devicessupport)
- [Q50 forum — SD card for nav system thread](https://www.infinitiq50.org/threads/sd-card-for-navigation-system.111329/)

### eMMC RPMB / write protection (reference)
- [sergioprado.blog — RPMB inside the eMMC](https://sergioprado.blog/rpmb-a-secret-place-inside-the-emmc/)
- [Wikipedia — Replay Protected Memory Block](https://en.wikipedia.org/wiki/Replay_Protected_Memory_Block)
- [Western Digital eMMC security white paper](https://documents.westerndigital.com/content/dam/doc-library/en_us/assets/public/western-digital/collateral/white-paper/white-paper-emmc-security.pdf)

### Internal cross-references
- [`docs/boot-safety.md`](./boot-safety.md) — slot A/B layout + FAT32 boot counter
- [`docs/oem-hidden-functions.md`](./oem-hidden-functions.md) — diagnostic menus, CONSULT boundary, "danger zone" Service tab
- [`docs/hardware-day-capture-checklist.md`](./hardware-day-capture-checklist.md) — J2534 + candump plan
- [`scripts/deploy-to-image.sh`](../scripts/deploy-to-image.sh) — actual deploy flow
