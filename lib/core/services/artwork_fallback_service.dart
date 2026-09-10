import 'dart:async';
import 'dart:collection';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../network/dio_client_provider.dart';
import '../storage/storage_service.dart';

part 'artwork_fallback_service.g.dart';

/// Finds a poster for an anime whose catalog artwork cannot be loaded.
///
/// Most catalog artwork lives on MyAnimeList's CDN, which some networks block
/// outright. AniList holds a cover for nearly every title, serves it from a
/// host those networks leave alone, and answers for a whole screen of cards in
/// one request — so it is asked first, by MyAnimeList id where the catalog
/// carries one and by title where it does not. AniZip and Kitsu cover the few
/// titles AniList does not know.
class ArtworkFallbackService {
  final Dio _dio;
  final StorageService _storage;

  ArtworkFallbackService(this._dio, this._storage) {
    _restore();
  }

  /// A screen paints its cards over several frames, so lookups are collected
  /// briefly and sent together rather than one request per card. AniList
  /// allows 50 ids per query, which is more than a screen ever shows.
  static const Duration _batchWindow = Duration(milliseconds: 32);
  static const int _idsPerQuery = 50;
  static const int _titlesPerQuery = 10;

  static const String _titleKeyPrefix = 't:';

  // ---------------------------------------------------------------- caching

  /// Resolved posters, including misses (stored as null) so a title without
  /// artwork anywhere is not looked up again for every card that shows it.
  static const int _cacheMax = 600;
  static final LinkedHashMap<int, String?> _cache =
      LinkedHashMap<int, String?>();
  static final LinkedHashMap<String, String?> _titleCache =
      LinkedHashMap<String, String?>();

  static bool _restored = false;

  /// Brings last run's answers back into memory, so a restart paints known
  /// posters on the first frame rather than querying again.
  void _restore() {
    if (_restored) return;
    _restored = true;
    for (final entry in _storage.getFallbackPosters().entries) {
      if (entry.value.isEmpty) continue;
      if (entry.key.startsWith(_titleKeyPrefix)) {
        _titleCache[entry.key.substring(_titleKeyPrefix.length)] = entry.value;
        continue;
      }
      final malId = int.tryParse(entry.key);
      if (malId != null) _cache[malId] = entry.value;
    }
  }

  Timer? _persistTimer;
  bool _dirty = false;

  /// The whole map is re-encoded on every write, so writing must stay rare:
  /// a long scroll produces a batch every few hundred milliseconds, and
  /// persisting each one would re-encode a growing map over and over on the
  /// UI isolate. Nothing here is worth a dropped frame — the cache is an
  /// optimisation, and losing the last few seconds of it costs one lookup.
  static const Duration _persistDebounce = Duration(seconds: 5);

  void _schedulePersist() {
    if (!_dirty || _persistTimer != null) return;
    _persistTimer = Timer(_persistDebounce, () {
      _persistTimer = null;
      _dirty = false;
      final hits = <String, String>{};
      for (final entry in _cache.entries) {
        final url = entry.value;
        if (url != null && url.isNotEmpty) hits['${entry.key}'] = url;
      }
      for (final entry in _titleCache.entries) {
        final url = entry.value;
        if (url != null && url.isNotEmpty) {
          hits['$_titleKeyPrefix${entry.key}'] = url;
        }
      }
      unawaited(_storage.setFallbackPosters(hits));
    });
  }

  /// Only a real answer is worth a write; a batch that resolved nothing new
  /// leaves the stored copy exactly as it was.
  void _markDirty(String? url) {
    if (url != null && url.isNotEmpty) _dirty = true;
  }

  static void _remember(int malId, String? url) {
    _cache.remove(malId);
    _cache[malId] = url;
    while (_cache.length > _cacheMax) {
      _cache.remove(_cache.keys.first);
    }
  }

  static void _rememberTitle(String key, String? url) {
    _titleCache.remove(key);
    _titleCache[key] = url;
    while (_titleCache.length > _cacheMax) {
      _titleCache.remove(_titleCache.keys.first);
    }
  }

