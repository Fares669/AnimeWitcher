import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/providers/witanime_provider.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

String _card(String href, String title) =>
    '<a href="$href"><img src="/posters/test.jpg" alt="$title"><h3>$title</h3></a>';

void main() {
  test('displayed filter labels map to the Witanime query values', () async {
    late Uri request;
    final provider = WitanimeProvider((uri, {cancelToken}) async {
      request = uri;
      return '<main></main>';
    });
    final options = await provider.getSearchFilterOptions();
    expect(options.studios, contains('A-1 Pictures'));
    expect(options.versions, contains('مدبلج'));
    expect(options.singleSelection, isTrue);
    await provider.searchPage(
      '',
      const ProviderSearchFilters(
        statuses: {'مستمر'},
        countries: {'اليابان'},
        studios: {'A-1 Pictures'},
        sources: {'رواية خفيفة'},
        versions: {'مدبلج'},
        genres: {'أكشن'},
        sort: 'name_asc',
      ),
    );
    expect(request.queryParameters, {
      'status': 'ongoing',
      'country': 'JP',
      'studio': 'a-1-pictures',
      'source': 'Light Novel',
      'version': 'dub',
      'genres[]': 'action',
      'sort': 'A-Z',
    });
  });

  test('search follows same-site pages and only returns unique results', () async {
    final requests = <Uri>[];
    final token = CancelToken();
    final provider = WitanimeProvider((uri, {cancelToken}) async {
      expect(cancelToken, same(token));
      requests.add(uri);
      if (uri.queryParameters['page'] == '2') {
        return '<main>${_card('/anime/first/', 'First')}'
            '${_card('/movie/first', 'Film')}'
            '<a rel="next" href="https://outside.test/search?page=3">التالي</a></main>';
      }
      return '<main>${_card('/anime/first', 'First')}'
          '<aside>${_card('/anime/excluded', 'Ranking')}</aside>'
          '<section><h2>قد يعجبك أيضًا</h2>${_card('/anime/unrelated', 'Suggested')}</section>'
          '<a rel="next" href="?page=2">التالي</a></main>';
    });

    final result = await provider.searchPage(
      'أنمي & فيلم',
      const ProviderSearchFilters(),
      limit: 2,
      cancelToken: token,
    );
    expect(requests.map((uri) => uri.path), ['/search', '/search']);
    expect(requests.map((uri) => uri.queryParameters['q']), [
      'أنمي & فيلم',
      'أنمي & فيلم',
    ]);
    expect(result.items.map((item) => item.title), ['First', 'Film']);
    expect(result.items.map((item) => item.contentType), [
      MultimediaContentType.anime,
      MultimediaContentType.movie,
    ]);
    expect(result.nextOffset, 2);
    expect(result.hasMore, isFalse);
  });

  test(
    'browse preserves repeated genres while reading the next page',
    () async {
      final requests = <Uri>[];
      final provider = WitanimeProvider((uri, {cancelToken}) async {
        requests.add(uri);
        return uri.path.endsWith('/2')
            ? '<main>${_card('/anime/next', 'Next')}</main>'
            : '<main>${_card('/anime/first', 'First')}'
                  '<a rel="next" href="/browse/page/2">التالي</a></main>';
      });

      const filters = ProviderSearchFilters(
        statuses: {'ongoing'},
        genres: {'action', 'mystery'},
        sort: 'Top Rated',
      );
      final first = await provider.searchPage('', filters, limit: 1);
      final second = await provider.searchPage(
        '',
        filters,
        offset: first.nextOffset,
        limit: 1,
      );

      expect(first.hasMore, isTrue);
      expect(second.items.single.title, 'Next');
      expect(second.hasMore, isFalse);
      expect(requests.last.queryParametersAll['genres[]'], [
        'action',
        'mystery',
      ]);
      expect(requests.last.queryParameters['status'], 'ongoing');
      expect(requests.last.queryParameters['sort'], 'Top Rated');
    },
  );

  test('details keep movie and series identities and fractional episode URLs', () async {
    final requests = <Uri>[];
    final provider = WitanimeProvider((uri, {cancelToken}) async {
      requests.add(uri);
      if (uri.path == '/movie/sample') {
        return '<main><h1>Film</h1><a href="/watch/movie/sample">شاهد الآن</a>'
            '<a href="/watch/unrelated/2">Other</a></main>';
      }
      return '''
        <script type="application/ld+json">{"@type":"TVSeries","name":"Work",
          "alternateName":"Alternate","datePublished":"2026-01-01",
          "genre":["Action"],"aggregateRating":{"ratingValue":8.5}}</script>
        <main><h1>Work</h1><img src="/posters/sample.jpg">
          <div><span>الاستوديو</span><p>Studio</p></div>
          <div><span>المدة</span><p>٢٤ دقيقة</p></div>
          <div><span>التصنيف العمري</span><p>PG-13</p></div>
          <div data-episode-list>
            <a href="/watch/sample/1">الحلقة 1</a>
            <a href="/watch/sample/1.5?ref=ignored">الحلقة 1.5</a>
            <a href="/watch/sample/1.5">Duplicate</a>
            <a href="/watch/sample/special">الحلقة الخاصة</a>
            <a href="https://outside.test/watch/sample/3">Other host</a>
          </div>
          <section><h2>ذات صلة</h2>${_card('/movie/sample', 'Film')}</section>
          <section><h2>قد يعجبك أيضًا</h2>${_card('/anime/other', 'Other')}</section>
        </main>
      ''';
    });

    final series = await provider.getDetails('/watch/sample/1.5');
    final movie = await provider.getDetails('/watch/movie/sample');
    expect(requests.map((uri) => uri.path), ['/anime/sample', '/movie/sample']);
    expect(series.provider, WitanimeProvider.id);
    expect(series.year, 2026);
    expect(series.score, 8.5);
    expect(series.duration, 24);
    expect(series.contentRating, 'PG-13');
    expect(series.syncData?['awStudio'], 'Studio');
    expect(series.episodes!.map((e) => Uri.parse(e.url).path).toSet(), {
      '/watch/sample/1',
      '/watch/sample/1.5',
      '/watch/sample/special',
    });
    expect(
      series.episodes!.singleWhere((e) => e.url.endsWith('/1.5')).serverNumber,
      '1.5',
    );
    expect(series.related?.single.contentType, MultimediaContentType.movie);
    expect(series.recommendations?.single.title, 'Other');
    expect(
      movie.episodes?.single.url,
      'https://witanime.site/watch/movie/sample',
    );
    await expectLater(
      provider.getDetails('https://outside.test/anime/sample'),
      throwsFormatException,
    );
    expect(requests, hasLength(2));
  });

  test('home and weekly schedule keep individual shelves separate', () async {
    final provider = WitanimeProvider(
      (uri, {cancelToken}) async => uri.path == '/schedule'
          ? '<main><section><h2>السبت</h2>${_card('/anime/saturday', 'Saturday')}</section>'
                '<section><h2>الأحد</h2>${_card('/anime/sunday', 'Sunday')}</section></main>'
          : '<main><section aria-roledescription="carousel">${_card('/anime/hero', 'Hero')}</section>'
                '<section><h2>الأكثر مشاهدة</h2>${_card('/anime/popular', 'Popular')}</section>'
                '<section><h2>أحدث الحلقات</h2>${_card('/watch/new/7', 'Episode')}</section>'
                '<section><h2>أحدث الأفلام</h2>${_card('/movie/new', 'Movie')}</section></main>',
    );
    final home = await provider.getHome();
    expect(home.keys.toList(), [
      'Trending',
      'أحدث الحلقات',
      'الأكثر مشاهدة',
      'أحدث الأفلام',
    ]);
    expect(home['Trending']?.single.title, 'Hero');
    expect(home['أحدث الحلقات']?.single.episodeBadge, 'الحلقة 7');
    expect(
      home['أحدث الحلقات']?.single.syncData?[WitanimeProvider.watchUrlKey],
      'https://witanime.site/watch/new/7',
    );
    expect(home['أحدث الأفلام']?.single.title, 'Movie');
    expect(
      (await provider.getBroadcastSchedulePage('السبت')).items.single.title,
      'Saturday',
    );
  });

  test(
    'a non-catalog response is an error instead of an empty result',
    () async {
      final provider = WitanimeProvider(
        (uri, {cancelToken}) async => '<title>Just a moment</title>',
      );
      await expectLater(provider.search('أنمي'), throwsFormatException);
    },
  );

  test(
    'seasons and upcoming use the documented browse filter values',
    () async {
      final requests = <Uri>[];
      final provider = WitanimeProvider((uri, {cancelToken}) async {
        requests.add(uri);
        if (uri.path == '/seasonal') {
          return '<main><h1>أنميات خريف ٢٠٢٦</h1></main>';
        }
        return '<main><select name="year"><option value="2026">2026</option>'
            '</select>${_card('/anime/sample', 'Sample')}</main>';
      });
      final seasons = await provider.getSeasonConfig();
      expect(seasons.past, 'صيف عام 2026');
      expect(seasons.current, 'خريف عام 2026');
      expect(seasons.next, 'شتاء عام 2027');
      expect(await provider.getAllSeasons(), hasLength(4));
      expect(
        (await provider.getSeasonPage(seasons.current)).items,
        hasLength(1),
      );
      expect(requests.last.queryParameters, {'season': 'fall', 'year': '2026'});
      expect(
        (await provider.getUpcomingPage()).items.single.status,
        ShowStatus.upcoming,
      );
      expect(requests.last.queryParameters, {'status': 'upcoming'});
    },
  );

  test(
    'home sections paginate, and details extract country, trailers, and 1000+ episodes',
    () async {
      final requestedPaths = <String>[];
      final provider = WitanimeProvider((uri, {cancelToken}) async {
        requestedPaths.add('${uri.path}?${uri.query}');
        if (uri.path == '/movies') {
          return '<main>${_card('/movie/m1', 'Movie 1')}</main>';
        }
        if (uri.path == '/browse') {
          return '<main>${_card('/anime/top1', 'Top 1')}</main>';
        }
        if (uri.path == '/seasonal') {
          return '<main>${_card('/anime/seas1', 'Season 1')}</main>';
        }
        if (uri.path == '/anime/long-series') {
          final eps = [
            for (var i = 1; i <= 1050; i++)
              '<a href="/watch/long-series/$i">الحلقة $i</a>',
          ].join();
          return '''
            <main>
              <h1>Long Series</h1>
              <div><span>البلد</span><p>اليابان</p></div>
              <iframe src="https://www.youtube.com/embed/abc123"></iframe>
              <div data-episode-list>$eps</div>
            </main>
          ''';
        }
        return '<main></main>';
      });

      final moviesPage = await provider.getHomeSectionPage('أحدث الأفلام');
      expect(moviesPage.items.single.title, 'Movie 1');
      final mostViewed = await provider.getHomeSectionPage('أكثر الأنميات مشاهدة');
      expect(mostViewed.items.single.title, 'Top 1');
      expect(requestedPaths.last, contains('Most+Viewed'));
      final seasonal = await provider.getHomeSectionPage('أشهر أنميات الموسم');
      expect(seasonal.items.single.title, 'Season 1');

      final details = await provider.getDetails('/anime/long-series');
      expect(details.syncData?['awCountry'], 'اليابان');
      expect(
        details.trailers?.single.url,
        'https://www.youtube.com/embed/abc123',
      );
      expect(details.episodes?.length, 1050);
      expect(details.episodes?.last.episode, 1050);
    },
  );

  test(
    'details and cards extract score from SVG star badges without reading related card scores',
    () async {
      final provider = WitanimeProvider((uri, {cancelToken}) async {
        if (uri.path == '/anime/tempal-item-no-chikara') {
          return '''
            <main>
              <div>
                <img src="/posters/tempal.jpg">
                <div>
                  <h1><span>TEMPAL ~Item no Chikara~</span></h1>
                  <div class="mb-4 flex flex-wrap items-center gap-2">
                    <span>TV</span>
                    <span>مستمر</span>
                    <span dir="ltr"><svg></svg> 7.70</span>
                  </div>
                </div>
              </div>
              <section>
                <h2>قد يعجبك أيضًا</h2>
                <a href="/anime/other">
                  <img src="/posters/other.jpg" alt="Other">
                  <span><svg></svg> 8.1</span>
                  <h3>Other</h3>
                </a>
              </section>
            </main>
          ''';
        }
        return '''
          <main>
            <h1>No Score Series</h1>
            <section>
              <h2>قد يعجبك أيضًا</h2>
            </section>
            <a href="/anime/no-score-series">
              <img src="/posters/other.jpg" alt="No Score">
              <h3>No Score</h3>
            </a>
          </main>
        ''';
      });

      final details = await provider.getDetails('/anime/tempal-item-no-chikara');
      expect(details.score, 7.7);
      expect(details.recommendations?.single.score, 8.1);

      final fallbackDetails = await provider.getDetails('/anime/no-score-series');
      expect(fallbackDetails.score, isNull);
    },
  );

  test(
    'details prefer full HTML synopsis over truncated JSON-LD description',
    () async {
      final provider = WitanimeProvider((uri, {cancelToken}) async {
        if (uri.path == '/anime/full-story') {
          return '''
            <script type="application/ld+json">{"@type":"TVSeries","name":"Full Story",
              "description":"قصة مختصرة من JSON-LD..."}</script>
            <main>
              <h1>Full Story</h1>
              <div>
                <p class="mb-6 text-sm leading-relaxed text-neutral-300">الفقرة الأولى كاملة.<br>تتمة السطر الثاني.</p>
                <p class="mb-6 text-sm leading-relaxed text-neutral-300">الفقرة الثانية كاملة.</p>
              </div>
            </main>
          ''';
        }
        return '''
          <script type="application/ld+json">{"@type":"TVSeries","name":"Fallback Story",
            "description":"قصة من JSON-LD عند غياب HTML."}</script>
          <main><h1>Fallback Story</h1></main>
        ''';
      });

      final full = await provider.getDetails('/anime/full-story');
      expect(
        full.description,
        'الفقرة الأولى كاملة.\nتتمة السطر الثاني.\n\nالفقرة الثانية كاملة.',
      );

      final fallback = await provider.getDetails('/anime/fallback-story');
      expect(fallback.description, 'قصة من JSON-LD عند غياب HTML.');
    },
  );
}
