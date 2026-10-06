# Progressive Blur Page Headers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every conventional list/content page a physically centered title and an Apple-style translucent header whose blur is strongest at the top and fades toward the content edge.

**Architecture:** Put the effect in `AppPageAppBar` and a small shared progressive-backdrop widget, then migrate conventional hand-written app bars to that component. Pages opt into scroll-under with `extendBodyBehindAppBar: true` and move their initial top spacing into the scrollable body so content starts below the header but can later pass behind it.

**Tech Stack:** Flutter 3.47.1, Material 3, `dart:ui ImageFilter`, existing AnimeWitcher Apple-header helpers; no new package.

**Spec:** `docs/superpowers/specs/2026-10-05-progressive-blur-page-header-design.md`

## Global Constraints

- Back stays on the physical left in both LTR and RTL.
- Page title stays on the physical horizontal center, independent of leading/trailing controls.
- Blur is spatially progressive: strongest at the top, weaker toward the lower edge.
- Header background remains translucent/transparent; no opaque title slab.
- Do not add a blur/glass dependency.
- Do not re-enable retired native Liquid Glass controls.
- Do not redesign player, manga reader, image crop, onboarding, dialogs, or custom detail hero chrome.
- Preserve existing bottom safe-area and dock/navigation insets.

## Review Focus

- Very long Arabic/English titles must ellipsize without colliding with back/actions; Task 1 test covers this.
- Pages with right-side actions must not shift the title off physical center; Task 1 and Task 3 tests cover this.
- Top safe-area differences (notch vs no notch) must keep the first row below the header at offset zero; Task 2 test covers this.
- Empty/error/loading list states must keep the same initial top clearance and remain refreshable; Task 2 representative tests cover this.
- Desktop `WindowControlsGap` must remain reserved without moving the title; Task 1 test covers this.

---

### Task 1: Shared progressive header

**Files:**
- Modify: `lib/shared/widgets/app_page_header.dart`
- Test: `test/shared/widgets/app_page_header_test.dart`

**Interfaces:**
- Produces: `AppPageAppBar(title:, canPop:, onBack:, actions:)` as the canonical conventional page header.
- Produces: `AppProgressiveHeaderBackdrop` used by custom app bars that genuinely cannot use `AppPageAppBar`.
- Consumes: existing `AppBackButton`, `WindowControlsGap`, and persistent Apple-header scope.

- [ ] **Step 1: Write failing widget tests**

Create `test/shared/widgets/app_page_header_test.dart` covering:
1. Arabic and English title center x equals screen center within 1 logical pixel.
2. Back button center remains on the physical left.
3. Adding a trailing action and `WindowControlsGap` does not move title center.
4. A long title is one line with ellipsis and does not overlap leading/trailing hit regions.
5. The header contains the progressive backdrop with at least three decreasing blur bands.

- [ ] **Step 2: Run the focused test and verify RED**

Run: `flutter test test/shared/widgets/app_page_header_test.dart`
Expected: FAIL because the current title is edge-aligned and the progressive backdrop interface does not exist.

- [ ] **Step 3: Implement the shared header**

In `lib/shared/widgets/app_page_header.dart`:
- add `AppProgressiveHeaderBackdrop` using a fixed small set of clipped `BackdropFilter` bands with monotonically decreasing sigma
- make `AppPageAppBar` transparent with zero/scrolled-under elevation
- render its title in a full-width overlay centered physically over the toolbar region
- preserve locale direction inside the title text
- add only `VoidCallback? onBack` and `List<Widget> actions = const []` needed by current pages
- preserve `ApplePersistentGlassHeaderScope` registration for back behavior

- [ ] **Step 4: Run the focused test and verify GREEN**

