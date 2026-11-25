import 'dart:convert';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;
import 'package:html_unescape/html_unescape.dart';

import '../../domain/entity/multimedia_item.dart';
import '../../network/http_defaults.dart';
import '../../utils/digit_normalization.dart';
import 'anime3rb_transport.dart';

const String anime3rbSourceUrlPrefix = 'anime3rb-source://';

/// Result returned by [Anime3rbTurnstileResolver] after running a
/// `video.vid3rb.com` player page inside WebView.
class Anime3rbTurnstileResult {
  const Anime3rbTurnstileResult({
    this.token,
    this.type,
    this.sourcesJson,
    this.cookies = const <String, String>{},
  });

  final String? token;
  final String? type;
  final String? sourcesJson;
  final Map<String, String> cookies;
}

/// Optional hook that can solve Cloudflare Turnstile on a `video.vid3rb.com`
/// player page and return `{cfToken, cfTokenType}` or pre-resolved video JSON.
typedef Anime3rbTurnstileResolver =
    Future<Anime3rbTurnstileResult?> Function(Uri playerUri);

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
    this.sizeLabel,
  });

  final Uri url;
  final String translationLabel;
  final String qualityLabel;
  final bool isPremium;
  final String? sizeLabel;
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
  final Map<String, ({List<StreamResult> streams, DateTime expiresAt})>
  _playerStreamsCache = {};
  final Map<String, Future<List<StreamResult>>> _inFlight = {};

  static const _cacheTtl = Duration(minutes: 2);

  static final _vid3rbIframeRegex = RegExp(
    r'''https:(?:\\/|/){2}video\.vid3rb\.com(?:\\/|/)player(?:\\/|/)(?:(?!&quot;)[^"'\s<>])+''',
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

  String get _activeUserAgent => _transport is DioAnime3rbTransport
      ? _transport.effectiveUserAgent
      : kDefaultBrowserUserAgent;

  void clearCache() {
    _episodeCache.clear();
    _playerStreamsCache.clear();
  }

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
      final iframeSrc = doc
          .querySelector('iframe[src*="video.vid3rb.com/player/"]')
          ?.attributes['src']
          ?.trim();
      if (iframeSrc != null && iframeSrc.isNotEmpty) {
        defaultPlayerUri = Uri.tryParse(_cleanUnescapedUrl(iframeSrc));
      }
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

    void collectDownloadAnchor(Element anchor, String translationLabel) {
      final href = anchor.attributes['href']?.trim() ?? '';
      if (href.isEmpty) return;
      final resolved = watchUri.resolve(_cleanUnescapedUrl(href));
      if (!resolved.queryParameters.containsKey('signature') ||
          !seenDownloadUrls.add(resolved.toString())) {
        return;
      }
      final card = anchor.parent;
      final wrapper = card?.parent;
      final wrapperContainsOnlyThisDownload =
          wrapper != null &&
          wrapper.querySelectorAll('a[href*="/download/"]').length == 1;
      final labelText =
          card
              ?.querySelector('label')
              ?.text
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim() ??
          anchor.text.replaceAll(RegExp(r'\s+'), ' ').trim();
      final anchorText = anchor.text.replaceAll(RegExp(r'\s+'), ' ').trim();
      final sizeMatch = RegExp(r'\[([^\]]+)\]').firstMatch(anchorText);
      final sizeLabel = sizeMatch?.group(1)?.trim();
      final isPremium =
          labelText.toUpperCase().contains('HEVC') ||
          card?.querySelector('a[href*="/hevc"], a[href*="/premium"]') !=
              null ||
          (wrapperContainsOnlyThisDownload &&
              wrapper.querySelector('a[href*="/hevc"], a[href*="/premium"]') !=
                  null);
      downloadOptions.add(
        _ParsedDownloadOption(
          url: resolved,
          translationLabel: translationLabel,
          qualityLabel: _normalizeQualityLabel(labelText),
          isPremium: isPremium,
          sizeLabel: (sizeLabel != null && sizeLabel.isNotEmpty)
              ? sizeLabel
              : null,
        ),
      );
    }

    for (final group in doc.querySelectorAll('[wire\\:key^="download."]')) {
      final translationLabel =
          group
              .querySelector('h3 small, h3')
              ?.text
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim() ??
          '';
      for (final anchor in group.querySelectorAll('a[href*="/download/"]')) {
        collectDownloadAnchor(anchor, translationLabel);
      }
    }

    // Fallback scan when download cards lack wire:key wrapper.
    if (downloadOptions.isEmpty) {
      for (final anchor in doc.querySelectorAll('a[href*="/download/"]')) {
        collectDownloadAnchor(anchor, '');
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

    final activeWatchSource = page.watchSources.isEmpty
        ? null
        : page.watchSources.firstWhere(
            (s) => page.activeSourceId == null || s.id == page.activeSourceId,
            orElse: () => page.watchSources.first,
          );
    final primaryLabel = activeWatchSource != null
        ? 'Vid3rb · ${activeWatchSource.label}'
        : 'Vid3rb';

    // Extract watch and download qualities directly from the Vid3rb player
    // (same flow as Abodabodd/re-3arabi Anim3rb, plus Turnstile /sources).
    if (page.defaultPlayerUri != null) {
      final extracted = await _extractPlayerStreams(
        page.defaultPlayerUri!,
        primaryLabel,
        watchUri,
      );
      results.addAll(extracted);

      // Expose any additional translation sources as deferred Vid3rb tokens so
      // the user can switch translations on demand via Livewire setVideoSource.
      for (final src in page.watchSources) {
        if (activeWatchSource != null && src.id == activeWatchSource.id) {
          continue;
        }
        final token = Anime3rbSourceToken(
          kind: 'stream',
          watchUrl: watchUri.toString(),
          label: 'Vid3rb · ${src.label}',
          quality: 'HD',
          sourceId: src.id,
        );
        results.add(
          StreamResult(
            url: token.encode(),
            source: 'Vid3rb · ${src.label}',
            quality: 'HD',
            requiresResolution: true,
            refreshUrl: watchUri.toString(),
          ),
        );
      }
    }

    // Fallback to free direct download links only when no Vid3rb player URL
    // was present on the episode page.
    if (results.isEmpty) {
      final freeDownloads = page.downloadOptions
          .where((opt) => !opt.isPremium)
          .toList()
        ..sort(
          (a, b) => _qualityRank(b.qualityLabel).compareTo(
            _qualityRank(a.qualityLabel),
          ),
        );
      for (final dl in freeDownloads) {
        final hasTranslation = dl.translationLabel.isNotEmpty;
        final tokenLabel = hasTranslation
            ? '${dl.translationLabel} · تحميل مباشر'
            : 'Anime3rb تحميل مباشر';
        final sizePart = dl.sizeLabel != null ? ' · ${dl.sizeLabel}' : '';
        final displaySource = hasTranslation
            ? '${dl.translationLabel} · تحميل مباشر$sizePart'
            : 'تحميل مباشر$sizePart';
        final token = Anime3rbSourceToken(
          kind: 'download',
          watchUrl: watchUri.toString(),
          label: tokenLabel,
          quality: dl.qualityLabel,
          targetUrl: dl.url.toString(),
        );
        results.add(
          StreamResult(
            url: token.encode(),
            source: displaySource,
            quality: dl.qualityLabel,
            requiresResolution: true,
            refreshUrl: watchUri.toString(),
          ),
        );
      }
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
      final direct = sources
          .where((candidate) => !candidate.requiresResolution)
          .toList(growable: false);
      if (direct.isNotEmpty) return direct;
      Object? lastError;
      for (final candidate in sources) {
        final decoded = Anime3rbSourceToken.tryDecode(candidate.url);
        if (decoded == null) return [candidate];
        try {
          final resolved = await _resolveToken(
            decoded,
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

    return _extractPlayerStreams(playerUri, token.label, watchUri);
  }

  Future<List<StreamResult>> _extractPlayerStreams(
    Uri playerUri,
    String sourceLabel,
    Uri watchUri,
  ) async {
    final cacheKey = '${playerUri.toString()}|$sourceLabel';
    final now = DateTime.now();
    final cached = _playerStreamsCache[cacheKey];
    if (cached != null && now.isBefore(cached.expiresAt)) {
      return cached.streams;
    }

    final playerResp = await _transport.get(
      playerUri,
      headers: {
        'Accept':
            'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Referer': '${_origin.origin}/',
        'Sec-Fetch-Dest': 'iframe',
        'Sec-Fetch-Site': 'cross-site',
        'Sec-Fetch-Mode': 'navigate',
      },
      operation: 'host_vid3rb_player',
    );
    if (playerResp.statusCode == 429) throw const Anime3rbRateLimitException();
    if (playerResp.isCloudflareChallenge && _turnstileResolver == null) {
      throw Anime3rbBrowserRequiredException(
        'يتطلب مشغّل Vid3rb إكمال تحقق Cloudflare.',
        watchUrl: watchUri,
      );
    }
    if (!playerResp.isSuccess && _turnstileResolver == null) {
      throw const Anime3rbSourceUnavailableException();
    }

    // 1. Check all inline `var video_sources = [...];` blocks (re-3arabi Anim3rb style).
    if (playerResp.isSuccess) {
      for (final match in _inlineSourcesRegex.allMatches(playerResp.body)) {
        final parsedInline = _parseVideoSourcesJson(
          match.group(1)!,
          playerUri,
          sourceLabel,
          watchUri,
        );
        if (parsedInline.isNotEmpty) {
          _playerStreamsCache[cacheKey] = (
            streams: parsedInline,
            expiresAt: DateTime.now().add(_cacheTtl),
          );
          return parsedInline;
        }
      }
    }

    // 2. Modern Vid3rb flow: `/player/{uuid}/sources?...&cf_token=...` via Turnstile WebView.
    final pathSegments = playerUri.pathSegments
        .where((s) => s.isNotEmpty)
        .toList();
    final playerIdx = pathSegments.indexOf('player');
    if (playerIdx >= 0 && playerIdx + 1 < pathSegments.length) {
      final uuid = pathSegments[playerIdx + 1];
      String? cfToken;
      String? cfTokenType;
      String? preResolvedSourcesJson;
      Map<String, String> solverCookies = const <String, String>{};
      if (_turnstileResolver != null) {
        final solved = await _turnstileResolver(playerUri);
        cfToken = solved?.token;
        cfTokenType = solved?.type;
        preResolvedSourcesJson = solved?.sourcesJson;
        solverCookies = solved?.cookies ?? const <String, String>{};
        if (solverCookies.isNotEmpty && _transport is DioAnime3rbTransport) {
          _transport.absorbCookies(playerUri, solverCookies);
        }
      }

      if (preResolvedSourcesJson != null &&
          preResolvedSourcesJson.trim().isNotEmpty) {
        final parsedPre = _parseVideoSourcesJson(
          preResolvedSourcesJson,
          playerUri,
          sourceLabel,
          watchUri,
        );
        if (parsedPre.isNotEmpty) {
          _playerStreamsCache[cacheKey] = (
            streams: parsedPre,
            expiresAt: DateTime.now().add(_cacheTtl),
          );
          return parsedPre;
        }
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

      final cookieHeader = solverCookies.isNotEmpty
          ? solverCookies.entries
              .map((entry) => '${entry.key}=${entry.value}')
              .join('; ')
          : null;
      final sourcesResp = await _transport.get(
        sourcesUri,
        headers: {
          'Accept': 'application/json',
          'X-Requested-With': 'XMLHttpRequest',
          'Referer': playerUri.toString(),
          if (cookieHeader != null) 'Cookie': cookieHeader,
        },
        operation: 'host_vid3rb_sources',
      );
      if (sourcesResp.statusCode == 429) throw const Anime3rbRateLimitException();
      if (sourcesResp.isSuccess) {
        final parsedApi = _parseVideoSourcesJson(
          sourcesResp.body,
          playerUri,
          sourceLabel,
          watchUri,
        );
        if (parsedApi.isNotEmpty) {
          _playerStreamsCache[cacheKey] = (
            streams: parsedApi,
            expiresAt: DateTime.now().add(_cacheTtl),
          );
          return parsedApi;
        }
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
      } else if (decoded is Map &&
          decoded['data'] is Map &&
          (decoded['data'] as Map)['sources'] is List<Object?>) {
        entries = (decoded['data'] as Map)['sources'] as List<Object?>;
      } else if (decoded is Map && decoded['videos'] is List<Object?>) {
        entries = decoded['videos'] as List<Object?>;
      } else if (decoded is Map &&
          (decoded['src'] != null ||
              decoded['file'] != null ||
              decoded['url'] != null)) {
        entries = [decoded];
      } else {
        return const [];
      }

      final parsed = <({int rank, StreamResult stream})>[];
      final seenUrls = <String>{};
      final headers = <String, String>{
        'Referer': '${playerUri.scheme}://${playerUri.host}/',
        'User-Agent': _activeUserAgent,
      };
      for (final entry in entries) {
        if (entry is! Map) continue;
        final isPremium =
            entry['premium'] == true ||
            entry['premium']?.toString().toLowerCase() == 'true';
        if (isPremium) continue;
        final rawSrc =
            entry['src']?.toString() ??
            entry['file']?.toString() ??
            entry['url']?.toString();
        if (rawSrc == null || rawSrc.trim().isEmpty) continue;
        final cleanedSrc = _cleanUnescapedUrl(rawSrc);
        final uri = Uri.tryParse(cleanedSrc);
        if (uri == null || !uri.hasScheme) continue;
        if (!seenUrls.add(uri.toString())) continue;
        final rawLabel =
            entry['label']?.toString() ??
            entry['res']?.toString() ??
            entry['quality']?.toString() ??
            'HD';
        final quality = _normalizeQualityLabel(rawLabel);
        parsed.add((
          rank: _qualityRank(quality),
          stream: StreamResult(
            url: uri.toString(),
            source: sourceLabel,
            quality: quality,
            headers: headers,
            requiresResolution: false,
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

  bool _isIntermediateDownloadUri(Uri uri) {
    final host = uri.host.toLowerCase();
    final isAnime3rb =
        host == _origin.host || host.endsWith('.${_origin.host}');
    return isAnime3rb && uri.path.startsWith('/download/');
  }

  List<StreamResult> _buildDownloadStreamResult(
    Uri mediaUri,
    Anime3rbSourceToken token,
  ) => [
    StreamResult(
      url: mediaUri.toString(),
      source: '${token.label} [${token.quality}]',
      quality: token.quality,
      headers: {
        'Referer': '${_origin.origin}/',
        'User-Agent': kDefaultBrowserUserAgent,
      },
      refreshUrl: token.watchUrl,
    ),
  ];

  Uri? _extractNextDownloadHop(Document doc, Uri currentUri) {
    for (final anchor in doc.querySelectorAll('a[href*="/download/"]')) {
      final href = anchor.attributes['href']?.trim() ?? '';
      if (href.contains('signature=')) {
        return currentUri.resolve(_cleanUnescapedUrl(href));
      }
    }
    for (final anchor in doc.querySelectorAll('a[href]')) {
      final href = anchor.attributes['href']?.trim() ?? '';
      final lower = href.toLowerCase();
      if (lower.contains('vid3rb.com/') &&
          (lower.contains('.mp4') || lower.contains('/video/'))) {
        return currentUri.resolve(_cleanUnescapedUrl(href));
      }
    }
    final meta = doc.querySelector('meta[http-equiv="refresh" i]');
    final content = meta?.attributes['content'] ?? '';
    final refreshMatch = RegExp(
      r'url\s*=\s*([^\s;]+)',
      caseSensitive: false,
    ).firstMatch(content);
    final refreshUrl = refreshMatch?.group(1)?.trim();
    if (refreshUrl != null && refreshUrl.isNotEmpty) {
      return currentUri.resolve(_cleanUnescapedUrl(refreshUrl));
    }
    return null;
  }

  Future<List<StreamResult>> _resolveDirectDownloadToken(
    Anime3rbSourceToken token,
  ) async {
    Uri? currentUri = token.targetUrl != null
        ? Uri.tryParse(token.targetUrl!)
        : null;
    if (currentUri == null) {
      throw const Anime3rbSourceUnavailableException();
    }

    var referer = token.watchUrl;
    for (var hop = 0; hop < 4; hop++) {
      final resp = await _transport.get(
        currentUri!,
        headers: <String, String>{
          'Accept':
              'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          'Referer': referer,
        },
        followRedirects: false,
        inspectMedia: true,
        operation: hop == 0 ? 'host_anime3rb_dl_hop1' : 'host_anime3rb_dl_hop2',
      );
      if (resp.statusCode == 429) throw const Anime3rbRateLimitException();
      if (resp.isCloudflareChallenge) {
        throw Anime3rbBrowserRequiredException(
          'يتطلب التحميل المباشر من Anime3rb إكمال تحقق Cloudflare في المتصفح.',
          watchUrl: Uri.tryParse(token.watchUrl),
        );
      }

      final location = resp.header('location');
      if (resp.statusCode >= 300 &&
          resp.statusCode < 400 &&
          location != null &&
          location.trim().isNotEmpty) {
        final nextUri = currentUri.resolve(location.trim());
        if (_isIntermediateDownloadUri(nextUri) && nextUri != currentUri) {
          referer = currentUri.toString();
          currentUri = nextUri;
          continue;
        }
        return _buildDownloadStreamResult(nextUri, token);
      }
      if (resp.hasMediaContent) {
        return _buildDownloadStreamResult(resp.finalUri ?? currentUri, token);
      }
      if (!resp.isSuccess) {
        throw const Anime3rbSourceUnavailableException();
      }

      final doc = html.parse(resp.body);
      final nextUri = _extractNextDownloadHop(doc, currentUri);
      if (nextUri == null) {
        if (resp.body.contains('اشتراك') || resp.body.contains('premium')) {
          throw const Anime3rbSourceUnavailableException(
            'هذه الجودة مخصصة للاشتراك المميز على Anime3rb، اختر جودة أخرى.',
          );
        }
        throw const Anime3rbSourceUnavailableException();
      }
      if (!_isIntermediateDownloadUri(nextUri)) {
        return _buildDownloadStreamResult(nextUri, token);
      }
      if (nextUri == currentUri) break;
      referer = currentUri.toString();
      currentUri = nextUri;
    }

    throw const Anime3rbSourceUnavailableException();
  }
}
