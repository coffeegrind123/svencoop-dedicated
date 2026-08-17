#!/usr/bin/env bash
#
# Assemble a complete, ready-to-run Sven Co-op dedicated server that accepts
# non-Steam clients. Fetches everything it needs; nothing is vendored in this repo.
#
#   scripts/assemble.sh -o /srv/svencoop
#
# Sources, and why each one:
#
#   Steam app 276060 (anonymous)  content, dlls/server.so, filesystem_stdio.so, cl_dlls,
#                                 delta.lst, liblist.gam. Anonymous login is enough --
#                                 276060 resolves depots 1006, 225841 (the GAME content)
#                                 and 276062, so no Steam account is required.
#   steamcmd                      steamclient.so. NOT the one in Sven's own depot; see the
#                                 provenance table below.
#   ReHLDS_Sven release           hlds_linux, engine_i486.so, libsteam_api.so, and the
#                                 gamedir/ overlay (Metamod-R + ReUnion, preconfigured).
#
set -euo pipefail

OUT=""
LAYER_ONLY=0
SKIP_CONTENT=0
ENGINE_REPO="${ENGINE_REPO:-coffeegrind123/ReHLDS_Sven}"
ENGINE_TAG="${ENGINE_TAG:-}"          # empty = latest release
APPID=276060
WORK="${WORK:-$(pwd)/.assemble}"

usage() {
  cat >&2 <<EOF
usage: $0 -o <outdir> [--layer-only] [--skip-content]

  -o <outdir>      where to build the server tree
  --layer-only     stage only the parts this project produces (engine, plugins,
                   configs, support libs) and skip the ~2 GB of retail content.
                   This is what CI publishes -- see README.
  --skip-content   keep an existing outdir's content, restage everything else.

env:
  ENGINE_REPO      default $ENGINE_REPO
  ENGINE_TAG       default: latest release
  WORK             scratch dir, default ./.assemble
EOF
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    -o) OUT="${2:-}"; shift 2 ;;
    --layer-only) LAYER_ONLY=1; SKIP_CONTENT=1; shift ;;
    --skip-content) SKIP_CONTENT=1; shift ;;
    -h|--help) usage ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
done
[ -n "$OUT" ] || usage

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: $1 is required but not installed" >&2; exit 1; }; }
need unzip
need curl

mkdir -p "$WORK" "$OUT"
OUT="$(cd "$OUT" && pwd)"

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
# DepotDownloader
# ---------------------------------------------------------------------------
DD="$WORK/DepotDownloader/DepotDownloader"
if [ ! -x "$DD" ]; then
  say "Installing DepotDownloader"
  mkdir -p "$WORK/DepotDownloader"
  curl -fsSL -o "$WORK/dd.zip" \
    https://github.com/SteamRE/DepotDownloader/releases/latest/download/DepotDownloader-linux-x64.zip
  unzip -o -q "$WORK/dd.zip" -d "$WORK/DepotDownloader"
  chmod +x "$DD"
fi
"$DD" --version | head -1

# ---------------------------------------------------------------------------
# Retail content + the official server binaries (Steam app 276060, anonymous)
#
# ⚠⚠ cl_dlls/ IS NOT CLIENT-ONLY MATERIAL. The server CRCs cl_dlls/client.dll -- the
# WINDOWS one -- during SV_SpawnServer. Without it you get one line mid-startup:
#     Couldn't CRC client side dll:  cl_dlls//client.dll
# ...and then a server that runs normally WITH NO MAP: it stays up, answers `meta list`
# perfectly, and replies to neither A2S nor getchallenge. `status` is the only thing that
# admits it: `Can't "status", not connected`.
# ---------------------------------------------------------------------------
if [ "$SKIP_CONTENT" -eq 0 ]; then
  say "Fetching Sven Co-op dedicated server + content from Steam (app $APPID, anonymous)"
  "$DD" -app "$APPID" -os linux -dir "$OUT" -validate
else
  say "Skipping Steam content fetch (--skip-content/--layer-only)"
fi

# ---------------------------------------------------------------------------
# ReHLDS_Sven release: engine, launcher, libsteam_api.so, and the gamedir/ overlay
# (Metamod-R + ReUnion, already configured to accept non-Steam clients).
# ---------------------------------------------------------------------------
say "Fetching the ReHLDS_Sven release"
need gh
rm -rf "$WORK/engine" && mkdir -p "$WORK/engine"
( cd "$WORK/engine" && gh release download ${ENGINE_TAG:+"$ENGINE_TAG"} \
    --repo "$ENGINE_REPO" --pattern 'rehlds-sven-bin-*.zip' --clobber )
ENGINE_ZIP=$(ls "$WORK/engine"/rehlds-sven-bin-*.zip | head -1)
unzip -o -q "$ENGINE_ZIP" -d "$WORK/engine/x"
echo "using $(basename "$ENGINE_ZIP")"

