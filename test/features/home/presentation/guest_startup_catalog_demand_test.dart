import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_models.dart';
import 'package:animewitcher/core/account/animewitcher_account_service.dart';
import 'package:animewitcher/core/account/firebase_auth_rest_client.dart';
import 'package:animewitcher/core/account/firestore_rest_client.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/extensions/providers/animewitcher_native_provider.dart';
import 'package:animewitcher/core/navigation/home_tab_reselection.dart';
import 'package:animewitcher/core/network/dio_client_provider.dart';
import 'package:animewitcher/core/providers/device_info_provider.dart';
import 'package:animewitcher/core/storage/secure_token_storage.dart';
import 'package:animewitcher/core/storage/settings_repository.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/home/presentation/home_provider.dart';
import 'package:animewitcher/features/home/presentation/home_screen.dart';
import 'package:animewitcher/features/home/presentation/home_state.dart';
import 'package:animewitcher/features/library/presentation/history_provider.dart';
import 'package:animewitcher/features/search/data/mal_rankings.dart';
import 'package:animewitcher/features/settings/presentation/general_settings_provider.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../../support/memory_storage_service.dart';

class _GuestSecureStorage extends SecureTokenStorage {
  _GuestSecureStorage(super.storage);

  @override
  Future<String?> read(String key) async => null;
}

class _ResumeFixtureRows extends ListBase<Map<String, dynamic>> {
  static const count = 250;
  int rowsRead = 0;

  final _rows = List.generate(
    count,
    (index) => <String, dynamic>{
      'title': 'متابعة تجريبية $index',
      'url': 'https://animewitcher.com/watch/resume-$index',
      'position': 10000,
      'duration': 20000,
      'timestamp': count - index,
    },
  );

  @override
  int get length => _rows.length;

  @override
  set length(int next) => throw UnsupportedError('Read-only fixture');

  @override
  Map<String, dynamic> operator [](int index) {
    rowsRead++;
    return _rows[index];
  }

  @override
  void operator []=(int index, Map<String, dynamic> value) =>
      throw UnsupportedError('Read-only fixture');
}

class _GuestStorage extends MemoryStorageService {
  final resumeRows = _ResumeFixtureRows();

  @override
  List<Map<String, dynamic>> getContinueWatching() => resumeRows;
}

const _railTitles = <String, String>{
  'series': 'الأعمال الجديدة',
  'series_rating': 'الأعلى تقييماً',
  'series_view': 'الأكثر مشاهدة',
};

Map<String, dynamic> _string(String value) => {'stringValue': value};

Map<String, dynamic> _map(Map<String, dynamic> fields) => {
  'mapValue': {'fields': fields},
};

class _CatalogFixture {
  final dio = Dio();
  final queries = <String, int>{};

