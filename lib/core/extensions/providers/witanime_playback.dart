import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:html/parser.dart' as html;
import 'package:html_unescape/html_unescape.dart';

import '../../domain/entity/multimedia_item.dart';
import 'mediafire_utils.dart';
import 'server_extraction_utils.dart';
import 'witanime_crypto.dart';
import 'witanime_transport.dart';

const String witanimeSourceUrlPrefix = 'witanime-source://';

class WitanimeBrowserRequiredException implements Exception {
  const WitanimeBrowserRequiredException(this.message, {this.watchUrl});

  final String message;
  final Uri? watchUrl;

  @override
  String toString() => message;
}

class WitanimeRateLimitException implements Exception {
  const WitanimeRateLimitException();

  @override
  String toString() =>
      'تجاوزت حد الطلبات على Witanime، انتظر قليلًا وأعد المحاولة.';
}

class _ExpiredSourceException implements Exception {
  const _ExpiredSourceException();
}

class WitanimeSourceToken {
  const WitanimeSourceToken({
    required this.kind,
    required this.watchUrl,
    required this.token,
    required this.label,
    required this.tier,
    this.version,
  });

  final String kind; // 'stream' | 'download'
  final String watchUrl;
  final String token;
  final String label;
  final String tier;
  final String? version;

  bool get isDownload => kind == 'download';

  String encode() {
    final payload = jsonEncode(<String, Object?>{
      'k': kind,
      'w': watchUrl,
      't': token,
      'l': label,
      'q': tier,
      if (version != null && version!.isNotEmpty) 'v': version,
    });
    return '$witanimeSourceUrlPrefix$kind/${base64Url.encode(utf8.encode(payload))}';
  }

  static WitanimeSourceToken? tryDecode(String raw) {
    final trimmed = raw.trim();
    if (!trimmed.startsWith(witanimeSourceUrlPrefix)) return null;
    final rest = trimmed.substring(witanimeSourceUrlPrefix.length);
    final slash = rest.indexOf('/');
    if (slash <= 0 || slash >= rest.length - 1) return null;
    final encoded = rest.substring(slash + 1);
    try {
      final jsonMap = jsonDecode(utf8.decode(base64Url.decode(encoded)));
      if (jsonMap is! Map) return null;
      final kind = jsonMap['k']?.toString().trim() ?? '';
      final watchUrl = jsonMap['w']?.toString().trim() ?? '';
      final token = jsonMap['t']?.toString().trim() ?? '';
      final label = jsonMap['l']?.toString().trim() ?? 'Server';
      final tier = jsonMap['q']?.toString().trim() ?? 'HD';
      final version = jsonMap['v']?.toString().trim();
      if (!const {'stream', 'download'}.contains(kind) ||
          watchUrl.isEmpty ||
          token.isEmpty) {
        return null;
      }
      return WitanimeSourceToken(
        kind: kind,
        watchUrl: watchUrl,
        token: token,
        label: label,
        tier: tier,
        version: version?.isEmpty == true ? null : version,
      );
    } catch (_) {
      return null;
    }
  }
}

class WitanimePlaybackResolver {
  WitanimePlaybackResolver(this._transport, {Uri? origin})
    : _origin = origin ?? Uri.https('witanime.site');

  final WitanimeTransport _transport;
  final Uri _origin;
  final HtmlUnescape _unescape = HtmlUnescape();
  final Random _random = Random();
  DateTime? _retryAt;

  static final _mediaPath = RegExp(
    r'\.(?:m3u8|mp4|mkv|webm|m4v|mov|avi|ts|mpd)$',
    caseSensitive: false,
  );
  static const _navigationAccept =
      'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8';

  static const _tierOrder = <String>['4K', 'FHD', 'HD', 'SD'];
  static const _hgcloudMirrors = <String>[
    'hanerix.com',
    'vibuxer.com',
    'audinifer.com',
  ];

  static String qualityLabelForTier(String tier) {
    switch (tier.trim().toUpperCase()) {
      case '4K':
      case '2160P':
        return '2160p';
      case 'FHD':
      case '1080P':
        return '1080p';
      case 'HD':
      case '720P':
        return '720p';
      case 'SD':
      case '480P':
        return '480p';
      case '360P':
        return '360p';
      default:
        return tier.trim().isEmpty ? '720p' : tier.trim();
    }
  }

  static String displaySourceName(String label, {String? version}) {
    final clean = label.trim().isEmpty ? 'Server' : label.trim();
    final ver = version?.trim().toLowerCase() ?? '';
    if (ver == 'dub' || ver == 'مدبلج') return '$clean (عربي مدبلج)';
    if (ver == 'sub' || ver == 'مترجم') return '$clean (عربي مترجم)';
    return clean;
  }

  Map<String, String> _corsPostHeaders(String csrf, Uri watchUri) => {
    'Accept': 'application/json',
    'X-CSRF-TOKEN': csrf,
    'Referer': watchUri.toString(),
    'Origin': _origin.origin,
    'Sec-Fetch-Site': 'same-origin',
    'Sec-Fetch-Mode': 'cors',
    'Sec-Fetch-Dest': 'empty',
  };

  void _checkCooldown([WitanimeHttpResponse? response]) {
    if (response?.statusCode == 429) {
      final now = DateTime.now();
      final header = response?.header('retry-after');
      DateTime? retryAt;
      if (header != null) {
        final seconds = int.tryParse(header);
        if (seconds != null && seconds >= 0) {
          retryAt = now.add(Duration(seconds: seconds));
        } else {
          try {
            retryAt = HttpDate.parse(header);
          } on FormatException {
            // A missing or malformed header uses a short cooldown.
          }
        }
      }
      retryAt ??= now.add(const Duration(seconds: 15));
      if (_retryAt?.isAfter(retryAt) != true) _retryAt = retryAt;
      throw const WitanimeRateLimitException();
    }
    if (response == null && _retryAt?.isAfter(DateTime.now()) == true) {
      throw const WitanimeRateLimitException();
    }
  }

  String? _extractRawSourcesUrl(String body) {
    final jsOrUnquoted = RegExp(r'''sourcesUrl\s*:\s*["']([^"']+)["']''')
        .firstMatch(body)
        ?.group(1);
    if (jsOrUnquoted != null && jsOrUnquoted.trim().isNotEmpty) {
      return jsOrUnquoted.replaceAll(r'\/', '/').trim();
    }
    final jsonQuoted = RegExp(r'''["']sourcesUrl["']\s*:\s*["']([^"']+)["']''')
        .firstMatch(body)
        ?.group(1);
    if (jsonQuoted != null && jsonQuoted.trim().isNotEmpty) {
      return jsonQuoted.replaceAll(r'\/', '/').trim();
    }
    final configMatch = RegExp(
      r'''data-watch-config=["']([^"']+)["']''',
      caseSensitive: false,
    ).firstMatch(body)?.group(1);
    if (configMatch != null && configMatch.trim().isNotEmpty) {
      final decoded = _tryJsonMap(_unescape.convert(configMatch));
      final raw = decoded?['sourcesUrl']?.toString().trim();
      if (raw != null && raw.isNotEmpty) return raw;
    }
    return null;
  }

