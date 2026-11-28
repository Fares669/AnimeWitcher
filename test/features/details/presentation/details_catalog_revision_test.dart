import 'dart:async';
import 'dart:ui' as ui;

import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_service.dart';
import 'package:animewitcher/core/account/animewitcher_character_models.dart';
import 'package:animewitcher/core/account/animewitcher_comment_models.dart';
import 'package:animewitcher/core/account/firestore_rest_client.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/extensions/providers/animewitcher_native_provider.dart';
import 'package:animewitcher/core/network/dio_client_provider.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_provider.dart';
import 'package:animewitcher/core/services/download_v2/logical_download_store_v2.dart';
import 'package:animewitcher/core/storage/library_category.dart';
import 'package:animewitcher/core/storage/secure_token_storage.dart';
import 'package:animewitcher/core/storage/settings_repository.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/details/presentation/details_controller.dart';
import 'package:animewitcher/features/details/presentation/details_screen.dart';
import 'package:animewitcher/features/details/presentation/extra_anime_list_screen.dart';
import 'package:animewitcher/features/details/presentation/widgets/details_desktop_hero.dart';
import 'package:animewitcher/features/details/presentation/widgets/details_extra_tabs.dart';
import 'package:animewitcher/features/details/presentation/widgets/details_poster_grid.dart';
import 'package:animewitcher/features/library/presentation/downloads_provider.dart';
import 'package:animewitcher/features/library/presentation/history_provider.dart';
import 'package:animewitcher/features/library/presentation/library_media_kind.dart';
import 'package:animewitcher/features/library/presentation/library_provider.dart';
import 'package:animewitcher/features/library/presentation/library_state.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
// Keep the same Material compatibility API as DetailsScreen.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/memory_storage_service.dart';

const _url = 'https://animewitcher.com/watch/source-anime';
const _sourceTitle = 'مغامرة الاختبار';
const _open = 'Open measured Details';

final class _Storage extends MemoryStorageService {
  @override
  List<Map<String, dynamic>> getWatchHistory() => const [];
  @override
  int getPosition(String url) => 0;
  @override
  Future<Map<String, Map<String, dynamic>>> getAllDownloadMetadata() async =>
      const {};
}

final class _EmptyDownloads extends DownloadsNotifier {
  @override
  Future<List<DownloadItem>> build() async => const [];
}

final class _EmptyHistory extends WatchHistory {
  @override
  List<HistoryItem> build() => const [];
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

final class _GuestAccount extends AnimeWitcherAccountService {
  _GuestAccount(_Storage storage)
    : super(storage: storage, secureStorage: SecureTokenStorage(storage));

  @override
  Future<AnimeWitcherCommentPage> loadComments(
    AnimeWitcherCommentTarget target, {
    AnimeWitcherCommentSort sort = AnimeWitcherCommentSort.newest,
    FirestoreDocument? cursor,
    int limit = 20,
  }) async => const AnimeWitcherCommentPage(
    items: <AnimeWitcherComment>[],
    cursor: null,
    hasMore: false,
  );
}

final class _Manager extends ExtensionManager {
  _Manager(this._source);
  final AnimeWitcherProvider _source;

  @override
  List<AnimeWitcherProvider> build() => [_source];
}

final class _Native extends AnimeWitcherNativeProvider {
  _Native(Dio dio, _Storage storage, _Catalog catalog)
    : super(
        dio,
        SettingsRepository(storage),
        algoliaSearchApiKey: 'local-details-fixture',
        isEcchiHidden: () => catalog.hide,
        resolveAnimeByMalIds: catalog.relatedHits,
      );

  int relatedCalls = 0;

  @override
  Future<RelatedAnimePage> getRelatedPage(
    String url, {
    bool includeAll = false,
  }) {
    relatedCalls++;
    return super.getRelatedPage(url, includeAll: includeAll);
  }
}

Map<String, dynamic> _hit(
  String id,
  String title, {
  int? malId,
  bool hidden = false,
}) => {
  'objectID': id,
  'anime_id': id,
  'name': title,
  'tags': hidden ? ['ecchi'] : ['دراما'],
  'mal_id': ?malId,
};

final class _Catalog {
  bool hide = false;
  int similarPosts = 0;
  int basicReads = 0;
  int relatedBatches = 0;
  Completer<void>? holdNextSimilar;

