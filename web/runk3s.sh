#!/bin/sh
# runk3s.sh — Stage 5: a k3s cluster that is all Weaver.
#
# Topology (every box is a QEMU VM: our kernel + svos-init):
#
#   earth-616 (server)        weaver-a (agent)          weaver-b ...
#   eth1 192.168.76.10        eth1 192.168.76.11        eth1 .12
#    |  k3s server :6443        |  k3s agent              |
#    +--------------------------+-------------------------+-- cluster LAN
#                               QEMU mcast 230.0.76.1:7676   (VM<->VM)
#   eth0 slirp (each VM has its own): host = 10.0.2.2
#     server: host 127.0.0.1:6443 -> guest :6443 (kubectl from the host)
#     agents: pull images from registry.py on the host, 10.0.2.2:5000
#
# Two NICs because neither network does both jobs: slirp reaches the host
# but every VM gets its own private copy of it (they can't see each
# other); a socket netdev joins the VMs but has no host on it (lesson 2).
# Each VM on the shared segment needs its own MAC — QEMU's default is the
# same for all of them.
#
# Nodes configure themselves: the kernel command line says what each one
# is (svos.role, svos.name, svos.lan, svos.server) and its FAT disk
# carries k3s and the join token. svos-init runs /etc/svos/boot, which
# reads both (docs/stage-5-k3s.md, "How a node joins by itself").
#
# Usage (one terminal each, in this order):
#   ./web/runk3s.sh server          # boot earth-616, the control plane
#   ./web/runk3s.sh registry        # local pull-only registry on :5000
#   ./web/runk3s.sh agent [node]    # boot a node (default weaver-a); it joins
# then from another:
#   ./web/runk3s.sh test            # create spider-test, wait for Running
#   ./web/runk3s.sh reset [node]    # forget a node (agent does this for you)
#   ./web/runk3s.sh kubectl ...     # kubectl against the server VM
#
# No sudo anywhere: k3s runs as root inside the VMs, not on the host.
#
# SVOS_DATA=disk (server only) keeps the cluster on an ext4 volume
# ($SCRATCH/earth-616.data.ext4) that survives reboots; the default,
# tmpfs, starts a fresh cluster on every server boot. Stop a disk-backed
# server with `reboot -f` on its console, not by killing QEMU (lesson 19).
#
# Every agent boot starts from a fresh initramfs, so the agent comes back
# with a new node password. A server that remembers the old one rejects
# it ("Node password rejected, duplicate hostname") — `reset` deletes the
# old node object and its password secret (lesson 9). `agent` runs it
# first whenever the server is up. Never reset a node that is joined:
# kubelet registers its node only at startup, so a deleted node stays
# gone until the VM reboots.
#
# SVOS_LAB (default ~/svos-lab) holds the disks and the fetched
# kubeconfig. SVOS_SERIAL_PORT=<port> puts the VM console on a TCP socket
# (with a log file) instead of this terminal, for scripted runs — give
# each VM its own port.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)          # web/
REPO=$(cd "$HERE/.." && pwd)
LAB=$HERE/lab
SCRATCH=${SVOS_LAB:-$HOME/svos-lab}
KERNEL=$REPO/kernel/out/linux-6.1.188/arch/x86/boot/bzImage
K3S=$REPO/web/bin/k3s
TOKEN=svos-stage5
SERVER=earth-616
LANNET=192.168.76                       # the cluster LAN, a /24
LANBUS=230.0.76.1:7676                  # its QEMU multicast group:port
KUBECONFIG_FILE=$SCRATCH/kubeconfig.yaml

# a node's last address octet on the cluster LAN; the MAC is derived from it
lan_octet() {
	case "$1" in
		"$SERVER") echo 10 ;;
		weaver-a) echo 11 ;;
		weaver-b) echo 12 ;;
		weaver-c) echo 13 ;;
		*) echo "unknown node '$1' (weaver-a|weaver-b|weaver-c)" >&2; exit 1 ;;
	esac
}

# the server VM writes its admin kubeconfig onto its FAT disk; copy it
# out each time, since a tmpfs server makes new certs on every boot
fetch_kubeconfig() {
	mcopy -n -o -i "$SCRATCH/$SERVER.img" ::/k3s.yaml "$KUBECONFIG_FILE" \
		2>/dev/null
}

kubectl() {
	fetch_kubeconfig || {
		echo "no kubeconfig on $SERVER's disk yet (is the server up?)" >&2
		return 1
	}
	"$K3S" kubectl --kubeconfig "$KUBECONFIG_FILE" "$@"
}

reset_node() {
	# --force: the old VM is gone, so no kubelet will ever confirm
	# the pod stopped — without it the pod sits in Terminating
	kubectl delete pod spider-test --ignore-not-found --force --grace-period=0
	kubectl delete node "$NODE" --ignore-not-found
	kubectl -n kube-system delete secret "$NODE.node-password.k3s" --ignore-not-found
}

