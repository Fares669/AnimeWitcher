import 'dart:collection';

import 'package:dio/dio.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'skip_service.dart';
import '../../../../core/logger/app_logger.dart';
import '../../../../core/network/dio_client_provider.dart';

part 'intro_db_service.g.dart';

class IntroDbService implements SkipService {
  final Dio _dio;

  IntroDbService(this._dio);

  @override
  String get name => 'IntroDB';

  // Cache results for an hour. Power-users fast-skipping through episodes
  // would otherwise hammer the public API on every seek. LRU-capped so an
  // all-day binge doesn't accumulate unbounded entries.
  static const int _cacheMax = 500;
  static const Duration _cacheTtl = Duration(hours: 1);
  static final LinkedHashMap<String, _CachedSegments> _cache =
      LinkedHashMap<String, _CachedSegments>();

  // When the server returns 429, hold off for the Retry-After period
  // (capped at 5 min) before issuing any further requests across all
  // instances. Avoids amplifying rate-limits.
  static DateTime? _rateLimitUntil;

  /// v2 of the API. The one this used to call answered with a single object
  /// per kind and seconds; this one answers with a list per kind and
  /// milliseconds, and an open-ended span leaves one end null — an intro
  /// that starts at the first frame, credits that run to the last.
  static const String _endpoint = 'https://api.theintrodb.org/v2/media';

  String _key(String id, int season, int episode) => '$id:$season:$episode';

  /// Reads the spans out of a v2 response.
  static List<SkipSegment> parseSegments(Object? body, {double? durationSec}) {
    final root = body is Map ? body : null;
    if (root == null) return const <SkipSegment>[];

    final out = <SkipSegment>[];
    void collect(String key, SkipType type) {
      final spans = root[key];
      if (spans is! List) return;
      for (final raw in spans) {
        if (raw is! Map) continue;
        final startMs = (raw['start_ms'] as num?)?.toDouble() ?? 0;
        final endMs =
            (raw['end_ms'] as num?)?.toDouble() ??
            (durationSec != null ? durationSec * 1000 : null);
        if (endMs == null || endMs <= startMs) continue;
        out.add(
          SkipSegment(
            startTime: startMs / 1000,
            endTime: endMs / 1000,
            type: type,
          ),
        );
      }
    }

    collect('intro', SkipType.intro);
    collect('recap', SkipType.recap);
    collect('credits', SkipType.outro);
    collect('preview', SkipType.outro);
    out.sort((a, b) => a.startTime.compareTo(b.startTime));
    return out;
  }

  List<SkipSegment>? _lookupCached(String key) {
    final entry = _cache[key];
    if (entry == null) return null;
    if (DateTime.now().isAfter(entry.expiresAt)) {
      _cache.remove(key);
      return null;
    }
    // LRU touch.
    _cache.remove(key);
    _cache[key] = entry;
    return entry.segments;
  }

  void _store(String key, List<SkipSegment> segments) {
    _cache.remove(key);
    _cache[key] = _CachedSegments(segments, DateTime.now().add(_cacheTtl));
    while (_cache.length > _cacheMax) {
      _cache.remove(_cache.keys.first);
    }
  }

  @override
  Future<List<SkipSegment>> getSkipSegments({
    int? tmdbId,
    String? imdbId,
    int? anilistId,
    int? malId,
    required int season,
    required int episode,
    int? duration,
  }) async {
    // Either id opens the door: v2 takes a TMDB id as readily as an IMDb
    // one, and anime reach us with whichever ani.zip happens to carry.
    if (imdbId == null && tmdbId == null) {
      return [];
    }

    final key = _key(imdbId ?? 'tmdb:$tmdbId', season, episode);
    final cached = _lookupCached(key);
    if (cached != null) return cached;

    final now = DateTime.now();
    final until = _rateLimitUntil;
    if (until != null && now.isBefore(until)) {
      return [];
    }

    // Whether IntroDB actually told us something. See the store below.
    var answered = false;

    try {
      final response = await _dio.get<Map<String, dynamic>>(
        _endpoint,
        queryParameters: <String, dynamic>{
          if (tmdbId != null) 'tmdb_id': tmdbId else 'imdb_id': imdbId,
          'season': season,
          'episode': episode,
        },
      );

      answered = response.statusCode == 200;
      if (answered && response.data != null) {
        final cleaned = SkipSegment.sanitize(
          parseSegments(response.data, durationSec: duration?.toDouble()),
          durationSec: duration?.toDouble(),
        );
        _store(key, cleaned);
        return cleaned;
      }
    } on DioException catch (e) {
      if (e.response?.statusCode == 429) {
        final retryAfter = _parseRetryAfter(
          e.response?.headers.value('retry-after'),
        );
        _rateLimitUntil = DateTime.now().add(retryAfter);
        talker.debug(
          'IntroDB rate-limited; holding off ${retryAfter.inSeconds}s',
        );
      }
      // A 404 is IntroDB saying it has nothing for this episode, which is
      // worth remembering. A rate limit or a network blip is not an answer
      // at all, and must not be stored as one.
      if (e.response?.statusCode == 404) answered = true;
    } catch (_) {
      // Ignore — caller treats empty list as "no skip data".
    }

    // Cache an empty result too, so we don't re-query a missing episode on
    // every seek — but only when the emptiness was IntroDB's answer rather
    // than a request that never arrived.
    if (answered) _store(key, const []);
    return [];
  }

  Duration _parseRetryAfter(String? header) {
    if (header == null) return const Duration(seconds: 60);
    final seconds = int.tryParse(header.trim());
    if (seconds == null || seconds < 0) return const Duration(seconds: 60);
    if (seconds > 300) return const Duration(minutes: 5);
    return Duration(seconds: seconds);
  }
}

class _CachedSegments {
  _CachedSegments(this.segments, this.expiresAt);
  final List<SkipSegment> segments;
  final DateTime expiresAt;
}

@riverpod
IntroDbService introDbService(Ref ref) {
  return IntroDbService(ref.watch(dioClientProvider));
}
