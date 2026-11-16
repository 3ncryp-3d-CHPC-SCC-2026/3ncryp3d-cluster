#!/bin/bash
# fetch_sources.sh - download every source and model the competition needs
# into one folder (for a USB stick), so venue internet isn't on the
# critical path. Run on any Linux box with internet; re-running skips what's
# already there.
#
# Usage: tools/fetch_sources.sh [DEST]          (default ./offline)
#        WITH_DEBS=1 tools/fetch_sources.sh     also cache Ubuntu 24.04 .debs
#                                               (only on an Ubuntu 24.04 box)
#
# Versions follow chpc-tech-eval/scc-nationals26 as read on 2026-11-16.
# Re-check that repo before the trip: case files are released later.
set -euo pipefail

DEST="${1:-./offline}"
mkdir -p "$DEST"/{src,git,models,pip}
DEST="$(cd "$DEST" && pwd)"

log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
get() {  # get <url> <file>
  local f="$DEST/src/$2"
  [[ -s "$f" ]] && { echo "have $2"; return; }
  curl -fSL --retry 3 -o "$f.part" "$1" && mv "$f.part" "$f"
}
clone() {  # clone <url> <dir> [ref] [--recursive]
  local d="$DEST/git/$2"
  if [[ ! -d "$d/.git" ]]; then git clone ${4:+--recurse-submodules} "$1" "$d"; fi
  if [[ -n "${3:-}" ]]; then
    git -C "$d" fetch --tags -q
    git -C "$d" checkout -q "$3"
    [[ -n "${4:-}" ]] && git -C "$d" submodule update --init --recursive -q
  fi
  echo "$2 @ $(git -C "$d" describe --tags --always)"
}

log "HPL/HPCG/HPCC + BLIS (checksums are verified later by build_stack.sh)"
get https://github.com/amd/blis/archive/refs/tags/5.3.2.tar.gz blis-5.3.2.tar.gz
get https://netlib.org/benchmark/hpl/hpl-2.3.tar.gz hpl-2.3.tar.gz
get https://github.com/hpcg-benchmark/hpcg/archive/refs/tags/HPCG-release-3-1-0.tar.gz hpcg-3.1.0.tar.gz
get https://github.com/icl-utk-edu/hpcc/archive/refs/tags/1.5.0.tar.gz hpcc-1.5.0.tar.gz

log "IO500 ISC26 v2 + the ior/pfind it pins"
clone https://github.com/IO500/io500.git io500 io500-isc26_v2
clone https://github.com/hpc/ior.git ior 5fcf0ba995f
clone https://github.com/VI4IO/pfind.git pfind d08501f9976
clone https://github.com/VI4IO/cdcl-schema-tools.git cdcl-schema-tools

log "SPECFEM3D Cartesian v4.1.1"
clone https://github.com/SPECFEM/specfem3d.git specfem3d v4.1.1 --recursive

log "WRF (version not stated by organisers; latest is v4.8.0, with submodules)"
clone https://github.com/wrf-model/WRF.git WRF v4.8.0 --recursive

log "llama.cpp v0.6.0 + a small test model"
clone https://github.com/ggml-org/llama.cpp.git llama.cpp v0.6.0
get https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf ../models/Llama-3.2-1B-Instruct-Q4_K_M.gguf

log "ExaHyPE 2 (Peano, gitlab.lrz.de, default branch p4)"
clone https://gitlab.lrz.de/hpcsoftware/Peano.git Peano

log "ECSim = OPEM v1.4 (Python wheels incl. dependencies)"
python3 -m pip download -q -d "$DEST/pip" "opem==1.4"

if [[ "${WITH_DEBS:-0}" == 1 ]]; then
  log "Ubuntu 24.04 build dependencies as .deb files"
  grep -q 'VERSION_ID="24.04"' /etc/os-release || { echo "WITH_DEBS needs Ubuntu 24.04" >&2; exit 1; }
  mkdir -p "$DEST/debs"
  sudo apt-get install -y --download-only -o Dir::Cache::archives="$DEST/debs" \
    build-essential gfortran cmake git autoconf automake libtool pkg-config python3-pip python3-venv \
    openmpi-bin libopenmpi-dev libhdf5-openmpi-dev hdf5-tools \
    libnetcdf-dev libnetcdff-dev netcdf-bin libpnetcdf-dev csh m4 \
    fio iperf3 ipmitool nfs-kernel-server nfs-common
fi

log "writing manifest"
( cd "$DEST"
  find src models pip debs -type f 2>/dev/null | sort | xargs -r sha256sum > MANIFEST.txt
  for d in git/*; do echo "git $d $(git -C "$d" rev-parse HEAD)"; done >> MANIFEST.txt )
du -sh "$DEST"
echo "done: copy $DEST to the USB stick"
