# PR264 download audit follow-up

Continue `fix/download-manager-v2-fixes` at `770416556d64e887c5dd4461e3142da310988126`.
Validate the supplied deep audit against current code and locked background_downloader 9.6.2 before changing behavior. Preserve exact writer identity, durable bytes, user pause intent and logical episode admission limits. Prefer existing platform APIs and small changes; add no dependencies.

1. Reproduce baseline failures and distinguish remaining defects from already fixed or inaccurate claims.
2. Fix manager failure persistence, retry restoration, callback fencing, bounded source refresh, safe deletion and admission serialization. Add behavioral regressions.
3. Fix range allocation and atomic promotion, assembly headroom, native replay ordering, atomic manga checkpoints and storage selection/containment. Preserve resumable parts on errors.
4. Fix failed-row retry routing and duplicate launch handling. Protect existing metadata on rollback.
5. Harden iOS expiration, foreground checks and credential-bearing queue persistence. Use native encryption/Keychain and verify compiled helpers on macOS.
6. Independently review the combined diff, resolve important findings, publish to the existing PR with a head lease, run analysis, focused/full tests and iOS CI, and revise the PR description to match evidence. Do not merge.

Baseline CI run 37497720984: analysis and iOS/native logger checks succeeded; focused V2 suite had 147 passes and seven failures. Local workspace has no Flutter or Swift SDK, so local static checks are not runtime validation. Final CI must supply execution evidence.

## Recovery follow-up at head 33b463b

1. Fix the observed Linux/Windows RED regressions for exclusive final-file reservation and interrupted promotion recovery. Preserve existing destinations and resumable ranges.
2. Count startup paused-but-live writers against admission without changing durable user intent; wake queued work when the writer actually pauses.
3. Apply admission and destination ownership to orphan manga chapter recovery while retaining the existing generation and pages.
4. Independently review the changes, run the existing Linux/Windows/Android/iOS/native CI gates, and replace the stale PR validation summary with evidence from the new head.
