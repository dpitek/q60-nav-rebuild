# Q60 DCU SD-Card Duplication Deep-Dive

**Date:** 2026-05-16 overnight
**Question:** Why did Doug's dd'd duplicate microSD fail to boot the DCU, even though dd was done from a known-good OEM image?
**Method:** Read the artifacts captured from the OEM card now in-hand (`/Volumes/boot/...`), cross-check against elilo 3.16 upstream source, DCUFix DIY guide, the V37 Q50/Q60 community, the Wind River / DENSO OSS landscape, and known-good A/B bootchooser patterns.

---

## TL;DR verdict

**Cause, with confidence ranking:**

| # | Cause | Confidence | Why |
|---|---|---|---|
| 1 | The duplicate SD was simply a bad / counterfeit card | **~75%** | The card's CID/MID profile (`MID 0x00`, garbled `??APPSD` product name, Class 4, unreadable partition table in macOS) is the textbook counterfeit signature documented across the SD-card-counterfeit literature. macOS detected the card at the SDHC controller layer but couldn't read a partition table — meaning the dd target was either wear-failed flash or fake (small-real-flash-padded-to-look-big). dd writing to such a card "succeeds" because writes go to RAM cache; reads later return garbage. We never md5'd the duplicate against the OEM, so we have zero proof dd integrity was preserved. |
| 2 | Slot A on the donor image is "already consumed" / Doug didn't switch to `logan2_backup` before imaging | **~15%** | DCUFix's published DIY procedure explicitly requires `default=logan1` → `default=logan2_backup` in `elilo.conf` *before* cloning. Their published rationale: by the time a user is cloning their card, Slot A (`logan1`) is presumed damaged or in a state that won't reliably boot. The OEM card pulled from a healthy car works because Slot A is healthy *on that specific eMMC* — but if any boot-counter / "blessed" state lives on the writable partitions or in EFI variables (NOT on the dd'd SD), a freshly-dd'd card walking in cold may need the manual default-swap to come up. Doug did not perform this step. |
| 3 | Genuine A/B-rollback bootchooser state lives off-SD (EFI variables / MTD / pmemdisk) and is reset when a "new" card boots | **~8%** | The DCU has writable state outside the SD card: the on-board MTD flash (`/dev/mtdblock0`, mounted at `/home/naviwork/data/pdm/ram`) and possibly EFI NVRAM variables (elilo's `EliloAlt` EFI variable mechanism, confirmed in upstream source `alternate.c`). A first boot with the dd'd card likely runs the userland `sud-change-elilo.service` which mutates this state. If the card itself had been good, the second cold boot would have succeeded. We cannot rule this out, but it's a less-likely explanation than the simpler "bad card." |
| 4 | DCU validates something on the card beyond contents (CID lock, SD-CSD-specific signature, anti-counterfeit firmware check) | **~2%** | Nearly excluded by direct evidence: DCUFix sells generic Class-10 microSDs commercially as drop-in repair kits, and Q50 owners report swapping cards between vehicles. If the DCU ran a CID-locked test it would reject those too. The strongest remaining sliver of doubt: it's *possible* the firmware does a sanity check on the SD card's CSD/SCR profile (rejecting cards that report Class 4 / SDSC / impossible CID) — which would explain why DCUFix-sourced Class-10 cards pass but a counterfeit card pretending to be Class 4 fails. That is, the rejection (if any) is on the *fake* card's CSD profile, not its CID identity. |

**Bottom line: the duplicate is almost certainly bad hardware. The bootchooser / first-boot-wizard / VIN-bind theory does not need to be invoked to explain the failure. Buy a real card and re-test.**

---

## Specific recommendation: what to do to make a duplicate boot

### Tier 1 — high-leverage actions Doug should do before the next attempt (in order)

1. **Verify the OEM `DSU backup.img` md5 against the live OEM card** (in-hand). This is the single foundational check that hasn't been done and that we should have. Once verified, that image is the source of truth.

2. **Buy a known-good card.** Specifically: SanDisk Industrial 16 GB or 32 GB (`SDSDQAF3-016G-I` / `SDSDQAF3-032G-I`), or Samsung PRO Endurance 32 GB. Avoid no-name, Amazon "knock-down" listings, and especially anything that doesn't ship from a reputable retailer. The DCUFix kit ships generic Class-10 — they don't even spec industrial — so industrial-grade is upside, not requirement.

3. **Read the card with a tool that surfaces the CID *before* writing.**
   - macOS: `system_profiler SPCardReaderDataType` — verify Manufacturer ID is non-zero, product name is sane ASCII (e.g. `SD32G`), serial isn't suspiciously low like `0x12800007`.
   - If anything looks wrong, return the card. Do NOT dd over it.

4. **dd the verified OEM image, then md5 the destination read-back vs the source image.** `dd if=/dev/rdisk12 of=/tmp/verify.img bs=4m count=<full-size-blocks>` then `md5 /tmp/verify.img /path/to/DSU\ backup.img`. They MUST match.

5. **Eject cleanly with `diskutil eject`** before pulling.

### Tier 2 — defensive actions (cheap insurance)

6. **Before ejecting after the dd, modify `elilo.conf`** on the FAT32 partition: change `default=logan1` to `default=logan2_backup`. This is DCUFix's published recommended step for cloning. It side-steps any "stale Slot A bootchooser state" — Slot B is identical on the OEM card (it's the factory backup), so booting from it is functionally equivalent for first-boot purposes.