  Future<({String csrf, Uri sourcesUri, Uri watchUri})> _fetchWatchMeta(
    Uri watchUri,
  ) async {
    _checkCooldown();
    if (!watchUri.hasScheme ||
        _resolveSameOrigin(watchUri.toString(), _origin) == null) {
      throw const FormatException('Invalid Witanime watch URL');
    }
    final page = await _transport.get(
      watchUri,
      headers: {
        'Accept': _navigationAccept,
        'Referer': '${_origin.origin}/',
        'Sec-Fetch-Site': 'same-origin',
        'Sec-Fetch-Mode': 'navigate',
        'Sec-Fetch-Dest': 'document',
        'Upgrade-Insecure-Requests': '1',
      },
      operation: 'watch_page',
    );
    _checkCooldown(page);
    if (page.statusCode == 403 ||
        page.body.contains('cf-challenge') ||
        page.body.contains('challenges.cloudflare.com')) {
      throw WitanimeBrowserRequiredException(
        'يتطلب هذا العرض التحقق من المتصفح على Witanime.',
        watchUrl: watchUri,
      );
    }
    if (!page.isSuccess) {
      throw FormatException('Witanime watch HTTP ${page.statusCode}');
    }
    final csrf =
        RegExp(
          r'''<meta[^>]*name=["']csrf-token["'][^>]*content=["']([^"']+)["']''',
          caseSensitive: false,
        ).firstMatch(page.body)?.group(1) ??
        RegExp(
          r'''<meta[^>]*content=["']([^"']+)["'][^>]*name=["']csrf-token["']''',
          caseSensitive: false,
        ).firstMatch(page.body)?.group(1) ??
        RegExp(
          r'''data-csrf=["']([^"']+)["']''',
          caseSensitive: false,
        ).firstMatch(page.body)?.group(1);
    if (csrf == null || csrf.trim().isEmpty) {
      throw WitanimeBrowserRequiredException(
        'تعذر العثور على رمز جلسة المشاهدة على Witanime.',
        watchUrl: watchUri,
      );
    }
    final effectiveWatch = page.finalUri ?? watchUri;
    if (_resolveSameOrigin(effectiveWatch.toString(), watchUri) == null) {
      throw const FormatException('Invalid Witanime watch redirect');
    }
    final rawSources = _extractRawSourcesUrl(page.body);
    final sourcesUri = rawSources != null && rawSources.isNotEmpty
        ? _resolveSameOrigin(rawSources, effectiveWatch) ??
              _defaultSourcesUri(effectiveWatch)
        : _defaultSourcesUri(effectiveWatch);

    return (
      csrf: csrf.trim(),
      sourcesUri: sourcesUri,
      watchUri: effectiveWatch,
    );
  }

  Uri _defaultSourcesUri(Uri watchUri) {
    final normalizedPath = watchUri.path.endsWith('/')
        ? '${watchUri.path}sources'
        : '${watchUri.path}/sources';
    return watchUri.resolve(normalizedPath);
  }

  Uri? _resolveSameOrigin(String raw, Uri base) {
    final parsed = Uri.tryParse(raw.trim());
    if (parsed == null) return null;
    final resolved = base.resolveUri(parsed);
    return resolved.scheme == _origin.scheme &&
            resolved.host == _origin.host &&
            resolved.port == _origin.port &&
            resolved.userInfo.isEmpty
        ? resolved.removeFragment()
        : null;
  }

  Future<List<StreamResult>> loadSources(
    String watchUrl, {
    required bool forDownload,
  }) async {
    final parsedWatch = Uri.tryParse(watchUrl.trim());
    if (parsedWatch == null || !looksLikeStreamUrl(parsedWatch.toString())) {
      throw const FormatException('Invalid Witanime watch URL');
    }
    var meta = await _fetchWatchMeta(parsedWatch);
    Future<WitanimeHttpResponse> postSources(
      ({String csrf, Uri sourcesUri, Uri watchUri}) m,
    ) => _transport.post(
      m.sourcesUri,
      headers: _corsPostHeaders(m.csrf, m.watchUri),
      operation: forDownload ? 'download_sources' : 'stream_sources',
    );
    var resp = await postSources(meta);
    if (resp.statusCode == 419) {
      meta = await _fetchWatchMeta(parsedWatch);
      resp = await postSources(meta);
    }
    _checkCooldown(resp);
    if (!resp.isSuccess) {
      throw FormatException('Witanime sources HTTP ${resp.statusCode}');
    }
    final dynamic root = jsonDecode(resp.body);
    if (root is! Map) return const <StreamResult>[];

    final out = <StreamResult>[];
    final seen = <String>{};

    void collectGroup(Object? groupObj, String kind, {String? version}) {
      if (groupObj is! Map) return;
      final groups = {
        for (final entry in groupObj.entries)
          entry.key.toString().trim().toUpperCase(): entry.value,
      };
      final orderedTiers = <String>[
        ..._tierOrder,
        for (final key in groups.keys)
          if (!_tierOrder.contains(key)) key,
      ];
      for (final tier in orderedTiers) {
        final entries = groups[tier];
        if (entries is! List) continue;
        for (final rawEntry in entries) {
          if (rawEntry is! Map) continue;
          final token = rawEntry['token']?.toString().trim() ?? '';
          if (token.isEmpty) continue;
          final label = rawEntry['label']?.toString().trim().isNotEmpty == true
              ? rawEntry['label'].toString().trim()
              : rawEntry['name']?.toString().trim().isNotEmpty == true
              ? rawEntry['name'].toString().trim()
              : 'Server';
          final rawEntryVersion = rawEntry['version']?.toString().trim();
          final effectiveVersion =
              version ??
              (rawEntryVersion != null && rawEntryVersion.toLowerCase() == 'dub'
                  ? 'dub'
                  : null);
          final sourceName = displaySourceName(
            label,
            version: effectiveVersion,
          );
          final quality = qualityLabelForTier(tier);
          if (!seen.add('$kind|$token|$effectiveVersion|$tier')) continue;
          final encoded = WitanimeSourceToken(
            kind: kind,
            watchUrl: meta.watchUri.toString(),
            token: token,
            label: label,
            tier: tier,
            version: effectiveVersion,
          ).encode();
          out.add(
            StreamResult(
              url: encoded,
              source: sourceName,
              quality: quality,
              requiresResolution: true,
              refreshUrl: encoded,
            ),
          );
        }
      }
    }

    void collectBucket(String key, String kind) {
      collectGroup(root[key], kind);
      final versions = root['versions'];
      if (versions is Map) {
        for (final entry in versions.entries) {
          final subGroup = entry.value;
          if (subGroup is Map) {
            collectGroup(subGroup[key], kind, version: entry.key.toString());
          }
        }
      }
    }

    if (forDownload) {
      collectBucket('downloads', 'download');
      if (out.isEmpty) collectBucket('players', 'stream');
    } else {
      collectBucket('players', 'stream');
      if (out.isEmpty) collectBucket('downloads', 'download');
    }

    return List<StreamResult>.unmodifiable(out);
  }