  Future<List<Map<String, dynamic>>> relatedHits(Iterable<int> ids) async {
    relatedBatches++;
    return [
      if (ids.contains(11)) _hit('related-ok', 'Related safe', malId: 11),
      if (ids.contains(12))
        _hit('related-filtered', 'Related tagged', malId: 12, hidden: true),
    ];
  }

  Dio createDio() => Dio()
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          final path = options.uri.path;
          Map<String, dynamic> data = {};
          if (path.endsWith('/indexes/series/source-anime') ||
              path.endsWith('/documents/anime_list/source-anime')) {
            basicReads++;
            final raw = <String, dynamic>{
              'objectID': 'source-anime',
              'anime_id': 'source-anime',
              'name': _sourceTitle,
              'tags': ['دراما'],
              'related_anime_ids': [11, 12],
            };
            data = path.endsWith('/indexes/series/source-anime')
                ? raw
                : {
                    'fields': {
                      'name': {'stringValue': _sourceTitle},
                      'tags': {
                        'arrayValue': {
                          'values': [
                            {'stringValue': 'دراما'},
                          ],
                        },
                      },
                      'related_anime_ids': {
                        'arrayValue': {
                          'values': [
                            {'integerValue': '11'},
                            {'integerValue': '12'},
                          ],
                        },
                      },
                    },
                  };
          } else if (path.endsWith('/indexes/series_similar/query')) {
            similarPosts++;
            final hold = holdNextSimilar;
            holdNextSimilar = null;
            if (hold != null) await hold.future;
            data = {
              'hits': [
                _hit('similar-ok', 'Similar safe'),
                _hit('similar-filtered', 'Similar tagged', hidden: true),
              ],
              'nbPages': 1,
            };
          }

          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: data,
            ),
          );
        },
      ),
    );
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pumpAndSettle(
    const Duration(milliseconds: 40),
    EnginePhase.sendSemanticsUpdate,
    const Duration(seconds: 4),
  );
}

Future<void> _completeWithinFrames(
  WidgetTester tester,
  Future<void> operation,
) async {
  var finished = false;
  final tracked = operation.then((_) => finished = true);
  for (var i = 0; i < 30 && !finished; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(finished, isTrue, reason: 'mocked refresh must complete');
  await tracked;
}

Future<void> _openDetails(
  WidgetTester tester,
  ProviderContainer container,
  MultimediaItem item, {
  Key? witness,
}) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: witness == null
            ? ThemeData.dark()
            : ThemeData(brightness: Brightness.dark, fontFamily: _font),
        builder: witness == null
            ? null
            : (context, child) => RepaintBoundary(key: witness, child: child),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => DetailsScreen(item: item),
                ),
              ),
              child: const Text(_open),
            ),
          ),
        ),
      ),
    ),
  );
  await _settle(tester);
  await tester.tap(find.text(_open));
  await _settle(tester);
  expect(find.text(_sourceTitle), findsWidgets);
}

Future<void> _showExtras(WidgetTester tester) async {
  final target = find.text(animeWitcherSimilarTabLabel);
  expect(find.byType(DetailsExtraTabs), findsOneWidget);
  for (var i = 0; i < 6 && target.hitTestable().evaluate().isEmpty; i++) {
    await tester.drag(find.byType(DetailsDesktopHero), const Offset(0, -280));
    await _settle(tester);
  }
  await tester.ensureVisible(target);
  await _settle(tester);
}

Future<void> _showTab(WidgetTester tester, String label) async {
  final tab = find.text(label);
  await tester.ensureVisible(tab);
  await tester.tap(tab);
  await _settle(tester);
}

const _font = 'C24DetailsReadex';
const _shot = ValueKey('c24-details-extra-projection');
const _projectedWorkTest =
    'Arabic Details projects Related and Similar without repeat identities';

final class _IdentityReads {
  int count = 0;
}

final class _CountedAnime extends MultimediaItem {
  _CountedAnime(int index, String tab, this.probe)
    : super(
        title: 'عمل $tab $index',
        url: 'https://example.test/$tab/$index',
        posterUrl: '',
        contentType: MultimediaContentType.anime,
      );

  final _IdentityReads probe;

  @override
  String get url {
    probe.count++;
    return super.url;
  }
}

