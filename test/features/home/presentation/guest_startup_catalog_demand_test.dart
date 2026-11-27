import 'dart:collection';

import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_service.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/extensions/providers/animewitcher_native_provider.dart';
import 'package:animewitcher/core/providers/device_info_provider.dart';
import 'package:animewitcher/core/storage/secure_token_storage.dart';
import 'package:animewitcher/core/storage/settings_repository.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/home/presentation/home_provider.dart';
import 'package:animewitcher/features/home/presentation/home_screen.dart';
import 'package:animewitcher/features/home/presentation/home_state.dart';
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

  _CatalogFixture() {
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
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
            {'objectID': '$index-$i', 'name': 'عنوان تجريبي $i'},
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
}
