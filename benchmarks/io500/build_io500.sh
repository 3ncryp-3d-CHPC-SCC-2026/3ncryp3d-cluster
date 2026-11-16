#!/bin/bash
# build_io500.sh - build IO500 ISC26 v2 (io500 + ior/mdtest + pfind) with the
# system OpenMPI. Uses the official prepare.sh, which pins ior and pfind
# by commit hash.
#
# Usage: benchmarks/io500/build_io500.sh
# Env:   PREFIX (default /mnt/shared/opt/io500)  - where the tree is built
#        SRC    (optional) a local io500 git checkout, e.g. from the USB stick
set -euo pipefail

PREFIX="${PREFIX:-/mnt/shared/opt/io500}"
TAG=io500-isc26_v2
# annotated tag object 8cf7aa6 points at this commit
TAG_SHA=8863e648cd88e56dbb4cb3849a35b2a6efef62cf

for c in mpicc git make autoconf automake pkg-config; do
  command -v "$c" >/dev/null || { echo "missing $c (apt install openmpi-bin libopenmpi-dev git build-essential autoconf automake pkg-config)" >&2; exit 1; }
done

mkdir -p "$(dirname "$PREFIX")"
if [[ ! -d "$PREFIX/.git" ]]; then
  git clone "${SRC:-https://github.com/IO500/io500.git}" "$PREFIX"
fi
cd "$PREFIX"
git fetch --tags -q || true
git checkout -q "$TAG"
[[ "$(git rev-parse HEAD)" == "$TAG_SHA" ]] || { echo "tag $TAG is not at $TAG_SHA" >&2; exit 1; }

# prepare.sh clones ior + pfind at pinned hashes and builds everything
CC=mpicc ./prepare.sh
ls -la io500 build/ior/src/ior build/ior/src/mdtest 2>/dev/null || true
echo "built IO500 $TAG in $PREFIX"
