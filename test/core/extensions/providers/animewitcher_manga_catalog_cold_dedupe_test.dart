import 'dart:async';

import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/providers/animewitcher_native_provider.dart';
import 'package:animewitcher/core/storage/settings_repository.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class _Settings extends SettingsRepository {
  _Settings() : super(StorageService());

  @override
  Future<void> saveAnimeWitcherSearchSettings(
    Map<String, dynamic> value,
  ) async {}
}

typedef _Hit = Map<String, dynamic>;

class _Call {
  _Call(this.options);
  final RequestOptions options;
  final response = Completer<Map<String, Object?>>();
  int status = 200;

  Map<String, String> get params => Uri.splitQueryString(
    (options.data as Map<String, dynamic>)['params'] as String,
  );

  void succeed(List<_Hit> hits, {int pages = 1}) =>
      response.complete({'hits': hits, 'nbPages': pages});
  void fail() {
    status = 403;
    response.complete(const {'error': 'synthetic rejected call'});
  }
}

class _CatalogFixture {
  _CatalogFixture() {
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          final Map<String, Object?> data;
          var status = 200;
          if (options.uri.path.endsWith('/indexes/manga_views_desc/query')) {
            final call = _Call(options);
            final index = calls.length;
            calls.add(call);
            _arrivals.remove(index)?.complete(call);
            data = await call.response.future;
            status = call.status;
          } else {
            expect(options.uri.path, endsWith('/Settings/constants'));
            data = {
              'fields': {
                'search_settings': {
                  'mapValue': {
                    'fields': {
                      'app_id': {'stringValue': appId},
                      'api_key': {'stringValue': key},
                    },
                  },
                },
              },
            };
          }
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: status,
              data: data,
            ),
          );
        },
      ),
    );
  }

  final dio = Dio();
  late final provider = AnimeWitcherNativeProvider(dio, _Settings());
  final calls = <_Call>[];
  final _arrivals = <int, Completer<_Call>>{};
  String appId = 'SYNTHAPP1';
  String key = 'SYNTHKEY1';

  Future<_Call> call(int i) => i < calls.length
      ? Future.value(calls[i])
      : _arrivals
            .putIfAbsent(i, Completer<_Call>.new)
            .future
            .timeout(const Duration(seconds: 4));
}

_Hit _hit(String title) => {'objectID': title, 'name': title};
const _ascending = ProviderSearchFilters(sort: 'name_asc');
const _descending = ProviderSearchFilters(sort: 'name_desc');

void main() {
  late _CatalogFixture f;
  setUp(() {
    f = _CatalogFixture();
    addTearDown(() => f.dio.close(force: true));
  });

  test('overlapping cold views share every page of one raw catalog', () async {
    final asc = f.provider.searchMangaPage('same', _ascending, limit: 10);
    final first = await f.call(0);
    final desc = f.provider.searchMangaPage(' same ', _descending, limit: 20);
    expect(first.params, containsPair('hitsPerPage', '1000'));
    expect(first.params, containsPair('page', '0'));
    first.succeed([
      for (var i = 0; i < 1000; i++)
        _hit('Book ${i.toString().padLeft(4, '0')}'),
    ], pages: 2);
    final second = await f.call(1);
    expect(second.params, containsPair('page', '1'));
    second.succeed([_hit('Zeta')], pages: 2);

    final pages = await Future.wait([asc, desc]);
    expect(pages[0].items.first.title, 'Book 0000');
    expect(pages[1].items.first.title, 'Zeta');
    expect(pages.map((page) => page.nextOffset), [10, 20]);
    expect(pages.every((page) => page.hasMore), isTrue);
    expect(f.calls, hasLength(2));
  });

  test(
    'different raw query or caller-owned token starts a separate request',
    () async {
      final one = f.provider.searchMangaPage('Alpha', _ascending);
      final a = await f.call(0);
      final two = f.provider.searchMangaPage('alpha', _ascending);
      final b = await f.call(1);
      final token = CancelToken();
      final three = f.provider.searchMangaPage(
        'Alpha',
        _ascending,
        cancelToken: token,
      );
      final c = await f.call(2);
      expect(a.params['query'], 'Alpha');
      expect(b.params['query'], 'alpha');
      expect(c.params['query'], 'Alpha');
      expect(identical(c.options.cancelToken, token), isTrue);
      expect(a.options.cancelToken, isNull);

      final cancelled = expectLater(three, throwsA(isA<DioException>()));
      token.cancel('test only');
      a.succeed([_hit('Capital')]);
      b.succeed([_hit('Lowercase')]);
      c.succeed([_hit('Token')]);
      expect((await one).items.single.title, 'Capital');
      expect((await two).items.single.title, 'Lowercase');
      await cancelled;
    },
  );

  test('account generation cannot join or cache an older completion', () async {
    final before = f.provider.searchMangaPage('same', _ascending);
    final old = await f.call(0);
    f.provider.invalidateMangaCatalog();
    final after = f.provider.searchMangaPage('same', _ascending);
    final fresh = await f.call(1);
    fresh.succeed([_hit('Current')]);
    expect((await after).items.single.title, 'Current');
    old.succeed([_hit('Stale')]);
    expect((await before).items.single.title, 'Stale');

    final warm = await f.provider.searchMangaPage('same', _ascending);
    expect(warm.items.single.title, 'Current');
    expect(f.calls, hasLength(2));
  });

  test(
    'retry never joins pending work from the old search configuration',
    () async {
      final before = f.provider.searchMangaPage('same', _ascending);
      final old = await f.call(0);
      expect(old.options.headers['X-Algolia-Application-Id'], 'SYNTHAPP1');
      f.appId = 'SYNTHAPP2';
      f.key = 'SYNTHKEY2';
      f.provider.prepareForNetworkRetry();
      final after = f.provider.searchMangaPage('same', _ascending);
      final fresh = await f.call(1);
      expect(fresh.options.headers['X-Algolia-Application-Id'], 'SYNTHAPP2');
      fresh.succeed([_hit('Current')]);
      expect((await after).items.single.title, 'Current');
      old.succeed([_hit('Stale')]);
      expect((await before).items.single.title, 'Stale');

      final warm = await f.provider.searchMangaPage('same', _ascending);
      expect(warm.items.single.title, 'Current');
      expect(f.calls, hasLength(2));
    },
  );

  test(
    'an overlapping failure rejects both callers and does not stick',
    () async {
      final first = f.provider.searchMangaPage('same', _ascending);
      final old = await f.call(0);
      final second = f.provider.searchMangaPage('same', _descending);
      final failures = Future.wait([
        expectLater(first, throwsStateError),
        expectLater(second, throwsStateError),
      ]);
      await Future<void>.delayed(Duration.zero);
      old.fail();
      await failures;
      expect(f.calls, hasLength(1));

      final retry = f.provider.searchMangaPage('same', _ascending);
      final fresh = await f.call(1);
      fresh.succeed([_hit('Recovered')]);
      expect((await retry).items.single.title, 'Recovered');
    },
  );
}
