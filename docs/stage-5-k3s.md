# Stage 5 — k3s on Weaver

> **Provenance note:** drafted with AI assistance
> (GLM (glm-5.3-flash) by Z.ai) from Anthony's hands-on session, 2026-09-25/26;
> updated with AI assistance (Claude Opus 5.5) after the 2026-09-26/27
> session that got the pod Running, and after the 2026-09-28 auto-join
> work. Working diary: `dossier/worklog.md`.

## Status

**A pod runs on a Weaver node.** `spider-test` reaches `1/1 Running` on
`weaver-a` (our kernel, svos-init, musl/busybox) as a k3s v1.37.0+k3s1
agent, joined to a k3s server on the host. Reproducible with
`web/runk3s.sh` (below), verified end to end on a fresh VM. **The node
joins by itself at boot** — nobody types at its console (2026-09-28).

The README's stage table sets a bigger bar for Stage 5 — **3-node QEMU
cluster, all Weaver, enroll auto-join** — and that is **not met yet**:
the server runs on the host, there is one Weaver node, and the join uses a
fixed lab token rather than `svos-enroll`. See "Exit criterion".

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
- **svos-init boot hook** (`init/svos-init.c`) — PID 1 runs
  `/etc/svos/boot` once before the console shell, and now respawns the
  shell only when the shell itself dies (lesson 16).
- **`/etc/svos/boot`** (`kernel/rootfs/etc/svos/boot`) — reads the node's
  role from the kernel command line and starts the k3s agent.
- **`web/runk3s.sh`** — the lab, reproducible (next section).

## Running the lab

```
./web/runk3s.sh server          # terminal 1: k3s server on the host (sudo)
./web/runk3s.sh registry        # terminal 2: registry on :5000
./web/runk3s.sh agent [node]    # terminal 3: boot weaver-a; it joins by itself
./web/runk3s.sh test            # create spider-test, wait for Running
```

Topology: the **server runs on the host** (`--disable-agent`,
`--advertise-address 10.0.2.2 --tls-san 10.0.2.2`, data under
`~/svos-lab`, packaged add-ons disabled). **weaver-a** has one NIC on
**slirp** (`-netdev user`): the guest is 10.0.2.15, the host is 10.0.2.2,
DNS is 10.0.2.3. The Nebula mesh isn't part of this lab; it runs
separately with `web/runlab.sh` (Stage 3).

`agent` resets the node's stale server-side state first (lesson 9) when
the server is up, so re-booting a node is just running `agent` again.

## How a node joins by itself

Identity goes on the **kernel command line**; binaries and secrets go on
the **disk**:

```
-append "... svos.role=agent svos.name=weaver-a svos.server=10.0.2.2"
/dev/vda (FAT, mounted read-only at /media): k3s, token, registries.yaml
```

The token stays off the command line because `/proc/cmdline` is readable
by every process. `svos.ip`, `svos.gw` and `svos.dns` override the slirp
defaults per node.

svos-init runs `/etc/svos/boot` once and waits for it; with no
`svos.role` it exits at once and the machine boots to a plain shell as
before (the smoke tests boot this way). With `svos.role=agent` it does,
in order, each step tied to its lesson:

1. mount the disk; require `/media/k3s` and `/media/token`
2. network: `lo` up, `eth0` = `svos.ip`, default route via `svos.gw`
3. `/etc/passwd` + `/etc/group` (lesson 4)
4. `/etc/resolv.conf` → `svos.dns`
5. `/etc/hosts` (lesson 12)
6. `hostname` = `svos.name` (lessons 7, 9)
7. mount cgroup2 on `/sys/fs/cgroup`; tmpfs on `/var/lib/kubelet` (lesson 5)
8. `/etc/rancher/k3s/registries.yaml` from the disk, if present
9. `k3s agent --server https://$svos.server:6443 --token-file /media/token`
   in the background, logging to `/var/log/k3s-agent.log` (lesson 8)

A failing boot script is logged (`svos-init: /etc/svos/boot failed
(exit 1)`) and the boot carries on to a shell to debug from. The script
must return: a hang would keep the console shell from ever starting
(an `alarm()` timeout in svos-init would close that gap).

## Exit criterion

| Criterion | Status |
|---|---|
| `kubectl get nodes` → Weaver node `Ready` | **Met** |
| `kubectl get pod spider-test` → `Running` on a Weaver node | **Met** (2026-09-27) |
| Node joins at boot, nobody at the console | **Met** (2026-09-28) — `Ready` ~10 s after `runk3s.sh agent` |
| README: 3-node QEMU cluster, all Weaver | Not met — server is on the host, 1 Weaver node |
| README: enroll auto-join | Partly — auto-join works with a fixed lab token; `svos-enroll` (certs, per-node tokens) not yet |

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
   found"). We blamed the serial line and planned virtio-console; the
   split input turned out to be **our PID 1 stacking extra shells** on
   the console (lesson 16). Still true: send k3s output to a log file,
   never the console.
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
16. **PID 1 must respawn the shell when *the shell* dies — not on every
    SIGCHLD.** svos-init looped `spawn_shell(); pause();`, and `pause()`
    returns on any signal. Every orphan PID 1 reaped started another shell
    on the same console: 3 orphaned background jobs turned 1 shell into 4
    (reproduced in QEMU), each reading part of what was typed. k3s orphans
    processes constantly — that was lesson 8. Fix: remember the shell's
    PID and respawn only when that PID is reaped. Doing it safely needs
    two classic pieces: keep SIGCHLD/SIGINT **blocked** and sleep in
    `sigsuspend()`, which unblocks and waits atomically (a plain
    check-then-`pause()` loses a signal that lands between the two), and
    restore the original mask in every child before `exec` — the mask,
    unlike handlers, survives `exec`. After the fix: 1 shell under full
    k3s load.
17. **Build caches must not cache our own files.** `kernel/build.sh`
    copied `/init`, svos-init and `/etc` only when it rebuilt busybox, so
    an edited `/init` silently didn't ship until the staged copy was
    deleted by hand. Busybox stays cached; our files are refreshed on
    every build.

## Next steps

Toward the README's Stage 5 bar:

1. **Server on Weaver** — run `k3s server` in a Weaver VM instead of on
   the host, so the cluster is all Weaver (a `svos.role=server` branch in
   `/etc/svos/boot`).
2. **Three nodes** — two more agents; this is where the VM↔VM network
   matters again (Nebula, or a shared QEMU network). `svos.ip`/`svos.gw`
   already let each node take its own address.
3. **`svos-enroll`** — per-node join credentials instead of the fixed
   lab token on the disk.

Polish:

- an `alarm()` timeout around the boot script in svos-init, so a hung
  script can't keep the console shell from starting
- virtio-console, if the serial console still misbehaves now that
  lesson 16 is fixed
- serve more than the pause image from the registry (needed for real
  workloads; k3s's packaged add-ons are disabled for now)
- pubkey embedding into the image, so `apk add` drops
  `--allow-untrusted` (Stage 4 debt)

## Honest caveats

- The "Running" pod is the pause image — it proves the node can pull,
  sandbox and start a container, not that a real workload runs.
- k3s's packaged add-ons (coredns, traefik, metrics-server, local-storage,
  servicelb) are disabled: our registry doesn't serve their images.
- The join token is a fixed lab value (`svos-stage5`) written onto every
  node's disk; `svos-enroll` is meant to replace it.
- The k3s agent isn't supervised: if it dies, nothing restarts it.
- `apk add` still carries `--allow-untrusted` (pubkey embedding pending).
