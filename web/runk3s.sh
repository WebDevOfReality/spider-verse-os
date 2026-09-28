#!/bin/sh
# runk3s.sh — Stage 5: a k3s cluster with a Weaver node.
#
# Topology:
#
#   host (Linux/WSL)                       QEMU VM (our kernel + svos-init)
#   +---------------------------+          +-----------------------------+
#   | k3s server   :6443        |<-slirp-->| weaver-a  eth0 10.0.2.15    |
#   |   (--disable-agent)       |          |   k3s agent, started at     |
#   | registry.py  :5000        |          |   boot by /etc/svos/boot    |
#   |   (pause image, HTTP)     |          |   pulls via 10.0.2.2:5000   |
#   +---------------------------+          +-----------------------------+
#
# Slirp (-netdev user) is the VM->host path: the guest sees the host as
# 10.0.2.2 and DNS at 10.0.2.3. (Socket netdevs have no ARP responder, so
# they can't reach the host — Stage 5 lesson 2.)
#
# The node joins by itself: the kernel command line says what it is
# (svos.role=agent svos.name=<node> svos.server=10.0.2.2) and the FAT disk
# carries k3s, the join token and the registry mirror config. svos-init
# runs /etc/svos/boot, which reads both and starts the agent.
#
# Usage (three terminals, in this order):
#   ./web/runk3s.sh server          # k3s server on the host (asks for sudo)
#   ./web/runk3s.sh registry        # local pull-only registry on :5000
#   ./web/runk3s.sh agent [node]    # boot a node (default weaver-a); it joins
# then from a fourth:
#   ./web/runk3s.sh test            # create spider-test, wait for Running
#   ./web/runk3s.sh reset [node]    # forget a node (agent does this for you)
#
# Every VM boot starts from a fresh initramfs, so the agent comes back
# with a new node password. The server still holds the old one and
# rejects it ("Node password rejected, duplicate hostname") — `reset`
# deletes the old node object and its password secret (lesson 9).
# `agent` runs it first whenever the server is up. Never reset a node
# that is joined: kubelet registers its node only at startup, so a
# deleted node stays gone until the VM reboots.
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
NODE=${2:-weaver-a}

kubectl() {
	"$K3S" kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml "$@"
}

reset_node() {
	# --force: the old VM is gone, so no kubelet will ever confirm
	# the pod stopped — without it the pod sits in Terminating
	kubectl delete pod spider-test --ignore-not-found --force --grace-period=0
	kubectl delete node "$NODE" --ignore-not-found
	kubectl -n kube-system delete secret "$NODE.node-password.k3s" --ignore-not-found
}

# k3s, the join token and the registry mirror ride on a FAT disk the
# guest mounts at /media (k3s is 78M — too big for the initramfs; the
# token is a secret, so it stays off the kernel command line)
mkagentdisk() {
	command -v mkfs.vfat >/dev/null && command -v mcopy >/dev/null || {
		echo "mkfs.vfat/mcopy missing (apt install dosfstools mtools)" >&2
		exit 1
	}
	mkdir -p "$SCRATCH"
	rm -f "$SCRATCH/$NODE.img"
	mkfs.vfat -C "$SCRATCH/$NODE.img" 131072 >/dev/null   # 128M
	mcopy -i "$SCRATCH/$NODE.img" "$K3S" ::/k3s
	printf '%s\n' "$TOKEN" | mcopy -i "$SCRATCH/$NODE.img" - ::/token
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
		# forget this node's last boot, so the new one isn't rejected
		if kubectl get --raw /readyz >/dev/null 2>&1; then
			echo "==> server up: resetting $NODE"
			reset_node
		else
			echo "==> server not reachable: skipping reset (run it before the next boot)"
		fi
		mkagentdisk
		if [ -n "${SVOS_SERIAL_PORT:-}" ]; then
			console="-display none -chardev socket,id=s0,host=127.0.0.1,port=$SVOS_SERIAL_PORT,server=on,wait=off,logfile=$SCRATCH/$NODE.serial.log -serial chardev:s0"
		else
			console="-nographic"
		fi
		echo "==> booting $NODE; it joins by itself (guest log: /var/log/k3s-agent.log)"
		# shellcheck disable=SC2086  # $console is several options
		exec qemu-system-x86_64 \
			-enable-kvm -cpu host -smp 4 -m 4096 \
			-kernel "$KERNEL" \
			-append "console=ttyS0 rdinit=/init svos.role=agent svos.name=$NODE svos.server=10.0.2.2" \
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
		reset_node
		;;
	*)
		echo "usage: $0 {server|registry|agent [node]|test|reset [node]}" >&2
		exit 1
		;;
esac
