import 'dart:collection';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../../core/logger/app_logger.dart';
import '../../../../core/network/dio_client_provider.dart';
import '../../../../core/storage/storage_service.dart';
import 'skip_id_persistence.dart';

part 'mal_id_resolver.g.dart';

/// Reads a MyAnimeList id out of one service's search response.
///
/// Pulled out of the network code so the shape of each service's answer can
/// be tested without one.
class MalIdParsers {
  MalIdParsers._();

  /// AniList: `data.Media.idMal`.
  static int? aniList(Object? body) {
    final media = _map(body)?['data'];
    final node = _map(media)?['Media'];
    final id = _map(node)?['idMal'];
    return _positive(id);
  }

  /// Kitsu's mapping list: the entry whose site is `myanimelist/anime`.
  ///
  /// Kitsu carries mappings for AniDB, TheTVDB and MAL alike, and the ids are
  /// strings there, so the MAL one has to be picked out by name and parsed.
  static int? kitsuMappings(Object? body) {
    final data = _map(body)?['data'];
    if (data is! List) return null;
    for (final raw in data) {
      final attributes = _map(_map(raw)?['attributes']);
      if (attributes == null) continue;
      if ('${attributes['externalSite']}' != 'myanimelist/anime') continue;
      return _positive(attributes['externalId']);
    }
    return null;
  }

  /// The Kitsu hit whose title actually matches [search].
  ///
  /// Kitsu ranks loosely: searching "Mao" answers with "Mao Zhi Ming", "Mao
  /// Yu Tao Hua Yuan" and three other unrelated shows. Taking the first hit
  /// meant resolving a wrong MyAnimeList id and asking AniSkip for another
  /// anime's timings — worse than having none, because the button would
  /// appear and skip into the episode.
  static String? kitsuMatchingId(Object? body, String search) {
    final data = _map(body)?['data'];
    if (data is! List || data.isEmpty) return null;
    final needle = _comparable(search);
    if (needle.isEmpty) return null;

    String? prefixMatch;
    for (final raw in data) {
      final node = _map(raw);
      final attributes = _map(node?['attributes']);
      if (node == null || attributes == null) continue;
      final id = node['id']?.toString().trim();
      if (id == null || id.isEmpty) continue;

      final candidates = <Object?>[
        attributes['canonicalTitle'],
        ...?(_map(attributes['titles'])?.values),
        ...?(attributes['abbreviatedTitles'] as List?),
      ];
      for (final candidate in candidates) {
        if (candidate == null) continue;
        final value = _comparable('$candidate');
        if (value.isEmpty) continue;
        if (value == needle) return id;

        // A catalog title and a service's title often differ past the series
        // name — "…ga: Suuguu Chouso Torikae Den" against "…ga Hinamiya Chou
        // Nezumi Torikae Den". One being the start of the other is a match,
        // but only when there is enough of it to mean something: "mao" is
        // the start of "maozhiming" and has nothing to do with it.
        const minimumPrefix = 8;
        final shorter = value.length < needle.length ? value : needle;
        final longer = value.length < needle.length ? needle : value;
        if (shorter.length >= minimumPrefix && longer.startsWith(shorter)) {
          prefixMatch ??= id;
        }
      }
    }
    return prefixMatch;
  }

  /// The AniList id Kitsu knows, for shows it has no MAL mapping for.
  static int? kitsuAniListId(Object? body) {
    final data = _map(body)?['data'];
    if (data is! List) return null;
    for (final raw in data) {
      final attributes = _map(_map(raw)?['attributes']);
      if (attributes == null) continue;
      if ('${attributes['externalSite']}' != 'anilist/anime') continue;
      return _positive(attributes['externalId']);
    }
    return null;
  }

  /// ani.zip's cross-service mapping: `mappings.mal_id`.
  static int? aniZip(Object? body) {
    final mappings = _map(_map(body)?['mappings']);
    return _positive(mappings?['mal_id']);
  }

  /// Case, punctuation and spacing removed, so "MAO" matches "Mao" and
  /// "Re:Zero" matches "Re Zero".
  static String _comparable(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9؀-ۿ]'), '');