  Future<List<StreamResult>> resolveStreams(
    String tokenOrWatchUrl, {
    required bool forDownload,
  }) async {
    final decoded = WitanimeSourceToken.tryDecode(tokenOrWatchUrl);
    if (decoded == null) {
      final sources = await loadSources(
        tokenOrWatchUrl,
        forDownload: forDownload,
      );
      final resolved = <StreamResult>[];
      for (final candidate in sources) {
        try {
          final items = await _resolveSelectedToken(
            WitanimeSourceToken.tryDecode(candidate.url)!,
            forDownload: forDownload,
          );
          resolved.addAll(items);
          if (resolved.isNotEmpty) break;
        } on WitanimeRateLimitException {
          rethrow;
        } catch (_) {
          // Try next server candidate.
        }
      }
      return List<StreamResult>.unmodifiable(resolved);
    }
    return _resolveSelectedToken(decoded, forDownload: forDownload);
  }

  Future<List<StreamResult>> _resolveSelectedToken(
    WitanimeSourceToken entry, {
    required bool forDownload,
  }) async {
    var current = entry;
    List<StreamResult> streams;
    try {
      streams = await _resolveToken(entry);
    } on _ExpiredSourceException {
      final fresh = await loadSources(entry.watchUrl, forDownload: forDownload);
      for (final candidate in fresh) {
        final token = WitanimeSourceToken.tryDecode(candidate.url)!;
        if (token.label == entry.label &&
            token.tier.toUpperCase() == entry.tier.toUpperCase() &&
            token.version == entry.version &&
            (token.token != entry.token || token.kind != entry.kind)) {
          current = token;
          break;
        }
      }
      if (identical(current, entry)) return const [];
      try {
        streams = await _resolveToken(current);
      } on _ExpiredSourceException {
        return const [];
      }
    }
    return [
      for (final stream in streams)
        if (!forDownload || !_isPlaylist(stream.url))
          stream.copyWith(refreshUrl: current.encode()),
    ];
  }

  bool _isPlaylist(String url) {
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    return path.endsWith('.m3u8') ||
        path.endsWith('.mpd') ||
        path.endsWith('/master.txt');
  }

  Future<List<StreamResult>> _resolveToken(WitanimeSourceToken entry) async {
    final watchUri = Uri.parse(entry.watchUrl);
    var meta = await _fetchWatchMeta(watchUri);
    final kind = entry.isDownload ? 'download' : 'stream';
    final sourceUri = _origin.replace(
      pathSegments: ['watch', '$kind-source', entry.token],
    );
    final defaultGate = _origin.replace(
      pathSegments: ['watch', '$kind-gate', entry.token],
    );

    Future<WitanimeHttpResponse> postActivate(
      ({String csrf, Uri sourcesUri, Uri watchUri}) m,
    ) => _transport.post(
      sourceUri,
      headers: _corsPostHeaders(m.csrf, m.watchUri),
      operation: '${kind}_source_unlock',
    );
    var activateResp = await postActivate(meta);
    if (activateResp.statusCode == 419) {
      meta = await _fetchWatchMeta(watchUri);
      activateResp = await postActivate(meta);
    }
    _checkCooldown(activateResp);
    if (activateResp.statusCode == 404 || activateResp.statusCode == 410) {
      throw const _ExpiredSourceException();
    }
    if (!activateResp.isSuccess) {
      throw FormatException(
        'Witanime source unlock HTTP ${activateResp.statusCode}',
      );
    }

    final activation = _tryJsonMap(activateResp.body);
    final rawGate = activation?['gateUrl']?.toString().trim() ?? '';
    final gate = rawGate.isEmpty
        ? defaultGate
        : _resolveSameOrigin(rawGate, meta.watchUri) ?? defaultGate;
    final policy = activation?['referrerPolicy']
        ?.toString()
        .trim()
        .toLowerCase();
    final referer = switch (policy) {
      'origin' || 'strict-origin' => '${_origin.origin}/',
      'no-referrer' => null,
      'same-origin' ||
      'origin-when-cross-origin' ||
      'strict-origin-when-cross-origin' ||
      'unsafe-url' ||
      'no-referrer-when-downgrade' => meta.watchUri.toString(),
      _ => entry.isDownload ? meta.watchUri.toString() : null,
    };
    final gateResp = await _transport.get(
      gate,
      headers: {
        'Accept': _navigationAccept,
        'Referer': ?referer,
        'Sec-Fetch-Site': 'same-origin',
        'Sec-Fetch-Mode': 'navigate',
        'Sec-Fetch-Dest': entry.isDownload ? 'document' : 'iframe',
        'Upgrade-Insecure-Requests': '1',
      },
      followRedirects: false,
      operation: '${kind}_gate',
    );
    _checkCooldown(gateResp);
    if (gateResp.statusCode == 404 || gateResp.statusCode == 410) {
      throw const _ExpiredSourceException();
    }
    if (gateResp.statusCode >= 400) {
      throw FormatException('Witanime gate HTTP ${gateResp.statusCode}');
    }

    final rawLoc =
        gateResp.header('location') ??
        _navigationTarget(gateResp.body, includeGateLinks: true);
    if (rawLoc == null || rawLoc.trim().isEmpty) {
      throw const FormatException('Witanime gate returned no host URL');
    }
    return resolveHostedLink(
      meta.watchUri.toString(),
      _absUrl(_unescape.convert(rawLoc.trim()), gate),
      entry,
    );
  }

