# Manga & Manhwa Support Design

Date: 2026-09-20  
Status: Approved  
Branch: `feat/manga-manhwa`  
Base: `feat/download-manager-v2` at `2535c4f3893e4a74f40d8f5b0c93a4c92891e7b2`

## 1. Goal

Add first-class Manga and Manhwa support to AnimeWitcher without building a second application inside the repository and without replacing the existing AnimeWitcher data source.

The feature must add:

- AnimeWitcher-backed Manga/Manhwa catalog data.
- Search switching between Anime, Animation, Manga, and Characters.
- Manga/Manhwa details and chapter browsing.
- A Flutter manga reader with webtoon and paged modes.
- Reading progress.
- Manga library separation from the anime library.
- A latest-chapters section on Home.
- Manga chapter downloads integrated into Download Manager V2.
- Exactly one active network transfer for Manga/Manhwa chapter pages regardless of the user's anime multipart setting.
- Manga-specific completed download copy: `فصل`, `فصلان`, `N فصول`.

The existing anime/player/download behavior must remain unchanged.

## 2. Branch/base decision

`main` does not yet contain the current Download Manager V2 work, while this feature explicitly depends on that manager for chapter downloads. Therefore this branch is intentionally stacked on `feat/download-manager-v2` rather than the current `main`.

Before final merge:

1. Download Manager V2 must land on `main`.
2. `feat/manga-manhwa` must be rebased/updated onto that resulting `main`.
3. Manga-specific regressions must be rerun after the rebase.

The Manga implementation must use the V2 APIs on this branch. It must not revive V1 or old transport ownership code.

## 3. Source-of-truth data decision

AnimeWitcher's own backend remains the Manga/Manhwa source.

The legacy APK analysis already exposed Manga-specific concepts including:

- `manga_list`
- `chapters`
- `chapter_id`
- `pages`
- `images`
- `manga_id`
- `manga_name`
- `manga_name_english`
- `manga_poster`
- `manga_recent`
- `fav_manga`
- `chapters_watched`
- `last_chapter_watched_id`

The legacy search surface also exposed Anime/Manga/Character search domains and Manga Algolia sort indices such as:

- `manga_name_asc`
- `manga_name_desc`
- `manga_views_desc`
- `manga_year_asc`
- `manga_year_desc`

The implementation must verify the current live Firestore/Algolia shape and permissions before writing production parsing. It must not add MangaDex, AniList, Jikan, or another external catalog as a fallback.

If the live backend differs from the legacy schema, adapt the provider to the live schema; do not add a second remote source merely to match the old APK.

## 4. Reader reuse decision

Do not build a reader from a blank screen and do not import an entire third-party manga application.

Primary implementation reference:

- `TesteurManiak/flutter_manga_reader` — Apache-2.0, Flutter, Riverpod, go_router, continuous and single-page readers.

Secondary implementation reference:

- `kodjodevf/mangayomi` — Apache-2.0, mature webtoon/paged reader, preload and memory-management patterns.

MPL-licensed readers such as Tsumiru/Catalyst may be studied for behavior but their source must not be copied into AnimeWitcher in this feature.

The port must copy/adapt only the reader portions we actually need. Any substantial Apache-licensed source reuse must retain the required license/attribution notices.

No whole-app dependency or source-engine framework is imported.

## 5. Domain model

### 5.1 Existing media type extension

Extend the existing media enums rather than introducing a parallel catalog root:

```dart
enum ProviderType {
  movie,
  series,
  anime,
  manga,
  livestream,
  other,
}

enum MultimediaContentType {
  movie,
  series,
  anime,
  manga,
  livestream,
  other,
}
```

Manga and Manhwa both use `MultimediaContentType.manga`.

Manga versus Manhwa is presentation/catalog metadata, not a second top-level media type. Use the existing `catalogType` field or a narrowly-scoped manga type field from the backend.

### 5.2 Chapter types

Do not reuse `Episode` for chapters.

Add focused Manga types:

```dart
class MangaChapter {
  final String id;
  final String mangaId;
  final String url;
  final String name;
  final double? number;
  final DateTime? publishedAt;
  final bool isRead;
}

class MangaPage {
  final int index;
  final String imageUrl;
  final Map<String, String>? headers;
}
```

Chapter numbers must support decimals/special chapters, so the model must not assume every chapter number is an integer.

### 5.3 Reading progress

Use a Manga-specific progress record:

```dart
class MangaReadingProgress {
  final String mangaId;
  final String chapterId;
  final int pageIndex;
  final int pageCount;
  final int updatedAt;
}
```

It must not be stored in video watch history or episode watch state.

## 6. Provider API

Keep AnimeWitcher networking inside `AnimeWitcherNativeProvider`; do not create a second Dio/Firestore/Algolia stack.

Add Manga-specific provider methods with the same timeout, retry, cache, and URL-encoding conventions already used by the provider:

```dart
Future<ProviderMediaPage> searchMangaPage(
  String query, {
  required int offset,
  required ProviderSearchFilters filters,
  CancelToken? cancelToken,
});

Future<MultimediaItem> getMangaDetails(String url);

Future<List<MangaChapter>> getMangaChapters(String url);

Future<List<MangaPage>> getMangaChapterPages(
  String mangaUrl,
  MangaChapter chapter,
);

Future<ProviderMediaPage> getLatestMangaPage({
  int offset = 0,
  int limit = 30,
});
```

Use `manga_recent` for latest-chapter discovery when the live backend confirms it is still authoritative.

Caches must be separate for:

- Manga details.
- Chapter lists.
- Chapter pages.
- Latest Manga/chapter data.

Do not put Manga chapter images through AniZip episode-artwork logic.

## 7. Backend discovery gate

Before production UI depends on Manga data, add a focused backend contract test/probe that verifies:

- Manga search index availability.
- Detail document shape.
- Chapter list path/shape.
- Page list path/shape.
- Latest-chapter path/index.
- Sort/filter support.
- Required image headers, if any.

The probe is read-only.

The feature is not considered complete if a legacy APK field is merely guessed into production code without live verification.

## 8. Search architecture

Add:

```dart
enum SearchDomain {
  anime,
  animation,
  manga,
  characters,
}
```

Default: `SearchDomain.anime`.

The selected domain owns the result provider and capabilities.

### 8.1 Search control

The current search header becomes:

```text
Search field + [Domain | Sort | Filter]
```

The domain button opens one Liquid Glass menu containing:

- أنمي
- انميشن
- مانجا
- شخصيات

### 8.2 Capability rules

Anime:

- Domain visible.
- Sort visible.
- Filter visible.

Animation:

- Domain visible.
- Sort visible when the live `all_animation` catalog exposes supported sorting.
- Filter visible only for filters confirmed by that catalog.

Manga:

- Domain visible.
- Manga sort visible.
- Manga filters visible.

Characters:

- Domain visible.
- Sort hidden.
- Filter hidden.

The action capsule must animate its width and child appearance/disappearance using the app's existing Liquid Glass show/hide behavior.

Do not leave disabled dead buttons in Character mode.

### 8.3 Request fencing

Every search request carries a generation/domain identity.

If the user changes domain while a request is running, stale results from the old domain must be ignored/canceled and must never render in the new domain.

Manga, Anime, Animation, and Character pagination state must not overwrite one another.

## 9. Manga search filtering and sorting

Manga filter values come from the live Manga catalog. Do not reuse anime values blindly.

The initial sort model maps to the legacy Manga index behavior when current backend support is verified:

- Most viewed/popular.
- Name ascending.
- Name descending.
- Year ascending.
- Year descending.

If the backend implements these as separate Algolia indices, the provider maps the UI sort value to the correct index. If it implements them as a single index with sort/facets, the provider uses that live shape.

The UI API stays stable regardless of backend implementation.

## 10. Manga details screen