  static String _titleKey(String title) => title.trim().toLowerCase();

  /// Banners found for an id, kept apart from the posters.
  ///
  /// A banner is a different picture with a different shape, and an entry
  /// that has one may still want a poster looked up, or the other way round.
  /// Static like the others, so the answers outlive one screen.
  static final Map<int, String?> _bannerCache = <int, String?>{};

  static void _rememberBanner(int malId, String? url) {
    _bannerCache.remove(malId);
    _bannerCache[malId] = url;
    while (_bannerCache.length > _cacheMax) {
      _bannerCache.remove(_bannerCache.keys.first);
    }
  }

  String? cached(int malId) => _cache[malId];

  String? cachedBanner(int malId) => _bannerCache[malId];

  bool hasResolvedBanner(int malId) => _bannerCache.containsKey(malId);

  bool hasResolved(int malId) => _cache.containsKey(malId);

  String? cachedForTitle(String title) => _titleCache[_titleKey(title)];

  bool hasResolvedTitle(String title) =>
      _titleCache.containsKey(_titleKey(title));

  // --------------------------------------------------------------- batching

  final Map<int, Completer<String?>> _pendingIds = <int, Completer<String?>>{};
  final Map<int, Completer<String?>> _pendingBanners =
      <int, Completer<String?>>{};
  final Map<String, Completer<String?>> _pendingTitles =
      <String, Completer<String?>>{};
  final Map<String, String> _pendingTitleText = <String, String>{};
  Timer? _flushTimer;

  Future<String?> posterFor(int malId) {
    if (malId <= 0) return Future<String?>.value();
    if (_cache.containsKey(malId)) {
      final value = _cache.remove(malId);
      _cache[malId] = value; // LRU touch
      return Future<String?>.value(value);
    }
    final queued = _pendingIds[malId];
    if (queued != null) return queued.future;

    final completer = Completer<String?>();
    _pendingIds[malId] = completer;
    _scheduleFlush();
    return completer.future;
  }

  /// The wide artwork for [malId], the way Harbor resolves one: whatever
  /// AniList carries, then AniZip's own mapping — which reaches TheTVDB's
  /// backgrounds and Kitsu's cover — and nothing if none of them has it.
  ///
  /// Rides the same batch the posters do, so a screen of cards asking for
  /// both costs one request rather than two.
  Future<String?> bannerFor(int malId) {
    if (malId <= 0) return Future<String?>.value();
    if (_bannerCache.containsKey(malId)) {
      final value = _bannerCache.remove(malId);
      _bannerCache[malId] = value; // LRU touch
      return Future<String?>.value(value);
    }
    final queued = _pendingBanners[malId];
    if (queued != null) return queued.future;

    final completer = Completer<String?>();
    _pendingBanners[malId] = completer;
    _scheduleFlush();
    return completer.future;
  }

  /// For catalog entries with no id at all. Matching on a title is less
  /// certain than on an id, which is why it is only reached when there is no
  /// id to use.
  Future<String?> posterForTitle(String title) {
    final key = _titleKey(title);
    if (key.isEmpty) return Future<String?>.value();
    if (_titleCache.containsKey(key)) {
      return Future<String?>.value(_titleCache[key]);
    }
    final queued = _pendingTitles[key];
    if (queued != null) return queued.future;

    final completer = Completer<String?>();
    _pendingTitles[key] = completer;
    _pendingTitleText[key] = title.trim();
    _scheduleFlush();
    return completer.future;
  }

  /// The window opens on the first request and is not extended by later ones:
  /// a grid being scrolled asks continuously, and restarting the timer each
  /// time would hold every card back for as long as the scrolling lasted.
  void _scheduleFlush() {
    _flushTimer ??= Timer(_batchWindow, _flush);
  }

