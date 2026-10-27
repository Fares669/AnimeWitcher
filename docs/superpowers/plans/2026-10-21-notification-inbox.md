# Notification Inbox Implementation Plan

> **For agentic workers:** Implement inline with test-first checks.

**Goal:** Add the APK-compatible inbox and badge above the sidebar account and at the physical upper-right of Account.
**Architecture:** Reuse the authenticated account service, Firestore REST paging/patches, Riverpod and existing theme/header/replies screen. No new dependency or push/repair behavior.
**Spec:** Approved user scope and static APK contract (users/{profile.documentId}/notifications, date descending, page size 20).

## Constraints and review focus
- Reads use profile document ID, never Auth UID; validate owned notification paths and supported target paths.
- Seen counter and clicked state are independent; reset seen only after initial results display.
- Guard account changes during every request and UI action; no stale-account result or follow-up write.
- Deleted targets, malformed/unknown types, missing actor maps, network and write failures remain usable and retryable.
- Preserve PR277 menu-button edits by touching only sidebar header; no live requests or publication.

## Tasks
- [ ] Add failing model/service tests for typed data, paging/cursor20, narrow writes, ownership, route validation and session changes; run red.
- [ ] Add minimal notification model and authenticated service methods; run tests green.
- [ ] Add failing widget tests for shared badge, loading/empty/error, pagination/refresh and actions.
- [ ] Add themed inbox with guarded async loads/actions and two entry points; run tests green.
- [ ] Run formatter, analyzer, focused tests and full suite; independent review, fix findings and report evidence/limitations.