# k3s and the join token ride on a FAT disk the guest mounts at /media
# (k3s is 78M — too big for the initramfs; the token is a secret, so it
# stays off the kernel command line). Agents also get the registry
# mirror config.
mkdisk() {
	command -v mkfs.vfat >/dev/null && command -v mcopy >/dev/null || {
		echo "mkfs.vfat/mcopy missing (apt install dosfstools mtools)" >&2
		exit 1
	}
	mkdir -p "$SCRATCH"
	rm -f "$SCRATCH/$NODE.img"
	mkfs.vfat -C "$SCRATCH/$NODE.img" 131072 >/dev/null   # 128M
	mcopy -i "$SCRATCH/$NODE.img" "$K3S" ::/k3s
	printf '%s\n' "$TOKEN" | mcopy -i "$SCRATCH/$NODE.img" - ::/token
	[ "$NODE" = "$SERVER" ] ||
		mcopy -i "$SCRATCH/$NODE.img" "$LAB/registries.yaml" ::/registries.yaml
}

# boot <extra -append words> <extra qemu options...>: one cluster VM
boot() {
	append=$1; shift
	[ -f "$KERNEL" ] || { echo "kernel missing: $KERNEL (run ./kernel/build.sh)" >&2; exit 1; }
	octet=$(lan_octet "$NODE")
	mac=$(printf '52:54:00:76:00:%02x' "$octet")
	if [ -n "${SVOS_SERIAL_PORT:-}" ]; then
		console="-display none -chardev socket,id=s0,host=127.0.0.1,port=$SVOS_SERIAL_PORT,server=on,wait=off,logfile=$SCRATCH/$NODE.serial.log -serial chardev:s0"
	else
		console="-nographic"
	fi
	# NIC order is interface order: n0 (slirp) is eth0, n1 (LAN) is eth1
	# shellcheck disable=SC2086  # $console is several options
	exec qemu-system-x86_64 \
		-enable-kvm -cpu host -smp 4 -m 4096 \
		-kernel "$KERNEL" \
		-append "console=ttyS0 rdinit=/init svos.name=$NODE svos.lan=$LANNET.$octet/24 $append" \
		-no-reboot $console \
		-drive file="$SCRATCH/$NODE.img",format=raw,if=virtio \
		"$@" \
		-device virtio-net-pci,netdev=n1,mac="$mac" \
		-netdev socket,id=n1,mcast="$LANBUS",localaddr=127.0.0.1
}

case "${1:-}" in
	server)
		NODE=$SERVER
		mkdisk
		data=tmpfs
		set --
		if [ "${SVOS_DATA:-tmpfs}" = disk ]; then
			data=disk
			vol=$SCRATCH/$SERVER.data.ext4
			if [ ! -f "$vol" ]; then
				# sparse: 4G on paper, only what k3s writes on disk
				truncate -s 4G "$vol"
				mkfs.ext4 -q -F -L k3s-data "$vol"
			fi
			set -- -drive file="$vol",format=raw,if=virtio
		fi
		echo "==> booting $SERVER (k3s server, data on $data); kubeconfig lands in $KUBECONFIG_FILE"
		# slirp forwards host 127.0.0.1:6443 here: the kubeconfig k3s
		# writes names https://127.0.0.1:6443, so it works unchanged
		boot "svos.role=server svos.data=$data" "$@" \
			-device virtio-net-pci,netdev=n0 \
			-netdev user,id=n0,hostfwd=tcp:127.0.0.1:6443-:6443
		;;
	registry)
		exec python3 "$REPO/scripts/registry.py" 5000
		;;
	agent)
		NODE=${2:-weaver-a}
		lan_octet "$NODE" >/dev/null
		# forget this node's last boot, so the new one isn't rejected
		if kubectl get --raw /readyz >/dev/null 2>&1; then
			echo "==> server up: resetting $NODE"
			reset_node
		else
			echo "==> server not reachable: skipping reset (run it before the next boot)"
		fi
		mkdisk
		echo "==> booting $NODE; it joins by itself (guest log: /var/log/k3s-agent.log)"
		boot "svos.role=agent svos.server=$LANNET.10" \
			-device virtio-net-pci,netdev=n0 -netdev user,id=n0
		;;
	test)
		kubectl apply -f "$LAB/spider-test.yaml"
		echo "==> waiting for spider-test to be Running"
		kubectl wait --for=jsonpath='{.status.phase}'=Running \
			pod/spider-test --timeout=180s
		kubectl get pod spider-test -o wide
		;;
	reset)
		NODE=${2:-weaver-a}
		reset_node
		;;
	kubectl)
		shift
		kubectl "$@"
		;;
	*)
		echo "usage: $0 {server|registry|agent [node]|test|reset [node]|kubectl ...}" >&2
		exit 1
		;;
esac
