import 'dart:convert';

import 'package:dio/dio.dart';

import '../../domain/entity/multimedia_item.dart';
import '../../network/stale_connection_retry.dart';
import '../../utils/anime_rift_stream_identity.dart';
import 'anime_rift_api_client.dart';
export 'anime_rift_api_client.dart' show AnimeRiftAuthenticationRequired;

typedef _SourceIdentity = AnimeRiftSourceIdentity;

class AnimeRiftPlaybackUnavailable extends AnimeRiftAccessUnavailable {
  const AnimeRiftPlaybackUnavailable();
  @override
  String toString() => 'تعذر تشغيل هذا المصدر من Anime Rift. جرّب سيرفرًا آخر.';
}

class AnimeRiftStreams {
  AnimeRiftStreams(this.api, this.episodeNumber, {Dio? externalDio})
    : _external = externalDio ?? createAnimeWitcherDio();
  final AnimeRiftApiClient api;
  final Future<int> Function(String animeId, String episodeId) episodeNumber;
  final Dio _external;
  final _sources =
      <String, ({DateTime expires, Future<Map<String, dynamic>> value})>{};

  static bool isSourceSelection(String url) =>
      _SourceIdentity.parse(url)?.host != null;
  void invalidate() => _sources.clear();

  Future<_SourceIdentity> _identity(String url, {bool download = false}) async {
    final parsed = _SourceIdentity.parse(url);
    if (parsed == null) throw const AnimeRiftPlaybackUnavailable();
    final number =
        parsed.number ?? await episodeNumber(parsed.anime, parsed.episode);
    return _SourceIdentity(
      parsed.anime,
      parsed.episode,
      number: number,
      host: parsed.host,
      quality: parsed.quality,
      download: download || parsed.download,
    );
  }

  Future<Map<String, dynamic>> _raw(_SourceIdentity ref) async {
    final cached = _sources[ref.episodeUrl];
    if (cached != null && cached.expires.isAfter(DateTime.now()))
      return cached.value;
    final value = api.request(
      'library/episode/sources',
      'ANIME.LIBRARY.EPISODES.SOURCES.ALL',
      method: 'POST',
      body: {
        'animeId': ref.anime,
        'episodeId': ref.episode,
        'episode_number': ref.number,
      },
    );
    _sources[ref.episodeUrl] = (
      expires: DateTime.now().add(const Duration(minutes: 1)),
      value: value,
    );
    if (_sources.length > 32) _sources.remove(_sources.keys.first);
    try {
      return await value;
    } catch (_) {
      if (identical(_sources[ref.episodeUrl]?.value, value))
        _sources.remove(ref.episodeUrl);
      rethrow;
    }
  }

  Future<List<StreamResult>> loadSources(
    String url, {
    bool download = false,
  }) async {
    final ref = await _identity(url, download: download);
    // Catalog discovery can run as a guest. Protected download discovery must
    // await the stored Rift session before checking server-side entitlements.
    if (ref.download) await api.restoreAccountSession();
    final data = await _raw(ref);
    // Offline eligibility is explicitly advertised by the source catalog.
    // A missing flag is not permission to download a playback-only stream.
    if (ref.download && data['offline_mode_enabled'] != true) return [];
    final configs = <String, Map<dynamic, dynamic>>{};
    if (data['configs'] case final List list) {
      for (final row in list.whereType<Map<dynamic, dynamic>>()) {
        if (row['server_key'] is String)
          configs[row['server_key'] as String] = row;
      }
    }
    final choices = <({StreamResult stream, int priority, int resolution})>[];
    final rows = data['items'];
    if (rows is! List) throw const AnimeRiftPlaybackUnavailable();
    final seen = <String>{};
    for (final row in rows.whereType<Map<dynamic, dynamic>>()) {
      final host = row['_id'];
      if (host is! String || !_SourceIdentity.isValidId(host)) continue;
      final config = configs[row['provider']] ?? const <String, dynamic>{};
      if (config['is_premium'] == true ||
          row['is_premium'] == true ||
          (ref.download && config['in_app_download_disabled'] == true))
        continue;
      final rawQualities = row['qualities'];
      final qualities = rawQualities is List && rawQualities.isNotEmpty
          ? rawQualities
                .whereType<String>()
                .where((q) => q.length <= 32 && _SourceIdentity.isValidId(q))
                .toList()
          : <String?>[null];
      for (final quality in qualities) {
        if (ref.host != null && (host != ref.host || quality != ref.quality))
          continue;
        final selected = _SourceIdentity(
          ref.anime,
          ref.episode,
          number: ref.number,
          host: host,
          quality: quality,
          download: ref.download,
        );
        if (!seen.add(selected.sourceUrl)) continue;
        final name = row['server_name'] is String
            ? row['server_name'] as String
            : 'Anime Rift';
        final language = row['sub_title'];
        final label = switch (language) {
          'ar_sub' => 'عربي مترجم',
          'ar_dub' => 'عربي مدبلج',
          'en_sub' => 'إنجليزي مترجم',
          'en_dub' => 'إنجليزي مدبلج',
          _ => language is String ? language : '',
        };
        choices.add((
          stream: StreamResult(
            url: selected.sourceUrl,
            source: label.isEmpty ? name : '$name ($label)',
            quality: quality,
            requiresResolution: true,
          ),
          priority: (config['priority'] as num?)?.toInt() ?? 99,
          resolution:
              int.tryParse(quality?.replaceAll(RegExp(r'[^0-9]'), '') ?? '') ??
              0,
        ));
      }
    }
    choices.sort((a, b) {
      final priority = a.priority.compareTo(b.priority);
      return priority != 0 ? priority : b.resolution.compareTo(a.resolution);
    });
    return choices.map((c) => c.stream).toList(growable: false);
  }

