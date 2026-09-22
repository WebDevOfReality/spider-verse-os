# Vlog plan — Spider-Verse OS, built in public

> **Status: MOVED.** This plan now lives at
> `heim-docs/src/content/webdev-of-reality/svos-vlog-plan.mdx`
> (on the heim server, part of heim-docs) — vlog planning is personal
> content, so it lives with the other content docs, not in the OS repo.
> This stub stays so the commit history links the two.

## Format decisions (locked)

- **Polished episodes:** long-form YouTube, 10–20 min, narrated walkthrough —
  screen recording + voiceover. One per stage, released when the stage's exit
  criterion is hit (not on a calendar).
- **Weekly build diary:** short raw update (5–10 min), no heavy editing,
  released weekly regardless of progress. **Failures are content** — a build
  log that explodes is an episode segment, not a shame-delete.
- **Episode 0 (pilot):** on camera (Anthony, face/voice), before any Stage 0
  content. Sets up why + rules + map.
- **Every polished episode ships with a matching blog post** on
  webdevofreality (same stage notes, prose form). Post #1 (Welcome) is
  separate and already in progress; Stage 6's post is the planned "post #2."
- **Ethics on camera (binding, from AGENTS.md):** no AI-generated thumbnails,
  logos, end cards, or any visual asset — ever. Hand-made or commissioned
  human art only. `TODO(art:)` and wait. AI-drafted scripts/blog prose get
  labeled in the blog metadata (`aiAssisted` + model) and are fine for the
  video as long as Anthony owns the ideas and reads/reviews everything.

## Episode list

| # | Episode (working title) | Source stage | Key beats | Status |
|---|---|---|---|---|
| 0 | "I'm Building an Operating System From Scratch (and You Can Watch It Break)" | — | Hook: not a fork, not an install — *my kernel, my PID 1*. Why 2026 is the year. heim backstory → why from scratch. The rules: timeboxes, 2-miss pivot, AI-ethics receipts. The map: 7 stages, the Earths. Ask: subscribe to watch the panics. | next up |
| 1 | "What a Cross-Compiler Actually Is" | Stage 0 | Cold open: `weaver` printed by a binary gcc built. The 3 narration questions: why gcc gets built more than once; why `-static` matters for an initramfs OS; what musl does for `puts()`. Failure reel: first build attempt's real errors. | waiting on Stage 0 |
| 2 | "My Kernel, My Panics" | Stage 1 | Cold open: boot log scrolling — *"this kernel is mine"*. tinyconfig as starting point; what virtio/net/cgroups/EFI each buy us; kernel config in git as an artifact. First kernel panic on camera. | |
| 3 | "PID 1 Is 150 Lines of C" | Stage 2 | Cold open: svos banner from our own ISO. What PID 1 must do (reap, respawn, never die). squashfs → RAM. ISO + qcow2 artifacts. | |
| 4 | "The Mesh Ships Inside the OS" | Stage 3 | Cold open: two VMs talking on 10.0.0.x, zero manual net config. Manual nebula quickstart first (lighthouse + certs), then baked-in + `svos-enroll` v0. | |
| 5 | "My Distro Has a Package Manager" | Stage 4 | apk-tools built from source; our own APKINDEX; `apk add kodi-ext` on a live Earth. What a package actually is. | |
| 6 | "From-Source Linux Runs Kubernetes" | Stage 5 | k3s on Weaver; enroll auto-join; 3-node QEMU cluster. K8s The Hard Way flashback for contrast. | |
| 7 | "svos-0.1.0: The Whole Spider-Verse, One Dress Rehearsal" | Stage 6 | 4 editions boot; Spider-Monitor v0 CronJob; tag + release; the heim migration decision. → Blog post #2. | |

Diaries are unnumbered by stage — label them `Build Diary #N (week of …)`.

## Per-episode template (polished)

1. **Cold open (30–60 s):** the exit criterion already working. Payoff first.
2. **"What and why" (2–3 min):** the one concept this stage teaches. One
   concept per episode — resist cramming.
3. **Build footage (8–12 min):** real terminal, real time (or honest
   time-lapse), narration over it. Show the config file, the actual error.
4. **Failure reel (2–3 min):** the diaries feed this — best/worst moments of
   the week(s). Panics are punchlines *and* lessons.
5. **Payoff, again (1–2 min):** exit criterion live, explain what changed.
6. **Next-episode tease (30 s):** the next stage's exit criterion as a cliffhanger.

## Weekly build diary template

- "This week:" 1–3 bullet updates (done / broken / learned)
- 1 terminal moment worth showing (even — especially — a failure)
- "Next week I'm going to try:" (commitment = accountability)
- Hard cap ~10 min. No color grading. Raw is the format.

## Production notes

- **[OPEN]** Screen recorder: OBS (X11/WSL capture needs a decision)
- **[OPEN]** Mic setup for voiceover
- **[OPEN]** Intro/outro branding + thumbnail template — **hand-made**;
  `TODO(art:)` until then, first episodes ship text-only thumbnails
- Channel/page: YouTube under WebDev of Reality; link matching blog post in
  description; description carries the AI-ethics one-liner as standing text

## Blog pairing

- Each polished episode → matching post, drafted from the stage notes in
  `docs/` (stage notes = first draft).
- Labeling per blog rules: prose Anthony wrote from an outline = human;
  AI-drafted prose = `aiAssisted: true` + model + `ai-assisted` scope.
- Post slugs mirror episode numbers: `ep1-what-a-cross-compiler-actually-is`…

## Cadence summary

| Week | Ships |
|---|---|
| every week | Build Diary (raw, ≤10 min) |
| on exit criterion | Polished episode + matching blog post |
| Stage 6 | post #2, tag `svos-0.1.0`, release artifacts |