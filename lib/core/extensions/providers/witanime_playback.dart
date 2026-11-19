import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:html/parser.dart' as html;
import 'package:html_unescape/html_unescape.dart';

import '../../domain/entity/multimedia_item.dart';
import 'mediafire_utils.dart';
import 'server_extraction_utils.dart';
import 'witanime_crypto.dart';
import 'witanime_mega_proxy.dart';
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
  WitanimePlaybackResolver(
    this._transport, {
    Uri? origin,
    WitanimeMegaProxy? megaProxy,
  }) : _origin = origin ?? Uri.https('witanime.site'),
       _megaProxy = megaProxy ?? WitanimeMegaProxy.shared;

  final WitanimeTransport _transport;
  final Uri _origin;
  final WitanimeMegaProxy _megaProxy;
  final HtmlUnescape _unescape = HtmlUnescape();
  final Random _random = Random();
  DateTime? _retryAt;
  DateTime? _lastUnlockAt;
  final Map<
    String,
    ({String csrf, Uri sourcesUri, Uri watchUri, DateTime expiresAt})
  >
  _metaCache = {};

  static const _metaCacheTtl = Duration(minutes: 3);
  static const _unlockMinSpacing = Duration(milliseconds: 350);
  static final _mediaPath = RegExp(
    r'\.(?:m3u8|mp4|mkv|webm|m4v|mov|avi|ts|mpd)$',
    caseSensitive: false,
  );
  static final _archivePath = RegExp(
    r'\.(?:zip|rar|7z)(?:/file)?$',
    caseSensitive: false,
  );
  static const _navigationAccept =
      'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8';

  static const _tierOrder = <String>['4K', 'FHD', 'HD', 'SD'];
  static const _hgcloudMirrors = <String>[
    'vibuxer.com',
    'hanerix.com',
    'dintezuvio.com',
    'cavanhabg.com',
    'audinifer.com',
  ];

  static String qualityLabelForTier(String tier) {
    switch (tier.trim().toUpperCase()) {
      case '4K':
      case '2160P':
      case 'ULTRA':
        return '2160p';
      case '2K':
      case '1440P':
      case 'QUAD':
        return '1440p';
      case 'FHD':
      case '1080P':
      case 'FULL':
        return '1080p';
      case 'HD':
      case '720P':
        return '720p';
      case 'SD':
      case '480P':
        return '480p';
      case '360P':
      case 'LOW':
        return '360p';
      case '240P':
      case 'LOWEST':
        return '240p';
      case '144P':
      case 'MOBILE':
        return '144p';
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
    Uri watchUri, {
    bool forceRefresh = false,
  }) async {
    _checkCooldown();
    final canonical = _resolveSameOrigin(watchUri.toString(), _origin);
    if (!watchUri.hasScheme || canonical == null) {
      throw const FormatException('Invalid Witanime watch URL');
    }
    final cacheKey = canonical.toString();
    if (!forceRefresh) {
      final cached = _metaCache[cacheKey];
      if (cached != null && cached.expiresAt.isAfter(DateTime.now())) {
        return (
          csrf: cached.csrf,
          sourcesUri: cached.sourcesUri,
          watchUri: cached.watchUri,
        );
      }
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

    final result = (
      csrf: csrf.trim(),
      sourcesUri: sourcesUri,
      watchUri: effectiveWatch,
    );
    final entry = (
      csrf: result.csrf,
      sourcesUri: result.sourcesUri,
      watchUri: result.watchUri,
      expiresAt: DateTime.now().add(_metaCacheTtl),
    );
    _metaCache[cacheKey] = entry;
    _metaCache[effectiveWatch.removeFragment().toString()] = entry;
    return result;
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
      meta = await _fetchWatchMeta(parsedWatch, forceRefresh: true);
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
    final seenDownloadSlots = <String>{};

    bool isDownloadFriendlyPlayer(String label) {
      final lower = label.trim().toLowerCase();
      return lower.contains('mp4upload') ||
          lower == 'ok' ||
          lower.contains('okru') ||
          lower == 'videa' ||
          lower.contains('4shared') ||
          lower.contains('drive') ||
          lower.contains('dropbox') ||
          lower.contains('pixeldrain') ||
          lower.contains('mail') ||
          lower.contains('yonaplay') ||
          lower.contains('dotplay');
    }

    int downloadLabelPriority(String label) {
      final lower = label.trim().toLowerCase();
      if (lower.contains('drive')) return 0;
      if (lower.contains('mp4upload')) return 1;
      if (lower.contains('pixeldrain')) return 2;
      if (lower.contains('4shared')) return 3;
      if (lower.contains('dropbox')) return 4;
      if (lower == 'videa') return 5;
      if (lower == 'ok' || lower.contains('okru')) return 6;
      if (lower.contains('gofile')) return 7;
      if (lower.contains('mediafire')) return 8;
      if (lower.contains('workupload')) return 10;
      return 9;
    }

    void collectGroup(
      Object? groupObj,
      String kind, {
      String? version,
      bool Function(String label)? labelFilter,
      bool sortForDownload = false,
    }) {
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
        final rawMaps = entries
            .whereType<Map<Object?, Object?>>()
            .toList(growable: false);
        final orderedMaps = sortForDownload
            ? ([...rawMaps]
                ..sort((a, b) {
                  final la = a['label']?.toString() ?? a['name']?.toString() ?? '';
                  final lb = b['label']?.toString() ?? b['name']?.toString() ?? '';
                  return downloadLabelPriority(la)
                      .compareTo(downloadLabelPriority(lb));
                }))
            : rawMaps;
        for (final rawEntry in orderedMaps) {
          final token = rawEntry['token']?.toString().trim() ?? '';
          if (token.isEmpty) continue;
          final label = rawEntry['label']?.toString().trim().isNotEmpty == true
              ? rawEntry['label'].toString().trim()
              : rawEntry['name']?.toString().trim().isNotEmpty == true
              ? rawEntry['name'].toString().trim()
              : 'Server';
          if (labelFilter != null && !labelFilter(label)) continue;
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
          if (forDownload &&
              !seenDownloadSlots.add(
                '${label.toLowerCase()}|$effectiveVersion|$tier',
              )) {
            continue;
          }
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

    void collectBucket(
      String key,
      String kind, {
      bool Function(String label)? labelFilter,
      bool sortForDownload = false,
    }) {
      collectGroup(
        root[key],
        kind,
        labelFilter: labelFilter,
        sortForDownload: sortForDownload,
      );
      final versions = root['versions'];
      if (versions is Map) {
        for (final entry in versions.entries) {
          final subGroup = entry.value;
          if (subGroup is Map) {
            collectGroup(
              subGroup[key],
              kind,
              version: entry.key.toString(),
              labelFilter: labelFilter,
              sortForDownload: sortForDownload,
            );
          }
        }
      }
    }

    if (forDownload) {
      collectBucket('downloads', 'download', sortForDownload: true);
      // Many Witanime download mirrors package episodes as .zip archives; also
      // expose direct-MP4 player mirrors so users always have playable downloads.
      collectBucket(
        'players',
        'stream',
        labelFilter: isDownloadFriendlyPlayer,
        sortForDownload: true,
      );
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
          stream.copyWith(
            url: _encodeUrlIfNeeded(stream.url),
            refreshUrl: current.encode(),
          ),
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
    ) async {
      final last = _lastUnlockAt;
      if (last != null) {
        final elapsed = DateTime.now().difference(last);
        if (elapsed < _unlockMinSpacing) {
          await Future<void>.delayed(_unlockMinSpacing - elapsed);
        }
      }
      _lastUnlockAt = DateTime.now();
      return _transport.post(
        sourceUri,
        headers: _corsPostHeaders(m.csrf, m.watchUri),
        operation: '${kind}_source_unlock',
      );
    }
    var activateResp = await postActivate(meta);
    if (activateResp.statusCode == 419) {
      meta = await _fetchWatchMeta(watchUri, forceRefresh: true);
      activateResp = await postActivate(meta);
    }
    _checkCooldown(activateResp);
    if (activateResp.statusCode == 404 || activateResp.statusCode == 410) {
      _metaCache.remove(watchUri.removeFragment().toString());
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
      return _resolveMega(cleanLink, entry);
    }

    if (host == 'mediafire.com' || host == 'www.mediafire.com') {
      return _resolveMediaFire(cleanLink, entry);
    }
    if (host == 'gofile.io' || host.endsWith('.gofile.io')) {
      return _resolveGoFile(cleanLink, entry);
    }
    if (host == 'workupload.com' || host.endsWith('.workupload.com')) {
      return _resolveWorkUpload(cleanLink, entry);
    }
    if (host == '4shared.com' || host.endsWith('.4shared.com')) {
      return _resolveFourShared(cleanLink, entry);
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
    if (_archivePath.hasMatch(uri.path)) {
      throw const FormatException(
        'هذا الرابط يحتوي على ملف مضغوط (ZIP) غير قابل للتشغيل، اختر سيرفرًا آخر.',
      );
    }
    if (_mediaPath.hasMatch(uri.path)) {
      return [_hostedStream(entry, cleanLink, episodeUrl)];
    }

    if (host.contains('yonaplay') || host.contains('soraplay')) {
      return _resolveYonaOrSora(episodeUrl, cleanLink, entry, depth: depth);
    }
    if (host == 'dotplay.net' || host.endsWith('.dotplay.net')) {
      return _resolveDotplay(episodeUrl, uri, entry, depth: depth);
    }
    if (low.contains('videa.hu') || low.contains('videakid.hu')) {
      return _resolveVidea(cleanLink, entry);
    }
    if (low.contains('videas.com') || low.contains('videas.fr')) {
      return _resolveVideas(episodeUrl, cleanLink, entry);
    }
    if (low.contains('ok.ru') || low.contains('odnoklassniki.ru')) {
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
          headers: const {
            'Referer': 'https://drive.google.com/',
            'User-Agent': DioWitanimeTransport.defaultUserAgent,
          },
        ),
      ];
    }
    if (low.contains('mail.ru')) {
      return _resolveMailRu(cleanLink, entry);
    }
    if (low.contains('hgcloud.') ||
        low.contains('vibuxer.') ||
        low.contains('hanerix.') ||
        low.contains('dintezuvio.') ||
        low.contains('cavanhabg.') ||
        low.contains('audinifer.') ||
        low.contains('streamhg') ||
        low.contains('earnvids')) {
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

  Future<List<StreamResult>> _resolveMega(
    String link,
    WitanimeSourceToken entry,
  ) async {
    final localUrl = await _megaProxy.registerStream(link, _transport);
    if (localUrl == null) {
      throw const WitanimeBrowserRequiredException(
        'تعذر فك تشفير رابط MEGA هذا. اختر سيرفرًا آخر.',
      );
    }
    return [
      StreamResult(
        url: localUrl,
        source: displaySourceName(entry.label, version: entry.version),
        quality: qualityLabelForTier(entry.tier),
        headers: const {'User-Agent': DioWitanimeTransport.defaultUserAgent},
      ),
    ];
  }

  Future<List<StreamResult>> _resolveMediaFire(
    String link,
    WitanimeSourceToken entry,
  ) async {
    final cleanUri = Uri.tryParse(link);
    if (cleanUri != null && _archivePath.hasMatch(cleanUri.path)) {
      throw const FormatException(
        'رابط MediaFire هذا ملف مضغوط (ZIP) وليس فيديو مباشرًا، اختر سيرفرًا آخر.',
      );
    }
    final pageUrl = mediaFirePageRequestUrl(link);
    final resp = await _transport.get(
      Uri.parse(pageUrl),
      headers: const {
        'Referer': 'https://www.mediafire.com/',
        'Accept': _navigationAccept,
      },
      operation: 'host_mediafire',
    );
    if (!resp.isSuccess) return const [];
    final doc = html.parse(resp.body);
    final dlBtn = doc.querySelector(
      '#downloadButton, a[aria-label="Download file"], a.popsok',
    );
    final scrambled = dlBtn?.attributes['data-scrambled-url']?.trim();
    String? directUrl;
    if (scrambled != null && scrambled.isNotEmpty) {
      try {
        directUrl = utf8.decode(decodeBase64Loose(scrambled)).trim();
      } on FormatException {
        directUrl = null;
      }
    }
    directUrl ??= dlBtn?.attributes['href']?.trim();
    if (directUrl != null && directUrl.isNotEmpty) {
      directUrl = _absUrl(prepareExtractedMediaUrl(directUrl), Uri.parse(pageUrl));
    }
    if (directUrl == null ||
        !looksLikeStreamUrl(directUrl) ||
        directUrl == pageUrl) {
      directUrl = RegExp(
        r'''https?://download[^/\s"'<>\\]*\.mediafire\.com/[^\s"'<>\\]+''',
        caseSensitive: false,
      ).firstMatch(resp.body)?.group(0);
    }
    if (directUrl == null || directUrl.trim().isEmpty) return const [];
    final normalized = _absUrl(
      prepareExtractedMediaUrl(directUrl),
      Uri.parse(pageUrl),
    );
    final directUri = Uri.tryParse(normalized);
    if (directUri != null && _archivePath.hasMatch(directUri.path)) {
      throw const FormatException(
        'رابط MediaFire هذا ملف مضغوط (ZIP) وليس فيديو مباشرًا، اختر سيرفرًا آخر.',
      );
    }
    if (!looksLikeStreamUrl(normalized)) return const [];
    return [_hostedStream(entry, normalized, pageUrl)];
  }

  String _encodeUrlIfNeeded(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return trimmed;
    final parsed = Uri.tryParse(trimmed);
    if (parsed != null && !trimmed.contains(' ')) return trimmed;
    return Uri.encodeFull(trimmed);
  }

  String _generateGoFileWebsiteToken(String accountToken, {String lang = 'ar'}) {
    final bucket = (DateTime.now().millisecondsSinceEpoch ~/ 1000) ~/ 14400;
    final payload =
        '${DioWitanimeTransport.defaultUserAgent}::$lang::$accountToken::$bucket::12af056dacea0b';
    return crypto.sha256.convert(utf8.encode(payload)).toString();
  }

  Future<Map<String, dynamic>?> _fetchGoFileFolderData(
    String contentId,
    String token,
  ) async {
    final wt = _generateGoFileWebsiteToken(token);
    final contentResp = await _transport.get(
      Uri.https('api.gofile.io', '/contents/$contentId', {
        'page': '1',
        'pageSize': '100',
        'sortField': 'name',
        'sortDirection': '1',
      }),
      headers: {
        'Accept': 'application/json',
        'Authorization': 'Bearer $token',
        'X-Website-Token': wt,
        'X-BL': 'ar',
        'Origin': 'https://gofile.io',
        'Referer': 'https://gofile.io/',
      },
      operation: 'host_gofile_content',
    );
    if (!contentResp.isSuccess) return null;
    final root = _tryJsonMap(contentResp.body);
    final dataObj = root?['data'];
    return dataObj is Map<String, dynamic>
        ? dataObj
        : dataObj is Map
        ? Map<String, dynamic>.from(dataObj)
        : null;
  }

  Future<List<StreamResult>> _resolveGoFile(
    String link,
    WitanimeSourceToken entry,
  ) async {
    final uri = Uri.parse(link);
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty) return const [];
    final contentId = segments.last;

    final accResp = await _transport.post(
      Uri.https('api.gofile.io', '/accounts'),
      body: '{}',
      headers: const {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'Origin': 'https://gofile.io',
        'Referer': 'https://gofile.io/',
      },
      operation: 'host_gofile_account',
    );
    if (!accResp.isSuccess) return const [];
    final accData = _tryJsonMap(accResp.body)?['data'];
    final token = accData is Map ? accData['token']?.toString().trim() : null;
    if (token == null || token.isEmpty) return const [];

    final dataObj = await _fetchGoFileFolderData(contentId, token);
    if (dataObj == null) return const [];
    if (dataObj['canAccess'] == false) {
      throw const FormatException(
        'مجلد GoFile غير متاح أو محمي بكلمة مرور، اختر سيرفرًا آخر.',
      );
    }

    List<Map<Object?, Object?>> extractChildren(Map<String, dynamic> container) {
      if (container['type']?.toString() == 'file') return [container];
      final children = container['children'];
      if (children is Map) {
        return children.values.whereType<Map<Object?, Object?>>().toList();
      }
      if (children is List) {
        return children.whereType<Map<Object?, Object?>>().toList();
      }
      return const [];
    }

    final fileEntries = <Map<Object?, Object?>>[];
    for (final child in extractChildren(dataObj)) {
      if (child['type']?.toString() == 'folder') {
        final codeCandidate = child['code']?.toString().trim() ?? '';
        final idCandidate = child['id']?.toString().trim() ?? '';
        final subId = codeCandidate.isNotEmpty ? codeCandidate : idCandidate;
        if (subId.isNotEmpty) {
          final subData = await _fetchGoFileFolderData(subId, token);
          if (subData != null) fileEntries.addAll(extractChildren(subData));
        }
      } else {
        fileEntries.add(child);
      }
    }
    if (fileEntries.isEmpty) return const [];

    final out = <StreamResult>[];
    var sawArchive = false;
    final cookieHeader = 'accountToken=$token';
    final source = displaySourceName(entry.label, version: entry.version);
    for (final child in fileEntries) {
      final name = child['name']?.toString().trim().toLowerCase() ?? '';
      final linkCandidate = child['link']?.toString().trim() ?? '';
      final directLinkCandidate = child['directLink']?.toString().trim() ?? '';
      final rawDirect =
          linkCandidate.isNotEmpty ? linkCandidate : directLinkCandidate;
      final direct = _encodeUrlIfNeeded(rawDirect);
      final mime = child['mimetype']?.toString().trim().toLowerCase() ?? '';
      if (direct.isEmpty || !looksLikeStreamUrl(direct)) continue;
      if (_archivePath.hasMatch(name) ||
          mime.contains('zip') ||
          mime.contains('rar') ||
          mime.contains('7z')) {
        sawArchive = true;
        continue;
      }
      out.add(
        StreamResult(
          url: direct,
          source: source,
          quality: qualityLabelForTier(entry.tier),
          headers: {
            'Referer': 'https://gofile.io/',
            'Origin': 'https://gofile.io',
            'Cookie': cookieHeader,
            'User-Agent': DioWitanimeTransport.defaultUserAgent,
          },
        ),
      );
    }
    if (out.isEmpty && sawArchive) {
      throw const FormatException(
        'رابط GoFile هذا ملف مضغوط (ZIP) وليس فيديو مباشرًا، اختر سيرفرًا آخر.',
      );
    }
    return out;
  }

  Future<List<StreamResult>> _resolveWorkUpload(
    String link,
    WitanimeSourceToken entry,
  ) async {
    final fileId = RegExp(
      r'workupload\.com/(?:file|start)/([A-Za-z0-9]+)',
      caseSensitive: false,
    ).firstMatch(link)?.group(1);
    if (fileId == null || fileId.isEmpty) return const [];

    final pageUrl = 'https://workupload.com/file/$fileId';
    final pageResp = await _transport.get(
      Uri.parse(pageUrl),
      headers: const {'Accept': _navigationAccept},
      operation: 'host_workupload',
    );
    if (!pageResp.isSuccess) return const [];
    // Never attempt to solve or bypass WorkUpload's proof-of-work/captcha gate.
    if (pageResp.body.contains('solvePuzzle') ||
        pageResp.body.contains('/puzzle')) {
      return const [];
    }
    final doc = html.parse(pageResp.body);
    final metaText =
        '${doc.querySelector('title')?.text ?? ''} '
                '${doc.querySelectorAll('th, td, h1, span.filename').map((e) => e.text).join(' ')}'
            .toLowerCase();
    if (metaText.contains('.zip') ||
        metaText.contains('.rar') ||
        metaText.contains('.7z')) {
      throw const FormatException(
        'رابط WorkUpload هذا ملف مضغوط (ZIP) وليس فيديو مباشرًا، اختر سيرفرًا آخر.',
      );
    }
    final cookies = <String, String>{};
    void absorb(WitanimeHttpResponse r) {
      final raw = _extractCookieHeader(r);
      if (raw.isEmpty) return;
      for (final pair in raw.split(';')) {
        final eq = pair.indexOf('=');
        if (eq > 0) {
          cookies[pair.substring(0, eq).trim()] = pair.substring(eq + 1).trim();
        }
      }
    }

    absorb(pageResp);
    String cookieString() =>
        cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');

    final startUrl = 'https://workupload.com/start/$fileId';
    final startResp = await _transport.get(
      Uri.parse(startUrl),
      headers: {
        'Referer': pageUrl,
        'Accept': _navigationAccept,
        if (cookies.isNotEmpty) 'Cookie': cookieString(),
      },
      operation: 'host_workupload_start',
    );
    absorb(startResp);

    final srvResp = await _transport.get(
      Uri.parse('https://workupload.com/api/file/getDownloadServer/$fileId'),
      headers: {
        'Referer': startUrl,
        'Accept': 'application/json',
        'X-Requested-With': 'XMLHttpRequest',
        if (cookies.isNotEmpty) 'Cookie': cookieString(),
      },
      operation: 'host_workupload_server',
    );
    absorb(srvResp);
    if (!srvResp.isSuccess) return const [];
    final data = _tryJsonMap(srvResp.body)?['data'];
    final dlUrl = data is Map ? data['url']?.toString().trim() : null;
    if (dlUrl == null || !looksLikeStreamUrl(dlUrl)) return const [];
    final dlUri = Uri.tryParse(dlUrl);
    if (dlUri != null && _archivePath.hasMatch(dlUri.path)) {
      throw const FormatException(
        'رابط WorkUpload هذا ملف مضغوط (ZIP) وليس فيديو مباشرًا، اختر سيرفرًا آخر.',
      );
    }
    return [
      StreamResult(
        url: dlUrl,
        source: displaySourceName(entry.label, version: entry.version),
        quality: qualityLabelForTier(entry.tier),
        headers: {
          'Referer': 'https://workupload.com/',
          'User-Agent': DioWitanimeTransport.defaultUserAgent,
          if (cookies.isNotEmpty) 'Cookie': cookieString(),
        },
      ),
    ];
  }

  Future<List<StreamResult>> _resolveFourShared(
    String link,
    WitanimeSourceToken entry,
  ) async {
    final fileId = RegExp(
      r'4shared\.com/(?:web/embed/file|embed|video|file|s)/([A-Za-z0-9_-]+)',
      caseSensitive: false,
    ).firstMatch(link)?.group(1);
    if (fileId == null || fileId.isEmpty) return const [];
    final normalizedEmbed = 'https://www.4shared.com/web/embed/file/$fileId';
    final resp = await _transport.get(
      Uri.parse(normalizedEmbed),
      headers: const {'Referer': 'https://www.4shared.com/'},
      operation: 'host_4shared',
    );
    if (!resp.isSuccess) return const [];
    final doc = html.parse(resp.body);
    final mp4Url =
        doc.querySelector('video source[src], video[src]')?.attributes['src']?.trim() ??
        RegExp(
          r'''https?://dc\d+\.4shared\.com/[^\s"'<>]+\.mp4[^\s"'<>]*''',
          caseSensitive: false,
        ).firstMatch(resp.body)?.group(0);
    if (mp4Url == null || !looksLikeStreamUrl(mp4Url)) return const [];
    return [_hostedStream(entry, mp4Url, 'https://www.4shared.com/')];
  }

  Future<List<StreamResult>> _resolveDotplay(
    String referer,
    Uri uri,
    WitanimeSourceToken entry, {
    required int depth,
  }) async {
    final page = await _transport.get(
      uri,
      headers: {
        'Accept': _navigationAccept,
        'Referer': referer,
        'Upgrade-Insecure-Requests': '1',
      },
      operation: 'host_dotplay_page',
    );
    final pageUri = page.finalUri ?? uri;
    final embedCode =
        RegExp(
          r'''window\.embedCode\s*=\s*["']([^"']+)["']''',
        ).firstMatch(page.body)?.group(1) ??
        RegExp(r'^/embed/([^/]+)').firstMatch(pageUri.path)?.group(1) ??
        (pageUri.pathSegments.isNotEmpty ? pageUri.pathSegments.last : null);
    final embedToken = RegExp(
      r'''window\.embedToken\s*=\s*["']([^"']+)["']''',
    ).firstMatch(page.body)?.group(1)?.trim();
    final cookies = _extractCookieHeader(page);
    if (embedCode != null && embedCode.isNotEmpty) {
      final response = await _transport.get(
        pageUri.replace(path: '/api.php', queryParameters: {'code': embedCode}),
        headers: {
          'Accept': 'application/json',
          'Referer': pageUri.toString(),
          if (embedToken != null && embedToken.isNotEmpty)
            'X-Embed-Token': embedToken,
          if (cookies.isNotEmpty) 'Cookie': cookies,
        },
        operation: 'host_dotplay',
      );
      final encoded = _tryJsonMap(response.body)?['video_url'];
      if (response.isSuccess && encoded is String && encoded.trim().isNotEmpty) {
        try {
          final decoded = utf8
              .decode(decodeBase64Loose(encoded))
              .split('|')
              .first;
          final url = prepareExtractedMediaUrl(decoded);
          if (looksLikeStreamUrl(url)) {
            return [_hostedStream(entry, url, pageUri.toString())];
          }
        } on FormatException {
          // Some older embed pages contain a plain player configuration.
        }
      }
    }
    return _resolveGeneric(
      referer,
      pageUri.toString(),
      entry,
      preloadedBody: page.isSuccess ? page.body : null,
      depth: depth,
    );
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

    // Encrypted Yonaplay API flow (`window._E={a:"/api", c:..., t:..., k:...}`)
    if (isYona) {
      final rawConfig = RegExp(
        r'window\._E\s*=\s*(\{[^;]+\})',
      ).firstMatch(page.body)?.group(1);
      final inlineConfig = rawConfig == null ? null : _tryJsonMap(rawConfig);
      final apiPath =
          inlineConfig?['a']?.toString().trim() ??
          RegExp(
            r'''window\._E\s*=\s*\{[^}]*\ba\s*:\s*["']([^"']+)["']''',
          ).firstMatch(page.body)?.group(1) ??
          '/api';
      final apiUri = pageUri.resolve(apiPath.replaceAll(r'\/', '/'));
      final apiBase = apiUri.origin == pageUri.origin
          ? '${apiUri.origin}${apiUri.path.replaceFirst(RegExp(r'/+$'), '')}'
          : '${pageUri.origin}/api';
      final cookie = _extractCookieHeader(page);
      var code = inlineConfig?['c']?.toString().trim() ?? '';
      var embedToken = inlineConfig?['t']?.toString().trim() ?? '';
      var key = inlineConfig?['k']?.toString().trim() ?? '';

      Map<String, String> apiHeaders() => {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'Referer': pageUrl,
        'Origin': pageUri.origin,
        'X-Requested-With': 'XMLHttpRequest',
        if (embedToken.isNotEmpty) 'X-Embed-Token': embedToken,
        if (cookie.isNotEmpty) 'Cookie': cookie,
      };

      if (code.isEmpty || key.isEmpty) {
        final initResp = await _transport.post(
          Uri.parse('$apiBase/init-session.php'),
          body: '{}',
          headers: apiHeaders(),
          operation: 'yonaplay_init',
        );
        if (initResp.isSuccess) {
          final initJson = _tryJsonMap(initResp.body);
          code = initJson?['c']?.toString().trim() ?? '';
          embedToken = initJson?['t']?.toString().trim() ?? embedToken;
          key = initJson?['k']?.toString().trim() ?? '';
        }
      }
      if (code.isNotEmpty && key.isNotEmpty) {
        final srcResp = await _transport.post(
          Uri.parse('$apiBase/sources.php'),
          body: jsonEncode({'code': code}),
          headers: apiHeaders(),
          operation: 'yonaplay_sources',
        );
        final srcJson = _tryJsonMap(srcResp.body);
        final tokens = _rankedYonaplayServerTokens(
          srcJson?['qualities'],
          entry.tier,
        );
        for (final token in tokens) {
          final apiResp = await _transport.post(
            Uri.parse('$apiBase/api.php'),
            body: jsonEncode({'code': code, 'token': token, 'key': key}),
            headers: apiHeaders(),
            operation: 'yonaplay_api',
          );
          final dataJson = _tryJsonMap(apiResp.body);
          final encrypted = dataJson?['d']?.toString();
          if (encrypted == null || encrypted.isEmpty) continue;
          final plain = decryptYonaplayPayload(key, encrypted);
          if (plain == null || plain.trim().isEmpty) continue;
          final sendRef = dataJson?['r'] != 0;
          try {
            final resolved = await resolveHostedLink(
              sendRef ? '${pageUri.origin}/' : pageUrl,
              _absUrl(plain.trim(), pageUri),
              entry,
              depth: depth + 1,
            );
            if (resolved.isNotEmpty) return resolved;
          } catch (_) {
            // Try next Yonaplay server candidate.
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
              headers: {
                'Referer': pageUrl,
                'User-Agent': DioWitanimeTransport.defaultUserAgent,
              },
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

  List<String> _rankedYonaplayServerTokens(
    Object? qualities,
    String preferredTier,
  ) {
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
    final ranked = <(int, String)>[];
    final seen = <String>{};
    for (final (tierName, tier) in tiers) {
      if (tier is! Map) continue;
      final name = tierName.trim().toLowerCase();
      var rank = rankMap[name] ?? 5;
      if (name == prefer) rank = 0;
      final servers = tier['servers'];
      if (servers is! List || servers.isEmpty) continue;
      for (final server in servers.whereType<Map<Object?, Object?>>()) {
        final token = server['token']?.toString().trim();
        if (token == null || token.isEmpty || !seen.add(token)) continue;
        ranked.add((rank, token));
      }
    }
    ranked.sort((a, b) => a.$1.compareTo(b.$1));
    return [for (final item in ranked) item.$2];
  }

  Future<List<StreamResult>> _resolveVidea(
    String link,
    WitanimeSourceToken entry,
  ) async {
    final uri = Uri.parse(link);
    final trailingId = uri.pathSegments.isNotEmpty
        ? uri.pathSegments.last.split('-').last
        : '';
    final vcode =
        uri.queryParameters['v'] ??
        RegExp(r'[?&]v=([A-Za-z0-9_-]+)').firstMatch(link)?.group(1) ??
        (trailingId.length >= 8 && trailingId.length <= 24 ? trailingId : null);
    if (vcode == null || vcode.isEmpty) return const <StreamResult>[];
    final playerUrl = 'https://videa.hu/player?v=$vcode';
    final page = await _transport.get(
      Uri.parse(playerUrl),
      headers: {'Referer': 'https://videa.hu/'},
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
      headers: {'Referer': playerUrl, 'Origin': 'https://videa.hu'},
      operation: 'host_videa_xml',
    );
    if (!xmlResp.isSuccess || xmlResp.body.trim().isEmpty) {
      return const <StreamResult>[];
    }
    final contentType = (xmlResp.header('content-type') ?? '').toLowerCase();
    final String xml;
    if (contentType.startsWith('text/xml') ||
        xmlResp.body.trimLeft().startsWith('<')) {
      xml = xmlResp.body;
    } else {
      final xs = xmlResp.header('x-videa-xs') ?? '';
      final Uint8List rawBytes;
      try {
        rawBytes = decodeBase64Loose(xmlResp.body);
      } on FormatException {
        return const <StreamResult>[];
      }
      final decrypted = rc4Crypt(utf8.encode('${parts.k}$rnd$xs'), rawBytes);
      xml = utf8.decode(decrypted, allowMalformed: true);
    }
    if (xml.contains('<error')) return const <StreamResult>[];

    final doc = html.parse(xml);
    final globalExp =
        doc.querySelector('video_sources')?.attributes['exp']?.trim() ??
        RegExp(
          r'''<video_sources?[^>]*exp=["'](\d+)["']''',
        ).firstMatch(xml)?.group(1);
    final hashes = <String, String>{};
    for (final m in RegExp(
      r'<hash_value_([^>]+)>([^<]+)</hash_value_',
    ).allMatches(xml)) {
      hashes[m.group(1)!.trim()] = m.group(2)!.trim();
    }

    final candidates =
        <({int rank, bool isMp4, String quality, String url})>[];
    for (final el in doc.querySelectorAll('video_source')) {
      final q = el.attributes['name']?.trim() ?? '';
      final rawPath = el.text.trim();
      if (q.isEmpty || rawPath.isEmpty) continue;
      final exp = el.attributes['exp']?.trim() ?? globalExp;
      final md5Hash = hashes[q];
      final baseUrl = rawPath.startsWith('http')
          ? rawPath
          : rawPath.startsWith('//')
          ? 'https:$rawPath'
          : 'https://$rawPath';
      final mediaUrl = (md5Hash != null && exp != null && exp.isNotEmpty)
          ? '$baseUrl?md5=$md5Hash&expires=$exp'
          : baseUrl;
      final mime = (el.attributes['mimetype'] ?? '').toLowerCase();
      final isMp4 = mime.contains('mp4') || !mime.contains('webm');
      final height = int.tryParse(RegExp(r'(\d+)').firstMatch(q)?.group(1) ?? '') ?? 0;
      candidates.add((rank: height, isMp4: isMp4, quality: q, url: mediaUrl));
    }
    candidates.sort((a, b) {
      if (a.isMp4 != b.isMp4) return a.isMp4 ? -1 : 1;
      return b.rank.compareTo(a.rank);
    });

    final source = displaySourceName(entry.label, version: entry.version);
    return [
      for (final c in candidates)
        StreamResult(
          url: c.url,
          source: source,
          quality: c.quality,
          headers: {
            'Referer': playerUrl,
            'User-Agent': DioWitanimeTransport.defaultUserAgent,
          },
        ),
    ];
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

  String _randomUuidV4() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    String hex(int start, int end) => bytes
        .sublist(start, end)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
  }

  Future<List<StreamResult>> _resolveVideas(
    String episodeUrl,
    String link,
    WitanimeSourceToken entry,
  ) async {
    final normalizedUrl = link.replaceFirst('/embed/media/', '/embed/');
    final uri = Uri.parse(normalizedUrl);
    final origin = uri.origin.isNotEmpty ? uri.origin : 'https://app.videas.com';
    final resp = await _transport.get(
      uri,
      headers: {'Referer': '${_origin.origin}/'},
      operation: 'host_videas',
    );
    if (!resp.isSuccess) return const <StreamResult>[];

    final doc = html.parse(resp.body);
    var embedId = '';
    var opening = '';
    final cfgRaw = doc.querySelector('script#videas-embed-config')?.text ?? '';
    if (cfgRaw.trim().isNotEmpty) {
      final cfg = _tryJsonMap(cfgRaw);
      embedId = cfg?['embedId']?.toString().trim() ?? '';
      opening = cfg?['opening']?.toString().trim() ?? '';
    }
    if (embedId.isEmpty) {
      embedId =
          RegExp(r'/embed/(?:media/)?([0-9a-fA-F-]{20,})')
              .firstMatch(link)
              ?.group(1) ??
          '';
    }

    final source = displaySourceName(entry.label, version: entry.version);
    final quality = qualityLabelForTier(entry.tier);
    final streamHeaders = <String, String>{
      'Referer': '$origin/',
      'Origin': origin,
      'User-Agent': DioWitanimeTransport.defaultUserAgent,
    };

    if (embedId.isNotEmpty) {
      final viewerId = _randomUuidV4();
      final visResp = await _transport.get(
        Uri.parse('$origin/api/visitor/embed/$embedId/?viewer_id=$viewerId'),
        headers: {
          'Accept': 'application/json',
          'Origin': origin,
          'Referer': link,
          if (opening.isNotEmpty) 'X-Embed-Opening': opening,
        },
        operation: 'host_videas_visitor',
      );
      if (visResp.isSuccess && visResp.body.trim().isNotEmpty) {
        final visObj = _tryJsonMap(visResp.body);
        final playbackToken =
            visObj?['playback_token']?.toString().trim() ?? '';
        final sessionId = visObj?['session_id']?.toString().trim() ?? '';
        final items = visObj?['items'];
        if (items is List) {
          final out = <StreamResult>[];
          for (final item in items.whereType<Map<Object?, Object?>>()) {
            final asset = item['asset'];
            if (asset is! Map) continue;
            final assetUid = asset['uid']?.toString().trim() ?? '';
            if (assetUid.isEmpty) continue;
            final subs = <SubtitleFile>[];
            final rawSubs = asset['subtitles'];
            if (rawSubs is List) {
              for (final s in rawSubs.whereType<Map<Object?, Object?>>()) {
                final subUrl = s['url']?.toString().trim() ?? '';
                if (subUrl.isEmpty) continue;
                final subLabel =
                    s['label']?.toString().trim() ??
                    s['language']?.toString().trim() ??
                    'Arabic';
                subs.add(
                  SubtitleFile(
                    url: _absUrl(subUrl, Uri.parse(origin)),
                    label: subLabel,
                    lang: subLabel,
                  ),
                );
              }
            }
            final pbResp = await _transport.post(
              Uri.parse('$origin/api/visitor/playback/info/'),
              body: jsonEncode({
                'asset_id': assetUid,
                'playback_token': playbackToken,
                'session_id': sessionId,
              }),
              headers: {
                'Content-Type': 'application/json',
                'Accept': 'application/json',
                'Origin': origin,
                'Referer': link,
              },
              operation: 'host_videas_playback',
            );
            if (!pbResp.isSuccess) continue;
            final pbObj = _tryJsonMap(pbResp.body);
            String? extractField(Object? value) {
              if (value is Map) return value['url']?.toString().trim();
              if (value is String &&
                  (value.startsWith('/') || value.startsWith('http'))) {
                return value.trim();
              }
              return null;
            }

            final mp4Raw = extractField(pbObj?['source_url']);
            final hlsRaw = extractField(pbObj?['hls_url']);
            if (hlsRaw != null && hlsRaw.isNotEmpty) {
              out.add(
                StreamResult(
                  url: _absUrl(hlsRaw, Uri.parse(origin)),
                  source: source,
                  quality: quality,
                  headers: streamHeaders,
                  subtitles: subs.isEmpty ? null : subs,
                ),
              );
            }
            if (mp4Raw != null && mp4Raw.isNotEmpty) {
              out.add(
                StreamResult(
                  url: _absUrl(mp4Raw, Uri.parse(origin)),
                  source: source,
                  quality: quality,
                  headers: streamHeaders,
                  subtitles: subs.isEmpty ? null : subs,
                ),
              );
            }
          }
          if (out.isNotEmpty) return out;
        }
      }
    }

    final preload =
        RegExp(
          r'''<link[^>]+rel=["']preload["'][^>]+href=["']([^"']+)["']''',
        ).firstMatch(resp.body)?.group(1) ??
        RegExp(
          r'''"src"\s*:\s*"(https?://[^"]+\.m3u8[^"]*)"''',
        ).firstMatch(resp.body)?.group(1);
    if (preload != null && looksLikeStreamUrl(preload)) {
      return [
        StreamResult(
          url: preload,
          source: source,
          quality: quality,
          headers: streamHeaders,
        ),
      ];
    }
    return _resolveGeneric(episodeUrl, link, entry, preloadedBody: resp.body);
  }

  Future<List<StreamResult>> _resolveOkRu(
    String link,
    WitanimeSourceToken entry,
  ) async {
    final embedLink = link.replaceFirst('/video/', '/videoembed/');
    final resp = await _transport.get(
      Uri.parse(embedLink),
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
    const okHeaders = <String, String>{
      'Referer': 'https://ok.ru/',
      'User-Agent': DioWitanimeTransport.defaultUserAgent,
    };
    const okQualityRank = <String, int>{
      'ultra': 2160,
      'quad': 1440,
      'full': 1080,
      'hd': 720,
      'sd': 480,
      'low': 360,
      'lowest': 240,
      'mobile': 144,
    };

    final mp4Items = <({int rank, StreamResult stream})>[];
    final videos = meta['videos'];
    if (videos is List) {
      for (final video in videos) {
        if (video is! Map) continue;
        if (video['disallowed'] == true) continue;
        final url = video['url']?.toString().trim() ?? '';
        if (url.isEmpty) continue;
        final name = video['name']?.toString().trim() ?? '';
        final rank =
            okQualityRank[name.toLowerCase()] ??
            int.tryParse(RegExp(r'(\d+)').firstMatch(name)?.group(1) ?? '') ??
            0;
        mp4Items.add((
          rank: rank,
          stream: StreamResult(
            url: url,
            source: source,
            quality: name.isNotEmpty
                ? qualityLabelForTier(name)
                : qualityLabelForTier(entry.tier),
            headers: okHeaders,
          ),
        ));
      }
    }
    mp4Items.sort((a, b) => b.rank.compareTo(a.rank));
    final out = <StreamResult>[for (final item in mp4Items) item.stream];
    final hls =
        (meta['ondemandHls']?.toString().trim().isNotEmpty == true
            ? meta['ondemandHls'].toString().trim()
            : meta['hlsManifestUrl']?.toString().trim()) ??
        '';
    if (hls.isNotEmpty) {
      out.add(
        StreamResult(
          url: hls,
          source: source,
          quality: 'متعدد',
          headers: okHeaders,
        ),
      );
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
      'User-Agent': DioWitanimeTransport.defaultUserAgent,
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
    final pageCookie = _extractCookieHeader(resp);
    final mr = await _transport.get(
      Uri.parse(metaUrl),
      headers: {
        'Referer': link,
        'X-Requested-With': 'XMLHttpRequest',
        if (pageCookie.isNotEmpty) 'Cookie': pageCookie,
      },
      operation: 'host_mailru_meta',
    );
    if (!mr.isSuccess) return const <StreamResult>[];
    final metaCookie = _extractCookieHeader(mr);
    final cookieMap = <String, String>{};
    for (final raw in [pageCookie, metaCookie]) {
      for (final part in raw.split(';')) {
        final eq = part.indexOf('=');
        if (eq > 0) {
          cookieMap[part.substring(0, eq).trim()] =
              part.substring(eq + 1).trim();
        }
      }
    }
    final combinedCookie = cookieMap.entries
        .map((e) => '${e.key}=${e.value}')
        .join('; ');
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
          headers: {
            'Referer': link,
            'User-Agent': DioWitanimeTransport.defaultUserAgent,
            if (combinedCookie.isNotEmpty) 'Cookie': combinedCookie,
          },
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
    List<String> extractUrls(String body, Uri baseUri) {
      final unpacked = unpackPackedJs(body);
      final text = unpacked.isNotEmpty ? '$unpacked\n$body' : body;
      final seen = <String>{};
      final m3u8Urls = <String>[];
      final txtUrls = <String>[];

      void addCandidate(String raw) {
        final clean = raw
            .replaceAll(r'\/', '/')
            .replaceAll('&amp;', '&')
            .trim();
        if (clean.isEmpty) return;
        final resolved = _absUrl(clean, baseUri);
        if (!looksLikeStreamUrl(resolved) || !seen.add(resolved)) return;
        if (resolved.toLowerCase().contains('.m3u8')) {
          m3u8Urls.add(resolved);
        } else {
          txtUrls.add(resolved);
        }
      }

      for (final keyName in const ['hls4', 'hls3', 'hls2', 'file']) {
        for (final match in RegExp(
          '''["']$keyName["']\\s*:\\s*["']([^"']+)["']''',
        ).allMatches(text)) {
          final raw = match.group(1)!.replaceAll(r'\/', '/').trim();
          if (raw.contains('.m3u8') ||
              raw.contains('master.txt') ||
              raw.startsWith('/stream/')) {
            addCandidate(raw);
          }
        }
      }
      for (final pattern in [
        RegExp(r'''https?://[^"'\s<>\\]+master\.m3u8[^"'\s<>\\]*'''),
        RegExp(r'''https?://[^"'\s<>\\]+\.m3u8[^"'\s<>\\]*'''),
        RegExp(r'''https?://[^"'\s<>\\]+master\.txt[^"'\s<>\\]*'''),
      ]) {
        for (final match in pattern.allMatches(text)) {
          addCandidate(match.group(0)!);
        }
      }
      // Prefer explicit .m3u8 playlists over .txt manifests for media_kit/AVPlayer.
      return [...m3u8Urls, ...txtUrls];
    }

    final uri = Uri.parse(link);
    final code =
        RegExp(r'/(?:e|d|v)/([A-Za-z0-9]+)').firstMatch(uri.path)?.group(1) ??
        (uri.pathSegments.isNotEmpty
            ? uri.pathSegments.last.split('.').first
            : '');
    final hostLower = uri.host.toLowerCase();
    final isHgRedirector = hostLower.contains('hgcloud.');

    final candidates = <({Uri uri, String op})>[];
    if (!isHgRedirector) {
      candidates.add((uri: uri, op: 'host_hgcloud'));
    }
    if (code.isNotEmpty) {
      final path = uri.path.startsWith('/e/') ? uri.path : '/e/$code';
      for (final mirror in _hgcloudMirrors) {
        if (mirror == hostLower) continue;
        candidates.add((
          uri: Uri.https(mirror, path),
          op: 'host_hgcloud_mirror',
        ));
      }
    }
    if (isHgRedirector) {
      candidates.add((uri: uri, op: 'host_hgcloud'));
    }

    var urls = const <String>[];
    var finalOrigin = uri.origin;
    var finalRef = '${uri.origin}/';

    // When the primary URL is hgcloud.*, try it first only if it directly serves
    // packed config; otherwise fall through immediately to active player mirrors.
    for (final candidate in candidates) {
      final candOrigin = candidate.uri.origin;
      final candRef = candidate.op == 'host_hgcloud'
          ? episodeUrl
          : '$candOrigin/';
      final resp = await _transport.get(
        candidate.uri,
        headers: {'Referer': candRef},
        operation: candidate.op,
      );
      if (!resp.isSuccess) continue;
      final effectiveUri = resp.finalUri ?? candidate.uri;
      final found = extractUrls(resp.body, effectiveUri);
      if (found.isNotEmpty) {
        urls = found;
        finalOrigin = effectiveUri.origin;
        finalRef = '${effectiveUri.origin}/';
        break;
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
          headers: {
            'Referer': finalRef,
            'Origin': finalOrigin,
            'User-Agent': DioWitanimeTransport.defaultUserAgent,
          },
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
        headers: {
          'Referer': '$origin/',
          'User-Agent': DioWitanimeTransport.defaultUserAgent,
        },
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
            headers: {
              'Referer': link,
              'User-Agent': DioWitanimeTransport.defaultUserAgent,
            },
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
    final uri = Uri.parse(link);
    final String embedUrl;
    if (link.contains('embed-')) {
      embedUrl = link;
    } else {
      final lastSeg = uri.pathSegments.isNotEmpty
          ? uri.pathSegments.last.split('.').first
          : '';
      embedUrl = lastSeg.isNotEmpty
          ? 'https://www.mp4upload.com/embed-$lastSeg.html'
          : link;
    }
    final resp = await _transport.get(
      Uri.parse(embedUrl),
      headers: const {'Referer': 'https://www.mp4upload.com/'},
      operation: 'host_mp4upload',
    );
    if (!resp.isSuccess) return const <StreamResult>[];
    final text = '${unpackPackedJs(resp.body)}\n${resp.body}';
    final src =
        RegExp(
          r'''player\.src\([^)]*?(https?://[^"'\s)]+\.mp4[^"'\s)]*)''',
          caseSensitive: false,
        ).firstMatch(text)?.group(1) ??
        RegExp(
          r'''src\s*:\s*["'](https?://[^"']+\.mp4[^"']*)["']''',
          caseSensitive: false,
        ).firstMatch(text)?.group(1) ??
        RegExp(
          r'''https?://[a-z0-9.-]*mp4upload\.com(?::\d+)?/d/[^"'\s<>]+\.mp4[^"'\s<>]*''',
          caseSensitive: false,
        ).firstMatch(text)?.group(0);
    if (src != null && looksLikeStreamUrl(src)) {
      return [
        StreamResult(
          url: src,
          source: displaySourceName(entry.label, version: entry.version),
          quality: qualityLabelForTier(entry.tier),
          headers: const {
            'Referer': 'https://www.mp4upload.com/',
            'Origin': 'https://www.mp4upload.com',
            'User-Agent': DioWitanimeTransport.defaultUserAgent,
          },
        ),
      ];
    }
    return _resolveGeneric(episodeUrl, embedUrl, entry, preloadedBody: text);
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
        decodedDownload = utf8.decode(decodeBase64Loose(scrambled));
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
    url: _encodeUrlIfNeeded(url),
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
