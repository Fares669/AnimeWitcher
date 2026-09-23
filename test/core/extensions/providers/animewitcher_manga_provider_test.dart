import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/providers/animewitcher_native_provider.dart';
import 'package:animewitcher/core/storage/settings_repository.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _stringField(String value) =>
    <String, dynamic>{'stringValue': value};

Map<String, dynamic> _mapField(Map<String, dynamic> fields) =>
    <String, dynamic>{
      'mapValue': <String, dynamic>{'fields': fields},
    };

Map<String, dynamic> _intField(int value) =>
    <String, dynamic>{'integerValue': value.toString()};

Map<String, dynamic> _homeSectionsDocument() => <String, dynamic>{
  'fields': <String, dynamic>{
    'sections': <String, dynamic>{
      'arrayValue': <String, dynamic>{
        'values': <Map<String, dynamic>>[
          _mapField(<String, dynamic>{
            'title': _stringField('فصول جديدة'),
            'type': _stringField('manga_recent'),
            'index_name': _stringField('manga_recent_live'),
            'hits_per_page': _intField(30),
            'order': _intField(2),
            'enabled': const <String, dynamic>{'booleanValue': true},
          }),
        ],
      },
    },
  },
};

Map<String, dynamic> _settingsDocument() => <String, dynamic>{
  'fields': <String, dynamic>{
    'search_settings': _mapField(<String, dynamic>{
      'app_id_v3': _stringField('MANGAAPP'),
      'api_key': _stringField('manga-search-key'),
      'is_search_active': const <String, dynamic>{'booleanValue': true},
    }),
  },
};

Map<String, dynamic> _mangaDocument() => <String, dynamic>{
  'name':
      'projects/animewitcher-1c66d/databases/(default)/documents/manga_list/m1',
  'fields': <String, dynamic>{
    'name': _stringField('Manga One'),
    'type': _stringField('مانهوا'),
    'story': _stringField('Story'),
    'poster_uri': _stringField('https://img.example/m1.webp'),
    'mangalek_page_url': _stringField(
      'https://mangalik.net/manga/manga-one/',
    ),
  },
};

bool _isAlgolia(Uri uri) =>
    uri.host.contains('algolia.net') || uri.host.contains('algolianet.com');

class _TestStorageService extends StorageService {
  @override
  bool isHighQualityPostersEnabled() => true;

  @override
  bool isEpisodeImagesFromAniZipEnabled() => false;
}