  _CatalogFixture({
    Duration simulatedLatency = Duration.zero,
    bool withManga = false,
  }) {
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) async {
          final path = request.uri.path;
          final data = switch (path) {
            String() when path.endsWith('/Settings/constants') => {
              'fields': {
                'search_settings': _map({
                  'app_id_v3': _string('GUESTFIXTURE'),
                  'api_key': _string('fixture-key'),
                  'is_search_active': {'booleanValue': true},
                }),
              },
            },
            String() when path.endsWith('/Settings/home_sections') => {
              'fields': {
                'sections': {
                  'arrayValue': {
                    'values': [
                      for (final rail in _railTitles.entries)
                        _map({
                          'title': _string(rail.value),
                          'type': _string('list'),
                          'index_name': _string(rail.key),
                          'hits_per_page': {'integerValue': '10'},
                        }),
                      if (withManga)
                        _map({
                          'title': _string('فصول المانجا'),
                          'type': _string('manga_recent'),
                          'index_name': _string('manga_recent_fixture'),
                          'hits_per_page': {'integerValue': '30'},
                        }),
                    ],
                  },
                },
              },
            },
            String()
                when path.startsWith('/1/indexes/') &&
                    path.endsWith('/query') =>
              _rail(request.uri.pathSegments[2]),
            _ => throw StateError('Unexpected catalogue path: $path'),
          };
          if (path.endsWith('/query') && simulatedLatency != Duration.zero) {
            await Future<void>.delayed(simulatedLatency);
          }
          handler.resolve(
            Response<Object?>(
              requestOptions: request,
              statusCode: 200,
              data: data,
            ),
          );
        },
      ),
    );
  }

  Map<String, dynamic> _rail(String index) {
    queries.update(index, (count) => count + 1, ifAbsent: () => 1);
    return {
      'hits': [
        if (_railTitles.containsKey(index))
          for (var i = 0; i < 10; i++)
            {
              'objectID': '$index-$i',
              'name': 'عنوان تجريبي $i',
              if (i == 9) 'tags': ['Ecchi'],
            },
        if (index == 'manga_recent_fixture')
          for (var i = 0; i <= 20; i++)
            {
              'objectID': 'new-$i',
              'manga_id': 'manga-$i',
              'manga_name': 'Manga $i',
              'type': 'مانجا',
              'chapter_id': '1',
              'chapter_name': 'الفصل 1',
              'date': 1789916400000 - i,
            },
        if (index == 'news') {'objectID': 'guest-news', 'title': 'خبر تجريبي'},
      ],
      'nbPages': 1,
    };
  }
}