  void _flush() {
    _flushTimer = null;

    if (_pendingIds.isNotEmpty || _pendingBanners.isNotEmpty) {
      // One query answers both: the ids waiting for a poster and the ids
      // waiting for a banner go out together, since AniList returns each
      // media's cover and banner in the same record.
      final ids = <int>{
        ..._pendingIds.keys,
        ..._pendingBanners.keys,
      }.take(_idsPerQuery).toList();
      final waiting = <int, Completer<String?>>{
        for (final id in ids)
          if (_pendingIds.containsKey(id)) id: _pendingIds.remove(id)!,
      };
      final bannerWaiting = <int, Completer<String?>>{
        for (final id in ids)
          if (_pendingBanners.containsKey(id)) id: _pendingBanners.remove(id)!,
      };
      unawaited(_runIdBatch(ids, waiting, bannerWaiting));
    }

    if (_pendingTitles.isNotEmpty) {
      final keys = _pendingTitles.keys.take(_titlesPerQuery).toList();
      final waiting = <String, Completer<String?>>{
        for (final key in keys) key: _pendingTitles.remove(key)!,
      };
      final texts = <String, String>{
        for (final key in keys) key: _pendingTitleText.remove(key) ?? key,
      };
      unawaited(_runTitleBatch(keys, texts, waiting));
    }

    // More than one query's worth arrived at once; the rest go out next tick.
    if (_pendingIds.isNotEmpty ||
        _pendingBanners.isNotEmpty ||
        _pendingTitles.isNotEmpty) {
      _scheduleFlush();
    }
  }

  Future<void> _runIdBatch(
    List<int> ids,
    Map<int, Completer<String?>> waiting,
    Map<int, Completer<String?>> bannerWaiting,
  ) async {
    Map<int, String> found;
    var banners = <int, String>{};
    // Whether AniList actually answered. A batch that never reached it has
    // learned nothing about these ids — see [_runIdBatch]'s use below.
    var answered = true;
    try {
      final result = await _aniListByMalIds(ids);
      found = result.covers;
      banners = result.banners;
    } catch (e) {
      if (kDebugMode) debugPrint('[Artwork] AniList id batch failed: $e');
      found = <int, String>{};
      answered = false;
    }

    // AniList did not know these; AniZip and Kitsu are the last places worth
    // asking, and only for the handful that are still missing.
    final missing = ids.where((id) => !found.containsKey(id)).toList();
    if (missing.isNotEmpty) {
      final extra = await Future.wait(
        missing.map((id) => _aniZipPoster(id).catchError((Object _) => null)),
      );
      for (var i = 0; i < missing.length; i++) {
        final url = extra[i];
        if (url != null && url.isNotEmpty) found[missing[i]] = url;
      }
    }

    // Anything still without a banner is worth one more ask: AniZip's
    // mapping carries TheTVDB's backgrounds, and Kitsu's cover behind that.
    final needBanner = bannerWaiting.keys
        .where((id) => !banners.containsKey(id))
        .toList();
    if (needBanner.isNotEmpty) {
      final extra = await Future.wait(
        needBanner.map(
          (id) => _aniZipBanner(id).catchError((Object _) => null),
        ),
      );
      for (var i = 0; i < needBanner.length; i++) {
        final url = extra[i];
        if (url != null && url.isNotEmpty) banners[needBanner[i]] = url;
      }
    }

    if (kDebugMode) {
      debugPrint('[Artwork] ids: ${ids.length} asked, ${found.length} found');
    }
    for (final id in ids) {
      final url = found[id];
      if (waiting.containsKey(id)) {
        // A miss is only worth remembering when something actually said no.
        // Recording one after a failed request turns a moment without a
        // connection into "this anime has no artwork" for the rest of the
        // session — fifty titles at a time, since that is the batch — and
        // nothing ever looks again.
        if (url != null || answered) {
          _remember(id, url);
          _markDirty(url);
        }
        waiting[id]?.complete(url);
      }
      if (bannerWaiting.containsKey(id)) {
        final banner = banners[id];
        if (banner != null || answered) {
          _rememberBanner(id, banner);
          _markDirty(banner);
        }
        bannerWaiting[id]?.complete(banner);
      }
    }
    _schedulePersist();
  }

