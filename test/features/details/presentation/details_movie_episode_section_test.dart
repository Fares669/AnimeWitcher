import 'dart:collection';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:animewitcher/core/providers/episode_sort_provider.dart';
import 'package:animewitcher/core/storage/episode_watch_repository.dart';
import 'package:animewitcher/features/details/presentation/downloaded_file_provider.dart';
import 'package:animewitcher/features/details/presentation/widgets/episode_browse.dart';
import 'package:animewitcher/features/details/presentation/widgets/episode_search.dart';
import 'package:animewitcher/features/library/presentation/history_provider.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/account/animewitcher_comment_models.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_provider.dart';
import 'package:animewitcher/core/services/download_v2/logical_download_store_v2.dart';
import 'package:animewitcher/core/storage/library_category.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/core/utils/artwork_quality.dart';
import 'package:animewitcher/features/details/presentation/details_controller.dart';
import 'package:animewitcher/features/details/presentation/download_launcher.dart';
import 'package:animewitcher/features/details/presentation/details_screen.dart';
import 'package:animewitcher/features/details/presentation/widgets/anime_information_section.dart';
import 'package:animewitcher/features/details/presentation/widgets/details_hero_actions.dart';
import 'package:animewitcher/features/details/presentation/widgets/details_layout_widgets.dart';
import 'package:animewitcher/features/details/presentation/widgets/episode_card.dart';
import 'package:animewitcher/features/details/presentation/widgets/episode_view_mode.dart';
import 'package:animewitcher/features/details/presentation/widgets/episode_action_chip.dart';
import 'package:animewitcher/features/comments/presentation/animewitcher_comments_screen.dart';
import 'package:animewitcher/features/library/presentation/downloads_provider.dart';
import 'package:animewitcher/features/library/presentation/library_media_kind.dart';
import 'package:animewitcher/features/library/presentation/library_provider.dart';
import 'package:animewitcher/features/library/presentation/library_state.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/memory_storage_service.dart';

final class _Storage extends MemoryStorageService {
  @override
  Future<Map<String, Map<String, dynamic>>> getAllDownloadMetadata() async =>
      const <String, Map<String, dynamic>>{};

  @override
  String? getString(String key) => settings[key] as String?;

  @override
  int getPosition(String url) => 0;

  @override
  List<Map<String, dynamic>> getWatchHistory() =>
      const <Map<String, dynamic>>[];

  @override
  int getEpisodePosition(
    String epUrl, {
    String? mainUrl,
    int? season,
    int? episode,
  }) => 0;

  @override
  int getEpisodeDuration(
    String epUrl, {
    String? mainUrl,
    int? season,
    int? episode,
  }) => 0;
}

final class _EmptyLibrary extends Library {
  @override
  LibraryState build() =>
      const LibraryEmpty(LibraryCategory.favorite, LibraryMediaKind.anime);

  @override
  bool isFavorite(String url, {String? providerId}) => false;

  @override
  LibraryCategory? itemCategory(
    String url, {
    String? providerId,
    bool manga = false,
  }) => null;
}

final class _EmptyDownloads extends DownloadsNotifier {
  @override
  Future<List<DownloadItem>> build() async => const <DownloadItem>[];
}

final class _BatchLauncher extends DownloadLauncher {
  _BatchLauncher(super.ref);

  final batches = <List<Episode>>[];

  @override
  Future<void> launchBatch(
    BuildContext context,
    MultimediaItem item,
    List<Episode> selectedEpisodes,
  ) async {
    batches.add(List<Episode>.of(selectedEpisodes));
  }
}

final class _RouteObserver extends NavigatorObserver {
  Route<dynamic>? pushed;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed = route;
  }
}

final class _ReadyDetailsController extends DetailsController {
  _ReadyDetailsController(this.item);

  final MultimediaItem item;

  @override
  DetailsState build(String itemUrl) => DetailsState(
    details: AsyncData<MultimediaItem?>(item),
    episodes: AsyncData<List<Episode>>(item.episodes ?? const <Episode>[]),
    cast: const AsyncData<List<Actor>>(<Actor>[]),
    trailers: const AsyncData<List<Trailer>>(<Trailer>[]),
    related: const AsyncData<List<MultimediaItem>>(<MultimediaItem>[]),
    recommendations: const AsyncData<List<MultimediaItem>>(<MultimediaItem>[]),
    seasonMap: <int, List<Episode>>{1: item.episodes ?? const <Episode>[]},
    item: item,
    isMovie: item.contentType == MultimediaContentType.movie,
    basicDetailsResolved: true,
    nextAiringResolved: true,
  );

  @override
  Future<void> loadDetails(
    MultimediaItem item, {
    bool autoPlay = false,
  }) async {}

  @override
  Future<void> loadEpisodesOnDemand({bool forceReload = false}) async {}
}

final class _ProjectionDownloads extends DownloadsNotifier {
  @override
  Future<List<DownloadItem>> build() async => const [];
  void publish(List<DownloadItem> items) => state = AsyncData(items);
}

final class _CountedDownloads extends ListBase<DownloadItem> {
  _CountedDownloads(this.items);
  final List<DownloadItem> items;
  int reads = 0;

  @override
  int get length => items.length;
  @override
  set length(int length) =>
      throw UnsupportedError('immutable Downloads fixture');
  @override
  DownloadItem operator [](int index) {
    reads++;
    return items[index];
  }

  @override
  void operator []=(int index, DownloadItem value) =>
      throw UnsupportedError('immutable Downloads fixture');
}

final class _ProjectionFiles extends DownloadedFiles {
  @override
  Map<String, File?> build() => {};
  @override
  Future<void> checkFile(MultimediaItem item, {Episode? episode}) async {}
}

