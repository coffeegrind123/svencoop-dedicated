# svencoop-dedicated

Build and run a **Sven Co-op dedicated server that accepts non-Steam clients**, using
[ReHLDS_Sven](https://github.com/coffeegrind123/ReHLDS_Sven) +
[metamod-fallguys](https://github.com/hzqst/metamod-fallguys) +
[ReUnion](https://github.com/rehlds/reunion) with the official Sven Co-op `server.so`.

The assembled server also accepts **stock Half-Life clients alongside retail Sven Co-op
ones** — see [Mixed Sven and Half-Life clients](#mixed-sven-and-half-life-clients).

This is a **recipe, not a redistribution**: build scripts and configuration only. It contains
no Valve or Sven Co-op content or binaries. Those are fetched from Steam at build time with
`DepotDownloader` (app **276060**, anonymous login).

## Requirements

Debian 11 (bullseye) for **both the build and the runtime**. This is not a preference —
a bookworm runtime dies in `Host_Init` with a malloc assertion, and a bookworm-built binary
will not load on bullseye at all. See
[Debian 11 is required on both sides](docs/troubleshooting.md#debian-11-is-required-on-both-sides)
for the matrix and what has already been ruled out.

`docker/Dockerfile.run` provides a correct runtime; `docker/Dockerfile.build` provides a
correct builder if you want to build ReHLDS_Sven from source rather than take a release.

## Quick start

One command builds a complete, ready-to-run server:

```sh
scripts/assemble.sh -o /srv/svencoop
```

It fetches everything and verifies the result. No Steam account is needed — app 276060
resolves depots `1006`, `225841` (the game content) and `276062`, all reachable anonymously.

| source | what it provides |
|---|---|
| Steam app **276060**, anonymous | retail content, `dlls/server.so`, `filesystem_stdio.so`, `cl_dlls/`, `liblist.gam` |
| steamcmd | `steamclient.so` — a modern one; Sven's own stops at `SteamClient020` |
| [ReHLDS_Sven](https://github.com/coffeegrind123/ReHLDS_Sven) release | engine, launcher, `libsteam_api.so`, and metamod-fallguys + ReUnion preconfigured |

Then run it:

```sh
cd /srv/svencoop
LD_LIBRARY_PATH="$PWD" ./hlds_linux -game svencoop \
    +map abandoned +maxplayers 8 +port 27015 +sv_lan 0
```

Use `sv_lan 0`, and confirm on the console that `meta list` reports `[ 1] Reunion  RUN` —
see [Confirming ReUnion is actually running](docs/troubleshooting.md#confirming-reunion-is-actually-running)
for why the obvious checks are not evidence.

CI runs the same script on every push and weekly, boots the result, and publishes the
**server layer** (engine, plugin stack, configuration and `assemble.sh`) as a release. The
retail content is deliberately not published: this repository is a recipe, and the assembled
tree is about 2.6 GB, past GitHub's per-asset limit regardless.

## Why this exists

Public Sven Co-op servers reject non-Steam authentication. Measured 2026-08-01 against 14 live
servers spanning secure/insecure and dedicated/listen: **none accepted**, and 8 returned
`STEAM validation rejected`. `secure=false` rejects identically to `secure=true`, because
`secure` is the VAC flag and is orthogonal to Steam *authentication* — Sven Co-op is a
Steam-only game whose servers validate with Steam either way.

No client-side work changes that; the ticket is a genuine Steam-issued credential the server
verifies with Steam. Playing with a non-Steam client therefore means hosting the server
yourself and allowing non-Steam authentication. That is what ReUnion does, and what this
repository automates.

## Mixed Sven and Half-Life clients

The engine picks the protocol dialect **per client at runtime** rather than at compile time,
so a retail Sven Co-op 5.26 player and a stock Half-Life player (vanilla, or the
[SevenKewp](https://github.com/wootguy/SevenKewp) client) can be on this server at the same
time, still running the official Sven `server.so` unchanged.

Both games announce protocol 48, but Svengine widened a set of wire fields and dropped packet
munging. The engine decides which dialect a client speaks by decoding its first netchan packet
both ways and keeping whichever parses as a valid `clc` stream, so it does not rely on anything
the client claims about itself. `status` gains a `proto` column showing what each player is
being served.

Nothing needs configuring for the default behaviour, with one exception: a stock Half-Life
client checks the server's gamedir itself and disconnects before spawning, so set
`sv_proto_hl_gamedir` to the gamedir those players run (typically `valve`).

A Half-Life client cannot represent everything Sven Co-op sends, and cannot render every Sven
Co-op map — the engine clamps or withholds rather than sending something the client would
misparse. The limits, and a tool that reports which maps are affected, are documented in
[the engine's mixed-client notes](https://github.com/coffeegrind123/ReHLDS_Sven/blob/master/docs/mixed-clients.md).

## Configuration

### Non-Steam clients

ReUnion's own `reunion.cfg` ships `cid_NoSteam47 = 5` and `cid_NoSteam48 = 5`, and **`5` means
drop the client** — the opposite of why it is being deployed:

| value | meaning |
|---|---|
| `1` | accept, use the id the emulator supplied |
| `3` | accept, assign a generated `STEAM_x:y:z` |
| `4` | accept, assign a generated `VALVE_x:y:z` |
| `5` | drop the client |

The `reunion.cfg` shipped inside the ReHLDS_Sven release is ReUnion's own file for the pinned
version with only those two values changed to `3`, so an assembled server is already correct.

### The ReUnion salt

`reunion.cfg` ships `SteamIdHashSalt = GENERATE_ON_FIRST_RUN`, and the engine replaces it from
the OS CSPRNG on first start, saving a copy to `<gamedir>/.reunion_salt` (mode `0600`). A salt
baked into a public release would be identical for everyone who downloaded it, and so no salt
at all.

**Keep `.reunion_salt`.** It is what lets a newer release be unpacked over an existing install
without minting a new salt, and a new salt changes every generated `STEAM_x:y:z`, invalidating
every ban and stored per-player record. A salt set by hand is never touched; `-noreunionsalt`
disables the behaviour.

## The engine

Build from [coffeegrind123/ReHLDS_Sven](https://github.com/coffeegrind123/ReHLDS_Sven), not
upstream ReHLDS. It carries the Sven Co-op protocol work behind a `REHLDS_SVEN` define, plus
three fixes the retail Sven `server.so` needs: recovery from an unterminated `MESSAGE_BEGIN`,
a `DELTA_ParseDelta` stack overflow, and `-nobreakpad` being honoured in
`FileSystem_SetGameDirectory`. It reports the upstream ReHLDS version it is built on, so
`sv_version` matches the upstream release it corresponds to.

Its CI builds in `debian:11-slim`, so released binaries already satisfy the build-side
requirement above and can be used directly instead of building:

```sh
gh release download -R coffeegrind123/ReHLDS_Sven -p 'rehlds-sven-bin-*.zip'
```

Take only `hlds_linux` and `engine_i486.so` from `bin/linux32/`. `filesystem_stdio.so` must
come from the official Sven dedicated server — ReHLDS_Sven's own build lacks Sven's
`SCFileSystem002` interface and the server will not boot with it (see
[Troubleshooting](docs/troubleshooting.md#unable-to-initialize-steam-file-system)).

## The plugin stack

metamod and ReUnion do not need assembling here. Every ReHLDS_Sven release ships a `gamedir/`
overlay whose contents go into the mod directory (`svencoop/`):

| path | what |
|---|---|
| `addons/metamod/dlls/metamod.so`, `metamod.dll` | metamod-fallguys, pinned |
| `addons/metamod/config.ini` | points metamod at the real game library (key: `gamedll`) |
| `addons/metamod/plugins.ini` | plugin list, ReUnion first |
| `addons/reunion/reunion_mm_i386.so`, `reunion_mm.dll` | ReUnion, pinned |
| `reunion.cfg` | already has `cid_NoSteam47/48 = 3` |
| `rotate-reunion-salt.sh` | forces a new salt |

The Metamod binary lives in `addons/metamod/dlls/`, not `addons/metamod/`; it moved with the
2026-08-23 switch from Metamod-R to metamod-fallguys. `liblist.gam` is the only part of that
wiring this repository writes — the overlay does not ship it — so the path is set in
`scripts/assemble.sh` and has to track the release.

## Repository layout

| path | what |
|---|---|
| `scripts/assemble.sh` | fetches everything and builds a complete server |
| `docker/Dockerfile.run` | bullseye runtime; mount an assembled tree at `/server` |
| `docker/Dockerfile.build` | bullseye builder, for building ReHLDS_Sven from source |
| `docs/troubleshooting.md` | diagnosed failures and the evidence behind them |

`config/reunion.cfg` and `config/plugins.ini` used to live here. They are now built and
shipped by the engine fork's CI inside every release, so this repository no longer carries a
second copy to drift out of step.

## Licence

Scripts and configuration here: MIT (see `LICENSE`).

ReHLDS_Sven, metamod-fallguys and ReUnion are their authors' work under their own licences.
Sven Co-op and Half-Life content belongs to its respective owners and is **not** included; it
is downloaded from Steam at build time.
