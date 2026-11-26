import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:webview_cookie_manager_flutter/webview_cookie_manager.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import '../../../features/settings/presentation/widgets/anime3rb_auth_webview_screen.dart';
import '../../router/app_router.dart';
import '../../services/app_diagnostics.dart';
import 'anime3rb_playback.dart';
import 'anime3rb_transport.dart';

class _ParkedWebViewSession {
  _ParkedWebViewSession({
    required this.origin,
    required this.controller,
    required this.entry,
    required this.visible,
    required this.parked,
    required this.progress,
    required this.pendingFetches,
    required this.onDispose,
  });

  final String origin;
  final WebViewController controller;
  final OverlayEntry entry;
  final ValueNotifier<bool> visible;
  final ValueNotifier<bool> parked;
  final ValueNotifier<double> progress;
  final Map<String, Completer<Anime3rbHttpResponse?>> pendingFetches;
  final VoidCallback onDispose;
  Timer? idleTimer;
  bool _disposed = false;

  void touch() {
    if (_disposed) return;
    idleTimer?.cancel();
    idleTimer = Timer(const Duration(minutes: 15), dispose);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    idleTimer?.cancel();
    for (final completer in pendingFetches.values) {
      if (!completer.isCompleted) completer.complete(null);
    }
    pendingFetches.clear();
    try {
      entry.remove();
    } catch (_) {}
    visible.dispose();
    parked.dispose();
    progress.dispose();
    onDispose();
  }
}

/// Cross-platform (iOS WKWebView & Android WebView) solver for Anime3rb
/// Cloudflare challenges and Vid3rb Turnstile source resolution.
///
/// After clearing a Cloudflare challenge for `anime3rb.com`, keeps the cleared
/// WebView parked silently so same-origin `fetch()` calls can reuse the live
/// Apple CFNetwork / Android WebView TLS fingerprint and `cf_clearance` cookie
/// whenever Dart's `HttpClient` (Dio) is rejected due to TLS/JA4 binding.
class Anime3rbWebViewSolver {
  Anime3rbWebViewSolver._();

  static final Anime3rbWebViewSolver instance = Anime3rbWebViewSolver._();

  static bool get isSupported =>
      !kIsWeb && Anime3rbAuthWebViewScreen.isSupported;

  static const String _fetchBridgeChannelName = 'awAnime3rbFetch';
  static const Set<String> _cloudflareCookieNames = <String>{
    'cf_clearance',
    '__cf_bm',
    '_cfuvid',
    'cf_chl_2',
    'cf_chl_rc_m',
    'cf_chl_rc_ni',
  };
  static const Set<String> _forbiddenFetchHeaders = <String>{
    'cookie',
    'user-agent',
    'referer',
    'origin',
    'host',
    'content-length',
    'connection',
    'accept-encoding',
  };

  /// Creates a platform-configured [WebViewController] with iOS WebKit
  /// preferences needed for Cloudflare Turnstile iframes.
  static WebViewController createPlatformController() {
    late final PlatformWebViewControllerCreationParams params;
    if (WebViewPlatform.instance is WebKitWebViewPlatform) {
      params = WebKitWebViewControllerCreationParams(
        allowsInlineMediaPlayback: true,
        mediaTypesRequiringUserAction: const <PlaybackMediaTypes>{},
        javaScriptCanOpenWindowsAutomatically: true,
      );
    } else {
      params = const PlatformWebViewControllerCreationParams();
    }
    return WebViewController.fromPlatformCreationParams(params);
  }

  /// Applies platform-specific settings required for Cloudflare Turnstile
  /// iframes (Android third-party cookies, authentic Mobile Safari / Chrome
  /// User-Agent normalization without cross-OS spoofing).
  static Future<String?> configurePlatformWebView(
    WebViewController controller,
  ) async {
    try {
      final platformController = controller.platform;
      final platformCookieManager = WebViewCookieManager().platform;
      if (platformController is AndroidWebViewController &&
          platformCookieManager is AndroidWebViewCookieManager) {
        await platformCookieManager.setAcceptThirdPartyCookies(
          platformController,
          true,
        );
      }
    } catch (_) {}

    try {
      final nativeUa = await controller.getUserAgent();
      final normalized = normalizeAnime3rbWebViewUserAgent(nativeUa);
      if (normalized != null &&
          normalized.isNotEmpty &&
          normalized != nativeUa?.trim()) {
        await controller.setUserAgent(normalized);
      }
      return normalized ?? nativeUa?.trim();
    } catch (_) {
      return null;
    }
  }

  final WebviewCookieManager _cookieManager = WebviewCookieManager();
  Future<void> _queue = Future<void>.value();
  _ParkedWebViewSession? _parkedSession;
  int _fetchSeq = 0;