  Future<List<StreamResult>> resolveHostedLink(
    String episodeUrl,
    String link,
    WitanimeSourceToken entry, {
    int depth = 0,
  }) async {
    final cleanLink = prepareExtractedMediaUrl(link);
    if (depth > 4 || !looksLikeStreamUrl(cleanLink)) return const [];
    final uri = Uri.parse(cleanLink);
    final host = uri.host.toLowerCase();
    final low = cleanLink.toLowerCase();
    final displaySource = displaySourceName(
      entry.label,
      version: entry.version,
    );
    final quality = qualityLabelForTier(entry.tier);

    if (host == 'mega.nz' || host == 'mega.co.nz' || host == 'www.mega.nz') {
      throw const WitanimeBrowserRequiredException(
        'روابط MEGA مشفّرة ولا يدعمها التطبيق. اختر سيرفرًا آخر.',
      );
    }

    if (host == 'mediafire.com' || host == 'www.mediafire.com') {
      return _resolveGeneric(
        episodeUrl,
        mediaFirePageRequestUrl(cleanLink),
        entry,
        depth: depth,
      );
    }
    if (host == 'dropbox.com' || host == 'www.dropbox.com') {
      final download = uri.replace(
        queryParameters: {...uri.queryParameters, 'dl': '1'}..remove('raw'),
      );
      return _resolveGeneric(
        episodeUrl,
        download.toString(),
        entry,
        depth: depth,
      );
    }
    if (host == 'pixeldrain.com' || host == 'pixeldrain.net') {
      final file = RegExp(r'^/u/([\w-]+)/?$').firstMatch(uri.path)?.group(1);
      if (file != null) {
        return [
          _hostedStream(
            entry,
            uri.replace(path: '/api/file/$file').toString(),
            uri.origin,
          ),
        ];
      }
    }
    if (_mediaPath.hasMatch(uri.path)) {
      return [
        StreamResult(
          url: cleanLink,
          source: displaySource,
          quality: quality,
          headers: {'Referer': episodeUrl},
        ),
      ];
    }

    if (host.contains('yonaplay') || host.contains('soraplay')) {
      return _resolveYonaOrSora(episodeUrl, cleanLink, entry, depth: depth);
    }
    if (host == 'dotplay.net' || host.endsWith('.dotplay.net')) {
      return _resolveDotplay(episodeUrl, uri, entry, depth: depth);
    }
    if (low.contains('videa.hu')) {
      return _resolveVidea(cleanLink, entry);
    }
    if (low.contains('videas.fr')) {
      return _resolveVideas(episodeUrl, cleanLink, entry);
    }
    if (low.contains('ok.ru')) {
      return _resolveOkRu(cleanLink, entry);
    }
    if (low.contains('dailymotion')) {
      return _resolveDailymotion(cleanLink, entry);
    }
    if (low.contains('drive.google')) {
      final direct = _driveDirectUrl(cleanLink);
      if (direct == null) return const <StreamResult>[];
      return [
        StreamResult(
          url: direct,
          source: displaySource,
          quality: quality,
          headers: const {'Referer': 'https://drive.google.com/'},
        ),
      ];
    }
    if (low.contains('mail.ru')) {
      return _resolveMailRu(cleanLink, entry);
    }
    if (low.contains('hgcloud')) {
      return _resolveHgcloud(episodeUrl, cleanLink, entry);
    }
    if (low.contains('dood') ||
        low.contains('playmogo') ||
        low.contains('dsvplay')) {
      return _resolveDood(episodeUrl, cleanLink, entry);
    }
    if (RegExp(r'//v[aie]d[bp][aoe]?m').hasMatch(low)) {
      return _resolveVidbom(episodeUrl, cleanLink, entry);
    }
    if (low.contains('mp4upload')) {
      return _resolveMp4Upload(episodeUrl, cleanLink, entry);
    }

    return _resolveGeneric(episodeUrl, cleanLink, entry, depth: depth);
  }

  Future<List<StreamResult>> _resolveDotplay(
    String referer,
    Uri uri,
    WitanimeSourceToken entry, {
    required int depth,
  }) async {
    final code = RegExp(r'^/embed/([^/]+)').firstMatch(uri.path)?.group(1);
    if (code != null) {
      final response = await _transport.get(
        uri.replace(path: '/api.php', queryParameters: {'code': code}),
        headers: {'Accept': 'application/json', 'Referer': uri.toString()},
        operation: 'host_dotplay',
      );
      final encoded = _tryJsonMap(response.body)?['video_url'];
      if (response.isSuccess && encoded is String) {
        try {
          final decoded = utf8.decode(base64Decode(encoded)).split('|').first;
          final url = prepareExtractedMediaUrl(decoded);
          if (looksLikeStreamUrl(url)) {
            return [_hostedStream(entry, url, uri.toString())];
          }
        } on FormatException {
          // Some older embed pages contain a plain player configuration.
        }
      }
    }
    return _resolveGeneric(referer, uri.toString(), entry, depth: depth);
  }

  Future<List<StreamResult>> _resolveYonaOrSora(
    String episodeUrl,
    String link,
    WitanimeSourceToken entry, {
    required int depth,
  }) async {
    final uri = Uri.parse(link);
    final isYona = uri.host.contains('yonaplay');
    final page = await _transport.get(
      uri,
      headers: {'Referer': isYona ? episodeUrl : 'https://yonaplay.org/'},
      operation: 'host_yonaplay',
    );
    if (!page.isSuccess) return const <StreamResult>[];
    final pageUri = page.finalUri ?? uri;
    final pageUrl = pageUri.toString();

    // Multi-player mirrors (yonaplay / /mirror pages)
    final multiMatches = RegExp(r'''go_to_player\(\s*["']([^"']+)["']\s*\)''')
        .allMatches(page.body);
    if (multiMatches.isNotEmpty) {
      final out = <StreamResult>[];
      for (final match in multiMatches) {
        final target = _absUrl(normalizePageEscapes(match.group(1)!), pageUri);
        try {
          out.addAll(
            await resolveHostedLink(pageUrl, target, entry, depth: depth + 1),
          );
        } catch (_) {}
      }
      if (out.isNotEmpty) return out;
    }

    // Encrypted Yonaplay API flow (window._E={a:"/api"})
    if (isYona) {
      final apiPath =
          RegExp(r'''window\._E\s*=\s*\{\s*a\s*:\s*["']([^"']+)["']''')
              .firstMatch(page.body)
              ?.group(1) ??
          '/api';
      final apiUri = pageUri.resolve(apiPath.replaceAll(r'\/', '/'));
      final apiBase = apiUri.origin == pageUri.origin
          ? '${apiUri.origin}${apiUri.path.replaceFirst(RegExp(r'/+$'), '')}'
          : '${pageUri.origin}/api';
      final cookie = _extractCookieHeader(page);
      Map<String, String> apiHeaders() => {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'Referer': pageUrl,
        'Origin': pageUri.origin,
        'X-Requested-With': 'XMLHttpRequest',
        if (cookie.isNotEmpty) 'Cookie': cookie,
      };

      final initResp = await _transport.post(
        Uri.parse('$apiBase/init-session.php'),
        body: '{}',
        headers: apiHeaders(),
        operation: 'yonaplay_init',
      );
      if (initResp.isSuccess) {
        final initJson = _tryJsonMap(initResp.body);
        final code = initJson?['c']?.toString();
        final key = initJson?['k']?.toString();
        if (code != null && key != null) {
          final srcResp = await _transport.post(
            Uri.parse('$apiBase/sources.php'),
            body: jsonEncode({'code': code}),
            headers: apiHeaders(),
            operation: 'yonaplay_sources',
          );
          final srcJson = _tryJsonMap(srcResp.body);
          final token = _pickYonaplayServerToken(
            srcJson?['qualities'],
            entry.tier,
          );
          if (token != null) {
            final apiResp = await _transport.post(
              Uri.parse('$apiBase/api.php'),
              body: jsonEncode({'code': code, 'token': token, 'key': key}),
              headers: apiHeaders(),
              operation: 'yonaplay_api',
            );
            final dataJson = _tryJsonMap(apiResp.body);
            final encrypted = dataJson?['d']?.toString();
            if (encrypted != null && encrypted.isNotEmpty) {
              final plain = decryptYonaplayPayload(key, encrypted);
              if (plain != null && plain.trim().isNotEmpty) {
                final resolved = await resolveHostedLink(
                  pageUrl,
                  _absUrl(plain.trim(), pageUri),
                  entry,
                  depth: depth + 1,
                );
                if (resolved.isNotEmpty) return resolved;
              }
            }
          }
        }
      }
    }

    // SoraPlay plain sources array
    final sourcesMatch = RegExp(
      r'sources\s*:\s*\[(.*?)\]',
      dotAll: true,
    ).firstMatch(page.body);
    if (sourcesMatch != null) {
      final out = <StreamResult>[];
      for (final m in RegExp(
        r'''\bfile["']?\s*:\s*["']([^"']+)["'](?:[^}]*\blabel["']?\s*:\s*["']([^"']*)["'])?''',
      ).allMatches(sourcesMatch.group(1)!)) {
        final url = _absUrl(normalizePageEscapes(m.group(1)!), pageUri);
        final label = m.group(2)?.trim();
        if (looksLikeStreamUrl(url)) {
          out.add(
            StreamResult(
              url: url,
              source: displaySourceName(entry.label, version: entry.version),
              quality: (label != null && label.isNotEmpty)
                  ? label
                  : qualityLabelForTier(entry.tier),
              headers: {'Referer': pageUrl},
            ),
          );
        }
      }
      if (out.isNotEmpty) return out;
    }

    return _resolveGeneric(
      episodeUrl,
      pageUrl,
      entry,
      preloadedBody: page.body,
      depth: depth,
    );
  }

