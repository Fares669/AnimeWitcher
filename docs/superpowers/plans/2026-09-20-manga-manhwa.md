# Manga & Manhwa Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add first-class AnimeWitcher-backed Manga/Manhwa search, details, chapters, reader, library, latest chapters, and sequential chapter downloads without reusing Anime-only details sections or creating a second transport authority.

**Architecture:** Extend the existing media/provider/search/storage primitives only where they are genuinely shared, then keep Manga presentation in a dedicated `features/manga` subtree. Download Manager V2 remains the logical/transport authority; Manga adds a media kind plus a sequential chapter transport path whose package-level concurrency is always one.

**Tech Stack:** Flutter/Dart 3.13, Riverpod 3, go_router typed routes, Dio, Hive, cached_network_image, background_downloader 9.6.2, existing AnimeWitcher Firestore/Algolia stack.

**Spec:** `docs/superpowers/specs/2026-09-20-manga-manhwa-design.md`

## Global Constraints

- Branch: `feat/manga-manhwa`, based directly on `main` after the Download Manager V2 merge.
- AnimeWitcher backend is the only Manga/Manhwa catalog source.
- Manga and Manhwa use `MultimediaContentType.manga`; their subtype is metadata, not a separate top-level media type.
- Manga details is a dedicated screen/controller and must not request or render comments, reviews, characters, similar, related media, recommendations, episodes, streams, or video-history state.
- Reader first release supports Webtoon/continuous vertical and paged LTR/RTL only.
- Manga/Manhwa chapter downloads always use exactly one active page transfer and never use Anime multipart/chunk settings.
- Anime download behavior and concurrency must remain unchanged.
- No second Manga download manager; V2 owns logical download lifecycle and `background_downloader` remains the network/native execution authority.
- No external Manga catalog fallback.
- Manga library/favorite state must use AnimeWitcher's existing cloud Manga contract when signed in. APK v1.4.9 proves Manga-specific user collections already exist (`fav_manga` and `user_manga`); do not invent a new endpoint or reuse Anime-only `fav_anime`/`user_anime` documents.
- Substantial Apache-2.0 reader source reuse must retain required attribution/license notices.

## Review Focus

- Switching search domains during a slow request must never leak stale Anime/Manga/Character results into the newly selected domain; Task 3 includes a generation-fence test.
- Decimal and non-numeric/special chapter labels must not be coerced into integer episode semantics; Tasks 1-2 include parser tests.
- Opening Manga details must not trigger Anime extras in the background even when those APIs are available; Task 4 includes a call-count contract test.
- Relaunching during a Manga chapter download must not create two page writers or skip a missing page; Tasks 8-9 include restart/one-writer tests.
- A long Manhwa must not eagerly decode/build every page; Task 5 includes a lazy-build/preload-window widget test.
- iOS Search controls must remain native interactive Liquid Glass on the native path; a Flutter blur/surface that only looks like glass is not equivalent.
- Search/Home may carry catalog fields needed to paint immediately, but must not call Manga details/chapter APIs before `MangaDetailsRoute` opens.
- Opening the reader must make the reader the current persistent-header owner so Manga-details back/menu/favorite controls cannot remain above a chapter.
- Signed-in Manga library actions must round-trip through AnimeWitcher's Manga collections and survive app relaunch/account refresh.

## Root-cause audit — 2026-09-20

These findings come from the current `feat/manga-manhwa` code, the existing Anime UI implementation, and the supplied AnimeWitcher v1.4.9 APK. They supersede earlier plan assumptions where they conflict.

1. **Search lost true native Liquid Glass.** `main` uses `AppleLiquidGlassActionGroup` + `AppleLiquidGlassToolbarButton` on iOS. The Manga branch replaced that native path with one `AppleLiquidGlassSurface` containing Flutter popup/gesture controls. It can look glass-like but no longer uses the native interactive menu/morph substrate.
2. **The Manga tab indicator is configured differently from Anime details.** Anime uses the shared `FilterStyleTabBar` without overriding `indicatorSize`; Manga forces `TabBarIndicatorSize.tab`, which explains the long half-width yellow line and different animation.
3. **The instant Manga page is not, by itself, proof of pre-route detail loading.** `MangaDetailsController.build()` is side-effect free and the screen starts `.load()` from its own `initState`; the incoming catalog item already has enough fields to paint immediately. The real pre-open chapter work is Home latest: current `getLatestMangaPage()` queries `manga_views_desc` and then scrapes chapter archives for multiple Manga before any Manga page is opened.
4. **Home Latest Chapters diverged from the original AnimeWitcher contract.** APK v1.4.9 contains `manga_recent` plus a `RecentMangaModel` with `chapter_id`, `chapter_name`, `date`, `manga_id`, `manga_name`, `poster_url`, `poster_url_aniList`, `thumb_uri`, `title`, and `type`. Its adapter/view holder has `chapterName`, `mangaName`, and `timeAgo`. The current branch instead resolves latest chapters by crawling Manga chapter pages and then renders `chapter.name` as a gray subtitle.
5. **Reader overlap is persistent-header ownership.** Manga details registers an `ApplePersistentGlassHeaderScope`. The global controller falls back to the newest active registered route when the current route owns no header. `MangaReaderScreen` registers nothing, so the covered Manga-details header remains selected. `PlayerScreen` already contains the correct current-route owner pattern.
6. **Manga library is local-only because the branch explicitly makes it so.** `LibraryRepository` returns early for Manga in add/move/favorite/remove paths and `Library` skips the account sign-in gate for Manga. Even without those returns, `AnimeWitcherAccountService.saveLibraryItem()` resolves only Anime ids. APK v1.4.9 proves server support exists: `/fav_manga`, `/user_manga`, `user_list_manga`, `manga_doc_id`, `manga_type`, and Manga statistics are present; `UserMangaModel` carries `date`, `doc_ref`, `mangaModel`, `type`, and `views`.