  Future<void> _runTitleBatch(
    List<String> keys,
    Map<String, String> texts,
    Map<String, Completer<String?>> waiting,
  ) async {
    Map<String, String> found;
    var answered = true;
    try {
      found = await _aniListByTitles(keys, texts);
    } catch (e) {
      if (kDebugMode) debugPrint('[Artwork] AniList title batch failed: $e');
      found = <String, String>{};
      answered = false;
    }
    if (kDebugMode) {
      debugPrint(
        '[Artwork] titles: ${keys.length} asked, ${found.length} found',
      );
    }
    for (final key in keys) {
      final url = found[key];
      // As above: only an answer teaches us anything about a title.
      if (url != null || answered) {
        _rememberTitle(key, url);
        _markDirty(url);
      }
      waiting[key]?.complete(url);
    }
    _schedulePersist();
  }

  // ---------------------------------------------------------------- AniList

  /// Unknown ids are simply absent from the page, so one bad id cannot cost
  /// the rest of the screen its artwork.
  Future<({Map<int, String> covers, Map<int, String> banners})>
  _aniListByMalIds(List<int> ids) async {
    const query =
        'query (\$ids: [Int]) { Page(perPage: $_idsPerQuery) { '
        'media(idMal_in: \$ids, type: ANIME) { '
        'idMal bannerImage coverImage { extraLarge large medium } } } }';

    final response = await _post(<String, dynamic>{
      'query': query,
      'variables': <String, dynamic>{'ids': ids},
    });
    final media = ((response?['data'] as Map?)?['Page'] as Map?)?['media'];
    final covers = <int, String>{};
    final banners = <int, String>{};
    if (media is! List) return (covers: covers, banners: banners);
    for (final raw in media) {
      if (raw is! Map) continue;
      final idMal = raw['idMal'];
      if (idMal is! num) continue;
      final id = idMal.toInt();
      final url = _coverUrl(raw['coverImage']);
      if (url != null) covers[id] = url;
      final banner = '${raw['bannerImage'] ?? ''}'.trim();
      if (banner.isNotEmpty && banner != 'null') banners[id] = banner;
    }
    return (covers: covers, banners: banners);
  }

  /// Searches are aliased into one document. `Page` is used rather than a bare
  /// `Media` because a search that matches nothing then yields an empty list
  /// instead of a 404, which would discard every other result in the batch.
  Future<Map<String, String>> _aniListByTitles(
    List<String> keys,
    Map<String, String> texts,
  ) async {
    final params = <String>[];
    final fields = <String>[];
    final variables = <String, dynamic>{};
    for (var i = 0; i < keys.length; i++) {
      params.add('\$t$i: String');
      fields.add(
        't$i: Page(perPage: 1) { media(search: \$t$i, type: ANIME) { '
        'coverImage { extraLarge large medium } } }',
      );
      variables['t$i'] = texts[keys[i]];
    }

    final response = await _post(<String, dynamic>{
      'query': 'query (${params.join(', ')}) { ${fields.join(' ')} }',
      'variables': variables,
    });
    final data = response?['data'];
    final out = <String, String>{};
    if (data is! Map) return out;
    for (var i = 0; i < keys.length; i++) {
      final media = (data['t$i'] as Map?)?['media'];
      if (media is! List || media.isEmpty) continue;
      final url = _coverUrl((media.first as Map?)?['coverImage']);
      if (url != null) out[keys[i]] = url;
    }
    return out;
  }

  Future<Map<String, dynamic>?> _post(Map<String, dynamic> body) async {
    final response = await _dio.post<Map<String, dynamic>>(
      'https://graphql.anilist.co',
      data: body,
      options: Options(contentType: Headers.jsonContentType),
    );
    return response.data;
  }

  String? _coverUrl(Object? cover) {
    if (cover is! Map) return null;
    for (final size in const <String>['extraLarge', 'large', 'medium']) {
      final url = '${cover[size] ?? ''}'.trim();
      if (url.isNotEmpty) return url;
    }
    return null;
  }

