# svencoop-dedicated

Build and run a **Sven Co-op dedicated server that accepts non-Steam clients**, using
[ReHLDS_Sven](https://github.com/coffeegrind123/ReHLDS_Sven) + [Metamod-R](https://github.com/rehlds/Metamod-R)
+ [ReUnion](https://github.com/rehlds/reunion) with the official Sven Co-op `server.so`.

This is a **recipe, not a redistribution**. It contains build scripts and configs.
It contains no Valve or Sven Co-op content or binaries — those are fetched from Steam at
build time with `DepotDownloader` (app **276060**, anonymous login).

## Why

Public Sven Co-op servers reject non-Steam authentication. Measured 2026-08-01 against 14
live servers spanning secure/insecure and dedicated/listen: **0 accepted**, 8 returned
`STEAM validation rejected`. `secure=false` rejects identically to `secure=true`, because
`secure` is the **VAC** flag and is orthogonal to Steam *authentication* — Sven is a
Steam-only game whose servers validate with Steam regardless.

No client-side work changes that: the ticket is a genuine Steam-issued credential the
server verifies with Steam. So to play Sven Co-op with a non-Steam client you must host
the server yourself and allow non-Steam auth. That is what ReUnion is for, and what this
repo automates.

## ⚠ Build on Debian 11 AND run on Debian 11. Both are required.

The single most expensive thing to learn here. Measured matrix:

| build on | runtime | result |
|---|---|---|
| bookworm (12) | bookworm | `malloc assertion failure in sysmalloc` — dies in `Host_Init` |
| bookworm | bullseye (11) | won't load: `GLIBC_2.34 not found` |
| bullseye | bookworm | same malloc assertion |
| **bullseye** | **bullseye** | ✅ `Console initialized.` |

Neither half is sufficient:

- **Build** on bullseye — upstream ReHLDS_Sven CI uses `container: debian:11-slim`.
  This drops the binary requirement from `GLIBC_2.34` to **`GLIBC_2.7`**, which is what
  makes a bullseye *runtime* possible at all.
- **Run** on bullseye — this is what avoids the heap corruption.

`Console initialized.` is the signal init cleared the corruption. It never appears on a
bookworm runtime.

**Ruled out, do not re-test:** breakpad (patched out in the engine fork, crash persists),
`steamclient.so` (crashes with and without it), heap sizing (`-minmemory`, `-maxmemory`,
`-heapsize 32768/131072` all identical), glibc malloc tunables (`MALLOC_MMAP_THRESHOLD_`,
`MALLOC_TOP_PAD_`, `glibc.malloc.arena_max`).

## ⚠ ReUnion `cid_*` = 5 means DROP, not accept

Upstream `reunion.cfg` ships `cid_NoSteam47 = 5` and `cid_NoSteam48 = 5`, i.e. plain
non-Steam clients are **rejected** by default — the opposite of why you are deploying it.

| value | meaning |
|---|---|
| `1` | accept, use the id the emulator supplied |
| `3` | accept, assign a generated `STEAM_x:y:z` |
| `4` | accept, assign a generated `VALVE_x:y:z` |
| **`5`** | **drop the client** |

`config/reunion.cfg` here is upstream's file with **only** those two values changed to `3`.

## Layout

| path | what |
|---|---|
| `docker/Dockerfile.build` | bullseye builder for ReHLDS_Sven |
| `config/reunion.cfg` | ReUnion config, non-Steam clients accepted |
| `config/plugins.ini` | Metamod plugin list (ReUnion first) |
| `docs/` | findings and runbook |

## The engine fork

Build from **[coffeegrind123/ReHLDS_Sven](https://github.com/coffeegrind123/ReHLDS_Sven)**,
not upstream.

**Rebuilt on current upstream (2026-08-17).** The fork used to descend from
[autisoid/ReHLDS_Sven](https://github.com/autisoid/ReHLDS_Sven), which branched off ReHLDS in
March 2025 and drifted. It is now a genuine fork of
[rehlds/ReHLDS](https://github.com/rehlds/ReHLDS) with the Sven Co-op protocol work replayed
commit by commit on top of current upstream, so it carries ~40 upstream commits it was missing
— the userinfo exploit fix, the movecmd/stringcmd rate limiting and speedhack detection, bzip2
decompression hardening — and can be rebased again rather than drifting further.

All Sven behaviour sits behind the `REHLDS_SVEN` define. The engine reports the **upstream**
version it is built on (`3.15.0.898`), not a fork-inflated number, so `sv_version` lines up
with the upstream release it actually corresponds to.

### Prebuilt binaries

The fork's CI builds in `debian:11-slim`, so **released binaries already satisfy the bullseye
requirement below** — verified `GLIBC_2.7` (`engine_i486.so`) and `GLIBC_2.1` (`hlds_linux`).
You can take them from the [releases](https://github.com/coffeegrind123/ReHLDS_Sven/releases)
instead of building:

```sh
gh release download -R coffeegrind123/ReHLDS_Sven -p 'rehlds-sven-bin-*.zip'
```

⚠ Take **only** `hlds_linux` and `engine_i486.so` from it. `filesystem_stdio.so` must come from
the official Sven dedicated server (it provides Sven's `SCFileSystem002`, which ReHLDS_Sven's
own build does not), and `libsteam_api.so` from ReHLDS_Sven's `rehlds/lib/linux32/`.

### The three Sven fixes

These are needed to run the retail Sven `server.so`. They used to live here as a `patches/`
directory applied before building; carrying them in the source instead means the build is a
plain checkout, and the fixes are reviewable as commits with their reasoning attached rather
than as context-free diffs.

- **`engine: recover from an unterminated MESSAGE_BEGIN`** — the official `server.so` calls
  `MESSAGE_BEGIN` and returns without a matching `MESSAGE_END`. `gMsgStarted` is set only in
  `PF_MessageBegin_I` and cleared only in `PF_MessageEnd_I`, and nothing resets it on level
  change, client drop or shutdown — so one leak is permanent and the *next* `MessageBegin`
  takes the fatal, though it is the victim rather than the culprit. Measured before the fix:
  **484 fatals over 8 days, ~30/day**, always in the pattern map change → server empties →
  fatal seconds later. Discarding the stale message is safe because `PF_MessageEnd_I` is the
  only thing that copies the staged buffer to a destination, so an unterminated message has
  written nothing to any client and there is nothing on the wire to corrupt.
- **`engine: fix stack overflow in DELTA_ParseDelta`** — under `REHLDS_SVEN`.
- **`engine: honour -nobreakpad in FileSystem_SetGameDirectory`** — `sys_dll2.cpp` already
  guards `SteamAPI_UseBreakpadCrashHandler` behind `-nobreakpad`, but `filesystem.cpp`
  called `SteamAPI_SetBreakpadAppID` unconditionally, so the flag never actually kept you
  out of Steam's breakpad path. A non-Steam server has no use for Steam crash reporting.

## Status

Working end to end on the rebuilt engine (`3.15.0.898`, verified 2026-08-17): boots with
`Console initialized.`, reports `Exe version 5.0.18 (svencoop)` (matching what 301 of 312 live
public servers report), Metamod-r loads, the official `server.so` loads, `meta list` shows
`[ 1] Reunion RUN`, a map spawns, and a **non-Steam client reaches `ca_active` and sustains
gameplay** with ReUnion issuing a generated `STEAM_x:y:z` identity.

### ⚠ Intermittent signon failure (~10–25%), PRE-EXISTING — do not blame the rebuild

Repeated verifier runs against the same server intermittently return
`{"works":false,"state":"signon_incomplete","reason":"server went silent during signon"}`,
having already passed auth (`connect accepted`, client logged as `connected`). It dies after
`serverinfo` / signon state 1, and the server logs nothing.

**This is not a regression from the upstream rebuild.** Matched 20-run samples on the *same*
host, game volume and harness:

| engine | result |
|---|---|
| old fork `3.15.0.896` | 15/20 |
| rebuilt `3.15.0.898` | 15/20 |

Identical, so the rebuild neither caused nor fixed it. ⚠ **A single run proves nothing here** —
the first run after the switch failed and looked exactly like a regression. Always take a
sample of ~20 and compare against the previous engine before concluding anything about signon.

Still open, and unrelated: Sven's `server.so` emits `Unable to initialize Steam file system` —
traced to the game DLL itself (grep with a control across every binary), most likely because
the server install is incomplete. Fetch the **full** depot; a filtered `regex:.*\.so$` filelist
looks complete but silently omits e.g. `libcurl.so.4`.

## Licence

Scripts and configs here: MIT (see `LICENSE`).
ReHLDS_Sven, Metamod-R and ReUnion are their authors' work under their own licences.
Sven Co-op and Half-Life content belongs to their respective owners and is **not**
included — it is downloaded from Steam at build time.