---

### Task 1: Add Manga domain primitives and a read-only backend contract probe

**Files:**
- Create: `lib/core/domain/entity/manga.dart`
- Create: `tool/manga_backend_probe.dart`
- Modify: `lib/core/domain/entity/multimedia_item.dart`
- Modify: `lib/core/extensions/base_provider.dart`
- Test: `test/core/domain/entity/manga_test.dart`
- Test: `test/core/extensions/manga_provider_contract_test.dart`

**Interfaces:**
- Produces: `MangaChapter`, `MangaPage`, `MangaLatestChapter`.
- Produces: `ProviderType.manga`, `MultimediaContentType.manga`.
- Produces optional provider methods: `searchMangaPage`, `getMangaDetails`, `getMangaChapters`, `getMangaChapterPages`, `getLatestMangaPage`.

- [ ] **Step 1: Write parser/model tests before adding production types**

```dart
test('MangaChapter keeps decimal and special chapter identity', () {
  const decimal = MangaChapter(
    id: '12.5',
    mangaId: 'm1',
    url: 'chapter://12.5',
    name: 'الفصل 12.5',
    number: 12.5,
  );
  const special = MangaChapter(
    id: 'extra-a',
    mangaId: 'm1',
    url: 'chapter://extra-a',
    name: 'Extra A',
  );

  expect(decimal.number, 12.5);
  expect(special.number, isNull);
});
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
flutter test test/core/domain/entity/manga_test.dart -r expanded
```

Expected: FAIL because `manga.dart` and the Manga types do not exist.

- [ ] **Step 3: Add the minimal domain types**

Use immutable types:

```dart
final class MangaChapter {
  const MangaChapter({
    required this.id,
    required this.mangaId,
    required this.url,
    required this.name,
    this.number,
    this.publishedAt,
  });

  final String id;
  final String mangaId;
  final String url;
  final String name;
  final double? number;
  final DateTime? publishedAt;
}

final class MangaPage {
  const MangaPage({
    required this.index,
    required this.imageUrl,
    this.headers = const <String, String>{},
  });

  final int index;
  final String imageUrl;
  final Map<String, String> headers;
}

final class MangaLatestChapter {
  const MangaLatestChapter({required this.manga, required this.chapter});
  final MultimediaItem manga;
  final MangaChapter chapter;
}
```

Extend both media enums with `manga` and update JSON parse/serialize switches so old records continue to decode.

- [ ] **Step 4: Add optional Manga APIs to `AnimeWitcherProvider`**

Defaults must be safe and unsupported rather than faking anime data:

```dart
Future<ProviderMediaPage> searchMangaPage(
  String query,
  ProviderSearchFilters filters, {
  int offset = 0,
  int limit = 30,
  CancelToken? cancelToken,
}) async => const ProviderMediaPage(
  items: <MultimediaItem>[],
  nextOffset: 0,
  hasMore: false,
);

Future<List<MangaChapter>> getMangaChapters(String url) async =>
    const <MangaChapter>[];

Future<List<MangaPage>> getMangaChapterPages(
  String mangaUrl,
  MangaChapter chapter,
) async => const <MangaPage>[];
```

- [ ] **Step 5: Add a read-only live backend probe**

`tool/manga_backend_probe.dart` must call the existing AnimeWitcher Firestore/Algolia endpoints with GET/query-only requests and print only schema/index facts, never secrets or full signed image URLs. It must verify:

```text
manga search index reachable
detail document reachable
chapter list shape
page list shape
latest chapter source
supported sort/filter facets
required page-image headers
```

The probe exits non-zero when a required contract is absent so production parsing is not based on APK guesses.

- [ ] **Step 6: Run tests and the probe**

Run:

```bash
flutter test test/core/domain/entity/manga_test.dart test/core/extensions/manga_provider_contract_test.dart -r expanded
dart run tool/manga_backend_probe.dart
```

Expected: tests PASS; probe prints verified live paths/index names and no credentials.

- [ ] **Step 7: Commit**

```bash
git add lib/core/domain/entity/manga.dart lib/core/domain/entity/multimedia_item.dart lib/core/extensions/base_provider.dart tool/manga_backend_probe.dart test/core/domain/entity/manga_test.dart test/core/extensions/manga_provider_contract_test.dart
git commit -m "feat(manga): add domain contracts and backend probe"
```

---

### Task 2: Implement AnimeWitcher Manga catalog, chapters, pages, sorting, and latest data

**Files:**
- Modify: `lib/core/extensions/providers/animewitcher_native_provider.dart`
- Create: `lib/core/extensions/providers/animewitcher_manga_mapping.dart`
- Test: `test/core/extensions/providers/animewitcher_manga_provider_test.dart`
- Test: `test/core/extensions/providers/animewitcher_manga_mapping_test.dart`

**Interfaces:**
- Consumes: Task 1 Manga types/provider methods.
- Produces: live implementations for Manga search/details/chapters/pages/latest.
- Produces: Manga-specific `ProviderSearchFilterOptions`.

- [ ] **Step 1: Encode the verified backend fixture shapes in tests**

Use redacted fixtures copied from the read-only probe, for example:

```dart
test('maps manga hit without episode semantics', () {
  final item = mapAnimeWitcherMangaHit(<String, Object?>{
    'objectID': 'm-42',
    'manga_name': 'Solo Leveling',
    'manga_poster': 'https://img.example/cover.webp',
    'manga_year': 2018,
    'manga_type': 'مانهوا',
  });

  expect(item.contentType, MultimediaContentType.manga);
  expect(item.catalogType, 'مانهوا');
  expect(item.episodes, isNull);
});
```