  String? _pickYonaplayServerToken(Object? qualities, String preferredTier) {
    final tiers = switch (qualities) {
      final Map<Object?, Object?> map => map.entries.map(
        (tier) => (tier.key.toString(), tier.value),
      ),
      final List<Object?> list => list.whereType<Map<Object?, Object?>>().map(
        (tier) => (tier['name']?.toString() ?? '', tier),
      ),
      _ => const <(String, Object?)>[],
    };
    const rankMap = <String, int>{'4k': 1, 'fhd': 2, 'hd': 3, 'sd': 4};
    final prefer = preferredTier.trim().toLowerCase();
    String? bestToken;
    var bestRank = 99;
    for (final (tierName, tier) in tiers) {
      if (tier is! Map) continue;
      final name = tierName.trim().toLowerCase();
      var rank = rankMap[name] ?? 5;
      if (name == prefer) rank = 0;
      final servers = tier['servers'];
      if (servers is! List || servers.isEmpty) continue;
      if (rank >= bestRank) continue;
      for (final server in servers.whereType<Map<Object?, Object?>>()) {
        final token = server['token']?.toString().trim();
        if (token == null || token.isEmpty) continue;
        bestToken = token;
        bestRank = rank;
        break;
      }
    }
    return bestToken;
  }

  Future<List<StreamResult>> _resolveVidea(
    String link,
    WitanimeSourceToken entry,
  ) async {
    final uri = Uri.parse(link);
    final vcode = uri.queryParameters['v'];
    if (vcode == null || vcode.isEmpty) return const <StreamResult>[];
    final page = await _transport.get(
      uri,
      headers: {'Referer': _origin.origin},
      operation: 'host_videa',
    );
    if (!page.isSuccess) return const <StreamResult>[];
    final xt = RegExp(
      r'''_xt\s*=\s*["']([^"']+)["']''',
    ).firstMatch(page.body)?.group(1);
    if (xt == null) return const <StreamResult>[];
    final parts = _videaToken(xt);
    if (parts == null) return const <StreamResult>[];

    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final rnd = List<String>.generate(
      8,
      (_) => chars[_random.nextInt(chars.length)],
    ).join();
    final xmlUri = Uri.https('videa.hu', '/player/xml', {
      'v': vcode,
      '_t': parts.t,
      '_s': rnd,
      'platform': 'desktop',
      'lang': 'en',
      'start': '0',
    });
    final xmlResp = await _transport.get(
      xmlUri,
      headers: {'Referer': link},
      operation: 'host_videa_xml',
    );
    if (!xmlResp.isSuccess) return const <StreamResult>[];
    final contentType = xmlResp.header('content-type') ?? '';
    final String xml;
    if (contentType.startsWith('text/xml') || xmlResp.body.trimLeft().startsWith('<')) {
      xml = xmlResp.body;
    } else {
      final xs = xmlResp.header('x-videa-xs') ?? '';
      final decrypted = rc4Crypt(
        utf8.encode('${parts.k}$rnd$xs'),
        base64Decode(xmlResp.body.trim()),
      );
      xml = latin1.decode(decrypted);
    }

    final exp = RegExp(r'''<video_sources?[^>]*exp=["'](\d+)["']''')
        .firstMatch(xml)
        ?.group(1);
    if (exp == null) return const <StreamResult>[];
    final hashes = <String, String>{};
    for (final m in RegExp(
      r'<hash_value_([^>]+)>([^<]+)</hash_value_',
    ).allMatches(xml)) {
      hashes[m.group(1)!] = m.group(2)!;
    }
    final out = <StreamResult>[];
    for (final m in RegExp(
      r'''<video_source\s+name=["']([^"']+)["'][^>]*>([^<]+)</video_source>''',
    ).allMatches(xml)) {
      final q = m.group(1)!;
      final path = m.group(2)!;
      final md5Hash = hashes[q];
      if (md5Hash == null) continue;
      final mediaUrl = path.startsWith('http')
          ? '$path?md5=$md5Hash&expires=$exp'
          : 'https:$path?md5=$md5Hash&expires=$exp';
      out.add(
        StreamResult(
          url: mediaUrl,
          source: displaySourceName(entry.label, version: entry.version),
          quality: q,
          headers: const {'Referer': 'https://videa.hu/'},
        ),
      );
    }
    return out;
  }

