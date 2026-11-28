/// Cross-service ids for an anime, from ani.zip's mapping table.
///
/// The catalog gives us a title. AniSkip wants a MyAnimeList id, and IntroDB
/// — a second, separate database of intro and credits timings — wants a TMDB
/// or IMDb id, which no anime source hands out. ani.zip keeps all of them
/// against each other, so one lookup off the MyAnimeList id opens the door to
/// a database that was otherwise unreachable for anime.
library;

import 'dart:collection';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../../core/network/dio_client_provider.dart';
import '../../../../core/storage/storage_service.dart';
import 'skip_id_persistence.dart';

part 'anime_id_mappings.g.dart';

class AnimeIds {
  const AnimeIds({this.imdbId, this.tmdbId, this.tvdbId, this.aniListId});

  final String? imdbId;
  final int? tmdbId;
  final int? tvdbId;
  final int? aniListId;

  bool get isEmpty =>
      imdbId == null && tmdbId == null && tvdbId == null && aniListId == null;

  /// Reads ani.zip's `mappings` block.
  static AnimeIds? parse(Object? body) {
    final root = body is Map ? body : null;
    final mappings = root?['mappings'];
    if (mappings is! Map) return null;

    final imdb = '${mappings['imdb_id'] ?? ''}'.trim();
    final ids = AnimeIds(
      imdbId: imdb.startsWith('tt') ? imdb : null,
      tmdbId: _int(mappings['themoviedb_id']),
      tvdbId: _int(mappings['thetvdb_id']),
      aniListId: _int(mappings['anilist_id']),
    );
    return ids.isEmpty ? null : ids;
  }

  static int? _int(Object? raw) {
    final value = raw is num ? raw.toInt() : int.tryParse('${raw ?? ''}');
    return (value != null && value > 0) ? value : null;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (imdbId != null) 'imdb': imdbId,
    if (tmdbId != null) 'tmdb': tmdbId,
    if (tvdbId != null) 'tvdb': tvdbId,
    if (aniListId != null) 'anilist': aniListId,
  };

  static AnimeIds? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final ids = AnimeIds(
      imdbId: raw['imdb']?.toString(),
      tmdbId: _int(raw['tmdb']),
      tvdbId: _int(raw['tvdb']),
      aniListId: _int(raw['anilist']),
    );
    return ids.isEmpty ? null : ids;
  }

  @override
  String toString() =>
      'AnimeIds(imdb: $imdbId, tmdb: $tmdbId, tvdb: $tvdbId, '
      'anilist: $aniListId)';
}

class AnimeIdMappings {
  AnimeIdMappings(this._dio, [this._storage]);

  final Dio _dio;
  final StorageService? _storage;

  static const String _endpoint = 'https://api.ani.zip/mappings';
  static const String _storageKey = 'anime_id_mappings_json';
  static const int _memoryMax = 200;
  static const int _diskMax = 400;

  static final LinkedHashMap<int, AnimeIds?> _cache =
      LinkedHashMap<int, AnimeIds?>();

  /// The other services' ids for the anime with this MyAnimeList id.
  Future<AnimeIds?> byMalId(int malId) async {
    if (malId <= 0) return null;
    if (_cache.containsKey(malId)) {
      final hit = _cache.remove(malId);
      _cache[malId] = hit;
      return hit;
    }

    final stored = _readStored(malId);
    if (stored != null) {
      _remember(malId, stored);
      return stored;
    }

    try {
      final response = await _dio.get<Map<String, dynamic>>(
        _endpoint,
        queryParameters: <String, dynamic>{'mal_id': malId},
      );
      final ids = AnimeIds.parse(response.data);
      _remember(malId, ids);
      if (ids != null) await _store(malId, ids);
      return ids;
    } catch (_) {
      // A failed lookup is not remembered: ani.zip being unreachable says
      // nothing about whether these ids exist.
      return null;
    }
  }

  void _remember(int malId, AnimeIds? ids) {
    _cache.remove(malId);
    _cache[malId] = ids;
    while (_cache.length > _memoryMax) {
      _cache.remove(_cache.keys.first);
    }
  }

  AnimeIds? _readStored(int malId) {
    final storage = _storage;
    if (storage == null) return null;
    try {
      final raw = storage.getString(_storageKey);
      if (raw == null || raw.trim().isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return AnimeIds.fromJson(decoded['$malId']);
    } catch (_) {
      return null;
    }
  }

  Future<void> _store(int malId, AnimeIds ids) =>
      saveSkipId(_storage, _storageKey, '$malId', _diskMax, ids.toJson);
}

@riverpod
AnimeIdMappings animeIdMappings(Ref ref) {
  return AnimeIdMappings(
    ref.watch(dioClientProvider),
    ref.watch(storageServiceProvider),
  );
}
