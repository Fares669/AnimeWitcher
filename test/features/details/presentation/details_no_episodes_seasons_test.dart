import 'dart:async';

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_service.dart';
import 'package:animewitcher/core/account/animewitcher_comment_models.dart';
import 'package:animewitcher/core/account/firestore_rest_client.dart';
import 'package:animewitcher/core/extensions/item_provider_resolution.dart';
import 'package:animewitcher/core/extensions/providers/animewitcher_native_provider.dart';
import 'package:animewitcher/core/extensions/providers/witanime_provider.dart';
import 'package:animewitcher/core/services/anilist_franchise_service.dart';
import 'package:animewitcher/core/storage/library_category.dart';
import 'package:animewitcher/core/storage/secure_token_storage.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/core/storage/settings_repository.dart';
import 'package:animewitcher/features/details/presentation/details_controller.dart';
import 'package:animewitcher/features/details/presentation/details_screen.dart';
import 'package:animewitcher/features/details/presentation/widgets/details_comments_preview.dart';
import 'package:animewitcher/features/details/presentation/widgets/details_hero_actions.dart';
import 'package:animewitcher/features/details/presentation/widgets/details_seasons_bar.dart';
import 'package:animewitcher/features/library/presentation/library_media_kind.dart';
import 'package:animewitcher/features/library/presentation/library_provider.dart';
import 'package:animewitcher/features/library/presentation/library_state.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/memory_storage_service.dart';

final class _Storage extends MemoryStorageService {
  @override
  String? getString(String key) => settings[key] as String?;

  @override
  int getPosition(String url) => 0;
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

  @override
  Future<void> setFavorite(
    MultimediaItem item,
    bool favorite, {
    LibraryMembership? membership,
  }) async {}
}

final class _MembershipAccount extends AnimeWitcherAccountService {
  _MembershipAccount(_Storage storage)
    : super(storage: storage, secureStorage: SecureTokenStorage(storage));

  LibraryMembership membership = (
    category: LibraryCategory.continueLater,
    favorite: true,
  );
  int reads = 0;

  @override
  bool get isSignedIn => true;

  @override
  String get accountUid => 'test-account';

  @override
  Future<LibraryMembership?> fetchAnimeLibraryMembership(String url) async {
    reads++;
    return membership;
  }

  @override
  Future<int?> loadAnimeUserRating(String animeId) async => null;
}

final class _NoEpisodeDetailsController extends DetailsController {
  _NoEpisodeDetailsController(this.item);

  final MultimediaItem item;

  @override
  DetailsState build(String itemUrl) => DetailsState(
    details: AsyncData<MultimediaItem?>(item),
    episodes: const AsyncData<List<Episode>>(<Episode>[]),
    cast: const AsyncData<List<Actor>>(<Actor>[]),
    trailers: const AsyncData<List<Trailer>>(<Trailer>[]),
    related: AsyncData<List<MultimediaItem>>(
      item.related ?? const <MultimediaItem>[],
    ),
    recommendations: const AsyncData<List<MultimediaItem>>(<MultimediaItem>[]),
    item: item,
    basicDetailsResolved: true,
    nextAiringResolved: true,
  );

  @override
  Future<void> loadDetails(
    MultimediaItem item, {
    bool autoPlay = false,
  }) async {}
}

final class _FranchiseProbe extends AniListFranchiseService {
  _FranchiseProbe(this.nodes) : super(Dio());

  final Map<int, AniListFranchiseNode> nodes;
  final requests = <int>[];

  @override
  Future<AniListFranchiseNode?> fetchByMalId(int malId) async {
    requests.add(malId);
    return nodes[malId];
  }
}

final class _CatalogueProbe extends AnimeWitcherNativeProvider {
  _CatalogueProbe(_Storage storage, this.results)
    : super(Dio(), SettingsRepository(storage));

  final Map<int, MultimediaItem> results;
  final requests = <Set<int>>[];

  @override
  Future<Map<int, MultimediaItem>> resolveCatalogAnimeByMalIds(
    Iterable<int> rawIds,
  ) async {
    final ids = rawIds.toSet();
    requests.add(ids);
    return {
      for (final id in ids)
        if (results.containsKey(id)) id: results[id]!,
    };
  }
}

final class _ReviewsAccount extends AnimeWitcherAccountService {
  _ReviewsAccount(_Storage storage)
    : super(storage: storage, secureStorage: SecureTokenStorage(storage));

  final loads = <FirestoreDocument?>[];
  final requests = <Completer<AnimeWitcherCommentPage>>[];

