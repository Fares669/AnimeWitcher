import 'dart:collection';
import 'dart:convert';

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/providers/animewitcher_native_provider.dart';
import 'package:animewitcher/core/storage/settings_repository.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/memory_storage_service.dart';

const _route = 'https://fixture.invalid/watch/fixture-show';

class _Settings extends MemoryStorageService {
  bool aniZipEnabled = true;

  @override
  bool isEpisodeImagesFromAniZipEnabled() => aniZipEnabled;
}

class _MapWork {
  int copies = 0;
  int entries = 0;
}

class _CountedMap extends MapBase<Object?, Object?> {
  _CountedMap(this._values, this._work);
  final Map<Object?, Object?> _values;
  final _MapWork _work;

  @override
  Object? operator [](Object? key) => _values[key];

  @override
  void operator []=(Object? key, Object? value) => _values[key] = value;

  @override
  void clear() => _values.clear();

  @override
  Iterable<Object?> get keys => _values.keys;

  @override
  Object? remove(Object? key) => _values.remove(key);

  @override
  Map<K, V> map<K, V>(
    MapEntry<K, V> Function(Object? key, Object? value) convert,
  ) {
    _work.copies++;
    return _values.map((key, value) {
      _work.entries++;
      return convert(key, value);
    });
  }
}

Map<String, dynamic> _document(
  String id,
  int number,
  int order, {
  String label = 'مترجم',
}) => {
  'fields': {
    'doc_id': {'stringValue': id},
    'episode_number': {'integerValue': '$number'},
    'sort_order': {'integerValue': '$order'},
    'name': {'stringValue': label},
    'title_translated': {'stringValue': 'قصة $id'},
    'thumb_uri': {'stringValue': 'native/$id.png'},
    'filler': {'booleanValue': number == 17},
  },
};

class _ProviderFixture {
  _ProviderFixture(
    List<Map<String, dynamic>> documents,
    this.aniZipRows, {
    this.malId = 425,
  }) {
    final dio = Dio();
    addTearDown(() => dio.close(force: true));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          final uri = request.uri;
          requests.add(uri);
          final Object data;
          if (uri.host == 'firestore.googleapis.com' &&
              uri.path.endsWith('/Settings/constants')) {
            data = {
              'fields': {
                'fixture': {'booleanValue': true},
              },
            };
          } else if (uri.host == 'firestore.googleapis.com' &&
              uri.path.endsWith('/anime_list/fixture-show')) {
            data = {
              'fields': {
                'name': {'stringValue': 'Fixture Anime'},
                'mal_id': {'integerValue': '$malId'},
              },
            };
          } else if (uri.host == 'firestore.googleapis.com' &&
              uri.path.endsWith('/anime_list/fixture-show/episodes')) {
            data = {'documents': documents};
          } else if (uri.path.endsWith('/indexes/series/fixture-show')) {
            // Route native details through the controlled original document.
            data = const <String, dynamic>{};
          } else if (uri.host == 'api.ani.zip' &&
              uri.path == '/mappings' &&
              uri.queryParameters['mal_id'] == '$malId') {
            aniZipRequests++;
            beforeAniZipResponse?.call();
            data = {'episodes': aniZipRows};
          } else {
            unexpected.add(uri);
            handler.reject(
              DioException(requestOptions: request, error: 'Unexpected $uri'),
            );
            return;
          }
          handler.resolve(
            Response<Object>(
              requestOptions: request,
              statusCode: 200,
              data: data,
            ),
          );
        },
      ),
    );
    provider = AnimeWitcherNativeProvider(dio, SettingsRepository(settings));
    addTearDown(() => expect(unexpected, isEmpty));
  }

  late final AnimeWitcherNativeProvider provider;
  final settings = _Settings();
  final int malId;
  Object? aniZipRows;
  void Function()? beforeAniZipResponse;
  int aniZipRequests = 0;
  final requests = <Uri>[];
  final unexpected = <Uri>[];
}

Object _identity(Episode row) => (
  row.url,
  row.episode,
  row.season,
  row.name,
  row.serverName,
  row.serverNumber,
  row.dubStatus,
  row.isFiller,
  row.isFinal,
);