7. **Don't change anything else.** Don't reformat, don't resize partitions, don't touch the GPT. Byte-for-byte image only.

### Tier 3 — diagnostic steps if Tier 1+2 still fail

8. **Try the dd'd card on a Q50 or other V37 vehicle.** If it boots there but not in Doug's Q60, the failure is car-specific (which would shift probability strongly toward a VIN/PDM binding theory). If it doesn't boot in either, the failure is card-specific.

9. **Mount the OEM SD's Slot A via `debugfs` read-only** (`sudo debugfs /dev/disk12s2`) and dump:
   - `/lib/systemd/system/sud-change-elilo.service` (full unit definition + `ExecStart` script path)
   - The actual binary `ExecStart` points at
   - Any state files referenced by name in that binary (strings dump)
   - `/etc/elilo.conf.d/` or `/var/lib/elilo/` style state dirs
   - `/home/naviwork/data/pdm/*` state files

   This would prove or kill the off-SD-state theory definitively.

10. **Capture an `efibootmgr -v` and any `EliloAlt` EFI variable** from the running DCU. If `EliloAlt` exists at any point, that confirms the alt-kernel one-shot mechanism is in active use.

---

## Evidence detail

### 1. The kernel cmdline is path-based, not identity-based

From `/Volumes/boot/elilo.conf` (read directly during this session):

```
default=logan1

image=vmlinuz-2.6.37.6-35.1_DLK0040-android-intel-crossville_lapis-fastboot
    label=logan1
    root=/dev/mmcblk0p2
    append="ro quiet rootwait lpj=1296800 android androidboot.console=tty1
            androidroot=/dev/mmcblk0p5 pmemdisk=/dev/mmcblk0p7
            memmap=2M$52M memmap=10M$54M panic=1 priority_khubd=98
            priority_ehciwork=44,R idle=halt ehci_hcd.log2_irq_thresh=2"
    read-only

image=...
    label=logan2_backup
    root=/dev/mmcblk0p3
    append="... androidroot=/dev/mmcblk0p6 ..."
    read-only
```

And from the running kernel's `/proc/cmdline` (captured in `Q60_PROBE_20260516-151334.LOG`):

```
BOOT_IMAGE=dev000:\vmlinuz-... root=/dev/mmcblk0p2 ro quiet rootwait
lpj=1296800 android androidboot.console=tty1 androidroot=/dev/mmcblk0p5
pmemdisk=/dev/mmcblk0p7 memmap=2M$52M memmap=10M$54M panic=1 ...
```

**`root=/dev/mmcblk0p2` is a device-path identifier.** No `UUID=`, no `PARTUUID=`, no `LABEL=`. So a dd'd duplicate inherits all the identity it needs by virtue of being a byte-for-byte copy of the partition layout. **The kernel-level identity argument for "duplicate won't boot" is dead.**