  void _checkAccess(Map<String, dynamic> response) {
    if (response['require_auth'] == true || response['requires_auth'] == true)
      throw const AnimeRiftAuthenticationRequired();
    if (response['can_play'] == false ||
        response['content_restricted'] == true ||
        response['requires_ad'] == true ||
        response['require_subscription'] == true ||
        response['is_premium'] == true) {
      throw const AnimeRiftPlaybackUnavailable();
    }
  }

  static bool _mediaUrl(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.host.isEmpty ||
        uri.hasFragment)
      return false;
    final host = uri.host.toLowerCase();
    return host != 'localhost' &&
        !host.endsWith('.localhost') &&
        !host.endsWith('.local') &&
        !RegExp(r'^[0-9.]+$').hasMatch(host) &&
        !host.contains(':');
  }

  Map<String, String> _headers(dynamic raw) {
    final headers = <String, String>{'User-Agent': 'libmpv', 'Accept': '*/*'};
    const blocked = {
      'host',
      'content-length',
      'connection',
      'transfer-encoding',
      'range',
      'integrity',
      'x-firebase-id',
      'x-firebase-app-check',
      'x-goog-api-key',
    };
    if (raw is Map<dynamic, dynamic>) {
      for (final e in raw.entries) {
        if (e.key is! String || e.value is! String) continue;
        final k = e.key as String, v = e.value as String;
        if (blocked.contains(k.toLowerCase()) ||
            !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(k) ||
            v.contains(RegExp(r'[\r\n]')))
          continue;
        headers[k] = v;
      }
    }
    return headers;
  }

  Future<String> _ticket(Map<String, dynamic> data) async {
    final file = data['fileId'], ticket = data['ticket'];
    if (file is! String || ticket is! String || file.isEmpty || ticket.isEmpty)
      throw const AnimeRiftPlaybackUnavailable();
    final wait = (data['wait_time'] as num?)?.toInt() ?? 5;
    if (wait < 0 || wait > 30) throw const AnimeRiftPlaybackUnavailable();
    await Future<void>.delayed(Duration(seconds: wait, milliseconds: 500));
    final uri = Uri.https('api.streamtape.com', '/file/dl', {
      'file': file,
      'ticket': ticket,
    });
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final response = await _external.get<dynamic>(
          uri.toString(),
          options: Options(
            followRedirects: false,
            headers: {'User-Agent': 'libmpv', 'Accept': 'application/json'},
            receiveTimeout: const Duration(seconds: 20),
            validateStatus: (_) => true,
          ),
        );
        final dynamic body = response.data is String
            ? jsonDecode(response.data as String)
            : response.data;
        if (response.statusCode == 200 &&
            body is Map<dynamic, dynamic> &&
            body['status'] == 200 &&
            body['result'] is Map<dynamic, dynamic>) {
          final url = (body['result'] as Map<dynamic, dynamic>)['url'];
          if (url is String && _mediaUrl(url)) return url;
        }
      } catch (_) {
        throw const AnimeRiftPlaybackUnavailable();
      }
      if (attempt == 0) await Future<void>.delayed(const Duration(seconds: 2));
    }
    throw const AnimeRiftPlaybackUnavailable();
  }

  Future<StreamResult> _resolve(
    StreamResult source, {
    required bool download,
  }) async {
    final ref = await _identity(source.url, download: download);
    final availability = await api.request(
      'library/episode/source/can_play',
      'ANIME.LIBRARY.EPISODES.SOURCES.CHECK_AVAILABILITY',
      method: 'POST',
      body: {
        'episodeId': ref.episode,
        'hostId': ref.host,
        'is_download': ref.download,
        'event_name': ref.download
            ? 'download_episode_unlocked'
            : 'play_episode_unlocked',
      },
    );
    _checkAccess(availability);
    final session = availability['sessionId'];
    if (session is! String || session.isEmpty)
      throw const AnimeRiftPlaybackUnavailable();
    final data = await api.request(
      'library/episode/source/direct_link',
      'ANIME.LIBRARY.EPISODES.SOURCES.DIRECT_LINK',
      method: 'POST',
      body: {
        'id': ref.host,
        if (ref.quality != null) 'quality': ref.quality,
        'with_internal_player': '1',
        'sessionId': session,
      },
    );
    _checkAccess(data);
    if (data['drm_protected'] == true ||
        data['licenseUrl'] != null ||
        data['drmKey'] != null)
      throw const AnimeRiftPlaybackUnavailable();
    final dynamic candidate = data['url_response'] == true
        ? data['videoUrl']
        : data['ticket_response'] == true
        ? await _ticket(data)
        : null;
    if (candidate is! String || !_mediaUrl(candidate))
      throw const AnimeRiftPlaybackUnavailable();
    final tracks = data['tracks'];
    final subtitles = <SubtitleFile>[];
    if (tracks is List)
      for (final track in tracks.whereType<Map<dynamic, dynamic>>()) {
        final url = track['file'] ?? track['url'];
        if (url is! String || !_mediaUrl(url)) continue;
        final kind = track['kind'];
        if (kind != null && kind != 'captions' && kind != 'subtitles') continue;
        final language = track['language'];
        final label = track['label'] ?? language;
        subtitles.add(
          SubtitleFile(
            url: url,
            label: label is String && label.isNotEmpty ? label : 'ترجمة',
            lang: language is String ? language : null,
          ),
        );
      }
    return StreamResult(
      url: candidate,
      source: source.source,
      quality: source.quality,
      headers: _headers(data['http_headers']),
      subtitles: subtitles,
      refreshUrl: ref.sourceUrl,
    );
  }

  /// Give each server a chance before retrying lower qualities on one server.
  /// A single unavailable server may advertise more than six qualities.
  Iterable<StreamResult> _fallbackSources(List<StreamResult> choices) sync* {
    final byHost = <String, List<StreamResult>>{};
    for (final source in choices) {
      final host = _SourceIdentity.parse(source.url)?.host;
      if (host == null) continue;
      byHost.putIfAbsent(host, () => <StreamResult>[]).add(source);
    }
    for (var qualityIndex = 0; ; qualityIndex++) {
      var found = false;
      for (final sources in byHost.values) {
        if (qualityIndex >= sources.length) continue;
        found = true;
        yield sources[qualityIndex];
      }
      if (!found) return;
    }
  }

  Future<List<StreamResult>> resolve(
    String url, {
    bool download = false,
  }) async {
    final ref = await _identity(url, download: download);
    final choices = await loadSources(url, download: ref.download);
    if (choices.isEmpty) throw const AnimeRiftPlaybackUnavailable();
    var authenticationRequired = false;
    final candidates = ref.host == null
        ? _fallbackSources(choices).take(6)
        : choices.take(1);
    for (final source in candidates) {
      try {
        return [await _resolve(source, download: ref.download)];
      } on AnimeRiftAuthenticationRequired {
        if (ref.host != null) rethrow;
        // For automatic playback, another server may be accessible to guests.
        // Never use a playback entitlement as a substitute for download access.
        authenticationRequired = true;
      } on AnimeRiftAccessUnavailable {
        if (ref.host != null) rethrow;
      }
    }
    if (authenticationRequired) throw const AnimeRiftAuthenticationRequired();
    throw const AnimeRiftPlaybackUnavailable();
  }
}
