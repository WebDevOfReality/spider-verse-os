#!/bin/sh
# agent.sh — Stage 5: bootstrap the k3s agent inside a Weaver guest.
#
# Runs from the agent disk (web/runk3s.sh agent builds it):
#   mkdir -p /media && mount -t vfat /dev/vda /media && sh /media/agent.sh
#
# Each step is a runtime precondition found the hard way; the lesson
# numbers point into docs/stage-5-k3s.md. k3s output goes to
# /var/log/k3s-agent.log, NOT the serial console — the console drops
# input once kubelet and containerd get busy (lesson 8).

# network: eth0 is slirp — host 10.0.2.2, DNS 10.0.2.3
ip link set lo up
ip link set eth0 up
ip addr add 10.0.2.15/24 dev eth0
ip route add default via 10.0.2.2

# kubelet's user-namespace manager reads these (lesson 4)
echo 'root:x:0:0:root:/:/bin/sh' > /etc/passwd
echo 'root:x:0:' > /etc/group
# image pulls resolve names even through the mirror
echo 'nameserver 10.0.2.3' > /etc/resolv.conf
# containerd copies /etc/hosts into every pod sandbox
printf '127.0.0.1 localhost\n10.0.2.15 weaver-a\n' > /etc/hosts

mkdir -p /sys/fs/cgroup /run /var/lib/rancher /var/lib/kubelet /var/log \
	/etc/rancher/k3s /etc/cni /opt/cni /var/cache/misc
mountpoint -q /sys/fs/cgroup || mount -t cgroup2 none /sys/fs/cgroup
# kubelet needs a real mounted fs here (lesson 5)
mountpoint -q /var/lib/kubelet || mount -t tmpfs none /var/lib/kubelet

# pull through the host's local registry, not Docker Hub
cp /media/registries.yaml /etc/rancher/k3s/registries.yaml

# a stable name, else the node registers as "(none)" (lessons 7, 9)
hostname weaver-a
echo svos-stage5 > /tmp/token
/media/k3s agent --server https://10.0.2.2:6443 --token-file /tmp/token \
	--node-ip 10.0.2.15 > /var/log/k3s-agent.log 2>&1 &
echo "agent launched; log: /var/log/k3s-agent.log"
