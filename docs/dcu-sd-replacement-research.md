# DCU Boot microSD Replacement Research

**Subject:** Nissan/Infiniti DCU (Display Control Unit) internal boot microSD — is it
field-replaceable, and what (if anything) is mediating "which cards boot"?

**Target hardware:** 2017 Infiniti Q60 Red Sport 400, DCU model 28387-4HK0B (Clarion
QY5092), Atom Crossville Lapis SoC, Wind River Linux 2.6.37 + Android subsystem +
DENSO GENIVI userland + Intel EMGD display stack, elilo boot loader.

**Bottom line first:** The internal boot microSD is field-replaceable with **any**
class-10/UHS-1 microSD up to 32 GB. There is **no CID lock**, no card-to-DCU pairing,
no dealer initialization step that involves the SD card. The "first boot fails, second
boot succeeds" pattern Doug saw is consistent with the **elilo bootchooser / dual A-B
rootfs ("logan1" + "logan2_backup") with a remaining-boot-attempts counter** that this
class of automotive Linux uses — it is **not** an identity check.

---

## 1. Verdict: Is the boot SD field-replaceable?

**YES — fully field-replaceable. No identity binding.**

Strongest evidence:

1. **DCUFix sells the repair kit for $189 with a generic class-10 microSD pre-flashed
   with a working image.** They explicitly note the same SD image works across vehicles:
   > *"An SD Card from an Infiniti QX60 has been confirmed working in a Nissan
   > Pathfinder; the hardware really doesn't seem to matter."*
   (DCUFix repair kit instructions)

2. **A Q50 owner physically swapped his SD into a stranger's 2016 Q50 — it just worked:**
   > *"I met another Infiniti Q50 owner on the street, tried their card, and everything
   > worked with no keys required."*
   ("Help restore the SD card" thread, infinitiq50.org/threads/132537)

3. **A $9 generic 32 GB card flashed with the 2014 firmware image booted flawlessly:**
   > *"One user bought a $9 32GB SD card, flashed it with the 2014 file, and after
   > installing it in the upper screen everything worked flawlessly."*
   (DCU Repair Megathread)

4. **DENSO/Denso-Ten ships exchange DCUs without an internal SD card.** Field replacement
   units arrive empty — installer flashes/inserts a working microSD. If CID were
   validated, Denso would have to dynamically register every blank shipped DCU, which
   they do not. (Multiple repair-shop and forum reports.)

5. **None of the three Infiniti TSBs for DCU replacement (ITB19-002a/b/c, covering
   2014-2017 and 2018-2020) mention the SD card at all.** The full procedure is:
   - Save Multi-AV configuration values from old DCU via CONSULT-III plus
   - Physically swap the DCU
   - Write the saved Multi-AV configuration values into the new DCU
   - (QX30 only, 2018-2019) — register replacement DCU via NNAnet/Infiniti Owner Services
     for InTouch *Apps subscription* binding
   - **No "SD initialization" step. No "card pairing" step. No CID write step.**

Confidence: **High**. Multiple independent commercial repair shops, DIY forums, the
official TSBs, and at least three documented cross-vehicle SD-card swap reports all
converge on the same answer.

---

## 2. So what IS being validated? (And why did Doug's duplicate card not boot?)

If it isn't card CID, what is it? Two candidates explain the empirical observation:

### Candidate A (most likely): **elilo + boot-attempts counter rollback**

The DCUFix DIY guide explicitly documents that `elilo.conf` sits in the 134-MB FAT/EFI
boot partition with a single `default=` line pointing at either `logan1` (primary) or
`logan2_backup` (secondary). The recovery procedure for a corrupted primary partition is
to manually edit `elilo.conf` to point at `logan2_backup`.

This is a textbook automotive **dual-rootfs A/B bootchooser** pattern. In standard
implementations (efibootguard, RAUC, U-Boot bootchooser, barebox bootchooser):

- A counter `remaining_attempts` is decremented on each boot attempt.
- A userland service ("health-check") resets the counter to N on successful boot.
- If the counter hits 0 without being reset, the loader switches `default=` to the
  other slot — this is the rollback.
