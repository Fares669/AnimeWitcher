import 'package:dio/dio.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'skip_api_support.dart';
import 'skip_service.dart';
import '../../../../core/logger/app_logger.dart';
import '../../../../core/network/dio_client_provider.dart';

part 'intro_db_service.g.dart';

class IntroDbService implements SkipService {
  final Dio _dio;

  IntroDbService(this._dio);

  @override
  String get name => 'IntroDB';

  static final _cache = SkipApiCache();

  // When the server returns 429, hold off for the Retry-After period
  // (capped at 5 min) before issuing any further requests across all
  // instances. Avoids amplifying rate-limits.
  static DateTime? _rateLimitUntil;

  static const String _endpoint = 'https://api.theintrodb.org/v4/media';

  String _key(String id, int? season, int? episode) => '$id:$season:$episode';

  /// Reads v4 segment arrays in milliseconds; a null endpoint is open-ended.
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

  @override
  Future<List<SkipSegment>> getSkipSegments({
    int? tmdbId,
    String? imdbId,
    int? anilistId,
    int? malId,
    required int? season,
    required int? episode,
    int? duration,
  }) async {
    // v4 resolves TMDB/IMDb ids to TVDB; no response identity is needed here.
    // Null coordinates identify a movie; TV requires both coordinates.
    if ((season == null) != (episode == null)) return [];
    if (imdbId == null && tmdbId == null) {
      return [];
    }

    final key = _key(imdbId ?? 'tmdb:$tmdbId', season, episode);
    final cached = _cache.lookup(key);
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
          if (season != null) 'season': season,
          if (episode != null) 'episode': episode,
        },
      );

      answered = response.statusCode == 200;
      if (answered && response.data != null) {
        final cleaned = SkipSegment.sanitize(
          parseSegments(response.data, durationSec: duration?.toDouble()),
          durationSec: duration?.toDouble(),
        );
        _cache.store(key, cleaned);
        return cleaned;
      }
    } on DioException catch (e) {
      if (e.response?.statusCode == 429) {
        final retryAfter = parseSkipRetryAfter(
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
    if (answered) _cache.store(key, const []);
    return [];
  }
}

@riverpod
IntroDbService introDbService(Ref ref) {
  return IntroDbService(ref.watch(dioClientProvider));
}