Also cover decimal chapter numbers, missing optional title, page ordering, and required headers.

- [ ] **Step 2: Run tests and verify RED**

```bash
flutter test test/core/extensions/providers/animewitcher_manga_mapping_test.dart -r expanded
```

- [ ] **Step 3: Add a focused mapping file**

Keep legacy field-name normalization outside the already-large native provider:

```dart
MultimediaItem mapAnimeWitcherMangaHit(Map<String, Object?> hit) { ... }
MangaChapter? mapAnimeWitcherChapter(Map<String, Object?> raw) { ... }
List<MangaPage> mapAnimeWitcherPages(Object? raw) { ... }
```

Malformed chapter/page rows are skipped; no row is converted to `Episode`.

- [ ] **Step 4: Implement Manga queries using existing Algolia/Firestore helpers**

Use the live probe's verified index/path constants. Add bounded TTL caches:

```dart
final Map<String, List<MangaChapter>> _mangaChapterCache = {};
final Map<String, DateTime> _mangaChapterExpiresAt = {};
final Map<String, List<MangaPage>> _mangaPageCache = {};
final Map<String, DateTime> _mangaPageExpiresAt = {};
```

Map sort values to the verified Manga indices and build only verified Manga facets.

- [ ] **Step 5: Add latest chapter retrieval from the official recent feed — no chapter archive crawling**

Return `MangaLatestChapter` directly from the verified `manga_recent`/current live equivalent. Map the APK-proven recent fields (`chapter_id`, `chapter_name`, `date`, `manga_id`, `manga_name`, artwork fields) without calling Anime APIs **and without** calling `_loadMangaArchiveChapters`, `getMangaChapters`, or MangaLek source pages per candidate.

Add a request-count test proving `getLatestMangaPage()` does not warm details/chapter caches or perform N per-Manga chapter requests.

- [ ] **Step 6: Run provider tests**

```bash
flutter test test/core/extensions/providers/animewitcher_manga_provider_test.dart test/core/extensions/providers/animewitcher_manga_mapping_test.dart -r expanded
```

Expected: PASS, including request-count/cache tests.

- [ ] **Step 7: Commit**

```bash
git add lib/core/extensions/providers/animewitcher_native_provider.dart lib/core/extensions/providers/animewitcher_manga_mapping.dart test/core/extensions/providers/animewitcher_manga_provider_test.dart test/core/extensions/providers/animewitcher_manga_mapping_test.dart
git commit -m "feat(manga): implement AnimeWitcher manga catalog"
```

---

### Task 3: Add the four-domain search switch and capability-aware Liquid Glass controls

**Files:**
- Create: `lib/features/search/presentation/search_domain.dart`
- Modify: `lib/features/search/presentation/search_provider.dart`
- Modify: `lib/features/search/presentation/search_screen.dart`
- Modify: `lib/features/search/presentation/widgets/search_header_bar.dart`
- Modify: `lib/features/search/presentation/widgets/search_action_buttons.dart`
- Modify: `lib/features/search/presentation/widgets/search_result_section.dart`
- Reuse/adapt character card widgets from: `lib/features/characters/`
- Test: `test/features/search/presentation/search_domain_test.dart`
- Test: `test/features/search/presentation/widgets/search_action_buttons_test.dart`
- Test: `test/features/search/presentation/search_domain_generation_test.dart`

**Interfaces:**
- Produces: `SearchDomain.anime|animation|manga|characters`.
- Produces: `SearchDomainCapabilities(showSort, showFilter)`.
- Search default remains `anime`.

- [ ] **Step 1: Write domain/capability tests**

```dart
test('characters expose only the domain control', () {
  expect(
    SearchDomain.characters.capabilities,
    const SearchDomainCapabilities(showSort: false, showFilter: false),
  );
});

test('default domain is anime', () {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  expect(container.read(searchDomainProvider), SearchDomain.anime);
});
```

- [ ] **Step 2: Add `SearchDomain` and notifier**

```dart
enum SearchDomain { anime, animation, manga, characters }

@Riverpod(keepAlive: true)
class SearchDomainSelection extends _$SearchDomainSelection {
  @override
  SearchDomain build() => SearchDomain.anime;
  void set(SearchDomain value) => state = value;
}
```

- [ ] **Step 3: Fence page loads by both generation and domain**

Update `PagedSearchNotifier` so `_loadPage` switches by domain and every completion verifies the captured domain:

```dart
final requestDomain = _domain;
final generation = ++_generation;
final page = await _loadPage(provider, 0, requestDomain);
if (generation != _generation || requestDomain != _domain) return;
```

Anime uses existing `searchPage`; Manga uses `searchMangaPage`; Animation uses the verified animation catalog; Characters use a separate character result state and existing AnimeWitcher character query rather than coercing characters into `MultimediaItem`.

- [ ] **Step 4: Add the third Liquid Glass domain control**

`SearchActionButtons` receives:

```dart
required SearchDomain domain,
required ValueChanged<SearchDomain> onDomainSelected,
required bool showSort,
required bool showFilter,
```

Preserve the pre-Manga platform split instead of replacing it:

- On native Apple Liquid Glass, render one `AppleLiquidGlassActionGroup` containing native `AppleLiquidGlassToolbarButton` controls. Sort and domain use native menu items; filter remains a native toolbar action.
- On fallback/non-native platforms, keep the shared visual capsule with Flutter popup controls.
- Width still follows the visible-control count; Character mode leaves only the domain button.
- Do not put Flutter `PopupMenuButton` controls inside `AppleLiquidGlassSurface` on the native iOS path.

