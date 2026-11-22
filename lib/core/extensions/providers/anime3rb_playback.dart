import 'dart:convert';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;
import 'package:html_unescape/html_unescape.dart';

import '../../domain/entity/multimedia_item.dart';
import '../../network/http_defaults.dart';
import '../../utils/digit_normalization.dart';
import 'anime3rb_transport.dart';

const String anime3rbSourceUrlPrefix = 'anime3rb-source://';

/// Optional hook that can solve Cloudflare Turnstile on a `video.vid3rb.com`
/// player page and return `{cfToken, cfTokenType}` or pre-resolved video JSON.
typedef Anime3rbTurnstileResolver =
    Future<({String token, String type})?> Function(Uri playerUri);

class Anime3rbSourceToken {
  const Anime3rbSourceToken({
    required this.kind,
    required this.watchUrl,
    required this.label,
    required this.quality,
    this.targetUrl,
    this.sourceId,
    this.isPremium = false,
  });

  final String kind; // 'stream' | 'download'
  final String watchUrl;
  final String label;
  final String quality;
  final String? targetUrl;
  final String? sourceId;
  final bool isPremium;

  bool get isDownload => kind == 'download';

  String encode() {
    final payload = jsonEncode(<String, Object?>{
      'k': kind,
      'w': watchUrl,
      'l': label,
      'q': quality,
      if (targetUrl != null && targetUrl!.isNotEmpty) 'u': targetUrl,
      if (sourceId != null && sourceId!.isNotEmpty) 's': sourceId,
      if (isPremium) 'p': true,
    });
    return '$anime3rbSourceUrlPrefix$kind/${base64Url.encode(utf8.encode(payload))}';
  }

  static Anime3rbSourceToken? tryDecode(String raw) {
    final trimmed = raw.trim();
    if (!trimmed.startsWith(anime3rbSourceUrlPrefix)) return null;
    final rest = trimmed.substring(anime3rbSourceUrlPrefix.length);
    final slash = rest.indexOf('/');
    if (slash <= 0 || slash >= rest.length - 1) return null;
    final encoded = rest.substring(slash + 1);
    try {
      final jsonMap = jsonDecode(utf8.decode(base64Url.decode(encoded)));
      if (jsonMap is! Map) return null;
      final kind = jsonMap['k']?.toString().trim() ?? '';
      final watchUrl = jsonMap['w']?.toString().trim() ?? '';
      final label = jsonMap['l']?.toString().trim() ?? 'Anime3rb';
      final quality = jsonMap['q']?.toString().trim() ?? 'HD';
      final targetUrl = jsonMap['u']?.toString().trim();
      final sourceId = jsonMap['s']?.toString().trim();
      final isPremium = jsonMap['p'] == true;
      if (!const {'stream', 'download'}.contains(kind) || watchUrl.isEmpty) {
        return null;
      }
      return Anime3rbSourceToken(
        kind: kind,
        watchUrl: watchUrl,
        label: label,
        quality: quality,
        targetUrl: targetUrl?.isEmpty == true ? null : targetUrl,
        sourceId: sourceId?.isEmpty == true ? null : sourceId,
        isPremium: isPremium,
      );
    } catch (_) {
      return null;
    }
  }
}

class _ParsedDownloadOption {
  const _ParsedDownloadOption({
    required this.url,
    required this.translationLabel,
    required this.qualityLabel,
    required this.isPremium,
  });

  final Uri url;
  final String translationLabel;
  final String qualityLabel;
  final bool isPremium;
}

class _ParsedEpisodePage {
  const _ParsedEpisodePage({
    required this.watchUri,
    required this.defaultPlayerUri,
    required this.activeSourceId,
    required this.watchSources,
    required this.downloadOptions,
    required this.csrfToken,
    required this.livewireUpdateUri,
    required this.livewireSnapshotRaw,
  });

  final Uri watchUri;
  final Uri? defaultPlayerUri;
  final String? activeSourceId;
  final List<({String id, String label})> watchSources;
  final List<_ParsedDownloadOption> downloadOptions;
  final String? csrfToken;
  final Uri? livewireUpdateUri;
  final String? livewireSnapshotRaw;
}

