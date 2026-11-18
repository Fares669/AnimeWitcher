import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;

import '../../domain/entity/multimedia_item.dart';
import '../../utils/digit_normalization.dart';
import '../base_provider.dart';

/// The caller supplies the catalog transport once access is configured.
class WitanimeProvider extends AnimeWitcherProvider {
  WitanimeProvider(this._fetchHtml);

  final Future<String> Function(Uri, {CancelToken? cancelToken}) _fetchHtml;

  static const id = 'witanime';
  static final _origin = Uri.https('witanime.site');
  static const _homeShelves = [
    'الأكثر مشاهدة',
    'أحدث الحلقات',
    'أحدث الأفلام',
    'أكثر الأنميات مشاهدة',
    'أكثر الأفلام مشاهدة',
    'أشهر أنميات الموسم',
  ];

  @override
  String get packageName => id;
  @override
  String get name => 'Witanime';
  @override
  String get mainUrl => _origin.origin;
  @override
  String get version => '1';
  @override
  List<String> get languages => const ['ar'];
  @override
  Set<ProviderType> get supportedTypes => const {
    ProviderType.anime,
    ProviderType.movie,
  };

  @override
  Future<List<MultimediaItem>> search(
    String query, {
    CancelToken? cancelToken,
  }) => searchWithFilters(
    query,
    const ProviderSearchFilters(),
    cancelToken: cancelToken,
  );

  @override
  Future<List<MultimediaItem>> searchWithFilters(
    String query,
    ProviderSearchFilters filters, {
    CancelToken? cancelToken,
  }) async =>
      (await searchPage(query, filters, cancelToken: cancelToken)).items;

  @override
  Future<ProviderMediaPage> searchPage(
    String query,
    ProviderSearchFilters filters, {
    int offset = 0,
    int limit = 30,
    CancelToken? cancelToken,
  }) {
    final text = query.trim();
    final plainSearch =
        text.isNotEmpty && filters.isEmpty && filters.sort.isEmpty;
    final path = plainSearch ? '/search' : '/browse';
    final uri = _origin.replace(
      path: path,
      queryParameters: <String, dynamic>{
        if (plainSearch) 'q': text else if (text.isNotEmpty) 'search': text,
        if (filters.statuses.isNotEmpty) 'status': filters.statuses.first,
        if (filters.types.isNotEmpty) 'type': filters.types.first,
        if (filters.years.isNotEmpty) 'year': filters.years.first,
        if (filters.seasons.isNotEmpty) 'season': filters.seasons.first,
        if (filters.countries.isNotEmpty) 'country': filters.countries.first,
        if (filters.genres.isNotEmpty) 'genres[]': filters.genres.toList(),
        if (filters.sort.isNotEmpty) 'sort': filters.sort,
      },
    );
    return _catalogPage(uri, offset, limit, cancelToken: cancelToken);
  }

  @override
  Future<Map<String, List<MultimediaItem>>> getHome() async {
    final main = await _main(_origin);
    final hero = main.querySelector('[aria-roledescription="carousel"]');
    final items = <String, List<MultimediaItem>>{
      if (hero != null) 'Trending': _cards(hero, _origin),
    };
    for (final title in _homeShelves) {
      final cards = _namedCards(main, title, _origin);
      if (cards.isNotEmpty) items[title] = cards;
    }
    if (items.values.every((shelf) => shelf.isEmpty)) {
      throw const FormatException('Witanime home sections missing');
    }
    return items;
  }

  Future<ProviderMediaPage> getMoviesPage({int offset = 0, int limit = 30}) =>
      _catalogPage(_origin.replace(path: '/movies'), offset, limit);

  @override
  bool get supportsBroadcastSchedule => true;

  @override
  Future<ProviderMediaPage> getBroadcastSchedulePage(
    String day, {
    int offset = 0,
    int limit = 30,
    bool refresh = false,
    CancelToken? cancelToken,
  }) async {
    final uri = _origin.replace(path: '/schedule');
    final main = await _main(uri, cancelToken: cancelToken);
    return _slice(_namedCards(main, day, uri), offset, limit);
  }

