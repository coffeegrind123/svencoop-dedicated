# svencoop-dedicated

Build and run a **Sven Co-op dedicated server that accepts non-Steam clients**, using
[ReHLDS_Sven](https://github.com/coffeegrind123/ReHLDS_Sven) + [metamod-fallguys](https://github.com/hzqst/metamod-fallguys)
+ [ReUnion](https://github.com/rehlds/reunion) with the official Sven Co-op `server.so`.

Since engine `3.15.0.905-sven1` the assembled server also accepts **stock Half-Life clients
alongside retail Sven ones** — see [Mixed Sven and Half-Life clients](#mixed-sven-and-half-life-clients).

This is a **recipe, not a redistribution**. It contains build scripts and configs.
It contains no Valve or Sven Co-op content or binaries — those are fetched from Steam at
build time with `DepotDownloader` (app **276060**, anonymous login).

## Quick start

One command builds a complete, ready-to-run server:

```sh
scripts/assemble.sh -o /srv/svencoop
```

It fetches everything and verifies the result:

| from | what |
|---|---|
| Steam app **276060**, anonymous | retail content, `dlls/server.so`, `filesystem_stdio.so`, `cl_dlls/`, `liblist.gam` |
| steamcmd | `steamclient.so` — a modern one; Sven's own stops at `SteamClient020` |
| [ReHLDS_Sven](https://github.com/coffeegrind123/ReHLDS_Sven) release | engine, launcher, `libsteam_api.so`, and metamod-fallguys + ReUnion preconfigured |

No Steam account is needed. App 276060 resolves depots `1006`, `225841` (the **game**
content) and `276062`, all reachable anonymously.

Then:

```sh
cd /srv/svencoop
LD_LIBRARY_PATH="$PWD" ./hlds_linux -game svencoop \
    +map abandoned +maxplayers 8 +port 27015 +sv_lan 0
```

> [!IMPORTANT]
> Use `sv_lan 0`. `sv_lan 1` bypasses Steam auth entirely, so a non-Steam client connects
> even when ReUnion is doing nothing — the test passes while proving nothing.

Confirm on the server console that `meta list` shows `[ 1] Reunion  RUN`.
`Read plugin config for: Reunion` is **not** proof; it prints either way.

CI runs the same script on every push and weekly, boots the result, and publishes the
**server layer** (engine, plugin stack, configs, and `assemble.sh`) as a release. The
retail content is deliberately not published — this repo is a recipe, and the assembled
tree is ~2.6 GB, past GitHub's per-asset limit regardless.

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

The `reunion.cfg` shipped in the ReHLDS_Sven release is ReUnion's own file for the pinned
version with **only** those two values changed to `3`.

## Layout

| path | what |
|---|---|
| `scripts/assemble.sh` | fetches everything and builds a complete server |
| `docker/Dockerfile.run` | bullseye runtime; mount an assembled tree at `/server` |
| `docker/Dockerfile.build` | bullseye builder, for building ReHLDS_Sven from source |
| `docs/` | findings and runbook |

> [!NOTE]
> `config/reunion.cfg` and `config/plugins.ini` used to live here. They are now built and
> shipped by the engine fork's CI inside every release, so this repo no longer carries a
> second copy to drift out of step. See **The plugin stack** below.

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
version it is built on (`3.15.0.905` as of `3.15.0.905-sven1`), not a fork-inflated number, so
`sv_version` lines up with the upstream release it actually corresponds to.

### Mixed Sven and Half-Life clients

From `3.15.0.905-sven1`, the engine picks the protocol dialect **per client at runtime**
rather than at compile time, so a retail Sven Co-op 5.26 player and a stock Half-Life player
(vanilla, or the [SevenKewp](https://github.com/wootguy/SevenKewp) client) can be on this
server at the same time — still running the official Sven `server.so`, unchanged.

Both games announce protocol 48, but Svengine widened a set of wire fields and dropped packet
munging. The engine decides which a client speaks by decoding its **first netchan packet both
ways** and keeping whichever parses as a valid `clc` stream, so it is not relying on anything
the client claims about itself.

| cvar | default | |
|---|---|---|
| `sv_proto_dialect` | `auto` | `sven` / `hl` pin every client, for testing |
| `sv_proto_fallback` | `sven` | assumed when detection stays inconclusive |
| `sv_proto_log` | `0` | `1` logs each verdict and connect; `2` adds hex dumps |

`status` gains a `proto` column showing what each player is being served. Nothing needs
configuring for the default behaviour — the two `FCVAR_SERVER` cvars above show up in
`A2S_RULES`, which is the quickest way to confirm an assembled server really is on an engine
new enough to do this.

⚠ **The engine framing being correct is not the same as the mod being playable.** A Half-Life
client gets correct bytes for every message, but whether it has the *content* and the
client-side message handlers to make sense of what a Sven mod sends it is a mod and gamedir
question, not an engine one. It also cannot represent coordinates past ±4096 units, entity
indices past 2047, or more than 56 delta fields — the engine clamps and truncates rather than
sending something the client would misparse. The full list is in the
[engine release notes](https://github.com/coffeegrind123/ReHLDS_Sven/releases/tag/3.15.0.905-sven1).

### Prebuilt binaries

The fork's CI builds in `debian:11-slim`, so **released binaries already satisfy the bullseye
requirement below** — verified `GLIBC_2.7` (`engine_i486.so`) and `GLIBC_2.1` (`hlds_linux`).
You can take them from the [releases](https://github.com/coffeegrind123/ReHLDS_Sven/releases)
instead of building:

```sh
gh release download -R coffeegrind123/ReHLDS_Sven -p 'rehlds-sven-bin-*.zip'
```

⚠ Take **only** `hlds_linux` and `engine_i486.so` from `bin/linux32/`. `filesystem_stdio.so`
must come from the official Sven dedicated server (it provides Sven's `SCFileSystem002`, which
ReHLDS_Sven's own build does not), and `libsteam_api.so` from ReHLDS_Sven's
`rehlds/lib/linux32/`.

## The plugin stack

**metamod and ReUnion no longer need assembling here.** Every ReHLDS_Sven release ships a
`gamedir/` overlay; copy its contents into the mod directory (`svencoop/`):

| path | what |
|---|---|
| `addons/metamod/dlls/metamod.so`, `metamod.dll` | metamod-fallguys, pinned |
| `addons/metamod/config.ini` | points metamod at the real game library (key: `gamedll`) |
| `addons/metamod/plugins.ini` | plugin list, ReUnion first |
| `addons/reunion/reunion_mm_i386.so`, `reunion_mm.dll` | ReUnion, pinned |
| `reunion.cfg` | already has `cid_NoSteam47/48 = 3` (see the trap above) |
| `rotate-reunion-salt.sh` | forces a new salt |

⚠ **The metamod binary lives in `addons/metamod/dlls/`, not `addons/metamod/`.** It moved
with the 2026-08-23 switch from Metamod-R to metamod-fallguys. `liblist.gam` is the only
part of that wiring this repo writes -- the overlay does not ship it -- so the path is
hardcoded in `scripts/assemble.sh` and has to track the release. `meta version` on a
running server reports `Metamod-P (mm-p)` / `1.21p38`; a `1.3.x` there means an old
overlay.

### The salt is generated for you now

`reunion.cfg` ships with `SteamIdHashSalt = GENERATE_ON_FIRST_RUN` and the **engine** replaces
it from the OS CSPRNG on first start, saving a copy to `<gamedir>/.reunion_salt` (mode `0600`).
A salt baked into a public release would be identical for everyone who downloaded it, so it
would be no salt at all.

⚠ **Keep `.reunion_salt`.** It is what lets a newer release be unpacked over an install without
minting a *new* salt — and a new salt changes every generated `STEAM_x:y:z`, invalidating every
ban and stored per-player record. A salt set by hand is never touched; `-noreunionsalt` disables
the behaviour.

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
public servers report), metamod loads, the official `server.so` loads, `meta list` shows
`[ 1] Reunion RUN`, a map spawns, and a **non-Steam client reaches `ca_active` and sustains
gameplay** with ReUnion issuing a generated `STEAM_x:y:z` identity.

**Engine `3.15.0.905-sven1`, verified 2026-08-30** by swapping `engine_i486.so`, `hlds_linux`
and `libsteam_api.so` into a running deployment and restarting it: `Console initialized.`,
`Exe version 5.0.18 (svencoop)`, metamod banner, `Started map "bm_sts"`, Steam connected, and
`A2S_RULES` advertising `sv_proto_dialect=auto` / `sv_proto_fallback=sven` — so the
per-client dialect layer is live.

⚠ What that run did **not** cover: no stock Half-Life client was connected to it. The
mixed-client path is verified by the engine's own unit tests and against an independently
measured wire spec, not yet by two real clients of different kinds on this deployment at
once. Treat "Sven clients still work, and the new code is loaded" as what is established
here.

### ⚠ Back-to-back verifier runs fail ~20% — that is YOUR TEST, not the server

Running the verifier in a tight loop returns
`{"works":false,"state":"signon_incomplete","reason":"server went silent during signon"}` for
roughly one run in five, sometimes with `rx_packets: 0`. It is tempting to read this as an
engine or fragmentation bug. It is neither.

**Each verifier run leaves a client connected.** The harness container exits without a clean
disconnect, so the client lingers server-side until timeout. Loop the harness and they pile up:

```
players :  3 active (8 max)
# 1 "verifier"     74 ... 172.18.0.10:43850
# 2 "(1)verifier"  75 ... 172.18.0.10:51647
# 3 "(2)verifier"  76 ... 172.18.0.10:58956
```

Every `docker run --rm` verifier gets the **same** container IP (`172.18.0.10`), so once six
have stacked up, `sv_rehlds_maxclients_from_single_ip` (default **5**) correctly refuses the
next one and the client sees total silence:

```
Too many connect packets from 172.18.0.10:54616 (6>5)
```

Measured, same server and settings:

| method | result |
|---|---|
| back-to-back trials | 15/20, 18/20, 19/20, 23/30 |
| trials spaced 25s so clients expire | **10/10** |

⚠ **Do not "fix" this by setting `sv_rehlds_maxclients_from_single_ip 0`.** The check is
`count > value`, so `0` rejects *everything* — it drops the pass rate to 7/30. Setting it high
(100) only trades the per-IP limit for the 8-slot player cap filling with zombies.

⇒ **Space verifier runs by ~25s**, or run each from a distinct source IP. Both engines
(old `3.15.0.896` and rebuilt `3.15.0.898`) score identically under identical method, so this
never had anything to do with the upstream rebuild.

### ✅ CLOSED: `Unable to initialize Steam file system` was the wrong `filesystem_stdio.so`

This was recorded as open, and blamed on an incomplete install — "fetch the **full** depot; a
filtered `regex:.*\.so$` filelist looks complete but silently omits e.g. `libcurl.so.4`".
**That hypothesis was wrong.** The depot is fetched in full now, but that is not what fixed it,
and chasing install completeness would have missed the cause entirely.

The cause is `filesystem_stdio.so` **provenance**. Sven's `dlls/server.so` dlopens it and asks
for `SCFileSystem002`, a Sven-specific interface:

| build of `filesystem_stdio.so` | `SCFileSystem002` | `VFileSystem009` |
|---|---|---|
| official Sven server (correct) | ✅ | ✅ |
| ReHLDS_Sven's own build | ❌ | ✅ |

ReHLDS_Sven's build satisfies the *engine* but not the *game DLL*, so the server dies —
**after** Metamod has printed its full banner, which is what makes it read as a Metamod or
install fault:

```
Unable to initialize Steam file system.
: Unknown error -1
```

Reproduced on demand 2026-08-17 as a positive control: on a tree that boots normally, swapping
in ReHLDS_Sven's `filesystem_stdio.so` and changing nothing else brings the error straight back.
`assemble.sh` stages Sven's copy and asserts `SCFileSystem002` is present, so this cannot
silently regress.

⚠ Note that `libcurl.so.4` is a **different** failure with a **different** symptom — Sven's
`server.so` links against it, and its absence gives `FATAL ERROR: Failure to load game DLL`,
not this message. `docker/Dockerfile.run` installs `libcurl4:i386` for that reason. Do not
conflate the two.

## Licence

Scripts and configs here: MIT (see `LICENSE`).
ReHLDS_Sven, metamod-fallguys and ReUnion are their authors' work under their own licences.
Sven Co-op and Half-Life content belongs to their respective owners and is **not**
included — it is downloaded from Steam at build time.