  // ------------------------------------------------------- AniZip and Kitsu

  Future<String?> _aniZipPoster(int malId) async {
    final mapping = await _dio.get<Map<String, dynamic>>(
      'https://api.ani.zip/mappings',
      queryParameters: <String, dynamic>{'mal_id': malId},
    );
    final data = mapping.data;
    if (data == null) return null;

    // AniZip's own poster sits on TheTVDB, which refuses some requests, so
    // Kitsu is asked first and TheTVDB kept as the last thing to try.
    final kitsuId = (data['mappings'] as Map?)?['kitsu_id'];
    final kitsu = kitsuId is num ? kitsuId.toInt() : null;
    if (kitsu != null && kitsu > 0) {
      final poster = await _kitsuPoster(kitsu);
      if (poster != null) return poster;
    }
    return _posterFromImages(data['images']);
  }

  /// The wide art AniZip knows about: TheTVDB's own backgrounds first, then
  /// Kitsu's cover, which is the same shape.
  Future<String?> _aniZipBanner(int malId) async {
    final mapping = await _dio.get<Map<String, dynamic>>(
      'https://api.ani.zip/mappings',
      queryParameters: <String, dynamic>{'mal_id': malId},
    );
    final data = mapping.data;
    if (data == null) return null;

    final fromImages = _imageOfType(data['images'], const <String>[
      'fanart',
      'background',
      'banner',
    ]);
    if (fromImages != null) return fromImages;

    final kitsuId = (data['mappings'] as Map?)?['kitsu_id'];
    final kitsu = kitsuId is num ? kitsuId.toInt() : null;
    if (kitsu != null && kitsu > 0) return _kitsuCover(kitsu);
    return null;
  }

  /// The first image whose `coverType` is one of [types], in that order.
  String? _imageOfType(Object? images, List<String> types) {
    if (images is! List) return null;
    for (final type in types) {
      for (final raw in images) {
        if (raw is! Map) continue;
        if ('${raw['coverType']}'.toLowerCase() != type) continue;
        final url = '${raw['url']}'.trim();
        if (url.isNotEmpty) return url;
      }
    }
    return null;
  }

  Future<String?> _kitsuCover(int kitsuId) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        'https://kitsu.app/api/edge/anime/$kitsuId',
        options: Options(
          headers: <String, String>{'Accept': 'application/vnd.api+json'},
        ),
      );
      final cover =
          ((response.data?['data'] as Map?)?['attributes']
              as Map?)?['coverImage'];
      if (cover is! Map) return null;
      for (final size in const <String>['original', 'large', 'small']) {
        final url = '${cover[size] ?? ''}'.trim();
        if (url.isNotEmpty) return url;
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[Artwork] Kitsu cover lookup failed: $e');
    }
    return null;
  }

  String? _posterFromImages(Object? images) {
    if (images is! List) return null;
    for (final raw in images) {
      if (raw is! Map) continue;
      if ('${raw['coverType']}'.toLowerCase() != 'poster') continue;
      final url = '${raw['url']}'.trim();
      if (url.isNotEmpty) return url;
    }
    return null;
  }

  Future<String?> _kitsuPoster(int kitsuId) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        'https://kitsu.app/api/edge/anime/$kitsuId',
        options: Options(
          headers: <String, String>{'Accept': 'application/vnd.api+json'},
        ),
      );
      final poster =
          ((response.data?['data'] as Map?)?['attributes']
              as Map?)?['posterImage'];
      if (poster is! Map) return null;
      for (final size in const <String>['large', 'original', 'medium']) {
        final url = '${poster[size] ?? ''}'.trim();
        if (url.isNotEmpty) return url;
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[Artwork] Kitsu poster lookup failed: $e');
    }
    return null;
  }
}

@riverpod
ArtworkFallbackService artworkFallbackService(Ref ref) {
  return ArtworkFallbackService(
    ref.watch(dioClientProvider),
    ref.watch(storageServiceProvider),
  );
}
