#!/bin/bash
# get_case.sh - download and unpack an NCAR WRF v4.4 CONUS benchmark case.
# Usage: cases/wrf/get_case.sh conus12km|conus2.5km
# Env:   CASES (default /mnt/shared/cases/wrf)
set -euo pipefail

name="${1:?usage: get_case.sh conus12km|conus2.5km}"
case "$name" in conus12km|conus2.5km) ;; *) echo "unknown case $name" >&2; exit 1 ;; esac
CASES="${CASES:-/mnt/shared/cases/wrf}"
url="https://www2.mmm.ucar.edu/wrf/users/benchmark/v44/v4.4_bench_${name}.tar.gz"
tgz="$CASES/v4.4_bench_${name}.tar.gz"
mkdir -p "$CASES"

need=$(curl -sIL "$url" | awk 'tolower($1)=="content-length:" {n=$2} END {print int(n/1024/1024/1024)+1}')
free=$(df -BG --output=avail "$CASES" | tail -1 | tr -dc 0-9)
echo "case $name: ~${need} GB download, ~$((need * 3)) GB once unpacked; ${free} GB free in $CASES"
(( free > need * 3 )) || { echo "not enough space" >&2; exit 1; }

[[ -s "$tgz" ]] || curl -fSL --retry 3 -C - -o "$tgz" "$url"
tmp="$CASES/.unpack-$name"
rm -rf "$tmp"; mkdir -p "$tmp"
tar -xzf "$tgz" -C "$tmp"
nl="$(find "$tmp" -name namelist.input -print -quit)"
[[ -n "$nl" ]] || { echo "no namelist.input inside $tgz" >&2; exit 1; }
rm -rf "${CASES:?}/$name"
mv "$(dirname "$nl")" "$CASES/$name"
rm -rf "$tmp"
ls -la "$CASES/$name"
echo "unpacked to $CASES/$name (the .tar.gz can be deleted to save space)"