({Dio dio, List<RequestOptions> requests}) _stubDio() {
  final requests = <RequestOptions>[];
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        requests.add(options);
        if (options.uri.host.contains('firestore') &&
            options.uri.path.contains('Settings/home_sections')) {
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: _homeSectionsDocument(),
            ),
          );
          return;
        }
        if (options.uri.host.contains('firestore') &&
            options.uri.path.contains('Settings/constants')) {
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: _settingsDocument(),
            ),
          );
          return;
        }
        if (options.uri.host.contains('firestore') &&
            options.uri.path.endsWith('/documents:runQuery')) {
          final body = options.data;
          final query = body is Map ? body['structuredQuery'] : null;
          final from = query is Map ? query['from'] : null;
          final firstFrom = from is List && from.isNotEmpty ? from.first : null;
          final collectionId = firstFrom is Map
              ? firstFrom['collectionId']?.toString() ?? ''
              : '';
          if (collectionId == 'manga_recent') {
            handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: 200,
                data: <Map<String, dynamic>>[
                  <String, dynamic>{
                    'document': <String, dynamic>{
                      'name':
                          'projects/animewitcher-1c66d/databases/(default)/documents/manga_recent/recent-b-30',
                      'fields': <String, dynamic>{
                        'manga_id': _stringField('recent-b'),
                        'manga_name': _stringField('Recent B'),
                        'type': _stringField('مانهوا'),
                        'poster_url': _stringField(
                          'https://img.example/b.webp',
                        ),
                        'chapter_id': _stringField('30'),
                        'chapter_name': _stringField('الفصل 30'),
                        'date': <String, dynamic>{
                          'timestampValue': '2026-09-20T15:00:00Z',
                        },
                      },
                    },
                  },
                  <String, dynamic>{
                    'document': <String, dynamic>{
                      'name':
                          'projects/animewitcher-1c66d/databases/(default)/documents/manga_recent/recent-a-20',
                      'fields': <String, dynamic>{
                        'manga_id': _stringField('recent-a'),
                        'manga_name': _stringField('Recent A'),
                        'type': _stringField('مانجا'),
                        'poster_url': _stringField(
                          'https://img.example/a.webp',
                        ),
                        'chapter_id': _stringField('20'),
                        'chapter_name': _stringField('الفصل 20'),
                        'date': <String, dynamic>{
                          'timestampValue': '2026-09-20T14:00:00Z',
                        },
                      },
                    },
                  },
                ],
              ),
            );
            return;
          }
        }
        if (_isAlgolia(options.uri) &&
            options.uri.path.endsWith('/indexes/manga_recent_live/query')) {
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: <String, dynamic>{
                'hits': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'objectID': 'recent-b-30',
                    'manga_id': 'recent-b',
                    'manga_name': 'Recent B',
                    'type': 'مانهوا',
                    'poster_url': 'https://img.example/b.webp',
                    'chapter_id': '30',
                    'chapter_name': 'الفصل 30',
                    'date': 1789916400000,
                  },
                  <String, dynamic>{
                    'objectID': 'recent-a-20',
                    'manga_id': 'recent-a',
                    'manga_name': 'Recent A',
                    'type': 'مانجا',
                    'poster_url': 'https://img.example/a.webp',
                    'chapter_id': '20',
                    'chapter_name': 'الفصل 20',
                    'date': 1789912800000,
                  },
                ],
                'page': 0,
                'nbPages': 1,
                'nbHits': 2,
              },
            ),
          );
          return;
        }
        if (_isAlgolia(options.uri) &&
            options.uri.path.endsWith('/indexes/manga_views_desc/query')) {
          final body = options.data;
          final params = body is Map ? body['params']?.toString() ?? '' : '';
          final isRecentQuery = params.contains('lastmodified');
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: isRecentQuery
                  ? <String, dynamic>{
                      'hits': <Map<String, dynamic>>[
                        <String, dynamic>{
                          'objectID': 'recent-a',
                          'name': 'Recent A',
                          'type': 'مانجا',
                          'poster_uri': 'https://img.example/a.webp',
                          'mangalek_page_url':
                              'https://mangalik.net/manga/recent-a/',
                          'lastmodified': 200,
                        },
                        <String, dynamic>{
                          'objectID': 'recent-b',
                          'name': 'Recent B',
                          'type': 'مانهوا',
                          'poster_uri': 'https://img.example/b.webp',
                          'mangalek_page_url':
                              'https://mangalik.net/manga/recent-b/',
                          'lastmodified': 300,
                        },
                      ],
                      'page': 0,
                      'nbPages': 1,
                      'nbHits': 2,
                    }
                  : <String, dynamic>{
                      'hits': <Map<String, dynamic>>[
                        <String, dynamic>{
                          'objectID': 'm1',
                          'name': 'Manga One',
                          'type': 'مانهوا',
                          'poster_uri': 'https://img.example/m1.webp',
                          'mangalek_page_url':
                              'https://mangalik.net/manga/manga-one/',
                        },
                      ],
                      'page': 0,
                      'nbPages': 1,
                    },
            ),
          );
          return;
        }
        if (options.uri.host.contains('firestore') &&
            options.uri.path.endsWith('/manga_list/m1')) {
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: _mangaDocument(),
            ),
          );
          return;
        }
        if (options.uri.host == 'mangalik.net' &&
            (options.uri.path == '/manga/recent-a/' ||
                options.uri.path == '/manga/recent-b/')) {
          final isB = options.uri.path.contains('recent-b');
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: '''
<ul>
<li class="wp-manga-chapter">
<a href="${isB ? '/manga/recent-b/chapter-30/' : '/manga/recent-a/chapter-20/'}">
${isB ? 'الفصل 30' : 'الفصل 20'}
</a>
<span class="chapter-release-date">2026-09-20</span>
</li>
</ul>
''',
            ),
          );
          return;
        }
        if (options.uri.host == 'lekmanga.online' &&
            options.uri.path == '/manga/manga-one/') {
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: '''
<ul>
<li class="wp-manga-chapter">
<a href="/manga/manga-one/chapter-9/">الفصل 9</a>
</li>
</ul>
''',
            ),
          );
          return;
        }
        if (options.uri.host == 'mangalik.net' &&
            options.uri.path == '/manga/manga-one/') {
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: '''
<ul>
<li class="wp-manga-chapter">
<a href="/manga/manga-one/chapter-1/">الفصل 1</a>
<span class="chapter-release-date">2026-09-20</span>
</li>
</ul>
''',
            ),
          );
          return;
        }
        if (options.uri.host == 'mangalik.net' &&
            options.uri.path == '/manga/manga-one/chapter-1/') {
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: '''
<div class="reading-content">
<div class="page-break"><img data-src="https://cdn.example/1.webp"></div>
<div class="page-break"><img data-src="https://cdn.example/2.webp"></div>
</div>
''',
            ),
          );
          return;
        }
        handler.resolve(
          Response<dynamic>(
            requestOptions: options,
            statusCode: 404,
            data: const <String, dynamic>{},
          ),
        );
      },
    ),
  );
  return (dio: dio, requests: requests);
}