  ({String t, String k})? _videaToken(String xt) {
    const o = 'xHb0ZvME5q8CBcoQi6AngerDu3FGO9fkUlwPmLVY_RTzj2hJIS4NasXWKy1td7p';
    const r = ['e', 'a', 'g', 'j', 'd', 'c', 'h', 'i', 'b', 'f'];
    const rr = ['f', 'h', 'c', 'b', 'i'];
    final buckets = <String, StringBuffer>{};
    for (var i = 0; i < xt.length; i++) {
      final bucketIndex = (i ~/ 8) + 1;
      if (bucketIndex >= r.length) return null;
      buckets.putIfAbsent(r[bucketIndex], StringBuffer.new).write(xt[i]);
    }
    final d =
        '${buckets['a'] ?? ''}${buckets['g'] ?? ''}${buckets['j'] ?? ''}${buckets['d'] ?? ''}';
    final u =
        '${buckets['c'] ?? ''}${buckets['h'] ?? ''}${buckets['i'] ?? ''}${buckets['b'] ?? ''}';
    if (d.isEmpty || u.isEmpty) return null;
    final m = StringBuffer();
    for (var i = 0; i < d.length; i++) {
      final oi = o.indexOf(d[i]);
      if (oi < 0) return null;
      final at = i - (oi - 31);
      if (at < 0 || at >= u.length) return null;
      m.write(u[at]);
    }
    final mm = m.toString();
    final finalBuckets = <String, StringBuffer>{};
    for (var i = 0; i < mm.length; i++) {
      final bucketIndex = (i ~/ 8) + 1;
      if (bucketIndex < rr.length) {
        finalBuckets
            .putIfAbsent(rr[bucketIndex], StringBuffer.new)
            .write(mm[i]);
      }
    }
    return (
      t: '${finalBuckets['h'] ?? ''}${finalBuckets['c'] ?? ''}',
      k: '${finalBuckets['b'] ?? ''}${finalBuckets['i'] ?? ''}',
    );
  }

  Future<List<StreamResult>> _resolveVideas(
    String episodeUrl,
    String link,
    WitanimeSourceToken entry,
  ) async {
    final resp = await _transport.get(
      Uri.parse(link),
      headers: {'Referer': episodeUrl},
      operation: 'host_videas',
    );
    if (!resp.isSuccess) return const <StreamResult>[];
    final preload =
        RegExp(
          r'''<link[^>]+rel=["']preload["'][^>]+href=["']([^"']+)["']''',
        ).firstMatch(resp.body)?.group(1) ??
        RegExp(
          r'''"src"\s*:\s*"(https?://[^"]+\.m3u8[^"]*)"''',
        ).firstMatch(resp.body)?.group(1);
    final source = displaySourceName(entry.label, version: entry.version);
    final quality = qualityLabelForTier(entry.tier);
    if (preload != null && looksLikeStreamUrl(preload)) {
      return [
        StreamResult(
          url: preload,
          source: source,
          quality: quality,
          headers: {'Referer': link},
        ),
      ];
    }
    return _resolveGeneric(episodeUrl, link, entry, preloadedBody: resp.body);
  }

  Future<List<StreamResult>> _resolveOkRu(
    String link,
    WitanimeSourceToken entry,
  ) async {
    final resp = await _transport.get(
      Uri.parse(link),
      headers: const {'Referer': 'https://ok.ru/'},
      operation: 'host_okru',
    );
    if (!resp.isSuccess) return const <StreamResult>[];
    final rawOpts = RegExp(
      r'data-options="([^"]+)"',
    ).firstMatch(resp.body)?.group(1);
    if (rawOpts == null) return const <StreamResult>[];
    final decodedOpts = _unescape.convert(rawOpts);
    final data = _tryJsonMap(decodedOpts);
    final flashvars = data?['flashvars'];
    if (flashvars is! Map) return const <StreamResult>[];
    final rawMeta = flashvars['metadata'];
    final meta = rawMeta is String
        ? _tryJsonMap(rawMeta)
        : rawMeta is Map
        ? Map<String, dynamic>.from(rawMeta)
        : null;
    if (meta == null) return const <StreamResult>[];
    final source = displaySourceName(entry.label, version: entry.version);
    final out = <StreamResult>[];
    final hls = meta['hlsManifestUrl']?.toString().trim() ?? '';
    if (hls.isNotEmpty) {
      out.add(
        StreamResult(
          url: hls,
          source: source,
          quality: 'متعدد',
          headers: const {'Referer': 'https://ok.ru/'},
        ),
      );
    }
    final videos = meta['videos'];
    if (videos is List) {
      for (final video in videos) {
        if (video is! Map) continue;
        final url = video['url']?.toString().trim() ?? '';
        if (url.isEmpty) continue;
        final name = video['name']?.toString().trim() ?? '';
        out.add(
          StreamResult(
            url: url,
            source: source,
            quality: name.isNotEmpty ? name : qualityLabelForTier(entry.tier),
            headers: const {'Referer': 'https://ok.ru/'},
          ),
        );
      }
    }
    return out;
  }

  Future<List<StreamResult>> _resolveDailymotion(
    String link,
    WitanimeSourceToken entry,
  ) async {
    const dmOrigin = 'https://www.dailymotion.com';
    const dmHeaders = <String, String>{
      'Referer': '$dmOrigin/',
      'Origin': dmOrigin,
    };
    final embedResp = await _transport.get(
      Uri.parse(link),
      headers: dmHeaders,
      operation: 'host_dailymotion',
    );
    if (!embedResp.isSuccess) return const <StreamResult>[];
    final internal =
        RegExp(
          r'var\s+__PLAYER_CONFIG__\s*=\s*(\{.*?\});',
          dotAll: true,
        ).firstMatch(embedResp.body)?.group(1) ??
        embedResp.body;
    final ts = RegExp(
      r'''"(?:dmTs|timestamp)"\s*:\s*"?(\d+)"?''',
    ).firstMatch(internal)?.group(1);
    final v1st = RegExp(
      r'''"(?:dmV1st|v1st)"\s*:\s*"([^"]+)"''',
    ).firstMatch(internal)?.group(1);
    final uri = Uri.parse(link);
    final videoId =
        uri.queryParameters['video'] ??
        (uri.pathSegments.isNotEmpty ? uri.pathSegments.last : '');
    if (ts == null || v1st == null || videoId.isEmpty) {
      return const <StreamResult>[];
    }
    final metaUri = Uri.https(
      'www.dailymotion.com',
      '/player/metadata/video/$videoId',
      {'locale': 'en-US', 'dmV1st': v1st, 'dmTs': ts, 'is_native_app': '0'},
    );
    final metaResp = await _transport.get(
      metaUri,
      headers: dmHeaders,
      operation: 'host_dailymotion_meta',
    );
    if (!metaResp.isSuccess) return const <StreamResult>[];
    final meta = _tryJsonMap(metaResp.body);
    final qualities = meta?['qualities'];
    final auto = qualities is Map ? qualities['auto'] : null;
    final master = (auto is List && auto.isNotEmpty && auto.first is Map)
        ? auto.first['url']?.toString().trim()
        : null;
    if (master == null || master.isEmpty) return const <StreamResult>[];
    final subs = <SubtitleFile>[];
    final subMap = meta?['subtitles']?['data'];
    if (subMap is Map) {
      for (final item in subMap.values) {
        if (item is Map && item['urls'] is List && (item['urls'] as List).isNotEmpty) {
          final subUrl = (item['urls'] as List).first?.toString().trim() ?? '';
          final subLabel = item['label']?.toString().trim() ?? 'Subtitles';
          if (subUrl.isNotEmpty) {
            subs.add(SubtitleFile(url: subUrl, label: subLabel, lang: subLabel));
          }
        }
      }
    }
    return [
      StreamResult(
        url: master,
        source: displaySourceName(entry.label, version: entry.version),
        quality: qualityLabelForTier(entry.tier),
        headers: dmHeaders,
        subtitles: subs.isEmpty ? null : subs,
      ),
    ];
  }