Extend `search_action_buttons_test.dart` with a regression assertion for the native action-group configuration so adding the third button cannot silently replace real Liquid Glass again.

- [ ] **Step 5: Add stale-domain RED/GREEN test**

Use a fake provider with completers:

```dart
final anime = Completer<ProviderMediaPage>();
final manga = Completer<ProviderMediaPage>();
// Start Anime, switch to Manga, complete Manga first, Anime last.
expect(renderedTitles, contains('Manga result'));
expect(renderedTitles, isNot(contains('Late anime result')));
```

- [ ] **Step 6: Route cards by content type**

Manga cards push `MangaDetailsRoute`; Anime/Animation cards keep `DetailsRoute`; character cards push the existing character details route.

- [ ] **Step 7: Run search tests**

```bash
flutter test test/features/search -r expanded
```

- [ ] **Step 8: Commit**

```bash
git add lib/features/search test/features/search
git commit -m "feat(search): add anime manga animation and character domains"
```

---

### Task 4: Build a dedicated Manga details page with only Details and Chapters

**Files:**
- Create: `lib/features/manga/presentation/manga_details_controller.dart`
- Create: `lib/features/manga/presentation/manga_details_state.dart`
- Create: `lib/features/manga/presentation/manga_details_screen.dart`
- Create: `lib/features/manga/presentation/widgets/manga_information_section.dart`
- Create: `lib/features/manga/presentation/widgets/manga_chapter_list.dart`
- Modify: `lib/core/router/app_router.dart`
- Test: `test/features/manga/presentation/manga_details_screen_test.dart`
- Test: `test/features/manga/presentation/manga_details_no_anime_extras_test.dart`

**Interfaces:**
- Produces: typed `MangaDetailsRoute`.
- Produces: `MangaDetailsController` that calls only Manga provider APIs.
- Does not depend on `DetailsController`.

- [ ] **Step 1: Write the architectural boundary test first**

Use a fake provider whose Anime-only methods increment counters:

```dart
await tester.pumpWidget(testApp(const MangaDetailsScreen(item: manga)));
await tester.pumpAndSettle();

expect(fake.commentsCalls, 0);
expect(fake.reviewsCalls, 0);
expect(fake.charactersCalls, 0);
expect(fake.similarCalls, 0);
expect(fake.relatedCalls, 0);
expect(fake.episodesCalls, 0);
expect(fake.streamCalls, 0);
```

Also assert the rendered page does not contain labels for comments, reviews, characters, similar, or related.

- [ ] **Step 2: Add typed Manga route**

```dart
@TypedGoRoute<MangaDetailsRoute>(path: '/manga-details')
class MangaDetailsRoute extends GoRouteData with $MangaDetailsRoute {
  const MangaDetailsRoute({required this.$extra});
  final MultimediaItem $extra;

  @override
  Widget build(BuildContext context, GoRouterState state) =>
      MangaDetailsScreen(item: $extra);
}
```

Regenerate go_router code later in this task.

- [ ] **Step 3: Implement Manga controller/state**

Initial load fetches Manga details. Chapters are loaded by Manga API, not `getEpisodes`.

State carries:

```dart
final class MangaDetailsState {
  const MangaDetailsState({
    required this.item,
    this.chapters = const <MangaChapter>[],
    this.isLoadingChapters = false,
    this.error,
  });
  ...
}
```

- [ ] **Step 4: Implement the two-section UI**

Only:

```text
التفاصيل | الفصول
```

Use the exact same shared `FilterStyleTabBar` indicator behavior as Anime details. Specifically, do not set Manga-only `indicatorSize: TabBarIndicatorSize.tab`; the yellow underline length and animation must resolve identically to Anime details.

Reuse generic poster/title/tag primitives only. Do not import `details_comments_preview.dart`, `details_character_rails.dart`, `details_extra_tabs.dart`, `related_anime_screen.dart`, playback launchers, or episode widgets.

- [ ] **Step 4A: Prove details/chapters are demand-loaded by the Manga route**

Before opening `MangaDetailsRoute`, fake-provider counters for `getMangaDetails` and `getMangaChapters` must both be zero. After opening, each logical call starts from the Manga screen. Immediate painting from the incoming search/home item is allowed; network counters are the authority.

Also coalesce concurrent real-provider `getMangaDetails(url)` work (or sequence the controller) so the details call and the chapter call cannot duplicate the same `manga_list/<id>` backend read during one page open.

- [ ] **Step 5: Add chapter order/read/download hooks**

Keep chapter list view-model callbacks abstract at this task:

```dart
onOpen: (chapter) => MangaReaderRoute(...).push(context),
onDownload: (chapter) => ...,
```

Reader/download implementations land in later tasks.

- [ ] **Step 6: Regenerate and test**

```bash
dart run build_runner build --delete-conflicting-outputs
flutter test test/features/manga/presentation/manga_details_screen_test.dart test/features/manga/presentation/manga_details_no_anime_extras_test.dart -r expanded
```

- [ ] **Step 7: Commit**

```bash
git add lib/features/manga lib/core/router test/features/manga
git commit -m "feat(manga): add dedicated details and chapters page"
```

---

### Task 5: Port the minimal reader and add durable reading progress

**Files:**
- Create: `lib/core/storage/manga_reading_repository.dart`
- Create: `lib/features/manga/reader/manga_reader_screen.dart`
- Create: `lib/features/manga/reader/manga_reader_controller.dart`
- Create: `lib/features/manga/reader/widgets/manga_paged_reader.dart`
- Create: `lib/features/manga/reader/widgets/manga_webtoon_reader.dart`
- Create: `lib/features/manga/reader/widgets/manga_page_image.dart`
- Create: `lib/features/manga/reader/widgets/manga_reader_controls.dart`
- Modify: `lib/core/router/app_router.dart`
- Modify: `lib/core/storage/storage_service.dart`
- Create when source is materially reused: `THIRD_PARTY_NOTICES.md`
- Test: `test/core/storage/manga_reading_repository_test.dart`
- Test: `test/features/manga/reader/manga_reader_test.dart`
- Test: `test/features/manga/reader/manga_reader_lazy_pages_test.dart`