  /// Jikan (MyAnimeList's own read API): `data[0].mal_id`.
  static int? jikan(Object? body) {
    final data = _map(body)?['data'];
    if (data is! List || data.isEmpty) return null;
    return _positive(_map(data.first)?['mal_id']);
  }

  static Map<String, dynamic>? _map(Object? value) =>
      value is Map ? value.map((k, v) => MapEntry(k.toString(), v)) : null;

  static int? _positive(Object? raw) {
    final value = raw is num ? raw.toInt() : int.tryParse('$raw');
    return (value != null && value > 0) ? value : null;
  }
}

/// Resolves an anime title to a MyAnimeList id.
///
/// AniSkip is keyed by MAL id and the catalog identifies anime by title, so
/// every skip lookup depends on this bridge. It used to be a single AniList
/// query, which meant AniList having a bad day — as it did when this was
/// written, answering every request with "temporarily disabled due to severe
/// stability issues" — took the skip button away for every anime in the app.
///
/// So it asks three services in turn and takes the first answer: AniList,
/// then Kitsu (which keeps MAL among its cross-site mappings), then Jikan,
/// MyAnimeList's own read API. They fail independently.
class MalIdResolver {
  final Dio _dio;
  final StorageService? _storage;

  MalIdResolver(this._dio, [this._storage]);

  static const String _aniListEndpoint = 'https://graphql.anilist.co';
  static const String _kitsuEndpoint = 'https://kitsu.io/api/edge/anime';
  static const String _jikanEndpoint = 'https://api.jikan.moe/v4/anime';
  static const String _aniZipEndpoint = 'https://api.ani.zip/mappings';

  static const String _storageKey = 'mal_id_by_title_json';

  /// A title's id never changes, so the only reason to bound this is size.
  static const int _diskMax = 500;

  static const String _query = r'''
query ($search: String) {
  Media(search: $search, type: ANIME) {
    idMal
  }
}
''';

  static const int _cacheMax = 300;
  static final LinkedHashMap<String, int?> _cache =
      LinkedHashMap<String, int?>();

  /// Per-service, so one service being throttled doesn't silence the others.
  static final Map<String, DateTime> _rateLimitUntil = <String, DateTime>{};

  /// Strips the release noise a catalog title often carries so the search
  /// text stays close to the official title the services index.
  static String normalizeTitle(String raw) {
    var value = raw.trim();
    if (value.isEmpty) return value;
    value = value.replaceAll(RegExp(r'\s*[\(\[][^\)\]]*[\)\]]'), ' ');
    value = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    return value;
  }

  /// The titles to try, in order, from the one the catalog gave us.
  ///
  /// A catalog title carries the season with it — "Mushoku Tensei III",
  /// "... ga: Suuguu Chouso Torikae Den" — and the metadata services index
  /// their own spelling of that. Searching the whole string finds nothing
  /// when their spelling differs; the shorter forms still find the series.
  static List<String> titleVariants(String raw) {
    final base = normalizeTitle(raw);
    if (base.isEmpty) return const <String>[];

    final variants = <String>[base];

    void add(String candidate) {
      final value = normalizeTitle(candidate);
      if (value.length < 3) return;
      if (variants.any((v) => v.toLowerCase() == value.toLowerCase())) return;
      variants.add(value);
    }

    // Everything before a subtitle marker.
    for (final marker in <String>[':', ' - ', '：']) {
      final index = base.indexOf(marker);
      if (index > 0) add(base.substring(0, index));
    }

    // A trailing season marker: "Season 2", "2nd Season", "III", "Part 2".
    add(
      base.replaceAll(
        RegExp(
          r'\s+((season\s*\d+)|(\d+(st|nd|rd|th)\s+season)|(part\s*\d+)|'
          r'(ii|iii|iv|v|vi|vii|viii|ix|x))$',
          caseSensitive: false,
        ),
        '',
      ),
    );

    return variants;
  }

  static int? parsePositiveId(String? raw) {
    final value = raw == null ? null : int.tryParse(raw.trim());
    return (value != null && value > 0) ? value : null;
  }