AnimeWitcherNativeProvider _provider(Dio dio) => AnimeWitcherNativeProvider(
  dio,
  SettingsRepository(_TestStorageService()),
);

void main() {
  test('native provider advertises manga support', () {
    final stub = _stubDio();
    expect(_provider(stub.dio).supportedTypes, contains(ProviderType.manga));
  });

  test('manga search uses the verified live manga index', () async {
    final stub = _stubDio();
    final page = await _provider(stub.dio).searchMangaPage(
      'one',
      const ProviderSearchFilters(sort: 'views'),
    );

    expect(page.items, hasLength(1));
    expect(page.items.single.contentType, MultimediaContentType.manga);
    expect(page.items.single.title, 'Manga One');
    final request = stub.requests.singleWhere(
      (entry) => entry.uri.path.endsWith('/indexes/manga_views_desc/query'),
    );
    expect(request.headers['X-Algolia-API-Key'], 'manga-search-key');
  });

  test('manga details reads manga_list and never anime_list', () async {
    final stub = _stubDio();
    final item = await _provider(
      stub.dio,
    ).getMangaDetails('https://animewitcher.com/manga/m1');

    expect(item.title, 'Manga One');
    expect(item.contentType, MultimediaContentType.manga);
    expect(
      stub.requests.any((entry) => entry.uri.path.contains('/anime_list/')),
      isFalse,
    );
  });

  test('latest manga follows the official manga_recent home Algolia section', () async {
    final stub = _stubDio();
    final page = await _provider(stub.dio).getLatestMangaPage(limit: 2);

    expect(page.items, hasLength(2));
    expect(page.items.map((entry) => entry.manga.title), <String>[
      'Recent B',
      'Recent A',
    ]);
    expect(page.items[0].chapter.name, 'الفصل 30');
    expect(page.items[1].chapter.name, 'الفصل 20');
    expect(
      page.items[0].chapter.publishedAt,
      DateTime.fromMillisecondsSinceEpoch(1789916400000),
    );

    final recentRequest = stub.requests.singleWhere(
      (entry) =>
          _isAlgolia(entry.uri) &&
          entry.uri.path.endsWith('/indexes/manga_recent_live/query'),
    );
    final body = recentRequest.data as Map;
    final params = body['params']?.toString() ?? '';
    expect(params, contains('attributesToRetrieve'));
    expect(params, contains('chapter_name'));
    expect(params, contains('manga_name'));

    expect(
      stub.requests.any((entry) {
        if (!entry.uri.host.contains('firestore') ||
            !entry.uri.path.endsWith('/documents:runQuery')) {
          return false;
        }
        final body = entry.data;
        final query = body is Map ? body['structuredQuery'] : null;
        final from = query is Map ? query['from'] : null;
        final firstFrom = from is List && from.isNotEmpty ? from.first : null;
        return firstFrom is Map && firstFrom['collectionId'] == 'manga_recent';
      }),
      isFalse,
    );
    expect(
      stub.requests.any(
        (entry) =>
            entry.uri.host == 'mangalik.net' ||
            entry.uri.host == 'manga-leko.net' ||
            entry.uri.host == 'lekmanga.online',
      ),
      isFalse,
    );
  });

  test('chapters use the original chapters_summery document before queries', () async {
    final stub = _stubDio();
    var queriedChaptersCollection = false;
    stub.dio.interceptors.insert(
      0,
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (!options.uri.host.contains('firestore')) {
            handler.next(options);
            return;
          }

          if (options.uri.path.endsWith(
            '/documents/manga_list/m1/chapters_summery/summery',
          )) {
            handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: 200,
                data: <String, dynamic>{
                  'fields': <String, dynamic>{
                    'chapters': <String, dynamic>{
                      'arrayValue': <String, dynamic>{
                        'values': <Map<String, dynamic>>[
                          _mapField(<String, dynamic>{
                            'doc_id': _stringField('42.5'),
                            'name': _stringField('الفصل 42.5'),
                            'thumb_uri': _stringField(
                              'https://img.example/ch42.webp',
                            ),
                          }),
                        ],
                      },
                    },
                  },
                },
              ),
            );
            return;
          }

          final body = options.data;
          final query = body is Map ? body['structuredQuery'] : null;
          final from = query is Map ? query['from'] : null;
          final firstFrom = from is List && from.isNotEmpty ? from.first : null;
          if (firstFrom is Map && firstFrom['collectionId'] == 'chapters') {
            queriedChaptersCollection = true;
          }
          handler.next(options);
        },
      ),
    );

    final chapters = await _provider(stub.dio).getMangaChapters(
      'https://animewitcher.com/manga/m1',
    );

    expect(chapters, hasLength(1));
    expect(chapters.single.id, '42.5');
    expect(chapters.single.name, 'الفصل 42.5');
    expect(chapters.single.number, 42.5);
    expect(queriedChaptersCollection, isFalse);
    expect(
      stub.requests.any(
        (entry) =>
            entry.uri.host == 'mangalik.net' ||
            entry.uri.host == 'manga-leko.net' ||
            entry.uri.host == 'lekmanga.online',
      ),
      isFalse,
    );
  });

  test('chapters and pages use AnimeWitcher Firestore hierarchy first', () async {
    final stub = _stubDio();
    Map? chapterStructuredQuery;
    stub.dio.interceptors.insert(
      0,
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (!options.uri.host.contains('firestore')) {
            handler.next(options);
            return;
          }

          final body = options.data;
          final query = body is Map ? body['structuredQuery'] : null;
          final from = query is Map ? query['from'] : null;
          final firstFrom = from is List && from.isNotEmpty ? from.first : null;
          final collectionId = firstFrom is Map
              ? firstFrom['collectionId']?.toString() ?? ''
              : '';

          if (options.uri.path.endsWith('/documents/manga_list/m1:runQuery') &&
              collectionId == 'chapters') {
            chapterStructuredQuery = query is Map ? Map.from(query) : null;
            handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: 200,
                data: <Map<String, dynamic>>[
                  <String, dynamic>{
                    'document': <String, dynamic>{
                      'name':
                          'projects/animewitcher-1c66d/databases/(default)/documents/manga_list/m1/chapters/c77',
                      'fields': <String, dynamic>{
                        'doc_id': _stringField('77'),
                        'name': _stringField('الفصل 77.5'),
                        'thumb_uri': _stringField(
                          'https://img.example/ch77.webp',
                        ),
                      },
                    },
                  },
                ],
              ),
            );
            return;
          }

          if (options.uri.path.endsWith(
                '/documents/manga_list/m1/chapters/c77:runQuery',
              ) &&
              collectionId == 'pages') {
            handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: 200,
                data: <Map<String, dynamic>>[
                  <String, dynamic>{
                    'document': <String, dynamic>{
                      'name':
                          'projects/animewitcher-1c66d/databases/(default)/documents/manga_list/m1/chapters/c77/pages/p2',
                      'fields': <String, dynamic>{
                        'name': _stringField('2'),
                        'image_url': _stringField(
                          'https://cdn.example/firestore-2.webp',
                        ),
                        'order': _intField(2),
                        'page_number': _intField(2),
                      },
                    },
                  },
                  <String, dynamic>{
                    'document': <String, dynamic>{
                      'name':
                          'projects/animewitcher-1c66d/databases/(default)/documents/manga_list/m1/chapters/c77/pages/p1',
                      'fields': <String, dynamic>{
                        'name': _stringField('1'),
                        'image_url': _stringField(
                          'https://cdn.example/firestore-1.webp',
                        ),
                        'order': _intField(1),
                        'page_number': _intField(1),
                      },
                    },
                  },
                ],
              ),
            );
            return;
          }

          handler.next(options);
        },
      ),
    );

    final provider = _provider(stub.dio);
    final chapters = await provider.getMangaChapters(
      'https://animewitcher.com/manga/m1',
    );

    expect(chapters, hasLength(1));
    expect(chapters.single.id, 'c77');
    expect(chapters.single.name, 'الفصل 77.5');
    expect(chapters.single.number, 77.5);
    expect(chapterStructuredQuery, isNotNull);
    expect(chapterStructuredQuery!.containsKey('orderBy'), isFalse);

    final pages = await provider.getMangaChapterPages(
      'https://animewitcher.com/manga/m1',
      chapters.single,
    );
    expect(
      pages.map((page) => page.imageUrl),
      <String>[
        'https://cdn.example/firestore-1.webp',
        'https://cdn.example/firestore-2.webp',
      ],
    );
    expect(
      stub.requests.any(
        (entry) =>
            entry.uri.host == 'mangalik.net' ||
            entry.uri.host == 'manga-leko.net' ||
            entry.uri.host == 'lekmanga.online',
      ),
      isFalse,
    );
  });

  test('chapters use stored source before archive fallback', () async {
    final stub = _stubDio();

    final chapters = await _provider(stub.dio).getMangaChapters(
      'https://animewitcher.com/manga/m1',
    );

    expect(chapters, hasLength(1));
    expect(chapters.single.name, 'الفصل 1');
    final chapterRequestIndex = stub.requests.indexWhere(
      (entry) =>
          entry.uri.host == 'mangalik.net' &&
          entry.uri.path == '/manga/manga-one/',
    );
    expect(chapterRequestIndex, greaterThanOrEqualTo(0));
    expect(
      stub.requests.any((entry) => entry.uri.host == 'manga-leko.net'),
      isFalse,
    );
  });

  test('chapters fall back to a MangaLek mirror when stored host fails', () async {
    final stub = _stubDio();
    stub.dio.interceptors.insert(
      0,
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.uri.host == 'mangalik.net' &&
              options.uri.path == '/manga/manga-one/') {
            handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: 503,
                data: 'temporarily unavailable',
              ),
            );
            return;
          }
          handler.next(options);
        },
      ),
    );

    final chapters = await _provider(stub.dio).getMangaChapters(
      'https://animewitcher.com/manga/m1',
    );

    expect(chapters, hasLength(1));
    expect(chapters.single.name, 'الفصل 9');
    expect(
      stub.requests.any((entry) => entry.uri.host == 'lekmanga.online'),
      isTrue,
    );
  });

  test('chapters ignore a 200 challenge page and try the next mirror', () async {
    final stub = _stubDio();
    stub.dio.interceptors.insert(
      0,
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.uri.host == 'mangalik.net' &&
              options.uri.path == '/manga/manga-one/') {
            handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: 200,
                data: '<html><title>Just a moment...</title></html>',
              ),
            );
            return;
          }
          handler.next(options);
        },
      ),
    );

    final chapters = await _provider(stub.dio).getMangaChapters(
      'https://animewitcher.com/manga/m1',
    );

    expect(chapters, hasLength(1));
    expect(chapters.single.name, 'الفصل 9');
    expect(
      stub.requests.any((entry) => entry.uri.host == 'lekmanga.online'),
      isTrue,
    );
  });

  test('chapters fall back to current WordPress archive shape', () async {
    final stub = _stubDio();
    final archiveRequests = <Uri>[];
    stub.dio.interceptors.insert(
      0,
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.uri.host == 'manga-leko.net') {
            archiveRequests.add(options.uri);
          }
          if (options.uri.path == '/manga/manga-one/' &&
              options.uri.host != 'manga-leko.net') {
            handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: 200,
                data: '<html><title>Moved</title></html>',
              ),
            );
            return;
          }
          if (options.uri.host == 'manga-leko.net' &&
              options.uri.path == '/tag/manga-one/') {
            handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: 200,
                data: '''
<main>
  <article><h2><a href="/manga-one-30-%D9%85%D8%AA%D8%B1%D8%AC%D9%85/">Manga One الفصل 30 مترجم</a></h2></article>
  <article><h2><a href="/manga-one-29-%D9%85%D8%AA%D8%B1%D8%AC%D9%85/">Manga One 29 مترجم</a></h2></article>
  <a class="next page-numbers" href="/tag/manga-one/page/2/">Next</a>
</main>
''',
              ),
            );
            return;
          }
          if (options.uri.host == 'manga-leko.net' &&
              options.uri.path == '/tag/manga-one/page/2/') {
            handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: 200,
                data: '''
<main>
  <article><h2><a href="/manga-one-28-%D9%85%D8%AA%D8%B1%D8%AC%D9%85/">Manga One الفصل 28 مترجم</a></h2></article>
</main>
''',
              ),
            );
            return;
          }
          if (options.uri.host == 'manga-leko.net' &&
              options.uri.path == '/tag/manga-one/page/3/') {
            handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: 404,
                data: 'not found',
              ),
            );
            return;
          }
          handler.next(options);
        },
      ),
    );

    final chapters = await _provider(stub.dio).getMangaChapters(
      'https://animewitcher.com/manga/m1',
    );

    expect(chapters.map((chapter) => chapter.number), <double?>[30, 29, 28]);
    expect(
      archiveRequests.any(
        (uri) =>
            uri.host == 'manga-leko.net' &&
            uri.path == '/tag/manga-one/',
      ),
      isTrue,
    );
  });

  test(
    'reader falls back to MangaLek when Firestore chapter has no pages',
    () async {
      final stub = _stubDio();
      stub.dio.interceptors.insert(
        0,
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.uri.host.contains('firestore') &&
                options.uri.path.endsWith(
                  '/documents/manga_list/m1/chapters_summery/summery',
                )) {
              handler.resolve(
                Response<dynamic>(
                  requestOptions: options,
                  statusCode: 200,
                  data: <String, dynamic>{
                    'fields': <String, dynamic>{
                      'chapters': <String, dynamic>{
                        'arrayValue': <String, dynamic>{
                          'values': <Map<String, dynamic>>[
                            _mapField(<String, dynamic>{
                              'doc_id': _stringField('c1'),
                              'name': _stringField('الفصل 1'),
                            }),
                          ],
                        },
                      },
                    },
                  },
                ),
              );
              return;
            }
            handler.next(options);
          },
        ),
      );

      final provider = _provider(stub.dio);
      final chapter = (await provider.getMangaChapters(
        'https://animewitcher.com/manga/m1',
      )).single;

      expect(
        chapter.url,
        'https://animewitcher.com/manga/m1/chapters/c1',
      );

      final pages = await provider.getMangaChapterPages(
        'https://animewitcher.com/manga/m1',
        chapter,
      );

      expect(
        pages.map((page) => page.imageUrl),
        <String>[
          'https://cdn.example/1.webp',
          'https://cdn.example/2.webp',
        ],
      );
      expect(
        pages.first.headers['Referer'],
        'https://mangalik.net/manga/manga-one/chapter-1/',
      );
    },
  );

  test('chapters and pages follow AnimeWitcher MangaLek pointer', () async {
    final stub = _stubDio();
    final provider = _provider(stub.dio);

    final chapters = await provider.getMangaChapters(
      'https://animewitcher.com/manga/m1',
    );
    expect(chapters, hasLength(1));
    expect(chapters.single.name, 'الفصل 1');

    final pages = await provider.getMangaChapterPages(
      'https://animewitcher.com/manga/m1',
      chapters.single,
    );
    expect(pages, hasLength(2));
    expect(pages.first.imageUrl, 'https://cdn.example/1.webp');
    expect(
      pages.first.headers['Referer'],
      'https://mangalik.net/manga/manga-one/chapter-1/',
    );
  });

  test('download refresh replaces stale Firestore page URLs with live source', () async {
    final stub = _stubDio();
    stub.dio.interceptors.insert(
      0,
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.uri.host.contains('firestore') &&
              options.uri.path.endsWith(
                '/documents/manga_list/m1/chapters/c1/summary_pages/summery',
              )) {
            handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: 200,
                data: <String, dynamic>{
                  'fields': <String, dynamic>{
                    'pages': <String, dynamic>{
                      'arrayValue': <String, dynamic>{
                        'values': <Map<String, dynamic>>[
                          _mapField(<String, dynamic>{
                            'image_url': _stringField(
                              'https://cdn.example/stale.webp',
                            ),
                            'order': _intField(1),
                          }),
                        ],
                      },
                    },
                  },
                },
              ),
            );
            return;
          }
          handler.next(options);
        },
      ),
    );

    final provider = _provider(stub.dio);
    const chapter = MangaChapter(
      id: 'c1',
      mangaId: 'm1',
      url: 'https://animewitcher.com/manga/m1/chapters/c1',
      name: 'الفصل 1',
      number: 1,
    );

    final cached = await provider.getMangaChapterPages(
      'https://animewitcher.com/manga/m1',
      chapter,
    );
    final refreshed = await provider.refreshMangaChapterPages(
      'https://animewitcher.com/manga/m1',
      chapter,
    );

    expect(cached.single.imageUrl, 'https://cdn.example/stale.webp');
    expect(refreshed.first.imageUrl, 'https://cdn.example/1.webp');
    expect(
      refreshed.first.headers['Referer'],
      'https://mangalik.net/manga/manga-one/chapter-1/',
    );
  });

  test('refreshMangaChapterPages bypasses the cached CDN page list', () async {
    final stub = _stubDio();
    var chapterLoads = 0;
    stub.dio.interceptors.insert(
      0,
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.uri.host == 'mangalik.net' &&
              options.uri.path == '/manga/manga-one/chapter-1/') {
            chapterLoads++;
            handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: 200,
                data:
                    '<div class="reading-content">'
                    '<div class="page-break"><img data-src="https://cdn.example/fresh-' +
                    chapterLoads.toString() +
                    '.webp"></div></div>',
              ),
            );
            return;
          }
          handler.next(options);
        },
      ),
    );

    final provider = _provider(stub.dio);
    final chapters = await provider.getMangaChapters(
      'https://animewitcher.com/manga/m1',
    );
    final first = await provider.getMangaChapterPages(
      'https://animewitcher.com/manga/m1',
      chapters.single,
    );
    final cached = await provider.getMangaChapterPages(
      'https://animewitcher.com/manga/m1',
      chapters.single,
    );
    final refreshed = await provider.refreshMangaChapterPages(
      'https://animewitcher.com/manga/m1',
      chapters.single,
    );

    expect(first.single.imageUrl, 'https://cdn.example/fresh-1.webp');
    expect(cached.single.imageUrl, 'https://cdn.example/fresh-1.webp');
    expect(refreshed.single.imageUrl, 'https://cdn.example/fresh-2.webp');
    expect(chapterLoads, 2);
  });

}