  String? _driveDirectUrl(String link) {
    final uri = Uri.tryParse(link);
    if (uri == null) return null;
    final host = uri.host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
    if (host != 'drive.google.com' && host != 'drive.usercontent.google.com') {
      return null;
    }
    final id =
        RegExp(r'/file/d/([\w-]+)').firstMatch(uri.path)?.group(1) ??
        uri.queryParameters['id'];
    if (id == null || id.isEmpty) return null;
    final rk = uri.queryParameters['resourcekey'];
    return Uri.https('drive.usercontent.google.com', '/download', {
      'id': id,
      'export': 'download',
      'confirm': 't',
      if (rk != null && rk.isNotEmpty) 'resourcekey': rk,
    }).toString();
  }

  Future<List<StreamResult>> _resolveMailRu(
    String link,
    WitanimeSourceToken entry,
  ) async {
    final resp = await _transport.get(
      Uri.parse(link),
      headers: const {'Referer': 'https://my.mail.ru/'},
      operation: 'host_mailru',
    );
    if (!resp.isSuccess) return const <StreamResult>[];
    final rawMeta = RegExp(
      r'metadataUrl"\s*:\s*"([^"]+)"',
    ).firstMatch(resp.body)?.group(1);
    if (rawMeta == null) return const <StreamResult>[];
    final metaUrl = rawMeta.startsWith('//') ? 'https:$rawMeta' : rawMeta;
    final mr = await _transport.get(
      Uri.parse(metaUrl),
      headers: {'Referer': link, 'X-Requested-With': 'XMLHttpRequest'},
      operation: 'host_mailru_meta',
    );
    if (!mr.isSuccess) return const <StreamResult>[];
    final data = _tryJsonMap(mr.body);
    final videos = data?['videos'];
    if (videos is! List) return const <StreamResult>[];
    final source = displaySourceName(entry.label, version: entry.version);
    final out = <StreamResult>[];
    for (final video in videos) {
      if (video is! Map) continue;
      final url = video['url']?.toString().trim() ?? '';
      if (url.isEmpty) continue;
      final normalized = url.startsWith('//') ? 'https:$url' : url;
      final key = video['key']?.toString().trim();
      out.add(
        StreamResult(
          url: normalized,
          source: source,
          quality: key != null && key.isNotEmpty
              ? key
              : qualityLabelForTier(entry.tier),
          headers: {'Referer': link},
        ),
      );
    }
    return out;
  }

  Future<List<StreamResult>> _resolveHgcloud(
    String episodeUrl,
    String link,
    WitanimeSourceToken entry,
  ) async {
    List<String> extractUrls(String body) {
      final unpacked = unpackPackedJs(body);
      final text = unpacked.isNotEmpty ? '$unpacked\n$body' : body;
      final seen = <String>{};
      final urls = <String>[];
      for (final pattern in [
        RegExp(r'''https?://[^"'\s<>\\]+master\.txt[^"'\s<>\\]*'''),
        RegExp(r'''https?://[^"'\s<>\\]+master\.m3u8[^"'\s<>\\]*'''),
        RegExp(r'''https?://[^"'\s<>\\]+\.m3u8[^"'\s<>\\]*'''),
      ]) {
        for (final match in pattern.allMatches(text)) {
          final clean = match
              .group(0)!
              .replaceAll(r'\/', '/')
              .replaceAll('&amp;', '&');
          if (seen.add(clean)) urls.add(clean);
        }
      }
      return urls;
    }

    var finalRef = link;
    final first = await _transport.get(
      Uri.parse(link),
      headers: {'Referer': episodeUrl},
      operation: 'host_hgcloud',
    );
    var urls = first.isSuccess ? extractUrls(first.body) : const <String>[];
    if (urls.isEmpty && first.body.contains('/main.js')) {
      final path = Uri.parse(link).path;
      for (final mirror in _hgcloudMirrors) {
        final ref = 'https://$mirror/';
        final mirrorResp = await _transport.get(
          Uri.https(mirror, path),
          headers: {'Referer': ref},
          operation: 'host_hgcloud_mirror',
        );
        if (!mirrorResp.isSuccess) continue;
        final found = extractUrls(mirrorResp.body);
        if (found.isNotEmpty) {
          urls = found;
          finalRef = ref;
          break;
        }
      }
    }
    final source = displaySourceName(entry.label, version: entry.version);
    final quality = qualityLabelForTier(entry.tier);
    return [
      for (final url in urls)
        StreamResult(
          url: url,
          source: source,
          quality: quality,
          headers: {'Referer': finalRef},
        ),
    ];
  }

  Future<List<StreamResult>> _resolveDood(
    String episodeUrl,
    String link,
    WitanimeSourceToken entry,
  ) async {
    final uri = Uri.parse(link);
    final page = await _transport.get(
      uri,
      headers: {'Referer': episodeUrl},
      operation: 'host_dood',
    );
    if (!page.isSuccess) return const <StreamResult>[];
    final embed = page.finalUri ?? uri;
    final origin = embed.origin;
    final md5Path = RegExp(r'''(/pass_md5/[^"']+)''')
        .firstMatch(page.body)
        ?.group(1);
    if (md5Path == null) return const <StreamResult>[];
    final token = md5Path
        .split('/')
        .lastWhere((p) => p.isNotEmpty, orElse: () => '');
    final md5Resp = await _transport.get(
      Uri.parse('$origin$md5Path'),
      headers: {'Referer': embed.toString()},
      operation: 'host_dood_md5',
    );
    if (!md5Resp.isSuccess || !looksLikeStreamUrl(md5Resp.body.trim())) {
      return const <StreamResult>[];
    }
    const alpha =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    final randomTail = List<String>.generate(
      10,
      (_) => alpha[_random.nextInt(alpha.length)],
    ).join();
    final expiry = DateTime.now().millisecondsSinceEpoch;
    final direct =
        '${md5Resp.body.trim()}$randomTail?token=$token&expiry=$expiry';
    return [
      StreamResult(
        url: direct,
        source: displaySourceName(entry.label, version: entry.version),
        quality: qualityLabelForTier(entry.tier),
        headers: {'Referer': '$origin/'},
      ),
    ];
  }