final class _ProjectionHistory extends WatchHistory {
  @override
  List<HistoryItem> build() => const [];
}

final class _ProjectionSort extends EpisodeSortAscendingNotifier {
  @override
  bool build() => true;
  @override
  void setAscending(bool value) => state = value;
}

final class _ProjectionWatch extends Fake implements EpisodeWatchRepository {
  final watched = <String>{};
  @override
  bool isWatched(String mainUrl, Episode episode) =>
      watched.contains(episode.url);
  @override
  bool? getExplicitState(String mainUrl, Episode episode) =>
      watched.contains(episode.url) ? true : null;
}

final class _EpisodeUrlReads {
  int count = 0;
}

final class _CountedRangeEpisode extends Episode {
  _CountedRangeEpisode({
    required super.name,
    required super.url,
    required super.season,
    required super.episode,
    required super.dubStatus,
    required this.probe,
  });

  final _EpisodeUrlReads probe;

  @override
  String get url {
    probe.count++;
    return super.url;
  }
}

final class _ProjectionDetails extends _ReadyDetailsController {
  _ProjectionDetails(super.item);
  @override
  DetailsState build(String itemUrl) =>
      super.build(itemUrl).copyWith(selectedDubStatus: DubStatus.subbed);
  void publish(List<Episode> episodes) => state = state.copyWith(
    episodes: AsyncData(episodes),
    seasonMap: {1: episodes},
  );
}

MultimediaItem _projectionItem() => MultimediaItem(
  title: 'مختبر الحلقات',
  url: 'https://example.test/episode-projection',
  posterUrl: '',
  contentType: MultimediaContentType.anime,
  episodes: [
    for (var i = 0; i <= 104; i++) ...[
      Episode(
        name: i == 0
            ? 'الحلقة الخاصة'
            : i == 104
            ? 'Magic Café'
            : 'البداية $i',
        serverName: i == 0 ? 'الفيلم' : 'الحلقة $i',
        url: 'https://example.test/sub/$i',
        season: 1,
        episode: i,
        dubStatus: DubStatus.subbed,
      ),
      if (i % 20 == 0)
        Episode(
          name: 'مدبلج وحلقة $i',
          url: 'https://example.test/dub/$i',
          season: 1,
          episode: i,
          dubStatus: DubStatus.dubbed,
        ),
    ],
  ],
);

List<int> _shownProjection(WidgetTester tester) {
  final grid = find.byType(SliverEpisodeCardGrid);
  if (grid.evaluate().isNotEmpty) {
    // The handset sliver only mounts the rows within reach of its viewport.
    // Check the order it passes to the lazy builder, then interact with a
    // real visible card below to assert selection wiring.
    EpisodeCard card(Widget child) => switch (child) {
      FadeTransition(child: final inner) => card(inner!),
      SlideTransition(child: final inner) => card(inner!),
      final EpisodeCard episodeCard => episodeCard,
      _ => throw StateError('Unexpected Details row widget'),
    };
    final deck = tester.widget<SliverEpisodeCardGrid>(grid);
    final context = tester.element(grid);
    return [
      for (var i = 0; i < deck.itemCount; i++)
        card(deck.itemBuilder(context, i)).episode.episode,
    ];
  }
  return tester
      .widgetList<EpisodeCard>(find.byType(EpisodeCard))
      .map((card) => card.episode.episode)
      .toList();
}

Finder _projectionKey(String value) => find.byKey(ValueKey(value));

Finder _projectionScrollView() => find
    .descendant(
      of: find.byKey(const PageStorageKey<String>('desktop-details-info-tab')),
      matching: find.byType(Scrollable),
    )
    .first;

Future<void> _positionProjection(WidgetTester tester, Finder target) async {
  expect(target, findsOneWidget);
  if (target.hitTestable().evaluate().isEmpty) {
    // The actual Details chrome floats above the scroll view. Aligning at
    // zero puts the control behind it instead of making it tappable.
    await Scrollable.ensureVisible(tester.element(target), alignment: 0.35);
    await tester.pumpAndSettle();
  }
  expect(target.hitTestable(), findsOneWidget);
}

Future<void> _tapProjection(WidgetTester tester, Finder button) async {
  await _positionProjection(tester, button);
  await tester.tap(button.hitTestable());
  await tester.pumpAndSettle();
}

