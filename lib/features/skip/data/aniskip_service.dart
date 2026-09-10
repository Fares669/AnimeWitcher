import 'dart:collection';

import 'package:dio/dio.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'skip_service.dart';
import '../../../../core/logger/app_logger.dart';
import '../../../../core/network/dio_client_provider.dart';

part 'aniskip_service.g.dart';

/// AniSkip (https://github.com/aniskip) — crowd-sourced opening/ending
/// timestamps keyed by MyAnimeList id.
///
/// Unlike anime-skip.com this needs no client id, so it works in every
/// build; it is the primary source for anime intro/credits segments.
class AniSkipService implements SkipService {
  final Dio _dio;

  AniSkipService(this._dio);

  @override
  String get name => 'AniSkip';

  /// Only the clean-cut types. `mixed-op` / `mixed-ed` are openings and
  /// endings that play over episode content — skipping those would skip
  /// story, and they also come back even when their timings belong to a
  /// different release, which would show a second, wrong "Skip intro".
  static const List<String> _types = <String>['op', 'ed', 'recap'];

  // Same caching shape as IntroDB: an hour of results, LRU-capped, so
  // seeking around an episode doesn't re-query per seek.
  static const int _cacheMax = 500;
  static const Duration _cacheTtl = Duration(hours: 1);
  static final LinkedHashMap<String, _CachedSegments> _cache =
      LinkedHashMap<String, _CachedSegments>();

  // Global cool-off after a 429 so we don't amplify a rate limit.
  static DateTime? _rateLimitUntil;

  // The response depends on the episode length we send, so it is part of
  // the key — a lookup made before the duration was known must not shadow
  // the better-matched one that follows.
  String _key(int malId, int episode, int episodeLength) =>
      '$malId:$episode:$episodeLength';

  List<SkipSegment>? _lookupCached(String key) {
    final entry = _cache[key];
    if (entry == null) return null;
    if (DateTime.now().isAfter(entry.expiresAt)) {
      _cache.remove(key);
      return null;
    }
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

  static SkipType _typeFor(Object? raw) {
    switch (raw?.toString().toLowerCase()) {
      case 'op':
      case 'mixed-op':
        return SkipType.intro;
      case 'ed':
      case 'mixed-ed':
        return SkipType.outro;
      case 'recap':
        return SkipType.recap;
      default:
        return SkipType.unknown;
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
    if (malId == null || malId <= 0) return [];

    // `episodeLength` filters rather than scales: asking with this file's
    // 1440 seconds when the submission was timed against a 1529-second
    // release answers "no skip times found", even though the timings are
    // there and usable. So every submission is fetched — that is what 0
    // means — and the one whose own length sits closest to this file is
    // chosen below, which is the matching this needs anyway.
    //
    // Dio's default list encoding writes the repeated
    // `types[]=op&types[]=ed&...` form the API expects.
    const episodeLength = 0;

    final key = _key(malId, episode, duration ?? 0);
    final cached = _lookupCached(key);
    if (cached != null) return cached;

    final until = _rateLimitUntil;
    if (until != null && DateTime.now().isBefore(until)) return [];

    // Whether AniSkip actually told us something. An empty result is only
    // worth remembering for an hour when it came from the service saying so.
    var answered = false;

    try {
      final response = await _dio.get<Map<String, dynamic>>(
        'https://api.aniskip.com/v2/skip-times/$malId/$episode',
        queryParameters: <String, dynamic>{
          'types': _types,
          'episodeLength': episodeLength,
        },
      );
      final data = response.data;
      answered = response.statusCode == 200;
      if (answered && data != null && data['found'] == true) {
        final results = data['results'];
        // The API can return several submissions of the same type, each
        // timed against a different release length. Keep one per type —
        // the one whose episodeLength sits closest to this file's.
        final best = <SkipType, _Candidate>{};
        if (results is List) {
          for (final raw in results) {
            if (raw is! Map) continue;
            final interval = raw['interval'];
            if (interval is! Map) continue;
            final start = (interval['startTime'] as num?)?.toDouble();
            final end = (interval['endTime'] as num?)?.toDouble();
            if (start == null || end == null) continue;
            final type = _typeFor(raw['skipType']);
            if (type == SkipType.unknown) continue;

            final entryLength = (raw['episodeLength'] as num?)?.toDouble();
            final drift = (duration != null && entryLength != null)
                ? (entryLength - duration).abs()
                : double.infinity;
            final current = best[type];
            if (current == null || drift < current.drift) {
              best[type] = _Candidate(
                SkipSegment(startTime: start, endTime: end, type: type),
                drift,
              );
            }
          }
        }

        final cleaned = SkipSegment.sanitize(
          best.values.map((c) => c.segment).toList(),
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
          'AniSkip rate-limited; holding off ${retryAfter.inSeconds}s',
        );
      }
      // 404 simply means nobody has submitted timestamps for this episode —
      // an answer, and one worth remembering. A rate limit or a server error
      // is not: it says nothing about whether the timings exist.
      if (e.response?.statusCode == 404) answered = true;
    } catch (_) {
      // Ignore — the caller treats an empty list as "no skip data".
    }

    // Cache the miss too, so a seek-heavy session doesn't re-ask every time.
    //
    // Only a real one, though. Caching a request that failed would hide the
    // skip button for the rest of the hour over a moment without a
    // connection, and the viewer would have no way to ask again — which is
    // exactly what "AniSkip doesn't work" looks like from the outside.
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

/// A candidate segment plus how far its submitted episode length is from
/// the file being played — lower wins when a type has several entries.
class _Candidate {
  _Candidate(this.segment, this.drift);
  final SkipSegment segment;
  final double drift;
}

@riverpod
AniSkipService aniSkipService(Ref ref) {
  return AniSkipService(ref.watch(dioClientProvider));
}
