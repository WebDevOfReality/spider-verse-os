# Stage 5 — k3s on Weaver

> **Provenance note:** drafted with AI assistance
> (GLM (glm-5.3-flash) by Z.ai) from Anthony's hands-on session, 2026-09-25/26;
> updated with AI assistance (Claude Opus 5.5) after the 2026-09-26/27
> session that got the pod Running, after the 2026-09-28 auto-join
> work, and after the 2026-10-01 server-on-Weaver work. Working diary:
> `dossier/worklog.md`.

## Status

**The cluster is all Weaver.** The k3s v1.37.0+k3s1 server runs in a
Weaver VM (`earth-616`, 2026-10-01), and `spider-test` reaches
`1/1 Running` on the Weaver agent `weaver-a` (our kernel, svos-init,
musl/busybox). The VMs talk over a shared QEMU network, not through the
host. **Nodes join by themselves at boot** — nobody types at a console
(2026-09-28). No sudo: k3s runs as root inside the VMs. Reproducible with
`web/runk3s.sh` (below).

The README's stage table sets the bar for Stage 5 — **3-node QEMU
cluster, all Weaver, enroll auto-join** — and that is **not met yet**:
there is one agent node, and the join uses a fixed lab token rather than
`svos-enroll`. See "Exit criterion".

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
  role from the kernel command line and starts the k3s server or agent.
- **CONFIG_EXT4_FS** — the server's persistent datastore volume
  (`svos.data=disk`).
- **`web/runk3s.sh`** — the lab, reproducible (next section).

## Running the lab

```
./web/runk3s.sh server          # terminal 1: boot earth-616, the control plane
./web/runk3s.sh registry        # terminal 2: registry on :5000
./web/runk3s.sh agent [node]    # terminal 3: boot weaver-a; it joins by itself
./web/runk3s.sh test            # create spider-test, wait for Running
./web/runk3s.sh kubectl ...     # kubectl against the server VM
```

Topology — every VM has two NICs (lesson 18):

```
earth-616 (server)      weaver-a (agent)      weaver-b, weaver-c
eth1 192.168.76.10      eth1 192.168.76.11    eth1 .12, .13
  +-----------------------+---------------------+---- cluster LAN
                QEMU multicast 230.0.76.1:7676 (VM<->VM)
eth0: slirp, a private copy per VM (guest 10.0.2.15, host 10.0.2.2)
  server: host 127.0.0.1:6443 -> guest :6443 (kubectl from the host)
  agents: pull from registry.py on the host at 10.0.2.2:5000
```

The server runs `--disable-agent` (control plane only), advertises
192.168.76.10, and has the packaged add-ons disabled. It copies its admin
kubeconfig onto its FAT disk; `runk3s.sh` reads it from there into
`~/svos-lab/kubeconfig.yaml` before every kubectl call. The kubeconfig
names `https://127.0.0.1:6443`, which slirp forwards into the VM, so it
works unchanged. The Nebula mesh isn't part of this lab; it runs
separately with `web/runlab.sh` (Stage 3).

Where the server keeps its state is your choice:

- **tmpfs** (default): a fresh cluster on every server boot — new CA,
  new kubeconfig. Reboot the agents after rebooting the server.
- **`SVOS_DATA=disk ./web/runk3s.sh server`**: an ext4 volume
  (`~/svos-lab/earth-616.data.ext4`, created on first use) on
  `/dev/vdb`, mounted at `/var/lib/rancher`. The cluster survives server
  reboots — **if the server is shut down cleanly**: type `reboot -f` on
  its console (QEMU exits, thanks to `-no-reboot`), never just kill QEMU
  (lesson 19).

`agent` resets the node's stale server-side state first (lesson 9) when
the server is up, so re-booting a node is just running `agent` again.

## How a node joins by itself

Identity goes on the **kernel command line**; binaries and secrets go on
the **disk**:

```
-append "... svos.role=agent svos.name=weaver-a svos.lan=192.168.76.11/24
            svos.server=192.168.76.10"
/dev/vda (FAT, mounted read-only at /media): k3s, token, registries.yaml
```

The token stays off the command line because `/proc/cmdline` is readable
by every process. `svos.lan` puts the node on the cluster LAN (`eth1`),
and that address becomes its k3s node IP. `svos.ip`, `svos.gw` and
`svos.dns` override the slirp defaults for `eth0`.

svos-init runs `/etc/svos/boot` once and waits for it; with no
`svos.role` it exits at once and the machine boots to a plain shell as
before (the smoke tests boot this way). With `svos.role=agent` it does,
in order, each step tied to its lesson:

1. mount the disk; require `/media/k3s` and `/media/token`
2. network: `lo` up, `eth0` = `svos.ip`, default route via `svos.gw`;
   `eth1` = `svos.lan` if set