Create a dedicated Manga details flow. It must **not** reuse the Anime details screen as the page implementation and must not grow Anime-only sections behind media-type conditionals.

Reuse only small, media-agnostic visual primitives where that reduces duplication cleanly, such as:

- Poster/hero image primitives.
- Title and description text styles.
- Generic metadata chips/rows.
- Generic catalog card geometry.

The Manga page itself owns its layout, controller/state, tabs, and data requests.

The only primary sections/tabs in the first release are:

- التفاصيل
- الفصول

The Manga page must **not** contain or request:

- التعليقات.
- المراجعات.
- الشخصيات.
- متشابهة.
- ذات صلة.
- Anime recommendations.
- Video-only Play controls.
- Episode duration.
- Stream server selection.
- Intro/skip controls.
- Subtitles.
- Video watch-state UI.

This is an architectural boundary, not merely hidden UI: opening a Manga page must not fire comments, reviews, character, similar, related, episode, stream, or video-history requests in the background.

The Manga screen shows only Manga-relevant backend metadata such as:

- Arabic/local title.
- English title.
- Manga/Manhwa type.
- Status.
- Year.
- Genres/tags.
- Author/artist only if the backend provides them.
- Chapter count.

If the backend exposes unrelated Anime-style relationship fields, ignore them for this feature rather than adding extra Manga page sections.

## 11. Chapter list

Chapter rows support:

- Chapter number/name.
- Read/unread state.
- Download state/action.
- Ascending/descending chapter order.
- Open reader.
- Offline-open when a downloaded chapter is complete.

Do not use `EpisodeCard` internally if that imports video-history/player semantics. Shared visual primitives may be extracted only where they remove duplication cleanly.

## 12. Manga reader

The reader supports two first-class modes in the first release:

1. Webtoon/continuous vertical mode.
2. Paged mode with LTR/RTL navigation.

Required behavior:

- Pinch zoom.
- Double-tap zoom.
- Fullscreen/immersive presentation.
- Tap to show/hide controls.
- Current page / total pages indicator.
- Previous/next chapter navigation.
- Restore last page.
- Retry one failed image without resetting the chapter.
- Read local downloaded files through the same page renderer.
- Preload a bounded number of nearby pages.
- Dispose decoded/off-screen image resources so a long manhwa does not decode the whole chapter at once.
- Preserve page position through ordinary widget rebuilds and orientation changes.

Use the existing image/network stack where practical. Do not add an image package if the current dependencies can render the required behavior.

## 13. Reading-state persistence

Add a dedicated Manga reading repository/storage entry.

Rules:

- Opening a chapter does not mark it fully read immediately.
- Persist page position while reading at a throttled cadence and on reader exit.
- Reaching the last page marks the chapter read.
- Opening a completed chapter later must not destroy its read state.
- Reader progress must survive app restart.
- Manga progress must not appear in Continue Watching.

A Manga-specific Continue Reading home/library feature is not part of this first feature unless it falls out naturally from the required library UI; do not add another home section beyond Latest Chapters.

## 14. Library

Add a top-level Liquid Glass selector in the library header at the requested location:

```text
أنمي | مانجا
```

The selection is persisted locally.

Anime mode retains the existing categories and behavior.

Manga mode uses Manga-specific wording for the same meaningful categories:

- المفضلة
- أقرأها حالياً
- أكملها لاحقاً
- أرغب بقراءتها
- تمت قراءتها
- لا أرغب بقراءتها

The Manga library must not serialize items as episodes or video history.

First-release Manga library persistence is local using the existing storage layer extended with media-kind separation. Cloud Manga library sync is not required unless the current AnimeWitcher account API already exposes the legacy Manga user paths cleanly during implementation; do not invent a new server API in this branch.

## 15. Home: latest chapters

Add an `أحدث الفصول` section.

Home loading must remain resilient:

- Anime home sections continue to load independently.
- News continues independently.
- Latest Manga chapters load independently.
- Failure of the Manga latest request must not turn the entire Home page into an error.

Home state gets a dedicated latest-Manga/chapter field rather than encoding chapters as fake anime sections.

