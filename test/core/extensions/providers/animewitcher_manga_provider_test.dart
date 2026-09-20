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
        if (_isAlgolia(options.uri) &&
            options.uri.path.endsWith('/indexes/manga_views_desc/query')) {
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: <String, dynamic>{
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
}