  Future<ProviderMediaPage> _catalogPage(
    Uri first,
    int offset,
    int limit, {
    CancelToken? cancelToken,
  }) async {
    final start = offset < 0 ? 0 : offset;
    final size = limit.clamp(1, 100);
    final seenPages = <Uri>{};
    final seenItems = <String>{};
    final items = <MultimediaItem>[];
    Uri? page = first;
    while (page != null && items.length < start + size && seenPages.add(page)) {
      final main = await _main(page, cancelToken: cancelToken);
      final grid = main.querySelector('[data-catalog-results]') ?? main;
      for (final item in _cards(grid, page, catalogResults: true)) {
        if (seenItems.add(item.url)) items.add(item);
      }
      final next = _siteUri(
        main.querySelector('a[rel="next"]')?.attributes['href'],
        page,
      );
      final suffix = RegExp('^${first.path}/page/([1-9][0-9]*)/?\$');
      int pageNumber(Uri uri) =>
          int.tryParse(
            uri.path == first.path
                ? uri.queryParameters['page'] ?? '1'
                : suffix.firstMatch(uri.path)?.group(1) ?? '',
          ) ??
          0;
      page = next != null && pageNumber(next) == pageNumber(page) + 1
          ? next.replace(
              queryParameters: {
                ...first.queryParametersAll,
                if (next.path == first.path) 'page': '${pageNumber(next)}',
              },
            )
          : null;
    }
    return _slice(
      items,
      start,
      size,
      hasNext: page != null && !seenPages.contains(page),
    );
  }

  static ProviderMediaPage _slice(
    List<MultimediaItem> items,
    int offset,
    int limit, {
    bool hasNext = false,
  }) {
    final start = offset.clamp(0, items.length);
    final end = (start + limit.clamp(1, 100)).clamp(start, items.length);
    return ProviderMediaPage(
      items: items.sublist(start, end),
      nextOffset: offset < 0 || start == offset ? end : offset,
      hasMore: end < items.length || hasNext,
    );
  }