### 2. The "first boot fails, second succeeds" pattern is consistent with a userland-managed slot-bless, not a hardware check

The bootchooser concept (`remaining_attempts` counter + slot bless on userland health-check) is well-documented for embedded automotive Linux. References: barebox bootchooser, RAUC, Android A/B, NVIDIA Jetson, Yocto OE meta-updater. ALL of them share the property that:

- Boot counter or boot-active bit is **stored off the rootfs being attempted** (so the rootfs can be RO, and so a slot switch doesn't require modifying the slot being switched away from). Storage options in industry practice: dedicated config partition, U-Boot env, EFI NVRAM, MTD, or a small RW partition.
- A "successful boot" is signaled by a userland health-check that runs late in init (usually after the main UI / IPC / sensors come up) and writes the "bless" bit.

In our system:
- The FAT32 EFI partition (`/dev/mmcblk0p1`) is the only writable place on the SD itself reachable from the EFI environment.
- The board has on-chip MTD flash mounted at `/home/naviwork/data/pdm/ram` (`/dev/mtdblock0`, ext4) — this is the **Personal Data Manager (PDM) RAM region**, 10 MB, distinctly off-SD. Confirmed by the captured `/proc/partitions` and `/proc/mounts`.
- elilo's `alternate.c` reads a `EliloAlt` EFI runtime variable that lets userland queue a one-shot alternate-kernel selection. **elilo erases the variable on read.** This is precisely the primitive a bootchooser needs.

The systemd unit `sud-change-elilo.service` is wired into `late-services.target.wants/` — i.e. it runs late in boot after the main userland is up. The unit description in the inventory: `"Change elilo.conf for ..."`. Together with the `sud-` prefix (DENSO's "Software Update Daemon" family — same prefix as `PS_SOFT_VUP` aka "Software Version Up" daemon in the captured `ps auxf`), this is **almost certainly the slot-bless / bootloader-config updater that closes the loop after a successful boot**.

Concretely, on a freshly-imaged card, the most likely sequence is:
1. elilo reads `elilo.conf` (says `default=logan1`).
2. elilo checks `EliloAlt` EFI variable. None present → boots `logan1`.
3. Kernel comes up, userland starts.
4. `sud-change-elilo.service` runs late in init and verifies "the last completed boot was successful, the elilo.conf default matches the slot we just came up on, all health checks pass" — then either does nothing (steady state) or rewrites `elilo.conf` if something needs adjusting.
5. On the next cold boot, everything boots clean from `logan1`.

The "first boot black, second boot succeeds" pattern Doug saw on the OEM card is **expected behavior** for this class of system — the first boot races between the slot-bless service finishing and the user looking at the screen. It doesn't mean the SD is special; it means the userland convergence isn't instant.

**For a fresh duplicate of a healthy OEM card, the second cold boot should also succeed — because the dd'd card has the exact same elilo.conf, same Slot A, same Slot B, same FAT32 EFI partition. Off-SD state (EFI variables on host, MTD on host) doesn't move with the SD; it stays in the DCU and is the same regardless of whose card you inserted.**

### 3. Persistent state that does NOT travel with the SD card

Going through the captured artifacts, here's everything that lives somewhere other than the SD:

| Storage | Mount | Type | Size | Role |
|---|---|---|---|---|
| `/dev/mtdblock0` | `/home/naviwork/data/pdm/ram` | ext4 | 10 MB | DENSO PDM "RAM region" — persistent user/system state across reboots. Lives on **on-chip MTD flash inside the DCU**, NOT on the SD. The `invalidate_pdm_ram.service` is wired into `final.target.wants` so it can clear this on shutdown. |
| EFI NVRAM | (firmware) | EFI vars | — | Bootloader state (`EliloAlt`, boot order, possibly bless counters). Stored in the host PCH SPI flash. |
| GPT primary header | `/dev/mmcblk0` byte 0–32 KB | GPT | — | (Lives on SD, but is a fixed structure.) |
| MAC addresses for `usb0`/`usb1`/`audio0`/`navi0` | kernel udev rename rules | runtime | — | From dmesg: `02:00:00:00:00:01`, `02:00:00:00:00:02` — these are **synthetic** CDC-Ether MACs assigned by the kernel/cdc_ether driver, not card-bound. |

**There is no on-SD file that is plausibly used to bind the SD to a specific car.** Per the Q50 community megathread quote: "the configuration is stored in the DCU itself, not the SD card. The SD card swap will not change any config." This is consistent with what we see: VIN-bound options coding lives in the DCU's MTD (PDM region), not on the SD.

### 4. The DCUFix DIY procedure is the practical existence proof

DCUFix's public guide (`https://dcufix.com/dcu-fix-diy-free-version/`) is unambiguous:

- **Card spec:** 16-32 GB microSD, Class 10, UHS-1, V10. (Must be ≤ 32 GB.)
- **Tool:** Gnome-Disks (image-save then image-restore). Functionally identical to `dd`.
- **Procedure:** Mount donor's FAT32, edit `elilo.conf` to set `default=logan2_backup` (line 4), unmount, image the donor card, restore the image to a new generic card, install in target DCU.
- **Cross-car compatibility:** Author explicitly says "I have been able to spread my image to other vehicles without issue many times now." (Per linked R52 Pathfinder pre-built kit page: "An SD Card from an Infiniti QX60 has been confirmed working in a Nissan Pathfinder; the hardware really doesn't seem to matter.")
- **Known failures:** Only failure mode the author calls out is "the SD Card in the DCU Screen was too far damaged" — i.e. the *donor* card had silent rot.

The procedure as described would NOT work if any of the following were true:
- DCU CID-locks the SD (it accepts arbitrary cards in the DCUFix kit).
- SD content is VIN-bound (the same image works across cars).
- A specific UUID/PARTUUID/LABEL must match (`dd` preserves them anyway, but the cross-car compatibility shows it doesn't matter).
- The bootloader requires a signature of the kernel/rootfs (no signed-boot anywhere in `elilo.conf`, and we have a kernel built by random people on the Internet booting successfully in dozens of DCUs).

**The DIY guide's mandatory `default=logan2_backup` step is the smoking gun for what's actually finicky:** Slot A on the donor's eMMC may be in some state that the donor's running userland kept healthy, but that a fresh boot from cold won't recover from. Switching to Slot B side-steps that. Both Slot A and Slot B contain the same factory rootfs (per our research) — Slot B is just the read-only fallback.

### 5. The duplicate card's CID profile screams counterfeit

From Doug's macOS `system_profiler` output on the duplicate:

```
Product Name:        ??APPSD        (?? = unprintable bytes — garbage UTF-8)
Speed Class:         Class 4
Manufacturer ID:     0x00           (INVALID — every real card vendor has a non-zero ID)
OEM/Application ID:  ???           (also unparseable)
Manufacturing Date:  2020-04
Serial:              0x12800007     (very low — typical counterfeit pattern)
diskutil list:       <no media>     (partition table unreadable)
```

Compare to the OEM Toshiba SE08G (from `CID.TXT`):

```
Product Name:        SE08G          (real product code)
Manufacturer ID:     0x000002       (Toshiba — well-known vendor ID)
OEM ID:              0x544d         ("TM" — Toshiba)
Serial:              0xcdcf05a1     (3.46 billion — plausible)
Manufacturing Date:  03/2015
```

Counterfeit SD card signatures documented by `cameramemoryspeed.com`, `hugdiy.com`, `arduino.cc forums`, and the Linux MMC mailing list all agree: invalid/zero MID, low serial, garbled product name, and partition tables that won't read in OS tools = either pure counterfeit or terminally wear-failed. Either way, **dd'ing to that card is throwing the data into a black hole.** The card may even silently report "write succeeded" while the actual NAND never accepts the writes (especially on counterfeit "capacity-padded" cards: real flash is much smaller than the labeled capacity, so writes past the real size loop around and trash earlier data).

### 6. What the InTouch dealer update tool actually does (and what it doesn't)

From the leaked-but-public DCU software update procedure (`infiniti-techinfo.com 1UH7.PDF`, P4248-ITGEN5):
- Update USB ships from Infiniti dealers, runs from the front USB port.
- After ~15s the upper display auto-shows the update UI.
- Engine must run for the full update (up to 60 min) — no ignition cycles or the DCU will brick.
- The update writes new firmware to the internal SD card (overlays the rootfs in-place — Slot A and Slot B both get the new version).
- Pre-condition for cars with Nav: the *map* SD card (a separate SD card in the center console, NOT the internal boot SD) must be UNLOCKED so it can be updated too.

The update mechanism does **not** rebless or VIN-bind the internal boot SD post-update — it just writes new bits. So a dd of a post-update card is functionally identical to a dd of a factory card. There's no "signing ceremony" we're missing.

### 7. Wind River OSS source availability

Both Bosch (`oss.bosch-cm.com/list/nissan`) and DENSO (`denso.com/global/en/opensource/ivi/nissan/`) publish Nissan/Infiniti GPL source releases. The page structure groups by hardware generation:

- **Display Audio** (single 2017-era entry, `0162_170223`, ID `X060140`)
- **NissanConnect** (D2xx through F10x — older platform, pre-Gen4)
- **AIVI / A-IVI2 / Gen4** (2018-onward, newer hardware)
- **P-IVI3.1** (newer still)

The "Display Audio" `0162_170223` (Feb 2017) is the closest candidate to our V37 Q50/Q60 DCU platform — it's the right era and the only Display-Audio-class entry. Worth a download (zip file referenced as `nissan_aivi_0162_170223_oss_dvd_contents.zip`) if Doug wants to definitively identify `sud-change-elilo` source. As reported by Q50 forum users though, the open-source releases are "almost entirely unmodified RPMs for standard open source software" — i.e. DENSO ships their build of Wind River + Yocto packages but holds back the proprietary daemons (the `sud-*`, `PS_*`, naviwork stuff). The bootchooser implementation may or may not be present; we'd need to actually download and grep.

### 8. There's no smoking-gun forum report of "I dd'd to a new card and it failed"

I searched the Q50, Q60, QX60, QX30, and Pathfinder forums plus DCUFix support pages and could not find a single thread where a DIY-er reports:
- dd'ing OEM SD to a verified-good replacement card AND
- the replacement card failing to boot AND
- the same OEM card still booting fine when reinserted.

Every "didn't boot after I swapped the SD" report I could find traces back to one of: (a) wrong-size card (>32 GB), (b) damaged donor SD, (c) didn't actually clone — just formatted and copied files (no GPT/MBR), (d) wrong card class. None match Doug's scenario where the duplicate apparently wasn't even a real card.

---

## Sources

| Source | URL | Key extract |
|---|---|---|
| DCUFix DIY Free guide v0.7 | https://dcufix.com/dcu-fix-diy-free-version/ | Card spec 16-32 GB Class 10; **change `default=logan1` to `default=logan2_backup` before imaging**; Gnome-Disks; works across cars; only failure mode is damaged donor SD |
| DCUFix Guides index | https://dcufix.com/guides/ | Lists guide titles confirming repair-kit commercialization (the kits use generic Class-10 SDs) |
| DCUFix R52 Pathfinder pre-built SD page | https://nissan.egguinox.ca/dcu-fix-pre-built-sd-card-version-version-0-2/ | "An SD Card from an Infiniti QX60 has been confirmed working in a Nissan Pathfinder; the hardware really doesn't seem to matter" |
| Infiniti Q50 Forum: 2014-2019 DCU Megathread | https://www.infinitiq50.org/threads/2014-2019-dcu-repair-megathread.140924/ | "The configuration is stored in the DCU itself, not the SD card. The SD card swap will not change any config." DCU configuration table is separate from SD, lives in DCU MTD |
| Infiniti Q50 Forum: Cloning Navigation SD card | https://www.infinitiq50.org/threads/cloning-navigation-sd-card.103505/ | DCU SD imaging procedure; `dd`/Win32DiskImager standard |
| Infiniti Q50 Forum: 2014 Q50 DCU Files | https://www.infinitiq50.org/threads/2014-q50-with-nav-dcu-files.139379/ | Shared OEM image, generic Class-10 SD card |
| Infiniti Q60 Forum: DCU SD card coding | https://www.infinitiq60.org/threads/dcu-sd-card-coding.18794/ | (Tollbit-gated) "coding" refers to DCU's separate config table, not SD card |
| Pathfindertalk R52 DCU megathread | https://www.pathfindertalk.com/threads/r52-2013-2021-pathfinder-center-screen-failure-dcu-megathread-and-fix.43995/ | DIY repair = same procedure, no special steps per-car |
| Q50 InTouch reverse-engineering thread | https://www.infinitiq50.org/threads/intouch-reverse-engineering-findings-more-to-come.137236/ | Confirms Wind River Linux 2.6.37, GCC 4.51, Atom Crossville-Lapis, DENSO ships unmodified upstream RPMs only |
| Q50 InTouch original source-code thread | https://www.infinitiq50.org/threads/parts-of-the-intouch-system-are-open-source-and-i-found-the-source-code.4545/ | DENSO Nissan OSS portal location and what's actually included |
| DENSO Nissan OSS portal | https://www.denso.com/global/en/opensource/ivi/nissan/ | Official source code releases (403s without referrer in WebFetch but the URL is canonical) |
| Bosch Nissan OSS portal | https://oss.bosch-cm.com/list/nissan | Same source code, mirrored; older releases tagged Display Audio / NissanConnect / AIVI / P-IVI3.1 |
| DENSO TEN Nissan IVI OSS source | https://www.denso-ten.com/support/source/oem/najptcu/ | Limited to Display Audio / NA & JP firmware images, OpenSSL-tier OSS only |
| Infiniti InTouch P4248-ITGEN5 Software Update Procedure v2.0 | https://www.infiniti-techinfo.com/asistgc_1/diskdocs/1/U/H/1UH7.PDF | USB-based dealer update writes both slots, no signing/blessing step |
| ELILO 3.16 upstream source (mirror) — `alternate.c` | https://github.com/NeoCui/elilo-3.16-source/blob/master/alternate.c | `EliloAlt` EFI runtime variable mechanism — one-shot alternate kernel selection, erased on read. Confirms userland-managed bootchooser primitive. |
| ELILO 3.16 upstream source — `elilo.c` | https://github.com/NeoCui/elilo-3.16-source/blob/master/elilo.c | Confirms ELILO has no automatic fallback/retry counter — bootchooser logic must be userland. |
| ELILO 3.16 upstream source — `simple.c` and `textmenu.c` | (same repo) | Confirms `alt_check` flag gates the EliloAlt read; flag set only via `-a` cmdline arg. |
| Counterfeit SD card identification | https://www.cameramemoryspeed.com/sd-memory-card-faq/reading-sd-card-cid-serial-psn-internal-numbers/ | MID 0x00 = invalid; garbled product name + low serial = counterfeit pattern |
| Counterfeit SD card identification | https://www.hugdiy.com/blog/how-to-identify-counterfeit-sd-cards-practical-diy-guide/ | Same pattern; fake cards return write-success without real persistence |
| Linux MMC mailing list (regarding zero MID) | https://www.mail-archive.com/linux-mmc@vger.kernel.org/msg17949.html | Kernel-side observation: counterfeit cards report 0x00 MID and bogus CSD |
| Barebox bootchooser docs (concept reference) | https://barebox.org/doc/latest/user/bootchooser.html | Authoritative concept doc for `remaining_attempts` + bless pattern used industry-wide |
| RAUC docs (concept reference) | https://rauc.readthedocs.io/en/latest/integration.html | A/B redundant slot integration model |
| Local artifact: `/Volumes/boot/elilo.conf` | (in-hand OEM card) | `default=logan1`, two image entries (`logan1` p2, `logan2_backup` p3), `read-only` for both, NO UUID/PARTUUID anywhere |
| Local artifact: `/Volumes/boot/CMDLINE.TXT` (probe) | (in-hand OEM card) | Live `/proc/cmdline` — confirms `root=/dev/mmcblk0p2` path-based, no identity strings |
| Local artifact: `/Volumes/boot/CID.TXT` (probe) | (in-hand OEM card) | OEM CID `02544d534530384702cdcf05a100f300` Toshiba SE08G, valid MID 0x000002 |
| Local artifact: `/Volumes/boot/Q60_INV_*/10-fs-recon.txt` | (in-hand OEM card) | `/lib/systemd/system/late-services.target.wants/sud-change-elilo.service` confirmed present, wired late in boot |
| Local artifact: `/Volumes/boot/Q60_INV_*/02b-units-all.txt` | (in-hand OEM card) | `sud-change-elilo.service  loaded inactive   dead  Change elilo.conf for` |
| Local artifact: `/Volumes/boot/Q60_PROBE_*.LOG` | (in-hand OEM card) | `/dev/mtdblock0` mounted at `/home/naviwork/data/pdm/ram` — confirms off-SD persistent state |
| Doug's `DSU backup.img` | `/Users/dpitek/DSU backup.img` | 7.21 GB byte-for-byte OEM backup — source of truth for future dd attempts |
| Existing repo doc | `docs/dcu-sd-replacement-research.md` | Prior research; this deep-dive reinforces and updates its 95%+ no-CID-lock confidence and the bootchooser theory |
| Existing repo doc | `docs/hardware-ground-truth-2026-05-16.md` | OEM card hardware ID + eMMC layout (which is actually SD, see note) |
| Existing repo doc | `docs/boot-failure-rca.md` | Independent boot-failure RCA confirming kernel-cmdline path-based root, no identity check |

---

## Caveats / unfinished business

1. **We never checked the duplicate card's md5 against the OEM image.** This is the single most diagnostic piece of evidence we're missing. If Doug still has the duplicate, plug it in, `dd if=/dev/<duplicate> of=/tmp/dup.img count=<full-size>`, and `md5 /tmp/dup.img /Users/dpitek/DSU\ backup.img`. If they differ, the card lied during writes — confirms counterfeit. If they match, the failure has to be off-card.

2. **We didn't extract `sud-change-elilo.service` itself.** The unit description was captured (`Change elilo.conf for `) but not the actual `ExecStart` script. To prove the slot-bless theory rigorously we'd need to `debugfs` Slot A and pull `/lib/systemd/system/sud-change-elilo.service` + the script it points at, then read the script. This is a future task — requires sudo on macOS, not a blocker for this verdict.

3. **No `efibootmgr -v` capture from the running DCU.** If `EliloAlt` exists at any point, it confirms userland writes that variable. Worth adding to a next probe-script revision.

4. **The 2% wildcard:** A pure CSD-class check (DCU firmware rejects cards reporting Class 4 / SDSC even if content is byte-identical) is consistent with what we saw and not directly disproven by any source. The DCUFix DIY guide spec'ing "Class 10 UHS-1" hints they may have seen this empirically. Not enough to override the simpler counterfeit-card hypothesis, but worth noting if a *real* known-good Class-4 card also fails.

5. **Wind River Linux 6 was the upstream BSP era for 2.6.37 + Intel Atom E6xx ('Crownsville-Lapis').** Confirmed via Intel ML7213/ML7223/ML7831 driver docs. Wind River published the BSP at `windriver.com/products/linux/support-maintenance`, but the actual GPL drop for *this* DENSO build would only come via the Bosch/DENSO portals listed above. The bootchooser implementation, if not pure userland scripting in `sud-change-elilo`, may have a kernel-side or initramfs-side counterpart we haven't tracked down — but not a blocker for the conclusion.

---

**Status:** Done. Verdict above. Action plan above. Confidence calibrated.

Doug's next move: buy a SanDisk Industrial 16-32 GB, verify CID looks sane before writing, dd from `DSU backup.img`, change `default=logan1` → `default=logan2_backup` in the new card's elilo.conf, install, try cold boot. If still no go, that points at off-SD state and warrants the debugfs Slot A inventory.
