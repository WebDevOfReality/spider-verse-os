# Stage 5 — k3s on Weaver (IN PROGRESS)

> **Provenance note:** drafted with AI assistance
> (GLM (glm-5.3-flash) by Z.ai) from Anthony's hands-on session, 2026-09-25/26.
> Working diary: `dossier/worklog.md`.

## Status

**One step from exit criterion.** A Weaver OS VM reached `Ready` as a
Kubernetes node (v1.37.0+k3s1) against a k3s server on the host via slirp.
The test pod (`spider-test`) was created and scheduled onto the node, but
was still working through image-pull DNS when the session hit its limit.

## What ships

- **k3s v1.37.0+k3s1** (81 MB static Go binary, `web/bin/k3s`) — runs
  unchanged on our musl kernel.
- **Kernel #11** with the full container feature set in
  `kernel/config.svos`:
  - namespaces (PID/NET/IPC/UTS/USER), cgroups v2 (pids/freezer/device),
    MEMCG, SECCOMP+filter, POSIX_MQUEUE, SYSVIPC
  - NETFILTER + **NF_TABLES** (k3s bundles `iptables-nft` — needs NFT, not
    just xtables), IP_VS + NFCT, VXLAN, BRIDGE, VETH, MACVLAN, DUMMY
  - OVERLAY_FS, INOTIFY_USER, PROC_SYSCTL
  - **CONFIG_KEYS** (kubelet ContainerManager reads /proc/sys/kernel/keys/*)
- **Lab topology** (this took several iterations — see lesson 1):
  - k3s **server on the host** (sudo, `--disable-agent`, ephemeral
    `--data-dir /tmp/opencode/k3s-data`, `--token svos-stage5`,
    `--advertise-address 10.0.2.2 --tls-san 10.0.2.2`)
  - agent VM reaches host via **slirp** (`-netdev user,id=n1`): guest gets
    10.0.2.15, gateway 10.0.2.2
  - Nebula mesh unchanged on socket-netdev links (LH VM with two netdevs,
    per-spoke subnets 192.168.100.0/24 + 192.168.200.0/24)

## Exit criterion

`kubectl get nodes` → Weaver node `Ready`. **Met.**

`kubectl get pod spider-test` → `Running` on the node. **One step out** —
blocked only by image-pull DNS at session end; the fix (resolv.conf) is
applied, pod needs re-creating on a clean boot.

## The agent runtime preconditions (every fresh boot, in order)

1. `ip link set lo up; ip addr add 192.168.100.2/24 dev eth0; ip link set eth0 up`
2. `ip addr add 10.0.2.15/24 dev eth1; ip link set eth1 up; ip route add default via 10.0.2.2`
3. `echo root:x:0:0:root:/:/bin/sh > /etc/passwd; echo root:x:0: > /etc/group`
   (kubelet's user-namespace manager reads /etc/passwd — without it:
   "failed to create kubelet: kubelet mappings: open /etc/passwd")
4. `echo nameserver 10.0.2.3 > /etc/resolv.conf` (slirp DNS — without it
   image pulls fail "lookup registry-1.docker.io: Try again")
5. `mkdir -p /media /sys/fs/cgroup /run /var/lib/rancher /var/lib/kubelet
   /var/log /etc/rancher /etc/cni /opt/cni /var/cache/misc`
6. `mount -t vfat /dev/vda /media; mount -t cgroup2 none /sys/fs/cgroup;
   mount -t tmpfs none /var/lib/kubelet` (kubelet stats the "rootfs"
   device — a real mounted fs for /var/lib/kubelet fixes "cannot find
   filesystem info for device rootfs")
7. `hostname weaver-a` (else the node registers as "(none)")
8. `echo svos-stage5 > /tmp/token && /media/k3s agent --server
   https://10.0.2.2:6443 --token-file /tmp/token`

## What we learned (the receipts)

1. **k3s on the host needs sudo** — it hard-codes `/etc/rancher` mkdir.
   Don't fight it: `--data-dir /tmp/...` keeps it ephemeral, no system
   install.
2. **QEMU socket netdev has no ARP responder** — a guest ARPs for the
   gateway MAC and nothing answers (`Host is unreachable` even with a valid
   route). Static ARP entries via busybox `arp -s` kept failing/garbling.
   **Slirp (`-netdev user`) is the correct answer for VM→host traffic.**
   Socket netdev stays for VM↔VM nebula underlay only.
3. **The server's advertised address is in cert SANs and the agent-config
   redirect.** Without `--advertise-address 10.0.2.2 --tls-san 10.0.2.2`,
   the agent redirects itself to `127.0.0.1:6444` (its internal LB) — an
   address that means "the agent's own localhost" inside the VM, where
   nothing listens (`connection reset by peer` on /cacerts).
4. **kubelet needs /etc/passwd + /etc/group** — "failed to create kubelet:
   kubelet mappings: open /etc/passwd: no such file". One line each.
5. **kubelet needs a real mounted fs for /var/lib/kubelet** — "cannot find
   filesystem info for device rootfs". A tmpfs mount fixes it.
6. **kube-proxy needs NFT, not just xtables** — k3s bundles
   `iptables-nft`; with `NETFILTER_XTABLES` alone: "Failed to initialize
   nft: Protocol not supported". Add `NF_TABLES` + `NFT_NAT` + `NFT_COMPAT`.
7. **CONFIG_KEYS** — kubelet ContainerManager reads
   `/proc/sys/kernel/keys/root_maxkeys` (fourth Kconfig gate lesson; this
   one has no menu gate, it was just missing).
8. **Serial console under load is unreliable.** Once kubelet+containerd run,
   ttyS0 echoes interleave and drop — commands arrive split ("sh: ta2: not
   found"). Workarounds: one short command per connection, `&&`-chain a
   whole setup into one line sent once, `dmesg -c` to clear floods, and
   when fully wedged: kill qemu and reboot the VM (the guest re-registers
   automatically). The **real fix** is virtio-console
   (`-device virtio-serial`) — deferred to Stage 5 polish.
9. **Node-password churn** — every hostname change + `/etc/rancher/node/
   password` mismatch registers a NEW node object (weaver-a,
   weaver-a-6670f3cd, weaver-t2-go). Fixed by `rm -f
   /etc/rancher/node/password` and relaunching with `--with-node-id`, or
   by keeping the hostname stable. Stale nodes need `kubectl delete node`
   cleanup (see the 3 NotReady entries).
10. **`/tmp/opencode` got wiped mid-session** (tmpfiles cleanup at 08:33) —
    killed the server data dir, serial sockets, and all VMs. Everything in
    the repo survived. Lab relaunch takes ~2 min (3 VMs + setup block).

## Next steps (pickup)

1. Clean the cluster:
   `kubectl delete node weaver-a weaver-a-6670f3cd weaver-t2-go` (+ pod).
2. Relaunch 3 VMs + server (commands above; server needs sudo with the
   advertise/tls flags).
3. Run the A-VM setup block, hostname weaver-a, launch agent.
4. `kubectl get nodes` → weaver-a Ready.
5. Re-create the pod (yaml in dossier/worklog.md) → `Running` = exit
   criterion met → write final docs + commit.
6. Optional polish: virtio-console for load-heavy guests; embed passwd/
   group/resolv/hostname + k3s dirs into rcS so the agent bootstraps
   itself; pubkey embedding into the image (Stage 4 debt).

## Honest caveats

- Pod never actually Ran (best state: ContainerCreating with pull errors,
  pre-DNS-fix). The pull with DNS was untested end-to-end before the
  session limit.
- Serial console reliability remains the session's biggest friction —
  virtio-console is queued as polish.
- `apk add` still carries `--allow-untrusted` (pubkey embedding pending).