# Learning roadmap — read/watch alongside each stage

> **Provenance note:** this roadmap was drafted with AI assistance
> (GLM (glm-5.3-flash) by Z.ai) from Anthony's "hands-on first" requirement.
> Curated and approved by Anthony.
>
> Rule: **DO first, then read.** Each stage lists what to build with your own
> hands before the reading material will make sense. When stuck, read the
> source — musl, busybox, apk-tools, nebula are all small enough to read.

## The spine (read in parallel with everything)

- **Linux From Scratch** (free book) — the canonical from-scratch build.
  Read ch. 1–2 now; ch. 5–6 during Stage 0.
  https://www.linuxfromscratch.org/lfs/
- **How Linux Works** (Brian Ward, 3rd ed.) — boot → kernel → init →
  userspace mental model in one book.
- ▶️ **"Linux From Scratch Speedrun" — Adam Nielsen (YouTube)** — the whole
  journey in ~40 min. Watch before Stage 0.

## Per stage

### Stage 0 — Toolchain
**DO:** build musl-cross-make yourself: https://github.com/richfelker/musl-cross-make
- LFS "Toolchain Technical Notes" — *why* gcc has to be built multiple times
- musl documentation: https://musl.libc.org/

### Stage 1 — Kernel
**DO:** build a stock kernel once for muscle memory, then start from
`tinyconfig`: https://kernelnewbies.org/KernelBuild
- https://docs.kernel.org/admin-guide/
- https://docs.kernel.org/filesystems/ramfs-rootfs-initramfs.html
- "Linux Inside" gitbook (0xax) — kernel boot internals

### Stage 2 — PID 1 / svos-init
**DO:** write busybox init scripts by hand first, then `svos-init` in C
- Tiny Core architecture (short, gold):
  http://www.tinycorelinux.net/architecture.html
- Talos Linux architecture docs (the production version of this idea)
- C: https://beej.us/guide/bgc/

### Stage 3 — The Web (Nebula)
**DO:** manual quickstart with 1 lighthouse + 2 hosts and hand-made certs,
*before* baking it in: https://nebula.defined.net/docs/
- Our own docs: heim-docs `spider-verse-os/web-of-reality.mdx`

### Stage 4 — apk-tools
**DO:** build apk-tools from source, generate your own APKINDEX
- https://gitlab.alpinelinux.org/alpine/apk-tools
- Alpine wiki (image building + apk format)

### Stage 5 — k3s
**DO:** **Kubernetes The Hard Way** once, manually — it is exactly what k3s
automates: https://github.com/kelseyhightower/kubernetes-the-hard-way
- https://docs.k3s.io/ (architecture; kernel requirement checklist)

### Stage 6 — Spiders
**DO:** K8s Jobs/CronJobs playground, then Spider-Monitor v0
- Our own docs: heim-docs `spider-verse-os/spider-agents.mdx`

## QEMU is the lab

Learn early:
- Direct kernel boot (no firmware): `-kernel … -initrd … -append …`
- `-nographic` for serial console
- `-netdev` / `-object filter-dump` for networking; multicast netdev is how
  multi-VM mesh tests work

## The habit

When stuck, read the source. In order of usefulness: busybox, musl, nebula,
apk-tools, Linux `init/main.c`.