class Anime3rbPlaybackResolver {
  Anime3rbPlaybackResolver(
    this._transport, {
    Uri? origin,
    Anime3rbTurnstileResolver? turnstileResolver,
  }) : _origin = origin ?? Uri.https('anime3rb.com'),
       _turnstileResolver = turnstileResolver;

  final Anime3rbTransport _transport;
  final Uri _origin;
  final Anime3rbTurnstileResolver? _turnstileResolver;
  final HtmlUnescape _unescape = HtmlUnescape();
  final Map<Uri, ({_ParsedEpisodePage page, DateTime expiresAt})> _episodeCache =
      {};
  final Map<String, Future<List<StreamResult>>> _inFlight = {};

  static const _cacheTtl = Duration(minutes: 2);

  static final _vid3rbIframeRegex = RegExp(
    r'''https:(?:\\/|/){2}video\.vid3rb\.com(?:\\/|/)player(?:\\/|/)[^"'\s<>]+''',
    caseSensitive: false,
  );
  static final _inlineSourcesRegex = RegExp(
    r'var\s+video_sources\s*=\s*(\[[\s\S]*?\])\s*;',
    caseSensitive: false,
  );
  static final _turnstileSitekeyRegex = RegExp(
    r'''sitekey\s*:\s*["']([^"']+)["']''',
    caseSensitive: false,
  );
  static final _qualityRegex = RegExp(r'(2160p|1440p|1080p|720p|480p|360p)', caseSensitive: false);

  void clearCache() => _episodeCache.clear();

  static String _normalizeQualityLabel(String raw) {
    final normalized = normalizeLocalizedDigits(raw);
    final match = _qualityRegex.firstMatch(normalized);
    if (match != null) return match.group(1)!.toLowerCase();
    final digits = RegExp(r'\d{3,4}').firstMatch(normalized)?.group(0);
    if (digits != null) return '${digits}p';
    return 'HD';
  }

  static int _qualityRank(String label) {
    final match = RegExp(r'(\d{3,4})').firstMatch(label);
    return int.tryParse(match?.group(1) ?? '') ?? 0;
  }

  String _cleanUnescapedUrl(String raw) => _unescape
      .convert(raw.replaceAll(r'\/', '/').replaceAll('\\u0026', '&').trim())
      .replaceAll('\\', '');