Future<void> _frames(WidgetTester tester) async {
  // Home also has animated decorations; measure a fixed elapsed window
  // rather than depending on continuous rendering to become quiescent.
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  testWidgets('a guest cold start only fetches each Home rail once', (
    tester,
  ) async {
    final savedInterval = VisibilityDetectorController.instance.updateInterval;
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
    addTearDown(() {
      VisibilityDetectorController.instance.notifyNow();
      VisibilityDetectorController.instance.updateInterval = savedInterval;
    });
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final storage = _GuestStorage();
    final catalogue = _CatalogFixture();
    final source = AnimeWitcherNativeProvider(
      catalogue.dio,
      SettingsRepository(storage),
    );
    final account = AnimeWitcherAccountService(
      storage: storage,
      secureStorage: _GuestSecureStorage(storage),
    );
    const expected = {
      'series': 1,
      'series_rating': 1,
      'series_view': 1,
      'news': 1,
    };
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storageServiceProvider.overrideWithValue(storage),
          extensionManagerProvider.overrideWithValue([source]),
          activeProviderProvider.overrideWithValue(source),
          animeWitcherAccountServiceProvider.overrideWithValue(account),
          mangaHasOwnTabProvider.overrideWithValue(false),
          homeMalRankingPageProvider.overrideWith(
            (_, _) async => const ProviderMediaPage(
              items: <MultimediaItem>[],
              nextOffset: 0,
              hasMore: false,
            ),
          ),
          deviceProfileProvider.overrideWith(
            (_) async => const DeviceProfile(),
          ),
        ],
        child: Consumer(
          builder: (_, ref, _) {
            // Same account startup wiring as MyApp, without download/platform
            // plugins. Home, the account controller and the catalog are real.
            ref.watch(animeWitcherAccountControllerProvider.notifier);
            return const MaterialApp(
              locale: Locale('ar'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: HomeScreen(),
            );
          },
        ),
      ),
    );
    await _frames(tester);

    final scope = ProviderScope.containerOf(
      tester.element(find.byType(HomeScreen)),
    );
    final home = scope.read(homeDataProvider) as HomeSuccess;
    expect(home.data.keys, containsAll(_railTitles.values));
    expect(home.data.values.map((items) => items.length), everyElement(10));
    expect(home.news.single.title, 'خبر تجريبي');
    expect(find.text('عنوان تجريبي 0').hitTestable(), findsWidgets);
    expect(find.text('متابعة تجريبية 0').hitTestable(), findsWidgets);
    expect(
      {
        'queries': catalogue.queries,
        'resumeRowsRead': storage.resumeRows.rowsRead,
        'accountRevisions': scope.read(accountDataRevisionProvider),
      },
      {
        'queries': expected,
        'resumeRowsRead': _ResumeFixtureRows.count,
        'accountRevisions': 0,
      },
    );
    expect(
      scope.read(animeWitcherAccountControllerProvider).requireValue.isSignedIn,
      isFalse,
    );

    // Home's explicit refresh still goes to the provider and refreshes
    // local rows; the change only suppresses the empty account startup.
    final refresh = tester.widget<RefreshIndicator>(
      find.byType(RefreshIndicator),
    );
    final refreshing = refresh.onRefresh();
    await _frames(tester);
    await refreshing;
    expect(catalogue.queries, expected.map((key, _) => MapEntry(key, 2)));
    expect(storage.resumeRows.rowsRead, _ResumeFixtureRows.count * 2);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final result in _Verification.values) {
    testWidgets('cached signed-in Home: ${result.name}', (tester) async {
      final savedInterval =
          VisibilityDetectorController.instance.updateInterval;
      VisibilityDetectorController.instance.updateInterval = Duration.zero;
      addTearDown(() {
        VisibilityDetectorController.instance.notifyNow();
        VisibilityDetectorController.instance.updateInterval = savedInterval;
      });
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final storage = _SignedInStorage();
      final secure = _CachedSecureStorage(
        storage,
        hideEcchi: result == _Verification.rejected,
      );
      final catalogue = _CatalogFixture(
        simulatedLatency: const Duration(milliseconds: 150),
        withManga: true,
      );
      final auth = _HeldAuth();
      final account = AnimeWitcherAccountService(
        storage: storage,
        secureStorage: secure,
        auth: auth,
        firestore: _AccountCloud(hideEcchi: result == _Verification.newFilter),
      );
      final clock = tester.binding.clock;
      final launched = clock.now();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            storageServiceProvider.overrideWithValue(storage),
            dioClientProvider.overrideWithValue(catalogue.dio),
            witanimeCatalogProvider.overrideWithValue(null),
            anime3rbCatalogProvider.overrideWithValue(null),
            animeWitcherAccountServiceProvider.overrideWithValue(account),
            mangaHasOwnTabProvider.overrideWithValue(false),
            homeMalRankingPageProvider.overrideWith(
              (_, _) async => const ProviderMediaPage(
                items: <MultimediaItem>[],
                nextOffset: 0,
                hasMore: false,
              ),
            ),
            deviceProfileProvider.overrideWith(
              (_) async => const DeviceProfile(),
            ),
          ],
          child: Consumer(
            builder: (_, ref, _) {
              ref.watch(animeWitcherAccountControllerProvider.notifier);
              return const MaterialApp(
                locale: Locale('ar'),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: HomeScreen(),
              );
            },
          ),
        ),
      );

      final scope = ProviderScope.containerOf(
        tester.element(find.byType(HomeScreen)),
      );
      int? firstContentMs;
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 10));
        if (firstContentMs == null &&
            find.text('عنوان تجريبي 0').hitTestable().evaluate().isNotEmpty) {
          firstContentMs = clock.now().difference(launched).inMilliseconds;
        }
      }

      final revisionsBefore = scope.read(accountDataRevisionProvider);
      final queriesBefore = Map.of(catalogue.queries);
      expect(revisionsBefore, 1);
      expect(
        scope
            .read(animeWitcherAccountControllerProvider)
            .requireValue
            .isSignedIn,
        isTrue,
      );
      expect(auth.lookupStarted, isTrue);
      expect(auth.lookupResult.isCompleted, isFalse);
      expect(firstContentMs, isNotNull, reason: 'Auth is still held.');
      final home = scope.read(homeDataProvider) as HomeSuccess;
      expect(home.news.single.title, 'خبر تجريبي');
      expect(home.latestManga, hasLength(20));
      expect(
        home.data[_railTitles['series']]!.length,
        result == _Verification.rejected ? 9 : 10,
      );

      switch (result) {
        case _Verification.unchanged:
        case _Verification.newFilter:
          auth.lookupResult.complete({'emailVerified': true});
        case _Verification.offline:
          auth.lookupResult.completeError(
            StateError('simulated offline lookup'),
          );
        case _Verification.rejected:
          auth.lookupResult.complete({'emailVerified': false});
      }
      await _frames(tester);
      final finalHome = scope.read(homeDataProvider) as HomeSuccess;
      final queriesAfter = Map.of(catalogue.queries);
      expect(scope.read(accountDataRevisionProvider), 2);
      expect(
        scope
            .read(animeWitcherAccountControllerProvider)
            .requireValue
            .isSignedIn,
        result != _Verification.rejected,
      );
      expect(
        finalHome.data[_railTitles['series']]!.length,
        result == _Verification.newFilter ? 9 : 10,
      );
      expect(finalHome.news.single.title, 'خبر تجريبي');
      expect(finalHome.latestManga, hasLength(20));
      if (result == _Verification.unchanged ||
          result == _Verification.newFilter) {
        expect(account.snapshot.lastSyncAt, isNotNull);
        // Real account revision refreshes the independent owner-only shelf.
        expect(
          scope.read(continueWatchingProvider).map((entry) => entry.item.title),
          ['Cloud resume row'],
        );
      }

      // Home's explicit pull-to-refresh still requests the public feed even
      // when the last account revision and catalogue are both recent.
      final refresh = tester.widget<RefreshIndicator>(
        find.byType(RefreshIndicator),
      );
      final refreshing = refresh.onRefresh();
      await _frames(tester);
      await refreshing;

      final changedFilter =
          result == _Verification.newFilter || result == _Verification.rejected;
      final initialBatches = result == _Verification.rejected ? 2 : 1;
      for (final index in [..._railTitles.keys, 'news']) {
        expect(queriesBefore[index], initialBatches);
        expect(queriesAfter[index], initialBatches + (changedFilter ? 1 : 0));
        expect(catalogue.queries[index], queriesAfter[index]! + 1);
      }
      expect(
        firstContentMs,
        lessThanOrEqualTo(initialBatches == 1 ? 310 : 350),
      );

      if (result == _Verification.unchanged) {
        // The selected Home tab still refreshes on a tap; an explicit load
        // is never coalesced with an account revision.
        scope.read(homeTabReselectionProvider.notifier).reselect();
        await _frames(tester);
        expect(catalogue.queries['news'], 3);

        // A changed provider always starts a new catalogue, including types
        // whose account dependencies Home doesn't know.
        final active = scope.read(activeProviderProvider.notifier);
        final native = scope.read(activeProviderProvider);
        final other = _OtherCatalogue();
        await active.set(other);
        await _frames(tester);
        expect(other.homeLoads, 1);
        expect((scope.read(homeDataProvider) as HomeSuccess).data.keys, [
          'Another catalogue',
        ]);
        scope.read(accountDataRevisionProvider.notifier).bump();
        await _frames(tester);
        expect(other.homeLoads, 2);
        await active.set(native);
        await _frames(tester);
        expect(catalogue.queries['news'], 4);
      }

      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}

