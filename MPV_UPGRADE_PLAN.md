# mpv 0.41 Upgrade Plan

> **Source of truth for branch status.** A checked item means the implementation decision is complete and automated verification is present. A platform is never checked merely because headers or version strings changed.

**Branch:** `feat/mpv-0.41-upgrade`  
**PR:** #245  
**Design:** `docs/superpowers/specs/2026-09-14-mpv-0.41-upgrade-design.md`  
**Detailed implementation plan:** `docs/superpowers/plans/2026-09-14-mpv-0.41-upgrade.md`

## Shipping constraints

- Target actual native runtime: mpv `v0.41.0` on every supported native platform.
- Target renderer: explicit `gpu-next`; keep explicit `gpu` only as fallback/A-B comparison while migration is validated.
- Keep `media_kit 1.2.6`, `media_kit_video 2.0.1`, and `media_kit_libs_video 1.0.7` unless a verified blocker requires a focused dependency change.
- Keep Anime4K behavior/presets and Apple Metal routing unchanged.
- Header/runtime ABI alignment is mandatory; headers-only updates do not count as a runtime upgrade.
- Runtime provenance and deterministic verification are required per platform.

---

- [x] **MPV-00 — Architecture and migration scope**
  - Approved design isolates inventory, header/runtime alignment, platform upgrades, renderer rollout, and acceptance verification.
  - `gpu-next` is the target renderer; `gpu` remains an explicit fallback.
  - Rollback remains platform-by-platform and renderer rollback is independent from runtime rollback.

- [ ] **MPV-01 — Runtime inventory/version contract**
  - Add machine-readable target/header/media_kit/platform provenance manifest.
  - Add deterministic verifier and CI tests.
  - Contract declares `renderer.primary = gpu-next` and `renderer.fallback = gpu`.
  - Current audited baselines: Darwin `v0.7.2 -> mpv v0.36.0`; Android `v1.1.7 -> mpv 78d43740...`; Windows `20241021 -> mpv 0f785845...`.

- [ ] **MPV-02 — Exact mpv v0.41.0 target headers**
  - Vendor the exact four upstream libmpv headers with immutable Git blob verification.
  - Do not activate them while Apple still links the v0.36 runtime.

- [ ] **MPV-03 — Runtime replacement boundary per platform**
  - Record whether each platform can use an upstream package or needs an isolated runtime overlay.
  - Do not fork the media_kit Dart API unless no smaller native boundary is safe.

- [ ] **MPV-04 — Apple runtime/header alignment**
  - iOS/macOS link mpv v0.41.0 and compile against matching v0.41.0 headers.
  - Header preparation no longer treats media_kit's old Darwin Makefile version as the source of truth.
  - Anime4K/media_kit and pacing patches remain fail-closed and pass their regression tests.

- [ ] **MPV-05 — Android runtime v0.41.0**
  - Replace the current pre-0.37-era runtime boundary.
  - Build and verify packaged runtime before marking complete.

- [ ] **MPV-06 — Windows runtime v0.41.0**
  - Replace the current 2024 development snapshot with stable v0.41.0.
  - Build and verify packaged runtime before marking complete.

- [ ] **MPV-07 — Explicit `gpu-next` renderer rollout**
  - Playback configuration explicitly selects `gpu-next` under mpv 0.41.
  - `gpu` remains available as an explicit fallback/A-B path, not the normal default.
  - Anime4K native/fallback routing and A+A/A+S presets remain unchanged.
  - Focused tests verify the renderer policy instead of relying on mpv defaults.

- [ ] **MPV-08 — Full build/playback acceptance**
  - Contract verifier, Flutter analyze/tests, native patch tests and platform build matrix are green.
  - Playback acceptance covers local/HLS, seek, pause/resume, subtitles, audio tracks, hwdec/software fallback, Anime4K off/A+A/A+S, repeated player open/close.
  - Acceptance compares `gpu-next` normal playback with explicit `gpu` fallback on the same mpv 0.41 runtime.
  - Exact PR head must be green before the draft is marked ready.

## Execution order

`MPV-01 -> MPV-02 -> MPV-03 -> MPV-04/05/06 (independent where possible) -> MPV-07 -> MPV-08`
