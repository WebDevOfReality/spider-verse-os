# Stage 5 — k3s on Weaver

> **Provenance note:** drafted with AI assistance
> (GLM (glm-5.3-flash) by Z.ai) from Anthony's hands-on session, 2026-09-25/26;
> updated with AI assistance (Claude Opus 5.5) after the 2026-09-26/27
> session that got the pod Running. Working diary: `dossier/worklog.md`.

## Status

**A pod runs on a Weaver node.** `spider-test` reaches `1/1 Running` on
`weaver-a` (our kernel, svos-init, musl/busybox) as a k3s v1.37.0+k3s1
agent, joined to a k3s server on the host. Reproducible with
`web/runk3s.sh` (below), verified end to end on a fresh VM.

The README's stage table sets a bigger bar for Stage 5 — **3-node QEMU
cluster, all Weaver, enroll auto-join** — and that is **not met yet**:
the server runs on the host, there is one Weaver node, and joining is
manual. See "Exit criterion".

## What ships

- **k3s v1.37.0+k3s1** (81 MB static Go binary, `web/bin/k3s`) — runs
  unchanged on our musl kernel.
- **Kernel** with the full container feature set in `kernel/config.svos`:
  - namespaces (PID/NET/IPC/UTS/USER), cgroups v2 (pids/freezer/device),
    MEMCG, SECCOMP+filter, POSIX_MQUEUE, SYSVIPC
  - **BPF_SYSCALL + CGROUP_BPF** (cgroup v2 device control — lesson 13)
  - NETFILTER + **NF_TABLES** (k3s bundles `iptables-nft` — needs NFT, not
    just xtables), IP_VS + NFCT, VXLAN, BRIDGE, VETH, MACVLAN, DUMMY
  - OVERLAY_FS, INOTIFY_USER, PROC_SYSCTL
  - **CONFIG_KEYS** (kubelet ContainerManager reads /proc/sys/kernel/keys/*)
- **`/init` switches root into a tmpfs** before svos-init
  (`kernel/rootfs/init`) — container runtimes can't `pivot_root` out of
  the initramfs (lesson 14).
- **`scripts/registry.py`** + `registry/` — a pull-only Docker Registry v2
  on the host serving `rancher/mirrored-pause:3.10.2` over plain HTTP, so
  the guest never needs Docker Hub, TLS or a CA bundle.
- **`web/runk3s.sh`** — the lab, reproducible (next section).

## Running the lab

```
./web/runk3s.sh server     # terminal 1: k3s server on the host (sudo)
./web/runk3s.sh registry   # terminal 2: registry on :5000
./web/runk3s.sh reset      # before every VM boot (lesson 9)
./web/runk3s.sh agent      # terminal 3: boot weaver-a, then at its shell:
                           #   mkdir -p /media && mount -t vfat /dev/vda /media && sh /media/agent.sh
./web/runk3s.sh test       # create spider-test, wait for Running
```

Topology: the **server runs on the host** (`--disable-agent`,
`--advertise-address 10.0.2.2 --tls-san 10.0.2.2`, data under
`~/svos-lab`, packaged add-ons disabled). **weaver-a** has one NIC on
**slirp** (`-netdev user`): the guest is 10.0.2.15, the host is 10.0.2.2,
DNS is 10.0.2.3. k3s, `agent.sh` and `registries.yaml` ride on a 128M FAT
disk mounted at `/media`. The Nebula mesh isn't part of this lab; it runs
separately with `web/runlab.sh` (Stage 3).

## The agent runtime preconditions

`web/lab/agent.sh` runs these in the guest on every boot, each commented
with its lesson:

1. network: `lo` up, `eth0` 10.0.2.15/24, default route via 10.0.2.2
2. `/etc/passwd` + `/etc/group` (lesson 4)
3. `/etc/resolv.conf` → 10.0.2.3 (slirp DNS)
4. `/etc/hosts` (lesson 12)
5. mount cgroup2 on `/sys/fs/cgroup`; tmpfs on `/var/lib/kubelet` (lesson 5)
6. `/etc/rancher/k3s/registries.yaml`: docker.io → `http://10.0.2.2:5000`
7. `hostname weaver-a` (lessons 7, 9)
8. `k3s agent --server https://10.0.2.2:6443 --node-ip 10.0.2.15`, logging
   to `/var/log/k3s-agent.log`, not the serial console (lesson 8)

## Exit criterion

| Criterion | Status |
|---|---|
| `kubectl get nodes` → Weaver node `Ready` | **Met** |
| `kubectl get pod spider-test` → `Running` on a Weaver node | **Met** (2026-09-27) |
| README: 3-node QEMU cluster, all Weaver | Not met — server is on the host, 1 Weaver node |
| README: enroll auto-join | Not met — the agent is started by hand |

## What we learned (the receipts)

1. **k3s on the host needs sudo** — it hard-codes `/etc/rancher` mkdir.
   Don't fight it: `--data-dir` somewhere scratch keeps it out of the
   system, no install.
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
   found"). What works: send one short line (`sh /media/agent.sh`) and
   send the agent's output to a log file, never the console. The **real
   fix** is virtio-console (`-device virtio-serial`) — deferred to polish.
9. **Node-password churn** — the agent stores a node password in
   `/etc/rancher/node/password`; on Weaver that lives in RAM, so every boot
   brings a new one, and the server rejects it ("Node password rejected,
   duplicate hostname"). Changing hostnames instead registers new node
   objects (weaver-a, weaver-a-6670f3cd, weaver-t2-go). Fix: before each
   boot, delete the node **and** its `<node>.node-password.k3s` secret in
   kube-system (`runk3s.sh reset`). Order matters: kubelet registers its
   node only at startup, so deleting the node of a *running* agent leaves
   it gone ("Node is being deleted") until the agent restarts.
10. **`/tmp/opencode` got wiped mid-session** (tmpfiles cleanup at 08:33) —
    killed the server data dir, serial sockets, and all VMs. Everything in
    the repo survived. The lab now lives in `~/svos-lab` (`SVOS_LAB`).
11. **A registry must label every response with the digest of *those*
    bytes.** Ours sent the amd64 manifest's digest on the tag's manifest
    list. containerd trusts `Docker-Content-Digest` when it resolves a tag,
    so it fetched the 501-byte amd64 manifest expecting the list's 2762
    bytes: "short read: expected 2261 bytes but got 0" (2762 − 501). Also:
    a HEAD response must not carry a body — on a keep-alive connection the
    stray bytes read as the start of the next response.
12. **containerd needs `/etc/hosts`** — it copies the host's file into
    every pod sandbox: "failed to generate sandbox hosts file … open
    /etc/hosts: no such file or directory". Same class as lesson 4: a
    minimal root is missing a file every "normal" distro has.
13. **cgroup v2 device control is eBPF** — v1 had a `devices.allow` file
    (`CGROUP_DEVICE`); v2 has none, so runc attaches a `BPF_CGROUP_DEVICE`
    program to each container's cgroup. Without the `bpf(2)` syscall:
    "bpf_prog_query(BPF_CGROUP_DEVICE) failed: function not implemented".
    Needs `BPF_SYSCALL` + `CGROUP_BPF` — and `CGROUP_BPF` depends on
    `BPF_SYSCALL`, so setting it alone gets silently dropped (Kconfig gate
    lesson five).
14. **You can't `pivot_root` out of the initramfs.** runc jails a
    container with `pivot_root(2)`, which needs the current root to be a
    real mount it can move aside. The initramfs is the kernel's special
    `rootfs`, which can never be unmounted: "pivot_root .: invalid
    argument". Every RAM-booting distro solves it the same way: copy the
    initramfs into a tmpfs and `switch_root` into it before starting init.
    `/init` now does that (falling back to the old path if it fails).
15. **The CI failures weren't ours.** Every red run since Sep 23 was
    musl-cross-make downloading `config.sub` from savannah's gitweb, which
    502s intermittently. Switching to savannah's cgit URL passed once,
    then timed out on the next run — the whole host is unreliable from CI.
    So the pinned revision now lives in the repo (`toolchain/config.sub`,
    checked against musl-cross-make's own sha1) and the build never goes
    to savannah. The GNU tarballs retry on 5xx, and CI builds the
    toolchain once and caches it.

## Next steps

Toward the README's Stage 5 bar:

1. **Server on Weaver** — run `k3s server` in a Weaver VM instead of on
   the host, so the cluster is all Weaver.
2. **Three nodes** — two more agents; this is where the VM↔VM network
   matters again (Nebula, or a shared QEMU network).
3. **Auto-join** — `svos-enroll` starts the agent at boot, with the
   preconditions baked into the image (rcS) instead of typed at a shell.

Polish:

- virtio-console for load-heavy guests (lesson 8)
- serve more than the pause image from the registry (needed for real
  workloads; k3s's packaged add-ons are disabled for now)
- pubkey embedding into the image, so `apk add` drops
  `--allow-untrusted` (Stage 4 debt)

## Honest caveats

- The "Running" pod is the pause image — it proves the node can pull,
  sandbox and start a container, not that a real workload runs.
- k3s's packaged add-ons (coredns, traefik, metrics-server, local-storage,
  servicelb) are disabled: our registry doesn't serve their images.
- The lab needs a person at the guest's serial shell to start the agent.
- `apk add` still carries `--allow-untrusted` (pubkey embedding pending).
