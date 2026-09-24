#!/bin/sh
# runlab.sh — Stage 3: boot the Weaver/Nebula lab.
#
# Topology (the roadmap's "1 lighthouse + 2 hosts" shape):
#
#   host (Debian/WSL)                    QEMU VMs (our kernel + svos-init)
#   +------------------+                 +---------------------------+
#   | nebula lighthouse|<-- UDP mesh --->| weaver VM "host-a"        |
#   | 10.99.99.1       |    (underlay    |   nebula0: 10.99.99.2     |
#   | 192.168.100.1    |    = UDP socket |   underlay: 192.168.100.2 |
#   +------------------+     network)   +---------------------------+
#                                       | weaver VM "host-b"        |
#                                       |   nebula0: 10.99.99.3     |
#                                       |   underlay: 192.168.100.2 |
#                                       +---------------------------+
#
# The "underlay" is QEMU's udp socket networking: each VM's traffic is
# tunneled as UDP datagrams by the host between VMs. Nebula then builds
# the mesh (overlay) on top. Two layers, both visible in the lab.
#
# The lighthouse runs on the host (your terminal) at underlay
# 127.0.0.1:22220. Each VM gets a distinct UDP port on 127.0.0.1 and all
# VMs reach the lighthouse via its static_host_map entry.
#
# Usage (three terminals):
#   ./web/runlab.sh lighthouse   # run nebula lighthouse on the host
#   ./web/runlab.sh host-a       # boot VM host-a (interactive)
#   ./web/runlab.sh host-b       # boot VM host-b (interactive)
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)          # web/
REPO=$(cd "$HERE/.." && pwd)
OUT=$REPO/kernel/out
LAB=$HERE/lab
CERTS=$LAB/certs

KERNEL=$OUT/linux-6.1.188/arch/x86/boot/bzImage
ISO=$OUT/weaver.iso

[ -f "$KERNEL" ] || { echo "kernel missing: $KERNEL (run ./kernel/build.sh)" >&2; exit 1; }
[ -f "$CERTS/ca.key" ] || { echo "certs missing — run ./web/mkcerts.sh first" >&2; exit 1; }

# the nebula binaries + certs + configs ride on a small FAT disk so the
# guest can mount /media and run nebula from it (keeps the initramfs tiny)
mknebuladisk() {
	local name=$1
	local tmp=/tmp/opencode/nebula-$name
	rm -rf "$tmp"; mkdir -p "$tmp/etc/nebula"
	cp "$LAB/$name.yml" "$tmp/etc/nebula/nebula.yml"
	cp "$LAB/certs/ca.crt" "$tmp/etc/nebula/"
	cp "$LAB/certs/$name.crt" "$LAB/certs/$name.key" "$tmp/etc/nebula/"
	cp "$REPO/web/bin/nebula" "$tmp/nebula"
	echo "guest: $name" > "$tmp/README"
	command -v mkfs.vfat >/dev/null && command -v mcopy >/dev/null || {
		echo "mkfs.vfat/mcopy missing (apt install dosfstools mtools)" >&2
		exit 1
	}
	# mkfs.vfat -C refuses to overwrite an existing image — clear it first
	# (nebula is 26M; blocks are 1024-byte units, so 65536 = 64M image)
	rm -f "$OUT/nebula-$name.img"
	mkfs.vfat -C "$OUT/nebula-$name.img" 65536 >/dev/null 2>&1
	# mcopy's -s needs explicit dirs; copy piecewise (glob can't expand in ::
	mcopy -i "$OUT/nebula-$name.img" "$tmp/README" :: >/dev/null 2>&1
	mcopy -i "$OUT/nebula-$name.img" "$tmp/nebula" ::/nebula >/dev/null 2>&1
	mcopy -i "$OUT/nebula-$name.img" -s "$tmp/etc" ::/etc >/dev/null 2>&1
	mdir -i "$OUT/nebula-$name.img" :: >/dev/null
}

runvm() {
	local name=$1 port=$2
	echo "==> boot $name (underlay 127.0.0.1:2222$port, mesh via lighthouse)"
	# QEMU socket netdev wiring: guest UDP payloads exit to udp=<addr> and
	# inbound arrives on localaddr=<port>. The lighthouse listens on
	# 22220, so the guest must send *from* 22220 toward... no: the guest's
	# nebula sends to 127.0.0.1:22220 directly — the socket netdev relays
	# guest packets to the `udp=` endpoint. So `udp=` MUST be the
	# lighthouse address (22220), and `localaddr` is the VM's own port.
	qemu-system-x86_64 \
		-m 512 \
		-kernel "$KERNEL" \
		-append "console=ttyS0 rdinit=/init" \
		-nographic -no-reboot \
		-device virtio-net-pci,netdev=n0 \
		-netdev socket,id=n0,udp=127.0.0.1:22220,localaddr=127.0.0.1:2222$port \
		-drive file="$OUT/nebula-$name.img",format=raw,if=virtio,readonly=on
}

case "${1:-}" in
	lighthouse)
		echo "==> nebula lighthouse on host (underlay 192.168.100.1:4242)"
		exec "$REPO/web/bin/nebula" -config "$LAB/lighthouse.yml"
		;;
	host-a|host-b)
		mknebuladisk "$1"
		runvm "$1" "$([ "$1" = host-a ] && echo 2 || echo 3)"
		;;
	*)
		echo "usage: $0 {lighthouse|host-a|host-b}" >&2
		echo "  terminal 1: $0 lighthouse"
		echo "  terminal 2: $0 host-a"
		echo "  terminal 3: $0 host-b"
		echo "  then in a VM: mount -t vfat /dev/vda /media && /media/nebula -config /media/etc/nebula/nebula.yml"
		exit 1
		;;
esac