Each card opens the Manga details page and can show the newest chapter label.

## 16. Download integration

Use Download Manager V2 as the single transport authority.

Do not add a second Manga download manager.

Add a media-kind discriminator to V2 logical metadata:

```dart
enum DownloadMediaKind {
  videoEpisode,
  mangaChapter,
}
```

Manga chapter downloads are logical parent jobs composed of image pages.

A Manga chapter appears as one download row even though it contains multiple page files.

## 17. Manga connection rule

For Manga/Manhwa:

- Exactly one page network transfer may be active at a time for a chapter.
- Never use `ParallelDownloadTask` for Manga pages.
- Never use the user's Anime multipart/connection count for Manga.
- Do not split an individual image into byte ranges/chunks.
- The next page starts only after the current page reaches a terminal success state.
- Anime downloads keep their current V2 parallelism behavior unchanged.

This rule is domain-level and must not be implemented by changing the global Anime holding-queue setting.

## 18. Background-download design

A chapter job has:

- stable logical chapter ID;
- Manga presentation metadata;
- ordered page descriptors;
- completed-page manifest;
- one current page task;
- aggregate progress;
- terminal completion only after all page files are present and valid.

On relaunch:

- completed pages are reused;
- the first missing/incomplete page becomes the next transfer;
- the chapter remains one logical UI row;
- paused Manga chapters stay paused;
- active Manga chapters may continue according to V2's active-intent startup semantics.

On iOS, sequential page tasks must use `background_downloader` native tasks so an already-running page can use URLSession background execution. The implementation must not rely on a pure-Dart loop staying alive indefinitely after suspension.

Because sequentially starting the *next* page after iOS suspends the process is platform-sensitive, the implementation must include an iOS device acceptance gate. If the package cannot safely chain page tasks while suspended, the chapter must truthfully pause between pages in background rather than introducing a custom native scheduler without a separate design review.

## 19. Manga download files

Use a deterministic directory layout under the app's managed downloads storage:

```text
manga/<stable-manga-id>/<stable-chapter-id>/
  manifest.json
  0001.<ext>
  0002.<ext>
  ...
```

File extensions come from validated response/content information; do not assume every page is JPEG.

A chapter is Completed only if:

- every expected page is present;
- every page file is non-empty;
- the manifest is complete and versioned;
- no page task is still active.

Deleting a chapter removes only that chapter directory and its V2 logical metadata.

## 20. Manga download progress

Aggregate chapter progress from durable page completion plus the current page's transport progress.

When total bytes are known:

```text
(completed page bytes + current page downloaded bytes) / expected chapter bytes
```

When byte sizes are not known, use page-based progress without fabricating byte precision.

Do not display impossible >100% progress.

## 21. Downloads UI

The Downloads page remains shared.

Completed items are grouped by media kind.

Anime group count:

- `حلقة`
- `حلقتان`
- `N حلقات`

Manga group count:

- `فصل`
- `فصلان`
- `N فصول`

Add a Manga-specific completed chapter card rather than making `CompletedDownloadEpisodeCard` understand reading state.

A Manga completed card opens the reader, not the video player.

Active Manga rows may reuse the common download progress/status shell where semantics are media-agnostic.

## 22. Localization

Add Arabic/English localization strings for:

- Manga.
- Manhwa.
- Chapters.
- Chapter singular/dual/plural count.
- Read/reading/plan-to-read labels.
- Reader controls/settings.
- Search domains.
- Latest chapters.
- Manga download messages.

Do not hard-code new user-facing strings in widgets.

## 23. Error behavior

Data:

- Empty Manga catalog is a valid empty state.
- Failed Manga requests expose recoverable retry UI without breaking Anime pages.
- Unsupported/malformed backend chapter/page documents are skipped or surfaced as a Manga-specific data error, not coerced into Episode.

Reader:

- One failed page can retry independently.
- A failed page does not mark the chapter read.
- Local missing/corrupt page reports an offline-file error and can offer re-download.