final class _ExtraProjectionDetails extends DetailsController {
  _ExtraProjectionDetails(this.item, this.related, this.similar);

  final MultimediaItem item;
  final List<MultimediaItem> related;
  final List<MultimediaItem> similar;

  @override
  DetailsState build(String itemUrl) => DetailsState(
    details: AsyncData(item),
    item: item,
    episodes: const AsyncData(<Episode>[]),
    cast: const AsyncData(<Actor>[]),
    trailers: const AsyncData(<Trailer>[]),
    related: AsyncData(related),
    recommendations: AsyncData(similar),
    relatedHasMore: true,
    similarHasMore: true,
    basicDetailsResolved: true,
    nextAiringResolved: true,
  );

  @override
  Future<void> loadDetails(
    MultimediaItem item, {
    bool autoPlay = false,
  }) async {}

  @override
  Future<void> loadRelatedIfNeeded() async {}

  @override
  Future<void> loadRecommendationsIfNeeded() async {}

  void publishTrailerMetadata(int revision) {
    // Details watches continuing trailer metadata independently of the already
    // resolved Related/Similar snapshots.
    state = state.copyWith(
      trailers: AsyncData([Trailer(url: 'https://fixture.invalid/$revision')]),
    );
  }

  void publishRelated(List<MultimediaItem> replacement) {
    state = state.copyWith(related: AsyncData(replacement));
  }
}

MultimediaItem _extraItem(String title, String url) => MultimediaItem(
  title: title,
  url: url,
  posterUrl: '',
  year: 2024,
  provider: 'animewitcher',
  contentType: MultimediaContentType.anime,
);

Future<String> _extraRaster(
  WidgetTester tester,
) async => (await tester.runAsync(() async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_shot),
  );
  final image = await boundary.toImage();
  try {
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    return sha256
        .convert(
          bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        )
        .toString();
  } finally {
    image.dispose();
  }
}))!;

