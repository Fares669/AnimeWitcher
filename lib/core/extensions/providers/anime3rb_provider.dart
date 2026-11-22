import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;

import '../../domain/entity/multimedia_item.dart';
import '../../utils/digit_normalization.dart';
import '../base_provider.dart';
import 'anime3rb_filter_values.dart';
import 'anime3rb_playback.dart';
import 'anime3rb_transport.dart';

/// Anime3rb (`https://anime3rb.com`) catalog, search, details, and playback provider.
class Anime3rbProvider extends AnimeWitcherProvider {
  Anime3rbProvider(
    this._fetchHtml, {
    Anime3rbTransport? transport,
    Anime3rbTurnstileResolver? turnstileResolver,
  }) : _transport = transport,
       _playback = transport == null
           ? null
           : Anime3rbPlaybackResolver(
               transport,
               origin: _origin,
               turnstileResolver: turnstileResolver,
             );

  factory Anime3rbProvider.withTransport(
    Anime3rbTransport transport, {
    Anime3rbTurnstileResolver? turnstileResolver,
  }) => Anime3rbProvider(
    (uri, {headers = const {}, cancelToken}) => transport.fetchHtml(
      uri,
      headers: headers,
      cancelToken: cancelToken,
    ),
    transport: transport,
    turnstileResolver: turnstileResolver,
  );

  final Future<String> Function(
    Uri, {
    Map<String, String> headers,
    CancelToken? cancelToken,
  })
  _fetchHtml;
  final Anime3rbTransport? _transport;
  final Anime3rbPlaybackResolver? _playback;

  static const id = 'anime3rb';
  static const watchUrlKey = 'anime3rbWatchUrl';
  static final _origin = Uri.https('anime3rb.com');
  static Uri websiteUri(String path) => _origin.replace(path: path);

  static const _catalogPageSize = 20;
  static const _homeLatestEpisodesSection = 'أحدث الحلقات';
  static const _homePinnedSection = 'الأنميات المثبتة';
  static const _homeRecentlyAddedSection = 'آخر الأنميات المضافة';
  static const _homeTopRatedSection = 'الأعلى تقييماً';
  static const _homeMoviesSection = 'أفلام الأنمي';

  static final _trailingEpisodeSuffix = RegExp(r'\s*الحلقة\s*\d+\s*$');
  static final _episodeNumberDigits = RegExp(r'\d+');

  @override
  String get packageName => id;

  @override
  String get name => 'Anime3rb';

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
  int get viewAllPageSize => _catalogPageSize;

  @override
  int get searchPageSize => _catalogPageSize;

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
  Future<ProviderSearchFilterOptions> getSearchFilterOptions() async =>
      ProviderSearchFilterOptions(
        statuses: const ['مكتمل', 'مستمر', 'قادم'],
        types: anime3rbTypeValues.keys.toList(growable: false),
        ageRatings: anime3rbAgeRatingValues.keys.toList(growable: false),
        years: anime3rbYearValues,
        studios: anime3rbStudioValues.keys.toList(growable: false),
        genres: anime3rbGenreValues.keys.toList(growable: false),
        singleSelection: false,
      );

