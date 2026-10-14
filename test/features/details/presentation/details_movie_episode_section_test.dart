import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_provider.dart';
import 'package:animewitcher/core/services/download_v2/logical_download_store_v2.dart';
import 'package:animewitcher/core/storage/library_category.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/details/presentation/details_controller.dart';
import 'package:animewitcher/features/details/presentation/details_screen.dart';
import 'package:animewitcher/features/details/presentation/widgets/details_hero_actions.dart';
import 'package:animewitcher/features/details/presentation/widgets/details_layout_widgets.dart';
import 'package:animewitcher/features/library/presentation/library_media_kind.dart';
import 'package:animewitcher/features/library/presentation/library_provider.dart';
import 'package:animewitcher/features/library/presentation/library_state.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
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
  List<Map<String, dynamic>> getWatchHistory() => const <Map<String, dynamic>>[];

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

final class _MovieController extends DetailsController {
  _MovieController(this.item);

  final MultimediaItem item;

  @override
  DetailsState build(String itemUrl) => DetailsState(
    details: AsyncData<MultimediaItem?>(item),
    episodes: AsyncData<List<Episode>>(item.episodes ?? const <Episode>[]),
    cast: const AsyncData<List<Actor>>(<Actor>[]),
    trailers: const AsyncData<List<Trailer>>(<Trailer>[]),
    related: const AsyncData<List<MultimediaItem>>(<MultimediaItem>[]),
    recommendations: const AsyncData<List<MultimediaItem>>(<MultimediaItem>[]),
    seasonMap: <int, List<Episode>>{
      1: item.episodes ?? const <Episode>[],
    },
    item: item,
    isMovie: true,
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

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storageServiceProvider.overrideWithValue(_Storage()),
          logicalDownloadStoreV2Provider.overrideWithValue(
            InMemoryLogicalDownloadStoreV2(),
          ),
          libraryProvider.overrideWith(_EmptyLibrary.new),
          detailsControllerProvider(movie.url).overrideWith(
            () => _MovieController(movie),
          ),
        ],
        child: MaterialApp(
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
          detailsControllerProvider(movie.url).overrideWith(
            () => _MovieController(movie),
          ),
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
    expect(
      tester.widget<FadeTransition>(controlsReveal).opacity.value,
      0.4,
    );
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