  Future<_ParsedEpisodePage> _loadEpisodePage(Uri watchUri) async {
    final now = DateTime.now();
    final cached = _episodeCache[watchUri];
    if (cached != null && now.isBefore(cached.expiresAt)) {
      return cached.page;
    }

    final body = await _transport.fetchHtml(
      watchUri,
      headers: {'Referer': _origin.toString()},
      operation: 'episode_page',
    );
    final doc = html.parse(body);

    String? csrf = doc
        .querySelector('meta[name="csrf-token"]')
        ?.attributes['content']
        ?.trim();
    Uri? livewireUpdateUri;
    final lwScript = doc.querySelector('script[data-update-uri]');
    if (lwScript != null) {
      csrf ??= lwScript.attributes['data-csrf']?.trim();
      final rawUpdate = lwScript.attributes['data-update-uri']?.trim();
      if (rawUpdate != null && rawUpdate.isNotEmpty) {
        livewireUpdateUri = watchUri.resolve(rawUpdate);
      }
    }

    final showVideoEl = doc.querySelector('[wire\\:name="video.show-video"]');
    final snapshotRaw = showVideoEl?.attributes['wire:snapshot'];
    String? snapshotVideoUrl;
    String? activeSourceId;
    if (snapshotRaw != null && snapshotRaw.isNotEmpty) {
      try {
        final decoded = jsonDecode(_unescape.convert(snapshotRaw));
        if (decoded is Map && decoded['data'] is Map) {
          final data = decoded['data'] as Map;
          snapshotVideoUrl = data['video_url']?.toString().trim();
          activeSourceId = data['video_source']?.toString().trim();
        }
      } catch (_) {}
    }

    Uri? defaultPlayerUri;
    if (snapshotVideoUrl != null && snapshotVideoUrl.isNotEmpty) {
      defaultPlayerUri = Uri.tryParse(_cleanUnescapedUrl(snapshotVideoUrl));
    }
    if (defaultPlayerUri == null) {
      final rawMatch = _vid3rbIframeRegex.firstMatch(body)?.group(0);
      if (rawMatch != null) {
        defaultPlayerUri = Uri.tryParse(_cleanUnescapedUrl(rawMatch));
      }
    }

    final watchSources = <({String id, String label})>[];
    final seenSources = <String>{};
    for (final btn in doc.querySelectorAll('button[data-video-source]')) {
      final sourceId = btn.attributes['data-video-source']?.trim() ?? '';
      if (sourceId.isEmpty || !seenSources.add(sourceId)) continue;
      final label =
          btn.querySelector('span[title]')?.attributes['title']?.trim() ??
          btn.text.replaceAll(RegExp(r'\s+'), ' ').trim();
      watchSources.add((
        id: sourceId,
        label: label.isEmpty ? 'Anime3rb' : label,
      ));
    }

    final downloadOptions = <_ParsedDownloadOption>[];
    final seenDownloadUrls = <String>{};
    for (final group in doc.querySelectorAll('[wire\\:key^="download."]')) {
      final translationLabel =
          group
              .querySelector('h3 small, h3')
              ?.text
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim() ??
          '';
      for (final anchor in group.querySelectorAll('a[href*="/download/"]')) {
        final href = anchor.attributes['href']?.trim() ?? '';
        if (href.isEmpty) continue;
        final resolved = watchUri.resolve(_cleanUnescapedUrl(href));
        if (!resolved.queryParameters.containsKey('signature') ||
            !seenDownloadUrls.add(resolved.toString())) {
          continue;
        }
        final card = anchor.parent;
        final labelText =
            card
                ?.querySelector('label')
                ?.text
                .replaceAll(RegExp(r'\s+'), ' ')
                .trim() ??
            anchor.text.replaceAll(RegExp(r'\s+'), ' ').trim();
        final isPremium =
            labelText.toUpperCase().contains('HEVC') ||
            card?.parent?.querySelector('a[href*="/hevc"]') != null;
        downloadOptions.add(
          _ParsedDownloadOption(
            url: resolved,
            translationLabel: translationLabel,
            qualityLabel: _normalizeQualityLabel(labelText),
            isPremium: isPremium,
          ),
        );
      }
    }

    // Fallback scan when download cards lack wire:key wrapper.
    if (downloadOptions.isEmpty) {
      for (final anchor in doc.querySelectorAll('a[href*="/download/"]')) {
        final href = anchor.attributes['href']?.trim() ?? '';
        if (href.isEmpty) continue;
        final resolved = watchUri.resolve(_cleanUnescapedUrl(href));
        if (!resolved.queryParameters.containsKey('signature') ||
            !seenDownloadUrls.add(resolved.toString())) {
          continue;
        }
        final labelText =
            anchor.parent
                ?.querySelector('label')
                ?.text
                .replaceAll(RegExp(r'\s+'), ' ')
                .trim() ??
            anchor.text.replaceAll(RegExp(r'\s+'), ' ').trim();
        final isPremium = labelText.toUpperCase().contains('HEVC');
        downloadOptions.add(
          _ParsedDownloadOption(
            url: resolved,
            translationLabel: '',
            qualityLabel: _normalizeQualityLabel(labelText),
            isPremium: isPremium,
          ),
        );
      }
    }

    final parsed = _ParsedEpisodePage(
      watchUri: watchUri,
      defaultPlayerUri: defaultPlayerUri,
      activeSourceId: activeSourceId,
      watchSources: watchSources,
      downloadOptions: downloadOptions,
      csrfToken: csrf,
      livewireUpdateUri: livewireUpdateUri,
      livewireSnapshotRaw: snapshotRaw,
    );
    _episodeCache[watchUri] = (
      page: parsed,
      expiresAt: now.add(_cacheTtl),
    );
    return parsed;
  }