Run: `flutter test test/shared/widgets/app_page_header_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

Commit message: `ui: add progressive centered page header`

### Task 2: Migrate straightforward list/grid pages

**Files:**
- Modify: `lib/features/settings/presentation/settings_screen.dart`
- Modify: `lib/features/settings/presentation/account_screen.dart`
- Modify: `lib/features/settings/presentation/account_management_screens.dart`
- Modify: `lib/features/settings/presentation/account_privacy_settings_screen.dart`
- Modify: `lib/features/home/presentation/view_all_screen.dart`
- Modify: `lib/features/manga/presentation/manga_view_all_screen.dart`
- Modify: `lib/features/news/presentation/news_list_screen.dart`
- Modify: `lib/features/more/presentation/coming_soon_screen.dart`
- Modify: `lib/features/more/presentation/recent_watched_screen.dart`
- Modify: `lib/features/more/presentation/broadcast_schedule_screen.dart`
- Modify: `lib/features/more/presentation/global_statistics_screen.dart`
- Modify: `lib/features/more/presentation/seasons_screen.dart`
- Modify: `lib/features/characters/presentation/characters_screen.dart`
- Modify: `lib/features/characters/presentation/anime_characters_screen.dart`
- Modify: `lib/features/details/presentation/extra_anime_list_screen.dart`
- Test: `test/shared/widgets/progressive_page_header_migration_test.dart`

**Interfaces:**
- Consumes: Task 1 `AppPageAppBar`.
- Produces: conventional pages whose body can scroll behind the shared header while starting below it.

- [ ] **Step 1: Write failing migration tests**

Create a representative migration test that pumps:
1. Settings with a simulated nonzero top safe area.
2. Home `ViewAllScreen`.
3. News list/grid page or another simple scrollable page with injectable/fake data.

Assert:
- `Scaffold.extendBodyBehindAppBar == true`
- `AppPageAppBar` is present
- first scroll child begins at or below `MediaQuery.padding.top + kToolbarHeight` at offset zero
- after dragging, a content child can enter the header's vertical region
- empty/loading/error states preserve the same scroll-under geometry where applicable

- [ ] **Step 2: Run migration tests and verify RED**

Run: `flutter test test/shared/widgets/progressive_page_header_migration_test.dart`
Expected: FAIL because most pages still place their body below a manual opaque/standard app bar.

- [ ] **Step 3: Migrate the listed pages**

For each conventional page:
- replace repeated manual `PreferredSize + Directionality + AppBar` chrome with `AppPageAppBar`
- set `extendBodyBehindAppBar: true`
- add initial top inset to the page's existing ListView/GridView/CustomScrollView padding equal to `MediaQuery.padding.top + kToolbarHeight` only where Scaffold no longer supplies that separation
- do not alter bottom padding, pagination, refresh, or layout behavior
- keep `MorePaneScope` pages non-poppable by passing `canPop: false` when embedded

- [ ] **Step 4: Run migration tests and affected existing suites**

Run:
`flutter test test/shared/widgets/progressive_page_header_migration_test.dart test/features/home/presentation/widgets/home_rails_rtl_test.dart test/features/search/search_start_page_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

Commit message: `ui: migrate list pages to progressive header`

### Task 3: Preserve pages with header actions and special conventional chrome

**Files:**
- Modify: `lib/features/comments/presentation/animewitcher_comments_screen.dart`
- Modify: `lib/features/comments/presentation/animewitcher_my_comments_screen.dart`
- Modify: `lib/features/comments/presentation/animewitcher_replies_screen.dart`
- Modify: `lib/features/characters/presentation/character_details_screen.dart`
- Modify: `lib/features/manga/reader/manga_reader_settings_screen.dart`
- Test: `test/shared/widgets/progressive_page_header_actions_test.dart`

**Interfaces:**
- Consumes: Task 1 `AppPageAppBar.actions` and, where a page cannot use it cleanly, `AppProgressiveHeaderBackdrop`.
- Produces: centered titles plus preserved sort/favorite/action controls.

- [ ] **Step 1: Write failing action-layout tests**

Cover:
1. Comments/replies sort action still exists and is tappable.
2. Title remains physically centered with the sort action present.
3. Character detail actions remain present while its title uses the character name and stays centered.
4. Manga reader settings retains its existing controls and gets the shared progressive backdrop without changing reader immersive chrome.

- [ ] **Step 2: Run action tests and verify RED**

Run: `flutter test test/shared/widgets/progressive_page_header_actions_test.dart`
Expected: FAIL because current special app bars edge-align or lack the progressive backdrop.

- [ ] **Step 3: Migrate special conventional headers**

- comments/replies: use `AppPageAppBar(actions: ...)` while keeping the existing sort callbacks and menu items
- character detail: use the character name as centered title, preserving current action group behavior
- manga reader settings: keep its specialized action layout but use `AppProgressiveHeaderBackdrop` and physical-center title overlay; do not change the reader screen itself

- [ ] **Step 4: Run action tests and existing comment tests**

Run:
`flutter test test/shared/widgets/progressive_page_header_actions_test.dart test/features/comments/comment_sort_caption_clearance_test.dart test/features/comments/presentation/animewitcher_reviews_screen_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

Commit message: `ui: center action page headers`

### Task 4: Whole-branch verification

**Files:**
- No production files unless verification finds a regression.

**Interfaces:**
- Consumes all previous tasks.
- Produces verification evidence for PR #262.

- [ ] **Step 1: Run analyzer**

Run: `flutter analyze --no-fatal-warnings --no-fatal-infos`
Expected: exit 0.

- [ ] **Step 2: Run the full Flutter suite**

Run: `flutter test --dart-define=ANIMEWITCHER_FIREBASE_API_KEY=test-api-key`
Expected: exit 0, zero failed tests.

- [ ] **Step 3: Verify iOS build through repository CI**

Push the final head and inspect the `Flutter Checks` workflow.
Expected: Analyze and test, iOS debug build without code signing, and native logger typecheck all succeed.

- [ ] **Step 4: Review the full diff against the spec**

Check that no excluded immersive screen was migrated and no conventional list/page manual app bar remains without either `AppPageAppBar` or `AppProgressiveHeaderBackdrop`.

- [ ] **Step 5: Commit any verification-only fixes, then update PR #262**