**Interfaces:**
- Produces: `MangaReadingProgress` repository methods `get`, `save`, `markRead`.
- Produces: `MangaReaderRoute`.
- Reader consumes online `MangaPage` or resolved local chapter directory.

- [ ] **Step 1: Add persistence tests**

```dart
await repo.save(
  const MangaReadingProgress(
    mangaId: 'm1',
    chapterId: '12',
    pageIndex: 7,
    pageCount: 30,
    updatedAt: 100,
  ),
);
expect(repo.get('m1', '12')!.pageIndex, 7);
```

- [ ] **Step 2: Add a dedicated Hive key space**

Use the existing settings/storage box with a namespaced key such as:

```text
manga_progress:<hash(mangaId)>:<hash(chapterId)>
```

Do not write into watch history or `EP_` keys.

- [ ] **Step 3: Implement reader using the smallest reusable Flutter pieces**

Follow `flutter_manga_reader`'s separation between continuous and paged readers, but prefer existing/native widgets:

- `PageView.builder` for paged mode.
- `ListView.builder`/slivers for Webtoon mode.
- `InteractiveViewer` for zoom.
- `CachedNetworkImage` for online pages.
- `Image.file` for offline pages.

Do not add `photo_view` or another reader package unless native widgets fail an acceptance case.

- [ ] **Step 4: Bound preload/build work**

Keep a preload window of current page ±2 for paged mode. Webtoon remains builder-based and never constructs all chapter children eagerly.

Test:

```dart
expect(pageBuildCount, lessThan(10));
expect(totalChapterPages, 120);
```

after initial pump of a 120-page chapter.

- [ ] **Step 5: Persist progress and read state**

Throttle page-position writes to at most once per second plus reader exit. Last page marks the chapter read.

- [ ] **Step 6: Add route and chapter transitions**

Reader route carries stable Manga/chapter identity. Previous/next chapter uses the chapter list and preserves each chapter's saved page.

On native persistent Liquid Glass, `MangaReaderScreen` must register itself as the current `ApplePersistentGlassHeaderConfig` owner, following the existing `PlayerScreen` pattern. The reader publishes its own back action and no Manga-details trailing buttons. Add a push/pop regression test: details owns menu/favorite -> push reader -> details trailing actions disappear -> pop -> details header restores.

- [ ] **Step 7: Test and commit**

```bash
dart run build_runner build --delete-conflicting-outputs
flutter test test/core/storage/manga_reading_repository_test.dart test/features/manga/reader -r expanded
git add lib/core/storage lib/features/manga/reader lib/core/router test/core/storage/manga_reading_repository_test.dart test/features/manga/reader THIRD_PARTY_NOTICES.md
git commit -m "feat(manga): add reader and reading progress"
```

If no third-party source was copied, omit `THIRD_PARTY_NOTICES.md` from the commit rather than creating an empty notice.

---

### Task 6: Add Anime/Manga Liquid Glass library switching with AnimeWitcher cloud Manga sync

**Files:**
- Create: `lib/features/library/presentation/library_media_kind.dart`
- Create: `lib/features/library/presentation/widgets/library_media_selector.dart`
- Modify: `lib/core/storage/storage_service.dart`
- Modify: `lib/core/storage/library_repository.dart`
- Modify: `lib/features/library/presentation/library_provider.dart`
- Modify: `lib/features/library/presentation/library_state.dart`
- Modify: `lib/features/library/presentation/library_screen.dart`
- Modify: `lib/features/library/presentation/widgets/library_category_selector.dart`
- Modify: `lib/features/library/presentation/widgets/bookmarks_tab.dart`
- Test: `test/features/library/presentation/library_media_selector_test.dart`
- Test: `test/features/library/presentation/library_manga_isolation_test.dart`

**Interfaces:**
- Produces: `LibraryMediaKind.anime|manga`.
- `LibraryState` gains `mediaKind`.
- Storage filters library rows by `MultimediaContentType.manga` versus non-Manga.

- [ ] **Step 1: Write isolation tests**

```dart
await storage.addToLibrary(anime, category: 'watching');
await storage.addToLibrary(manga, category: 'watching');

expect(storage.getLibraryItems(mediaKind: LibraryMediaKind.anime), [anime]);
expect(storage.getLibraryItems(mediaKind: LibraryMediaKind.manga), [manga]);
```

- [ ] **Step 2: Persist the selected top-level library kind**

Add a single settings key and default to Anime.

- [ ] **Step 3: Replace the current local-only Manga path with the official AnimeWitcher cloud contract**

First pin the APK/live contract read-only. v1.4.9 proves Manga-specific collections/fields exist: `fav_manga`, `user_manga`, `manga_doc_id`, `manga_type`, and `UserMangaModel(date, doc_ref, mangaModel, type, views)`. Verify the exact document id and Firestore field/reference types before the first write; do not guess the shape.

Then add Manga-specific account methods (for example `saveMangaLibraryItem`, `removeMangaLibraryItem`, and Manga library refresh) using Manga ids and Manga collection paths. Do not route Manga through `AnimeWitcherSyncIds.animeIdFromUrl` or Anime-only `fav_anime`/`user_anime`.