void main() {
  testWidgets(_projectedWorkTest, (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      final font = FontLoader(_font)
        ..addFont(
          rootBundle.load('assets/fonts/readex_pro/ReadexPro-Regular.ttf'),
        )
        ..addFont(
          rootBundle.load('assets/fonts/readex_pro/ReadexPro-Bold.ttf'),
        );
      await font.load();
    });
    final storage = _Storage();
    final catalog = _Catalog();
    final dio = catalog.createDio();
    final provider = _Native(dio, storage, catalog);
    final item = MultimediaItem(
      title: _sourceTitle,
      url: _url,
      posterUrl: '',
      provider: provider.packageName,
      contentType: MultimediaContentType.anime,
    );
    final relatedProbe = _IdentityReads();
    final similarProbe = _IdentityReads();
    final original = _extraItem(
      'العمل السابق',
      'https://fixture.invalid/shared',
    );
    final legacy = _extraItem(' Legacy Title ', '');
    final related = [
      original,
      _extraItem('نسخة لا تظهر', ' https://fixture.invalid/shared '),
      legacy,
      _extraItem('legacy title', ''),
      for (var i = 0; i < 3; i++)
        _extraItem('صلة $i', 'https://fixture.invalid/related/$i'),
      for (var i = 0; i < 72; i++) _CountedAnime(i, 'related', relatedProbe),
    ];
    final similar = [
      _extraItem('المتداخل لا يظهر', 'https://fixture.invalid/shared'),
      _extraItem('  LEGACY TITLE', ''),
      for (var i = 0; i < 5; i++)
        _extraItem('شبيه $i', 'https://fixture.invalid/similar/$i'),
      _extraItem('شبيه مكرر', ' https://fixture.invalid/similar/0 '),
      for (var i = 0; i < 96; i++) _CountedAnime(i, 'similar', similarProbe),
    ];
    final detail = _ExtraProjectionDetails(item, related, similar);
    final container = ProviderContainer(
      overrides: [
        storageServiceProvider.overrideWithValue(storage),
        dioClientProvider.overrideWithValue(dio),
        animeWitcherAccountServiceProvider.overrideWithValue(
          _GuestAccount(storage),
        ),
        extensionManagerProvider.overrideWith(() => _Manager(provider)),
        activeProviderProvider.overrideWithValue(provider),
        downloadsProvider.overrideWith(_EmptyDownloads.new),
        watchHistoryProvider.overrideWith(_EmptyHistory.new),
        libraryProvider.overrideWith(_EmptyLibrary.new),
        logicalDownloadStoreV2Provider.overrideWithValue(
          InMemoryLogicalDownloadStoreV2(),
        ),
        detailsControllerProvider(_url).overrideWith(() => detail),
      ],
    );
    addTearDown(() {
      container.dispose();
      dio.close(force: true);
    });

    final extras = find.byType(DetailsExtraTabs);
    DetailsExtraTabs projected() => tester.widget<DetailsExtraTabs>(extras);
    DetailsPosterGrid grid(String name) => tester.widget<DetailsPosterGrid>(
      find.byWidgetPredicate(
        (widget) => widget is DetailsPosterGrid && widget.keyPrefix == name,
      ),
    );
    await _openDetails(tester, container, item, witness: _shot);
    await _showExtras(tester);
    expect(
      Directionality.of(tester.element(find.text(animeWitcherSimilarTabLabel))),
      TextDirection.rtl,
    );
    expect(grid('similar').items, orderedEquals(similar.sublist(2, 7)));
    expect(projected().similar.requireValue.length, 101);
    expect(projected().related.requireValue.length, 77);
    final similarFrame = await _extraRaster(tester);
    await _showTab(tester, animeWitcherRelatedTabLabel);
    expect(
      grid('related').items,
      orderedEquals([original, legacy, ...related.sublist(4, 7)]),
    );
    // Track the actual selected Material tab's Focus (rather than forcing
    // primary focus into the poster grid's nested handset viewport).
    final relatedTab = find.text(animeWitcherRelatedTabLabel);
    expect(relatedTab.hitTestable(), findsOneWidget);
    final tabContext = tester.element(relatedTab);
    final focus = Focus.of(tabContext);
    expect(focus, isNot(same(FocusScope.of(tabContext))));
    expect(focus.canRequestFocus, isTrue);
    focus.requestFocus();
    FocusManager.instance.applyFocusChangesIfNeeded();
    await _settle(tester);
    expect(FocusManager.instance.primaryFocus, same(focus));
    final before = await _extraRaster(tester);

    relatedProbe.count = 0;
    similarProbe.count = 0;
    const updates = 6;
    for (var i = 0; i < updates; i++) {
      final previous = projected();
      detail.publishTrailerMetadata(i);
      await _settle(tester);
      expect(projected(), isNot(same(previous)));
      expect(Focus.of(tester.element(relatedTab)), same(focus));
      expect(FocusManager.instance.primaryFocus, same(focus));
      expect(grid('related').items.first, same(original));
      expect(projected().similar.requireValue.length, 101);
    }
    // Trailer data resolves during these publications, so the full frame can
    // legitimately change between checkpoints. Compare each checkpoint with
    // the same checkpoint on the other production build, not a stale frame.
    final after = await _extraRaster(tester);
    debugPrint(
      'C24_DETAILS_EXTRA related=${relatedProbe.count} '
      'similar=${similarProbe.count} frames=$similarFrame,$before,$after',
    );
    expect(relatedProbe.count, updates * 72);
    expect(similarProbe.count, updates * 96);

    // A Related replacement must still immediately affect Similar exclusion.
    detail.publishRelated([original, ...related.sublist(4)]);
    await _settle(tester);
    await _showTab(tester, animeWitcherSimilarTabLabel);
    expect(grid('similar').items.first, same(similar[1]));
    expect(projected().similar.requireValue.length, 102);

    // Use the rendered Related More affordance and return to the same tab.
    await _showTab(tester, animeWitcherRelatedTabLabel);
    final more = find.byKey(const ValueKey('related-more'));
    await tester.ensureVisible(more);
    await _settle(tester);
    expect(more.hitTestable(), findsOneWidget);
    await tester.tap(more);
    await _settle(tester);
    expect(find.byType(RelatedAnimeScreen), findsOneWidget);
    expect(find.text('Related safe'), findsWidgets);
    await tester.binding.handlePopRoute();
    await _settle(tester);
    expect(find.byType(RelatedAnimeScreen), findsNothing);
    expect(find.byKey(const ValueKey('related-grid')), findsOneWidget);
    expect(grid('related').items.first, same(original));
    await tester.binding.handlePopRoute();
    await _settle(tester);
    expect(find.text(_open), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Details catalog ignores unrelated account revisions', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final storage = _Storage();
    final catalog = _Catalog();
    final dio = catalog.createDio();
    final provider = _Native(dio, storage, catalog);
    final container = ProviderContainer(
      overrides: [
        storageServiceProvider.overrideWithValue(storage),
        dioClientProvider.overrideWithValue(dio),
        animeWitcherAccountServiceProvider.overrideWithValue(
          _GuestAccount(storage),
        ),
        extensionManagerProvider.overrideWith(() => _Manager(provider)),
        activeProviderProvider.overrideWithValue(provider),
        downloadsProvider.overrideWith(_EmptyDownloads.new),
        watchHistoryProvider.overrideWith(_EmptyHistory.new),
        libraryProvider.overrideWith(_EmptyLibrary.new),
        logicalDownloadStoreV2Provider.overrideWithValue(
          InMemoryLogicalDownloadStoreV2(),
        ),
      ],
    );
    addTearDown(() {
      container.dispose();
      dio.close(force: true);
    });
    final item = MultimediaItem(
      title: 'Initial fallback title',
      url: _url,
      posterUrl: '',
      provider: provider.packageName,
      contentType: MultimediaContentType.anime,
    );

    await _openDetails(tester, container, item);
    expect(provider.relatedCalls, 0);
    await _showExtras(tester);
    expect(catalog.similarPosts, 1);
    expect(find.text('Similar tagged'), findsWidgets);
    await _showTab(tester, animeWitcherRelatedTabLabel);
    expect(provider.relatedCalls, 1);
    expect(find.text('Related tagged'), findsWidgets);
    expect(catalog.relatedBatches, 1);
    final basicReads = catalog.basicReads;

    final revision = container.read(accountDataRevisionProvider.notifier);
    for (var i = 0; i < 8; i++) {
      revision.bump();
      await _settle(tester);
    }
    expect(catalog.similarPosts, 1);
    expect(provider.relatedCalls, 1);
    expect(catalog.relatedBatches, 1);
    expect(catalog.basicReads, basicReads);
    expect(find.text('Related safe'), findsWidgets);
    expect(find.text('Related tagged'), findsWidgets);

    catalog.hide = true;
    revision.bump();
    await _settle(tester);
    expect(catalog.similarPosts, 2);
    expect(provider.relatedCalls, 2);
    expect(find.text('Related tagged'), findsNothing);
    expect(find.text('Related safe'), findsWidgets);
    await _showTab(tester, animeWitcherSimilarTabLabel);
    expect(find.text('Similar tagged'), findsNothing);
    expect(find.text('Similar safe'), findsWidgets);

    // The same visible page still makes a real request on pull to refresh.
    final hero = tester.widget<DetailsDesktopHero>(
      find.byType(DetailsDesktopHero),
    );
    await _completeWithinFrames(tester, hero.onRefresh());
    await _settle(tester);
    expect(catalog.similarPosts, 3);
    expect(provider.relatedCalls, 3);
    expect(catalog.basicReads, greaterThan(basicReads));
    expect(find.text('Similar safe'), findsWidgets);

    // Simulates sign-out resetting the effective native setting to false.
    // Hold a request initiated while hidden, then release it after the new
    // catalogue renders. Its old filtered response must not overwrite it.
    final hold = Completer<void>();
    catalog.holdNextSimilar = hold;
    final controller = container.read(detailsControllerProvider(_url).notifier);
    final older = controller.refreshDetails();
    for (var i = 0; i < 20 && catalog.holdNextSimilar != null; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(catalog.holdNextSimilar, isNull);
    catalog.hide = false;
    revision.bump();
    await _settle(tester);
    expect(find.text('Similar tagged'), findsWidgets);
    hold.complete();
    await _completeWithinFrames(tester, older);
    await _settle(tester);
    expect(find.text('Similar tagged'), findsWidgets);
    await _showTab(tester, animeWitcherRelatedTabLabel);
    expect(find.text('Related tagged'), findsWidgets);

    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await _settle(tester);
    expect(find.text(_open), findsOneWidget);
    final beforeReopen = catalog.similarPosts;
    await tester.tap(find.text(_open));
    await _settle(tester);
    await _showExtras(tester);
    expect(catalog.similarPosts, beforeReopen + 1);
    expect(find.text('Similar tagged'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
