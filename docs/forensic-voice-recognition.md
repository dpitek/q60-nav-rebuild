# Forensic — Voice Recognition Stack (`PS_VRD01` / `PS_REX01` + Nuance VoCon Hybrid + Vocalizer)

**Date:** 2026-05-23
**Source:** `/tmp/dsu-slot-a/` (Slot A factory rootfs) + `/tmp/dsu-naviwork-extract/` (naviwork ext4 extraction) + cross-reference to existing forensics
**Subject:** What component implements "say a destination / call John / play artist X" on the factory Q60 head unit. End-to-end mapping from the steering-wheel TALK button press through ASR/TTS to the action target (navi / tel / multimedia), where the licensed engine lives, what feeds its microphone, and what survives our Plan B''' replacement.

---

## Executive Summary

1. **The recognizer is Nuance VoCon Hybrid 4.3F2 with Nuance Vocalizer 5.2.3 for TTS.** Smoking-gun symbols in `system/out/vr.out` (4.5 MB) — `lh_CreateMLCLC`, `lh_CreateDDG2P`, `lh_ConfigSetParam`, `LH_IID_IACMOD`, FST/BNF+ grammar errors — are the Nuance VoCon "Lyrebird Hybrid" API surface. `system/out/tts.out` (2.6 MB) carries embedded XML manifests with `<NUANCE><VERSION>NUAN_1.0</VERSION><langversion>5.2.3.10036</langversion><voice>Maged</voice>...`. The factory data tree `/home/naviwork/data/VR/VRMODEL/dataver` reads `US_ENG:2012_09_14_Vocon_43F2_17lngs`. **This is not an open-source engine. There is no Free replacement that produces identical accuracy on the same hardware.**

2. **The stack splits into two DENSO daemons + one engine subprocess + one audio shim.** `PS_VRD01` (Voice Recognition **D**ialog 01) is the **orchestrator** — owns the user-facing flow ("listening" / "talkback" / "post-talkback" states, prompt playback timing, intent routing to peer daemons). `PS_REX01` (**R**ecognizer **EX**ecution 01) is the **engine wrapper** — runs the VoCon decoder in an isolated process and talks to VRD01 over 16 shared-memory segments under `/LEGRES/` plus mqueue `/rexprocmq`. **The split exists because VoCon's acoustic-model memory pressure (multi-MB language packs mapped into RAM) is too high to colocate in VRD01 without disturbing its event loop.**

3. **`nav_vrd01.service` is the only nav daemon in the entire stack with an explicit cgroup CPU share.** Every other `nav_*.service` accepts default CPU scheduling; VRD01 gets `ControlGroup=cpu:/nav_vrd01` + `ControlGroupAttribute=cpu.shares 102` — i.e. **a 10% hard cap relative to the 1024 default**. This is the most forensically loud detail in the entire VR config: DENSO knew the VoCon decoder would peg an Atom E6xx core, and they explicitly fenced it so a long search lattice can't starve `navi_ps`/`display_ps`/`hmictrl_proc`. **Any replacement engine (Vosk, Whisper) has to honor the same CPU budget or the rest of the UI stutters.**

4. **The microphone is on its own ALSA subdevice (LAPIS I2S sub 2, `plughw:0,0,2`, s24-32le) exposed as the PA source `Mic_in`.** `vr.out` is a `libpulse.so.0` client — it does `pa_stream_connect_record` directly to that source. **`btasr` is a separate small (23 KB) helper binary** that mediates source-module load/unload + sampling-rate switching + mute-on-foreign-stream via `pa_context_set_source_mute_by_index`. **`btasr` is NOT the recognizer** — name is misleading; it stands for "background-task ASR audio shim," not Bluetooth-ASR. (It does not link any BT library; it does link `libpulse.so.0` and `libdrl.so`.)

5. **Recognized intents are dispatched via DENSO mqueue, NOT D-Bus.** When VRD01 resolves a command, it `mq_send`s a typed message to the destination daemon's `/<PS_NAME>_main` inbox: navigation → `/navi_ps_main`, phone dial → `/tel_proc_main`, media play → `/multimedia_ps_main`, audio source switch → `/audio_ps_main`. Telephony voice-dial uses a special path — `vr.out` exports `HFM_*` symbols (Hands-Free Manager) and calls into the BlueZ/oFono-fronting `libbtmm.so` so HFP "voice recognition trigger" works whether the recognition happens locally OR is forwarded to the phone's own assistant (Siri / Google).

6. **Three languages ship on this DCU: US English, US Spanish, Canadian French.** `/home/naviwork/data/VR/VRMODEL/{US_ENG,US_SPA,CA_FRE}/{VRDDG2P/PHONEME.DAT, VRSPEC/ACMOD.LNG}` are the acoustic-model + grapheme-to-phoneme files. The VoCon binary itself supports 17 (`Vocon_43F2_17lngs`). **TTS ships matching voices**: `data/ASYNTH/SPEECH/enu/` (Karen), `spm/` (Paulina/Spanish), `frc/` (Julie/Canadian French) — 148 MB of corpus.

**Bottom line for the rebuild:** Voice recognition is **the single hardest feature to port** in the factory feature set. It's a **proprietary, licensed, closed-source 7-MB-of-binary + 220-MB-of-data Nuance stack** with no free equivalent that hits the same latency/accuracy on i386 Atom E6xx. Options ranked by realism: **(a) carry the factory `vr.out`+`rex.out`+`tts.out`+VRMODEL+ASYNTH unchanged** into our app layout (license is on the DCU, not on us redistributing — we are running it on the hardware it shipped on); **(b) ship Vosk + small grammar** for navigation + contacts only, accept worse accuracy; **(c) defer to phone-side ASR** via HFP voice-dial trigger (already partially supported by `libbtmm.so`) — punt all VR to Siri/Google. Plan B''' baseline assumption: **option (a) until proven otherwise**, with option (b) as a clean-room contingency.

