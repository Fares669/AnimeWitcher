import 'dart:collection';
import 'dart:convert';

import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/extensions/providers/animewitcher_native_provider.dart';
import 'package:animewitcher/core/storage/settings_repository.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/home/presentation/home_provider.dart';
import 'package:animewitcher/features/home/presentation/home_state.dart';
import 'package:animewitcher/features/home/presentation/widgets/news_card.dart';
import 'package:animewitcher/features/news/presentation/news_list_screen.dart';
import 'package:animewitcher/features/news/presentation/open_news.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:animewitcher/shared/widgets/app_back_button.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _opener = ValueKey('actual-native-news');
const _seconds = 1700000000;

class _NoHomeSeed extends HomeData {
  @override
  HomeState build() => HomeSuccess(const {});
}

class _MapCopies {
  int maps = 0;
  int entries = 0;
}

// Count actual Map.map calls and entry conversions performed by production
// code. Both arms use the same otherwise ordinary read-only fixture maps.
class _CountedMap<K> extends MapBase<K, dynamic> {
  _CountedMap(this.delegate, this.copies);

  final Map<K, dynamic> delegate;
  final _MapCopies copies;

  @override
  Iterable<K> get keys => delegate.keys;

  @override
  dynamic operator [](Object? key) => delegate[key];

  @override
  Map<RK, RV> map<RK, RV>(MapEntry<RK, RV> Function(K, dynamic) convert) {
    copies.maps++;
    return delegate.map((key, value) {
      copies.entries++;
      return convert(key, value);
    });
  }

  @override
  void operator []=(K key, dynamic value) =>
      throw UnsupportedError('read only');

  @override
  dynamic remove(Object? key) => throw UnsupportedError('read only');

  @override
  void clear() => throw UnsupportedError('read only');
}

Map<String, dynamic> _constantSettings() => {
  'fields': {
    'search_settings': {
      'mapValue': {
        'fields': {
          'app_id_v3': {'stringValue': 'MOCKAPP'},
          'api_key': {'stringValue': 'mock-search'},
          'browse_api_key': {'stringValue': 'mock-browse'},
          'is_search_active': {'booleanValue': true},
        },
      },
    },
  },
};

class _Feed {
  final copies = _MapCopies();
  final legacyCopies = _MapCopies();
  final requests = <String>[];
  int feeds = 0;

  List<dynamic> _hits(int revision) => [
    for (var i = 0; i < 998; i++)
      _CountedMap<String>({
        'objectID': i == 997 ? 'item-0' : 'item-$i',
        'title': i == 0 ? '<b>خبر &amp; أول $revision</b>' : 'الخبر رقم $i',
        'thumb_link': '',
        'news_link': 'https://fixture.invalid/news/$i',
        'anime_id': 'مرتبط-$i',
        'date_created': _CountedMap<String>(
          i == 0
              ? {
                  'value': _CountedMap<String>({'seconds': _seconds}, copies),
                }
              : {'_seconds': _seconds - i},
          copies,
        ),
      }, copies),
    _CountedMap<Object?>({
      'docId': 'legacy-map',
      'name': 'خبر قديم',
      'newsLink': 'https://fixture.invalid/legacy',
      'date': '$_seconds',
    }, legacyCopies),
    jsonEncode({
      'id': 'legacy-string',
      'title_ar': 'خبر نصي',
      'date_created': jsonEncode({'timestamp': _seconds}),
    }),
  ];

  Dio dio() => Dio()
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          final path = request.uri.path;
          requests.add(path);
          dynamic data;
          if (path.endsWith('/Settings/constants')) {
            data = _constantSettings();
          } else if (path.endsWith('/indexes/news/query')) {
            expect(request.method, 'POST');
            expect(request.headers['X-Algolia-API-Key'], 'mock-browse');
            final body = request.data as Map;
            final params = Uri.splitQueryString(body['params'] as String);
            expect(params['page'], '0');
            expect(params['hitsPerPage'], '1000');
            data = <String, dynamic>{'hits': _hits(++feeds), 'nbPages': 1};
          } else {
            fail('Unexpected mocked request: $path');
          }
          handler.resolve(
            Response<dynamic>(
              requestOptions: request,
              statusCode: 200,
              data: data,
            ),
          );
        },
      ),
    );
}