  /// Resolves a MyAnimeList id from direct ids, AniList/AniDB mappings, then titles.
  Future<int?> resolveForItem({
    Map<String, String>? syncData,
    String? title,
    List<String> alternativeTitles = const <String>[],
  }) async {
    final direct =
        parsePositiveId(syncData?['malId']) ??
        parsePositiveId(syncData?['mal_id']) ??
        parsePositiveId(syncData?['awMalId']);
    if (direct != null) return direct;

    final aniListId =
        parsePositiveId(syncData?['anilist']) ??
        parsePositiveId(syncData?['anilistId']) ??
        parsePositiveId(syncData?['anilist_id']);
    final aniDbId =
        parsePositiveId(syncData?['anidbId']) ??
        parsePositiveId(syncData?['anidb_id']);
    final fromExternal = await resolveExternalIds(
      aniListId: aniListId,
      aniDbId: aniDbId,
    );
    if (fromExternal != null) return fromExternal;

    final seen = <String>{};
    for (final raw in <String?>[title, ...alternativeTitles]) {
      final candidate = raw?.trim() ?? '';
      if (candidate.isEmpty || !seen.add(candidate.toLowerCase())) continue;
      final resolved = await resolve(candidate);
      if (resolved != null) return resolved;
    }
    return null;
  }

  /// Resolves a MyAnimeList id from AniList or AniDB ids via ani.zip.
  Future<int?> resolveExternalIds({int? aniListId, int? aniDbId}) async {
    for (final entry in <(String param, String prefix, int? id)>[
      ('anilist_id', 'anilist', aniListId),
      ('anidb_id', 'anidb', aniDbId),
    ]) {
      final id = entry.$3;
      if (id == null || id <= 0) continue;
      final cacheKey = '${entry.$2}:$id';
      if (_cache.containsKey(cacheKey)) {
        final hit = _cache[cacheKey];
        if (hit != null) {
          _cache.remove(cacheKey);
          _cache[cacheKey] = hit;
          return hit;
        }
        continue;
      }
      final stored = _readStored(cacheKey);
      if (stored != null) {
        _remember(cacheKey, stored);
        return stored;
      }
      _sourceUnavailable = false;
      final resolved = await _fromAniZipBy(entry.$1, id);
      if (resolved != null) {
        _remember(cacheKey, resolved);
        await _store(cacheKey, resolved);
        return resolved;
      }
      if (!_sourceUnavailable) _remember(cacheKey, null);
    }
    return null;
  }

  Future<int?> resolve(String title) async {
    final search = normalizeTitle(title);
    if (search.isEmpty) return null;

    final key = search.toLowerCase();
    if (_cache.containsKey(key)) {
      final cached = _cache.remove(key);
      _cache[key] = cached; // LRU touch
      return cached;
    }

    // Written to disk, so a title resolved once stays resolved across
    // launches — and keeps working while every one of these services is
    // unreachable.
    final stored = _readStored(key);
    if (stored != null) {
      _remember(key, stored);
      return stored;
    }

    _sourceUnavailable = false;
    for (final variant in titleVariants(search)) {
      for (final lookup in <Future<int?> Function(String)>[
        _fromAniList,
        _fromKitsu,
        _fromJikan,
      ]) {
        final resolved = await lookup(variant);
        if (resolved != null) {
          _remember(key, resolved);
          await _store(key, resolved);
          return resolved;
        }
      }
    }

    // "Nobody has it" is worth remembering for the session. "Nobody could be
    // asked" is not: Kitsu answers the same query with a 500 often enough
    // that caching that as a miss would cost the anime its skip button for
    // as long as the app stayed open.
    if (!_sourceUnavailable) _remember(key, null);
    return null;
  }

  /// Set when a lookup failed for a reason that says nothing about whether
  /// the anime exists.
  bool _sourceUnavailable = false;