Remove the current `if (isManga) return` / `if (contentType == manga) return` short circuits from add, move, clear-category, favorite, and remove flows. Signed-in Manga actions must reach the server; sign-in/error behavior must not report a local-only write as a successful cloud save.

Add two-way relaunch coverage: add Manga -> remote doc exists -> rebuild local state/account refresh -> Manga returns; remove Manga -> remote doc disappears -> refresh does not resurrect it.

Add account/library tests that fail if a Manga mutation touches Anime collections or never reaches the account service.

- [ ] **Step 4: Add the requested top-level Liquid Glass selector**

Render:

```text
أنمي | مانجا
```

in the library header, alongside the existing category selector without shrinking the content grid.

- [ ] **Step 5: Make category copy media-aware**

Anime keeps current labels. Manga uses:

```text
المفضلة
أقرأها حالياً
أكملها لاحقاً
أرغب بقراءتها
تمت قراءتها
لا أرغب بقراءتها
```

No new category enum is needed; only copy and assignability rules differ by media kind.

- [ ] **Step 6: Route Manga cards to Manga details**

`BookmarksTab` switches tap route by `item.contentType`.

- [ ] **Step 7: Run tests and commit**

```bash
flutter test test/features/library/presentation/library_media_selector_test.dart test/features/library/presentation/library_manga_isolation_test.dart -r expanded
git add lib/core/storage lib/features/library test/features/library
git commit -m "feat(library): separate anime and manga collections"
```

---

### Task 7: Add resilient Home latest-chapters section

**Files:**
- Modify: `lib/features/home/presentation/home_state.dart`
- Modify: `lib/features/home/presentation/home_provider.dart`
- Modify: `lib/features/home/presentation/home_screen.dart`
- Create: `lib/features/home/presentation/widgets/latest_manga_chapters_section.dart`
- Test: `test/features/home/presentation/home_latest_manga_test.dart`

**Interfaces:**
- `HomeSuccess` gains `List<MangaLatestChapter> latestManga`.
- Manga latest request is independent from Anime home/news failure behavior.

- [ ] **Step 1: Write the resilience test**

Fake `getLatestMangaPage` to throw while Anime home succeeds:

```dart
expect(state, isA<HomeSuccess>());
expect((state as HomeSuccess).data, isNotEmpty);
expect(state.latestManga, isEmpty);
```

- [ ] **Step 2: Add latest Manga to Home state**

```dart
class HomeSuccess extends HomeState {
  const HomeSuccess(
    this.data, {
    this.news = const <NewsItem>[],
    this.latestManga = const <MangaLatestChapter>[],
  });
  ...
}
```

- [ ] **Step 3: Fetch latest chapters in its own guarded future, from `manga_recent` only**

Add a third `Future.wait` entry whose internal catch returns an empty list, matching the News resilience pattern. The provider behind it must use the direct AnimeWitcher recent feed from Task 2; Home must not scrape chapter archives or call Manga details/chapter APIs.

- [ ] **Step 4: Render Latest Chapters with original AnimeWitcher/New Episodes parity**

Reuse the existing `MultimediaCard` poster geometry and yellow bottom-right badge. The card composition must be:

```text
poster + yellow badge: الفصل <x>
Manga title
relative release time (for example: منذ 20 ساعة)
```

Pass the chapter label through the existing yellow badge path (`episodeBadge`, or rename/generalize that property without changing its renderer) and the `manga_recent.date` relative-time string through `subtitle`. Do not use `chapter.name` as the gray subtitle. Tap opens `MangaDetailsRoute`.

Add widget assertions for the yellow `الفصل` badge, title, relative time, and matching New Episodes card dimensions.

- [ ] **Step 5: Test and commit**

```bash
flutter test test/features/home/presentation/home_latest_manga_test.dart test/features/home/presentation/home_provider_test.dart test/features/home/presentation/home_screen_test.dart -r expanded
git add lib/features/home test/features/home
git commit -m "feat(home): add latest manga chapters"
```

---

### Task 8: Generalize V2 logical identity for Manga without breaking existing Anime records

**Files:**
- Modify: `lib/core/services/download_v2/download_v2_models.dart`
- Modify: `lib/core/services/download_v2/download_v2_identity.dart`
- Modify: `lib/core/services/download_v2/download_manager_v2.dart`
- Modify: `lib/core/services/download_v2/logical_download_store_v2.dart`
- Test: `test/core/services/download_v2/download_v2_models_test.dart`
- Test: `test/core/services/download_v2/download_v2_identity_test.dart`
- Create: `test/core/services/download_v2/download_v2_manga_migration_test.dart`

**Interfaces:**
- Produces: `DownloadMediaKind.videoEpisode|mangaChapter`.
- Replace semantic storage names with `mediaId` and `unitKey` while keeping backward JSON compatibility for old `animeId`/`episodeKey` rows.
- Existing Anime callers keep compatibility getters during the migration.

- [ ] **Step 1: Write backward-compatibility tests**

```dart
final old = LogicalDownloadRecordV2.fromJson(<String, Object?>{
  'schemaVersion': 1,
  'logicalId': 'old-anime',
  'animeId': 'a1',
  'episodeKey': 'e2',
  'variantKey': 'sub',
  'generation': 1,
  'taskId': 't1',
  'intent': 'active',
  'destinationPath': '/tmp/a.mp4',
  'sourceDescriptor': <String, Object?>{},
  'updatedAtMillis': 1,
});

expect(old!.mediaKind, DownloadMediaKind.videoEpisode);
expect(old.mediaId, 'a1');
expect(old.unitKey, 'e2');
```

- [ ] **Step 2: Add new schema fields**

