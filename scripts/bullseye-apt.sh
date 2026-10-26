#!/bin/sh
# Point apt in a debian:11-slim container at the image's own snapshot.debian.org pins.
#
# Debian 11 left LTS on 2026-08-31 and its security pool is being pruned from
# deb.debian.org, so `apt-get install` there fails with 404 / exit 100. The security
# suite cannot just be dropped: the image ships libc6 from bullseye-security, and the
# :i386 packages must match it exactly.
#
# The image carries the fix itself: /etc/apt/sources.list has, commented out, the
# snapshot.debian.org lines for the exact snapshot it was built from. They are
# permanent and follow the image when it is rebuilt. Snapshot Release files have
# long-expired Valid-Until by design, hence the flag. Same fix as ReHLDS_Sven's CI.
set -eu
sed -i -e 's|^# *\(deb http://snapshot\.debian\.org/\)|\1|' \
       -e '/^deb http:\/\/deb\.debian\.org\//d' /etc/apt/sources.list
if ! grep -q '^deb http://snapshot\.debian\.org/' /etc/apt/sources.list; then
  echo "FATAL: the image no longer ships snapshot.debian.org pins in /etc/apt/sources.list:" >&2
  cat /etc/apt/sources.list >&2
  exit 1
fi
printf 'Acquire::Check-Valid-Until "false";\nAcquire::Retries "5";\n' \
  > /etc/apt/apt.conf.d/99snapshot