void main() {
  for (final wide in [false, true]) {
    testWidgets(
      'Details isolates other series downloads on ${wide ? 'desktop' : 'phone'}',
      (tester) async {
        tester.view.physicalSize = wide
            ? const Size(1360, 1050)
            : const Size(430, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        addTearDown(resetEpisodeBrowse);
        addTearDown(() => episodeViewMode.value = EpisodeViewMode.list);
        final item = _projectionItem();
        final downloads = _ProjectionDownloads();
        final foreign = item.copyWith(
          url: 'https://example.test/foreign',
          provider: 'test.other',
        );
        final otherProvider = item.copyWith(provider: 'test.not-native');
        final first = item.episodes!.firstWhere(
          (ep) => ep.episode == 1 && ep.dubStatus == DubStatus.subbed,
        );
        final sameHistoryItem = item.copyWith(provider: 'Local');
        DownloadItem row(
          int i,
          MultimediaItem parent,
          Episode episode,
          TaskStatus status, {
          double progress = 0,
          String? alias,
        }) => DownloadItem(
          task: DownloadTask(
            taskId: 'fixture-$i',
            url: 'https://example.test/video.mp4',
            filename: 'fixture.mp4',
          ),
          item: parent,
          episode: episode,
          trackingUrl: alias ?? episode.url,
          timestamp: i,
          status: status,
          progress: progress,
        );

        final foreignRows = [
          for (var i = 0; i < 1500; i++)
            row(
              i,
              foreign,
              first.copyWith(url: 'foreign://$i'),
              TaskStatus.complete,
            ),
        ];
        // The same URL on another provider must never promote its row.
        final wrongProvider = row(
          2001,
          otherProvider,
          first,
          TaskStatus.complete,
        );
        final container = ProviderContainer(
          overrides: [
            storageServiceProvider.overrideWithValue(_Storage()),
            detailsControllerProvider(item.url)
                .overrideWith(() => _ProjectionDetails(item)),
            libraryProvider.overrideWith(_EmptyLibrary.new),
            watchHistoryProvider.overrideWith(_ProjectionHistory.new),
            episodeWatchRepositoryProvider.overrideWithValue(
              _ProjectionWatch(),
            ),
            logicalDownloadStoreV2Provider.overrideWithValue(
              InMemoryLogicalDownloadStoreV2(),
            ),
            downloadsProvider.overrideWith(() => downloads),
            downloadedFilesProvider.overrideWith(_ProjectionFiles.new),
            episodeSortAscendingProvider.overrideWith(_ProjectionSort.new),
          ],
        );
        addTearDown(container.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              locale: const Locale('ar'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              theme: ThemeData.dark(),
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () => Navigator.of(context).push<void>(
                      MaterialPageRoute<void>(
                        builder: (_) => DetailsScreen(item: item),
                      ),
                    ),
                    child: const Text('Open measured Details'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await container.read(downloadsProvider.future);
        final initial = _CountedDownloads([...foreignRows, wrongProvider]);
        downloads.publish(initial);
        await tester.tap(find.text('Open measured Details'));
        await tester.pumpAndSettle();
        await _tapProjection(tester, _projectionKey('details-episodes-toggle'));
        final firstCard = find.byKey(ValueKey(first.url));
        await _positionProjection(tester, firstCard);
        final visibleCardsBefore = find.byType(EpisodeCard).evaluate().length;
        expect(visibleCardsBefore, greaterThan(1));
        expect(_shownProjection(tester).first, 0);
        expect(
          find.descendant(
            of: firstCard,
            matching: find.byIcon(Icons.delete_outline_rounded),
          ),
          findsNothing,
        );

        var builds = 0;
        debugOnRebuildDirtyWidget = (element, _) {
          if (element.widget is EpisodeCard) builds++;
        };
        addTearDown(() => debugOnRebuildDirtyWidget = null);
        var unrelatedReads = 0;
        for (var tick = 1; tick <= 8; tick++) {
          final snapshot = _CountedDownloads([
            ...foreignRows,
            wrongProvider,
            row(2000, foreign, first, TaskStatus.running, progress: tick / 10),
          ]);
          downloads.publish(snapshot);
          await tester.pump();
          unrelatedReads += snapshot.reads;
        }
        final unrelatedBuilds = builds;
        final initialReads = initial.reads;
        final active = row(2002, item, first, TaskStatus.running, progress: .6);
        downloads.publish([...foreignRows, wrongProvider, active]);
        await tester.pump();
        expect(
          find.descendant(of: firstCard, matching: find.text('60%')),
          findsOneWidget,
        );
        final complete = row(
          2002,
          sameHistoryItem,
          first.copyWith(url: 'legacy://renamed'),
          TaskStatus.complete,
          progress: 1,
          alias: first.url,
        );
        downloads.publish([...foreignRows, wrongProvider, complete]);
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: firstCard,
            matching: find.byIcon(Icons.delete_outline_rounded),
          ),
          findsOneWidget,
        );
        expect(find.text('60%'), findsNothing);

        final filters = _projectionKey('episode-filter-downloaded');
        await _tapProjection(tester, filters);
        expect(_shownProjection(tester), [1]);
        downloads.publish([...foreignRows, wrongProvider]);
        await tester.pumpAndSettle();
        expect(_shownProjection(tester), isEmpty);
        await _tapProjection(tester, _projectionKey('episode-filter-all'));

        // A real user scroll, then route-pop, must preserve the catalog.
        final cards = find.byType(EpisodeCard);
        final shownCards = cards.hitTestable();
        if (shownCards.evaluate().isEmpty) {
          await _positionProjection(tester, cards.first);
        }
        List<String> visibleUrls() => tester
            .widgetList<EpisodeCard>(shownCards)
            .map((card) => card.episode.url)
            .toList();
        final cardsBeforeScroll = visibleUrls();
        await tester.drag(shownCards.last, const Offset(0, -520));
        await tester.pumpAndSettle();
        final cardsAfterScroll = visibleUrls();
        expect(cardsBeforeScroll, isNotEmpty);
        expect(cardsAfterScroll, isNotEmpty);
        expect(cardsAfterScroll, isNot(cardsBeforeScroll));
        tester.state<NavigatorState>(find.byType(Navigator)).pop();
        await tester.pumpAndSettle();
        expect(find.text('Open measured Details'), findsOneWidget);
        expect(tester.takeException(), isNull);
        debugOnRebuildDirtyWidget = null;

        // Read each snapshot once, not once per mounted card or alias,
        // and don't relayout these rows when another series progresses.
        expect(initialReads, foreignRows.length + 1);
        expect(unrelatedReads, 8 * (foreignRows.length + 2));
        expect(unrelatedBuilds, 0);
      },
    );
  }

  testWidgets(
    'portrait episode selection keeps its still but quality still updates',
    (tester) async {
      tester.view.physicalSize = const Size(780, 1688);
      tester.view.devicePixelRatio = 2;
      final previousQuality = highQualityArtwork.value;
      highQualityArtwork.value = true;
      addTearDown(tester.view.reset);
      addTearDown(() {
        highQualityArtwork.value = previousQuality;
        imageCache
          ..clear()
          ..clearLiveImages();
      });
      const url = 'https://example.test/episode-stability-still.jpg';
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawColor(const Color(0xff526c86), ui.BlendMode.src);
      final picture = recorder.endRecording();
      final image = picture.toImageSync(96, 54);
      picture.dispose();
      for (final width in [384, 288]) {
        final key = await ResizeImage.resizeIfNeeded(
          width,
          null,
          const CachedNetworkImageProvider(url),
        ).obtainKey(ImageConfiguration.empty);
        imageCache.putIfAbsent(
          key,
          () => OneFrameImageStreamCompleter(
            SynchronousFuture(ImageInfo(image: image.clone())),
          ),
        );
      }
      image.dispose();

      final episode = Episode(
        name: 'Episode 1',
        url: 'episode://stable',
        episode: 1,
        posterUrl: url,
      );
      final item = MultimediaItem(
        title: 'Episode art fixture',
        url: 'https://example.test/episode-stability-title',
        posterUrl: '',
        episodes: [episode],
      );
      final provider = detailsControllerProvider(item.url);
      final container = ProviderContainer(
        overrides: [
          storageServiceProvider.overrideWithValue(_Storage()),
          downloadsProvider.overrideWith(_EmptyDownloads.new),
          logicalDownloadStoreV2Provider.overrideWithValue(
            InMemoryLogicalDownloadStoreV2(),
          ),
          provider.overrideWith(() => _ReadyDetailsController(item)),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            locale: const Locale('ar'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Center(
                child: EpisodeCard(
                  episode: episode,
                  parentItem: item,
                  plain: true,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final art = find.byType(CachedNetworkImage);
      final prior = tester.widget<CachedNetworkImage>(art);
      expect(prior.memCacheWidth, 384);
      await tester.longPress(find.byType(EpisodeCard));
      await tester.pumpAndSettle();
      expect(container.read(provider).selectedEpisodeKeys, hasLength(1));
      expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
      expect(tester.widget<CachedNetworkImage>(art), same(prior));

      highQualityArtwork.value = false;
      await tester.pumpAndSettle();
      expect(tester.widget<CachedNetworkImage>(art).memCacheWidth, 288);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      // Let the dependency's delayed cache housekeeping finish off-screen.
      await tester.pump(const Duration(seconds: 11));
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  for (final wide in [false, true]) {
    testWidgets(
      'Details episode projection preserves selection, range and filters on '
      '${wide ? 'wide' : 'phone'}',
      (tester) async {
        tester.view.physicalSize = wide
            ? const Size(1360, 1050)
            : const Size(430, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        addTearDown(resetEpisodeBrowse);
        addTearDown(() => episodeViewMode.value = EpisodeViewMode.list);
        addTearDown(() => episodeSearchQuery.value = '');

        final item = _projectionItem();
        final details = _ProjectionDetails(item);
        final watch = _ProjectionWatch();
        final downloads = _ProjectionDownloads();
        final container = ProviderContainer(
          overrides: [
            storageServiceProvider.overrideWithValue(_Storage()),
            detailsControllerProvider(item.url).overrideWith(() => details),
            libraryProvider.overrideWith(_EmptyLibrary.new),
            watchHistoryProvider.overrideWith(_ProjectionHistory.new),
            episodeWatchRepositoryProvider.overrideWithValue(watch),
            logicalDownloadStoreV2Provider.overrideWithValue(
              InMemoryLogicalDownloadStoreV2(),
            ),
            downloadsProvider.overrideWith(() => downloads),
            downloadedFilesProvider.overrideWith(_ProjectionFiles.new),
            episodeSortAscendingProvider.overrideWith(_ProjectionSort.new),
          ],
        );
        addTearDown(container.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              locale: const Locale('ar'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              theme: ThemeData.dark(),
              home: DetailsScreen(item: item),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await _tapProjection(tester, _projectionKey('details-episodes-toggle'));
        await _tapProjection(tester, _projectionKey('episode-range-menu'));
        await _tapProjection(tester, _projectionKey('episode-range-1'));
        expect(find.text('الحلقات 100–104'), findsOneWidget);
        expect(_shownProjection(tester), [100, 101, 102, 103, 104]);

        await _tapProjection(tester, _projectionKey('episode-sort-toggle'));
        expect(_shownProjection(tester), [104, 103, 102, 101, 100]);

        final first = item.episodes!.singleWhere((e) => e.episode == 104);
        final card = find.byKey(ValueKey(first.url));
        await _positionProjection(tester, card);
        await tester.longPress(card.hitTestable());
        await tester.pumpAndSettle();
        expect(
          container
              .read(detailsControllerProvider(item.url))
              .selectedEpisodeKeys,
          isNotEmpty,
        );
        expect(find.text('تم تحديد 1'), findsOneWidget);
        if (!wide && card.evaluate().isEmpty) {
          // The phone lazily mounts rows. The new selection bar reduces the
          // viewport, so scroll as a viewer would with selection still open.
          await tester.scrollUntilVisible(
            card,
            100,
            scrollable: _projectionScrollView(),
            maxScrolls: 8,
          );
          await tester.pumpAndSettle();
        }
        expect(_shownProjection(tester), [104, 103, 102, 101, 100]);
        details.clearEpisodeSelection();
        await tester.pumpAndSettle();

        if (wide) {
          await _tapProjection(tester, find.byIcon(Icons.search_rounded).last);
          await tester.enterText(find.byType(TextField).last, '١٠');
          await tester.pumpAndSettle();
          expect(_shownProjection(tester), [104, 103, 102, 101, 100]);
          await _tapProjection(
            tester,
            find.byIcon(Icons.grid_view_rounded).last,
          );
          expect(episodeViewMode.value, EpisodeViewMode.grid);
          expect(_shownProjection(tester), [104, 103, 102, 101, 100]);
          await tester.enterText(find.byType(TextField).last, 'cAfÉ');
          await tester.pumpAndSettle();
          expect(_shownProjection(tester), [104]);

          final rows = List<Episode>.of(item.episodes!);
          rows[rows.indexOf(first)] = first.copyWith(name: 'Magic ending');
          details.publish(rows);
          await tester.pumpAndSettle();
          expect(_shownProjection(tester), isEmpty);
          await tester.enterText(find.byType(TextField).last, 'ENDING');
          await tester.pumpAndSettle();
          expect(_shownProjection(tester), [104]);
        }

        final unwatchedChip = _projectionKey('episode-filter-unwatched');
        if (!wide && unwatchedChip.evaluate().isEmpty) {
          await tester.scrollUntilVisible(
            unwatchedChip,
            -100,
            scrollable: _projectionScrollView(),
            maxScrolls: 8,
          );
          await tester.pumpAndSettle();
        }
        await _tapProjection(tester, unwatchedChip);
        watch.watched.add(first.url);
        final current = container
            .read(detailsControllerProvider(item.url))
            .seasonMap[1]!;
        details.publish(List<Episode>.of(current));
        container.read(episodeWatchRevisionProvider.notifier).bump();
        await tester.pumpAndSettle();
        expect(_shownProjection(tester), wide ? isEmpty : [103, 102, 101, 100]);

        await _tapProjection(
          tester,
          _projectionKey('episode-filter-downloaded'),
        );
        expect(_shownProjection(tester), isEmpty);
        DownloadItem row(TaskStatus status) => DownloadItem(
          item: item,
          episode: first,
          task: DownloadTask(
            taskId: 'fixture-download',
            url: 'https://example.test/video.mp4',
            filename: 'fixture.mp4',
            metaData: first.url,
          ),
          status: status,
          progress: 1,
          timestamp: 0,
        );
        downloads.publish([row(TaskStatus.running)]);
        await tester.pumpAndSettle();
        expect(_shownProjection(tester), isEmpty);
        downloads.publish([row(TaskStatus.complete)]);
        await tester.pumpAndSettle();
        expect(_shownProjection(tester), [104]);

        if (wide) {
          await tester.enterText(find.byType(TextField).last, '');
          await tester.pumpAndSettle();
        }
        await _tapProjection(tester, _projectionKey('episode-filter-all'));
        final l10n = AppLocalizations.of(
          tester.element(find.byType(DetailsScreen)),
        )!;
        await _tapProjection(tester, find.text(l10n.dub).first);
        expect(_shownProjection(tester), [100, 80, 60, 40, 20, 0]);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'Arabic desktop Details reuses the selected episode range during search',
    (tester) async {
      tester.view.physicalSize = const Size(1360, 1050);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      addTearDown(resetEpisodeBrowse);
      addTearDown(() => episodeViewMode.value = EpisodeViewMode.list);
      addTearDown(() => episodeSearchQuery.value = '');

      final probe = _EpisodeUrlReads();
      final item = MultimediaItem(
        title: 'السلسلة الطويلة',
        url: 'https://example.test/long-episode-range',
        posterUrl: '',
        contentType: MultimediaContentType.anime,
        episodes: [
          for (var i = 1; i <= 1200; i++)
            if (i >= 301 && i <= 700)
              _CountedRangeEpisode(
                name: 'الأحداث $i',
                url: 'https://example.test/long/$i',
                season: 1,
                episode: i,
                dubStatus: DubStatus.subbed,
                probe: probe,
              )
            else
              Episode(
                name: 'الأحداث $i',
                url: 'https://example.test/long/$i',
                season: 1,
                episode: i,
                dubStatus: DubStatus.subbed,
              ),
        ],
      );
      final details = _ProjectionDetails(item);
      final watch = _ProjectionWatch();
      final container = ProviderContainer(
        overrides: [
          storageServiceProvider.overrideWithValue(_Storage()),
          detailsControllerProvider(item.url).overrideWith(() => details),
          libraryProvider.overrideWith(_EmptyLibrary.new),
          watchHistoryProvider.overrideWith(_ProjectionHistory.new),
          episodeWatchRepositoryProvider.overrideWithValue(watch),
          logicalDownloadStoreV2Provider.overrideWithValue(
            InMemoryLogicalDownloadStoreV2(),
          ),
          downloadsProvider.overrideWith(_EmptyDownloads.new),
          downloadedFilesProvider.overrideWith(_ProjectionFiles.new),
          episodeSortAscendingProvider.overrideWith(_ProjectionSort.new),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            locale: const Locale('ar'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: ThemeData.dark(),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) => DetailsScreen(item: item),
                    ),
                  ),
                  child: const Text('افتح التفاصيل'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('افتح التفاصيل'));
      await tester.pumpAndSettle();
      await _tapProjection(tester, _projectionKey('details-episodes-toggle'));
      await _tapProjection(tester, _projectionKey('episode-range-menu'));
      // The menu shows up to the visible options; reveal range 8 if needed.
      final range = _projectionKey('episode-range-8');
      await tester.ensureVisible(range);
      await _tapProjection(tester, range);
      expect(find.text('الحلقات 801–900'), findsOneWidget);
      await _tapProjection(tester, find.byIcon(Icons.search_rounded).last);
      final field = find.byType(TextField).last;
      final input = find
          .descendant(of: field, matching: find.byType(EditableText))
          .last;
      expect(tester.widget<EditableText>(input).focusNode.hasFocus, isTrue);

      probe.count = 0;
      final shown = <List<int>>[];
      final work = <int>[];
      for (final query in ['٨٨', '٨٨٨', '٨٧', '٧٧٧', '٨٩١']) {
        final before = probe.count;
        await tester.enterText(field, query);
        await tester.pumpAndSettle();
        shown.add(_shownProjection(tester));
        work.add(probe.count - before);
        expect(tester.widget<EditableText>(input).focusNode.hasFocus, isTrue);
      }
      expect(shown, [
        [for (var i = 880; i <= 889; i++) i],
        [888],
        [for (var i = 870; i <= 879; i++) i],
        <int>[],
        [891],
      ]);
      debugPrint('C22_DETAILS_RANGE outOfRangeUrlReads=$work results=$shown');
      expect(work, List<int>.filled(5, 0));

      await _tapProjection(tester, _projectionKey('episode-filter-unwatched'));
      expect(_shownProjection(tester), [891]);
      watch.watched.add('https://example.test/long/891');
      container.read(episodeWatchRevisionProvider.notifier).bump();
      await tester.pumpAndSettle();
      expect(_shownProjection(tester), isEmpty);
      await _tapProjection(tester, _projectionKey('episode-filter-all'));
      expect(_shownProjection(tester), [891]);
      expect(episodeRangeIndex.value, 8);
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pumpAndSettle();
      expect(find.text('افتح التفاصيل'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'episode selection bar downloads the selected episodes as a batch',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final item = MultimediaItem(
        title: 'Anime',
        url: 'https://example.test/',
        posterUrl: '',
        contentType: MultimediaContentType.anime,
        episodes: <Episode>[
          Episode(name: 'Episode 1', url: 'episode://1', episode: 1),
          Episode(name: 'Episode 2', url: 'episode://2', episode: 2),
        ],
      );
      late _BatchLauncher launcher;
      final container = ProviderContainer(
        overrides: [
          storageServiceProvider.overrideWithValue(_Storage()),
          downloadsProvider.overrideWith(_EmptyDownloads.new),
          logicalDownloadStoreV2Provider.overrideWithValue(
            InMemoryLogicalDownloadStoreV2(),
          ),
          libraryProvider.overrideWith(_EmptyLibrary.new),
          detailsControllerProvider(item.url)
              .overrideWith(() => _ReadyDetailsController(item)),
          downloadLauncherProvider.overrideWith((ref) {
            launcher = _BatchLauncher(ref);
            return launcher;
          }),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            locale: const Locale('ar'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: ThemeData.dark(),
            home: DetailsScreen(item: item),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final controller = container.read(
        detailsControllerProvider(item.url).notifier,
      );
      controller.toggleEpisodeSelection(item.episodes!.last);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('batch-download-episodes')),
        findsOneWidget,
      );
      expect(find.text('تنزيل 1 حلقة'), findsOneWidget);

      expect(
        tester
            .getTopLeft(find.byKey(const ValueKey('batch-download-episodes')))
            .dy,
        lessThan(tester.getTopLeft(find.text('تمت مشاهدته')).dy),
      );
      await tester.tap(find.byKey(const ValueKey('batch-download-episodes')));
      await tester.pumpAndSettle();

      expect(launcher.batches, hasLength(1));
      expect(launcher.batches.single.map((episode) => episode.url), [
        'episode://2',
      ]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'episode rail fits comment actions at fractional scale and focus',
    (tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.25;
      addTearDown(tester.view.reset);
      final previousMode = episodeViewMode.value;
      episodeViewMode.value = EpisodeViewMode.rail;
      addTearDown(() => episodeViewMode.value = previousMode);
      final previousQuality = highQualityArtwork.value;
      highQualityArtwork.value = true;
      addTearDown(() => highQualityArtwork.value = previousQuality);
      final episode = Episode(
        name: 'القصة التي بدأت في المدينة الجديدة وما حدث بعدها',
        url: 'anime|rail-episode-1',
        posterUrl: 'https://example.test/rail-episode.jpg',
        episode: 1,
      );
      final item = MultimediaItem(
        title: 'Anime',
        url: 'https://animewitcher.com/watch/rail-layout',
        posterUrl: '',
        provider: animeWitcherNativeProviderId,
        episodes: [episode],
      );
      final container = ProviderContainer(
        overrides: [
          storageServiceProvider.overrideWithValue(_Storage()),
          downloadsProvider.overrideWith(_EmptyDownloads.new),
          logicalDownloadStoreV2Provider.overrideWithValue(
            InMemoryLogicalDownloadStoreV2(),
          ),
          detailsControllerProvider(item.url)
              .overrideWith(() => _ReadyDetailsController(item)),
        ],
      );
      addTearDown(container.dispose);

      for (final scale in [1.0, 1.5, 2.0]) {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              locale: const Locale('ar'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              theme: ThemeData.dark(),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: Scaffold(
                body: SingleChildScrollView(
                  child: DetailsDesktopEpisodeColumn(
                    parentItem: item,
                    itemUrl: item.url,
                    isMovie: false,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byIcon(Icons.chat_bubble_outline_rounded), findsOneWidget);
        expect(tester.takeException(), isNull, reason: 'text scale $scale');
        final thumbnail = find.descendant(
          of: find.byType(EpisodeCard),
          matching: find.byType(CachedNetworkImage),
        );
        expect(thumbnail, findsOneWidget);
        final paintedWidth = tester.getSize(thumbnail).width;
        final decodeWidth = tester
            .widget<CachedNetworkImage>(thumbnail)
            .memCacheWidth;
        expect(paintedWidth, greaterThan(140));
        expect(
          decodeWidth,
          artworkDisplayDecodeWidth(
            paintedWidth: paintedWidth,
            devicePixelRatio: 1.25,
            highQuality: true,
            sizeHighQualityToDisplay: true,
          ),
        );
        final focus = tester
            .widget<Focus>(
              find.byWidgetPredicate(
                (widget) =>
                    widget is Focus &&
                    widget.focusNode?.debugLabel == 'ep_body',
              ),
            )
            .focusNode!;
        focus.requestFocus();
        await tester.pumpAndSettle();
        expect(
          tester.widget<CachedNetworkImage>(thumbnail).memCacheWidth,
          decodeWidth,
        );
        expect(
          tester.takeException(),
          isNull,
          reason: 'focused at text scale $scale',
        );
        focus.unfocus();
        await tester.pumpAndSettle();
      }
    },
  );

  for (final platform in <TargetPlatform>[
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.linux,
    TargetPlatform.android,
    TargetPlatform.iOS,
  ]) {
    testWidgets('wide anime poster is restored only on Windows ($platform)', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final item = MultimediaItem(
        title: 'Anime',
        url: 'https://example.test/windows-poster',
        posterUrl: '',
        contentType: MultimediaContentType.anime,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            storageServiceProvider.overrideWithValue(_Storage()),
            logicalDownloadStoreV2Provider.overrideWithValue(
              InMemoryLogicalDownloadStoreV2(),
            ),
            libraryProvider.overrideWith(_EmptyLibrary.new),
            detailsControllerProvider(item.url)
                .overrideWith(() => _ReadyDetailsController(item)),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: ThemeData.dark(),
            home: DetailsScreen(item: item),
          ),
        ),
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('details-hero-poster')),
        platform == TargetPlatform.windows ? findsOneWidget : findsNothing,
      );
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant(<TargetPlatform>{platform}));
  }

  testWidgets('episode selection circle is centered on the thumbnail', (
    tester,
  ) async {
    final episode = Episode(name: 'Episode 1', url: 'episode://1', episode: 1);
    final item = MultimediaItem(
      title: 'Anime',
      url: 'anime://selection',
      posterUrl: '',
      episodes: [episode],
    );
    final container = ProviderContainer(
      overrides: [
        storageServiceProvider.overrideWithValue(_Storage()),
        downloadsProvider.overrideWith(_EmptyDownloads.new),
        logicalDownloadStoreV2Provider.overrideWithValue(
          InMemoryLogicalDownloadStoreV2(),
        ),
        detailsControllerProvider(item.url)
            .overrideWith(() => _ReadyDetailsController(item)),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: EpisodeCard(episode: episode, parentItem: item),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    container
        .read(detailsControllerProvider(item.url).notifier)
        .toggleEpisodeSelection(episode);
    await tester.pumpAndSettle();
    expect(
      tester.getCenter(find.byIcon(Icons.check_circle_rounded)).dy,
      closeTo(tester.getCenter(find.byType(AspectRatio).first).dy, 1),
    );
  });

  testWidgets('episode comments use the anime outline and retain their target', (
    tester,
  ) async {
    final episode = Episode(
      name: 'Episode 1',
      url: 'anime|episode-1',
      episode: 1,
    );
    final item = MultimediaItem(
      title: 'Anime',
      url: 'https://animewitcher.com/watch/anime',
      posterUrl: '',
      provider: animeWitcherNativeProviderId,
      episodes: [episode],
    );
    final observer = _RouteObserver();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storageServiceProvider.overrideWithValue(_Storage()),
          downloadsProvider.overrideWith(_EmptyDownloads.new),
          logicalDownloadStoreV2Provider.overrideWithValue(
            InMemoryLogicalDownloadStoreV2(),
          ),
          detailsControllerProvider(item.url)
              .overrideWith(() => _ReadyDetailsController(item)),
        ],
        child: MaterialApp(
          navigatorObservers: [observer],
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: EpisodeCard(episode: episode, parentItem: item),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final comments = find.byWidgetPredicate(
      (widget) =>
          widget is EpisodeActionChip && widget.tooltip == 'تعليقات الحلقة',
    );
    expect(
      tester.widget<EpisodeActionChip>(comments).icon,
      Icons.chat_bubble_outline_rounded,
    );
    expect(find.byIcon(Icons.forum_outlined), findsNothing);
    expect(find.byIcon(Icons.save_alt_rounded), findsOneWidget);

    await tester.tap(comments);
    final route = observer.pushed! as MaterialPageRoute<void>;
    final screen =
        route.builder(tester.element(comments)) as AnimeWitcherCommentsScreen;
    expect(
      screen.target.collectionPath,
      'anime_list/anime/episodes/episode-1/comments',
    );
    expect(screen.target.isReviews, isFalse);
    // Inspect the pushed destination without starting its network-backed load.
    route.navigator!.removeRoute(route);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  for (final desktop in <bool>[false, true]) {
    testWidgets(
      '${desktop ? 'desktop' : 'phone'} selection preserves the episode-to-information gap',
      (tester) async {
        await tester.binding.setSurfaceSize(Size(desktop ? 1100 : 390, 1800));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final item = MultimediaItem(
          title: 'Anime',
          url: 'https://example.test/selection-spacing',
          posterUrl: '',
          contentType: MultimediaContentType.anime,
          duration: 23,
          episodes: <Episode>[
            for (var i = 1; i <= 4; i++)
              Episode(name: 'Episode $i', url: 'episode://$i', episode: i),
          ],
        );
        final container = ProviderContainer(
          overrides: [
            storageServiceProvider.overrideWithValue(_Storage()),
            downloadsProvider.overrideWith(_EmptyDownloads.new),
            logicalDownloadStoreV2Provider.overrideWithValue(
              InMemoryLogicalDownloadStoreV2(),
            ),
            detailsControllerProvider(item.url)
                .overrideWith(() => _ReadyDetailsController(item)),
          ],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              locale: const Locale('ar'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              theme: ThemeData.dark(),
              home: Consumer(
                builder: (context, ref, _) {
                  final selected = ref.watch(
                    detailsControllerProvider(
                      item.url,
                    ).select((state) => state.selectedEpisodeKeys.isNotEmpty),
                  );
                  return Scaffold(
                    bottomNavigationBar: selected
                        ? const SizedBox(height: 112)
                        : null,
                    body: CustomScrollView(
                      slivers: <Widget>[
                        if (desktop)
                          SliverToBoxAdapter(
                            child: DetailsDesktopEpisodeColumn(
                              parentItem: item,
                              itemUrl: item.url,
                              isMovie: false,
                            ),
                          )
                        else
                          SliverDetailsEpisodeList(
                            parentItem: item,
                            itemUrl: item.url,
                            isMovie: false,
                          ),
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.only(top: 32),
                            child: AnimeInformationSection(item: item),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        void expectNormalGap() {
          expect(find.byType(EpisodeCard), findsNWidgets(4));
          final episodeBottom = tester.getBottomLeft(
            find.byType(EpisodeCard).last,
          );
          final informationTop = tester.getTopLeft(
            find.byType(AnimeInformationSection),
          );
          expect(informationTop.dy - episodeBottom.dy, closeTo(32, 0.01));
          expect(tester.takeException(), isNull);
        }

        expectNormalGap();
        final controller = container.read(
          detailsControllerProvider(item.url).notifier,
        );
        controller.toggleEpisodeSelection(item.episodes!.first);
        await tester.pumpAndSettle();
        expectNormalGap();
        controller.selectAllEpisodes();
        await tester.pumpAndSettle();
        expectNormalGap();
        controller.clearEpisodeSelection();
        await tester.pumpAndSettle();
        expectNormalGap();
      },
    );
  }

  testWidgets('movie play control lives inside the expanded episodes section', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(590, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final movie = MultimediaItem(
      title: 'Movie',
      url: 'https://example.test/movie',
      posterUrl: '',
      contentType: MultimediaContentType.movie,
      episodes: <Episode>[
        Episode(name: 'Movie', url: 'episode://movie', episode: 1),
      ],
    );
    final observer = _RouteObserver();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storageServiceProvider.overrideWithValue(_Storage()),
          logicalDownloadStoreV2Provider.overrideWithValue(
            InMemoryLogicalDownloadStoreV2(),
          ),
          libraryProvider.overrideWith(_EmptyLibrary.new),
          detailsControllerProvider(movie.url)
              .overrideWith(() => _ReadyDetailsController(movie)),
        ],
        child: MaterialApp(
          navigatorObservers: [observer],
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData.dark(),
          home: DetailsScreen(item: movie),
        ),
      ),
    );
    await tester.pump();

    final heroButtons = tester.widgetList<DetailsHeroIconButton>(
      find.byType(DetailsHeroIconButton),
    );
    expect(
      heroButtons.any(
        (button) => button.icon == Icons.chat_bubble_outline_rounded,
      ),
      isTrue,
    );
    expect(
      heroButtons.any((button) => button.icon == Icons.rate_review_outlined),
      isFalse,
    );

    expect(find.byType(DetailsHeroPlayPill), findsNothing);

    await tester.tap(
      find.byWidgetPredicate(
        (widget) =>
            widget is DetailsHeroIconButton &&
            widget.icon == Icons.chat_bubble_outline_rounded,
      ),
    );
    final route = observer.pushed! as MaterialPageRoute<void>;
    final comments = route.builder(
      tester.element(find.byType(DetailsScreen)),
    ) as AnimeWitcherCommentsScreen;
    expect(comments.target.collectionPath, 'anime_list/movie/comments');
    route.navigator!.removeRoute(route);
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('details-episodes-toggle')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));

    expect(
      find.byKey(const ValueKey<String>('details-episodes-reveal')),
      findsOneWidget,
    );
    final fade = tester.widget<FadeTransition>(
      find.byKey(const ValueKey<String>('details-episodes-reveal')),
    );
    expect(fade.opacity.value, greaterThan(0));
    expect(fade.opacity.value, lessThan(1));

    await tester.pumpAndSettle();
    expect(find.byType(DetailsHeroPlayPill), findsOneWidget);
  });

  testWidgets('episode controls consume the same reveal animation as rows', (
    tester,
  ) async {
    final movie = MultimediaItem(
      title: 'Movie',
      url: 'https://example.test/movie-controls',
      posterUrl: '',
      contentType: MultimediaContentType.movie,
      episodes: <Episode>[
        Episode(name: 'Movie', url: 'episode://movie-controls', episode: 1),
      ],
    );
    const reveal = AlwaysStoppedAnimation<double>(0.4);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storageServiceProvider.overrideWithValue(_Storage()),
          logicalDownloadStoreV2Provider.overrideWithValue(
            InMemoryLogicalDownloadStoreV2(),
          ),
          detailsControllerProvider(movie.url)
              .overrideWith(() => _ReadyDetailsController(movie)),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData.dark(),
          home: Scaffold(
            body: CustomScrollView(
              slivers: <Widget>[
                SliverDetailsEpisodeList(
                  parentItem: movie,
                  itemUrl: movie.url,
                  isMovie: false,
                  transition: reveal,
                  transitionOffset: const Offset(0, -0.045),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final controlsReveal = find.byKey(
      const ValueKey<String>('details-episode-controls-reveal'),
    );
    expect(controlsReveal, findsOneWidget);
    expect(tester.widget<FadeTransition>(controlsReveal).opacity.value, 0.4);
    expect(
      find.descendant(
        of: controlsReveal,
        matching: find.byKey(const ValueKey<String>('episode-filter-all')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: controlsReveal,
        matching: find.byType(DetailsHeroPlayPill),
      ),
      findsOneWidget,
    );
  });
}