```dart
enum DownloadMediaKind { videoEpisode, mangaChapter }

final DownloadMediaKind mediaKind;
final String mediaId;
final String unitKey;

@Deprecated('Use mediaId')
String get animeId => mediaId;

@Deprecated('Use unitKey')
String get episodeKey => unitKey;
```

Serialize schema v2 keys while accepting schema v1 keys on read.

- [ ] **Step 3: Update logical ID generation**

Manga chapter logical ID includes stable Manga ID + chapter ID and never page URL:

```text
manga:<mangaId>:chapter:<chapterId>
```

- [ ] **Step 4: Run the entire existing V2 unit suite**

```bash
flutter test test/core/services/download_v2 -r expanded
```

Expected: all pre-existing Anime V2 tests remain green plus migration tests.

- [ ] **Step 5: Commit**

```bash
git add lib/core/services/download_v2 test/core/services/download_v2
git commit -m "refactor(downloads): support media kinds in v2 records"
```

---

### Task 9: Add one-writer sequential Manga chapter transport inside V2

**Files:**
- Create: `lib/core/services/download_v2/manga_chapter_manifest_v2.dart`
- Create: `lib/core/services/download_v2/manga_chapter_transport_v2.dart`
- Modify: `lib/core/services/download_v2/background_downloader_gateway.dart`
- Modify: `lib/core/services/download_v2/download_manager_v2.dart`
- Modify: `lib/core/services/download_v2/download_v2_provider.dart`
- Modify: `lib/features/manga/presentation/manga_details_controller.dart`
- Test: `test/core/services/download_v2/manga_chapter_transport_v2_test.dart`
- Test: `test/core/services/download_v2/download_manager_v2_manga_test.dart`

**Interfaces:**
- Produces: `MangaChapterTransportSpecV2`.
- Produces: versioned `MangaChapterManifestV2`.
- V2 exposes `startMangaChapter(...)` through the existing manager/provider boundary; callers do not instantiate a second manager.

- [ ] **Step 1: Write the one-writer RED test**

Use a fake package starter that records concurrent page tasks:

```dart
expect(maxActivePackageTasks, 1);
expect(startedPageIndexes, <int>[0, 1, 2, 3]);
expect(videoParallelSpec.parallelChunks, 8); // Anime unchanged.
```

- [ ] **Step 2: Add a durable chapter manifest**

```dart
final class MangaChapterManifestV2 {
  const MangaChapterManifestV2({
    required this.version,
    required this.mangaId,
    required this.chapterId,
    required this.pages,
    required this.completedIndexes,
  });

  static const currentVersion = 1;
  ...
}
```

Store it at:

```text
manga/<stable-manga-id>/<stable-chapter-id>/manifest.json
```

with page files named `0001.<validated-ext>`, `0002.<validated-ext>`, etc.

- [ ] **Step 3: Add a chapter transport spec to the existing gateway boundary**

Refactor the gateway start input to a sealed spec without changing video behavior:

```dart
sealed class DownloadTransportSpecV2 {
  const DownloadTransportSpecV2({required this.taskId});
  final String taskId;
}

final class FileDownloadTransportSpecV2 extends DownloadTransportSpecV2 { ... }

final class MangaChapterTransportSpecV2 extends DownloadTransportSpecV2 {
  const MangaChapterTransportSpecV2({
    required super.taskId,
    required this.destinationDirectory,
    required this.pages,
    required this.retries,
  });

  final String destinationDirectory;
  final List<MangaPage> pages;
  final int retries;
}
```

`PackageBackgroundDownloaderGateway.start` switches on spec type. The Manga handle launches exactly one package `DownloadTask` at a time and launches the next only after the previous reaches complete.

- [ ] **Step 4: Aggregate chapter progress**

When total bytes are available, use durable completed bytes + current task bytes. Otherwise use completed-page fraction plus current-page fractional contribution. Clamp to `0..1`.

- [ ] **Step 5: Implement pause/resume/relaunch semantics**

Rules pinned by tests:

- Pause stops admission of the next page and pauses/cancels only the current package task according to supported package semantics.
- Relaunch reuses completed page files from manifest.
- Active intent resumes from the first missing page.
- Paused intent starts no package task.
- Cancel fences current page callbacks.
- Delete removes manifest + chapter directory.
- A chapter becomes V2 completed only after every page is present/non-empty and manifest completion is true.

- [ ] **Step 6: Preserve iOS truthfulness**

The sequential handle may continue to the next page in background only when the package callback/runtime can safely schedule it. No custom native scheduler is added. Device acceptance in Task 11 determines actual iOS background chaining behavior.

- [ ] **Step 7: Wire Manga details download action**

The controller builds one Manga chapter V2 request; it never calls `ParallelDownloadTask` and never reads the Anime connection-count setting.

- [ ] **Step 8: Run V2 tests**

```bash
flutter test test/core/services/download_v2 -r expanded
```

- [ ] **Step 9: Commit**

```bash
git add lib/core/services/download_v2 lib/features/manga/presentation test/core/services/download_v2
git commit -m "feat(downloads): add sequential manga chapter transport"
```

---

### Task 10: Project Manga downloads into the shared Downloads UI and offline reader

**Files:**
- Modify: `lib/features/library/presentation/downloads_provider.dart`
- Modify: `lib/features/library/presentation/widgets/downloads_tab.dart`
- Create: `lib/features/library/presentation/widgets/completed_download_chapter_card.dart`
- Modify: `lib/features/manga/reader/manga_reader_controller.dart`
- Test: `test/features/library/presentation/downloads_manga_test.dart`
- Test: `test/features/library/presentation/manga_download_count_label_test.dart`
- Test: `test/features/manga/reader/manga_reader_offline_test.dart`

