# Spider-Verse OS

**A from-scratch Linux distribution for the Spider-Verse.**

Kernel + initramfs core (codename **Weaver**) with the mesh network — the
"Web of Reality" (Nebula) — built directly into the OS image. Every part is
compiled from source with our own cross-toolchain. Built in public, one vlog
episode at a time.

```
       ┌──────────────────────────────────────────┐
       │              SPIDER-VERSE OS             │
       │  ┌────────────────────────────────────┐  │
       │  │  extensions (apk): kodi, juicefs…  │  │
       │  ├────────────────────────────────────┤  │
       │  │  k3s · Spider agents (K8s Jobs)    │  │
       │  ├────────────────────────────────────┤  │
       │  │  THE WEB: nebula (in the image)    │  │
       │  ├────────────────────────────────────┤  │
       │  │  svos-init (PID 1) + busybox/musl  │  │
       │  ├────────────────────────────────────┤  │
       │  │  our own Linux kernel (tinyconfig) │  │
       │  └────────────────────────────────────┘  │
       │   built by our own cross-toolchain       │
       └──────────────────────────────────────────┘
```

## Why from scratch

Because "I run k3s on Ubuntu" teaches you Ubuntu, and this project is about
understanding **every layer**: what a cross-compiler is, what PID 1 actually
does, what a kernel needs for a mesh VPN, and what a package manager is. The
distro is the excuse; the understanding is the product. (And the vlog posts
write themselves.)

## The plan — Phase 1: "Weaver"

Architecture: **initramfs-first**. The OS is a tiny
kernel + musl/busybox initramfs that boots to RAM; the mesh (nebula) is baked
in; `apk` (built from source) installs extensions at runtime onto a writable
overlay. There is no package-managed root. (The same shape other minimal
distros use, but ours is built entirely from source.)

| Stage | What we build from source | Exit criterion | Vlog episode |
|---|---|---|---|
| 0 | Cross-toolchain via `musl-cross-make` → `x86_64-svos-linux-musl-gcc` | hello-world runs in QEMU | "What a cross-compiler actually is" |
| 1 | Linux kernel, `tinyconfig` + virtio/net/cgroups/EFI; config in git | kernel boots busybox initramfs | "My kernel, my panics" |
| 2 | `svos-init` (C, ~150 lines) + squashfs → ISO/qcow2 | boots to svos banner from our ISO | "PID 1 is 150 lines of C" |
| 3 | musl nebula in initramfs + `svos-enroll` v0 (manual cert sign) | 2 VMs mesh on 10.0.0.x, zero manual net config | "The mesh ships inside the OS" |
| 4 | apk-tools from source + our own extension repo | `apk add kodi-ext` on a live Earth | "My distro has a package manager" |
| 5 | k3s static binary + kernel support; enroll auto-join | 3-node QEMU cluster, all Weaver | "From-source Linux runs Kubernetes" |
| 6 | Spider-Monitor v0 (CronJob) + full-verse dress rehearsal | tag `svos-0.1.0` + release artifacts | Blog post #2 |

**Timeboxes:** ~1 week of evenings per stage. **Two misses on a stage =
pivot** to Plan B (below). Stages 0–2 remain vlog content either way.

## Plan B (documented fallback)

If the from-scratch road stalls, Spider-Verse OS ships as an **Alpine
extension** instead: our own ISO + APK repo + `svos-enroll`, built with a
simple pinned-package build script (pure Alpine runtime, no exotic tooling).
The architecture (editions: server/media/nas/edge, enrollment)
carries over unchanged. Weaver stages 0–2 still ship as learning content.

## Editions (from Stage 5 onward)

| Edition | Target Earth | Contents |
|---|---|---|
| `server` | Earth-616 | nebula, k3s, enroll |
| `media` | Earth-221 | nebula, Kodi extension, enroll |
| `nas` | Earth-321 | nebula, JuiceFS/drbd deps, enroll |
| `edge` | Earth-199 | minimal, nebula, Termux side-load notes |

## Repository layout

```
toolchain/    Stage 0 — musl-cross-make based cross-toolchain build
kernel/       Stage 1 — kernel config + build scripts
init/         Stage 2 — svos-init (PID 1), inittab, boot scripts
web/          Stage 3 — nebula integration + svos-enroll
apk/          Stage 4 — apk-tools + extension repo
server/       Stage 5 — k3s integration
spiders/      Stage 6 — Spider-Monitor v0
docs/         learning roadmap, stage notes (vlog/blog material)
scripts/      build + CI helpers
```

## Ethics (binding — see AGENTS.md)

Every AI-assisted change is signed in its commit (`ai-assisted: <model>`).
No AI-generated art, ever — the boot banner is hand-made ASCII. This repo is
built in public, so the receipts are public too.

## Status

**Stage 0 in progress.** See `docs/learning-roadmap.md` for the reading list
that accompanies each stage.

## License

MIT — see `LICENSE`.