#!/bin/bash
# build_stack.sh - build the benchmark stack for the EPYC 9135 (Zen 5) nodes:
#   AMD BLIS (zen5 kernels) -> HPL 2.3, HPCG 3.1, HPCC 1.5.0
# against the system OpenMPI (installed on every node by cluster-bootstrap.sh).
#
# Build ON a compute node: -march=native and BLIS "auto" pick up Zen 5 there.
# Install to the shared NFS volume so all three nodes run the same binaries.
#
# Usage: benchmarks/build_stack.sh [all|blis|hpl|hpcg|hpcc]
# Env:   PREFIX      install root      (default /mnt/shared/opt/bench)
#        BLIS_CONFIG BLIS target       (default auto; zen5 on the real nodes)
#        CC/CXX      MPI wrappers      (default mpicc/mpicxx)
#        JOBS        make -j           (default nproc)
#        OPT         extra CFLAGS      (default "-O3 -march=native")
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-/mnt/shared/opt/bench}"
BUILD="${BUILD:-$HERE/build}"
BLIS_CONFIG="${BLIS_CONFIG:-auto}"
CC="${CC:-mpicc}"
CXX="${CXX:-mpicxx}"
JOBS="${JOBS:-$(nproc)}"
OPT="${OPT:--O3 -march=native}"
WHAT="${1:-all}"

# Pinned sources + SHA-256 (checked 2026-11-16).
BLIS_VER=5.3.2
BLIS_URL="https://github.com/amd/blis/archive/refs/tags/${BLIS_VER}.tar.gz"
BLIS_SHA=183f7628407ebb55c2a1d00d1887851cfd0bbc897cc05ecd04fc25664b0a8c9d
HPL_URL="https://netlib.org/benchmark/hpl/hpl-2.3.tar.gz"
HPL_SHA=32c5c17d22330e6f2337b681aded51637fb6008d3f0eb7c277b163fadd612830
HPCG_URL="https://github.com/hpcg-benchmark/hpcg/archive/refs/tags/HPCG-release-3-1-0.tar.gz"
HPCG_SHA=be841a30231c09b80d715600846212d2854c6709a56ba85af337e43a26255133
HPCC_URL="https://github.com/icl-utk-edu/hpcc/archive/refs/tags/1.5.0.tar.gz"
HPCC_SHA=a1ef5edaaa1f2cf12dc668264885b3b91acae538b7ed0d6faed7dac06a130b43

log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

for c in "$CC" "$CXX" make curl sha256sum tar python3; do
  command -v "$c" >/dev/null || die "'$c' not found (on the nodes: openmpi-bin libopenmpi-dev build-essential)"
done
mkdir -p "$BUILD/src" "$PREFIX"

# fetch <url> <sha256> <file>  - download once, always verify
fetch() {
  local url="$1" sha="$2" f="$BUILD/src/$3"
  if [[ ! -f "$f" ]]; then
    curl -fsSL --retry 3 -o "$f.part" "$url"
    mv "$f.part" "$f"
  fi
  echo "$sha  $f" | sha256sum -c --quiet - || { rm -f "$f"; die "checksum mismatch for $3"; }
}

# unpack <file> <dir>  - fresh source tree every build
unpack() {
  rm -rf "${BUILD:?}/$2"
  mkdir -p "$BUILD/$2"
  tar xzf "$BUILD/src/$1" -C "$BUILD/$2" --strip-components=1
}

# HPL-style arch file (HPL and HPCC share it). $1 = TOPdir
hpl_arch() {
  cat <<EOF
SHELL        = /bin/sh
CD           = cd
CP           = cp
LN_S         = ln -fs
MKDIR        = mkdir -p
RM           = /bin/rm -f
TOUCH        = touch
ARCH         = blis
TOPdir       = $1
INCdir       = \$(TOPdir)/include
BINdir       = \$(TOPdir)/bin/\$(ARCH)
LIBdir       = \$(TOPdir)/lib/\$(ARCH)
HPLlib       = \$(LIBdir)/libhpl.a
MPdir        =
MPinc        =
MPlib        =
LAdir        = $PREFIX/blis/lib
LAinc        = -I$PREFIX/blis/include/blis
LAlib        = \$(LAdir)/libblis.a -lm -lpthread
F2CDEFS      = -DAdd__ -DF77_INTEGER=int -DStringSunStyle
HPL_INCLUDES = -I\$(INCdir) -I\$(INCdir)/\$(ARCH) \$(LAinc) \$(MPinc)
HPL_LIBS     = \$(HPLlib) \$(LAlib) \$(MPlib)
HPL_OPTS     = -DHPL_CALL_CBLAS
HPL_DEFS     = \$(F2CDEFS) \$(HPL_OPTS) \$(HPL_INCLUDES)
CC           = $CC
CCNOOPT      = \$(HPL_DEFS)
CCFLAGS      = \$(HPL_DEFS) $OPT -fomit-frame-pointer -funroll-loops
LINKER       = $CC
LINKFLAGS    = \$(CCFLAGS)
ARCHIVER     = ar
ARFLAGS      = r
RANLIB       = echo
EOF
}