- A watchdog forces reboot if the system hangs before health-check runs.

**This matches Doug's observation exactly:**
- **First boot of a partially-modified card:** counter decrements, userland comes up
  far enough to *write* the boot-counter state but possibly not far enough for
  full UI / health-check to clear it, or the boot-counter is intentionally being
  incremented up to a "first-boot complete" flag.
- **Second boot:** counter is at the right value (or the first-boot wizard finished),
  health-check clears the flag, full boot succeeds.

The "q60_boot_attempts" file Doug mentioned is consistent with this — it's the
remaining-attempts persistence file. If Doug's image preserved the counter at a value
the loader interpreted as "first boot already attempted and failed," it could explain
why the duplicate didn't boot the first time but did the second.

### Candidate B (less likely but worth checking): **filesystem identity (UUID / volume serial / label)**

The kernel `bootargs` line on this class of system typically references the root device
either as `/dev/mmcblk0p2` (path-based, would always work) or as
`root=UUID=…` / `root=PARTUUID=…` / `root=LABEL=…` (identity-based). If the latter, then
the duplicate card needs to **preserve the exact same UUID / PARTUUID / label** as the
OEM card. A naive `dd` will preserve them; many imaging tools regenerate UUIDs.

Easy way to verify: read the elilo entry's `append=` line on the original card and
check whether `root=` resolves by path or by identity. If by identity, that's your
delta. Doug's duplicate was described as "byte-for-byte identical," which should
preserve UUIDs — but **not** if it was sourced from an image created by re-imaging
through a filesystem-aware tool that regenerated identifiers.

### What is **NOT** being validated (with high confidence):

- **CID (Card Identification register).** No forum has ever reported CID-locked behavior
  on the DCU boot card. The only Nissan/Infiniti CID-locked card is the **Nissan Leaf's
  Bosch infotainment SD** (zelemar.eu has a guide for that — different system entirely).
- **MID / MAC.** Same reasoning — community has never seen brand-specific
  acceptance/rejection.
- **Volume serial (FAT BPB) — most likely irrelevant** but trivial to verify alongside
  UUID/PARTUUID above.

---

## 3. What does the dealer actually do when replacing a DCU?

From TSB ITB19-002c (current as of Feb 2021), confirmed near-identical procedure in
ITB19-002a/b:

**Tools:** CONSULT-III plus diagnostic tablet, NNAnet.com login, battery maintainer.

**Procedure summary:**

1. **PART 1 — Order exchange DCU from Denso-Ten** via f10ncs.com (TECH LINE call no
   longer required as of ITB19-002c).
2. **PART 2 — Record Multi AV Configuration** — Open CONSULT-III plus →
   Re/programming Configuration → Confirm VIN → MULTI AV → **Before ECU Replacement**
   → Record the "Setting Value" table (radio variant, around-view, BOSE option,
   nav-equipped, lane departure, etc.) and Save.
3. **Physical DCU swap** per ESM section.
4. **PART 3 — Configure Multi AV System** — repeat the CONSULT-III plus connect /
   VIN-confirm steps, this time hit Confirm. If a particular dialog appears, the system
   has auto-loaded the configuration from NNAnet via VIN and you're done. If the dialog
   does not appear (or errors), proceed to PART 4.
5. **PART 4 — Manual Multi AV configuration** — re-enter the values written down in PART 2
   from drop-downs.
6. **(QX30 only, 2018-2019)** PART 5 — register the new DCU via call to Infiniti Owner
   Services at 1-855-444-7244, providing Unit ID + VIN, for InTouch Apps subscription.

**Nothing in any TSB touches the internal boot SD card.** Steps are pure ECU
configuration writes (vehicle option flags), nothing storage-related. Q50/Q60/V37
chassis explicitly does **not** require the "Register Replacement DCU" step — that's
QX30-only and is about online-services subscription binding, not bootability.

