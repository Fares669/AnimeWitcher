import 'package:animewitcher/core/extensions/providers/animewitcher_native_provider.dart';
import 'package:animewitcher/core/storage/settings_repository.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _document(String id) {
  return <String, dynamic>{
    'name':
        'projects/animewitcher-1c66d/databases/(default)/documents/anime_list/$id',
    'fields': <String, dynamic>{
      'name': <String, dynamic>{'stringValue': 'Anime $id'},
      'show_time': const <String, dynamic>{'stringValue': 'السبت'},
      'poster': <String, dynamic>{
        'mapValue': <String, dynamic>{
          'fields': <String, dynamic>{
            'large': <String, dynamic>{
              'stringValue': 'https://cdn.example.test/$id.jpg',
            },
          },
        },
      },
    },
  };
}

({Dio dio, List<RequestOptions> requests}) _stubDio({
  List<Map<String, dynamic>>? runQueryDocuments,
  int runQueryStatus = 200,
}) {
  final requests = <RequestOptions>[];
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        requests.add(options);
        if (options.uri.toString().contains(':runQuery')) {
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: runQueryStatus,
              data: <Map<String, dynamic>>[
                for (final document
                    in runQueryDocuments ??
                        <Map<String, dynamic>>[
                          _document('one'),
                          _document('two'),
                          _document('three'),
                        ])
                  <String, dynamic>{'document': document},
              ],
            ),
          );
          return;
        }
        handler.resolve(
          Response<dynamic>(
            requestOptions: options,
            statusCode: 200,
            data: const <String, dynamic>{},
          ),
        );
      },
    ),
  );
  return (dio: dio, requests: requests);
}

class _TestStorageService extends StorageService {
  @override
  bool isHighQualityPostersEnabled() => true;

  @override
  bool isEpisodeImagesFromAniZipEnabled() => false;
}

AnimeWitcherNativeProvider _provider(Dio dio) =>
    AnimeWitcherNativeProvider(dio, SettingsRepository(_TestStorageService()));

void main() {
  test('broadcast schedule page requests one bounded Firestore page', () async {
    final stub = _stubDio();

    final page = await _provider(
      stub.dio,
    ).getBroadcastSchedulePage('السبت', limit: 2);

    expect(page.items.map((item) => item.title).toList(), <String>[
      'Anime one',
      'Anime two',
    ]);
    expect(page.nextOffset, 2);
    expect(page.hasMore, isTrue);
    expect(stub.requests, hasLength(1));
    final payload = Map<String, dynamic>.from(stub.requests.single.data as Map);
    final query = Map<String, dynamic>.from(payload['structuredQuery'] as Map);
    expect(query['offset'], 0);
    expect(query['limit'], 3);
    final where = Map<String, dynamic>.from(query['where'] as Map);
    final filter = Map<String, dynamic>.from(where['fieldFilter'] as Map);
    expect(filter['field'], <String, dynamic>{'fieldPath': 'show_time'});
    expect(filter['value'], <String, dynamic>{'stringValue': 'السبت'});
  });

  test('broadcast schedule page advances the Firestore offset', () async {
    final stub = _stubDio();

    final page = await _provider(
      stub.dio,
    ).getBroadcastSchedulePage('السبت', offset: 30, limit: 10);

    expect(page.nextOffset, 33);
    expect(page.hasMore, isFalse);
    final payload = Map<String, dynamic>.from(stub.requests.single.data as Map);
    final query = Map<String, dynamic>.from(payload['structuredQuery'] as Map);
    expect(query['offset'], 30);
    expect(query['limit'], 11);
  });

  test(
    'broadcast schedule page ignores an unknown day without a network call',
    () async {
      final stub = _stubDio();

      final page = await _provider(
        stub.dio,
      ).getBroadcastSchedulePage('غير معروف');

      expect(page.items, isEmpty);
      expect(page.nextOffset, 0);
      expect(page.hasMore, isFalse);
      expect(stub.requests, isEmpty);
    },
  );

  test('an empty Firestore day does not load the weekly fallback', () async {
    final stub = _stubDio(runQueryDocuments: const <Map<String, dynamic>>[]);

    final page = await _provider(stub.dio).getBroadcastSchedulePage('السبت');

    expect(page.items, isEmpty);
    expect(page.hasMore, isFalse);
    expect(stub.requests, hasLength(1));
  });

  test('a failed Firestore page falls back to the weekly loader', () async {
    final stub = _stubDio(runQueryStatus: 500);

    final page = await _provider(stub.dio).getBroadcastSchedulePage('السبت');

    expect(page.items, isEmpty);
    expect(stub.requests.length, greaterThan(1));
  });
}
