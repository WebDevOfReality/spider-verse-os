#!/bin/sh
# runk3s.sh — Stage 5: a k3s cluster with a Weaver node.
#
# Topology:
#
#   host (Linux/WSL)                       QEMU VM (our kernel + svos-init)
#   +---------------------------+          +-----------------------------+
#   | k3s server   :6443        |<-slirp-->| weaver-a  eth0 10.0.2.15    |
#   |   (--disable-agent)       |          |   k3s agent (from /media)   |
#   | registry.py  :5000        |          |   containerd pulls from     |
#   |   (pause image, HTTP)     |          |   http://10.0.2.2:5000      |
#   +---------------------------+          +-----------------------------+
#
# Slirp (-netdev user) is the VM->host path: the guest sees the host as
# 10.0.2.2 and DNS at 10.0.2.3. (Socket netdevs have no ARP responder, so
# they can't reach the host — Stage 5 lesson 2.)
#
# Usage (three terminals, in this order):
#   ./web/runk3s.sh server     # k3s server on the host (asks for sudo)
#   ./web/runk3s.sh registry   # local pull-only registry on :5000
#   ./web/runk3s.sh agent      # boot weaver-a; then at its shell:
#                              #   mkdir -p /media && mount -t vfat /dev/vda /media && sh /media/agent.sh
# then from a fourth:
#   ./web/runk3s.sh test       # create spider-test, wait for Running
#   ./web/runk3s.sh reset      # before re-booting the VM (see below)
#
# Every VM boot starts from a fresh initramfs, so the agent comes back
# with a new node password. The server still holds the old one and
# rejects it ("Node password rejected, duplicate hostname") — `reset`
# deletes the old node object and its password secret (lesson 9).
# Run it BEFORE booting the agent, never while one is joined: kubelet
# registers its node only at startup, so a deleted node stays gone.
#
# SVOS_LAB (default ~/svos-lab) holds the server data dir and the agent
# disk. SVOS_SERIAL_PORT=<port> puts the VM console on a TCP socket (with
# a log file) instead of this terminal, for scripted runs.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)          # web/
REPO=$(cd "$HERE/.." && pwd)
LAB=$HERE/lab
SCRATCH=${SVOS_LAB:-$HOME/svos-lab}
KERNEL=$REPO/kernel/out/linux-6.1.188/arch/x86/boot/bzImage
K3S=$REPO/web/bin/k3s
TOKEN=svos-stage5
NODE=weaver-a

kubectl() {
	"$K3S" kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml "$@"
}

# k3s, the bootstrap script and the registry mirror ride on a FAT disk
# the guest mounts at /media (k3s is 78M — too big for the initramfs)
mkagentdisk() {
	command -v mkfs.vfat >/dev/null && command -v mcopy >/dev/null || {
		echo "mkfs.vfat/mcopy missing (apt install dosfstools mtools)" >&2
		exit 1
	}
	mkdir -p "$SCRATCH"
	rm -f "$SCRATCH/$NODE.img"
	mkfs.vfat -C "$SCRATCH/$NODE.img" 131072 >/dev/null   # 128M
	mcopy -i "$SCRATCH/$NODE.img" "$K3S" ::/k3s
	mcopy -i "$SCRATCH/$NODE.img" "$LAB/agent.sh" ::/agent.sh
	mcopy -i "$SCRATCH/$NODE.img" "$LAB/registries.yaml" ::/registries.yaml
}

case "${1:-}" in
	server)
		mkdir -p "$SCRATCH/k3s-data"
		# --advertise-address/--tls-san: the agent must be told to come
		# back to 10.0.2.2, not the server's 127.0.0.1 (lesson 3)
		# --disable: only the pause image is in our registry; the
		# packaged add-ons would sit in ImagePullBackOff
		exec sudo "$K3S" server --disable-agent \
			--data-dir "$SCRATCH/k3s-data" --token "$TOKEN" \
			--advertise-address 10.0.2.2 --tls-san 10.0.2.2 \
			--write-kubeconfig-mode 644 \
			--disable traefik,servicelb,metrics-server,local-storage,coredns
		;;
	registry)
		exec python3 "$REPO/scripts/registry.py" 5000
		;;
	agent)
		[ -f "$KERNEL" ] || { echo "kernel missing: $KERNEL (run ./kernel/build.sh)" >&2; exit 1; }
		mkagentdisk
		if [ -n "${SVOS_SERIAL_PORT:-}" ]; then
			console="-display none -chardev socket,id=s0,host=127.0.0.1,port=$SVOS_SERIAL_PORT,server=on,wait=off,logfile=$SCRATCH/$NODE.serial.log -serial chardev:s0"
		else
			console="-nographic"
			echo "==> at the weaver shell: mkdir -p /media && mount -t vfat /dev/vda /media && sh /media/agent.sh"
		fi
		# shellcheck disable=SC2086  # $console is several options
		exec qemu-system-x86_64 \
			-enable-kvm -cpu host -smp 4 -m 4096 \
			-kernel "$KERNEL" \
			-append "console=ttyS0 rdinit=/init" \
			-no-reboot $console \
			-device virtio-net-pci,netdev=n0 -netdev user,id=n0 \
			-drive file="$SCRATCH/$NODE.img",format=raw,if=virtio
		;;
	test)
		kubectl apply -f "$LAB/spider-test.yaml"
		echo "==> waiting for spider-test to be Running"
		kubectl wait --for=jsonpath='{.status.phase}'=Running \
			pod/spider-test --timeout=180s
		kubectl get pod spider-test -o wide
		;;
	reset)
		# --force: the old VM is gone, so no kubelet will ever confirm
		# the pod stopped — without it the pod sits in Terminating
		kubectl delete pod spider-test --ignore-not-found --force --grace-period=0
		kubectl delete node "$NODE" --ignore-not-found
		kubectl -n kube-system delete secret "$NODE.node-password.k3s" --ignore-not-found
		;;
	*)
		echo "usage: $0 {server|registry|agent|test|reset}" >&2
		exit 1
		;;
esac
