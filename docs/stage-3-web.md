# Stage 3 — The Web (Nebula)

> **Provenance note:** stage notes drafted with AI assistance
> (GLM (glm-5.3-flash) by Z.ai) from the hands-on session, 2026-09-24.

## What ships

- **Nebula 1.11.2** (upstream static Go binaries — run on our musl kernel
  unchanged) in `web/bin/`, also packed into lab VM disks.
- **`web/mkcerts.sh`** — generates the lab CA + per-node certs
  (lighthouse 10.99.99.1, host-a .2, host-b .3). Output gitignored —
  the CA key IS the mesh.
- **`web/lab/*.yml`** — lighthouse + node configs (per-node certs,
  static_host_map, explicit allow-any firewall — nebula denies inbound
  by default).
- **`web/runlab.sh`** — boots lab VMs on QEMU socket-netdev underlay.
- **Lighthouse runs inside a Weaver VM** (not the host — see lesson 1).

## Exit criterion — met

3 Weaver VMs on a UDP-socket underlay, all running Nebula:

- host-a (10.99.99.2) → lighthouse (10.99.99.1): ping 3/3, ~2.6 ms
- host-b (10.99.99.3) → lighthouse: ping 3/3
- host-a → host-b (learned via lighthouse, routed through it): ping 4/4

Handshake logs show cert verification against our own CA (`certName=host-a
fingerprint=1ce69c...`) on every peer contact.

## What we learned (the receipts)

1. **QEMU socket netdev is a 1:1 pipe, not a network.** `-netdev socket,
   udp=X,localaddr=Y` sends *every* frame the guest emits to X and
   accepts frames only from Y. A VM with one netdev has exactly one
   peer. The 3-node lab therefore gives the lighthouse VM **two**
   netdevs (one per spoke) and puts each node on a different underlay
   subnet (A: 192.168.100.0/24, B: 192.168.200.0/24) — otherwise the
   kernel's route for both subnets matches the wrong interface and
   lighthouse replies get misdelivered.
2. **Host lighthouse + guest node doesn't work with socket netdev:**
   guest frames land on the host *as encapsulated frames* for the
   QEMU peer, so a host-side process can't be a nebula peer. Everything
   (lighthouse included) must be in a VM. (A user-mode netdev with port
   forwarding could host-side, deferred.)
3. **Nebula default firewall denies inbound** — with default configs the
   handshake completes but ICMP dies. The lab sets explicit
   `firewall: inbound/outbound: allow any` (production would use real
   rules; that's the point of the Stage 4+ work).
4. **`lighthouse.hosts` is required** on regular nodes (or they only
   initiate to static_host_map entries and never learn other peers).
5. **Cross-subnet node-to-node needs routing help:** lighthouse must
   `ip_forward=1`; A and B each need a route to the other's underlay
   via the lighthouse (`ip route add 192.168.200.0/24 via 192.168.100.1`).
   Real meshes punch direct paths (punchy); in the socket-netdev lab
   every path physically flows through the lighthouse VM.
6. **Kconfig gates, third strike:** `CONFIG_TUN=y` was silently dropped
   until `CONFIG_NET_CORE=y` (its menu gate) was also set. The gate
   lesson now has a permanent home in the fragment comments.
7. **Kernel additions for the web:** `TUN` (nebula device), `VIRTIO_NET`
   (underlay NICs), `FAT_FS/VFAT` + NLS (nebula+certs payload disk).
8. **busybox vfat caching:** remounting a vfat after changing its
   content under QEMU doesn't refresh file contents — a VM reboot is
   the honest way to see repacked data.

## Layout

```
web/bin/nebula, nebula-cert   # upstream static binaries (v1.11.2)
web/mkcerts.sh                # CA + host certs (hand-run, output ignored)
web/lab/{lighthouse,host-a,host-b}.yml
web/runlab.sh                 # boots lab VMs (kernel+netdev wiring)
kernel/out/nebula-*.img       # vfat disks: nebula + certs + config
```

## Next (Stage 4 — apk-tools)

`svos-enroll` (node asks the mesh for admission, gets certs) and
apk-tools from source + our own APKINDEX — the OS starts becoming
extendable.