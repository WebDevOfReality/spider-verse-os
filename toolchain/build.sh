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
# DL_CMD: retry transient server errors instead of failing the build
# (mirrors 502 now and then; -c resumes a partial download).
cat > config.mak <<EOF
TARGET = ${TARGET}
OUTPUT = ${OUTPUT}/toolchain
DL_CMD = wget --tries=5 --waitretry=10 --retry-on-http-error=502,503,504 -c -O
EOF

# config.sub: musl-cross-make fetches it from savannah's old gitweb URL,
# which 502s intermittently (CI failed on it repeatedly). Fetch the same
# pinned revision from savannah's cgit instead, verified against
# musl-cross-make's own hash, so make finds it already in sources/.
CONFIG_SUB_REV=$(sed -n 's/^CONFIG_SUB_REV = //p' Makefile)
if [ ! -f sources/config.sub ]; then
	echo "==> fetching config.sub ${CONFIG_SUB_REV} (cgit)"
	rm -rf sources/config.sub.tmp
	mkdir -p sources/config.sub.tmp
	wget -q --tries=5 --waitretry=10 --retry-on-http-error=502,503,504 \
		-O sources/config.sub.tmp/config.sub \
		"https://git.savannah.gnu.org/cgit/config.git/plain/config.sub?id=${CONFIG_SUB_REV}"
	(cd sources/config.sub.tmp && sha1sum -c "../../hashes/config.sub.${CONFIG_SUB_REV}.sha1")
	mv sources/config.sub.tmp/config.sub sources/config.sub
	rm -rf sources/config.sub.tmp
fi

echo "==> building (this takes a while; go make tea)"
make -j"$(nproc)" install

echo "==> done. Toolchain at: ${OUTPUT}/toolchain"
echo "    Try: PATH=${OUTPUT}/toolchain/bin:\$PATH ${TARGET}-gcc --version"