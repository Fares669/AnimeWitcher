import 'dart:collection';
import 'dart:convert';

import 'package:animewitcher/core/extensions/providers/animewitcher_native_provider.dart';
import 'package:animewitcher/core/storage/settings_repository.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

const _low = 'https://fixtures.invalid/medium.webp';
const _high = 'https://fixtures.invalid/large.webp';
const _cover = 'https://fixtures.invalid/cover.webp';
const _animeId = 'native-detail-fixture';

class _Settings extends SettingsRepository {
  _Settings() : super(StorageService());

  var highQuality = false;

  @override
  bool isHighQualityPostersEnabled() => highQuality;
}

class _CountedList extends ListBase<dynamic> {
  _CountedList(List<dynamic> values) : _values = values;

  final List<dynamic> _values;
  var renderCount = 0;

  @override
  int get length => _values.length;

  @override
  set length(int value) => throw UnsupportedError('read only');

  @override
  dynamic operator [](int index) => _values[index];

  @override
  void operator []=(int index, dynamic value) =>
      throw UnsupportedError('read only');

  @override
  String toString() {
    renderCount++;
    return super.toString();
  }
}

class _CountedMap extends MapBase<String, dynamic> {
  _CountedMap(this._values);

  final Map<String, dynamic> _values;
  var renderCount = 0;

  @override
  Iterable<String> get keys => _values.keys;

  @override
  dynamic operator [](Object? key) => _values[key];

  @override
  void operator []=(String key, dynamic value) =>
      throw UnsupportedError('read only');

  @override
  void clear() => throw UnsupportedError('read only');

  @override
  dynamic remove(Object? key) => throw UnsupportedError('read only');

  @override
  String toString() {
    renderCount++;
    return super.toString();
  }
}

void main() {
  test(
    'native details merge typed collections without rendering their text',
    () async {
      final details = _CountedMap(<String, dynamic>{
        'state': 'مستمر',
        'year': '2024',
        'season': 'خريف',
        'mal_mean': 8.1,
      });
      final tags = _CountedList(<dynamic>['أكشن', 'غامض', 'أكشن']);
      final relations = _CountedList(<dynamic>[
        <String, dynamic>{'mal_id': 101, 'relation_type': 'sequel'},
        <String, dynamic>{'mal_id': 102, 'relation_type': 'prequel'},
      ]);
      final settings = _Settings();
      var title = 'عنوان موثوق';
      var algoliaRequests = 0;
      var firestoreRequests = 0;
      final when =
          DateTime.now().add(const Duration(days: 1)).millisecondsSinceEpoch ~/
          1000;
      final dio = Dio();
      addTearDown(dio.close);
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            final path = request.uri.path;
            final Map<String, dynamic> data;
            if (path.endsWith('/series/$_animeId')) {
              algoliaRequests++;
              data = <String, dynamic>{
                'objectID': _animeId,
                'name': title,
                'story': ' \t ',
                'english_title': null,
                'poster_uri': _low,
                'poster': <String, dynamic>{'large': _high},
                'cover_uri': _cover,
                'details': details,
                'tags': tags,
                'related_anime_ids': relations,
                'episode_id': 12,
                'nextAiringAt': when,
              };
            } else {
              if (path.endsWith('/anime_list/$_animeId')) firestoreRequests++;
              data = const <String, dynamic>{};
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
      final provider = AnimeWitcherNativeProvider(
        dio,
        settings,
        algoliaSearchApiKey: 'fixture-key',
        resolveAnimeByMalIds: (ids) async => [
          for (final id in ids)
            <String, dynamic>{
              'objectID': 'related-$id',
              'mal_id': id,
              'anime_id': 'related-$id',
              'name': 'مرتبط $id',
            },
        ],
      );
      final url = Uri.https('animewitcher.com', '/watch/$_animeId', {
        'aw_data': jsonEncode(<String, dynamic>{
          'name': 'عنوان قديم',
          'english_title': 'Legacy title',
          'story': 'الوصف &amp; القصة',
          'tags': ['قديم'],
          'details': <String, dynamic>{'studio': 'استوديو', 'year': '2000'},
        }),
      }).toString();

      final detailFuture = provider.getDetails(url);
      final nextFuture = provider.getNextAiring(url);
      final detail = await detailFuture;
      final next = await nextFuture;
      expect(detail.title, 'عنوان موثوق');
      expect(detail.url, url);
      expect(detail.description, 'الوصف & القصة');
      expect(detail.year, 2024);
      expect(detail.score, 8.1);
      expect(detail.tags, ['أكشن', 'غامض']);
      expect(detail.posterUrl, _low);
      expect(detail.fullPosterUrl, _high);
      expect(detail.bannerUrl, _cover);
      expect(detail.syncData?['awEnglishTitle'], 'Legacy title');
      expect(detail.syncData?['awStudio'], 'استوديو');
      expect(detail.syncData?['awSeason'], 'خريف');
      expect(next?.episode, 13);
      expect(next?.unixTime, when);
      expect(algoliaRequests, 1);
      expect(firestoreRequests, 0);

      final related = await provider.getRelatedPage(url);
      expect(related.items.map((item) => item.title), [
        'مرتبط 102',
        'مرتبط 101',
      ]);
      expect(related.hasMore, isFalse);
      settings.highQuality = true;
      final reopened = await provider.getDetails(url);
      expect(reopened.posterUrl, _high);
      expect(algoliaRequests, 1);

      title = 'عنوان محدث';
      provider.invalidateDetailCaches(url);
      final refreshed = await provider.getDetails(url);
      expect(refreshed.title, title);
      expect(algoliaRequests, 2);
      expect(firestoreRequests, 0);
      final collectionRenders = [
        details.renderCount,
        tags.renderCount,
        relations.renderCount,
      ];
      // After every metadata assertion, so a stock failure here is measured.
      expect(collectionRenders, [0, 0, 0]);
    },
  );
}
