import 'dart:collection';
import 'dart:convert';

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/providers/animewitcher_native_provider.dart';
import 'package:animewitcher/core/storage/settings_repository.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/memory_storage_service.dart';

const _url = 'https://fixture.invalid/watch/c13-episode-show';
const _showPath = '/anime_list/c13-episode-show';
const _episodePath = '$_showPath/episodes';
const _summaryPath = '$_showPath/episodes_summery/summery';

Map<String, dynamic> _s(String value) => {'stringValue': value};

Map<String, dynamic> _i(int value) => {'integerValue': '$value'};

Map<String, dynamic> _m(Map<String, dynamic> fields) => {
  'mapValue': {'fields': fields},
};

Map<String, dynamic> _a(List<dynamic> values) => {
  'arrayValue': {'values': values},
};

Map<String, dynamic> _document(String id, Map<dynamic, dynamic> fields) => {
  'name': 'fixture/catalog/episodes/$id',
  'fields': fields,
};

class _IgnoredFieldWork {
  int mapCopies = 0;
  int inspectedFields = 0;
  int instrumentedMaps = 0;

  Map<String, dynamic> wrap(Map<String, dynamic> value) {
    instrumentedMaps++;
    return _CountedMap(value, this);
  }

  Map<String, dynamic> payload(int episode) => {
    'stream_sources': wrap({
      'arrayValue': wrap({
        'values': [
          for (var i = 0; i < 12; i++)
            wrap({
              'mapValue': wrap({
                'fields': wrap({
                  'name': wrap(_s('fixture-source-$i')),
                  'url': wrap(_s('https://stream.invalid/$episode/$i')),
                  'priority': wrap(_i(i)),
                  'options': wrap({
                    'arrayValue': wrap({
                      'values': [
                        wrap(_s('fixture-option-a')),
                        wrap(_s('fixture-option-b')),
                      ],
                    }),
                  }),
                }),
              }),
            }),
        ],
      }),
    }),
    'future_provider_notes': wrap({
      'mapValue': wrap({
        'fields': wrap({
          'en': wrap(_s('unused fallback note')),
          'ar': wrap(_s('حقل لا يظهر في صفحة الحلقات')),
        }),
      }),
    }),
  };
}

final class _CountedMap extends MapBase<String, dynamic> {
  _CountedMap(this._source, this._work);

  final Map<String, dynamic> _source;
  final _IgnoredFieldWork _work;

  @override
  dynamic operator [](Object? key) => _source[key];

  @override
  void operator []=(String key, dynamic value) => _source[key] = value;

  @override
  Iterable<String> get keys => _source.keys;

  @override
  dynamic remove(Object? key) => _source.remove(key);

  @override
  void clear() => _source.clear();

  @override
  Map<K, V> map<K, V>(
    MapEntry<K, V> Function(String key, dynamic value) convert,
  ) {
    _work.mapCopies++;
    return _source.map((key, value) {
      _work.inspectedFields++;
      return convert(key, value);
    });
  }
}

typedef _Page = ({List<Map<String, dynamic>> docs, String? nextToken});

final class _Fixture {
  _Fixture() {
    final dio = Dio();
    addTearDown(() => dio.close(force: true));
    addTearDown(() => expect(unexpected, isEmpty));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          final uri = request.uri;
          requests.add(uri);
          if (uri.host != 'firestore.googleapis.com') {
            unexpected.add(uri);
          } else if (uri.path.endsWith(_episodePath)) {
            final token = uri.queryParameters['pageToken'] ?? '';
            final page = pages[token];
            if (collectionFailure) {
              handler.reject(DioException(requestOptions: request));
              return;
            }
            if (page != null) {
              handler.resolve(
                Response<Object>(
                  requestOptions: request,
                  statusCode: 200,
                  data: {
                    'documents': page.docs,
                    if (page.nextToken != null) 'nextPageToken': page.nextToken,
                  },
                ),
              );
              return;
            }
            unexpected.add(uri);
          } else if (uri.path.endsWith(_summaryPath)) {
            final value = summary;
            if (value != null) {
              handler.resolve(
                Response<Object>(
                  requestOptions: request,
                  statusCode: 200,
                  data: value,
                ),
              );
              return;
            }
            if (summaryFailure) {
              handler.reject(DioException(requestOptions: request));
              return;
            }
            unexpected.add(uri);
          } else {
            unexpected.add(uri);
          }
          handler.reject(DioException(requestOptions: request));
        },
      ),
    );
    provider = AnimeWitcherNativeProvider(
      dio,
      SettingsRepository(MemoryStorageService()),
    );
  }

  final requests = <Uri>[];
  final unexpected = <Uri>[];
  final pages = <String, _Page>{};
  Map<String, dynamic>? summary;
  bool collectionFailure = false;
  bool summaryFailure = false;
  late final AnimeWitcherNativeProvider provider;

  List<String> get collectionTokens => [
    for (final uri in requests)
      if (uri.path.endsWith(_episodePath))
        uri.queryParameters['pageToken'] ?? '',
  ];
}

