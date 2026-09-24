# Stage 1 — the Weaver kernel

> **Provenance note:** stage notes drafted with AI assistance
> (GLM (glm-5.3-flash) by Z.ai) from Anthony's hands-on build session.
> Every failure below was hit for real on 2026-09-24.

## What ships

- Linux **6.1.188** built with our own `x86_64-svos-linux-musl-` toolchain,
  from `allnoconfig` + `kernel/config.svos` fragment; settled config committed
  as `kernel/config-6.1.188-svos`.
- BusyBox **1.38.0**, static, built by our cross-toolchain (first real
  consumer of Stage 0's output).
- Hand-written `/init` (PID 1 skeleton — Stage 2 replaces it with `svos-init`).
- The initramfs is **baked into bzImage** at kernel build time
  (`CONFIG_INITRAMFS_SOURCE=.../kernel/out/rootfs`).

## Exit criterion — met

QEMU direct kernel boot (`-kernel bzImage -append console=ttyS0 rdinit=/init`),
serial console shows the hand-made ASCII banner, the busybox shell executes a
command driven over serial (`SVOS-MARKER-42`), clean `poweroff -f`. CI runs
the whole thing (`stage1-kernel` job).

## What we learned (the receipts)

1. **`tinyconfig` is a trap for real systems.** It's not "small Linux", it's
   "no Linux": `BINFMT_ELF` off (can't exec anything), `FUTEX` off (no
   musl threads), `TTY` off (no console at all), `EPOLL`/`TIMERFD` off.
   Worse, options whose *dependencies* vanish (TTY, `VIRTIO_MENU`) are
   silently dropped by `olddefconfig` — you must re-enable the gate, not just
   the leaf. Fix: `allnoconfig` + `KCONFIG_ALLCONFIG=config.svos` fragment
   listing the syscall layer musl/busybox require, then virtio/net/console.
2. **`CONFIG_BINFMT_SCRIPT` is a separate knob from `BINFMT_ELF`** — without
   it the kernel can't `execve` a `#!/bin/sh` script, and `/init` fails with
   `error -8` (ENOEXEC). Musl static busybox + `BINFMT_SCRIPT` = the minimal
   bootable pair.
3. **PID 1 has no guaranteed stdio.** Even with `console=ttyS0`,
   "unable to open an initial console" happens because devtmpfs isn't mounted
   when PID 1 spawns. `/init` must open `/dev/console` itself, *after*
   mounting devtmpfs (`exec </dev/console >/dev/console 2>&1`), or your
   banner and shell go nowhere.
4. **`make all` vs `make install`** (Stage 0 hangover): a partially built
   target + the wrong resume target = "Nothing to be done" lies. Always
   resume with the real target.
5. **Script shebang portability:** build.sh runs under `/bin/sh` (dash on
   Ubuntu) — no bash process substitution `<( )`; use a temp fragment file.

## Layout

```
kernel/build.sh            # fetch-verify-build-smoke, idempotent
kernel/config.svos         # our fragment (human-readable intent)
kernel/config-6.1.188-svos # the settled .config (committed per AGENTS.md)
kernel/rootfs/init         # PID 1 skeleton (hand-written, hand-made banner)
kernel/rootfs/populate     # busybox applet symlink helper
```

## Next (Stage 2)

`svos-init` in C replaces this shell script, squashfs, and an ISO/qcow2
that boots on real firmware. The busybox rootfs here is the skeleton it
inherits.