#!/bin/sh
# mkcerts — Stage 3: generate the Nebula CA + host certs for the lab.
#
# This is the "hand-made certs" step from the roadmap. NEVER commit the
# output (certs/ is gitignored): the CA key IS the mesh.
#
# Usage: ./web/mkcerts.sh
#   creates web/lab/certs/{ca.crt,ca.key,*.crt,*.key} for:
#     lighthouse  10.99.99.1   (the coordinating node)
#     host-a      10.99.99.2
#     host-b      10.99.99.3
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
CERTS=$HERE/lab/certs
BIN=$HERE/bin

mkdir -p "$CERTS"
cd "$CERTS"

# CA: name is arbitrary; validity 1s before now .. 100 years out
if [ -f ca.key ]; then
	echo "CA already exists at $CERTS/ca.key — refusing to overwrite" >&2
	exit 1
fi

"$BIN/nebula-cert" ca -name "Spider-Verse OS Lab CA" -duration 876000h

# one cert per lab node; -ip assigns the nebula overlay address
"$BIN/nebula-cert" sign -name lighthouse -ip 10.99.99.1/24 -duration 87600h
"$BIN/nebula-cert" sign -name host-a      -ip 10.99.99.2/24 -duration 87600h
"$BIN/nebula-cert" sign -name host-b      -ip 10.99.99.3/24 -duration 87600h

echo "==> certs in $CERTS:"
ls -la
echo
echo "==> verify the chain:"
"$BIN/nebula-cert" print -path lighthouse.crt
"$BIN/nebula-cert" print -path host-a.crt