  Future<List<StreamResult>> loadSources(
    String episodeUrl, {
    required bool forDownload,
  }) async {
    final watchUri = Uri.tryParse(episodeUrl.trim());
    if (watchUri == null || !watchUri.hasScheme) {
      throw const Anime3rbSourceUnavailableException(
        'رابط الحلقة غير صالح على Anime3rb.',
      );
    }

    final page = await _loadEpisodePage(watchUri);
    final results = <StreamResult>[];

    final freeDownloads = page.downloadOptions
        .where((opt) => !opt.isPremium)
        .toList()
      ..sort(
        (a, b) =>
            _qualityRank(b.qualityLabel).compareTo(_qualityRank(a.qualityLabel)),
      );

    void addWatchSources() {
      if (page.watchSources.isNotEmpty) {
        for (final src in page.watchSources) {
          final isActive =
              page.activeSourceId == null || src.id == page.activeSourceId;
          final token = Anime3rbSourceToken(
            kind: 'stream',
            watchUrl: watchUri.toString(),
            label: 'Vid3rb (${src.label})',
            quality: 'HD',
            targetUrl: isActive ? page.defaultPlayerUri?.toString() : null,
            sourceId: src.id,
          );
          results.add(
            StreamResult(
              url: token.encode(),
              source: 'Vid3rb · ${src.label} [HD]',
              requiresResolution: true,
              refreshUrl: watchUri.toString(),
            ),
          );
        }
      } else if (page.defaultPlayerUri != null) {
        final token = Anime3rbSourceToken(
          kind: 'stream',
          watchUrl: watchUri.toString(),
          label: 'Vid3rb',
          quality: 'HD',
          targetUrl: page.defaultPlayerUri.toString(),
        );
        results.add(
          StreamResult(
            url: token.encode(),
            source: 'Vid3rb [HD]',
            requiresResolution: true,
            refreshUrl: watchUri.toString(),
          ),
        );
      }
    }

    void addDownloadSources() {
      for (final dl in freeDownloads) {
        final suffix = dl.translationLabel.isEmpty
            ? ''
            : ' · ${dl.translationLabel}';
        final token = Anime3rbSourceToken(
          kind: 'download',
          watchUrl: watchUri.toString(),
          label: 'تحميل مباشر$suffix',
          quality: dl.qualityLabel,
          targetUrl: dl.url.toString(),
        );
        results.add(
          StreamResult(
            url: token.encode(),
            source: 'Anime3rb مباشر$suffix [${dl.qualityLabel}]',
            requiresResolution: true,
            refreshUrl: watchUri.toString(),
          ),
        );
      }
    }

    if (forDownload) {
      addDownloadSources();
      addWatchSources();
    } else {
      addWatchSources();
      addDownloadSources();
    }

    if (results.isEmpty) {
      throw const Anime3rbSourceUnavailableException(
        'لم يتم العثور على سيرفرات مشاهدة أو تحميل لهذه الحلقة.',
      );
    }
    return results;
  }

  Future<List<StreamResult>> resolveStreams(
    String urlOrToken, {
    required bool forDownload,
  }) {
    final key = '${forDownload ? 'dl' : 'st'}:$urlOrToken';
    final existing = _inFlight[key];
    if (existing != null) return existing;

    final future = _resolveStreamsInternal(urlOrToken, forDownload: forDownload)
        .whenComplete(() {
          _inFlight.remove(key);
        });
    _inFlight[key] = future;
    return future;
  }

  Future<List<StreamResult>> _resolveStreamsInternal(
    String urlOrToken, {
    required bool forDownload,
  }) async {
    final token = Anime3rbSourceToken.tryDecode(urlOrToken);
    if (token == null) {
      // Called directly with an episode watch URL instead of a deferred token.
      final sources = await loadSources(urlOrToken, forDownload: forDownload);
      Object? lastError;
      for (final candidate in sources) {
        try {
          final resolved = await _resolveToken(
            Anime3rbSourceToken.tryDecode(candidate.url)!,
            forDownload: forDownload,
          );
          if (resolved.isNotEmpty) return resolved;
        } catch (error) {
          lastError = error;
          if (error is Anime3rbRateLimitException) rethrow;
        }
      }
      if (lastError != null) throw lastError;
      throw const Anime3rbSourceUnavailableException();
    }
    return _resolveToken(token, forDownload: forDownload);
  }

  Future<List<StreamResult>> _resolveToken(
    Anime3rbSourceToken token, {
    required bool forDownload,
  }) async {
    if (token.isDownload) {
      return _resolveDirectDownloadToken(token);
    }
    return _resolveVid3rbStreamToken(token, forDownload: forDownload);
  }

