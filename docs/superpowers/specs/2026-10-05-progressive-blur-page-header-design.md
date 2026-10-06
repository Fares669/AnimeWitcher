# Progressive Blur Page Header Design

## Goal

Standardize AnimeWitcher's list and content pages around an Apple-style translucent top header: the page title is physically centered, the header remains transparent, and content scrolling behind it receives a vertically progressive blur that is strongest near the top edge and fades toward the bottom edge.

The visual target is the iOS Settings navigation bar behavior shown by the user: content remains visible behind the header, but becomes increasingly blurred as it approaches the status-bar/top region.

## Scope

Apply this treatment to ordinary app pages that use a title/header above scrollable list or grid content, including:

- Settings and account-management pages that already use `AppPageAppBar`
- Home "View all" pages
- Manga "View all" pages
- News list
- Seasons
- Coming soon
- Recent watched
- Broadcast schedule
- Global statistics
- Character list/detail pages where the page uses a conventional top app bar
- Extra anime/list pages and similar catalog pages

Do not alter purpose-built immersive chrome:

- Video player
- Manga reader
- Image crop screen
- Onboarding
- Dialogs / bottom sheets
- Detail-page hero chrome where artwork is intentionally drawn behind custom controls
- Search's custom floating search-header behavior unless it routes through the shared conventional page header

## Shared Header Architecture

### `AppPageAppBar`

`lib/shared/widgets/app_page_header.dart` becomes the canonical conventional page header.

It must:

- Use a physically centered title in both LTR and RTL layouts.
- Keep the physical back control on the left.
- Preserve trailing platform/window-control space on desktop.
- Be transparent so body content can paint underneath it.
- Reuse the existing persistent Apple-header plumbing where needed; do not revive native Liquid Glass controls.
- Expose no extra configuration unless a current page genuinely needs it.

### Progressive blur

Add a shared internal/header-layer widget based on Flutter's native `BackdropFilter` / `ImageFilter.blur`, without a new dependency.

The blur should be visually progressive from top to bottom rather than a single uniform blur slab. Implement this with the smallest maintainable native Flutter composition, for example several clipped horizontal blur bands whose sigma decreases toward the bottom, masked by a transparent-to-clear gradient if needed.

The result must satisfy:

- strongest blur near the top/status-bar side
- progressively weaker blur toward the bottom
- no opaque rectangle behind the title
- no hard visual cutoff at the lower edge
- dark/light theme compatibility

Exact sigma values are implementation details and may be tuned during verification, but the gradient must be visibly monotonic.

## Scroll-under behavior

Pages adopting the shared header should use `extendBodyBehindAppBar: true` (or equivalent stack/sliver layout) so scrollable content can physically move behind the translucent header.

Initial content must still begin below the header/status area. This is achieved with top padding inside the scrollable content rather than by permanently positioning the body below the AppBar.

This distinction is required:

- at scroll offset 0: first content row/grid tile is fully below the header
- while scrolling: content may pass behind the header and receive the progressive blur

Bottom safe areas and existing bottom-navigation offsets must remain unchanged.

## Migration strategy

Prefer replacing repeated manual conventional `AppBar` blocks with `AppPageAppBar` rather than duplicating blur logic.

A page should only retain a custom app bar when it has behavior that cannot be represented by the shared conventional header.

Migration should be incremental within this branch but cover all conventional list/page headers currently present in the app. Avoid broad layout rewrites unrelated to the header.

## RTL / positioning

The title is physically centered, not merely centered inside the remaining area after leading/trailing widgets.

Back remains on the physical left as requested.

Text direction inside the title follows locale, so Arabic shaping and punctuation remain RTL even though the title container is centered.

Desktop window controls retain their reserved space without shifting the title off the physical center.

## Performance

Blur is restricted to the compact header region only.

Do not blur the full page or full viewport.

Prefer a small fixed number of blur bands rather than per-pixel or scroll-driven shader work. The blur does not need animation based on scroll offset; the visual progression is spatial and constant while content moves underneath it.

## Testing

Add focused widget tests for the shared header and representative migrated pages.

Tests should verify:

- title center remains at the physical screen center in Arabic and English
- back control remains on the physical left
- progressive-blur layer is present
- migrated scrollable content includes enough internal top inset to start below the header
- representative list/grid content can occupy the area behind the app bar when scrolled
- existing safe-area behavior remains intact

Run the focused header/page tests first, then the repository's normal analyzer, Flutter test suite, and iOS debug build workflow before completion.

## Non-goals

- Recreating UIKit's private/material algorithms exactly
- Introducing a new blur or glass package
- Re-enabling the retired native Liquid Glass implementation
- Redesigning immersive player/reader/detail chrome
- Changing navigation semantics or page routing
