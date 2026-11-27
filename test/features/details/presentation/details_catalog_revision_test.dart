import 'dart:async';

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
import 'package:animewitcher/features/details/presentation/widgets/details_desktop_hero.dart';
import 'package:animewitcher/features/details/presentation/widgets/details_extra_tabs.dart';
import 'package:animewitcher/features/library/presentation/downloads_provider.dart';
import 'package:animewitcher/features/library/presentation/history_provider.dart';
import 'package:animewitcher/features/library/presentation/library_media_kind.dart';
import 'package:animewitcher/features/library/presentation/library_provider.dart';
import 'package:animewitcher/features/library/presentation/library_state.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:dio/dio.dart';
// Keep the same Material compatibility API as DetailsScreen.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
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
  MultimediaItem item,
) async {
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

void main() {
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
