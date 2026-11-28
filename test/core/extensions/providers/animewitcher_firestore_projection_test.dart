import 'dart:collection';
import 'dart:convert';

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/providers/animewitcher_native_provider.dart';
import 'package:animewitcher/core/storage/settings_repository.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

const _season = 'شتاء 2025';
const _id = 'series-z';
const _url = 'https://animewitcher.com/watch/$_id';
const _poster = 'https://fixtures.invalid/poster.webp';
const _large = 'https://fixtures.invalid/large.webp';
const _cover = 'https://fixtures.invalid/cover.webp';

class _TestSettings extends SettingsRepository {
  _TestSettings() : super(StorageService());

  @override
  bool isHighQualityPostersEnabled() => false;

  @override
  Future<void> saveAnimeWitcherSearchSettings(
    Map<String, dynamic> value,
  ) async {}
}

class _CopyMeter {
  var copies = 0;
  var copiedEntries = 0;

  (int, int) get counts => (copies, copiedEntries);

  _WireMap map(Map<String, dynamic> values) => _WireMap(this, values);

  _WireMap fields(Map<String, Object?> values) =>
      map({for (final entry in values.entries) entry.key: value(entry.value)});

  _WireMap value(Object? raw) => map(switch (raw) {
    Map<String, Object?> raw => {
      'mapValue': map({'fields': fields(raw)}),
    },
    List<Object?> raw => {
      'arrayValue': map({'values': raw.map(value).toList()}),
    },
    bool raw => {'booleanValue': raw},
    int raw => {'integerValue': '$raw'},
    double raw => {'doubleValue': raw},
    String raw => {'stringValue': raw},
    null => {'nullValue': null},
    _ => throw StateError('Unsupported Firestore fixture: $raw'),
  });
}

class _WireMap extends MapBase<String, dynamic> {
  _WireMap(this.meter, this.valuesByKey);

  final _CopyMeter meter;
  final Map<String, dynamic> valuesByKey;

  @override
  Iterable<String> get keys => valuesByKey.keys;

  @override
  bool containsKey(Object? key) => valuesByKey.containsKey(key);

  @override
  dynamic operator [](Object? key) => valuesByKey[key];

  @override
  void operator []=(String key, dynamic value) => valuesByKey[key] = value;

  @override
  void clear() => valuesByKey.clear();

  @override
  dynamic remove(Object? key) => valuesByKey.remove(key);

  // Counts real provider calls that materialize copies of transport maps.
  @override
  Map<K, V> map<K, V>(MapEntry<K, V> Function(String, dynamic) convert) {
    meter.copies++;
    meter.copiedEntries += valuesByKey.length;
    return valuesByKey.map(convert);
  }
}

class _LegacyDocumentKey {
  @override
  String toString() => 'document';
}

_WireMap _document(
  _CopyMeter meter,
  String id,
  String title, {
  List<String> tags = const ['أكشن', 'غامض', 'أكشن'],
}) {
  final fields = meter.fields({
    'name': title,
    'story': '<b>القصة</b> &amp; التفاصيل',
    'poster_uri': _poster,
    'poster': {'large': _large, 'medium': _poster},
    'cover_uri': _cover,
    'type': 'TV',
    'dubbed': true,
    'mal_id': 89,
    'aniList_id': 213,
    'imdb_id': 'tt9876',
    'rating': {'rate': 7.5, 'count': 23},
    'statictes': {'fav_count': 102},
    'tags': tags,
    'details': {
      'year': 2025,
      'season': _season,
      'english_title': 'English fixture',
      'mal_mean': 8.25,
      'duration': '٢٤ دقيقة',
      'age': 'PG-13',
      'studio': ['ألف', 'باء'],
      'start_date': '2025-01-03',
    },
  });
  // A legacy transport may provide an encoded wrapper. The compatibility
  // path should still parse it even while surrounding typed maps are read.
  fields['details']['mapValue']['fields']['state'] = jsonEncode({
    'stringValue': 'مكتمل',
  });
  return meter.map({
    'name': 'projects/offline/databases/(default)/documents/anime_list/$id',
    'fields': fields,
  });
}