enum _Verification { unchanged, offline, newFilter, rejected }

class _HeldAuth extends FirebaseAuthRestClient {
  bool lookupStarted = false;
  final lookupResult = Completer<Map<String, dynamic>>();

  @override
  Future<Map<String, dynamic>> lookup(String idToken) {
    lookupStarted = true;
    return lookupResult.future;
  }
}

class _CachedSecureStorage extends SecureTokenStorage {
  _CachedSecureStorage(super.storage, {required bool hideEcchi}) {
    _values['animewitcher_account_session_v1'] = jsonEncode(
      AnimeWitcherSession(
        uid: 'fixture-user',
        idToken: 'fixture-token',
        refreshToken: 'fixture-refresh',
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
        signInMethod: AnimeWitcherSignInMethod.email,
        providerIds: const ['password'],
      ).toJson(),
    );
    _values['animewitcher_account_profile_v1'] = jsonEncode(
      AnimeWitcherProfile(
        documentId: 'fixture-profile',
        uid: 'fixture-user',
        signInMethod: AnimeWitcherSignInMethod.email,
        userName: 'Fixture user',
        providerIds: const ['password'],
        privacySettings: AnimeWitcherPrivacySettings(hideEcchiAnime: hideEcchi),
      ).toJson(),
    );
  }