  Future<Uri?> _switchLivewireVideoSource(
    _ParsedEpisodePage page,
    String sourceId,
  ) async {
    final updateUri = page.livewireUpdateUri ?? _origin.replace(path: '/livewire/update');
    final csrf = page.csrfToken;
    final snapshot = page.livewireSnapshotRaw;
    if (csrf == null || csrf.isEmpty || snapshot == null || snapshot.isEmpty) {
      return page.defaultPlayerUri;
    }
    final resp = await _transport.post(
      updateUri,
      body: jsonEncode(<String, Object?>{
        '_token': csrf,
        'components': [
          <String, Object?>{
            'snapshot': _unescape.convert(snapshot),
            'updates': <String, Object?>{},
            'calls': [
              <String, Object?>{
                'path': '',
                'method': 'setVideoSource',
                'params': [sourceId],
              },
            ],
          },
        ],
      }),
      headers: {
        'Accept': '*/*',
        'Content-Type': 'application/json',
        'X-Livewire': '1',
        'Origin': _origin.origin,
        'Referer': page.watchUri.toString(),
      },
      operation: 'livewire_set_source',
    );
    if (resp.statusCode == 429) throw const Anime3rbRateLimitException();
    if (!resp.isSuccess) return null;
    try {
      final json = jsonDecode(resp.body);
      final components = json is Map ? json['components'] : null;
      if (components is List && components.isNotEmpty) {
        final first = components.first;
        if (first is Map && first['snapshot'] is String) {
          final snap = jsonDecode(first['snapshot'] as String);
          final videoUrl = snap is Map && snap['data'] is Map
              ? snap['data']['video_url']?.toString().trim()
              : null;
          if (videoUrl != null && videoUrl.isNotEmpty) {
            return Uri.tryParse(_cleanUnescapedUrl(videoUrl));
          }
        }
        final htmlFragment = first is Map && first['effects'] is Map
            ? first['effects']['html']?.toString() ?? ''
            : '';
        final match = _vid3rbIframeRegex.firstMatch(htmlFragment)?.group(0);
        if (match != null) {
          return Uri.tryParse(_cleanUnescapedUrl(match));
        }
      }
    } catch (_) {}
    return null;
  }

  Future<List<StreamResult>> _resolveVid3rbStreamToken(
    Anime3rbSourceToken token, {
    required bool forDownload,
  }) async {
    final watchUri = Uri.parse(token.watchUrl);
    final page = await _loadEpisodePage(watchUri);

    var playerUri = token.targetUrl != null
        ? Uri.tryParse(token.targetUrl!)
        : null;
    if (playerUri == null &&
        token.sourceId != null &&
        token.sourceId != page.activeSourceId) {
      playerUri = await _switchLivewireVideoSource(page, token.sourceId!);
    }
    playerUri ??= page.defaultPlayerUri;
    if (playerUri == null) {
      throw const Anime3rbSourceUnavailableException(
        'تعذّر العثور على رابط مشغّل Vid3rb لهذه الحلقة.',
      );
    }

    final playerResp = await _transport.get(
      playerUri,
      headers: {
        'Accept':
            'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Referer': '${_origin.origin}/',
      },
      operation: 'host_vid3rb_player',
    );
    if (playerResp.statusCode == 429) throw const Anime3rbRateLimitException();
    if (playerResp.isCloudflareChallenge) {
      throw Anime3rbBrowserRequiredException(
        'يتطلب مشغّل Vid3rb إكمال تحقق Cloudflare.',
        watchUrl: watchUri,
      );
    }
    if (!playerResp.isSuccess) {
      throw const Anime3rbSourceUnavailableException();
    }

    // 1. Check inline `var video_sources = [...];` if populated.
    final inlineMatch = _inlineSourcesRegex.firstMatch(playerResp.body);
    if (inlineMatch != null) {
      final parsedInline = _parseVideoSourcesJson(
        inlineMatch.group(1)!,
        playerUri,
        token.label,
        watchUri,
      );
      if (parsedInline.isNotEmpty) return parsedInline;
    }

    // 2. Modern Vid3rb flow: `/player/{uuid}/sources?...&cf_token=...`.
    final pathSegments = playerUri.pathSegments
        .where((s) => s.isNotEmpty)
        .toList();
    final playerIdx = pathSegments.indexOf('player');
    if (playerIdx >= 0 && playerIdx + 1 < pathSegments.length) {
      final uuid = pathSegments[playerIdx + 1];
      String? cfToken;
      String? cfTokenType;
      if (_turnstileResolver != null) {
        final solved = await _turnstileResolver(playerUri);
        cfToken = solved?.token;
        cfTokenType = solved?.type;
      }

      final sourcesUri = playerUri.replace(
        path: '/player/$uuid/sources',
        queryParameters: {
          ...playerUri.queryParameters,
          if (cfToken != null && cfToken.isNotEmpty) 'cf_token': cfToken,
          if (cfTokenType != null && cfTokenType.isNotEmpty)
            'cf_token_type': cfTokenType,
        },
      );

      final sourcesResp = await _transport.get(
        sourcesUri,
        headers: {
          'Accept': 'application/json',
          'X-Requested-With': 'XMLHttpRequest',
          'Referer': playerUri.toString(),
        },
        operation: 'host_vid3rb_sources',
      );
      if (sourcesResp.statusCode == 429) throw const Anime3rbRateLimitException();
      if (sourcesResp.isSuccess) {
        final parsedApi = _parseVideoSourcesJson(
          sourcesResp.body,
          playerUri,
          token.label,
          watchUri,
        );
        if (parsedApi.isNotEmpty) return parsedApi;
      }
    }

    // 3. Fallback to free direct download links if Vid3rb requires Turnstile.
    if (!forDownload) {
      for (final dl in page.downloadOptions.where((d) => !d.isPremium)) {
        try {
          final resolved = await _resolveDirectDownloadToken(
            Anime3rbSourceToken(
              kind: 'download',
              watchUrl: watchUri.toString(),
              label: token.label,
              quality: dl.qualityLabel,
              targetUrl: dl.url.toString(),
            ),
          );
          if (resolved.isNotEmpty) return resolved;
        } catch (_) {}
      }
    }

    if (_turnstileSitekeyRegex.hasMatch(playerResp.body) ||
        playerResp.body.contains('challenges.cloudflare.com/turnstile')) {
      throw Anime3rbBrowserRequiredException(
        'يتطلب مشغّل Vid3rb إكمال تحقق Turnstile في المتصفح.',
        watchUrl: watchUri,
      );
    }

    throw const Anime3rbSourceUnavailableException();
  }