Map<String, dynamic> _episodeFields(
  int n, {
  String? title,
  _IgnoredFieldWork? unused,
}) => {
  'doc_id': _s('episode-$n'),
  'episode_number': _i(n),
  'name': _s(n == 3 ? ' الحلقة ٣ والأخيرة ' : 'الحلقة $n'),
  'sort_order': _i(n),
  'title_translated': _m({'ar': _s(title ?? 'قصة $n'), 'en': _s('Story $n')}),
  'thumb_uri': _s('https://image.invalid/$n.jpg'),
  'filler': {'booleanValue': n == 17},
  ...?unused?.payload(n),
};

List<Object?> _visibleRecord(Episode episode) => [
  episode.url,
  episode.season,
  episode.episode,
  episode.name,
  episode.serverName,
  episode.serverNumber,
  episode.posterUrl,
  episode.isFiller,
  episode.isFinal,
  episode.dubStatus,
];

List<Object?> _expectedRow(int n, {String? title}) => [
  'c13-episode-show|episode-$n',
  1,
  n,
  title ?? 'قصة $n',
  n == 3 ? ' الحلقة ٣ والأخيرة ' : 'الحلقة $n',
  '$n',
  'https://image.invalid/$n.jpg',
  n == 17,
  n == 3,
  DubStatus.none,
];