**Interfaces:**
- `DownloadItem` exposes `mediaKind` and optional Manga chapter presentation metadata.
- Completed Manga card opens `MangaReaderRoute`.
- Anime completed card/playback path stays unchanged.

- [ ] **Step 1: Add media-kind projection tests**

```dart
expect(mangaDownload.mediaKind, DownloadMediaKind.mangaChapter);
expect(mangaDownload.episode, isNull);
expect(videoDownload.mediaKind, DownloadMediaKind.videoEpisode);
```

- [ ] **Step 2: Split count formatting by media kind**

```dart
String completedUnitCountLabel(
  BuildContext context,
  DownloadMediaKind kind,
  int count,
) {
  if (kind == DownloadMediaKind.mangaChapter) {
    if (count == 1) return 'فصل';
    if (count == 2) return 'فصلان';
    return '$count فصول';
  }
  ...
}
```

Move final user-facing Arabic copy to localization in Task 11; this task's test pins the grammar before replacement.

- [ ] **Step 3: Group Manga by Manga identity, not episode/file heuristics**

Use stable `mediaId` and `unitKey` from the V2 record. Do not call episode ordering helpers for Manga groups.

- [ ] **Step 4: Add `CompletedDownloadChapterCard`**

It shows chapter label/read state/delete action and opens the reader. It must not import playback launcher, episode watch repository, or video history.

- [ ] **Step 5: Resolve offline pages through the manifest**

The reader controller prefers a complete local manifest/directory when available; otherwise it uses online pages.

- [ ] **Step 6: Run tests and commit**

```bash
flutter test test/features/library/presentation/downloads_manga_test.dart test/features/library/presentation/manga_download_count_label_test.dart test/features/manga/reader/manga_reader_offline_test.dart -r expanded
git add lib/features/library lib/features/manga/reader test/features/library test/features/manga/reader
git commit -m "feat(downloads): show manga chapters and offline reading"
```

---

### Task 11: Localization, generated code, full regression, and physical-device acceptance

**Files:**
- Modify: `lib/l10n/app_ar.arb`
- Regenerate: `lib/l10n/generated/app_localizations.dart`
- Regenerate: `lib/l10n/generated/app_localizations_ar.dart`
- Regenerate: generated Riverpod/router files touched by prior tasks
- Add/update tests where generated labels are asserted
- Update plan checkboxes as gates are proven

**Interfaces:**
- Final user-facing Manga strings come from localization/generated APIs.
- No widget owns duplicated Arabic Manga copy.

- [ ] **Step 1: Add Manga localization keys**

Include at minimum:

```json
{
  "manga": "مانجا",
  "manhwa": "مانهوا",
  "chapters": "الفصول",
  "chapter": "فصل",
  "latestChapters": "أحدث الفصول",
  "readingNow": "أقرأها حاليًا",
  "planToRead": "أرغب بقراءتها",
  "completedReading": "تمت قراءتها"
}
```

Add parameterized plural/count helpers using the repository's supported ARB generation pattern rather than leaving `N فصول` duplicated in widgets.

- [ ] **Step 2: Regenerate code**

```bash
flutter gen-l10n
dart run build_runner build --delete-conflicting-outputs
```

- [ ] **Step 3: Run focused feature suites**

```bash
flutter test test/features/search test/features/manga test/features/library test/features/home test/core/extensions/providers test/core/services/download_v2 -r expanded
```

- [ ] **Step 4: Run full static and test gates**

```bash
flutter analyze
flutter test -r expanded
```

Expected: no new analyzer errors and no Manga/Download V2 regressions.

- [ ] **Step 5: Run iOS physical-device acceptance**

Verify on a real iPhone:

1. Anime/Manga/Animation/Character search switch.
2. Search domain/sort/filter are one true native Liquid Glass action group on iOS.
3. Manga details has only Details + Chapters and no Anime extras.
4. Details/chapter network counters stay zero until Manga details is opened.
5. Manga yellow tab underline length/motion matches Anime details.
6. Latest Chapters matches New Episodes: yellow `الفصل x` badge, Manga title, relative time.
7. Opening a chapter removes Manga-details menu/favorite controls; reader owns the persistent header and popping restores details.
8. Signed-in add/favorite/category/remove mutations round-trip through `fav_manga`/`user_manga` and survive kill/relaunch/account refresh.
9. Webtoon reader.
10. Paged RTL/LTR reader.
11. Reading progress after app relaunch.
12. 30+ page Manga download with one active transfer.
13. Background app during chapter download.
14. Kill/relaunch while chapter download is active.
15. Pause -> relaunch -> resume.
16. Offline completed chapter.
17. Simultaneous Anime multipart download keeps configured Anime connection count.

If iOS cannot chain the *next* page while suspended, record the truthful behavior: the current native page may finish and the chapter waits until foreground/relaunch. Do not add a custom native page scheduler in this plan.

- [ ] **Step 6: Run Android physical-device acceptance**

Repeat chapter lifecycle, one-writer, offline, and simultaneous Anime multipart cases.

- [ ] **Step 7: Run Windows acceptance**

Verify Manga search/details/reader/download/offline reader and the existing Anime details -> episodes navigation regression case.

- [ ] **Step 8: Confirm branch remains cleanly based on `main`**

Before final review, compare `main...feat/manga-manhwa` and verify the branch is not behind and that its diff contains only Manga/Manhwa work.

- [ ] **Step 9: Final scope audit**

Confirm there is no Manga-page import or runtime request for:

```text
comments
reviews
characters
similar
related
recommendations
episodes
streams
video history
```

and no Manga transport path constructs `ParallelDownloadTask`.

- [ ] **Step 10: Commit final generated/localization and verification adjustments**

```bash
git add lib/l10n lib test
git commit -m "chore(manga): finalize localization and verification"
```
