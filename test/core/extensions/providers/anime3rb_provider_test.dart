import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/providers/anime3rb_provider.dart';
import 'package:animewitcher/core/extensions/providers/anime3rb_transport.dart';
import 'package:animewitcher/core/services/anizip_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

String _videoCard(String href, String title, String epNum) => '''
<a href="$href" class="video-card">
  <div class="poster"><img src="https://images.anime3rb.com/ep.jpg" alt="$title"></div>
  <h3 class="title-name">$title</h3>
  <p class="number">الحلقة $epNum</p>
</a>
''';

String _titleCard(String slug, String title, {String? score, String? epBadge}) => '''
<div class="title-card" data-title="$slug">
  <a href="https://anime3rb.com/titles/$slug">
    <img src="https://images.anime3rb.com/$slug.jpg" alt="$title">
  </a>
  <a class="details" href="https://anime3rb.com/titles/$slug">
    <h2 class="title-name">$title</h2>
    <div class="genres"><span>أكشن</span><span>مغامرة</span></div>
    <p>
      ${score == null ? '' : '<span class="badge">التقييم $score</span>'}
      ${epBadge == null ? '' : '<span class="badge">$epBadge</span>'}
      <span class="badge">خريف 1999</span>
    </p>
    <p class="synopsis">ملخص تجريبي للأنمي.</p>
  </a>
</div>
''';

