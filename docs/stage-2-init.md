# Stage 2 — PID 1 / svos-init

> **Provenance note:** stage notes drafted with AI assistance
> (GLM (glm-5.3-flash) by Z.ai) from Anthony's hands-on session, 2026-09-24.

## What ships

- **Stage 2a** — busybox `init` boot flow, hand-written:
  `/etc/inittab` (sysinit/respawn/ctrlaltdel/shutdown actions) driving
  `/etc/init.d/rcS` (mounts, hostname, banner) and `rcK` (unmounts).
  `/init` is a shim that execs `busybox init`.
- **Stage 2b/2c** — **`svos-init`** (`init/svos-init.c`, ~160 lines of C,
  static musl): our own PID 1. Mounts proc/sysfs/devtmpfs, re-opens
  `/dev/console` onto stdio, spawns a job-control shell in its own session
  (`setsid` + `TIOCSCTTY`), respawns it forever, reaps orphans
  (`SIGCHLD` + `waitpid(WNOHANG)` loop), reboots on SIGINT (ctrl-alt-del),
  ignores SIGHUP (serial carrier drops). Never exits — the kernel panics
  if PID 1 does.
- **Stage 2d** — bootable disk artifact: `scripts/mkimage.sh` packs the
  rootfs into an xz squashfs (`weaver-root.squashfs`) wrapped in a qcow2
  (`kernel/out/weaver.qcow2`), mounted read-only by the guest as
  `/dev/vda`.
- **Stage 2d (ISO)** — `weaver.iso`: El Torito CD, BIOS-bootable
  (SeaBIOS → ISOLINUX 6.04 → kernel → svos-init), isohybrid MBR so the
  same file also boots from USB. Verified booting with plain
  `-cdrom weaver.iso` — no `-kernel` help.

## Exit criterion — met

`./kernel/build.sh` end-to-end from clean tree: kernel boots, svos-init
banner on ttyS0, shell executes commands, shell respawns after `exit`,
disk artifact builds **and mounts inside the guest** (CI mirrors all of
this in the `stage1-kernel` job).

## What we learned (the receipts)

1. **Busybox init is just inittab** — `::sysinit:` runs once and init
   *waits* for it; `ttyS0::respawn:/bin/sh` gives you a maintained console;
   `::shutdown:` runs before halt. Hand-writing this first (per the
   roadmap) makes the C version obvious: busybox init is a table-driven
   fork/respawn/reap loop — exactly what svos-init implements by hand.
2. **The mkdir-before-mount trap (again, subtler):** Stage 1's shim did
   `mkdir -p /proc /sys /dev` but the Stage 2a rewrite dropped it —
   mounts failed *silently* (mount returns error, script had no `set -e`
   there) and busybox init had no console: boot = zero output, no panic.
   Debug lesson: when a box prints *nothing at all*, suspect its stdio,
   not its code.
3. **PID 1 signal rules** (signal(7)): PID 1 is immune to signals it
   hasn't installed a handler for — but SIGINT/SIGCHLD/SIGHUP *do* matter:
   - SIGCHLD must be caught and reaped or orphans become immortal zombies
   - SIGINT is the ctrl-alt-del path (kernel routes it to PID 1)
   - SIGHUP must be ignored or a serial hangup kills your init
   - `volatile sig_atomic_t` for the handler flag; never work in a handler
4. **Kconfig gates, again:** `SQUASHFS` lives under `MISC_FILESYSTEMS`
   — with `allnoconfig` that menu is off, so `CONFIG_SQUASHFS=y` in the
   fragment is *silently dropped* (same shape as the `VIRTIO_MENU` lesson
   in Stage 1). Rule of thumb: enable the menu, then the entry.
5. **virtio device nodes:** devtmpfs creates `/dev/vda` (254:0) only when
   the virtio driver probes; if you boot before probing completes, `mount`
   says "No such file or directory" for a disk that dmesg *already
   announced*. In a real init you'd `mdev -s` or wait for uevents — here
   the shell just retries.
6. **losetup noise:** busybox `losetup` prints `Can't open blockdev`
   warnings that look fatal but aren't; squashfs mounts fine without it
   (it's only needed for file-backed loop devices, not whole-disk mounts).
7. **ISO boot chain needs its whole family:** isolinux.bin alone is not
   enough — syslinux 6.04 also requires `ldlinux.c32` next to it in the
   ISO tree, or you get the terse `Failed to load ldlinux.c32`. And the
   bootloader must be *copied into the tree xorriso packs* — the
   `-b isolinux/isolinux.bin` option points at the file inside the image,
   it does not fetch it from the host.

## Layout

```
init/svos-init.c        # our PID 1 (C, static musl, cross-compiled)
init/Makefile           # make check = build + static-link sanity
kernel/rootfs/etc/inittab      # busybox-init fallback config
kernel/rootfs/etc/init.d/rcS   # boot script (mounts + banner)
kernel/rootfs/etc/init.d/rcK   # shutdown script (unmounts)
kernel/rootfs/init             # shim: exec /sbin/svos-init
scripts/mkimage.sh      # squashfs + qcow2 artifact builder
kernel/out/weaver.qcow2 # the artifact (gitignored, CI rebuilds it)
```

## Honest caveats

- UEFI boot is still open: the ISO is BIOS-only (isolinux). GRUB
  EFI/xorriso `-eltorito-alt-boot` work is deferred until it's needed.
- No partition table on the qcow2 yet (raw squashfs wrap); GPT arrives
  with real installer work.
- `poweroff -f` from the shell doesn't run `rcK` yet (svos-init doesn't
  dispatch shutdown scripts — queued for Stage 2 polish or Stage 3).

## Next (Stage 3 — The Web)

Nebula manual quickstart: 1 lighthouse + 2 hosts, hand-made certs,
*before* baking anything into the OS image. `svos-enroll` comes after
the manual flow is understood.