EBIN="$WORK/engine/x/bin/linux32"
EGAME="$WORK/engine/x/gamedir"
for p in "$EBIN/hlds_linux" "$EBIN/engine_i486.so" "$EGAME/reunion.cfg"; do
  [ -e "$p" ] || { echo "ERROR: the release is missing $p" >&2; exit 1; }
done

mkdir -p "$OUT/svencoop"
install -m 0755 "$EBIN/hlds_linux"     "$OUT/hlds_linux"
install -m 0644 "$EBIN/engine_i486.so" "$OUT/engine_i486.so"

# The plugin stack ships preconfigured in the release; drop it into the mod dir.
cp -a "$EGAME/." "$OUT/svencoop/"

# ---------------------------------------------------------------------------
# liblist.gam: point the engine at Metamod, which then loads dlls/server.so.
# Rewritten in place rather than shipping a fork of the file, so retail updates
# flow through untouched.
# ---------------------------------------------------------------------------
if [ -f "$OUT/svencoop/liblist.gam" ]; then
  sed -i 's|^gamedll_linux .*|gamedll_linux "addons/metamod/metamod_i386.so"|' "$OUT/svencoop/liblist.gam"
  grep -q '^gamedll_linux' "$OUT/svencoop/liblist.gam" \
    || echo 'gamedll_linux "addons/metamod/metamod_i386.so"' >> "$OUT/svencoop/liblist.gam"
  echo "liblist.gam -> $(grep '^gamedll_linux' "$OUT/svencoop/liblist.gam")"
fi

# ---------------------------------------------------------------------------
# The three root support libraries have THREE DIFFERENT provenances.
#
# This is the part that looks arbitrary and is not. Each wrong choice fails at a
# DIFFERENT stage, and no failure names the file or the reason.
#
#   filesystem_stdio.so  <- the OFFICIAL SVEN server (Steam).
#       Sven's dlls/server.so dlopens it and asks for SCFileSystem002, a Sven-specific
#       interface. ReHLDS_Sven's own build provides only Valve's VFileSystem009, and with
#       that the server prints "Unable to initialize Steam file system." and exits AFTER
#       Metamod has printed its full banner -- so it reads as a Metamod fault and is not.
#
#   libsteam_api.so      <- REHLDS_SVEN.
#       engine_i486.so is built against it and needs SteamInternal_SteamAPI_Init, which
#       Sven's retail copy does not export. It asks for SteamClient021.
#
#   steamclient.so       <- STEAMCMD, not Sven's bundled copy.
#       Forced by the line above: Sven's own steamclient.so stops at SteamClient020, so it
#       cannot satisfy the 021 that ReHLDS_Sven's libsteam_api.so requires. With Sven's
#       copy you get "[S_API] SteamAPI_Init(): No SteamClient021" then
#       "FATAL ERROR: Unable to initialize Steam." -- which reads as a missing file and is
#       a version mismatch.
# ---------------------------------------------------------------------------
say "Staging the support libraries"

if [ "$SKIP_CONTENT" -eq 0 ] || [ -f "$OUT/filesystem_stdio.so" ]; then
  grep -aq 'SCFileSystem002' "$OUT/filesystem_stdio.so" \
    || { echo "ERROR: $OUT/filesystem_stdio.so does not provide SCFileSystem002" >&2; exit 1; }
  echo "filesystem_stdio.so: provides SCFileSystem002 (from Steam)"
fi

API_SRC=$(find "$WORK/engine/x" -name 'libsteam_api.so' -print -quit || true)
[ -n "$API_SRC" ] || {
  echo "ERROR: libsteam_api.so not found in the ReHLDS_Sven release." >&2
  echo "       Releases from 3.15.0.898-sven4 onward ship it in bin/linux32/." >&2
  exit 1; }
install -m 0644 "$API_SRC" "$OUT/libsteam_api.so"

# Read the required interface OUT of libsteam_api.so rather than hardcoding it, so an
# engine bump cannot silently invalidate this check.
WANT_SC=$(grep -aoE 'SteamClient0[0-9]+' "$OUT/libsteam_api.so" | sort -uV | tail -1)
[ -n "$WANT_SC" ] || { echo "ERROR: no SteamClient interface string in libsteam_api.so -- the probe is broken" >&2; exit 1; }
echo "libsteam_api.so requires $WANT_SC"

STEAMCLIENT_SO="${STEAMCLIENT_SO:-}"
if [ -z "$STEAMCLIENT_SO" ]; then
  for c in "$HOME/steamcmd/linux32/steamclient.so" \
           "$HOME/.steam/steamcmd/linux32/steamclient.so" \
           "$HOME/.steam/debian-installation/linux32/steamclient.so" \
           "$HOME/.steam/sdk32/steamclient.so"; do
    [ -f "$c" ] && grep -aq "$WANT_SC" "$c" && { STEAMCLIENT_SO="$c"; break; }
  done
fi