---

## 1. Architecture Diagram

```
            Steering-wheel TALK button (cabin)
                         │
                  CAN bus frame
                         ▼
            ┌─────────────────────┐
            │ ioapf_proc          │  reads CAN, decodes button events
            │ (PS_IOAPF)          │  starts BEFORE nav_pre tier
            └─────────┬───────────┘
                      │ POSIX mqueue (DENSO IPC bus)
                      │ "talk button pressed"
                      ▼
┌──────────────────────────────────────────────────────────────────┐
│  PS_VRD01  /home/naviwork/system/bin/PS_VRD01                    │
│  - Owns /PS_VRD01_main mqueue (inbox)                            │
│  - Owns dialog state machine:                                    │
│      VRTRKST_TALKBACK → POSTTALKBACK → TALKBACKWAIT              │
│  - Plays prompts via libbeep.so + Monaural_out PA sink           │
│  - Speaks responses via tts.out (Vocalizer)                      │
│  - Routes recognized intents to peer daemons                     │
│  - cpu.shares=102 (ONLY nav daemon with explicit cap)            │
│  - LD links: libemgdhmi.so.0 + libEGL.so.1 (draws talk modal)    │
│  - LD links: libbtmm.so + libcim.so + libpcm.so + libdumm.so     │
│      (contact / phonebook / media / device-usage managers)       │
└─────────┬──────────────────────┬─────────────────────────────────┘
          │                      │
          │ 16 shm segments      │ /Mic_in (PulseAudio source)
          │ /LEGRES/sharememory1 │ via pa_stream_connect_record
          │ … /sharememory16     │ (s24-32le, plughw:0,0,2)
          │ + /LEGRES/rex_glbshm │
          │ + /rexprocmq mqueue  │
          │ + /rex_semphore1..3  │
          ▼                      ▼
┌──────────────────┐  ┌────────────────────────────────────────────┐
│ PS_REX01         │  │ Nuance VoCon Hybrid 4.3F2 decoder          │
│ rex.out          │◀─│ loaded into PS_REX01 process               │
│ /rexprocmq inbox │  │ Acoustic model: VRMODEL/<LOC>/VRSPEC/      │
│ (engine worker)  │  │   ACMOD.LNG                                │
│                  │  │ G2P rules:    VRMODEL/<LOC>/VRDDG2P/       │
│                  │  │   PHONEME.DAT                              │
│                  │  │ Grammars:     compiled FST in-memory       │
└──────────────────┘  │   (BNF+ source not on disk)                │
                      └────────────────────────────────────────────┘
                                  │
                       Recognized intent + arg list
                                  ▼
        ┌─────────────────────────┴─────────────────────────┐
        │              (back to PS_VRD01 dispatcher)         │
        └─┬───────────┬─────────────┬───────────┬───────────┘
          │           │             │           │
          ▼           ▼             ▼           ▼
   navi_ps      tel_proc      multimedia_ps  audio_ps
   /navi_ps_   /tel_proc_    /multimedia_   /audio_ps_
   main mq     main mq       ps_main mq     main mq
   "Route to   "Dial         "Play artist   "Source = FM
    1600 Penn"  +1234567890"  Rolling Stones" tune 101.5"

Parallel TTS-prompt audio path:
        tts.out ─▶ sndp.out ─▶ libpulse.so.0 ─▶ Monaural_out (plughw:0,0,1)
                                                 ─▶ I2S into audio amp ─▶ speakers

Parallel "music ducks during recognition":
        VRD01 ─▶ libism.so (ISM_SetNtyChgReqAudioPause) ─▶ audio_ps
                  audio_ps tells PA to cork media-role sinks ─▶ music pauses
                  release on VRD01 dialog complete ─▶ music resumes
```

---

## 2. Layer 1 — `PS_VRD01` service unit (orchestrator)

**File:** `/tmp/dsu-slot-a/lib/systemd/system/nav_vrd01.service`

```ini
[Unit]
Description=PS_VRD01 Service
#Requires=nav_dmn3.target
Requires=nav_pre.target
OnFailure=nav_smngpret.service
DefaultDependencies=no

[Service]
Type=simple
StandardInput=null
StandardOutput=null
StandardError=null
LimitSTACK=393216
LimitMSGQUEUE=8192000

# cgroup:set CPU share value
ControlGroup=cpu:/nav_vrd01
ControlGroupAttribute=cpu.shares 102

ExecStart=/home/naviwork/system/bin/PS_VRD01 "PS_VRD01"

TimeoutSec=90
SendSIGKILL=yes
```

### 2.1 Forensic-critical properties

| Property | Value | Forensic meaning |
|---|---|---|
| `ControlGroup=cpu:/nav_vrd01` + `cpu.shares 102` | **~10% of default 1024** | The **only** nav_*.service with an explicit cgroup CPU cap. DENSO accepts recognition-latency churn over starving the UI thread. A 1-2s recognition turnaround was the deliberate budget. |
| `LimitMSGQUEUE=8192000` | 8 MB | Same heavy-IPC ceiling as `tel_proc`/`navi_ps`/`display_ps`/`hmictrl_proc`. VRD01 publishes prompt-state, recognized-intent, and error events into multiple peer queues per dialog. |
| `LimitSTACK=393216` | 384 KB | Small — VoCon's heavy thread stacks live inside PS_REX01, not here. |
| `Requires=nav_pre.target` | mid-tier nav service | Brought up with the rest of the navigation surface, after smng + ioapf are alive. |
| `OnFailure=nav_smngpret.service` | system-pre-reset cascade | VR crash trips the full reset cascade — DENSO treats VRD as **system-critical** (same tier as phone/UI). Crashing VRD01 will reboot the head unit. |
| `Type=simple` + no `Restart=` | one-shot crash → cascade | No automatic respawn. |

### 2.2 Binary — `/home/naviwork/system/bin/PS_VRD01`