  Future<int?> _fromAniList(String search) async {
    if (_throttled(_aniListEndpoint)) return null;
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        _aniListEndpoint,
        data: <String, dynamic>{
          'query': _query,
          'variables': <String, dynamic>{'search': search},
        },
        options: Options(contentType: Headers.jsonContentType),
      );
      return MalIdParsers.aniList(response.data);
    } on DioException catch (e) {
      _noteFailure(_aniListEndpoint, e, 'AniList');
    } catch (_) {}
    return null;
  }

  Future<int?> _fromKitsu(String search) async {
    if (_throttled(_kitsuEndpoint)) return null;
    // Kitsu returns a 500 for perfectly good queries often enough that a
    // single attempt is not an answer. Two are.
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final hits = await _dio.get<Map<String, dynamic>>(
          _kitsuEndpoint,
          queryParameters: <String, dynamic>{
            'filter[text]': search,
            'page[limit]': 10,
          },
          options: Options(headers: {'Accept': 'application/vnd.api+json'}),
        );
        final kitsuId = MalIdParsers.kitsuMatchingId(hits.data, search);
        if (kitsuId == null) return null;

        final mappings = await _dio.get<Map<String, dynamic>>(
          '$_kitsuEndpoint/$kitsuId/mappings',
          options: Options(headers: {'Accept': 'application/vnd.api+json'}),
        );
        final malId = MalIdParsers.kitsuMappings(mappings.data);
        if (malId != null) return malId;

        // Kitsu carries no MyAnimeList mapping for some newer shows, but it
        // does carry their AniList id, and ani.zip maps that to MAL — which
        // is how the id is reached while AniList's own API is refusing.
        final aniListId = MalIdParsers.kitsuAniListId(mappings.data);
        if (aniListId == null) return null;
        return _fromAniZipBy('anilist_id', aniListId);
      } on DioException catch (e) {
        _noteFailure(_kitsuEndpoint, e, 'Kitsu');
        final status = e.response?.statusCode ?? 0;
        if (status < 500 && status != 0) return null;
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  /// ani.zip's mapping table, reached with an AniList or AniDB id.
  Future<int?> _fromAniZipBy(String paramName, int id) async {
    if (id <= 0 || _throttled(_aniZipEndpoint)) return null;
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        _aniZipEndpoint,
        queryParameters: <String, dynamic>{paramName: id},
      );
      return MalIdParsers.aniZip(response.data);
    } on DioException catch (e) {
      _noteFailure(_aniZipEndpoint, e, 'ani.zip');
    } catch (_) {}
    return null;
  }

  Future<int?> _fromJikan(String search) async {
    if (_throttled(_jikanEndpoint)) return null;
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        _jikanEndpoint,
        queryParameters: <String, dynamic>{'q': search, 'limit': 1},
      );
      return MalIdParsers.jikan(response.data);
    } on DioException catch (e) {
      // Jikan answers 504 when MyAnimeList itself is unreachable, which is
      // its way of saying "not now" rather than "no such anime".
      _noteFailure(_jikanEndpoint, e, 'Jikan');
    } catch (_) {}
    return null;
  }

  bool _throttled(String endpoint) {
    final until = _rateLimitUntil[endpoint];
    if (until == null) return false;
    if (DateTime.now().isBefore(until)) return true;
    _rateLimitUntil.remove(endpoint);
    return false;
  }

  void _noteFailure(String endpoint, DioException e, String name) {
    final status = e.response?.statusCode;
    _sourceUnavailable = true;
    if (status == 429 || status == 403 || status == 503) {
      _rateLimitUntil[endpoint] = DateTime.now().add(
        const Duration(minutes: 10),
      );
      talker.debug('$name id lookup unavailable ($status); resting it');
    }
  }

  void _remember(String key, int? value) {
    _cache.remove(key);
    _cache[key] = value;
    while (_cache.length > _cacheMax) {
      _cache.remove(_cache.keys.first);
    }
  }

  int? _readStored(String key) {
    final storage = _storage;
    if (storage == null) return null;
    try {
      final raw = storage.getString(_storageKey);
      if (raw == null || raw.trim().isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final value = decoded[key];
      return (value is num && value > 0) ? value.toInt() : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _store(String key, int malId) =>
      saveSkipId(_storage, _storageKey, key, _diskMax, () => malId);
}

@riverpod
MalIdResolver malIdResolver(Ref ref) {
  return MalIdResolver(
    ref.watch(dioClientProvider),
    ref.watch(storageServiceProvider),
  );
}
