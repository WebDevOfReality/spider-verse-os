# AI Usage & Provenance

This project is built in public with AI as the assumed default for code —
every non-trivial commit carries a `Co-authored-by: GLM (glm-5.3-flash) by
Z.ai <noreply@z.ai>` trailer, and the receipts are documented per stage.

## What AI did / didn't do

| Work | AI | Human |
|---|---|---|
| Kernel build, config fragment, debugging | drafted + iterated | ran, decided, learned |
| svos-init (C PID 1) | drafted | reviewed line-by-line (on request) |
| Nebula lab configs + topology | drafted | decided topology, hit the failures |
| apk repo format | reverse-engineered w/ AI | verified against real Alpine pkgs |
| Hand-made boot banner (ASCII art) | **never** | **always** (AGENTS.md §2) |
| Architecture + roadmap decisions | never | always (Anthony's) |

## Per-stage receipts

| Stage | Notes | Key learnings |
|---|---|---|
| 0 | toolchain built | musl-cross-make, hello-world smoke |
| 1 | docs/stage-1-kernel.md | tinyconfig traps, BINFMT_SCRIPT, PID 1 stdio, KCONFIG_ALLCONFIG |
| 2 | docs/stage-2-init.md | silent mount failures = no console; menu gates (MISC_FILESYSTEMS); isolinux + ldlinux.c32 |
| 3 | docs/stage-3-web.md | socket netdev = 1:1 pipe; nebula denies inbound; TUN needs NET_CORE gate (strike 3) |
| 4 | docs/stage-4-apk.md | apk v2 = 3 gzip members; pkg-config shim; datahash covers payload |
| 5 | (in progress; notes in dossier/worklog.md) | k3s kernel reqs; slirp for VM→host; serial console under load is unreliable |

## Working diary

`dossier/worklog.md` (untracked, Anthony's) — the session-by-session
working diary: what broke, what we learned, where we stopped. Stage notes
in `docs/` are the polished "what ships" records; the worklog is the raw
process.