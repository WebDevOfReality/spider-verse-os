#!/bin/sh
# Stage 0 — build the Spider-Verse OS cross-toolchain.
#
# Uses musl-cross-make (richfelker) to build binutils + gcc + musl from
# source, producing a `x86_64-svos-linux-musl-` toolchain in toolchain/out.
#
# Usage: ./toolchain/build.sh
# Requires: gcc/g++, make, patch, wget, xz, bzip2, file, bison, flex
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
TARGET=x86_64-svos-linux-musl
OUTPUT="$HERE/out"
MCM_VERSION=v0.9.9

mkdir -p "$OUTPUT"
cd "$OUTPUT"

if [ ! -d musl-cross-make ]; then
	echo "==> fetching musl-cross-make $MCM_VERSION"
	wget -q "https://github.com/richfelker/musl-cross-make/archive/refs/tags/${MCM_VERSION}.tar.gz"
	tar xf "${MCM_VERSION}.tar.gz"
	mv "musl-cross-make-${MCM_VERSION#v}" musl-cross-make
	rm "${MCM_VERSION}.tar.gz"
fi

cd musl-cross-make

# Pin the toolchain components: TARGET, and musl/gcc/binutils sources.
# musl-cross-make fetches and verifies hashes itself at build time.
cat > config.mak <<EOF
TARGET = ${TARGET}
OUTPUT = ${OUTPUT}/toolchain
EOF

echo "==> building (this takes a while; go make tea)"
make -j"$(nproc)" install

echo "==> done. Toolchain at: ${OUTPUT}/toolchain"
echo "    Try: PATH=${OUTPUT}/toolchain/bin:\$PATH ${TARGET}-gcc --version"