3. `/etc/passwd` + `/etc/group` (lesson 4)
4. `/etc/resolv.conf` → `svos.dns`
5. `/etc/hosts` (lesson 12)
6. `hostname` = `svos.name` (lessons 7, 9)
7. mount cgroup2 on `/sys/fs/cgroup`; tmpfs on `/var/lib/kubelet` (lesson 5)
8. `/etc/rancher/k3s/registries.yaml` from the disk, if present
9. `k3s agent --server https://$svos.server:6443 --token-file /media/token
   --node-ip <svos.lan> --flannel-iface eth1` in the background, logging
   to `/var/log/k3s-agent.log` (lesson 8). Flannel's VXLAN must use
   `eth1` too, or pod traffic between nodes would head for slirp.

With `svos.role=server` steps 1–6 are the same (the disk is mounted
read-write), then:

- `svos.data=disk`: mount ext4 `/dev/vdb` on `/var/lib/rancher`;
  `svos.data=tmpfs` (default): nothing to do — the root is already a
  tmpfs (lesson 14)
- `k3s server --disable-agent --token-file /media/token
  --advertise-address <svos.lan> --tls-san <svos.lan>` with the add-ons
  disabled, logging to `/var/log/k3s-server.log`
- in the background, wait for `/etc/rancher/k3s/k3s.yaml`, copy it to
  `/media/k3s.yaml` and `sync`, so the host can read it off the disk

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
| k3s server on Weaver | **Met** (2026-10-01) — `earth-616`, tmpfs or ext4 datastore |
| README: 3-node QEMU cluster, all Weaver | Partly — all Weaver, VMs on a shared LAN; 1 agent node so far |
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
18. **A VM cluster needs two networks.** With the server on the host,
    slirp was enough: every VM reached it at 10.0.2.2. With the server in
    a VM it isn't — each VM gets its *own* private slirp (every guest is
    10.0.2.15), so VMs can't see each other. A QEMU socket netdev in
    multicast mode (`-netdev socket,mcast=230.0.76.1:7676,localaddr=127.0.0.1`)
    is a shared Ethernet segment for any number of VMs on one machine —
    but it has no host on it (lesson 2). So each VM gets both: `eth0` on
    slirp for the host (registry, DNS) and `eth1` on the segment for the
    cluster. Two details: every VM on the segment needs its own MAC
    (QEMU's default is the same for all of them), and k3s must be told
    which side is the cluster — `--node-ip` and `--flannel-iface eth1` on
    agents, `--advertise-address` on the server, or each node offers its
    slirp address, 10.0.2.15, the same for all of them.
19. **Killing QEMU is pulling the power cord.** With the datastore on
    ext4, a server killed a minute after `weaver-a` joined came back
    without the node or its pod — but with the volume, `state.db` and its
    certificates intact. Nothing deleted the node: the writes never left
    the guest's page cache. k3s's sqlite runs in WAL mode, which doesn't
    `fsync` each commit, and Linux writes dirty pages back on its own
    clock (up to ~30 s). The same steps with `sync` typed on the server
    console before the kill kept both. A persistent server has to shut
    down cleanly: `reboot -f` (busybox syncs first; `-n` would skip it),
    which `-no-reboot` turns into QEMU exiting. Not `poweroff -f`: it
    syncs too, but our kernel has no ACPI, so it can only halt the CPU —
    "System halted" — and QEMU keeps running. svos-init has no clean
    shutdown of its own yet.

## Next steps

Toward the README's Stage 5 bar:

1. ~~**Server on Weaver**~~ — done (2026-10-01).
2. **Three nodes** — two more agents. The shared LAN, per-node
   addresses and MACs are in place (`weaver-b` .12, `weaver-c` .13);
   what's left is booting them together and checking pod traffic
   between nodes (flannel VXLAN over `eth1`).
3. **`svos-enroll`** — per-node join credentials instead of the fixed
   lab token on the disk.

Features:

- **server + node** (`TODO(feature)` in `/etc/svos/boot`): a server
  without `--disable-agent` also runs kubelet and counts as a node. The
  server is control plane only for now (Anthony's call, 2026-10-01).

Polish:

- clean shutdown in svos-init: on SIGTERM/SIGUSR2 (busybox `reboot` /
  `poweroff` without `-f`), stop children, `sync`, then `reboot(2)` —
  so a persistent server can't lose writes (lesson 19)

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
- k3s (server and agent) isn't supervised: if it dies, nothing restarts it.
- A disk-backed server must be shut down from its console
  (`reboot -f`); killing QEMU can lose the last ~30 s of cluster
  writes (lesson 19).
- `apk add` still carries `--allow-untrusted` (pubkey embedding pending).