build_blis() {
  log "AMD BLIS $BLIS_VER (config: $BLIS_CONFIG, single-threaded: 1 MPI rank per core)"
  fetch "$BLIS_URL" "$BLIS_SHA" "blis-$BLIS_VER.tar.gz"
  unpack "blis-$BLIS_VER.tar.gz" blis
  ( cd "$BUILD/blis"
    ./configure --prefix="$PREFIX/blis" --enable-cblas -t no "$BLIS_CONFIG"
    make -j"$JOBS"
    make install )
  log "BLIS kernels built for: $(grep -m1 -o 'CONFIG_NAME *:= *[a-z0-9_]*' "$BUILD/blis/config.mk" | awk '{print $3}')"
}

build_hpl() {
  [[ -f "$PREFIX/blis/lib/libblis.a" ]] || die "build BLIS first"
  log "HPL 2.3"
  fetch "$HPL_URL" "$HPL_SHA" hpl-2.3.tar.gz
  unpack hpl-2.3.tar.gz hpl
  hpl_arch "$BUILD/hpl" > "$BUILD/hpl/Make.blis"
  ( cd "$BUILD/hpl" && make arch=blis -j1 )
  install -D -m 755 "$BUILD/hpl/bin/blis/xhpl" "$PREFIX/bin/xhpl"
}

build_hpcg() {
  log "HPCG 3.1"
  fetch "$HPCG_URL" "$HPCG_SHA" hpcg-3.1.0.tar.gz
  unpack hpcg-3.1.0.tar.gz hpcg
  sed -e "s|^CXX .*|CXX          = $CXX|" \
      -e "s|^CXXFLAGS .*|CXXFLAGS     = \$(HPCG_DEFS) $OPT -fopenmp|" \
      "$BUILD/hpcg/setup/Make.MPI_GCC_OMP" > "$BUILD/hpcg/setup/Make.BENCH"
  mkdir -p "$BUILD/hpcg/out"
  ( cd "$BUILD/hpcg/out" && ../configure BENCH && make -j"$JOBS" )
  install -D -m 755 "$BUILD/hpcg/out/bin/xhpcg" "$PREFIX/bin/xhpcg"
}

build_hpcc() {
  [[ -f "$PREFIX/blis/lib/libblis.a" ]] || die "build BLIS first"
  log "HPCC 1.5.0"
  fetch "$HPCC_URL" "$HPCC_SHA" hpcc-1.5.0.tar.gz
  unpack hpcc-1.5.0.tar.gz hpcc
  # HPCC builds its bundled HPL from the top dir with TOPdir=../../..
  hpl_arch "../../.." | sed 's|^HPL_OPTS .*|HPL_OPTS     = -DHPL_CALL_CBLAS -DHPCC_FFT_235|' > "$BUILD/hpcc/hpl/Make.blis"
  ( cd "$BUILD/hpcc" && make arch=blis -j1 )
  install -D -m 755 "$BUILD/hpcc/hpcc" "$PREFIX/bin/hpcc"
  install -D -m 644 "$BUILD/hpcc/_hpccinf.txt" "$PREFIX/share/_hpccinf.txt"
}

case "$WHAT" in
  all)  build_blis; build_hpl; build_hpcg; build_hpcc ;;
  blis) build_blis ;;
  hpl)  build_hpl ;;
  hpcg) build_hpcg ;;
  hpcc) build_hpcc ;;
  *) die "unknown target $WHAT (all|blis|hpl|hpcg|hpcc)" ;;
esac
log "installed under $PREFIX/bin:"
ls -la "$PREFIX/bin" 2>/dev/null || true