For software updates, the dealer tool is the **P4248-ITGEN5 2.0 USB memory stick**,
inserted into the center-console USB port — not an SD card. The update runs from USB,
takes ~60 minutes, and writes to the internal SD invisibly. This confirms the SD is
read/write-mounted by stock firmware as a normal filesystem, not a CID-bound secure
element.

---

## 4. The "first boot fails, second boot succeeds" pattern

Doug's observation is **consistent with elilo / bootchooser A/B rollback behavior, not
a card-identity check.** Specifically:

- First boot of partially-modified image: kernel comes up, userland init runs partway,
  but something fails or the boot-counter is in a state that hasn't been "blessed"
  yet → loader either picks `logan2_backup` or stalls and reboots.
- Second boot: `logan2_backup` boots cleanly OR the userland completes the first-boot
  "bless" step from the partial run → boot completes normally.

If the failure were card-identity (CID/MID/etc.), the first boot would *never* succeed
even after reboot — because the card identity doesn't change between boots. The fact
that the *second* boot succeeded on the same hardware is strong evidence the gating
mechanism is **stateful boot-counter logic**, not identity.

To pin this down on the bench:

1. Read `elilo.conf` on the OEM card — note `default=` value and any `append=` kernel
   args with `root=…`.
2. Look for a per-slot counter file: `/dcu/boot-cnt`, `/data/boot_attempts`,
   `/var/lib/efibootguard/*`, or a similar systemd-installed file on the persistent
   data partition.
3. Look for a systemd unit / SysV init script named something like `boot-complete`,
   `health-check`, `mark-good`, `clear-boot-counter`, or referencing
   `boot_attempts` / `q60_boot_attempts`.
4. Verify the kernel `bootargs` `root=` is path-based (`/dev/mmcblkXpY`) vs
   identity-based (`UUID=…` / `PARTUUID=…` / `LABEL=…`).

---

## 5. The "armrest map SD" vs "internal boot SD" — definitive disambiguation

These two cards are **not the same** and have **different validation models.**
Cross-referenced sources sometimes conflate them, so making the split explicit:

| Card | Where | Part Number | Pairing? | Mechanism |
|------|-------|-------------|----------|-----------|
| **Internal boot microSD** | Mainboard inside upper DCU | Not a separately-ordered part. Q50/Q60 service replacement is whole DCU; community repair = any 16–32 GB class-10 microSD flashed with the right firmware image | **NO** | None — generic SD, any brand. Filesystem-level only (elilo, dual rootfs). |
| **Map (Nav) SD card** | Center-console armrest slot, eject button accessible to driver | 25920-4HB0E (and revisions) for V37 chassis; supplied by HERE/Navteq | **YES** | "NAV ID" application-layer license key: when you order a map update from HERE/infiniti.navigation.com, you supply your NAVI ID (found at Menu → Information → Map Information) and HERE ships you a card whose map databases are activated for that NAVI ID. The card itself is plain FAT; the maps software refuses to load if NAVI ID mismatches. The lock-tab on the side is the standard SD write-protect tab, and dealer SW updates *require* it unlocked. |

Doug's note: "I had to insert a maps SD in the armrest for normal factory boot to
succeed." This is consistent with the firmware checking for the maps card during the
*nav-enabled* boot path. If your car was originally built with navigation, the
firmware may go down an `if (nav-equipped) { wait_for_maps_card(); }` codepath. The
maps-card check is **independent** of the internal boot card and uses a totally
different mechanism. The boot SD does not need any kind of map SD to be present in
order to boot Linux — but the application layer (`q60_app_…` whatever the upper UI
launcher is named) may stall waiting for it if nav is enabled in the Multi-AV
configuration.

---

## 6. Implications for the project

You can absolutely use a non-OEM card for development. Practical guidance:

- **Card spec:** SanDisk Industrial / SanDisk High-Endurance / Samsung PRO Endurance,
  16 or 32 GB, class-10 / UHS-1 / V10 minimum. (Avoid generic consumer SDs — vibration
  and thermal cycling kill them, exactly why the OEM Toshiba SE08G fails in the first
  place.) Do **not** exceed 32 GB.