  List<StreamResult> _parseVideoSourcesJson(
    String rawJson,
    Uri playerUri,
    String sourceLabel,
    Uri watchUri,
  ) {
    try {
      final decoded = jsonDecode(rawJson);
      final List<Object?> entries;
      if (decoded is List<Object?>) {
        entries = decoded;
      } else if (decoded is Map && decoded['sources'] is List<Object?>) {
        entries = decoded['sources'] as List<Object?>;
      } else if (decoded is Map && decoded['data'] is List<Object?>) {
        entries = decoded['data'] as List<Object?>;
      } else {
        return const [];
      }

      final parsed = <({int rank, StreamResult stream})>[];
      final headers = <String, String>{
        'Referer': '${playerUri.scheme}://${playerUri.host}/',
        'User-Agent': kDefaultBrowserUserAgent,
      };
      for (final entry in entries) {
        if (entry is! Map) continue;
        final isPremium =
            entry['premium'] == true ||
            entry['premium']?.toString().toLowerCase() == 'true';
        if (isPremium) continue;
        final rawSrc = entry['src']?.toString() ?? entry['file']?.toString();
        if (rawSrc == null || rawSrc.trim().isEmpty) continue;
        final cleanedSrc = _cleanUnescapedUrl(rawSrc);
        final uri = Uri.tryParse(cleanedSrc);
        if (uri == null || !uri.hasScheme) continue;
        final rawLabel =
            entry['label']?.toString() ?? entry['res']?.toString() ?? 'HD';
        final quality = _normalizeQualityLabel(rawLabel);
        parsed.add((
          rank: _qualityRank(quality),
          stream: StreamResult(
            url: uri.toString(),
            source: '$sourceLabel [$quality]',
            headers: headers,
            refreshUrl: watchUri.toString(),
          ),
        ));
      }
      parsed.sort((a, b) => b.rank.compareTo(a.rank));
      return parsed.map((e) => e.stream).toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  Future<List<StreamResult>> _resolveDirectDownloadToken(
    Anime3rbSourceToken token,
  ) async {
    final hop1Uri = token.targetUrl != null
        ? Uri.tryParse(token.targetUrl!)
        : null;
    if (hop1Uri == null) {
      throw const Anime3rbSourceUnavailableException();
    }

    final headers = <String, String>{
      'Accept':
          'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      'Referer': token.watchUrl,
      'User-Agent': kDefaultBrowserUserAgent,
    };

    final hop1 = await _transport.get(
      hop1Uri,
      headers: headers,
      followRedirects: false,
      inspectMedia: true,
      operation: 'host_anime3rb_dl_hop1',
    );
    if (hop1.statusCode == 429) throw const Anime3rbRateLimitException();
    if (hop1.isCloudflareChallenge) {
      throw Anime3rbBrowserRequiredException(
        'يتطلب التحميل المباشر من Anime3rb إكمال تحقق Cloudflare في المتصفح.',
        watchUrl: Uri.tryParse(token.watchUrl),
      );
    }

    final hop1Location = hop1.header('location');
    if (hop1.statusCode >= 300 &&
        hop1.statusCode < 400 &&
        hop1Location != null &&
        hop1Location.trim().isNotEmpty) {
      final mediaUri = hop1Uri.resolve(hop1Location.trim());
      return [
        StreamResult(
          url: mediaUri.toString(),
          source: '${token.label} [${token.quality}]',
          headers: {
            'Referer': '${_origin.origin}/',
            'User-Agent': kDefaultBrowserUserAgent,
          },
          refreshUrl: token.watchUrl,
        ),
      ];
    }
    if (hop1.hasMediaContent) {
      return [
        StreamResult(
          url: (hop1.finalUri ?? hop1Uri).toString(),
          source: '${token.label} [${token.quality}]',
          headers: {
            'Referer': '${_origin.origin}/',
            'User-Agent': kDefaultBrowserUserAgent,
          },
          refreshUrl: token.watchUrl,
        ),
      ];
    }
    if (!hop1.isSuccess) {
      throw const Anime3rbSourceUnavailableException();
    }

    final doc = html.parse(hop1.body);
    final hop2Anchor = doc
        .querySelectorAll('a[href*="/download/"]')
        .firstWhere(
          (a) => (a.attributes['href'] ?? '').contains('signature='),
          orElse: () => Element.tag('a'),
        );
    final hop2Href = hop2Anchor.attributes['href']?.trim() ?? '';
    if (hop2Href.isEmpty) {
      if (hop1.body.contains('اشتراك') || hop1.body.contains('premium')) {
        throw const Anime3rbSourceUnavailableException(
          'هذه الجودة مخصصة للاشتراك المميز على Anime3rb، اختر جودة أخرى.',
        );
      }
      throw const Anime3rbSourceUnavailableException();
    }

    final hop2Uri = hop1Uri.resolve(_cleanUnescapedUrl(hop2Href));
    final hop2 = await _transport.get(
      hop2Uri,
      headers: {
        ...headers,
        'Referer': hop1Uri.toString(),
      },
      followRedirects: false,
      inspectMedia: true,
      operation: 'host_anime3rb_dl_hop2',
    );
    if (hop2.statusCode == 429) throw const Anime3rbRateLimitException();
    if (hop2.isCloudflareChallenge) {
      throw Anime3rbBrowserRequiredException(
        'يتطلب التحميل المباشر من Anime3rb إكمال تحقق Cloudflare في المتصفح.',
        watchUrl: Uri.tryParse(token.watchUrl),
      );
    }

    final location = hop2.header('location');
    if (hop2.statusCode >= 300 &&
        hop2.statusCode < 400 &&
        location != null &&
        location.trim().isNotEmpty) {
      final finalMediaUri = hop2Uri.resolve(location.trim());
      return [
        StreamResult(
          url: finalMediaUri.toString(),
          source: '${token.label} [${token.quality}]',
          headers: {
            'Referer': '${_origin.origin}/',
            'User-Agent': kDefaultBrowserUserAgent,
          },
          refreshUrl: token.watchUrl,
        ),
      ];
    }
    if (hop2.hasMediaContent) {
      return [
        StreamResult(
          url: (hop2.finalUri ?? hop2Uri).toString(),
          source: '${token.label} [${token.quality}]',
          headers: {
            'Referer': '${_origin.origin}/',
            'User-Agent': kDefaultBrowserUserAgent,
          },
          refreshUrl: token.watchUrl,
        ),
      ];
    }

    throw const Anime3rbSourceUnavailableException();
  }
}