  final _values = <String, String>{};

  @override
  Future<String?> read(String key) async {
    // Allow the first batch to launch before the cached account is read.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return _values[key];
  }

  @override
  Future<void> write(String key, String value) async => _values[key] = value;

  @override
  Future<void> delete(String key) async => _values.remove(key);
}

class _AccountCloud extends FirestoreRestClient {
  _AccountCloud({required this.hideEcchi});

  final bool hideEcchi;

  @override
  Future<List<FirestoreDocument>> queryByStringField({
    required String collectionId,
    required String field,
    required String value,
    required String idToken,
    int limit = 20,
  }) async => [
    FirestoreDocument(
      id: 'fixture-profile',
      path: 'users/fixture-profile',
      fields: {
        'uid': 'fixture-user',
        'user_name': 'Fixture user',
        'settings': {'hide_ecchi_anime': hideEcchi},
      },
    ),
  ];

  @override
  Future<List<FirestoreDocument>> listDocuments(
    String collectionPath,
    String idToken, {
    int pageSize = 100,
  }) async => [
    if (collectionPath.endsWith('/continue_watching'))
      FirestoreDocument(
        id: 'cloud-resume',
        path: 'users/fixture-profile/continue_watching/cloud-resume',
        fields: {
          'anime_id': 'cloud-resume',
          'animewitcher_item': MultimediaItem(
            title: 'Cloud resume row',
            contentType: MultimediaContentType.anime,
            url: 'https://animewitcher.com/watch/cloud-resume',
            posterUrl: '',
          ).toJson(),
          'position': 10000,
          'duration': 20000,
          'date_updated': DateTime.utc(2026, 1),
        },
      ),
  ];
}

class _SignedInStorage extends MemoryStorageService {
  Map<String, dynamic>? _resume;

  @override
  List<MultimediaItem> getLibraryItems({String? category}) => const [];

  @override
  List<Map<String, dynamic>> getContinueWatching() => [?_resume];

  @override
  Future<void> remove(String key) async {
    settings.remove(key);
  }

  @override
  Future<void> saveContinueWatchingProgress(
    MultimediaItem item,
    int positionMillis,
    int durationMillis, {
    String? lastStreamUrl,
    String? lastEpisodeUrl,
    int? season,
    int? episode,
    String? episodeTitle,
    String? episodeServerName,
    String? episodeServerNumber,
    String? episodePosterUrl,
    int? progressPercent,
    int? timestamp,
    String? syncedAccountUid,
    int? syncedAt,
  }) async {
    _resume = {
      ...item.toJson(),
      'position': positionMillis,
      'duration': durationMillis,
      'lastEpisodeUrl': lastEpisodeUrl,
      'timestamp': timestamp,
      'animeWitcherSyncedUid': syncedAccountUid,
      'animeWitcherSyncedAt': syncedAt,
    };
  }
}

class _OtherCatalogue extends AnimeWitcherProvider {
  int homeLoads = 0;

  @override
  String get packageName => 'fixture.other';

  @override
  String get name => 'Fixture provider';
  @override
  String get mainUrl => 'https://catalogue.invalid';

  @override
  String get version => '1';

  @override
  List<String> get languages => const ['ar'];

  @override
  Set<ProviderType> get supportedTypes => const {ProviderType.anime};

  @override
  Future<Map<String, List<MultimediaItem>>> getHome() async {
    homeLoads++;
    return {
      'Another catalogue': [
        MultimediaItem(
          title: 'Switched provider title',
          contentType: MultimediaContentType.anime,
          url: 'https://catalogue.invalid/watch/fixture',
          posterUrl: '',
        ),
      ],
    };
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
