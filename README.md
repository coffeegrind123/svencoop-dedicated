# svencoop-dedicated

Build and run a **Sven Co-op dedicated server that accepts non-Steam clients**, using
[ReHLDS_Sven](https://github.com/sw1ft747/ReHLDS_Sven) + [Metamod-R](https://github.com/rehlds/Metamod-R)
+ [ReUnion](https://github.com/rehlds/reunion) with the official Sven Co-op `server.so`.

This is a **recipe, not a redistribution**. It contains build scripts, patches and configs.
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

**Ruled out, do not re-test:** breakpad (patched out — `patches/`, crash persists),
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
| `patches/` | patches applied to ReHLDS_Sven before building |
| `config/reunion.cfg` | ReUnion config, non-Steam clients accepted |
| `config/plugins.ini` | Metamod plugin list (ReUnion first) |
| `docs/` | findings and runbook |

## Patches

- **`0001-nobreakpad-in-filesystem-init.patch`** — `sys_dll2.cpp` already guards
  `SteamAPI_UseBreakpadCrashHandler` behind `-nobreakpad`, but `filesystem.cpp` called
  `SteamAPI_SetBreakpadAppID` unconditionally, so the flag never actually kept you out of
  Steam's breakpad path. A non-Steam server has no use for Steam crash reporting.

## Status

Working: engine builds and boots, reports `Exe version 5.0.18 (svencoop)` (matching what
301 of 312 live public servers report), Metamod-r loads, the official `server.so` loads.

Open: Sven's `server.so` emits `Unable to initialize Steam file system` — traced to the
game DLL itself (grep with a control across every binary), most likely because the server
install is incomplete. Fetch the **full** depot; a filtered `regex:.*\.so$` filelist looks
complete but silently omits e.g. `libcurl.so.4`.

## Licence

Scripts, patches and configs here: MIT (see `LICENSE`).
ReHLDS_Sven, Metamod-R and ReUnion are their authors' work under their own licences.
Sven Co-op and Half-Life content belongs to their respective owners and is **not**
included — it is downloaded from Steam at build time.