void main() {
  testWidgets(
    'Arabic native News projects the complete feed without map copies',
    (tester) async {
      const stock = bool.fromEnvironment('AW_C19_NEWS_STOCK');
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final fixture = _Feed();
      final dio = fixture.dio();
      addTearDown(() => dio.close(force: true));
      final provider = AnimeWitcherNativeProvider(
        dio,
        SettingsRepository(StorageService()),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            activeProviderProvider.overrideWithValue(provider),
            homeDataProvider.overrideWith(_NoHomeSeed.new),
          ],
          child: MaterialApp(
            locale: const Locale('ar'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Consumer(
              builder: (context, ref, _) => Scaffold(
                body: TextButton(
                  key: _opener,
                  onPressed: () => openNewsScreen(context, ref),
                  child: const Text('الأخبار'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(_opener));
      await tester.pumpAndSettle();

      void expectFeed(int revision) {
        expect(find.byType(NewsListScreen), findsOneWidget);
        final first = find.widgetWithText(NewsCard, 'خبر & أول $revision');
        final second = find.widgetWithText(NewsCard, 'الخبر رقم 1');
        final card = tester.widget<NewsCard>(first);
        expect(Directionality.of(tester.element(first)), TextDirection.rtl);
        expect(
          tester.getRect(second).top,
          greaterThan(tester.getRect(first).top),
        );
        expect(card.item.id, 'item-0'); // first of the duplicate IDs wins
        expect(card.item.docRef, 'news/item-0');
        expect(card.item.newsUrl, 'https://fixture.invalid/news/0');
        expect(card.item.animeId, 'مرتبط-0');
        expect(
          card.item.publishedAt,
          DateTime.fromMillisecondsSinceEpoch(
            _seconds * 1000,
            isUtc: true,
          ).toLocal(),
        );
        expect(card.onOpen, isNotNull);
        expect(card.onAnimeTap, isNotNull);
        final list = tester.widget<ListView>(find.byType(ListView));
        expect(list.childrenDelegate.estimatedChildCount, 2 * 999 - 1);
      }

      expectFeed(1);
      expect(fixture.feeds, 1);
      expect(fixture.copies.maps, stock ? 1997 : 0);
      expect(fixture.copies.entries, stock ? 6987 : 0);
      expect((fixture.legacyCopies.maps, fixture.legacyCopies.entries), (1, 4));
      print(
        'C19 Arabic News cold route: ${fixture.feeds} full feed, '
        '${fixture.copies.maps} typed map copies, '
        '${fixture.copies.entries} typed entry conversions',
      );

      await tester.dragFrom(const Offset(195, 170), const Offset(0, 350));
      await tester.pumpAndSettle();
      expectFeed(2);
      expect(find.text('خبر & أول 1'), findsNothing);
      expect(fixture.feeds, 2);
      expect(
        fixture.requests.where((p) => p.endsWith('/indexes/news/query')),
        hasLength(2),
      );
      expect(fixture.copies.maps, stock ? 3994 : 0);
      expect(fixture.copies.entries, stock ? 13974 : 0);
      expect((fixture.legacyCopies.maps, fixture.legacyCopies.entries), (2, 8));

      // Read the tail's final builder slots from the same production list
      // delegate instead of scrolling and constructing a thousand unrelated rows.
      final listFinder = find.byType(ListView);
      final delegate =
          tester.widget<ListView>(listFinder).childrenDelegate
              as SliverChildBuilderDelegate;
      for (final (itemIndex, title) in [(997, 'خبر قديم'), (998, 'خبر نصي')]) {
        final built = delegate.builder(
          tester.element(listFinder),
          itemIndex * 2,
        ) as NewsCard;
        expect(built.item.title, title);
        expect(built.item.publishedAt?.millisecondsSinceEpoch, _seconds * 1000);
      }

      await tester.tap(find.byType(AppBackButton).hitTestable());
      await tester.pumpAndSettle();
      expect(find.byType(NewsListScreen), findsNothing);
      expect(find.byKey(_opener), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