  @override
  Future<AnimeWitcherCommentPage> loadComments(
    AnimeWitcherCommentTarget target, {
    AnimeWitcherCommentSort sort = AnimeWitcherCommentSort.newest,
    FirestoreDocument? cursor,
    int limit = 20,
  }) {
    expect(target.isReviews, isTrue);
    expect(target.animeId, 'anime');
    expect(sort, AnimeWitcherCommentSort.newest);
    expect(limit, kDetailsCommentsPageSize);
    loads.add(cursor);
    final request = Completer<AnimeWitcherCommentPage>();
    requests.add(request);
    return request.future;
  }
}

MultimediaItem _franchiseFixture(
  int id, {
  String? relation,
  String? provider,
}) => MultimediaItem(
  title: 'Probe Title $id',
  url: provider == null
      ? 'anilist-mal:$id'
      : 'https://example.test/watch/probe-$id',
  posterUrl: '',
  relationType: relation,
  provider: provider,
  catalogType: 'مسلسل',
  syncData: {'malId': '$id'},
);

void main() {
  testWidgets('RTL details appends reviews without rebuilding previous rows', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(590, 650));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final storage = _Storage();
    final account = _ReviewsAccount(storage);
    final item = MultimediaItem(
      title: 'أنمي',
      url: 'https://animewitcher.com/watch/anime',
      posterUrl: '',
      contentType: MultimediaContentType.anime,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storageServiceProvider.overrideWithValue(storage),
          animeWitcherAccountServiceProvider.overrideWithValue(account),
          libraryProvider.overrideWith(_EmptyLibrary.new),
          detailsControllerProvider(item.url)
              .overrideWith(() => _NoEpisodeDetailsController(item)),
        ],
        child: MaterialApp(
          locale: const Locale('ar'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => DetailsScreen(item: item),
                  ),
                ),
                child: const Text('فتح'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('فتح'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final footer = find.byKey(kDetailsCommentsPreviewKey);
    final view = tester.element(footer);
    expect(Directionality.of(view), TextDirection.rtl);
    final position = Scrollable.of(view).position;
    if (account.loads.isEmpty) {
      position.jumpTo(position.maxScrollExtent);
      await tester.pump();
    }

    final oldBuildCallback = debugOnRebuildDirtyWidget;
    var rebuilds = 0;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      oldBuildCallback?.call(element, builtOnce);
      if (element.widget.runtimeType.toString() == '_CommentRow') rebuilds++;
    };
    addTearDown(() => debugOnRebuildDirtyWidget = oldBuildCallback);

    final counts = <int>[];
    final spoiler = find.descendant(
      of: footer,
      matching: find.text('يحتوي على حرق — افتح للقراءة'),
    );
    const pages = 4;
    const pageSize = kDetailsCommentsPageSize;
    FirestoreDocument? cursor;
    for (var page = 0; page < pages; page++) {
      rebuilds = 0;
      if (page > 0) {
        position.jumpTo(0);
        position.jumpTo(position.maxScrollExtent);
        await tester.pump();
      }
      expect(account.loads, hasLength(page + 1));
      expect(account.loads.last, same(cursor));
      final offset = page * pageSize;
      final contents = List.generate(pageSize, (index) {
        final number = offset + index;
        return AnimeWitcherComment(
          id: '$number',
          path: 'anime_list/anime/reviews/$number',
          text: 'مراجعة رقم $number',
          userId: 'user-$number',
          userName: 'كاتب $number',
          likes: page,
          replies: index.isEven ? 1 : 0,
          spoiler: index == 1,
        );
      });
      cursor = FirestoreDocument(
        id: contents.last.id,
        path: contents.last.path,
        fields: const {},
      );
      account.requests.last.complete(
        AnimeWitcherCommentPage(
          items: contents,
          cursor: cursor,
          hasMore: page + 1 < pages,
        ),
      );
      await tester.pump();
      await tester.pump();
      counts.add(rebuilds);

      expect(spoiler, findsNWidgets(page + 1));
      expect(find.text('مراجعة رقم ${offset + 1}'), findsNothing);
      expect(find.text('مراجعة رقم ${offset + 2}'), findsOneWidget);
    }

    final authors = tester.widgetList<Text>(
      find.descendant(
        of: footer,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Text && (widget.data?.startsWith('كاتب ') ?? false),
        ),
      ),
    );
    expect(
      authors.map((text) => text.data),
      List.generate(pages * pageSize, (index) => 'كاتب $index'),
    );
    position.jumpTo(0);
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(account.loads, hasLength(pages));
    expect(counts, [6, 6, 6, 6], reason: 'Review row builds per page');
  });

  for (final scenario in ['external', 'standalone', 'sequel']) {
    testWidgets(
      'details season requests only for displayable work ($scenario)',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(590, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final storage = _Storage();
        storage.settings[SeasonsBarStyleNotifier.storageKey] =
            SeasonsBarStyle.pills.name;
        const rootId = 101;
        const nextId = 102;
        final sequel = _franchiseFixture(nextId, relation: 'SEQUEL');
        final franchise = _FranchiseProbe({
          rootId: AniListFranchiseNode(
            item: _franchiseFixture(rootId),
            related: scenario == 'standalone' ? [] : [sequel],
          ),
          nextId: AniListFranchiseNode(item: sequel, related: []),
        });
        final native = _CatalogueProbe(storage, {
          nextId: _franchiseFixture(nextId, provider: 'probe'),
        });
        final available = scenario == 'external'
            ? WitanimeProvider((_, {cancelToken}) async => '')
            : native;
        final item = _franchiseFixture(rootId, provider: 'probe');
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              storageServiceProvider.overrideWithValue(storage),
              libraryProvider.overrideWith(_EmptyLibrary.new),
              detailsControllerProvider(item.url)
                  .overrideWith(() => _NoEpisodeDetailsController(item)),
              itemSourceProvider(item.provider).overrideWithValue(available),
              aniListFranchiseServiceProvider.overrideWithValue(franchise),
            ],
            child: MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              theme: ThemeData.dark(),
              home: DetailsScreen(item: item),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byType(DetailsSeasonsBar), findsOneWidget);
        expect(
          find.byKey(const ValueKey('details-episodes-toggle')),
          findsOneWidget,
        );
        expect(
          find.text('الموسم 2'),
          scenario == 'sequel' ? findsOneWidget : findsNothing,
        );
        debugPrint(
          'Details $scenario: franchise=${franchise.requests}, '
          'catalogue=${native.requests}',
        );
        expect(franchise.requests, switch (scenario) {
          'external' => <int>[],
          'standalone' => [rootId],
          _ => [rootId, nextId],
        });
        expect(
          native.requests,
          scenario == 'sequel'
              ? [
                  <int>{nextId},
                ]
              : isEmpty,
        );
      },
    );
  }

  testWidgets(
    'details reload server membership on reopen and update the heart immediately',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(590, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final storage = _Storage();
      final account = _MembershipAccount(storage);
      final item = MultimediaItem(
        title: 'Anime',
        url: 'https://animewitcher.com/watch/anime',
        posterUrl: '',
        contentType: MultimediaContentType.anime,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            storageServiceProvider.overrideWithValue(storage),
            animeWitcherAccountServiceProvider.overrideWithValue(account),
            libraryProvider.overrideWith(_EmptyLibrary.new),
            detailsControllerProvider(item.url)
                .overrideWith(() => _NoEpisodeDetailsController(item)),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: ThemeData.dark(),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => DetailsScreen(item: item),
                    ),
                  ),
                  child: const Text('Open anime'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open anime'));
      await tester.pumpAndSettle();
      expect(find.text('أكملها لاحقًا'), findsOneWidget);
      expect(find.byIcon(Icons.favorite_rounded), findsOneWidget);
      await tester.tap(find.byIcon(Icons.favorite_rounded));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.favorite_border_rounded), findsOneWidget);

      Navigator.of(tester.element(find.byType(DetailsScreen))).pop();
      await tester.pumpAndSettle();
      account.membership = (
        category: LibraryCategory.completed,
        favorite: true,
      );
      await tester.tap(find.text('Open anime'));
      await tester.pumpAndSettle();
      expect(account.reads, 2);
      expect(find.text('تمت مشاهدته'), findsOneWidget);
      expect(find.byIcon(Icons.favorite_rounded), findsOneWidget);
    },
  );

  testWidgets('seasons stay visible when an anime has no episodes yet', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(590, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final firstSeason = MultimediaItem(
      title: 'Example Season 1',
      url: 'https://animewitcher.test/watch/example-s1',
      posterUrl: '',
      contentType: MultimediaContentType.anime,
      catalogType: 'مسلسل',
      relationType: 'PREQUEL',
      year: 2024,
    );
    final upcomingSeason = MultimediaItem(
      title: 'Example Season 2',
      url: 'https://animewitcher.test/watch/example-s2',
      posterUrl: '',
      contentType: MultimediaContentType.anime,
      catalogType: 'مسلسل',
      year: 2027,
      description: 'Upcoming season',
      related: <MultimediaItem>[firstSeason],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storageServiceProvider.overrideWithValue(_Storage()),
          libraryProvider.overrideWith(_EmptyLibrary.new),
          detailsControllerProvider(upcomingSeason.url)
              .overrideWith(() => _NoEpisodeDetailsController(upcomingSeason)),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData.dark(),
          home: DetailsScreen(item: upcomingSeason),
        ),
      ),
    );

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(DetailsSeasonsBar), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('details-episodes-toggle')),
      findsOneWidget,
    );
    expect(
      find.byType(DetailsHeroPlayPill),
      findsNothing,
      reason: 'series playback stays inside the collapsed episodes section',
    );
  });
}