void main() {
  test('getHome parses latest, pinned (excluding clones), recently added, top rated, and movies', () async {
    final provider = Anime3rbProvider((uri, {headers = const {}, cancelToken}) async {
      if (uri.path == '/titles/list' && uri.queryParameters['sort_by'] == 'rate') {
        return '<html><body><div class="titles-list">${_titleCard('frieren', 'Frieren', score: '9.3')}</div></body></html>';
      }
      if (uri.path == '/titles/list/movie') {
        return '<html><body><div class="titles-list">${_titleCard('your-name', 'Your Name', epBadge: 'حلقة واحدة')}</div></body></html>';
      }
      return '''
<html><body>
  <section>
    <h2>الأنميات المثبتة</h2>
    <div class="glide">
      <div class="glide__slide glide__slide--clone">${_videoCard('/episode/clone-show/1', 'Clone Show', '1')}</div>
      <div class="glide__slide">${_videoCard('/episode/one-piece/1180', 'One Piece', '1180')}</div>
    </div>
  </section>
  <section>
    <h3>أحدث الحلقات</h3>
    <div id="videos">
      ${_videoCard('/episode/bleach/12', 'Bleach', '12')}
    </div>
  </section>
  <section>
    <h3>آخر الأنميات المضافة</h3>
    <div class="glide">
      <div class="glide__slide glide__slide--clone">${_titleCard('clone-title', 'Clone Title')}</div>
      <div class="glide__slide">${_titleCard('dandadan', 'Dandadan', score: '8.5', epBadge: '12 حلقة')}</div>
    </div>
  </section>
</body></html>
''';
    });

    final home = await provider.getHome();
    expect(home.keys, containsAll([
      'أحدث الحلقات',
      'الأنميات المثبتة',
      'آخر الأنميات المضافة',
      'الأعلى تقييماً',
      'أفلام الأنمي',
    ]));

    final latest = home['أحدث الحلقات']!;
    expect(latest, hasLength(1));
    expect(latest.first.url, 'https://anime3rb.com/titles/bleach');
    expect(latest.first.syncData?[Anime3rbProvider.watchUrlKey], 'https://anime3rb.com/episode/bleach/12');
    expect(latest.first.episodeBadge, 'الحلقة 12');

    final pinned = home['الأنميات المثبتة']!;
    expect(pinned.map((e) => e.title), ['One Piece']);

    final recent = home['آخر الأنميات المضافة']!;
    expect(recent.map((e) => e.title), ['Dandadan']);
    expect(recent.first.score, 8.5);
    expect(recent.first.year, 1999);
    expect(recent.first.tags, ['أكشن', 'مغامرة']);
  });

  test('getHomeSectionPage paginates أحدث الحلقات via /?page=N with X-Requested-With', () async {
    late Uri requestedUri;
    late Map<String, String> requestedHeaders;
    final provider = Anime3rbProvider((uri, {headers = const {}, cancelToken}) async {
      requestedUri = uri;
      requestedHeaders = headers;
      return _videoCard('/episode/naruto/500', 'Naruto', '500');
    });

    final page = await provider.getHomeSectionPage('أحدث الحلقات', offset: 30, limit: 20);
    expect(requestedUri.toString(), 'https://anime3rb.com/?page=2');
    expect(requestedHeaders['X-Requested-With'], 'XMLHttpRequest');
    expect(page.items.map((e) => e.title), ['Naruto']);
  });

  test('searchPage maps query, filters, single genre, and pagination cleanly', () async {
    final requests = <Uri>[];
    final token = CancelToken();
    final provider = Anime3rbProvider((uri, {headers = const {}, cancelToken}) async {
      if (uri.path == '/search') {
        expect(cancelToken, same(token));
      }
      requests.add(uri);
      if (uri.path == '/search' && uri.queryParameters['page'] == '2') {
        return '<html><body><div class="titles-list">${_titleCard('one-piece-film-red', 'One Piece Film Red')}</div></body></html>';
      }
      if (uri.path == '/search') {
        return '''
<html><body>
  <div class="titles-list">${_titleCard('one-piece', 'One Piece')}</div>
  <nav aria-label="Pagination Navigation"><a rel="next" href="?q=one+piece&page=2">Next</a></nav>
</body></html>
''';
      }
      return '<html><body><div class="titles-list">${_titleCard('naruto', 'Naruto')}</div></body></html>';
    });

    final options = await provider.getSearchFilterOptions();
    expect(options.genres, containsAll(['أكشن', 'تعليمية']));
    expect(options.types, containsAll(['مسلسل (TV)', 'فيلم (Movie)']));
    expect(options.singleSelection, isFalse);

    final searchRes = await provider.searchPage(
      'one piece',
      const ProviderSearchFilters(sort: 'favorites'),
      limit: 2,
      cancelToken: token,
    );
    expect(requests.first.path, '/search');
    expect(requests.first.queryParameters['q'], 'one piece');
    expect(requests.first.queryParameters['sort_by'], 'rate');
    expect(requests.first.queryParameters['sort_dir'], 'desc');
    expect(searchRes.items.map((e) => e.title), ['One Piece', 'One Piece Film Red']);
    expect(searchRes.hasMore, isFalse);

    await provider.searchPage(
      '',
      const ProviderSearchFilters(genres: {'أكشن'}),
    );
    expect(requests.last.path, '/genre/action');

    await provider.searchPage(
      '',
      const ProviderSearchFilters(
        types: {'فيلم (Movie)'},
        statuses: {'مستمر'},
        genres: {'أكشن', 'مغامرة'},
        ageRatings: {'للجميع G'},
        studios: {'Toei Animation'},
        years: {'2020', '2024'},
        sort: 'name_asc',
      ),
    );
    expect(requests.last.path, '/titles/list/movie');
    expect(requests.last.queryParameters, {
      'genres': 'action,adventure',
      'status': 'running',
      'age': 'g-all-ages',
      'c': 'toei-animation',
      'year': '2020-2024',
      'sort_by': 'name',
      'sort_dir': 'asc',
    });
  });

  test('getDetails normalizes episode URLs to work URL and parses metadata, episodes, related, and trailers', () async {
    late Uri fetched;
    final provider = Anime3rbProvider((uri, {headers = const {}, cancelToken}) async {
      fetched = uri;
      return '''
<html>
<head>
  <meta property="og:image" content="https://images.anime3rb.com/one-piece.jpg">
  <script type="application/ld+json">
  {
    "@type": "TVSeries",
    "name": "One Piece",
    "datePublished": "1999-10-20",
    "aggregateRating": {"ratingValue": "8.72"}
  }
  </script>
</head>
<body>
  <h1><span dir="ltr">One Piece</span> <span class="font-light">( مسلسل )</span></h1>
  <h2 class="lg:text-meta">ون بيس</h2>
  <img src="https://images.anime3rb.com/one-piece.jpg" alt="بوستر One Piece">
  <div x-data="{summary: false}">
    <div x-show="! summary"><p>قصة لوفي وطاقم قبعة القش.</p></div>
  </div>
  <div wire:name="genres">
    <a href="https://anime3rb.com/genre/adventure" class="btn btn-md btn-link genre">مغامرة <span class="badge">1446</span></a>
    <a href="https://anime3rb.com/genre/drama" class="btn btn-md btn-link genre">دراما <span class="badge">1416</span></a>
  </div>
  <a href="https://anime3rb.com/genre/action">أكشن</a>
  <a href="https://anime3rb.com/genre/fantasy">خيال</a>
  <a href="https://anidb.net/anime/69">anidb</a>
  <a href="https://myanimelist.net/anime/21">myanimelist</a>
  <table>
    <tr><td>الحالة:</td><td>قيد البث</td></tr>
    <tr><td>إصدار:</td><td title="1999-10-20">خريف 1999</td></tr>
    <tr><td>الاستديو:</td><td><a href="https://anime3rb.com/c/studio/toei-animation">Toei Animation</a></td></tr>
  </table>
  <iframe data-src="https://www.youtube.com/embed/abc123"></iframe>
  <div class="video-list">
    <a href="https://anime3rb.com/episode/one-piece/1">
      <img src="https://images.anime3rb.com/ep1.jpg">
      <div class="video-data"><span>الحلقة 1</span><p>أنا لوفي!</p></div>
    </a>
    <a href="https://anime3rb.com/episode/one-piece/1180">
      <img src="https://images.anime3rb.com/ep1180.jpg">
      <div class="video-data"><span>الحلقة 1180</span><p>نهاية الآرك</p></div>
    </a>
  </div>
  <section>
    <h3>أعمال ذات صلة</h3>
    <div class="glide__slide">${_titleCard('one-piece-film-red', 'One Piece Film: Red')}</div>
  </section>
  <section>
    <h3>أنميات مشابهة مقترحة</h3>
    <div class="glide__slide">${_titleCard('fairy-tail', 'Fairy Tail')}</div>
  </section>
</body>
</html>
''';
    });

    final item = await provider.getDetails('https://anime3rb.com/episode/one-piece/1180');
    expect(fetched.toString(), 'https://anime3rb.com/titles/one-piece');
    expect(item.provider, Anime3rbProvider.id);
    expect(item.title, 'One Piece');
    expect(item.url, 'https://anime3rb.com/titles/one-piece');
    expect(item.status, ShowStatus.ongoing);
    expect(item.year, 1999);
    expect(item.score, 8.72);
    expect(item.syncData?['awStudio'], 'Toei Animation');
    expect(item.syncData?['awEnglishTitle'], 'ون بيس');
    expect(item.syncData?['malId'], '21');
    expect(item.syncData?['anidbId'], '69');
    expect(item.trailers?.map((t) => t.url), ['https://www.youtube.com/embed/abc123']);
    expect(item.episodes, hasLength(2));
    expect(item.episodes!.first.episode, 1);
    expect(item.episodes!.first.serverName, 'الحلقة 1');
    expect(item.episodes!.first.name, 'أنا لوفي!');
    expect(item.episodes!.last.episode, 1180);
    expect(item.episodes!.last.serverName, 'الحلقة 1180');
    expect(item.episodes!.last.name, 'نهاية الآرك');
    expect(item.tags, ['أكشن', 'خيال']);
    expect(item.related?.map((e) => e.title), ['One Piece Film: Red']);
    expect(item.recommendations?.map((e) => e.title), ['Fairy Tail']);
  });

  test('getDetails caches details and avoids a second request on getEpisodes until invalidated', () async {
    var detailFetches = 0;
    final provider = Anime3rbProvider((uri, {headers = const {}, cancelToken}) async {
      detailFetches++;
      return '''
<html><body>
  <h1><span dir="ltr">Naruto</span></h1>
  <div class="video-list">
    <a href="https://anime3rb.com/episode/naruto/1">
      <div class="video-data"><span>الحلقة 1</span><p>Enter Naruto!</p></div>
    </a>
  </div>
</body></html>
''';
    });

    final item = await provider.getDetails('https://anime3rb.com/titles/naruto');
    final episodes = await provider.getEpisodes('https://anime3rb.com/titles/naruto');
    expect(detailFetches, 1);
    expect(item.episodes, hasLength(1));
    expect(episodes, hasLength(1));

    provider.invalidateDetailCaches('https://anime3rb.com/titles/naruto');
    await provider.getEpisodes('https://anime3rb.com/titles/naruto');
    expect(detailFetches, 2);
  });

  test('getEpisodeMetadata enriches Anime3rb episodes from AniZip using extracted MAL ID (including long-running absolute episodes) and respects toggle', () async {
    var detailFetches = 0;
    var aniZipFetches = 0;
    var aniZipEnabled = true;

    final aniZipDio = Dio();
    aniZipDio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          aniZipFetches++;
          expect(options.path, '/mappings');
          expect(options.queryParameters['mal_id'], '21');
          handler.resolve(
            Response<Map<String, dynamic>>(
              requestOptions: options,
              statusCode: 200,
              data: <String, dynamic>{
                'episodes': <String, dynamic>{
                  '1': <String, dynamic>{
                    'episodeNumber': 1,
                    'absoluteEpisodeNumber': 1,
                    'image': 'https://artworks.thetvdb.com/ep1-still.jpg',
                  },
                  '1180': <String, dynamic>{
                    'seasonNumber': 23,
                    'episodeNumber': 25,
                    'absoluteEpisodeNumber': 1180,
                    'image': 'https://artworks.thetvdb.com/ep1180-still.jpg',
                  },
                },
              },
            ),
          );
        },
      ),
    );

    final provider = Anime3rbProvider(
      (uri, {headers = const {}, cancelToken}) async {
        detailFetches++;
        return '''
<html><body>
  <h1><span dir="ltr">One Piece</span></h1>
  <a href="https://myanimelist.net/anime/21">myanimelist</a>
  <div class="video-list">
    <a href="https://anime3rb.com/episode/one-piece/1">
      <img src="https://images.anime3rb.com/fallback.jpg">
      <div class="video-data"><span>الحلقة 1</span><p>أنا لوفي!</p></div>
    </a>
    <a href="https://anime3rb.com/episode/one-piece/1180">
      <img src="https://images.anime3rb.com/fallback.jpg">
      <div class="video-data"><span>الحلقة 1180</span><p>نهاية الآرك</p></div>
    </a>
  </div>
</body></html>
''';
      },
      useAniZipEpisodeImages: () => aniZipEnabled,
      aniZip: AniZipService(dio: aniZipDio),
    );

    final enriched = await provider.getEpisodeMetadata(
      'https://anime3rb.com/titles/one-piece',
    );
    expect(detailFetches, 1);
    expect(aniZipFetches, 1);
    expect(enriched.map((e) => e.posterUrl).toList(), [
      'https://artworks.thetvdb.com/ep1-still.jpg',
      'https://artworks.thetvdb.com/ep1180-still.jpg',
    ]);
    // Cached on second call without hitting AniZip or Anime3rb again.
    await provider.getEpisodeMetadata('https://anime3rb.com/titles/one-piece');
    expect(detailFetches, 1);
    expect(aniZipFetches, 1);

    // Turning off AniZip episode images skips enrichment just like AnimeWitcher.
    aniZipEnabled = false;
    final disabled = await provider.getEpisodeMetadata(
      'https://anime3rb.com/titles/one-piece',
    );
    expect(disabled, isEmpty);
  });

  test('searchPage uses Livewire search component and parses simple-title-card results when transport is attached', () async {
    var postCalls = 0;
    final transport = _TestSearchTransport(
      onGet: (uri) async {
        expect(uri.path, anyOf('/', ''));
        return const Anime3rbHttpResponse(
          statusCode: 200,
          body:
              '<html><body>'
              '<script src="/livewire/livewire.min.js" data-csrf="csrf-abc" data-update-uri="https://anime3rb.com/livewire-test/update"></script>'
              '<div wire:name="search" wire:snapshot=\'{"data":{"query":"","ready":false}}\'></div>'
              '</body></html>',
        );
      },
      onPost: (uri, body, headers) async {
        postCalls++;
        expect(uri.toString(), 'https://anime3rb.com/livewire-test/update');
        expect(headers['X-Livewire'], '1');
        expect(body.toString(), contains('"query":"solo"'));
        return const Anime3rbHttpResponse(
          statusCode: 200,
          body:
              '{"components":[{"snapshot":"{\\"data\\":{\\"query\\":\\"solo\\",\\"ready\\":true}}","effects":{"html":"<div>'
              '<a href=\\"https://anime3rb.com/titles/solo-leveling\\" class=\\"simple-title-card\\">'
              '<img src=\\"https://images.anime3rb.com/solo.jpg\\">'
              '<h4>Solo Leveling</h4>'
              '<h5>سولو ليفيلينج</h5>'
              '<span class=\\"badge\\">8.30</span>'
              '<span class=\\"badge\\">12 حلقة</span>'
              '<span class=\\"badge\\">2024</span>'
              '</a></div>"}}]}',
        );
      },
    );

    final provider = Anime3rbProvider.withTransport(transport);
    final res = await provider.searchPage(
      'solo',
      const ProviderSearchFilters(sort: 'favorites'),
    );
    expect(postCalls, 1);
    expect(res.items, hasLength(1));
    expect(res.items.single.title, 'Solo Leveling');
    expect(res.items.single.url, 'https://anime3rb.com/titles/solo-leveling');
    expect(res.items.single.score, 8.3);
    expect(res.items.single.year, 2024);
    expect(res.items.single.episodeBadge, '12 حلقة');
    expect(res.items.single.syncData?['awEnglishTitle'], 'سولو ليفيلينج');
  });
}

