# Troubleshooting

Failures diagnosed on this stack, with the evidence that identified them. Each one was
misleading in a specific way, which is why they are written down rather than left to be
rediscovered.

## `Unable to initialize Steam file system`

```
Unable to initialize Steam file system.
: Unknown error -1
```

**Cause: the wrong build of `filesystem_stdio.so`.** Sven's `dlls/server.so` dlopens it and
asks for `SCFileSystem002`, a Sven-specific interface:

| build of `filesystem_stdio.so` | `SCFileSystem002` | `VFileSystem009` |
|---|---|---|
| official Sven dedicated server | yes | yes |
| ReHLDS_Sven's own build | no | yes |

ReHLDS_Sven's build satisfies the *engine* but not the *game DLL*. The server dies **after**
Metamod has printed its full banner, which is what makes this read as a Metamod or
installation fault.

`assemble.sh` stages Sven's copy and asserts `SCFileSystem002` is present, so it cannot
regress silently.

Reproduced on demand as a positive control (2026-08-17): on a tree that boots normally,
swapping in ReHLDS_Sven's `filesystem_stdio.so` and changing nothing else brings the error
straight back.

This was previously attributed to an incomplete depot fetch — the theory being that a
filtered `regex:.*\.so$` filelist looks complete but omits files such as `libcurl.so.4`. That
was wrong. The depot is fetched in full now, but that is not what fixed it.

## `FATAL ERROR: Failure to load game DLL`

A **different** failure with a different cause, easily conflated with the one above. Sven's
`server.so` links against `libcurl.so.4`; without it the game DLL cannot be loaded at all.
`docker/Dockerfile.run` installs `libcurl4:i386` for this reason.

It can also mean the Metamod path in `liblist.gam` is wrong. The Metamod binary lives at
`addons/metamod/dlls/metamod.so` since the 2026-08-23 switch from Metamod-R to
metamod-fallguys; a `liblist.gam` still pointing at `addons/metamod/metamod_i386.so` produces
this error with no mention of the path it tried.

## Debian 11 is required on both sides

Build **and** runtime must be bullseye. Neither half is sufficient:

| build on | runtime | result |
|---|---|---|
| bookworm (12) | bookworm | `malloc assertion failure in sysmalloc`, dies in `Host_Init` |
| bookworm | bullseye (11) | will not load: `GLIBC_2.34 not found` |
| bullseye | bookworm | same malloc assertion |
| **bullseye** | **bullseye** | boots: `Console initialized.` |

Building on bullseye drops the binary requirement from `GLIBC_2.34` to `GLIBC_2.7`, which is
what makes a bullseye runtime possible at all. Running on bullseye is what avoids the heap
corruption. `Console initialized.` is the signal that init cleared it; it never appears on a
bookworm runtime.

ReHLDS_Sven's own CI builds in `debian:11-slim`, so its released binaries already satisfy the
build half — verified `GLIBC_2.7` (`engine_i486.so`) and `GLIBC_2.1` (`hlds_linux`).

Ruled out, and not worth re-testing: breakpad (patched out in the engine fork, crash
persists), `steamclient.so` (crashes with and without it), heap sizing (`-minmemory`,
`-maxmemory`, `-heapsize 32768/131072` all identical), and glibc malloc tunables
(`MALLOC_MMAP_THRESHOLD_`, `MALLOC_TOP_PAD_`, `glibc.malloc.arena_max`).

## Intermittent signon failures when looping a test client

Running a connection test in a tight loop returns
`{"works":false,"state":"signon_incomplete","reason":"server went silent during signon"}` for
roughly one run in five, sometimes with `rx_packets: 0`. This is an artefact of the test
method, not a server or fragmentation fault.

Each run leaves a client connected: a harness container that exits without a clean disconnect
lingers server-side until timeout. Looping it stacks them up, and every `docker run --rm`
container gets the same address:

```
players :  3 active (8 max)
# 1 "verifier"     74 ... 172.18.0.10:43850
# 2 "(1)verifier"  75 ... 172.18.0.10:51647
# 3 "(2)verifier"  76 ... 172.18.0.10:58956
```

Once six have accumulated, `sv_rehlds_maxclients_from_single_ip` (default 5) correctly refuses
the next connection and the client sees silence:

```
Too many connect packets from 172.18.0.10:54616 (6>5)
```

| method | result |
|---|---|
| back-to-back trials | 15/20, 18/20, 19/20, 23/30 |
| trials spaced 25s so clients expire | 10/10 |

Space runs by about 25 seconds, or source each from a distinct address.

Raising `sv_rehlds_maxclients_from_single_ip` is not the fix. The check is `count > value`, so
`0` rejects everything and drops the pass rate to 7/30; a high value only trades the per-IP
limit for the player slots filling with zombies.

Two engine builds (`3.15.0.896` and `3.15.0.898`) score identically under identical method, so
this was never related to the upstream rebuild.

## Confirming ReUnion is actually running

`meta list` showing `[ 1] Reunion  RUN` is the only proof. `Read plugin config for: Reunion`
is printed either way and is not evidence.

metamod-fallguys prints nothing on a successful plugin load, so grepping the startup log for
`reunion` comes back empty on a healthy server. `meta version` reports `Metamod-P (mm-p)` /
`1.21p38`; a `1.3.x` there means an old overlay.

Test with `sv_lan 0`. `sv_lan 1` bypasses Steam authentication entirely, so a non-Steam client
connects even when ReUnion is doing nothing — the test passes while proving nothing.