void main() {
  test(
    'authoritative episode pages decode only fields used by Details',
    () async {
      final fixture = _Fixture();
      final ignored = _IgnoredFieldWork();
      final visible = const _ExpectedRange();
      fixture.pages[''] = (
        docs: [
          for (var n = visible.page1End; n >= 1; n--)
            _document('episode-$n', _episodeFields(n, unused: ignored)),
        ],
        nextToken: 'fixture next+page',
      );
      fixture.pages['fixture next+page'] = (
        docs: [
          for (var n = visible.end; n > visible.page1End; n--)
            _document('episode-$n', _episodeFields(n, unused: ignored)),
          _document(
            'duplicate-first',
            _episodeFields(12, title: 'النسخة اللاحقة'),
          ),
        ],
        nextToken: null,
      );

      expect(ignored.instrumentedMaps, greaterThan(50000));
      final first = await fixture.provider.getEpisodes(_url);
      expect(first.map(_visibleRecord), [
        for (var n = 1; n <= visible.end; n++) _expectedRow(n),
      ]);
      expect(fixture.collectionTokens, ['', 'fixture next+page']);
      expect(fixture.requests, hasLength(2));
      expect(
        fixture.requests.every(
          (uri) => uri.queryParameters['pageSize'] == '1000',
        ),
        isTrue,
      );
      expect(ignored.mapCopies, 0);
      expect(ignored.inspectedFields, 0);

      final reused = await fixture.provider.getEpisodes(_url);
      expect(reused.map(_visibleRecord), first.map(_visibleRecord));
      expect(fixture.collectionTokens, ['', 'fixture next+page']);
      fixture.provider.invalidateDetailCaches(_url);
      fixture.pages[''] = (
        docs: [
          _document(
            'episode-3',
            _episodeFields(3, title: 'قصة جديدة', unused: ignored),
          ),
        ],
        nextToken: null,
      );
      const updatedTitle = 'قصة جديدة';
      final fresh = await fixture.provider.getEpisodes(_url);
      expect(fresh.map(_visibleRecord), [_expectedRow(3, title: updatedTitle)]);
      expect(fixture.collectionTokens, ['', 'fixture next+page', '']);
    },
  );

  test('selected aliases preserve localized data, zero movie variants and fallback ids', () async {
    final fixture = _Fixture();
    fixture.pages[''] = (
      docs: [
        _document('unused-direct-id', {
          'episode_id': _s('episode-10'),
          'episodeNumber': _s(' ٠٠١٠٫٥ '),
          'episode_name': _s(' الحلقة ١٠ والأخيرة '),
          'sortOrder': _i(1),
          'title_translated': _s('الحلقة 10'),
          'episodeTitle': _m({'ar_SA': _s('المغامرة &amp; العودة')}),
          'image_url': _s('https://image.invalid/variant.jpg'),
          'is_filler': {'booleanValue': true},
        }),
        _document('movie-sub', {
          'episode': _i(0),
          'episodeName': _s(' مترجم '),
          'sort': _i(2),
          'poster': _s('https://image.invalid/subbed.jpg'),
        }),
        _document(
          'movie-dub',
          _mixedKeyFields({
            'id': _s('movie-dub'),
            'ep': _i(0),
            'episode_name': _s('مدبلج'),
            'sort_order': _i(3),
            'image': _s('https://image.invalid/dubbed.jpg'),
            'isFiller': {'booleanValue': true},
          }),
        ),
        _document('leading-zero', {
          'episode': _i(0),
          'number': _s(' ٠٠٤ '),
          'name': _s('Episode 0'),
          'title': _m({'customLocale': _s('عنوان من اللغة الاحتياطية')}),
          'sort_order': _i(4),
        }),
      ],
      nextToken: null,
    );
    final episodes = await fixture.provider.getEpisodes(_url);
    expect(episodes.map(_visibleRecord), [
      [
        'c13-episode-show|episode-10',
        1,
        10,
        'المغامرة & العودة',
        ' الحلقة ١٠ والأخيرة ',
        ' ٠٠١٠٫٥ ',
        'https://image.invalid/variant.jpg',
        true,
        true,
        DubStatus.none,
      ],
      [
        'c13-episode-show|movie-sub',
        1,
        0,
        '',
        ' مترجم ',
        '0',
        'https://image.invalid/subbed.jpg',
        false,
        false,
        DubStatus.subbed,
      ],
      [
        'c13-episode-show|movie-dub',
        1,
        0,
        '',
        'مدبلج',
        '0',
        'https://image.invalid/dubbed.jpg',
        true,
        false,
        DubStatus.dubbed,
      ],
      [
        'c13-episode-show|leading-zero',
        1,
        0,
        'عنوان من اللغة الاحتياطية',
        'Episode 0',
        '0',
        null,
        false,
        false,
        DubStatus.none,
      ],
    ]);
  });

  test('summary compatibility, source authority and genuine retry keep their behavior', () async {
    final fixture = _Fixture()
      ..collectionFailure = true
      ..summaryFailure = true;
    await expectLater(fixture.provider.getEpisodes(_url), throwsStateError);
    fixture
      ..summaryFailure = false
      ..summary = {
        'fields': {
          'episodes': _a([_s(jsonEncode(_episodeFieldsAsPlainMap()))]),
        },
      };
    final summary = await fixture.provider.getEpisodes(_url);
    expect(summary.single.name, 'عنوان النسخة الاحتياطية');
    expect(summary.single.url, 'c13-episode-show|legacy-seven');
    expect(summary.single.episode, 7);
    expect(
      fixture.requests.where((uri) => uri.path.endsWith(_summaryPath)),
      hasLength(2),
    );

    fixture.provider.invalidateDetailCaches(_url);
    fixture.collectionFailure = false;
    fixture.pages[''] = (
      docs: [_document('episode-7', _episodeFields(7))],
      nextToken: null,
    );
    final canonical = await fixture.provider.getEpisodes(_url);
    expect(canonical.map(_visibleRecord), [_expectedRow(7)]);
    expect(
      fixture.requests.where((uri) => uri.path.endsWith(_summaryPath)),
      hasLength(2),
    );
  });
}

// Preserve non-string-key normalization, including ignored mixed map keys.
Map<dynamic, dynamic> _mixedKeyFields(Map<String, dynamic> values) => {
  ...values,
  999: {'stringValue': 'opaque-unused-field'},
};

Map<String, dynamic> _episodeFieldsAsPlainMap() => {
  'doc_id': 'legacy-seven',
  'episode_number': 7,
  'name': 'الحلقة القديمة',
  'title_ar': 'عنوان النسخة الاحتياطية',
};

class _ExpectedRange {
  const _ExpectedRange();
  int get page1End => 548;
  int get end => 612;
}