  @override
  Future<ProviderMediaPage> searchPage(
    String query,
    ProviderSearchFilters filters, {
    int offset = 0,
    int limit = _catalogPageSize,
    CancelToken? cancelToken,
  }) {
    final text = query.trim();
    final (sortBy, sortDir) = switch (filters.sort) {
      'favorites' => ('rate', 'desc'),
      'year_asc' => ('release_date', 'asc'),
      'year_desc' => ('release_date', 'desc'),
      'name_asc' => ('name', 'asc'),
      'name_desc' => ('name', 'desc'),
      _ => (text.isNotEmpty ? 'relevance' : null, null),
    };

    String? mapValue(String raw, Map<String, String> known) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty) return null;
      return known[trimmed] ?? (known.containsValue(trimmed) ? trimmed : null);
    }

    final typeSlug = filters.types.isNotEmpty
        ? mapValue(filters.types.first, anime3rbTypeValues)
        : null;
    final genreSlugs = [
      for (final g in filters.genres)
        ?mapValue(g, anime3rbGenreValues),
    ];
    final statusSlugs = [
      for (final s in filters.statuses)
        ?mapValue(s, anime3rbStatusValues),
    ];
    final ageSlugs = [
      for (final a in filters.ageRatings)
        ?mapValue(a, anime3rbAgeRatingValues),
    ];
    final studioSlugs = [
      for (final studio in filters.studios)
        if (studio.trim().isNotEmpty) anime3rbStudioSlug(studio),
    ];

    String? yearRange;
    if (filters.years.isNotEmpty) {
      final parsedYears = filters.years
          .map((y) => int.tryParse(normalizeLocalizedDigits(y.trim())))
          .whereType<int>()
          .toList()
        ..sort();
      if (parsedYears.isNotEmpty) {
        yearRange = '${parsedYears.first}-${parsedYears.last}';
      }
    }

    final hasNonGenreFilters =
        text.isNotEmpty ||
        typeSlug != null ||
        statusSlugs.isNotEmpty ||
        ageSlugs.isNotEmpty ||
        studioSlugs.isNotEmpty ||
        yearRange != null;

    final String path;
    if (text.isNotEmpty) {
      path = '/search';
    } else if (!hasNonGenreFilters && genreSlugs.length == 1) {
      path = '/genre/${genreSlugs.first}';
    } else if (typeSlug != null) {
      path = '/titles/list/$typeSlug';
    } else {
      path = '/titles/list';
    }

    final queryParams = <String, dynamic>{
      if (text.isNotEmpty) 'q': text,
      if (path != '/genre/${genreSlugs.firstOrNull}' && genreSlugs.isNotEmpty)
        'genres': genreSlugs.join(','),
      if (statusSlugs.isNotEmpty) 'status': statusSlugs.join(','),
      if (ageSlugs.isNotEmpty) 'age': ageSlugs.join(','),
      if (studioSlugs.isNotEmpty) 'c': studioSlugs.join(','),
      'year': ?yearRange,
      'sort_by': ?sortBy,
      'sort_dir': ?sortDir,
    };

    final uri = _origin.replace(
      path: path,
      queryParameters: queryParams.isEmpty ? null : queryParams,
    );
    return _catalogPage(uri, offset, limit, cancelToken: cancelToken);
  }

  @override
  Future<Map<String, List<MultimediaItem>>> getHome() async {
    final homeFuture = _document(_origin);
    final topRatedFuture = _safeCatalogFirstPage(
      _origin.replace(
        path: '/titles/list',
        queryParameters: const {'sort_by': 'rate', 'sort_dir': 'desc'},
      ),
    );
    final moviesFuture = _safeCatalogFirstPage(
      _origin.replace(path: '/titles/list/movie'),
    );

    final doc = await homeFuture;
    final topRated = await topRatedFuture;
    final movies = await moviesFuture;

    final sections = <String, List<MultimediaItem>>{};

    final latest = _parseVideoCards(
      doc.querySelector('#videos'),
      _origin,
    );
    if (latest.isNotEmpty) sections[_homeLatestEpisodesSection] = latest;

    final pinnedContainer = _findSectionByHeading(doc, _homePinnedSection);
    final pinned = _parseVideoCards(
      pinnedContainer,
      _origin,
      excludeClones: true,
    );
    if (pinned.isNotEmpty) sections[_homePinnedSection] = pinned;

    final recentContainer = _findSectionByHeading(
      doc,
      _homeRecentlyAddedSection,
    );
    final recent = _parseTitleCards(
      recentContainer,
      _origin,
      excludeClones: true,
    );
    if (recent.isNotEmpty) sections[_homeRecentlyAddedSection] = recent;

    if (topRated.isNotEmpty) sections[_homeTopRatedSection] = topRated;
    if (movies.isNotEmpty) sections[_homeMoviesSection] = movies;

    if (sections.isEmpty) {
      throw const FormatException('Anime3rb home sections missing');
    }
    return sections;
  }

  Future<List<MultimediaItem>> _safeCatalogFirstPage(Uri uri) async {
    try {
      final doc = await _document(uri);
      return _parseTitleCards(
        doc.querySelector('.titles-list') ?? doc.body,
        uri,
      );
    } catch (_) {
      return const <MultimediaItem>[];
    }
  }

  @override
  Future<ProviderMediaPage> getHomeSectionPage(
    String sectionName, {
    int offset = 0,
    int limit = _catalogPageSize,
  }) async {
    switch (sectionName.trim()) {
      case _homeLatestEpisodesSection:
        return _latestEpisodesPage(offset, limit);
      case _homeRecentlyAddedSection:
        return _catalogPage(
          _origin.replace(
            path: '/titles/list',
            queryParameters: const {
              'sort_by': 'addition_date',
              'sort_dir': 'desc',
            },
          ),
          offset,
          limit,
        );
      case _homeTopRatedSection:
        return _catalogPage(
          _origin.replace(
            path: '/titles/list',
            queryParameters: const {'sort_by': 'rate', 'sort_dir': 'desc'},
          ),
          offset,
          limit,
        );
      case _homeMoviesSection:
        return _catalogPage(
          _origin.replace(path: '/titles/list/movie'),
          offset,
          limit,
        );
      default:
        return super.getHomeSectionPage(
          sectionName,
          offset: offset,
          limit: limit,
        );
    }
  }

  Future<ProviderMediaPage> _latestEpisodesPage(int offset, int limit) async {
    final start = offset < 0 ? 0 : offset;
    final size = limit.clamp(1, 100);
    final pageNum = (start ~/ 30) + 1;
    final uri = pageNum <= 1
        ? _origin
        : _origin.replace(path: '/', queryParameters: {'page': '$pageNum'});
    final raw = await _fetchHtml(
      uri,
      headers: pageNum > 1
          ? const {'X-Requested-With': 'XMLHttpRequest'}
          : const {},
    );
    final doc = html.parse(raw);
    final scope = pageNum <= 1 ? doc.querySelector('#videos') : doc.body;
    final items = _parseVideoCards(scope, _origin);
    final localStart = start % 30;
    if (localStart >= items.length) {
      return ProviderMediaPage(
        items: const <MultimediaItem>[],
        nextOffset: start,
        hasMore: false,
      );
    }
    final end = (localStart + size).clamp(localStart, items.length);
    return ProviderMediaPage(
      items: items.sublist(localStart, end),
      nextOffset: start + (end - localStart),
      hasMore: end < items.length || items.length >= 30,
    );
  }

  Future<ProviderMediaPage> _catalogPage(
    Uri baseUri,
    int offset,
    int limit, {
    CancelToken? cancelToken,
  }) async {
    final start = offset < 0 ? 0 : offset;
    final size = limit.clamp(1, 100);
    final startPage = (start ~/ _catalogPageSize) + 1;
    final skipInFirstPage = start % _catalogPageSize;

    final seenItems = <String>{};
    final items = <MultimediaItem>[];
    var currentPage = startPage;
    var hasMore = false;
    var pagesFetched = 0;

    while (items.length < size && pagesFetched < 3) {
      final pageUri = currentPage <= 1
          ? baseUri
          : baseUri.replace(
              queryParameters: {
                ...baseUri.queryParameters,
                'page': '$currentPage',
              },
            );
      final doc = await _document(pageUri, cancelToken: cancelToken);
      pagesFetched++;

      final grid = doc.querySelector('.titles-list') ?? doc.body;
      final pageItems = _parseTitleCards(grid, pageUri);
      final sliced = pagesFetched == 1 && skipInFirstPage > 0
          ? (skipInFirstPage < pageItems.length
                ? pageItems.sublist(skipInFirstPage)
                : const <MultimediaItem>[])
          : pageItems;
      for (final item in sliced) {
        if (seenItems.add(item.url)) items.add(item);
      }

      hasMore = _hasNextPaginationPage(doc, currentPage);
      if (!hasMore || pageItems.isEmpty) break;
      currentPage++;
    }

    final capped = items.length > size ? items.sublist(0, size) : items;
    final stillMore = items.length > size || hasMore;
    return ProviderMediaPage(
      items: capped,
      nextOffset: start + capped.length,
      hasMore: stillMore && capped.isNotEmpty,
    );
  }

  static bool _hasNextPaginationPage(Document doc, int currentPage) {
    final nav = doc.querySelector('nav[aria-label="Pagination Navigation"]');
    if (nav == null) return false;
    if (nav.querySelector('a[rel="next"]') != null) return true;
    final nextPageStr = '${currentPage + 1}';
    for (final link in nav.querySelectorAll('a[href]')) {
      final href = link.attributes['href'] ?? '';
      final uri = Uri.tryParse(href);
      if (uri?.queryParameters['page'] == nextPageStr) return true;
    }
    return false;
  }

  @override
  Future<MultimediaItem> getDetails(String url) async {
    final link = parseCatalogLink(url);
    if (link == null) {
      throw const FormatException('Invalid Anime3rb title URL');
    }
    final uri = link.work;
    final doc = await _document(uri);
    final json = _metadata(doc);

    final h1Ltr = _text(doc.querySelector('h1 span[dir="ltr"]'));
    final h1Full = _text(doc.querySelector('h1'))
        ?.replaceAll(_trailingEpisodeSuffix, '')
        .trim();
    final title = h1Ltr ?? _string(json['name']) ?? h1Full;
    if (title == null || title.isEmpty) {
      throw const FormatException('Anime3rb title missing');
    }

    final typeLabel = _text(doc.querySelector('h1 span.font-light')) ?? '';
    final contentType = _contentTypeFromLabel(
      typeLabel,
      jsonType: json['@type']?.toString(),
    );

    final poster =
        _image(doc.querySelector('img[alt*="بوستر"]'), uri) ??
        _artwork(
          doc.querySelector('meta[property="og:image"]')?.attributes['content'],
          uri,
        ) ??
        _artwork(json['image']?.toString(), uri) ??
        '';

    final synopsis =
        _text(doc.querySelector('[x-data] > div[x-show="! summary"] p')) ??
        _text(doc.querySelector('p.synopsis')) ??
        _string(json['description']) ??
        _string(
          doc.querySelector('meta[name="description"]')?.attributes['content'],
        );

    final altName = _text(doc.querySelector('h2.lg\\:text-meta'));
    final tableFields = _parseDetailsTable(doc);

    final genres = <String>{
      for (final a in doc.querySelectorAll('a[href*="/genre/"]')) ?_text(a),
      if (json['genre'] case final List<Object?> list)
        for (final g in list) ?_string(g),
    }.toList(growable: false);

    final status = _parseShowStatus(tableFields['الحالة'] ?? '');
    final year = _extractYear(
      tableFields['إصدار'] ?? json['datePublished']?.toString() ?? '',
    );

    final score =
        _extractScore(doc) ?? _rating(json['aggregateRating']);
    final ageRating =
        _extractSummaryCardValue(doc, 'التصنيف العمري') ??
        _string(json['contentRating']);

    final studio = _text(doc.querySelector('a[href*="/c/studio/"]')) ??
        tableFields['الاستديو'] ??
        tableFields['الاستوديو'];

    final trailers = _trailers(doc, uri);
    final episodes = _episodes(doc, uri, title);
    final related = _parseTitleCards(
      _findSectionByHeading(doc, 'أعمال ذات صلة'),
      uri,
      excludeClones: true,
    );
    final recommendations = _parseTitleCards(
      _findSectionByHeading(doc, 'أنميات مشابهة مقترحة'),
      uri,
      excludeClones: true,
    );

    return MultimediaItem(
      title: title,
      url: uri.toString(),
      posterUrl: poster,
      description: synopsis,
      provider: id,
      contentType: contentType,
      catalogType: typeLabel.replaceAll(RegExp(r'[()]'), '').trim(),
      status: status,
      year: year,
      contentRating: ageRating,
      syncData: {
        'awStudio': ?(studio != null && studio.isNotEmpty ? studio : null),
        'awEnglishTitle': ?(altName != null && altName.isNotEmpty
            ? altName
            : null),
      },
      trailers: trailers,
      score: score,
      tags: genres,
      episodes: episodes,
      related: related,
      recommendations: recommendations,
    );
  }

  @override
  bool isExplicitStreamSelection(String url) =>
      url.trim().startsWith(anime3rbSourceUrlPrefix);

  @override
  Future<List<StreamResult>> loadStreamSources(String url) {
    final resolver = _playback;
    if (resolver == null) {
      return Future<List<StreamResult>>.error(
        UnsupportedError('Anime3rb playback transport is not configured'),
      );
    }
    return resolver.loadSources(url, forDownload: false);
  }

  @override
  Future<List<StreamResult>> loadDownloadStreamSources(String url) {
    final resolver = _playback;
    if (resolver == null) {
      return Future<List<StreamResult>>.error(
        UnsupportedError('Anime3rb playback transport is not configured'),
      );
    }
    return resolver.loadSources(url, forDownload: true);
  }

  @override
  Future<List<StreamResult>> loadDownloadStreams(String url) {
    final resolver = _playback;
    if (resolver == null) {
      return Future<List<StreamResult>>.error(
        UnsupportedError('Anime3rb playback transport is not configured'),
      );
    }
    return resolver.resolveStreams(url, forDownload: true);
  }

  @override
  Future<List<StreamResult>> loadStreams(String url) async {
    final resolver = _playback;
    if (resolver == null) {
      throw UnsupportedError('Anime3rb playback transport is not configured');
    }
    return resolver.resolveStreams(url, forDownload: false);
  }

  @override
  void prepareForNetworkRetry() {
    _transport;
    _playback?.clearCache();
  }

  @override
  void invalidateDetailCaches(String url) {
    _playback?.clearCache();
  }

  Future<Document> _document(
    Uri uri, {
    Map<String, String> headers = const {},
    CancelToken? cancelToken,
  }) async => html.parse(
    await _fetchHtml(uri, headers: headers, cancelToken: cancelToken),
  );

  static Element? _findSectionByHeading(Document doc, String headingText) {
    for (final heading in doc.querySelectorAll('h2, h3')) {
      final txt = _text(heading) ?? '';
      if (!txt.contains(headingText)) continue;
      for (
        var cur = heading.parent;
        cur != null && cur.localName != 'body';
        cur = cur.parent
      ) {
        if (cur.querySelector('.video-card, .title-card') != null) {
          return cur;
        }
      }
    }
    return null;
  }

  static List<MultimediaItem> _parseVideoCards(
    Element? scope,
    Uri base, {
    bool excludeClones = false,
  }) {
    if (scope == null) return const <MultimediaItem>[];
    final items = <String, MultimediaItem>{};
    for (final anchor in scope.querySelectorAll('a.video-card[href]')) {
      if (excludeClones && _isInsideCloneSlide(anchor, scope)) continue;
      final link = _reference(anchor.attributes['href'], base);
      if (link == null) continue;
      final title =
          _text(anchor.querySelector('h3.title-name, h3, h2')) ??
          _string(anchor.querySelector('img')?.attributes['alt']);
      if (title == null || title.isEmpty) continue;
      final poster = _image(anchor.querySelector('img'), base) ?? '';
      final badge = _text(anchor.querySelector('p.number, .number'));
      final key = (link.watch ?? link.work).toString();
      if (items[key]?.posterUrl.isNotEmpty == true) continue;
      items[key] = MultimediaItem(
        title: title,
        url: link.work.toString(),
        posterUrl: poster,
        provider: id,
        contentType: MultimediaContentType.anime,
        syncData: link.watch == null
            ? null
            : {watchUrlKey: link.watch.toString()},
        episodeBadge: badge,
      );
    }
    return items.values.toList(growable: false);
  }

  static List<MultimediaItem> _parseTitleCards(
    Element? scope,
    Uri base, {
    bool excludeClones = false,
  }) {
    if (scope == null) return const <MultimediaItem>[];
    final items = <String, MultimediaItem>{};
    for (final card in scope.querySelectorAll('.title-card')) {
      if (excludeClones && _isInsideCloneSlide(card, scope)) continue;
      final anchor = card.querySelector('a[href*="/titles/"]');
      final link = _reference(anchor?.attributes['href'], base);
      if (link == null) continue;
      final title =
          _text(card.querySelector('h2.title-name, h2, h3')) ??
          _string(card.querySelector('img')?.attributes['alt']);
      if (title == null || title.isEmpty) continue;
      final poster = _image(card.querySelector('img'), base) ?? '';
      final synopsis = _text(card.querySelector('p.synopsis'));
      final genres = <String>[
        for (final g in card.querySelectorAll('.genres span')) ?_text(g),
      ];
      double? score;
      String? badge;
      int? year;
      for (final b in card.querySelectorAll('p span.badge, span.badge')) {
        final txt = normalizeLocalizedDigits(_text(b) ?? '');
        if (txt.contains('التقييم')) {
          final m = RegExp(r'(\d+(?:\.\d+)?)').firstMatch(txt);
          score ??= double.tryParse(m?.group(1) ?? '');
        } else if (txt.contains('حلقة') || txt.contains('حلقات')) {
          badge ??= txt;
        } else if (RegExp(r'\b(19|20)\d{2}\b').hasMatch(txt)) {
          year ??= _extractYear(txt);
        }
      }
      final key = link.work.toString();
      if (items[key]?.posterUrl.isNotEmpty == true) continue;
      items[key] = MultimediaItem(
        title: title,
        url: key,
        posterUrl: poster,
        description: synopsis,
        provider: id,
        contentType: MultimediaContentType.anime,
        year: year,
        score: score,
        tags: genres,
        episodeBadge: badge,
      );
    }
    return items.values.toList(growable: false);
  }

  static bool _isInsideCloneSlide(Element el, Element scope) {
    for (
      var cur = el.parent;
      cur != null && cur != scope;
      cur = cur.parent
    ) {
      if (cur.classes.contains('glide__slide--clone')) return true;
    }
    return false;
  }

  static List<Episode> _episodes(Document doc, Uri work, String animeTitle) {
    final container = doc.querySelector('.video-list');
    final anchors = container?.querySelectorAll('a[href*="/episode/"]') ??
        doc.querySelectorAll('a[href*="/episode/"]');
    final episodes = <String, Episode>{};

    for (final anchor in anchors) {
      final ref = _reference(anchor.attributes['href'], work);
      final watch = ref?.watch;
      if (watch == null || ref!.work != work) continue;
      final key = watch.toString();
      if (episodes.containsKey(key)) continue;

      final numberStr = normalizeLocalizedDigits(watch.pathSegments.last);
      final epNum = int.tryParse(numberStr) ??
          int.tryParse(_episodeNumberDigits.stringMatch(numberStr) ?? '') ??
          0;
      final epLabel =
          _text(anchor.querySelector('.video-data span')) ?? 'الحلقة $epNum';
      final epTitle = _text(anchor.querySelector('.video-data p'));
      final name = (epTitle != null && epTitle.isNotEmpty) ? epTitle : epLabel;
      final poster = _image(anchor.querySelector('img'), work);

      episodes[key] = Episode(
        name: name,
        url: key,
        episode: epNum,
        serverNumber: numberStr,
        serverName: name,
        posterUrl: poster,
        isFinal: epLabel.contains('الأخيرة'),
      );
    }
    return episodes.values.toList(growable: false);
  }

  static List<Trailer> _trailers(Document doc, Uri base) {
    final trailers = <Trailer>[];
    final seen = <String>{};
    for (final el in doc.querySelectorAll(
      'iframe[data-src*="youtube.com"], iframe[src*="youtube.com"], '
      'a[href*="youtube.com"], a[href*="youtu.be"]',
    )) {
      final raw =
          el.attributes['data-src'] ??
          el.attributes['src'] ??
          el.attributes['href'];
      final url = _httpsUri(raw, base)?.toString();
      if (url == null || !seen.add(url)) continue;
      trailers.add(Trailer(url: url));
    }
    return trailers;
  }

  static Map<String, String> _parseDetailsTable(Document doc) {
    final map = <String, String>{};
    for (final row in doc.querySelectorAll('table tr')) {
      final cells = row.querySelectorAll('th, td');
      if (cells.length < 2) continue;
      final key = _text(cells[0])?.replaceAll(':', '').trim() ?? '';
      final valueEl = cells[1];
      final titleAttr = valueEl.attributes['title']?.trim();
      final value = _text(valueEl) ?? '';
      if (key.isEmpty) continue;
      if (value.isNotEmpty) map.putIfAbsent(key, () => value);
      if (titleAttr != null && titleAttr.isNotEmpty && key == 'إصدار') {
        map['إصدار_date'] = titleAttr;
      }
    }
    return map;
  }

  static double? _extractScore(Document doc) {
    final raw = _extractSummaryCardValue(doc, 'التقييم');
    if (raw == null) return null;
    final match = RegExp(r'(\d+(?:\.\d+)?)').firstMatch(
      normalizeLocalizedDigits(raw),
    );
    final score = double.tryParse(match?.group(1) ?? '');
    return score != null && score >= 0 && score <= 10 ? score : null;
  }

  static String? _extractSummaryCardValue(Document doc, String label) {
    for (final card in doc.querySelectorAll('div, section')) {
      final text = _text(card);
      if (text == null || !text.startsWith(label)) continue;
      final rest = text.substring(label.length).trim();
      if (rest.isNotEmpty && rest.length < 80) return rest;
    }
    return null;
  }

  static ShowStatus _parseShowStatus(String raw) {
    final text = raw.trim();
    if (text.contains('منتهي') || text.contains('مكتمل')) {
      return ShowStatus.completed;
    }
    if (text.contains('قادم') || text.contains('لم يعرض')) {
      return ShowStatus.upcoming;
    }
    return ShowStatus.ongoing;
  }

  static int? _extractYear(String raw) {
    final match = RegExp(r'\b(19\d{2}|20\d{2})\b').firstMatch(
      normalizeLocalizedDigits(raw),
    );
    return int.tryParse(match?.group(1) ?? '');
  }

  static MultimediaContentType _contentTypeFromLabel(
    String label, {
    String? jsonType,
  }) {
    final lower = label.toLowerCase();
    if (lower.contains('فيلم') ||
        lower.contains('movie') ||
        jsonType == 'Movie') {
      return MultimediaContentType.movie;
    }
    return MultimediaContentType.anime;
  }

  static ({Uri work, Uri? watch, bool movie})? parseCatalogLink(String url) =>
      _reference(url, _origin);

  static ({Uri work, Uri? watch, bool movie})? _reference(
    String? raw,
    Uri base,
  ) {
    final uri = _siteUri(raw, base);
    if (uri == null) return null;
    final parts = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (parts.any((s) => s == '.' || s == '..' || s.contains(r'\'))) {
      return null;
    }
    final (slug, watch) = switch (parts) {
      ['titles', final slug] when slug != 'list' => (slug, false),
      ['episode', final slug, _] => (slug, true),
      _ => ('', false),
    };
    if (slug.isEmpty) return null;
    return (
      work: Uri(
        scheme: 'https',
        host: _origin.host,
        pathSegments: ['titles', slug],
      ),
      watch: watch
          ? Uri(scheme: 'https', host: _origin.host, pathSegments: parts)
          : null,
      movie: false,
    );
  }

  static Uri? _siteUri(String? raw, Uri base) {
    final uri = _httpsUri(raw, base);
    if (uri == null) return null;
    if (uri.host != _origin.host && uri.host != 'www.${_origin.host}') {
      return null;
    }
    return uri.replace(host: _origin.host).removeFragment();
  }

  static Uri? _httpsUri(String? raw, Uri base) {
    final trimmed = raw?.trim() ?? '';
    if (trimmed.isEmpty) return null;
    final parsed = Uri.tryParse(trimmed);
    if (parsed == null) return null;
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