if [ -z "$STEAMCLIENT_SO" ]; then
  say "Installing steamcmd for steamclient.so ($WANT_SC)"
  mkdir -p "$WORK/steamcmd"
  curl -fsSL https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz \
    | tar -xz -C "$WORK/steamcmd"
  ( cd "$WORK/steamcmd" && ./steamcmd.sh +quit >/dev/null 2>&1 || true )
  for c in "$WORK/steamcmd/linux32/steamclient.so" "$HOME/.steam/steamcmd/linux32/steamclient.so"; do
    [ -f "$c" ] && grep -aq "$WANT_SC" "$c" && { STEAMCLIENT_SO="$c"; break; }
  done
fi

[ -n "$STEAMCLIENT_SO" ] || {
  echo "ERROR: no steamclient.so providing $WANT_SC was found." >&2
  echo "       Sven's own bundled copy stops at SteamClient020 and cannot be used." >&2
  echo "       Install steamcmd, or set STEAMCLIENT_SO=<path>." >&2
  exit 1; }

install -m 0644 "$STEAMCLIENT_SO" "$OUT/steamclient.so"
# ⚠ It must exist at BOTH paths. Only the absolute one's failure is fatal, and the
# earlier warnings about the bare name look like noise.
mkdir -p "$HOME/.steam/sdk32"
install -m 0644 "$STEAMCLIENT_SO" "$HOME/.steam/sdk32/steamclient.so"
echo "steamclient.so: $STEAMCLIENT_SO (provides $WANT_SC)"

# ---------------------------------------------------------------------------
# Verify, rather than trusting any of the above.
# ---------------------------------------------------------------------------
say "Verifying"
fail=0
chk() { if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1" >&2; fail=1; fi; }

chk "hlds_linux present and executable"        '[ -x "$OUT/hlds_linux" ]'
chk "engine_i486.so present"                   '[ -s "$OUT/engine_i486.so" ]'
chk "libsteam_api.so present"                  '[ -s "$OUT/libsteam_api.so" ]'
chk "steamclient.so provides $WANT_SC"         'grep -aq "$WANT_SC" "$OUT/steamclient.so"'
chk "metamod present"                          '[ -s "$OUT/svencoop/addons/metamod/metamod_i386.so" ]'
chk "reunion present"                          '[ -s "$OUT/svencoop/addons/reunion/reunion_mm_i386.so" ]'
chk "reunion.cfg accepts non-Steam (cid 47)"   'grep -qE "^cid_NoSteam47 = 3" "$OUT/svencoop/reunion.cfg"'
chk "reunion.cfg accepts non-Steam (cid 48)"   'grep -qE "^cid_NoSteam48 = 3" "$OUT/svencoop/reunion.cfg"'
chk "reunion.cfg has a salt line"              'grep -qE "^SteamIdHashSalt = .+" "$OUT/svencoop/reunion.cfg"'
chk "plugins.ini lists reunion"                'grep -q "reunion" "$OUT/svencoop/addons/metamod/plugins.ini"'

# GLIBC floor: the engine must be old-glibc enough to run on the target. Built in
# debian:11-slim upstream, so anything above 2.31 means a wrong build slipped in.
MAXG=$(grep -ao 'GLIBC_2\.[0-9]*' "$OUT/engine_i486.so" | sort -uV | tail -1)
chk "engine_i486.so glibc floor ($MAXG <= GLIBC_2.31)" \
    '[ "$(printf "%s\n%s\n" "$MAXG" "GLIBC_2.31" | sort -V | tail -1)" = "GLIBC_2.31" ]'

if [ "$LAYER_ONLY" -eq 0 ]; then
  chk "dlls/server.so present"                 '[ -s "$OUT/svencoop/dlls/server.so" ]'
  chk "filesystem_stdio.so has SCFileSystem002" 'grep -aq "SCFileSystem002" "$OUT/filesystem_stdio.so"'
  chk "cl_dlls/client.dll staged (map spawns)" '[ -s "$OUT/svencoop/cl_dlls/client.dll" ]'
  chk "maps present"                           '[ -n "$(ls "$OUT/svencoop/maps"/*.bsp 2>/dev/null | head -1)" ]'
  chk "liblist.gam points at metamod"          'grep -q "metamod_i386.so" "$OUT/svencoop/liblist.gam"'
fi

[ "$fail" -eq 0 ] || { echo; echo "assembly FAILED" >&2; exit 1; }

say "Done: $OUT"
cat <<EOF

Start it with sv_lan 0 -- sv_lan 1 bypasses Steam auth entirely and will make a
non-Steam client connect even when ReUnion is doing nothing:

  cd "$OUT" && LD_LIBRARY_PATH="$OUT" ./hlds_linux -game svencoop \\
      +map abandoned +maxplayers 8 +port 27015 +sv_lan 0

Then confirm on the server console:

  meta list     ->  [ 1] Reunion  RUN   ...  1 plugins, 1 running

"Read plugin config for: Reunion" is NOT proof -- it prints either way.
EOF