- **Imaging tool:** `dd` (raw) or `gnome-disks` Restore Disk Image — preserves UUIDs,
  PARTUUIDs, labels, and the FAT volume serial.
- **What to preserve / replicate on the new card:**
  - GPT / MBR partition table layout (sectors, types, flags).
  - **PARTUUIDs** (set them explicitly with `sfdisk` if `dd`-imaging isn't used).
  - **UUID / LABEL** on every partition.
  - All boot files and the elilo.conf with `default=logan1` (or whichever slot is
    primary on the OEM image).
  - Any `boot_attempts` / `q60_boot_attempts` counter file at whatever value the
    "first boot already succeeded" state requires (this is the suspect difference).
- **Validation strategy:** on the bench, do a `dd if=/dev/sdX | md5sum` against the
  full byte-image of the OEM card to confirm the duplicate is *truly* byte-for-byte.
  If it is, and the duplicate still won't boot, the differentiator is *not* on the
  card — and only possibilities left are CID/MID/MAC differences at the SD controller
  level (which, per all the community evidence above, the DCU does not check).
- **If you want to definitively rule out CID locking**, the cleanest test is the one
  already implied by the community: take any modern SanDisk 16–32 GB microSD, flash
  the OEM image to it (CID will be different from Toshiba SE08G), and try to boot.
  If it boots, CID is conclusively NOT validated. (This is the same test DCUFix runs
  thousands of times a year shipping repair kits.)

---

## 7. Source / citation list

| Source | URL | Use |
|---|---|---|
| DCUFix DIY Free repair guide | https://dcufix.com/dcu-fix-diy-free-version/ | Card specs (16-32 GB, class-10), elilo.conf with logan1/logan2_backup, A/B rollback model, gnome-disks tool |
| DCUFix Guides index | https://dcufix.com/guides/ | Confirms commercial sale of generic pre-flashed microSDs, $189 kit |
| DCUFix R52 Pathfinder pre-built SD guide | https://nissan.egguinox.ca/dcu-fix-pre-built-sd-card-version-version-0-2/ | "An SD Card from an Infiniti QX60 has been confirmed working in a Nissan Pathfinder; the hardware really doesn't seem to matter" |
| Infiniti TSB ITB19-002c (2018-2020 DCU replacement) | https://static.nhtsa.gov/odi/tsbs/2021/MC-10188539-0001.pdf | Full dealer DCU replacement procedure; no SD card mention; CONSULT-III plus Multi-AV configure-only flow |
| Infiniti TSB ITB19-002b (2018-2019 DCU replacement) | https://static.nhtsa.gov/odi/tsbs/2020/MC-10171213-0001.pdf | Earlier version of same procedure |
| Infiniti TSB (2014-2017 DCU replacement) | https://static.nhtsa.gov/odi/tsbs/2019/MC-10152988-9999.pdf | 2014-2017 version, same conclusion |
| InTouch SW Update v2.0 (Dec 2014) | https://www.infiniti-techinfo.com/asistgc_1/diskdocs/1/U/H/1UH7.PDF | Dealer SW update uses USB stick P4248-ITGEN5 2.0, ~60 min, not SD-based |
| DCU Repair Megathread (Q50) | https://www.infinitiq50.org/threads/2014-2019-dcu-repair-megathread.140924/ | "$9 32GB SD card, flashed with 2014 file, worked flawlessly"; SD location/install; common failure pattern |
| InTouch Reverse Engineering Findings thread | https://www.infinitiq50.org/threads/intouch-reverse-engineering-findings-more-to-come.137236/ | Intel Crossville Lapis SoC, Linux kernel, system.map + vmlinuz on first partition (~4.5 MB), Wayland WM, root shell via USB-TTL after patch |
| "Help restore the SD card" thread (Q50) | https://www.infinitiq50.org/threads/help-restore-the-sd-card.132537/ | Owner swap test — another Q50's card "everything worked, no keys required" |
| DCU SD card coding (Q60) | https://www.infinitiq60.org/threads/dcu-sd-card-coding.18794/ | Forum confirmation of community DIY repair |
| DCU replacement without dealership (Q60) | https://www.infinitiq60.org/threads/dcu-replacement-without-a-dealership.19770/ | Dealer-bypass options |
| 2014 Q50 with Nav DCU Files thread | https://www.infinitiq50.org/threads/2014-q50-with-nav-dcu-files.139379/ | Confirmed firmware images circulate freely; same image works across many vehicles of same year |
| go-parts.com DCU repair guide | https://www.go-parts.com/garage/infotainment-display-infiniti-q50-infiniti-q60-2014-2019 | Independent confirmation of micro-SD reflash repair (~$50 in parts) |
| Squarewheels Q50 infotainment upgrade paths | https://squarewheelsauto.com/blogs/news/q50-infotainment-upgrade-paths-three-options | DCU failure modes catalog |
| Bosch headunit root (ea/bosch_headunit_root) | https://github.com/ea/bosch_headunit_root | DIFFERENT Bosch lcn2kai architecture — NOR-flash boot + MMC root, no CID auth. Useful as reference for "no auth" in adjacent Nissan IVI systems. Not directly applicable to Denso DCU. |
| Hackaday — Nissan root via USB | https://hackaday.com/2021/01/30/nissan-gives-up-root-shell-thanks-to-hacked-usb-drive/ | Nissan Rogue/Sentra/Altima/Xterra/Frontier (Bosch lcn2kai) — same family, no CID auth on storage |
| NAVI ID — how to find | https://infiniti.navigation.com/cms/page.HowToFindCodes/en_US/InfinitiNA/USD | Disambiguates: the "pairing" people talk about is the *map* SD's NAVI ID activation, not the boot SD |
| Where is the NAVI ID? (Q60) | https://www.infinitiq60.org/threads/where-is-the-navi-id.14512/ | Confirms NAVI ID is at Menu → Information → Map Information |
| ReTouch project discussion | https://www.infinitiq50.org/threads/retouch-update-october-2023.143195/ | Custom-board InTouch replacement project (Silicon Autosport) — references same architecture |
| DENSO open-source compliance — Nissan | https://www.denso.com/global//en/opensource/ivi/nissan/ | OSS source bundles for Nissan/DENSO IVI |
| Nissan global OSS site | https://www.nissan-global.com/EN/OSS/ | OSS bundles index by ISH version |
| ZELEMAR SD CID/lock decoder | https://zelemar.eu/sd-toolbox-lock-unlock-with-password-cid-reading-and-more/ | CID concept reference (this is for *Bosch* Leaf systems, NOT Denso DCU) |
| Just Answer — Reprogram DCU on 2014 Q50 | https://www.justanswer.com/nissan-infiniti/tfgyu-infiniti-q50-dcu-program-reinstall-guide.html | Independent dealer-perspective explanation of CONSULT-III configure-only flow |
| Just Answer — Q50 audio/nav lost after factory reset | https://www.justanswer.com/nissan-infiniti/p6ekw-jay-i-m-having-few-issues-q60-q5o.html | Factory reset breaks Multi-AV config, fixed by CONSULT-III re-config |

---

## 8. Recommendation

Stop investigating CID locking. The mechanism mediating "this card boots, that card
doesn't" on Doug's bench is almost certainly one of:

1. **elilo bootchooser state** (`default=logan1` vs `default=logan2_backup` plus a
   `remaining-attempts` counter file that persists across boots). Doug should
   `cat` the OEM card's elilo.conf and locate any boot-counter file in /data, /var,
   or a dedicated config partition.

2. **Partition-identity (PARTUUID / UUID / LABEL) in kernel cmdline `root=`.** Diff
   the kernel `append=` line vs the partition identifiers on Doug's duplicate.
   `blkid /dev/sdX*` on both cards side-by-side closes this in ten seconds.

3. **First-boot-wizard state file** living on the writable data partition. Once
   marked "first-boot complete," the device proceeds normally. Doug's "second boot
   succeeds" is the smoking gun here — find the file that flipped between attempts.

Confidence the boot SD is non-CID-locked: **95%+.** Confidence the gating is one of
the three above: **~80%, with elilo/bootchooser most likely.**