void main() {
  test(
    'short exact-key AniZip response does not scan absolute matches',
    () async {
      final outer = _MapWork();
      final nested = _MapWork();
      final fixture = _ProviderFixture(
        [for (var i = 1; i <= 8; i++) _document('ep-$i', i, i)],
        _CountedMap({
          '2': {'image': 'wrong-string-key.png'},
          for (var i = 1; i <= 8; i++)
            i: _CountedMap({
              'image': 'direct/$i.png',
              'absoluteEpisodeNumber': i,
            }, nested),
          'never-scanned': _CountedMap({'absoluteEpisodeNumber': 41}, nested),
        }, outer),
      );
      final result = await fixture.provider.getEpisodeMetadata(_route);
      expect(result.map((row) => row.posterUrl), [
        for (var i = 1; i <= 8; i++) 'direct/$i.png',
      ]);
      expect(
        result.map(_identity),
        (await fixture.provider.getEpisodes(_route)).map(_identity),
      );
      expect(fixture.aniZipRequests, 1);
      expect(outer.copies, 1);
      expect(outer.entries, 10);
      expect(nested.copies, 8);
      expect(nested.entries, 16);
    },
  );

  test(
    'mixed response preserves native identity and image precedence at scale',
    () async {
      const count = 800;
      final outer = _MapWork();
      final nested = _MapWork();
      final fixture = _ProviderFixture(
        [
          _document('dub|0%١', 0, count + 2, label: 'مدبلج'),
          _document('negative', -1, count + 3),
          for (var i = count; i > 0; i--)
            _document(
              'ep-$i',
              i,
              i,
              label: i == count ? 'الحلقة 800 والأخيرة' : 'مترجم',
            ),
          _document('dub-33', 33, count + 1, label: 'مدبلج'),
        ],
        _CountedMap({
          for (var i = 1; i <= count; i++)
            if (i % 5 == 1)
              '$i': _CountedMap({'image': 'direct/$i.png'}, nested)
            else if (i % 5 == 2)
              '$i': _CountedMap({
                'image': '',
                'imageUrl': 'discarded/$i.png',
              }, nested)
            else if (i % 5 == 3)
              '$i': const <String, dynamic>{}
            else if (i % 5 == 4)
              i: jsonEncode({'thumbnail': 'serialized/$i.png'}),
          for (var i = 1; i <= count; i++)
            if (i % 5 == 3) ...{
              '0$i': _CountedMap({
                (i.isOdd ? 'absoluteEpisodeNumber' : 'absolute_episode_number'):
                    'ep $i',
                'image_url': 'absolute/$i.png',
              }, nested),
              'later-$i': _CountedMap({
                'absoluteEpisodeNumber': i,
                'image': 'wrong-duplicate/$i.png',
              }, nested),
            },
          '0': {'image': 'must-ignore-zero.png'},
          '-1': {'image': 'must-ignore-negative.png'},
        }, outer),
      );
      final result = await fixture.provider.getEpisodeMetadata(_route);
      final native = await fixture.provider.getEpisodes(_route);
      expect(result.map(_identity), native.map(_identity));
      expect(result, hasLength(count + 3));
      expect(result.first.url, 'fixture-show|ep-1');
      expect(result[16].isFiller, isTrue);
      expect(result[count - 1].isFinal, isTrue);
      expect(result[count].dubStatus, DubStatus.dubbed);
      expect(
        result[count + 1].url,
        'fixture-show|${Uri.encodeComponent('dub|0%١')}',
      );
      expect(result[count + 1].episode, 0);
      expect(result[count + 2].episode, -1);
      expect(result.map((row) => row.posterUrl), [
        for (var i = 1; i <= count; i++)
          switch (i % 5) {
            1 => 'direct/$i.png',
            3 => 'absolute/$i.png',
            4 => 'serialized/$i.png',
            _ => 'native/ep-$i.png',
          },
        'absolute/33.png',
        'native/dub|0%١.png',
        'native/negative.png',
      ]);
      expect(fixture.aniZipRequests, 1);
      expect(outer.copies, 1);
      expect(outer.entries, 962);
      expect(nested.copies, 960);
    },
  );

  test(
    'a resolved absolute miss neither scans the tail nor reopens the prefix',
    () async {
      final nested = _MapWork();
      final fixture = _ProviderFixture(
        [
          _document('first-two', 2, 1),
          _document('later-one', 1, 2),
          _document('second-two', 2, 3, label: 'مدبلج'),
        ],
        {
          '01': _CountedMap({
            'absoluteEpisodeNumber': 1,
            'image': 'one.png',
          }, nested),
          '02': _CountedMap({
            'absolute_episode_number': 2,
            'image': 'two.png',
          }, nested),
          '03': _CountedMap({'absoluteEpisodeNumber': 3}, nested),
        },
      );
      final rows = await fixture.provider.getEpisodeMetadata(_route);
      expect(rows.map((row) => row.posterUrl), [
        'two.png',
        'one.png',
        'two.png',
      ]);
      expect(nested.copies, 2);
    },
  );

  test(
    'first absolute entry without artwork and nonempty direct row both win',
    () async {
      final fixture = _ProviderFixture(
        [for (var i = 1; i <= 4; i++) _document('ep-$i', i, i)],
        {
          'unused-malformed': '{invalid JSON',
          'first-by-absolute': {'absolute_episode_number': 'الحلقة ١'},
          'later-with-art': {'absoluteEpisodeNumber': 1, 'image': 'wrong.png'},
          '2': {'name': 'existing direct row intentionally has no image'},
          'fallback-with-art': {
            'absoluteEpisodeNumber': 2,
            'image': 'wrong.png',
          },
          '3': {'imageUrl': 'direct-three.png'},
          'earlier-than-direct': {
            'absoluteEpisodeNumber': 3,
            'image': 'wrong.png',
          },
          '04': {'absolute_episode_number': '٤', 'image': 'absolute-four.png'},
        },
      );
      final first = await fixture.provider.getEpisodeMetadata(_route);
      expect(first.map((row) => row.posterUrl), [
        'native/ep-1.png',
        'native/ep-2.png',
        'direct-three.png',
        'absolute-four.png',
      ]);
      fixture.aniZipRows = jsonEncode({
        '01': {'absoluteEpisodeNumber': 1, 'image': 'new-response.png'},
      });
      final next = await fixture.provider.getEpisodeMetadata(_route);
      expect(next.first.posterUrl, 'new-response.png');
      expect(next.skip(1).map((row) => row.posterUrl), [
        'native/ep-2.png',
        'native/ep-3.png',
        'native/ep-4.png',
      ]);
      expect(fixture.aniZipRequests, 2);
    },
  );

  test('disabled, changed in-flight, no MAL ID and invalid payload keep native art', () async {
    final documents = [_document('ep-1', 1, 1)];
    final fixture = _ProviderFixture(documents, {
      '1': {'image': 'ani.zip.png'},
    });
    fixture.settings.aniZipEnabled = false;
    final disabled = await fixture.provider.getEpisodeMetadata(_route);
    expect(disabled.single.posterUrl, 'native/ep-1.png');
    expect(fixture.aniZipRequests, 0);

    fixture.settings.aniZipEnabled = true;
    fixture.beforeAniZipResponse = () => fixture.settings.aniZipEnabled = false;
    final turnedOff = await fixture.provider.getEpisodeMetadata(_route);
    expect(turnedOff.single.posterUrl, 'native/ep-1.png');
    expect(fixture.aniZipRequests, 1);

    fixture.settings.aniZipEnabled = true;
    fixture.beforeAniZipResponse = null;
    fixture.aniZipRows = ['not an episode map'];
    final malformed = await fixture.provider.getEpisodeMetadata(_route);
    expect(malformed.single.posterUrl, 'native/ep-1.png');
    expect(fixture.aniZipRequests, 2);

    final noMal = _ProviderFixture(documents, {}, malId: 0);
    expect(
      (await noMal.provider.getEpisodeMetadata(_route)).single.posterUrl,
      'native/ep-1.png',
    );
    expect(noMal.aniZipRequests, 0);
  });
}
