import 'dart:convert';
import 'dart:math';

import 'package:html_unescape/html_unescape.dart';

import '../../domain/entity/multimedia_item.dart';
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
      if (kind.isEmpty || watchUrl.isEmpty || token.isEmpty) return null;
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

  Future<({String csrf, Uri sourcesUri, Uri watchUri})> _fetchWatchMeta(
    Uri watchUri,
  ) async {
    final page = await _transport.get(
      watchUri,
      headers: {
        'Accept':
            'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Referer': '${_origin.origin}/',
      },
      operation: 'watch_page',
    );
    if (page.statusCode == 429) {
      throw const FormatException(
        'تجاوزت حد الطلبات على Witanime، انتظر قليلًا وأعد المحاولة.',
      );
    }
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
    final rawSources = RegExp(
      r'''sourcesUrl\s*:\s*["']([^"']+)["']''',
    ).firstMatch(page.body)?.group(1)?.replaceAll(r'\/', '/').trim();
    final sourcesUri = rawSources != null && rawSources.isNotEmpty
        ? _resolveSameOrigin(rawSources, effectiveWatch) ??
              _defaultSourcesUri(effectiveWatch)
        : _defaultSourcesUri(effectiveWatch);

    return (csrf: csrf.trim(), sourcesUri: sourcesUri, watchUri: effectiveWatch);
  }

  Uri _defaultSourcesUri(Uri watchUri) {
    final normalizedPath = watchUri.path.endsWith('/')
        ? '${watchUri.path}sources'
        : '${watchUri.path}/sources';
    return watchUri.replace(path: normalizedPath, query: null, fragment: null);
  }

  Uri? _resolveSameOrigin(String raw, Uri base) {
    final parsed = Uri.tryParse(raw.trim());
    if (parsed == null) return null;
    final resolved = base.resolveUri(parsed);
    return resolved.host == _origin.host ? resolved.removeFragment() : null;
  }

  Future<List<StreamResult>> loadSources(
    String watchUrl, {
    required bool forDownload,
  }) async {
    final parsedWatch = Uri.tryParse(watchUrl.trim());
    if (parsedWatch == null || parsedWatch.host != _origin.host) {
      throw const FormatException('Invalid Witanime watch URL');
    }
    final meta = await _fetchWatchMeta(parsedWatch);
    final resp = await _transport.post(
      meta.sourcesUri,
      body: '{}',
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'X-CSRF-TOKEN': meta.csrf,
        'X-Requested-With': 'XMLHttpRequest',
        'Referer': meta.watchUri.toString(),
        'Origin': _origin.origin,
      },
      operation: forDownload ? 'download_sources' : 'stream_sources',
    );
    if (resp.statusCode == 429) {
      throw const FormatException(
        'تجاوزت حد الطلبات على Witanime، انتظر قليلًا وأعد المحاولة.',
      );
    }
    if (!resp.isSuccess) {
      throw FormatException('Witanime sources HTTP ${resp.statusCode}');
    }
    final dynamic root = jsonDecode(resp.body);
    if (root is! Map) return const <StreamResult>[];

    final out = <StreamResult>[];
    final seen = <String>{};

    void collectGroup(Object? groupObj, {String? version}) {
      if (groupObj is! Map) return;
      final orderedTiers = <String>[
        ..._tierOrder,
        for (final key in groupObj.keys)
          if (!_tierOrder.contains(key.toString().toUpperCase())) key.toString(),
      ];
      for (final tier in orderedTiers) {
        final entries = groupObj[tier] ?? groupObj[tier.toLowerCase()];
        if (entries is! List) continue;
        for (final rawEntry in entries) {
          if (rawEntry is! Map) continue;
          final token = rawEntry['token']?.toString().trim() ?? '';
          if (token.isEmpty) continue;
          final label =
              rawEntry['label']?.toString().trim().isNotEmpty == true
              ? rawEntry['label'].toString().trim()
              : rawEntry['name']?.toString().trim().isNotEmpty == true
              ? rawEntry['name'].toString().trim()
              : 'Server';
          final sourceName = displaySourceName(label, version: version);
          final quality = qualityLabelForTier(tier);
          if (!seen.add('$token|$version')) continue;
          final encoded = WitanimeSourceToken(
            kind: forDownload ? 'download' : 'stream',
            watchUrl: meta.watchUri.toString(),
            token: token,
            label: label,
            tier: tier,
            version: version,
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

    final bucketKey = forDownload ? 'downloads' : 'players';
    final fallbackKey = forDownload ? 'players' : 'downloads';
    collectGroup(root[bucketKey]);

    final versions = root['versions'];
    if (versions is Map) {
      for (final entry in versions.entries) {
        final versionName = entry.key.toString();
        final subGroup = entry.value;
        if (subGroup is Map) {
          collectGroup(subGroup[bucketKey], version: versionName);
        }
      }
    }

    if (out.isEmpty) {
      collectGroup(root[fallbackKey]);
      if (versions is Map) {
        for (final entry in versions.entries) {
          final versionName = entry.key.toString();
          final subGroup = entry.value;
          if (subGroup is Map) {
            collectGroup(subGroup[fallbackKey], version: versionName);
          }
        }
      }
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
          final items = await _resolveToken(
            WitanimeSourceToken.tryDecode(candidate.url)!,
            forDownload: forDownload,
          );
          resolved.addAll(items);
          if (resolved.isNotEmpty) break;
        } on WitanimeBrowserRequiredException {
          rethrow;
        } catch (_) {
          // Try next server candidate.
        }
      }
      return List<StreamResult>.unmodifiable(resolved);
    }
    return _resolveToken(decoded, forDownload: forDownload);
  }

  Future<List<StreamResult>> _resolveToken(
    WitanimeSourceToken entry, {
    required bool forDownload,
  }) async {
    final watchUri = Uri.parse(entry.watchUrl);
    final meta = await _fetchWatchMeta(watchUri);
    final encodedToken = Uri.encodeComponent(entry.token);
    final sourcePath = (forDownload || entry.isDownload)
        ? '/watch/download-source/$encodedToken'
        : '/watch/stream-source/$encodedToken';
    final gatePath = (forDownload || entry.isDownload)
        ? '/watch/download-gate/$encodedToken'
        : '/watch/stream-gate/$encodedToken';

    final activateResp = await _transport.post(
      _origin.replace(path: sourcePath),
      body: '{}',
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'X-CSRF-TOKEN': meta.csrf,
        'X-Requested-With': 'XMLHttpRequest',
        'Referer': meta.watchUri.toString(),
        'Origin': _origin.origin,
      },
      operation: forDownload ? 'download_source_unlock' : 'stream_source_unlock',
    );
    if (activateResp.statusCode == 429) {
      throw const FormatException(
        'تجاوزت حد الطلبات على Witanime، انتظر قليلًا وأعد المحاولة.',
      );
    }
    if (!activateResp.isSuccess) {
      throw FormatException('Witanime source unlock HTTP ${activateResp.statusCode}');
    }

    // Stream gate responds 302 + Location only on navigation requests without Referer.
    final gateResp = await _transport.get(
      _origin.replace(path: gatePath),
      headers: (forDownload || entry.isDownload)
          ? {
              'Accept':
                  'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
              'Referer': meta.watchUri.toString(),
              'Upgrade-Insecure-Requests': '1',
            }
          : const {
              'Accept':
                  'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
              'Sec-Fetch-Mode': 'navigate',
              'Sec-Fetch-Dest': 'iframe',
              'Sec-Fetch-Site': 'same-origin',
            },
      followRedirects: false,
      operation: forDownload ? 'download_gate' : 'stream_gate',
    );
    if (gateResp.statusCode == 429) {
      throw const FormatException(
        'تجاوزت حد الطلبات على Witanime، انتظر قليلًا وأعد المحاولة.',
      );
    }
    if (gateResp.statusCode >= 400) {
      throw FormatException('Witanime gate HTTP ${gateResp.statusCode}');
    }

    final rawLoc =
        gateResp.header('location') ??
        RegExp(r"url='([^']+)'").firstMatch(gateResp.body)?.group(1) ??
        RegExp(
          r'''href=["'](https?://[^"']+)["']''',
        ).firstMatch(gateResp.body)?.group(1);
    if (rawLoc == null || rawLoc.trim().isEmpty) {
      throw const FormatException('Witanime gate returned no host URL');
    }
    final hostUrl = _absUrl(rawLoc.trim(), _origin);
    final refreshEncoded = entry.encode();
    final streams = await resolveHostedLink(
      meta.watchUri.toString(),
      hostUrl,
      entry,
    );
    return [
      for (final stream in streams)
        stream.copyWith(
          refreshUrl: stream.refreshUrl?.trim().isNotEmpty == true
              ? stream.refreshUrl
              : refreshEncoded,
        ),
    ];
  }

  Future<List<StreamResult>> resolveHostedLink(
    String episodeUrl,
    String link,
    WitanimeSourceToken entry, {
    int depth = 0,
  }) async {
    if (depth > 4) return const <StreamResult>[];
    final cleanLink = link.trim();
    if (cleanLink.isEmpty) return const <StreamResult>[];
    final low = cleanLink.toLowerCase();
    final displaySource = displaySourceName(entry.label, version: entry.version);
    final quality = qualityLabelForTier(entry.tier);

    if (low.contains('mega.nz') || low.contains('mega.co.nz')) {
      throw WitanimeBrowserRequiredException(
        'هذا المصدر ($displaySource) يتطلب فتح صفحة المشاهدة الرسمية على Witanime.',
        watchUrl: Uri.tryParse(episodeUrl),
      );
    }

    final basePath = cleanLink.split(RegExp(r'[?#]')).first.toLowerCase();
    if (basePath.endsWith('.mp4') || basePath.endsWith('.m3u8')) {
      return [
        StreamResult(
          url: cleanLink,
          source: displaySource,
          quality: quality,
          headers: {'Referer': episodeUrl},
        ),
      ];
    }

    if (low.contains('yonaplay') || low.contains('soraplay')) {
      return _resolveYonaOrSora(episodeUrl, cleanLink, entry, depth: depth);
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
    if (low.contains('dropbox.com')) {
      return _resolveDropbox(episodeUrl, cleanLink, entry);
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

    return _resolveGeneric(episodeUrl, cleanLink, entry);
  }

  Future<List<StreamResult>> _resolveYonaOrSora(
    String episodeUrl,
    String link,
    WitanimeSourceToken entry, {
    required int depth,
  }) async {
    final uri = Uri.parse(link);
    final origin = '${uri.scheme}://${uri.host}';
    final low = link.toLowerCase();
    final page = await _transport.get(
      uri,
      headers: {'Referer': low.contains('yonaplay') ? _origin.origin : 'https://yonaplay.org/'},
      operation: 'host_yonaplay',
    );
    if (!page.isSuccess) return const <StreamResult>[];

    // Multi-player mirrors (yonaplay / /mirror pages)
    final multiMatches = RegExp(r"go_to_player\('([^']*)'\)").allMatches(page.body);
    if (multiMatches.isNotEmpty) {
      final out = <StreamResult>[];
      for (final match in multiMatches) {
        var target = match.group(1)?.trim() ?? '';
        if (target.isEmpty) continue;
        if (target.startsWith('//')) target = 'https:$target';
        try {
          out.addAll(
            await resolveHostedLink(episodeUrl, target, entry, depth: depth + 1),
          );
        } catch (_) {}
      }
      if (out.isNotEmpty) return out;
    }

    // Encrypted Yonaplay API flow (window._E={a:"/api"})
    if (low.contains('yonaplay')) {
      final apiPath =
          RegExp(r'''window\._E\s*=\s*\{\s*a\s*:\s*["']([^"']+)["']''')
              .firstMatch(page.body)
              ?.group(1) ??
          '/api';
      final apiBase = '$origin$apiPath';
      final cookie = _extractCookieHeader(page);
      Map<String, String> apiHeaders() => {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'Referer': link,
        'Origin': origin,
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
          final token = _pickYonaplayServerToken(srcJson?['qualities'], entry.tier);
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
                return resolveHostedLink(
                  episodeUrl,
                  plain.trim(),
                  entry,
                  depth: depth + 1,
                );
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
        r'''["']file["']\s*:\s*["']([^"']+)["'](?:[^}]*["']label["']\s*:\s*["']([^"']*)["'])?''',
      ).allMatches(sourcesMatch.group(1)!)) {
        final url = m.group(1)!.replaceAll(r'\/', '/').trim();
        final label = m.group(2)?.trim();
        if (looksLikeStreamUrl(url)) {
          out.add(
            StreamResult(
              url: url,
              source: displaySourceName(entry.label, version: entry.version),
              quality: (label != null && label.isNotEmpty)
                  ? label
                  : qualityLabelForTier(entry.tier),
              headers: {'Referer': link},
            ),
          );
        }
      }
      if (out.isNotEmpty) return out;
    }

    return _resolveGeneric(episodeUrl, link, entry);
  }

  String? _pickYonaplayServerToken(Object? qualities, String preferredTier) {
    if (qualities is! List) return null;
    const rankMap = <String, int>{'fhd': 1, 'hd': 2, 'sd': 3};
    final prefer = preferredTier.trim().toLowerCase();
    String? bestToken;
    var bestRank = 99;
    for (final tier in qualities) {
      if (tier is! Map) continue;
      final name = (tier['name']?.toString() ?? '').trim().toLowerCase();
      var rank = rankMap[name] ?? 4;
      if (name == prefer) rank = 0;
      final servers = tier['servers'];
      if (servers is! List || servers.isEmpty) continue;
      final first = servers.first;
      final token = first is Map ? first['token']?.toString().trim() : null;
      if (token != null && token.isNotEmpty && rank < bestRank) {
        bestToken = token;
        bestRank = rank;
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

  Future<List<StreamResult>> _resolveDropbox(
    String episodeUrl,
    String link,
    WitanimeSourceToken entry,
  ) async {
    var current = link;
    for (var i = 0; i < 5; i++) {
      final resp = await _transport.get(
        Uri.parse(current),
        headers: {'Referer': episodeUrl},
        followRedirects: false,
        operation: 'host_dropbox',
      );
      if (resp.statusCode >= 400) return const <StreamResult>[];
      final loc = resp.header('location');
      if (loc == null || loc.trim().isEmpty) break;
      current = _absUrl(loc.trim(), Uri.parse(current));
    }
    return [
      StreamResult(
        url: current,
        source: displaySourceName(entry.label, version: entry.version),
        quality: qualityLabelForTier(entry.tier),
      ),
    ];
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
    final origin = '${uri.scheme}://${uri.host}';
    final page = await _transport.get(
      uri,
      headers: {'Referer': episodeUrl},
      operation: 'host_dood',
    );
    if (!page.isSuccess) return const <StreamResult>[];
    final md5Path = RegExp(
      r'''(/pass_md5/[^"']+)''',
    ).firstMatch(page.body)?.group(1);
    if (md5Path == null) return const <StreamResult>[];
    final token = md5Path.split('/').lastWhere((p) => p.isNotEmpty, orElse: () => '');
    final md5Resp = await _transport.get(
      Uri.parse('$origin$md5Path'),
      headers: {'Referer': link},
      operation: 'host_dood_md5',
    );
    if (!md5Resp.isSuccess || md5Resp.body.trim().isEmpty) {
      return const <StreamResult>[];
    }
    const alpha = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    final randomTail = List<String>.generate(
      10,
      (_) => alpha[_random.nextInt(alpha.length)],
    ).join();
    final expiry = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final direct = '${md5Resp.body.trim()}$randomTail?token=$token&expiry=$expiry';
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
  }) async {
    final body = preloadedBody ??
        (await _transport.get(
          Uri.parse(link),
          headers: {'Referer': episodeUrl},
          operation: 'host_generic',
        )).body;
    final unpacked = unpackPackedJs(body);
    final combined = unpacked.isNotEmpty ? '$unpacked\n$body' : body;
    final source = displaySourceName(entry.label, version: entry.version);
    final quality = qualityLabelForTier(entry.tier);
    final seen = <String>{};
    final out = <StreamResult>[];
    for (final m in RegExp(
      r'''https?://[^"'\s<>\\]+(?:\.m3u8|\.mp4)[^"'\s<>\\]*''',
    ).allMatches(combined)) {
      final candidate = prepareExtractedMediaUrl(m.group(0)!);
      if (looksLikeStreamUrl(candidate) && seen.add(candidate)) {
        out.add(
          StreamResult(
            url: candidate,
            source: source,
            quality: quality,
            headers: {'Referer': link},
          ),
        );
      }
    }
    return out;
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