  Future<List<StreamResult>> _resolveVidbom(
    String episodeUrl,
    String link,
    WitanimeSourceToken entry,
  ) async {
    final resp = await _transport.get(
      Uri.parse(link),
      headers: {'Referer': episodeUrl},
      operation: 'host_vidbom',
    );
    if (!resp.isSuccess) return const <StreamResult>[];
    final out = <StreamResult>[];
    final source = displaySourceName(entry.label, version: entry.version);
    for (final m in RegExp(
      r'''file\s*:\s*["'](https?://[^"']+)["'](?:[^}]*label\s*:\s*["']([^"']*)["'])?''',
    ).allMatches(resp.body)) {
      final url = m.group(1)!.replaceAll(r'\/', '/').trim();
      final label = m.group(2)?.trim();
      if (looksLikeStreamUrl(url)) {
        out.add(
          StreamResult(
            url: url,
            source: source,
            quality: (label != null && label.isNotEmpty)
                ? label
                : qualityLabelForTier(entry.tier),
            headers: {'Referer': link},
          ),
        );
      }
    }
    return out;
  }

  Future<List<StreamResult>> _resolveMp4Upload(
    String episodeUrl,
    String link,
    WitanimeSourceToken entry,
  ) async {
    final resp = await _transport.get(
      Uri.parse(link),
      headers: {'Referer': episodeUrl},
      operation: 'host_mp4upload',
    );
    if (!resp.isSuccess) return const <StreamResult>[];
    final text = '${unpackPackedJs(resp.body)}\n${resp.body}';
    final src = RegExp(
      r'''player\.src\([^)]*?(https?://[^"'\s)]+\.mp4[^"'\s)]*)''',
    ).firstMatch(text)?.group(1);
    if (src != null && looksLikeStreamUrl(src)) {
      return [
        StreamResult(
          url: src,
          source: displaySourceName(entry.label, version: entry.version),
          quality: qualityLabelForTier(entry.tier),
          headers: {'Referer': link},
        ),
      ];
    }
    return _resolveGeneric(episodeUrl, link, entry, preloadedBody: text);
  }

  Future<List<StreamResult>> _resolveGeneric(
    String episodeUrl,
    String link,
    WitanimeSourceToken entry, {
    String? preloadedBody,
    int? depth,
  }) async {
    final requestedUri = Uri.parse(link);
    var pageUri = requestedUri;
    var body = preloadedBody;
    if (body == null) {
      final response = await _transport.get(
        requestedUri,
        headers: {'Referer': episodeUrl, 'Accept': _navigationAccept},
        inspectMedia: true,
        operation: 'host_generic',
      );
      if (!response.isSuccess) return const [];
      pageUri = response.finalUri ?? requestedUri;
      body = response.body;
      if (response.hasMediaContent || body.trimLeft().startsWith('#EXTM3U')) {
        return [_hostedStream(entry, pageUri.toString(), episodeUrl)];
      }
    }
    final pageUrl = pageUri.toString();
    final unpacked = unpackPackedJs(body);
    final combined = normalizePageEscapes('$unpacked\n$body');
    final document = html.parse(body);
    final seen = <String>{};
    final out = <StreamResult>[];

    void addMedia(String raw, {bool declaredVideo = false}) {
      final url = _absUrl(prepareExtractedMediaUrl(raw), pageUri);
      if (!looksLikeStreamUrl(url) || url == pageUrl || url == link) return;
      final uri = Uri.parse(url);
      if (uri.host == 'www.mediafire.com' || uri.host == 'mediafire.com') {
        return;
      }
      if ((declaredVideo || _mediaPath.hasMatch(uri.path)) && seen.add(url)) {
        out.add(_hostedStream(entry, url, pageUrl));
      }
    }

    for (final media in document.querySelectorAll(
      'video[src], video source[src]',
    )) {
      addMedia(media.attributes['src']!, declaredVideo: true);
    }
    for (final match in RegExp(
      r'''\b(?:file|src)["']?\s*:\s*["']([^"']+)["']''',
    ).allMatches(unpacked.isEmpty ? body : '$unpacked\n$body')) {
      addMedia(match.group(1)!);
    }
    for (final m in RegExp(
      r'''(?:https?:)?//[^"'\s<>\\]+''',
    ).allMatches(combined)) {
      addMedia(m.group(0)!);
    }
    if (out.isNotEmpty || depth == null) return out;

    final download = document.querySelector(
      '#downloadButton, a[download], a[aria-label="Download file"], a.popsok',
    );
    final scrambled = download?.attributes['data-scrambled-url'];
    String? decodedDownload;
    if (scrambled != null) {
      try {
        decodedDownload = utf8.decode(base64Decode(scrambled));
      } on FormatException {
        // Fall back to the regular link or an embed.
      }
    }
    final target =
        decodedDownload ??
        download?.attributes['href'] ??
        _navigationTarget(body);
    if (target == null || target.trim().isEmpty) return const [];
    final targetUrl = _absUrl(prepareExtractedMediaUrl(target), pageUri);
    if (targetUrl == pageUrl || targetUrl == link) return const [];
    return resolveHostedLink(pageUrl, targetUrl, entry, depth: depth + 1);
  }

  StreamResult _hostedStream(
    WitanimeSourceToken entry,
    String url,
    String referer,
  ) => StreamResult(
    url: url,
    source: displaySourceName(entry.label, version: entry.version),
    quality: qualityLabelForTier(entry.tier),
    headers: {
      'Referer': referer,
      'User-Agent': DioWitanimeTransport.defaultUserAgent,
    },
  );

  String? _navigationTarget(String body, {bool includeGateLinks = false}) {
    final doc = html.parse(body);
    final iframe = doc.querySelector('iframe[src], iframe[data-src]');
    if (iframe != null) {
      return iframe.attributes['data-src'] ?? iframe.attributes['src'];
    }
    final refresh = doc.querySelector('meta[http-equiv="refresh"]');
    final metaTarget = RegExp(
      r'''\burl\s*=\s*(.+)$''',
      caseSensitive: false,
    ).firstMatch(refresh?.attributes['content'] ?? '')?.group(1);
    if (metaTarget != null) return prepareExtractedMediaUrl(metaTarget);
    final jsTarget = RegExp(
      r'''(?:window\.)?location(?:\.href)?\s*=\s*["']([^"']+)["']''',
    ).firstMatch(body)?.group(1);
    if (jsTarget != null) return jsTarget;
    if (includeGateLinks) {
      return doc
          .querySelector('a[download], a[href^="http"], a[href^="//"]')
          ?.attributes['href'];
    }
    return null;
  }

  String _extractCookieHeader(WitanimeHttpResponse response) {
    final cookies = <String>[];
    for (final entry in response.headers.entries) {
      if (entry.key.toLowerCase() != 'set-cookie') continue;
      for (final raw in entry.value) {
        final pair = raw.split(';').first.trim();
        if (pair.isNotEmpty && pair.contains('=')) cookies.add(pair);
      }
    }
    return cookies.join('; ');
  }

  Map<String, dynamic>? _tryJsonMap(String body) {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map<String, dynamic>
          ? decoded
          : decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : null;
    } catch (_) {
      return null;
    }
  }

  String _absUrl(String href, Uri base) {
    final parsed = Uri.tryParse(href);
    if (parsed == null) return href;
    return base.resolveUri(parsed).toString();
  }
}