  @override
  Future<MultimediaItem> getDetails(String url) async {
    final link = _reference(url, _origin);
    if (link == null) throw const FormatException('Invalid Witanime work URL');
    final uri = link.work;
    final document = await _document(uri);
    final main = _requireMain(document);
    final json = _metadata(document);
    final title = _text(main.querySelector('h1')) ?? _string(json['name']);
    if (title == null) {
      throw const FormatException('Witanime work title missing');
    }

    final poster =
        _image(main.querySelector('img[src*="/posters/"]'), uri) ??
        _artwork(
          document
              .querySelector('meta[property="og:image"]')
              ?.attributes['content'],
          uri,
        );
    final description =
        _string(json['description']) ??
        _text(main.querySelector('p.leading-relaxed'));
    final kind = link.movie
        ? MultimediaContentType.movie
        : MultimediaContentType.anime;
    final rawGenres = json['genre'];
    final genres = switch (rawGenres) {
      final List<Object?> values => values.whereType<String>(),
      final String value => value.split(','),
      _ => main.querySelectorAll('a[href*="genre"]').map((e) => e.text),
    };
    final status = switch (main
        .querySelector('span[data-status]')
        ?.attributes['data-status']) {
      'completed' => ShowStatus.completed,
      'upcoming' => ShowStatus.upcoming,
      'ongoing' => ShowStatus.ongoing,
      _ when _hasLabel(main, {'قادم', 'لم يعرض بعد'}) => ShowStatus.upcoming,
      _ when _hasLabel(main, {'مكتمل', 'منتهي'}) => ShowStatus.completed,
      _ => ShowStatus.ongoing,
    };
    final fields = <String, String>{};
    for (final label in main.querySelectorAll('p, dt, span')) {
      final key = _text(label);
      if (key == null || label.children.isNotEmpty) continue;
      final value = _text(label.nextElementSibling);
      if (value != null) fields.putIfAbsent(key, () => value);
    }
    final duration = RegExp(r'[0-9]+')
        .stringMatch(normalizeLocalizedDigits(fields['المدة'] ?? ''));
    return MultimediaItem(
      title: title,
      url: uri.toString(),
      posterUrl: poster ?? '',
      bannerUrl: _image(main.querySelector('img[src*="/banners/"]'), uri),
      description: description,
      provider: id,
      contentType: kind,
      catalogType: link.movie ? 'فيلم' : _string(json['@type']),
      status: status,
      year: int.tryParse(
        (_string(json['datePublished']) ??
                normalizeLocalizedDigits(fields['السنة'] ?? ''))
            .split('-')
            .first,
      ),
      duration: int.tryParse(duration ?? ''),
      contentRating: fields['التصنيف العمري'],
      source: fields['المصدر'],
      syncData: {
        'awStudio': ?fields['الاستوديو'],
        'awEnglishTitle': ?_string(json['alternateName']),
      },
      score: _rating(json['aggregateRating']),
      tags: genres
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty)
          .toSet()
          .toList(),
      episodes: _episodes(main, uri, title),
      related: _namedCards(main, 'ذات صلة', uri),
      recommendations: _namedCards(main, 'قد يعجبك أيضًا', uri),
    );
  }

  @override
  Future<List<StreamResult>> loadStreams(String url) async =>
      throw UnsupportedError('Witanime playback transport is not configured');

  Future<Document> _document(Uri uri, {CancelToken? cancelToken}) async =>
      html.parse(await _fetchHtml(uri, cancelToken: cancelToken));

  Future<Element> _main(Uri uri, {CancelToken? cancelToken}) async =>
      _requireMain(await _document(uri, cancelToken: cancelToken));

  static Element _requireMain(Document document) {
    final main = document.querySelector('main');
    if (main == null) {
      throw const FormatException('Witanime main content missing');
    }
    return main;
  }

  static List<MultimediaItem> _namedCards(Element main, String title, Uri uri) {
    for (final heading in main.querySelectorAll('h2, h3')) {
      if (_text(heading) != title) continue;
      for (
        var block = heading.parent;
        block != null && block != main;
        block = block.parent
      ) {
        final headings = block.querySelectorAll('h2');
        if (headings.length > 1) break;
        final cards = _cards(block, uri);
        if (cards.isNotEmpty) return cards;
      }
    }
    return const [];
  }

  static List<MultimediaItem> _cards(
    Element scope,
    Uri uri, {
    bool catalogResults = false,
  }) {
    final items = <String, MultimediaItem>{};
    for (final anchor in scope.querySelectorAll('a[href]')) {
      if (catalogResults && _insideSecondarySection(anchor, scope)) continue;
      final link = _reference(anchor.attributes['href'], uri);
      if (link == null || (catalogResults && link.watch != null)) continue;
      final image = anchor.querySelector('img');
      final title =
          _text(anchor.querySelector('h3, h2')) ??
          _string(image?.attributes['alt']) ??
          _string(anchor.attributes['title']);
      if (title == null) continue;
      final work = link.work.toString();
      final poster = _image(image, uri) ?? '';
      final key = (link.watch ?? link.work).toString();
      if (items[key]?.posterUrl.isNotEmpty == true) continue;
      items[key] = MultimediaItem(
        title: title,
        url: work,
        posterUrl: poster,
        provider: id,
        contentType: link.movie
            ? MultimediaContentType.movie
            : MultimediaContentType.anime,
        episodeBadge: link.watch != null && !link.movie
            ? 'الحلقة ${link.watch!.pathSegments.last}'
            : null,
      );
    }
    return items.values.toList();
  }

  static bool _insideSecondarySection(Element anchor, Element scope) {
    for (
      var parent = anchor.parent;
      parent != null && parent != scope;
      parent = parent.parent
    ) {
      if (parent.localName == 'aside' || parent.localName == 'nav') return true;
      if (parent.children.any(
        (child) =>
            child.localName == 'h2' &&
            const {'الأعلى تقييمًا', 'قد يعجبك أيضًا'}.contains(_text(child)),
      )) {
        return true;
      }
    }
    return false;
  }

  static List<Episode> _episodes(Element main, Uri work, String title) {
    final list = main.querySelector('[data-episode-list]');
    final anchors = (list ?? main).querySelectorAll('a[href]');
    final episodes = <String, Episode>{};
    for (final anchor in anchors) {
      final ref = _reference(anchor.attributes['href'], work);
      final watch = ref?.watch;
      if (watch == null || ref!.work != work) continue;
      final key = watch.toString();
      if (episodes.containsKey(key)) continue;
      final number = normalizeLocalizedDigits(watch.pathSegments.last);
      final value = ref.movie ? null : double.tryParse(number);
      final raw = _text(anchor);
      final name = ref.movie
          ? title
          : (raw != null && raw != 'شاهد الآن' && raw != number
                ? raw
                : 'الحلقة $number');
      episodes[key] = Episode(
        name: name,
        url: key,
        episode: ref.movie
            ? 1
            : (value?.isFinite == true ? value!.truncate() : 0),
        serverNumber: value?.isFinite == true ? number : null,
        serverName: name,
        posterUrl: _image(anchor.querySelector('img'), work),
        isFinal: name.contains('الأخيرة'),
      );
    }
    return episodes.values.toList();
  }

  static ({Uri work, Uri? watch, bool movie})? _reference(
    String? raw,
    Uri base,
  ) {
    final uri = _siteUri(raw, base);
    if (uri == null) return null;
    final parts = uri.pathSegments.toList();
    if (parts.isNotEmpty && parts.last.isEmpty) parts.removeLast();
    if (parts.any(
      (segment) =>
          segment.isEmpty ||
          segment.contains('/') ||
          segment.contains(r'\') ||
          segment == '.' ||
          segment == '..',
    )) {
      return null;
    }
    final (movie, slug, watch) = switch (parts) {
      ['anime', final slug] => (false, slug, false),
      ['movie', final slug] => (true, slug, false),
      ['watch', 'movie', final slug] => (true, slug, true),
      ['watch', final slug, _] => (false, slug, true),
      _ => (false, '', false),
    };
    if (slug.isEmpty) return null;
    return (
      work: Uri(
        scheme: 'https',
        host: _origin.host,
        pathSegments: [movie ? 'movie' : 'anime', slug],
      ),
      watch: watch
          ? Uri(scheme: 'https', host: _origin.host, pathSegments: parts)
          : null,
      movie: movie,
    );
  }

  static Uri? _siteUri(String? raw, Uri base) {
    final uri = _httpsUri(raw, base);
    return uri?.host == _origin.host ? uri!.removeFragment() : null;
  }

  static Uri? _httpsUri(String? raw, Uri base) {
    final parsed = Uri.tryParse(raw?.trim() ?? '');
    if (parsed == null || raw == null || raw.trim().isEmpty) return null;
    final uri = base.resolveUri(parsed);
    return uri.scheme == 'https' &&
            uri.hasAuthority &&
            uri.host.isNotEmpty &&
            uri.userInfo.isEmpty &&
            uri.port == 443
        ? uri
        : null;
  }

  static String? _artwork(String? raw, Uri base) =>
      _httpsUri(raw, base)?.toString();
  static String? _image(Element? image, Uri base) =>
      _artwork(image?.attributes['data-src'], base) ??
      _artwork(image?.attributes['src'], base);

  static String? _text(Element? el) => _string(el?.text);
  static String? _string(Object? raw) {
    final text = raw is String
        ? raw.replaceAll(RegExp(r'\s+'), ' ').trim()
        : '';
    return text.isEmpty ? null : text;
  }

  static bool _hasLabel(Element root, Set<String> labels) =>
      root.querySelectorAll('span').any((span) => labels.contains(_text(span)));

  static Map<String, dynamic> _metadata(Document document) {
    for (final script in document.querySelectorAll(
      'script[type="application/ld+json"]',
    )) {
      try {
        final value = jsonDecode(script.text);
        if (value is Map<String, dynamic> &&
            const {'TVSeries', 'Movie'}.contains(value['@type'])) {
          return value;
        }
      } on FormatException {
        continue;
      }
    }
    return const {};
  }

  static double? _rating(Object? value) {
    if (value is! Map) return null;
    final score = double.tryParse('${value['ratingValue']}');
    return score != null && score >= 0 && score <= 10 ? score : null;
  }
}