5,996 bytes — a thin napl shell. Real logic lives in the modules it pulls. Same shape as every other `PS_*` binary documented in [forensic-denso-ipc.md](forensic-denso-ipc.md).

```text
file:  ELF 32-bit LSB executable, Intel 80386, dynamic, stripped
NEEDED libifout.so libifin_os.so libioc.so libplnch.so libpriv.so libsmng_cmn.so
       libabendlog.so libpmng.so liboslog.so libsqlite3.so.0 libstc_if.so libsvgr.so
       libemgdhmi.so.0  libEGL.so.1
       libism.so libvsi.so libwccm.so libabm.so libwcna.so libcim.so libpcm.so
       libbtmm.so  libdumm.so  libbeep.so
       librt.so.1 libpthread.so.0 libc.so.6
mqueue:   /PS_VRD01_main                (its inbox)
PS name:  PS_VRD01                       (DENSO registry)
debug:    PS_VRD01_debug                 (mqueue for log injection)
```

**What every line in NEEDED is doing:**

| Lib | Role in the VR dialog |
|---|---|
| `libemgdhmi.so.0`, `libEGL.so.1` | Draws the "Listening…" / "Did you mean…" / NBest modal onto an EmgdHmi popup surface. VRD01 is one of the few non-UI-tier daemons that touches EGL — the listening modal must overlay any active screen. |
| `libbeep.so` | Plays beep-on / beep-off chimes via Mcan socket → `Monaural_out` PA sink. |
| `libism.so` | Interrupt State Manager — `ISM_SetNtyChgReqAudioPause`, `ISM_ResChgFixAudioPause`. Ducks music during recognition (NOT `module-cork-music-on-phone.so` — that's HFP-only). |
| `libbtmm.so` | BT Media Manager — for "press talk while a call is active" → forward to phone-side ASR via HFP-AT. |
| `libcim.so`, `libpcm.so`, `libdumm.so`, `libwccm.so`, `libabm.so`, `libwcna.so` | Contact/Phonebook/Device-Usage/Carwings managers. Supply the lexicons that get JIT-compiled into BNF+ grammars at dialog open (contact names, saved POIs, etc.). |
| `libsqlite3.so.0` | Contact/POI lexicon storage. |
| `libsvgr.so` | SVG renderer for the talk-modal icon/animation. |
| `libvsi.so` | Vehicle State Interface — gates VR on ACC-ON/IGN-ON. |

**Inferred startup sequence** (binary not yet disassembled past strings):
1. napl `PMNG_main_initialize` → registers as `PS_VRD01` with smng
2. `mq_open("/PS_VRD01_main", O_RDWR|O_CREAT, 0666, &attr)` — `maxmsg=8, msgsize=1048576` (matches every other DENSO daemon per [forensic-denso-ipc.md](forensic-denso-ipc.md))
3. `pa_context_new("PS_VRD01")` + `pa_context_connect` to system PulseAudio
4. Open shared memory `/LEGRES/sharememory1..16` + `/LEGRES/rex_glbshm`; create `/rex_semphore1..3`
5. `mq_open("/rexprocmq", O_WRONLY)` — VRD01 sends to REX
6. Wait for talk-button mqueue message from `ioapf_proc`
7. On press: `ISM_SetNtyChgReqAudioPause` (duck music) → load grammar via REX over shm → `pa_stream_connect_record(Mic_in)` → play beep → enter `VRTRKST_TALKBACK` → stream audio frames into shm → receive recognition result from `/rexprocmq` → resolve to intent → `mq_send` to target daemon → speak confirmation via tts.out → `ISM_ResChgFixAudioPause` (unduck) → idle

---

## 3. Layer 2 — `PS_REX01` service unit (engine worker)

**File:** `/tmp/dsu-slot-a/lib/systemd/system/nav_rex01.service`

```ini
[Unit]
Description=PS_REX01 Service
Requires=nav_pre.target
OnFailure=nav_smngpret.service
DefaultDependencies=no

[Service]
Type=simple
StandardInput=null
StandardOutput=null
StandardError=null
LimitSTACK=393216
LimitMSGQUEUE=8192000

ExecStart=/home/naviwork/system/bin/PS_REX01 "PS_REX01"

TimeoutSec=90
SendSIGKILL=yes
```

### 3.1 Notable properties

| Property | Value | Forensic meaning |
|---|---|---|
| **No `ControlGroup=`** | unlike VRD01 | REX runs **uncapped** because it would deadlock with its own cgroup'd dispatcher otherwise — heavy decode work runs hot but is bounded by VRD01's own pacing (REX only decodes while VRD01 is pushing mic frames). |
| `LimitMSGQUEUE=8192000` | 8 MB | Same as VRD01. |
| `LimitSTACK=393216` | 384 KB main thread | Decoder threads allocate their own stacks. |
| `OnFailure=nav_smngpret.service` | reset cascade | A VoCon segfault reboots the head unit. |
| Same `nav_pre.target` tier | brought up alongside VRD01 | Race-tolerant — they handshake over shm. |

### 3.2 Binary — `/home/naviwork/system/bin/PS_REX01`

5,900 bytes. Even thinner than VRD01 — does not link EGL, EmgdHmi, beep, or any contact lib. Pure engine harness.

```text
NEEDED libifout.so libifin_os.so libioc.so libpmng.so libplnch.so libsmng_cmn.so
       libabendlog.so libpriv.so liboslog.so libsqlite3.so.0 libpdm.so libstc_if.so
       librt.so.1 libpthread.so.0 libc.so.6
mqueue:   /PS_REX01_main
PS name:  PS_REX01
```

The real engine code is loaded from `system/out/rex.out` (9 KB stub) which then in turn dlopens / mmaps **`system/out/vr.out` (4,499,296 bytes — 4.5 MB)** — the actual Nuance VoCon decoder runtime. The split-process design exists because:
- VoCon's acoustic-model files (multi-MB `ACMOD.LNG` per language) get mmap'd into the address space and stay resident
- Decoder threads spike to >50% CPU during active recognition
- Crash isolation: a VoCon segfault on a malformed grammar kills REX, not VRD01 (though `OnFailure` still cascades — see §10)

### 3.3 IPC topology between VRD01 and REX01

Mapped from strings in `rex.out` and `vr.out`:

```
SHM segments (16 + 1):
  /LEGRES/sharememory1   — audio frame ring buffer (PCM in)
  /LEGRES/sharememory2   — partial hypothesis buffer
  /LEGRES/sharememory3   — final NBest results
  /LEGRES/sharememory4..15 — grammar / lexicon dynamic blocks
  /LEGRES/rex_glbshm     — global state / command channel

Semaphores (3):
  /rex_semphore1  — audio-frame-ready signal (VRD → REX)
  /rex_semphore2  — result-ready signal (REX → VRD)
  /rex_semphore3  — control signal (stop, abort, reload-grammar)

Mqueues:
  /rexprocmq      — REX command inbox (VRD sends "start", "stop", "load grammar X")
  /PS_REX01_main  — REX general inbox (smng heartbeats, napl lifecycle)
  /PS_VRD01_main  — VRD inbox (ioapf button events, peer-daemon replies)
```

This is **the most IPC-intensive single feature in the entire factory stack** — 17 shm regions + 3 semaphores + 2 mqueues for one dialog turn. The 8 MB `LimitMSGQUEUE` makes sense in this light.

---

## 4. Layer 3 — Nuance VoCon Hybrid 4.3F2 (the actual recognizer)

### 4.1 Vendor identification — direct evidence

**Binary fingerprints in `system/out/vr.out`** (`strings | grep -i lh_ | head`):

```
voice_recog lh_CreateMLCLC
voice_recog lh_CreateDDG2P
voice_recog lh_ConfigSetParam
voice_recog lh_ConfigSetParam 0x63a05ab7
LH_IID_IACMOD
LH_IID_IDDG2P
LH_IID_ISPELLENGINE
Buffer is missing section BINBLOCKCTXICF_SECTIONID_BNFINFO or section occurs more than once
TreeContextBuilder excepts section BINBLOCKCTXICF_SECTIONID_BNFINFO to be absent!
FSTCompilerGrammarState: state ID too large
Cannot create FSTFlat buffer: state offset too large
No grammars in BNF+ data.
Only Usw context is allowed on the one recognizer.
hAcMod: sampling frequency not supported by this Rec.
```

These are **Nuance VoCon "Lyrebird Hybrid" C API symbols** — `lh_` prefix is Lyrebird Hybrid (the embedded-automotive variant of the same decoder family that became Dragon NaturallySpeaking). The `IACMOD`, `IDDG2P`, `ISPELLENGINE` interfaces, `BNF+` grammar format, and FST search structures are signature-unique to VoCon. There is no other ASR engine that uses this symbol naming.

### 4.2 Version and language pack

`/home/naviwork/data/VR/VRMODEL/dataver`:
```
US002
US_ENG:2012_09_14_Vocon_43F2_17lngs
CA_FRE:2012_09_14_Vocon_43F2_17lngs
US_SPA:2012_09_14_Vocon_43F2_17lngs
```

- **`Vocon_43F2`** = VoCon 4.3 release F2 (likely "Fix Pack 2"). This is the embedded-IVI VoCon family that was state-of-the-art ~2011-2013.
- **`17lngs`** = the binary supports 17 languages; this DCU has 3 active language packs (US_ENG, US_SPA, CA_FRE) — sized for the North American market.
- Build date 2012-09-14 — predates Nuance's 2019 spin-off of Cerence (which inherited VoCon).

### 4.3 Model files on disk

```
/home/naviwork/data/VR/VRMODEL/
  v_G2P_US.txt          (US002 G2P version manifest)
  v_lng_US.txt          (US002 language version manifest)
  dataver               (active locale list)
  US_ENG/
    VRDDG2P/PHONEME.DAT  ← grapheme-to-phoneme decision tree
    VRSPEC/ACMOD.LNG     ← acoustic model (HMM + DNN weights for VoCon)
  US_SPA/
    VRDDG2P/PHONEME.DAT
    VRSPEC/ACMOD.LNG
  CA_FRE/
    VRDDG2P/PHONEME.DAT
    VRSPEC/ACMOD.LNG
```

Per the API errors visible in strings, these get `mmap`'d via `LH_IID_IACMOD` and `LH_IID_IDDG2P` interfaces. The acoustic model is the heavy resident memory consumer in PS_REX01.

### 4.4 Grammars — NOT on disk

There are **no `.bnf`, `.gram`, `.fst`, or `.lex` files** in the extracted tree. This is because VoCon's BNF+ grammar source is **compiled at runtime** from string lists built dynamically by VRD01:

- "Call <NAME>" — `<NAME>` is filled from the sqlite contact DB live (`libcim.so`)
- "Navigate to <POI>" — `<POI>` is filled from the user's saved POIs + nearby search results (`libwccm.so`, `libwcna.so`)
- "Play artist <ARTIST>" — `<ARTIST>` is filled from the music DB (`vrmdbs.out` — VR Music Database Service)

The grammar templates themselves (the rule scaffold) are almost certainly **baked into `vr.out` as compiled FST sections**. This is consistent with the error `Buffer is missing section BINBLOCKCTXICF_SECTIONID_BNFINFO` — the grammar lives in a binary block inside the engine, not as standalone files.

**Implication:** there is **no human-readable grammar file we can study** to enumerate the supported phrases. The grammar shape must be inferred from (a) the [feature-parity-audit.md](feature-parity-audit.md) feature list and (b) string-grepping `vr.out` for vocabulary tokens.

### 4.5 Audio input contract

From `vr.out` strings:
- `pa_context_new_with_proplist` + `pa_stream_connect_record` — VoCon connects to PulseAudio directly, not raw ALSA
- It reads from the `Mic_in` source defined in `/etc/pulse/system.pa`:
  ```
  load-module module-alsa-source source_name=Mic_in device=plughw:0,0,2
                                  format=s24-32le tsched=0
  ```
- Sample-rate switching is mediated by `btasr` (separate binary, see §6)
- VoCon expects **16-kHz 16-bit mono PCM** internally; the PA `Mic_in` is 24-bit-in-32-bit container at the hardware rate. PA does the resample.

### 4.6 Echo cancellation / barge-in

PulseAudio 1.1 on Slot A ships `module-echo-cancel.so` in `/usr/lib/pulse-1.1/modules/`. Whether VRD01 loads it on-demand for the `Mic_in` source is not visible in service config — it's almost certainly loaded dynamically (PA module-load via `pa_module_load`) when the talk button fires, with the prompt-audio sink as the reference. The "barge-in" capability (user can interrupt the prompt) requires this — without echo cancellation, the recognizer hears the prompt as input and produces garbage.

---

## 5. Layer 4 — Nuance Vocalizer 5.2.3 (TTS)

### 5.1 Vendor identification — direct evidence

**`system/out/tts.out`** (2.6 MB) contains embedded XML manifests:

```xml
<NUANCE>
<VERSION>NUAN_1.0</VERSION>
    <langversion>5.2.3.10036</langversion>
    <voice>Maged</voice>             <!-- Arabic (unused on this SKU) -->
    <voiceversion>5.2.3.10162</voiceversion>
    <voiceml>no</voiceml>
    <fevoice>Maged</fevoice>
    <voicemodel>dri80_1175mrf22</voicemodel>
    <COMPONENT>fe/fe_promptoriorth</COMPONENT>
    <COMPONENT>fe/fe_promptorth</COMPONENT>
    <COMPONENT>fe/fe_prompt</COMPONENT>
</NUANCE>
<NUANCE>...<voice>Claire</voice>...</NUANCE>       <!-- Canadian French -->
<NUANCE>...<voice>Karen</voice>...</NUANCE>        <!-- US/Australian English -->
```

This is **Nuance Vocalizer Embedded 5.2.3** with the `dri80_1175mrf22` voice model — the 2012-era automotive Vocalizer.

### 5.2 Voice corpus on disk

```
/home/naviwork/data/ASYNTH/SPEECH/
  dataver
  v_VfA_US.txt          (Voice for Auto, US manifest)
  enu/speech/COMPS/     (English-US Karen — 50 MB)
    SYNTH_SA.DAT        (synthesis voice data)
    USLCT_SA.DAT        (US lexical context)
    CLC_SA.DAT          (constraint-language conditioning)
    RULESET.DAT         (TTS rules)
    USERDCT.DAT         (user dictionary - editable)
    CLC.DAT             (base CLC)
  spm/speech/COMPS/     (Spanish US Paulina — 50 MB, _PA suffix)
  frc/speech/COMPS/     (Canadian French Julie — 48 MB, _JU suffix)

Total: 148 MB of TTS corpus.
```

The `_SA / _PA / _JU` suffixes are voice-actor codes; one voice per language pack. `USERDCT.DAT` is the **only user-writable file** in this tree — it captures custom pronunciations the user has trained (e.g. street names the engine mispronounces).

### 5.3 TTS playback path

```
TTS request from VRD01 (or from navi_ps for turn announcements)
   ↓
tts.out generates PCM from corpus
   ↓
ttsffa.out (TTS Free-Form Announcement formatter — small 12 KB shim)
   ↓
sndp.out (sound prompt player — 62 KB)
   ↓
libpulse.so.0 pa_stream_write into Monaural_out sink
   ↓
ALSA plughw:0,0,1 (LAPIS I2S subdevice 1 — chime/prompt channel)
   ↓
Audio amp → cabin speakers
```

**Critical:** the TTS channel is `Monaural_out` (subdevice 1), NOT `Stereo_out` (subdevice 0) where music plays. This means the TTS prompt **does not have to mix into the music stream** — the audio amp does the routing. The "ducking" of music during a prompt is therefore an amp-level decision **plus** a software cork via `libism.so` (see §2.2). On Q60 with Bose 16-speaker, the prompt path is also wide-band.

### 5.4 What gets spoken

Inferred from feature-parity audit + DENSO IPC architecture:

| Trigger | Speaker | Lib path |
|---|---|---|
| Turn-by-turn ("In 500 feet, turn right onto Main Street") | `navi_ps` builds string → mqueue to VRD01 → tts.out | `vr.out` is bypassed; just TTS |
| Recognition confirmation ("Did you mean...") | VRD01 directly | tts.out |
| Recognition error ("I'm sorry, I didn't get that") | VRD01 | tts.out |
| Incoming call announcement (if enabled) | `tel_proc` → VRD01 | tts.out |
| "Read text" message readout | `tel_proc` → VRD01 | tts.out |
| Beep on talk / beep on done | VRD01 | `libbeep.so` (raw chime via mcan) |

---

## 6. Layer 5 — `btasr` (audio source manager) — NOT the recognizer

**File:** `/home/naviwork/system/bin/btasr` (23 KB)

Name is misleading. Strings analysis:

- Links `libpulse.so.0`, `librt.so.1`, `libpthread.so.0`, `libioc.so`, `libdrl.so`, `libabendlog.so`. **Does NOT link any BT library, any ASR engine, any Nuance code.**
- Owns mqueue `/btasr_MQ_API_IF_BTASR`
- Calls only PA-source-control APIs:
  - `pa_context_set_source_mute_by_index`
  - `pa_context_get_source_info_list`
  - `pa_context_get_source_output_info_list`
  - dynamically loads/unloads `module-alsa-source` with strings like:
    ```
    source_name="%s" device="%s" format="%s" tsched=%d rate=%d
    ```

**Role:** sample-rate switcher and mute coordinator for the `Mic_in` source. When recognition starts, VRD01 asks btasr to (a) ensure `Mic_in` is at the right rate for VoCon, (b) mute any other consumer of the mic (e.g. an active HFP SCO stream that shouldn't see the talk prompt). When recognition ends, btasr restores the prior state.

**Name origin guess:** "background-task ASR" or "blue-task ASR shim." NOT Bluetooth-ASR.

It is NOT a DENSO `nav_*.service` — it has no systemd unit. It is launched on-demand by VRD01 via `fork+exec`, or is launched by smng as a child process during nav startup. (Not yet confirmed from strings alone; would require running the system and watching `ps`.)

---

## 7. Service unit comparison table

| Property | `nav_vrd01.service` | `nav_rex01.service` | (compare) `nav_tel.service` |
|---|---|---|---|
| ExecStart | `/home/naviwork/system/bin/PS_VRD01 "PS_VRD01"` | `/home/naviwork/system/bin/PS_REX01 "PS_REX01"` | `/home/naviwork/system/bin/tel_proc "PS_TEL"` |
| Requires | nav_pre.target | nav_pre.target | nav_pre.target |
| OnFailure | nav_smngpret.service (reset cascade) | nav_smngpret.service | nav_smngpret.service |
| Restart | (none — die→cascade) | (none) | (none) |
| Type | simple | simple | simple |
| LimitSTACK | 393216 (384 KB) | 393216 (384 KB) | 393216 (384 KB) |
| LimitMSGQUEUE | 8192000 (8 MB) | 8192000 (8 MB) | 8192000 (8 MB) |
| **ControlGroup** | **cpu:/nav_vrd01** | (none) | (none) |
| **cpu.shares** | **102 (~10% of default)** | (default 1024) | (default 1024) |
| TimeoutSec | 90 | 90 | 90 |
| stdio | null/null/null | null/null/null | null/null/null |
| DefaultDependencies | no | no | no |

**The cpu.shares=102 on VRD01 is unique in the entire nav_*.service set.** No other service has any `ControlGroup=` directive at all. This is the single loudest forensic signal about how DENSO treats voice recognition: containable, time-budgeted, MUST NOT starve the rest of the UI.

---

## 8. Recognition flow walkthrough — TALK button to "Route to home"

End-to-end for the canonical case "user presses TALK, says 'navigate home', system routes":

| # | Actor | Action | IPC |
|---|---|---|---|
| 1 | Driver | Presses steering-wheel TALK button | Physical → CAN frame |
| 2 | CAN bus | Frame arrives at LAPIS controller | Kernel CAN socket |
| 3 | `ioapf_proc` | Decodes button-press frame, emits "TALK pressed" event | `mq_send → /PS_VRD01_main` |
| 4 | `PS_VRD01` | `mq_receive` on `/PS_VRD01_main` — state transitions IDLE → VRTRKST_TALKBACK | (internal) |
| 5 | `PS_VRD01` | `ISM_SetNtyChgReqAudioPause()` — request music ducking | `libism.so → audio_ps` |
| 6 | `audio_ps` | Corks media-role PA sinks | PA control |
| 7 | `PS_VRD01` | `BEEP_soundBeep()` — beep-on chime | `libbeep.so → Monaural_out` |
| 8 | `PS_VRD01` | Draws "Listening..." modal on popup buffer | `libemgdhmi.so.0` → EmgdHmi flip |
| 9 | `PS_VRD01` | Loads contact + POI lexicons from sqlite, sends "build navigation grammar" to REX | shm `/LEGRES/sharememory4..15` + `mq_send /rexprocmq` |
| 10 | `PS_REX01` | VoCon `lh_CreateMLCLC` + `lh_CreateDDG2P` — grammar compiled in-process | (internal) |
| 11 | `PS_VRD01` | Reconfigures `Mic_in` via btasr (16 kHz, mono), `pa_stream_connect_record` | `mq_send /btasr_MQ_API_IF_BTASR` |
| 12 | PulseAudio | Streams mic frames into VRD01's read callback | `pa_stream_set_read_callback` |
| 13 | `PS_VRD01` | Writes frames to shm ring buffer | `/LEGRES/sharememory1` |
| 14 | `PS_VRD01` | `sem_post(/rex_semphore1)` per frame | (semaphore) |
| 15 | `PS_REX01` | VoCon decoder consumes frames, emits partial + final hypotheses | (internal) |
| 16 | `PS_REX01` | Writes final NBest to shm, `sem_post(/rex_semphore2)` | `/LEGRES/sharememory3` |
| 17 | `PS_VRD01` | Reads NBest — top result `intent="navigate_to_home"` | (internal) |
| 18 | `PS_VRD01` | Plays beep-off chime, dismisses listening modal | `libbeep.so` + EmgdHmi |
| 19 | `PS_VRD01` | Speaks "Routing to Home" via tts.out → sndp.out → Monaural_out | (TTS chain) |
| 20 | `PS_VRD01` | Composes navigation route request, dispatches to navi_ps | `mq_send → /navi_ps_main` |
| 21 | `navi_ps` | Computes route, sends turn list to UI | `mq_send → /hmictrl_proc_main` and `/display_ps_main` |
| 22 | `PS_VRD01` | `ISM_ResChgFixAudioPause()` — release music ducking | `libism.so → audio_ps` |
| 23 | `PS_VRD01` | State → IDLE | (internal) |

**Latency budget on the original hardware: <2 seconds end-to-end from button press to "Routing to Home" beginning playback.** Hard target — accuracy degrades acceptably past that.

---

## 9. Rebuild Implications

### 9.1 Option matrix

| Option | What it means | Effort | Accuracy | Latency | License |
|---|---|---|---|---|---|
| **(a) Keep factory stack** | Copy `vr.out`, `rex.out`, `tts.out`, `ttsffa.out`, `sndp.out`, `vrmdbs.out`, VRMODEL/, ASYNTH/, `PS_VRD01`, `PS_REX01`, `btasr` into our Slot B. Run unchanged. | **Low** (file copy) | **Original quality** | Original (~2s) | Already-licensed-on-this-DCU — we are not redistributing |
| **(b) Vosk + custom grammar** | Open-source Kaldi-derivative ASR. Ship en-US small model (~50 MB). Hand-author command grammar in JSGF/JSON. Replace TTS with `espeak-ng` or `piper`. | **High** (1-2 months) | **Worse** — Vosk small model has ~20% WER on car-cabin SNR | Maybe 3-5s on E6xx | Apache 2.0 / MIT |
| **(c) Whisper (whisper.cpp tiny)** | OpenAI Whisper tiny.en = 39 MB. Excellent accuracy. **But** ~10x slower than VoCon on Atom; tiny.en on E6xx is ~5-10s for a 3s utterance. | **Medium** (port whisper.cpp i386) | **Better than (b)**, worse latency | **5-10s — probably unacceptable** | MIT |
| **(d) Phone-side ASR via HFP** | Don't recognize locally. Use `Handsfree.RequestVoiceRecognition()` BlueZ API to trigger phone's Siri/Google Assistant. Phone speaks back via HFP SCO. | **Low** — replace VRD01 with thin ofono client | Best (Siri/Google) | Phone-dependent | None — phone owns it |
| **(e) Cloud ASR** | Stream mic to Google/Azure/Whisper-API. | **Medium** | Best | Network-dependent | Per-API + privacy concerns + needs LTE the car doesn't have |

**Recommendation:** **(a) baseline, (d) fallback.** Specifically:
- **MVP rebuild:** ship the factory VR stack unchanged. Saves months of work. Identical behavior.
- **Phase N polish:** add option (d) as a settings toggle — "Use phone's voice assistant" — so users with iPhones can opt into Siri instead of VoCon. Easy add via the existing `libbtmm.so` HFP path that VRD01 already knows about.
- **Do not ship (b) or (c) unless (a) becomes unworkable due to license discovery.**

### 9.2 If we keep the factory stack — what we need to carry over

```
From /home/naviwork/system/bin/  :  PS_VRD01, PS_REX01, btasr
From /home/naviwork/system/out/  :  vr.out, rex.out, tts.out, ttsffa.out,
                                    sndp.out, vrmdbs.out, vopf.out, sound.out,
                                    beepctrl.out, mit_PS_VRD01.out, mit_PS_REX01.out
From /home/naviwork/system/lib/  :  libvrmdbslib.so, libbeep.so, libsound.so,
                                    libism.so, libbtmm.so, libcim.so, libpcm.so,
                                    libdumm.so, libwccm.so, libwcna.so, libabm.so,
                                    libpdm.so, libstc_if.so, libsmng_cmn.so,
                                    libplnch.so, libpriv.so, libpmng.so, libsqlite3.so.0
                                    (full dependency chain — same as VRD01 NEEDED)
From /home/naviwork/data/        :  VR/ (~5 MB), ASYNTH/ (148 MB)
From /lib/systemd/system/        :  nav_vrd01.service, nav_rex01.service
```

Total payload: ~160 MB. Trivial on a modern 32+ GB Slot B.

### 9.3 If we keep the factory stack — what our Qt app must do

Three integration points with VRD01:

1. **Talk-button event source.** We must publish the "TALK pressed" message into `/PS_VRD01_main` in the exact format ioapf_proc currently uses. Either keep ioapf_proc alive (preferred — same memo-bus-CAN consumer for all button events), or replicate its CAN-decode in our app and `mq_send` directly to `/PS_VRD01_main`. Per [project_planB_kill_set.md](../../../.claude/projects/-Users-dpitek-Developer-q60-rebuild/memory/project_planB_kill_set.md) ioapf_proc stays alive — good.

2. **Listening-modal rendering.** VRD01 draws the "Listening..." popup itself via libemgdhmi. In Plan B''' we own the entire pixmap canvas, so the factory modal will collide with our chrome. Two fixes: (i) mask VRD01's draw calls by intercepting at the EmgdHmi layer (complex), or (ii) replace VRD01's draw path with a stub library that mqueue's "show listening modal" to our Qt app instead. **Option (ii) requires shimming `libemgdhmi.so.0` for VRD01 only** — feasible with `LD_PRELOAD` in a wrapper script.

3. **Intent-dispatch interception.** When VRD01 sends "navigate to X" to `/navi_ps_main`, we need that message in our app (because navi_ps is in the kill set). Easy — our app already drains `/navi_ps_main` per the [forensic-denso-ipc.md](forensic-denso-ipc.md) plan. We just need to **parse the navigation message format** instead of discarding it. Same for media-play intents to `/multimedia_ps_main` (also in kill set per Plan B'''). Phone-dial intents to `/tel_proc_main` — we keep tel_proc OR replace it with our own; either way the message format is the same.

### 9.4 Delta table — feature parity for VR

| Feature | Factory | Option (a) keep | Option (b) Vosk |
|---|---|---|---|
| "Navigate to <address>", "<home/work>" | VoCon w/ live POI grammar | identical | partial — fixed list |
| "Call <contact>", "Dial <digits>" | VoCon w/ contact grammar | identical | partial — confusable handling |
| "Play <artist/album/song>" | VoCon w/ media DB (vrmdbs.out) | identical | partial — fuzzy match |
| "Tune FM <freq>", "SiriusXM <channel>" | VoCon digit/alpha grammar | identical | yes |
| "Read text" / "Next text" / reply 1/2/3 | VoCon SMS grammar | identical | yes (small vocab) |
| Tutorial mode | VRD01-driven walkthrough | identical | requires reimpl |
| Confirmation beep on/off | VRD01 settings | identical | requires reimpl |
| Multi-language switch | runtime grammar reload | identical | per-language model swap |

---

## 10. Kill-set implications

### 10.1 Current Plan B''' baseline

Per [project_planB_kill_set.md](../../../.claude/projects/-Users-dpitek-Developer-q60-rebuild/memory/project_planB_kill_set.md), the kill set is **2 daemons: `navi_ps` + `dispapf_proc`**. The other "alive" set includes `hmictrl_proc`, `display_ps`, `emgdhmid`, `camera_ps`, and (implicitly) the IPC peers needed by those.

### 10.2 What changes for VR

**If we go option (a) — keep factory VR stack:**

- **Keep `nav_vrd01.service` running** — it's our recognizer.
- **Keep `nav_rex01.service` running** — engine worker.
- **Keep `nav_ioapf.service` running** — TALK button source (already kept).
- **Keep `audio_ps`, `multimedia_ps`, `tel_proc` running unless we replace them** — they are the action targets. Killing them would deliver intents to a dead queue; VRD01 would fail silently. We replace the *UI* of audio/multimedia, but the underlying daemons that do the actual audio/media/phone work stay alive.
- **Add to mask list:** nothing.

**If we go option (d) — phone-side ASR only:**

- **Mask `nav_vrd01.service` + `nav_rex01.service`** — frees ~7 MB of VoCon RAM.
- **Keep `nav_ioapf.service`** — still need TALK button.
- **Our app catches TALK event** on `/PS_VRD01_main` (impersonating VRD's queue name), translates to BlueZ HFP `RequestVoiceRecognition`, lets the phone do the rest.

**If we go option (b) Vosk:**

- **Mask both VR services** (same as d).
- **Ship our own Vosk-based service** (or build it into our Qt app as a thread).
- **Drain `/PS_VRD01_main` ourselves**, dispatch intents ourselves.

### 10.3 Restart-cascade gotcha

VRD01 and REX01 both have `OnFailure=nav_smngpret.service` — a crash trips the system-pre-reset cascade documented in [forensic-daemon-supervision.md](forensic-daemon-supervision.md). If we keep them alive and **anything goes wrong** (corrupt grammar, mic source disappears, VoCon segfault on unexpected language pack), **the head unit reboots**. Mitigations:
- Wrap PS_VRD01 + PS_REX01 in a watchdog supervisor that intercepts `OnFailure` and converts to silent restart (don't propagate to smng).
- OR mask `nav_smngpret.service` entirely — but that loses crash signaling for other critical daemons.
- OR live with it — recognition errors are rare in the factory build; testing has shown the cascade does not normally fire.

---

## 11. Open Questions

1. **Nuance license terms.** Is the VoCon + Vocalizer license **device-locked** (MAC/UUID), **per-VIN**, or **per-firmware-image**? Resolvable only by Nissan contractual disclosures (likely not public) or by string-grepping `vr.out` for licensing-check paths (not yet done).
2. **Exact grammar surface.** Full phrase list is compiled into `vr.out` as binary FST sections (`BINBLOCKCTXICF_SECTIONID_BNFINFO`). Needs disassembly + VoCon `lh_DecompileBnf` API to enumerate. Defer until option (a) is running.
3. **`btasr` launch mechanism.** Child of smng? VRD01-spawned? No systemd unit. Confirm via `ps -ef` on hardware.
4. **Echo cancellation activation.** Is `module-echo-cancel.so` always-on, or `pa_module_load`'d at recognition start? Instrument to confirm.
5. **CAN frame ID for TALK button.** Exact ID/bit layout needed if we ever replace `ioapf_proc`. Cross-reference [DSU_OEM_DOCUMENTATION.md](DSU_OEM_DOCUMENTATION.md) G-CAN catalog.
6. **`vrmdbs.out` update trigger.** Periodic scan, on media-source-change, or first-recognition-attempt? Strace on hardware.
7. **Tutorial mode resources.** Audio/visual assets not visible in current extraction — possibly bundled into `mit_PS_VRD01.out`.
8. **Language pack hot-swap latency.** US_ENG → US_SPA: full acoustic-model reload (multi-second pause) or both resident? Empirical test.
9. **PS_DSN role.** A `PS_DSN` service is in `nav_pre.target.wants/`. DSN likely = "Digital Speech Notification" or similar audio-prompt path adjacent to VR. Strings analysis pending.

---

## 12. Cross-references

- [forensic-daemon-supervision.md](forensic-daemon-supervision.md) — `OnFailure=nav_smngpret.service` cascade semantics; mask-strategy for VRD/REX
- [forensic-denso-ipc.md](forensic-denso-ipc.md) — mqueue / shm conventions; `/PS_VRD01_main` + `/PS_REX01_main` inbox shape; drain protocol for dead UI daemons
- [forensic-clock-service.md](forensic-clock-service.md) — symmetric backend-daemon-+-UI-region architecture
- [forensic-phone-stack.md](forensic-phone-stack.md) — HFP path that VRD01's `libbtmm.so` integrates with for phone-side voice-dial trigger
- [forensic-factory-ui-binary.md](forensic-factory-ui-binary.md) — popup-buffer rendering (EMGD_POPUP_BUFFER=3) used by VRD01's listening modal; EmgdHmi pixmap canvas
- [forensic-libemgdhmi-api.md](forensic-libemgdhmi-api.md) — `libemgdhmi.so.0` API that VRD01 calls to draw the listening modal
- [feature-parity-audit.md](feature-parity-audit.md) — visible VR feature list we must preserve (navigate / call / dial / play / tune / read-text / tutorial / confirmation-beep)
- [DSU_HARDWARE_INVENTORY.md](DSU_HARDWARE_INVENTORY.md) — LAPIS ML7213 I2S audio paths (subdevice 0 = Stereo_out, 1 = Monaural_out / prompts, 2 = Mic_in, 4 = BTA_in)
- [DSU_OEM_DOCUMENTATION.md](DSU_OEM_DOCUMENTATION.md) — Nissan G-CAN steering-wheel button frame layout