Downloads:

- A failed page preserves completed pages.
- Retry resumes from the first missing/failed page.
- Cancel stops the current page and fences stale callbacks.
- Delete cannot be resurrected by late transport events.

## 24. Testing strategy

### Provider/data tests

- Parse Manga details.
- Parse decimal/special chapter numbering.
- Parse page lists and headers.
- Search sort/index mapping.
- Manga filters remain separate from Anime filters.
- Latest chapter mapping.
- Stale search request generation is ignored.

### Search widget tests

- Default domain is Anime.
- Domain menu contains all four requested domains.
- Character hides sort/filter.
- Manga restores sort/filter.
- Liquid Glass action capsule changes width without dead hit targets.
- Switching domain while loading cannot render stale results.

### Manga details/chapter tests

- Details renders Manga copy.
- Chapters render without Episode/player dependencies.
- Ascending/descending order.
- Read state survives refresh.

### Reader tests

- Paged LTR.
- Paged RTL.
- Webtoon vertical.
- Initial-page restore.
- Progress persistence.
- Last page marks read.
- Failed-image retry.
- Downloaded page path.
- Long chapter does not eagerly build/decode every page.

### Library/Home tests

- Anime/Manga library selector.
- Counts remain media-kind isolated.
- Manga wording.
- Latest-chapter failure does not fail Home.
- Latest chapter opens Manga details.

### Download tests

- Manga page transport concurrency is exactly one.
- Anime parallelism remains unchanged.
- Chapter progress aggregates correctly.
- Completed pages survive restart.
- Pause/relaunch remains paused.
- Active restart resumes from first incomplete page.
- Duplicate start coalesces to one logical chapter job.
- Cancel/delete fence late page callbacks.
- Completion requires all page files and manifest.
- Arabic chapter count singular/dual/plural.

### Device acceptance

iOS and Android:

1. Open online Manga chapter.
2. Reader webtoon and paged modes.
3. Resume reading after app restart.
4. Download a 30+ page chapter.
5. Verify only one Manga page transfer is active.
6. Background the app during download.
7. Kill/relaunch during active chapter download.
8. Pause/relaunch/resume.
9. Network loss/recovery.
10. Open completed chapter fully offline.
11. Delete downloaded chapter.
12. Run an Anime multipart download in parallel and verify its connection setting is unaffected.

Windows:

- Manga search/details/reader.
- Chapter downloads.
- Offline reader.
- No regression in Anime details/player navigation.

## 25. Rollout order

The implementation will be split into dependency-ordered plans after this written spec is approved:

1. Live Manga backend contract discovery.
2. Domain types/provider APIs.
3. Manga search domain and dynamic search controls.
4. Manga details and chapter list.
5. Reader and reading-progress persistence.
6. Library Manga mode.
7. Home latest chapters.
8. V2 Manga chapter download model and sequential transport.
9. Downloads UI/count copy/offline reader integration.
10. Full regression/device acceptance.
11. Rebase onto the post-V2 `main`.
12. Final review and merge readiness.

Each step must land with tests before the next dependent slice is marked complete.

## 26. Explicit non-goals

This first Manga/Manhwa feature does not:

- add external Manga catalog providers;
- add a new Manga extension ecosystem;
- add a second download manager;
- turn chapters into Episodes;
- turn reading progress into video watch history;
- add cloud Manga sync unless the current backend/account API already provides it with no server changes;
- copy entire third-party Manga applications;
- add novel/e-book support;
- add a second Manga-specific Home tab;
- add speculative reader modes beyond Webtoon and paged LTR/RTL;
- add comments to Manga pages;
- add reviews to Manga pages;
- add character sections to Manga pages;
- add similar/recommendation sections to Manga pages;
- add related-media sections to Manga pages;
- reuse the Anime details page implementation as the Manga details page;
- delete unrelated Anime functionality.

The unfinished phrase `واحذف` from the original request did not identify an object to remove, so this design intentionally deletes nothing based on that phrase.