class _TestSearchTransport implements Anime3rbTransport {
  _TestSearchTransport({required this.onGet, required this.onPost});

  final Future<Anime3rbHttpResponse> Function(Uri uri) onGet;
  final Future<Anime3rbHttpResponse> Function(
    Uri uri,
    Object? body,
    Map<String, String> headers,
  )
  onPost;

  @override
  Future<Anime3rbHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const {},
    bool followRedirects = true,
    bool inspectMedia = false,
    CancelToken? cancelToken,
    String operation = 'get',
  }) => onGet(uri);

  @override
  Future<Anime3rbHttpResponse> post(
    Uri uri, {
    Object? body,
    Map<String, String> headers = const {},
    bool followRedirects = true,
    CancelToken? cancelToken,
    String operation = 'post',
  }) => onPost(uri, body, headers);

  @override
  Future<Anime3rbHttpResponse> put(
    Uri uri, {
    Object? body,
    Map<String, String> headers = const {},
    bool followRedirects = true,
    CancelToken? cancelToken,
    String operation = 'put',
  }) => Future.value(const Anime3rbHttpResponse(statusCode: 404, body: ''));

  @override
  Future<Anime3rbHttpResponse> delete(
    Uri uri, {
    Object? body,
    Map<String, String> headers = const {},
    bool followRedirects = true,
    CancelToken? cancelToken,
    String operation = 'delete',
  }) => Future.value(const Anime3rbHttpResponse(statusCode: 404, body: ''));

  @override
  Future<String> fetchHtml(
    Uri uri, {
    Map<String, String> headers = const {},
    CancelToken? cancelToken,
    String operation = 'catalog',
  }) async => (await get(uri, headers: headers)).body;

  @override
  void close({bool force = false}) {}
}
