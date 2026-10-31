import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/account/animewitcher_comment_models.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_provider.dart';
import 'package:animewitcher/core/services/download_v2/logical_download_store_v2.dart';
import 'package:animewitcher/core/storage/library_category.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
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
  bool isFavorite(String url) => false;

  @override
  LibraryCategory? itemCategory(String url) => null;
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

void main() {
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
      final episode = Episode(
        name: 'القصة التي بدأت في المدينة الجديدة وما حدث بعدها',
        url: 'anime|rail-episode-1',
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