  void _recordWebViewDiagnostic(
    String action, {
    String? status,
    int? durationMs,
    String? reason,
    bool? result,
  }) {
    appDiagnostics.record('anime3rb.webview', <String, Object?>{
      'action': action,
      if (status != null && status.isNotEmpty) 'status': status,
      'durationMs': ?durationMs,
      if (reason != null && reason.isNotEmpty) 'reason': reason,
      'result': ?result,
    });
  }

  /// Releases any parked background WebView session (e.g. on explicit retry).
  void disposeParkedSession() {
    final session = _parkedSession;
    _parkedSession = null;
    session?.dispose();
  }

  Future<T?> _serialized<T>(Future<T?> Function() action) {
    final next = _queue.then<T?>((_) => action(), onError: (_) => action());
    _queue = next.then((_) {}, onError: (_) {});
    return next;
  }

  /// Executes a same-origin HTTP request through the already-cleared parked
  /// WebView using `window.fetch(..., { credentials: 'include' })` so requests
  /// inherit the real browser TLS/JA4 fingerprint, HTTP/2 stack, and `HttpOnly`
  /// `cf_clearance` cookies.
  Future<Anime3rbHttpResponse?> fetchViaWebView(
    Uri uri, {
    String method = 'GET',
    Map<String, String> headers = const <String, String>{},
    Object? body,
    bool followRedirects = true,
  }) async {
    final session = _parkedSession;
    if (session == null ||
        !followRedirects ||
        session.origin != uri.origin ||
        (body != null && body is! String)) {
      return null;
    }

    session.touch();
    final elapsed = Stopwatch()..start();
    final reqId = 'aw_${++_fetchSeq}';
    final completer = Completer<Anime3rbHttpResponse?>();
    session.pendingFetches[reqId] = completer;

    final safeHeaders = <String, String>{};
    for (final entry in headers.entries) {
      final lower = entry.key.trim().toLowerCase();
      if (lower.isEmpty ||
          _forbiddenFetchHeaders.contains(lower) ||
          lower.startsWith('sec-')) {
        continue;
      }
      safeHeaders[entry.key] = entry.value;
    }

    final payload = jsonEncode(<String, Object?>{
      'id': reqId,
      'url': uri.toString(),
      'method': method.toUpperCase(),
      'headers': safeHeaders,
      'body': body as String?,
    });

    try {
      await session.controller.runJavaScript('''
(function(req) {
  var opts = {
    method: req.method || 'GET',
    credentials: 'include',
    redirect: 'follow',
    headers: req.headers || {}
  };
  if (req.body !== null && req.body !== undefined && req.method !== 'GET' && req.method !== 'HEAD') {
    opts.body = req.body;
  }
  fetch(req.url, opts).then(function(resp) {
    var hdrs = {};
    try {
      resp.headers.forEach(function(v, k) {
        var key = String(k).toLowerCase();
        if (!hdrs[key]) hdrs[key] = [];
        hdrs[key].push(String(v));
      });
    } catch (_) {}
    return resp.text().then(function(txt) {
      $_fetchBridgeChannelName.postMessage(JSON.stringify({
        id: req.id,
        status: resp.status,
        url: resp.url || req.url,
        headers: hdrs,
        body: txt
      }));
    });
  }).catch(function(err) {
    $_fetchBridgeChannelName.postMessage(JSON.stringify({
      id: req.id,
      error: String(err && err.message ? err.message : err)
    }));
  });
})($payload);
''');
    } catch (_) {
      session.pendingFetches.remove(reqId);
      disposeParkedSession();
      _recordWebViewDiagnostic(
        'webview_fetch',
        status: 'failed',
        durationMs: elapsed.elapsedMilliseconds,
        reason: 'js_eval_error',
      );
      return null;
    }

    try {
      final response = await completer.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () => null,
      );
      session.pendingFetches.remove(reqId);
      if (response == null) {
        _recordWebViewDiagnostic(
          'webview_fetch',
          status: 'failed',
          durationMs: elapsed.elapsedMilliseconds,
          reason: 'timeout_or_error',
        );
        return null;
      }
      if (response.isCloudflareChallenge) {
        disposeParkedSession();
        _recordWebViewDiagnostic(
          'webview_fetch',
          status: 'cf_challenge',
          durationMs: elapsed.elapsedMilliseconds,
          reason: 'http_${response.statusCode}',
        );
        return response;
      }
      session.touch();
      _recordWebViewDiagnostic(
        'webview_fetch',
        status: response.isSuccess ? 'ok' : 'http_error',
        durationMs: elapsed.elapsedMilliseconds,
        reason: response.isSuccess ? null : 'http_${response.statusCode}',
      );
      return response;
    } catch (_) {
      session.pendingFetches.remove(reqId);
      return null;
    }
  }

  /// Resolves a Cloudflare challenge for [uri] and returns updated cookies,
  /// rendered HTML (if cleared), and the active WebView User-Agent.
  Future<Anime3rbChallengeSolution?> solveCloudflareChallenge(
    Uri uri, {
    Map<String, String> currentCookies = const <String, String>{},
  }) {
    if (!isSupported) return Future<Anime3rbChallengeSolution?>.value(null);
    return _serialized(() => _runCloudflareSession(uri));
  }

  /// Resolves Vid3rb Turnstile on [playerUri], returning either captured
  /// `/player/{uuid}/sources` JSON, `(token, type)`, or synced cookies.
  Future<Anime3rbTurnstileResult?> solveVid3rbTurnstile(Uri playerUri) {
    if (!isSupported) return Future<Anime3rbTurnstileResult?>.value(null);
    return _serialized(() => _runVid3rbTurnstileSession(playerUri));
  }

  Future<void> _clearCloudflareCookies(Uri uri) async {
    final targets = <String>{
      uri.origin,
      'https://anime3rb.com',
      'https://video.vid3rb.com',
    };
    final expiredCookies = <Cookie>[];
    final seen = <String>{};
    for (final target in targets) {
      try {
        final cookies = await _cookieManager.getCookies(target);
        for (final cookie in cookies) {
          final name = cookie.name.trim();
          if (!_cloudflareCookieNames.contains(name)) continue;
          final key = '$name|${cookie.domain ?? ''}|${cookie.path ?? '/'}';
          if (!seen.add(key)) continue;
          cookie.expires = DateTime.fromMillisecondsSinceEpoch(0);
          expiredCookies.add(cookie);
        }
      } catch (_) {}
    }
    if (expiredCookies.isEmpty) return;
    try {
      await _cookieManager.setCookies(expiredCookies);
    } catch (_) {}
  }

  Future<Anime3rbChallengeSolution?> _runCloudflareSession(Uri uri) async {
    // Discard any stale parked session for this origin before solving anew.
    if (_parkedSession?.origin == uri.origin) {
      disposeParkedSession();
    }

    final elapsed = Stopwatch()..start();
    var sawChallenge = false;
    DateTime? clearedWithoutCookieAt;
    final isAnime3rbSite =
        uri.host == 'anime3rb.com' || uri.host.endsWith('.anime3rb.com');

    final solution = await _withWebViewOverlay<Anime3rbChallengeSolution>(
      initialUri: uri,
      title: 'التحقق من Anime3rb',
      subtitle: 'أكمل التحقق الأمني للمتابعة في التصفح والتحميل.',
      invisibleGracePeriod: const Duration(milliseconds: 2200),
      totalTimeout: const Duration(seconds: 90),
      parkOnSuccess: isAnime3rbSite,
      onRefreshPressed: (controller) async {
        await _clearCloudflareCookies(uri);
        _recordWebViewDiagnostic('cf_refresh_clear', status: 'ok');
      },
      onProgressHook: (controller, progress, checkNow) async {
        if (progress >= 30 && progress < 100) {
          await checkNow();
        }
      },
      evaluateState: (controller, currentUrl, promoteVisible) async {
        final state = await _evalJson(
          controller,
          '''
(function() {
  var href = String(window.location && window.location.href ? window.location.href : '');
  var title = (document.title || '').toLowerCase();
  var text = document.body ? (document.body.textContent || '') : '';
  var textLower = text.toLowerCase();
  var cfEl = document.querySelector(
    '#challenge-form, #challenge-running, #challenge-stage, #challenge-body-text, #cf-please-wait, .cf-browser-verification, .ray-id, script[src*="/cdn-cgi/challenge-platform/"]'
  );
  var hasInteractive = !!document.querySelector(
    'iframe[src*="challenges.cloudflare.com"], input[name="cf-turnstile-response"], .cf-turnstile, #turnstile-wrapper'
  );
  var isCf = !!cfEl ||
    typeof window._cf_chl_opt !== 'undefined' ||
    href.indexOf('/cdn-cgi/challenge') !== -1 ||
    title.indexOf('just a moment') !== -1 ||
    title.indexOf('attention required') !== -1 ||
    title.indexOf('لحظة واحدة') !== -1 ||
    title.indexOf('security verification') !== -1 ||
    title.indexOf('التحقق الأمني') !== -1 ||
    textLower.indexOf('checking your browser') !== -1 ||
    textLower.indexOf('verify you are human') !== -1 ||
    textLower.indexOf('performing security verification') !== -1 ||
    textLower.indexOf('verifies you are not a bot') !== -1 ||
    textLower.indexOf('security service to protect against malicious bots') !== -1 ||
    textLower.indexOf('enable javascript and cookies') !== -1 ||
    textLower.indexOf('إجراء التحقق الأمني') !== -1 ||
    textLower.indexOf('يتحقق من أنك') !== -1 ||
    textLower.indexOf('تأكد من أنك إنسان') !== -1;
  var ready = document.readyState || '';
  var hasAppContent = !!document.querySelector(
    'meta[name="csrf-token"], #videos, .titles-list, .title-card, a[href*="/titles/"], a[href*="/episode/"], [wire\\\\:id], [wire\\\\:snapshot]'
  );
  var visibleLen = 0;
  if (!isCf && ready === 'complete' && document.body) {
    visibleLen = String(document.body.innerText || '').trim().length;
  }
  return JSON.stringify({
    isCf: isCf,
    hasInteractive: hasInteractive,
    hasAppContent: hasAppContent,
    ready: ready,
    visibleLen: visibleLen,
    ua: navigator.userAgent || '',
    href: href
  });
})()
''',
        );
        if (state == null) return null;
        final isCf = state['isCf'] == true;
        final hasAppContent = state['hasAppContent'] == true;
        final ready = state['ready']?.toString() ?? '';
        final visibleLen = (state['visibleLen'] as num?)?.toInt() ?? 0;
        final ua = state['ua']?.toString().trim();
        final href = state['href']?.toString().trim() ?? '';
        final effectiveUrl = href.isNotEmpty ? href : currentUrl;

        if (isCf) {
          sawChallenge = true;
          clearedWithoutCookieAt = null;
          // Reveal immediately whenever Cloudflare presents a challenge so
          // Turnstile initializes at full opacity=1.0 and interactive state.
          promoteVisible('cf_detected');
          return null;
        }
        if (ready != 'complete') return null;

        final effectiveUri = Uri.tryParse(effectiveUrl);
        if (effectiveUri == null ||
            effectiveUri.scheme == 'about' ||
            effectiveUri.host.isEmpty) {
          return null;
        }

        final cookies = await _collectCookies(controller, effectiveUrl);
        final hasClearance = cookies.containsKey('cf_clearance');
        if (isAnime3rbSite && !hasAppContent && !(hasClearance && visibleLen >= 80)) {
          return null;
        }
        if (!hasClearance) {
          if (visibleLen < 80) return null;
          if (sawChallenge) {
            // Give iOS WKHTTPCookieStore a brief window to flush the newly
            // issued HttpOnly cf_clearance cookie after the challenge redirect.
            clearedWithoutCookieAt ??= DateTime.now();
            if (DateTime.now().difference(clearedWithoutCookieAt!) <
                const Duration(milliseconds: 1500)) {
              return null;
            }
          }
        }
        final html = await _evalString(
          controller,
          'document.documentElement ? document.documentElement.outerHTML : ""',
        );
        _recordWebViewDiagnostic(
          'cf_solved',
          status: 'ok',
          durationMs: elapsed.elapsedMilliseconds,
          reason: sawChallenge ? 'after_challenge' : 'already_clear',
          result: hasClearance,
        );
        return (
          cookies: cookies,
          html: (html != null && html.trim().isNotEmpty) ? html : null,
          userAgent: (ua != null && ua.isNotEmpty) ? ua : null,
        );
      },
    );
    return solution;
  }

  Future<Anime3rbTurnstileResult?> _runVid3rbTurnstileSession(
    Uri playerUri,
  ) async {
    var hookInstalled = false;
    DateTime? tokenSeenAt;
    return _withWebViewOverlay<Anime3rbTurnstileResult>(
      initialUri: playerUri,
      requestHeaders: const <String, String>{
        'Referer': 'https://anime3rb.com/',
      },
      title: 'التحقق من مشغّل Vid3rb',
      subtitle: 'أكمل التحقق الأمني لتحميل سيرفرات المشاهدة والتحميل.',
      invisibleGracePeriod: const Duration(milliseconds: 5500),
      totalTimeout: const Duration(seconds: 90),
      onPageStartedHook: (controller) async {
        hookInstalled = false;
        await _installVid3rbHook(controller);
      },
      onPageFinishedHook: (controller) async {
        hookInstalled = false;
        await _installVid3rbHook(controller);
        hookInstalled = true;
      },
      onProgressHook: (controller, progress, _) async {
        if (progress >= 10) {
          await _installVid3rbHook(controller);
        }
      },
      evaluateState: (controller, currentUrl, promoteVisible) async {
        if (!hookInstalled) {
          await _installVid3rbHook(controller);
          hookInstalled = true;
        }
        final state = await _evalJson(
          controller,
          '''
(function() {
  var title = (document.title || '').toLowerCase();
  var text = document.body ? (document.body.textContent || '') : '';
  var textLower = text.toLowerCase();
  var cfChallenge = !!document.querySelector('#challenge-form, #challenge-running, #challenge-stage, #challenge-body-text, .cf-browser-verification, script[src*="/cdn-cgi/challenge-platform/"]') ||
    typeof window._cf_chl_opt !== 'undefined' ||
    title.indexOf('just a moment') !== -1 ||
    title.indexOf('attention required') !== -1 ||
    title.indexOf('security verification') !== -1 ||
    textLower.indexOf('checking your browser') !== -1 ||
    textLower.indexOf('verify you are human') !== -1 ||
    textLower.indexOf('performing security verification') !== -1 ||
    textLower.indexOf('verifies you are not a bot') !== -1;

  var managedWrap = document.querySelector('.captcha-wrapper');
  var managedVisible = false;
  if (managedWrap) {
    var st = window.getComputedStyle ? window.getComputedStyle(managedWrap) : null;
    if (st && st.display !== 'none' && st.visibility !== 'hidden' && st.opacity !== '0') {
      managedVisible = managedWrap.offsetWidth > 0 && managedWrap.offsetHeight > 0;
    }
  }

  var inlineSources = '';
  try {
    if (Array.isArray(window.video_sources) && window.video_sources.length > 0) {
      inlineSources = JSON.stringify(window.video_sources);
    }
  } catch (_) {}

  var vjsSources = '';
  if (!inlineSources) {
    try {
      var list = [];
      var seen = {};
      function addSrc(s) {
        if (!s || !s.src) return;
        var u = String(s.src).trim();
        if (u.indexOf('http') !== 0 || seen[u]) return;
        seen[u] = true;
        list.push({
          src: u,
          label: String(s.label || s.res || s.quality || 'HD'),
          res: s.res != null ? String(s.res) : '',
          premium: Boolean(s.premium)
        });
      }
      function collectFromPlayer(p) {
        if (!p) return;
        if (typeof p.getGroupedSrc === 'function') {
          var g = p.getGroupedSrc();
          var groups = (g && (g.label || g.res || g.type)) || null;
          if (groups && typeof groups === 'object') {
            var keys = Object.keys(groups);
            for (var gi = 0; gi < keys.length; gi++) {
              var arr = groups[keys[gi]];
              if (Array.isArray(arr)) {
                for (var ai = 0; ai < arr.length; ai++) addSrc(arr[ai]);
              }
            }
          }
        }
        if (!list.length && typeof p.currentSources === 'function') {
          var cs = p.currentSources();
          if (Array.isArray(cs)) {
            for (var ci = 0; ci < cs.length; ci++) addSrc(cs[ci]);
          }
        }
        if (!list.length && p.options_ && Array.isArray(p.options_.sources)) {
          for (var oi = 0; oi < p.options_.sources.length; oi++) addSrc(p.options_.sources[oi]);
        }
      }
      if (window.player) collectFromPlayer(window.player);
      if (!list.length && window.videojs && typeof window.videojs.getAllPlayers === 'function') {
        var players = window.videojs.getAllPlayers() || [];
        for (var i = 0; i < players.length; i++) collectFromPlayer(players[i]);
      }
      if (!list.length) {
        var els = document.querySelectorAll('video source[src], video[src]');
        for (var k = 0; k < els.length; k++) {
          var u = els[k].getAttribute('src') || els[k].currentSrc || '';
          if (u && u.indexOf('http') === 0) {
            addSrc({
              src: u,
              label: els[k].getAttribute('label') || els[k].getAttribute('size') || 'HD',
              premium: false
            });
          }
        }
      }
      if (list.length > 0) vjsSources = JSON.stringify(list);
    } catch (_) {}
  }

  var tokenInput = document.querySelector('input[name="cf-turnstile-response"]');
  var domToken = tokenInput && tokenInput.value ? String(tokenInput.value).trim() : '';

  var cap = window.__awVid3rbCapture || {};
  return JSON.stringify({
    cfChallenge: cfChallenge,
    managedVisible: managedVisible,
    sourcesJson: cap.sourcesJson || inlineSources || vjsSources || '',
    token: cap.token || domToken || '',
    tokenType: cap.tokenType || (domToken ? (managedVisible ? 'managed' : 'invisible') : ''),
    ua: navigator.userAgent || ''
  });
})()
''',
        );
        if (state == null) return null;

        if (state['cfChallenge'] == true || state['managedVisible'] == true) {
          promoteVisible('vid3rb_interactive');
        }

        final sourcesJson = state['sourcesJson']?.toString().trim() ?? '';
        final token = state['token']?.toString().trim() ?? '';
        final tokenType = state['tokenType']?.toString().trim() ?? '';
        if (sourcesJson.isEmpty) {
          if (token.isEmpty) return null;
          // Wait for the WebView's own /sources XHR to finish so we capture
          // the JSON directly instead of burning a single-use Turnstile token.
          tokenSeenAt ??= DateTime.now();
          if (DateTime.now().difference(tokenSeenAt!) <
              const Duration(seconds: 6)) {
            return null;
          }
        }

        final cookies = await _collectCookies(controller, currentUrl);
        return Anime3rbTurnstileResult(
          token: token.isEmpty ? null : token,
          type: tokenType.isEmpty ? 'invisible' : tokenType,
          sourcesJson: sourcesJson.isEmpty ? null : sourcesJson,
          cookies: cookies,
        );
      },
    );
  }

  Future<void> _installVid3rbHook(WebViewController controller) async {
    try {
      await controller.runJavaScript('''
(function() {
  if (window.__awVid3rbHooked) return;
  window.__awVid3rbHooked = true;
  var cap = window.__awVid3rbCapture = window.__awVid3rbCapture || {};

  function recordUrl(url) {
    try {
      var u = new URL(String(url), window.location.href);
      var tok = u.searchParams.get('cf_token');
      var typ = u.searchParams.get('cf_token_type');
      if (tok && !cap.token) cap.token = tok;
      if (typ && !cap.tokenType) cap.tokenType = typ;
    } catch (_) {}
  }

  function hasNonEmptySources(parsed) {
    if (Array.isArray(parsed)) return parsed.length > 0;
    if (!parsed || typeof parsed !== 'object') return false;
    if (Array.isArray(parsed.sources) && parsed.sources.length > 0) return true;
    if (Array.isArray(parsed.data) && parsed.data.length > 0) return true;
    if (parsed.data && Array.isArray(parsed.data.sources) && parsed.data.sources.length > 0) return true;
    if (Array.isArray(parsed.videos) && parsed.videos.length > 0) return true;
    return Boolean(parsed.src || parsed.file || parsed.url);
  }

  function maybeSaveSources(url, text) {
    if (!url || String(url).indexOf('/sources') === -1 || !text) return;
    try {
      var parsed = JSON.parse(text);
      if (hasNonEmptySources(parsed)) {
        cap.sourcesJson = text;
      }
    } catch (_) {}
  }

  if (typeof window.fetch === 'function') {
    var origFetch = window.fetch;
    window.fetch = function(input, init) {
      var reqUrl = (typeof input === 'string') ? input : (input && input.url ? input.url : '');
      recordUrl(reqUrl);
      return origFetch.apply(this, arguments).then(function(resp) {
        try {
          if (reqUrl.indexOf('/sources') !== -1 && resp && resp.clone) {
            resp.clone().text().then(function(t) { maybeSaveSources(reqUrl, t); }).catch(function() {});
          }
        } catch (_) {}
        return resp;
      });
    };
  }

  if (window.XMLHttpRequest && window.XMLHttpRequest.prototype) {
    var origOpen = window.XMLHttpRequest.prototype.open;
    var origSend = window.XMLHttpRequest.prototype.send;
    window.XMLHttpRequest.prototype.open = function(method, url) {
      this.__awUrl = url;
      recordUrl(url);
      return origOpen.apply(this, arguments);
    };
    window.XMLHttpRequest.prototype.send = function() {
      this.addEventListener('load', function() {
        try {
          if (this.status >= 200 && this.status < 300) {
            maybeSaveSources(this.__awUrl, this.responseText);
          }
        } catch (_) {}
      });
      return origSend.apply(this, arguments);
    };
  }
})();
''');
    } catch (_) {}
  }

  Future<T?> _withWebViewOverlay<T>({
    required Uri initialUri,
    Map<String, String> requestHeaders = const <String, String>{},
    required String title,
    required String subtitle,
    required Duration invisibleGracePeriod,
    required Duration totalTimeout,
    bool parkOnSuccess = false,
    Future<void> Function(WebViewController controller)? onRefreshPressed,
    required Future<T?> Function(
      WebViewController controller,
      String currentUrl,
      void Function(String reason) promoteVisible,
    )
    evaluateState,
    Future<void> Function(WebViewController controller)? onPageStartedHook,
    Future<void> Function(WebViewController controller)? onPageFinishedHook,
    Future<void> Function(
      WebViewController controller,
      int progress,
      Future<void> Function() checkNow,
    )?
    onProgressHook,
  }) async {
    final overlay = rootNavigatorKey.currentState?.overlay;
    if (overlay == null) return null;

    final completer = Completer<T?>();
    final visible = ValueNotifier<bool>(false);
    final parked = ValueNotifier<bool>(false);
    final progress = ValueNotifier<double>(0);
    final pendingFetches = <String, Completer<Anime3rbHttpResponse?>>{};
    var currentUrl = initialUri.toString();
    var busyEvaluating = false;
    Timer? pollTimer;
    Timer? revealTimer;
    Timer? overallTimer;
    OverlayEntry? entry;

    late final WebViewController controller;

    void finish(T? value, {String? endReason}) {
      if (completer.isCompleted) return;
      pollTimer?.cancel();
      revealTimer?.cancel();
      overallTimer?.cancel();

      if (value != null && parkOnSuccess && entry != null) {
        visible.value = false;
        parked.value = true;
        final session = _ParkedWebViewSession(
          origin: initialUri.origin,
          controller: controller,
          entry: entry,
          visible: visible,
          parked: parked,
          progress: progress,
          pendingFetches: pendingFetches,
          onDispose: () {
            if (_parkedSession?.controller == controller) {
              _parkedSession = null;
            }
          },
        );
        final previous = _parkedSession;
        _parkedSession = session;
        session.touch();
        previous?.dispose();
      } else {
        if (endReason != null) {
          _recordWebViewDiagnostic(endReason, status: 'cancelled');
        }
        try {
          entry?.remove();
        } catch (_) {}
        visible.dispose();
        parked.dispose();
        progress.dispose();
      }
      completer.complete(value);
    }

    void reveal(String reason) {
      if (!completer.isCompleted && !visible.value) {
        visible.value = true;
        _recordWebViewDiagnostic('cf_revealed', status: 'ok', reason: reason);
      }
    }

    Future<void> checkNow() async {
      if (completer.isCompleted || busyEvaluating) return;
      busyEvaluating = true;
      try {
        final result = await evaluateState(controller, currentUrl, reveal);
        if (result != null) {
          finish(result);
        }
      } catch (_) {
        // Keep polling until solved or timed out.
      } finally {
        busyEvaluating = false;
      }
    }

    controller = createPlatformController();
    await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    final activeUa = await configurePlatformWebView(controller);
    _recordWebViewDiagnostic(
      'cf_start',
      status: 'ok',
      reason: (activeUa != null && activeUa.contains('Safari/'))
          ? 'safari_ua'
          : 'native_ua',
    );
    if (parkOnSuccess) {
      try {
        await controller.addJavaScriptChannel(
          _fetchBridgeChannelName,
          onMessageReceived: (JavaScriptMessage message) {
            try {
              final decoded = jsonDecode(message.message);
              if (decoded is! Map) return;
              final id = decoded['id']?.toString();
              if (id == null) return;
              final pending = pendingFetches.remove(id);
              if (pending == null || pending.isCompleted) return;
              if (decoded['error'] != null) {
                pending.complete(null);
                return;
              }
              final status = (decoded['status'] as num?)?.toInt() ?? 0;
              final body = decoded['body']?.toString() ?? '';
              final url = decoded['url']?.toString();
              final rawHeaders = decoded['headers'];
              final headersMap = <String, List<String>>{};
              if (rawHeaders is Map) {
                for (final entry in rawHeaders.entries) {
                  final val = entry.value;
                  if (val is List) {
                    headersMap[entry.key.toString()] = val
                        .map((e) => e.toString())
                        .toList(growable: false);
                  } else if (val != null) {
                    headersMap[entry.key.toString()] = [val.toString()];
                  }
                }
              }
              pending.complete(
                Anime3rbHttpResponse(
                  statusCode: status,
                  body: body,
                  headers: headersMap,
                  finalUri: url != null ? Uri.tryParse(url) : null,
                ),
              );
            } catch (_) {}
          },
        );
      } catch (_) {}
    }
    await controller.setNavigationDelegate(
      NavigationDelegate(
        onProgress: (p) {
          if (!completer.isCompleted) {
            progress.value = p / 100.0;
            if (onProgressHook != null) {
              unawaited(onProgressHook(controller, p, checkNow));
            }
          }
        },
        onUrlChange: (change) {
          if (change.url != null && change.url!.isNotEmpty) {
            currentUrl = change.url!;
          }
        },
        onPageStarted: (url) {
          if (url.isNotEmpty) currentUrl = url;
          if (onPageStartedHook != null) {
            unawaited(onPageStartedHook(controller));
          }
        },
        onPageFinished: (url) {
          if (url.isNotEmpty) currentUrl = url;
          unawaited(() async {
            if (onPageFinishedHook != null) {
              await onPageFinishedHook(controller);
            }
            await checkNow();
          }());
        },
      ),
    );

    final webViewKey = GlobalKey();
    final webViewWidget = WebViewWidget(
      key: webViewKey,
      controller: controller,
    );

    entry = OverlayEntry(
      builder: (context) => ValueListenableBuilder<bool>(
        valueListenable: parked,
        builder: (context, isParked, child) {
          if (isParked) {
            return Positioned(
              left: 0,
              top: 0,
              width: 1,
              height: 1,
              child: IgnorePointer(child: Opacity(opacity: 0.01, child: child)),
            );
          }
          return ValueListenableBuilder<bool>(
            valueListenable: visible,
            builder: (context, isVisible, innerChild) {
              final size = MediaQuery.sizeOf(context);
              final maxWidth = (size.width - 32).clamp(280.0, 520.0);
              final maxHeight = (size.height * 0.72).clamp(360.0, 620.0);
              return Positioned.fill(
                child: IgnorePointer(
                  ignoring: !isVisible,
                  child: Opacity(
                    opacity: isVisible ? 1.0 : 0.01,
                    child: Material(
                      color: isVisible ? Colors.black54 : Colors.transparent,
                      child: SafeArea(
                        child: Center(
                          child: Container(
                            width: maxWidth,
                            height: maxHeight,
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.surface,
                              borderRadius: BorderRadius.circular(18),
                              boxShadow: isVisible
                                  ? const [
                                      BoxShadow(
                                        color: Colors.black38,
                                        blurRadius: 24,
                                        offset: Offset(0, 10),
                                      ),
                                    ]
                                  : const [],
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: Column(
                              children: [
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    16,
                                    12,
                                    8,
                                    8,
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text(
                                              title,
                                              style: Theme.of(
                                                context,
                                              ).textTheme.titleMedium,
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              subtitle,
                                              style: Theme.of(
                                                context,
                                              ).textTheme.bodySmall,
                                            ),
                                          ],
                                        ),
                                      ),
                                      IconButton(
                                        tooltip: 'إعادة التحميل',
                                        icon: const Icon(Icons.refresh_rounded),
                                        onPressed: () => unawaited(() async {
                                          if (onRefreshPressed != null) {
                                            await onRefreshPressed(controller);
                                          }
                                          await controller.loadRequest(
                                            initialUri,
                                            headers: requestHeaders,
                                          );
                                        }()),
                                      ),
                                      IconButton(
                                        tooltip: 'إغلاق',
                                        icon: const Icon(Icons.close),
                                        onPressed: () => finish(
                                          null,
                                          endReason: 'cf_dismissed',
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                ValueListenableBuilder<double>(
                                  valueListenable: progress,
                                  builder: (_, value, _) =>
                                      value > 0 && value < 1
                                      ? LinearProgressIndicator(value: value)
                                      : const Divider(height: 1),
                                ),
                                Expanded(child: innerChild!),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
            child: child,
          );
        },
        child: webViewWidget,
      ),
    );

    overlay.insert(entry);
    try {
      await controller.loadRequest(initialUri, headers: requestHeaders);
    } catch (_) {
      finish(null, endReason: 'cf_load_error');
      return completer.future;
    }

    pollTimer = Timer.periodic(
      const Duration(milliseconds: 550),
      (_) => unawaited(checkNow()),
    );
    revealTimer = Timer(invisibleGracePeriod, () => reveal('grace_timeout'));
    overallTimer = Timer(
      totalTimeout,
      () => finish(null, endReason: 'cf_timeout'),
    );

    return completer.future;
  }

  Future<Map<String, String>> _collectCookies(
    WebViewController controller,
    String currentUrl,
  ) async {
    final cookies = <String, String>{};
    try {
      final raw = await controller.runJavaScriptReturningResult(
        'document.cookie',
      );
      cookies.addAll(parseAnime3rbDocumentCookies(raw));
    } catch (_) {}

    for (final target in <String>{
      currentUrl,
      'https://anime3rb.com',
      'https://video.vid3rb.com',
    }) {
      try {
        final nativeCookies = await _cookieManager.getCookies(target);
        for (final cookie in nativeCookies) {
          final name = cookie.name.trim();
          final value = cookie.value.trim();
          if (name.isEmpty || value.isEmpty) continue;
          cookies[name] = value;
        }
      } catch (_) {}
    }
    return cookies;
  }

  Future<Map<String, dynamic>?> _evalJson(
    WebViewController controller,
    String script,
  ) async {
    final raw = await _evalString(controller, script);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic>
          ? decoded
          : (decoded is Map ? Map<String, dynamic>.from(decoded) : null);
    } catch (_) {
      return null;
    }
  }

  Future<String?> _evalString(
    WebViewController controller,
    String script,
  ) async {
    try {
      final result = await controller.runJavaScriptReturningResult(script);
      var text = result.toString().trim();
      if (text.isEmpty || text == 'null' || text == 'undefined') return null;
      if (text.length >= 2 && text.startsWith('"') && text.endsWith('"')) {
        final decoded = jsonDecode(text);
        if (decoded is String) text = decoded;
      }
      return text;
    } catch (_) {
      return null;
    }
  }
}