void main() {
  test('Firestore season pages and details read typed wire maps without cloning', () async {
    final seasonMeter = _CopyMeter();
    final detailMeter = _CopyMeter();
    final settings = _CopyMeter().fields({
      'search_settings': {'is_search_active': false},
      'seasons': {'past': 'خريف 2024', 'current': _season, 'next': 'ربيع 2025'},
    });
    final detail = _document(detailMeter, _id, 'العنوان الكامل');
    final firstRow = _document(seasonMeter, _id, 'العنوان الأول');
    final rows = [
      seasonMeter.map({'document': firstRow}),
      seasonMeter.map({
        'document': _document(
          seasonMeter,
          'filtered',
          'يُخفى',
          tags: const ['أكشن / إيتشي'],
        ),
      }),
      seasonMeter.map({
        'document': _document(seasonMeter, 'filtered', 'مكرر بلا إيتشي'),
      }),
      seasonMeter.map({'document': _document(seasonMeter, _id, 'عنوان مكرر')}),
      // Untyped key normalization still works on a real page row.
      <Object?, Object?>{
        _LegacyDocumentKey(): _document(seasonMeter, 'legacy', 'قديم'),
      },
      ...List.generate(
        20,
        (i) => seasonMeter.map({
          'document': _document(seasonMeter, 'extra-$i', 'إضافي $i'),
        }),
      ),
      seasonMeter.map({'readTime': '2025-01-01T00:00:00Z'}),
    ];
    var hideEcchi = true;
    final calls = <String>[];
    final queries = <(String, Map<String, dynamic>)>[];
    final dio = Dio();
    addTearDown(dio.close);
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          final Object body;
          if (request.uri.path.endsWith('/Settings/constants')) {
            calls.add('constants');
            body = {'fields': settings};
          } else if (request.uri.path.endsWith('documents:runQuery')) {
            calls.add('page');
            queries.add((
              request.method,
              (request.data as Map<String, dynamic>)['structuredQuery']
                  as Map<String, dynamic>,
            ));
            body = rows;
          } else if (request.uri.path.endsWith('/anime_list/$_id')) {
            calls.add('details');
            body = detail;
          } else {
            fail('Unexpected offline request: ${request.uri}');
          }
          handler.resolve(
            Response<dynamic>(
              requestOptions: request,
              statusCode: 200,
              data: body,
            ),
          );
        },
      ),
    );
    final provider = AnimeWitcherNativeProvider(
      dio,
      _TestSettings(),
      algoliaSearchApiKey: '',
      isEcchiHidden: () => hideEcchi,
    );

    expect((await provider.getSeasonConfig()).current, _season);
    final page = await provider.getSeasonPage(' $_season ', offset: 5);
    expect(page.hasMore, isTrue);
    expect(page.nextOffset, 29);
    expect(page.items.map((item) => item.title), [
      'العنوان الأول',
      'قديم',
      for (var i = 0; i < 20; i++) 'إضافي $i',
    ]);
    final card = page.items.first;
    expect(card.url, _url);
    expect(card.posterUrl, _poster);
    expect(card.fullPosterUrl, _large);
    expect(card.bannerUrl, _cover);
    expect(card.tags, ['أكشن', 'غامض']);
    expect(card.year, 2025);
    expect(card.status, ShowStatus.completed);
    expect(card.syncData?['malId'], '89');

    // Replayed transport objects can change. Do not memoize their decoding
    // or mutate them, and do not leak later changes into previous pages.
    expect(firstRow.containsKey('anime_id'), isFalse);
    expect(firstRow['fields'].containsKey('anime_id'), isFalse);
    firstRow['fields']['name']['stringValue'] = 'تحديث العنوان';
    hideEcchi = false;
    final reopened = await provider.getSeasonPage(_season, offset: 5);
    expect(reopened.items.length, 23);
    expect(reopened.items.take(3).map((item) => item.title), [
      'تحديث العنوان',
      'يُخفى',
      'قديم',
    ]);
    expect(card.title, 'العنوان الأول');

    final item = await provider.getDetails(_url);
    expect(item.title, 'العنوان الكامل');
    expect(item.description, 'القصة & التفاصيل');
    expect(item.tags, ['أكشن', 'غامض']);
    expect(item.score, 8.25);
    expect(item.duration, 24);
    expect(item.year, 2025);
    expect(item.status, ShowStatus.completed);
    expect(item.imdbId, 'tt9876');
    expect(item.posterUrl, _poster);
    expect(item.fullPosterUrl, _large);
    expect(item.bannerUrl, _cover);
    expect(item.isDubbed, isTrue);
    expect(item.syncData, containsPair('awStudio', 'ألف, باء'));
    expect(item.syncData, containsPair('awSeason', _season));
    expect(item.syncData, containsPair('awScoreCount', '23'));
    expect(item.syncData, containsPair('awFavorites', '102'));

    detail['fields']['name']['stringValue'] = 'نسخة أحدث';
    detail['fields']['details']['mapValue']['fields']['studio']['arrayValue']['values'][0]['stringValue'] =
        'جيم';
    final cached = await provider.getDetails(_url);
    expect(cached.title, 'العنوان الكامل');
    expect(cached.syncData?['awStudio'], 'ألف, باء');
    provider.invalidateDetailCaches(_url);
    final refreshed = await provider.getDetails(_url);
    expect(refreshed.title, 'نسخة أحدث');
    expect(refreshed.syncData?['awStudio'], 'جيم, باء');
    expect(item.syncData?['awStudio'], 'ألف, باء');
    expect(calls, ['constants', 'page', 'page', 'details', 'details']);

    expect(queries.length, 2);
    for (final (method, query) in queries) {
      // Firestore caps the page at 24, plus the look-ahead row.
      expect(method, 'POST');
      expect(query['limit'], 25);
      expect(query['offset'], 5);
      final filter = query['where']['fieldFilter'];
      expect(filter['field']['fieldPath'], 'details.season');
      expect(filter['value']['stringValue'], _season);
    }

    // (Transient source map copies, entries copied). The details HTTP
    // envelope is still copied at the existing response boundary.
    debugPrint(
      'wire map copies/entries: season=${seasonMeter.counts}, '
      'details=${detailMeter.counts}',
    );
    expect(seasonMeter.counts, (0, 0));
    expect(detailMeter.counts, (2, 4));
  });
}
