import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:webview_cookie_manager_flutter/webview_cookie_manager.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../../features/settings/presentation/widgets/anime3rb_auth_webview_screen.dart';
import '../../network/http_defaults.dart';
import '../../router/app_router.dart';
import 'anime3rb_playback.dart';
import 'anime3rb_transport.dart';

/// Cross-platform (iOS WKWebView & Android WebView) solver for Anime3rb
/// Cloudflare challenges and Vid3rb Turnstile source resolution.
///
/// Always attempts an invisible, non-interactive load first so Cloudflare JS
/// checks and Vid3rb's `#cf-invisible-turnstile` complete silently without user
/// interruption. If Cloudflare or Vid3rb presents an interactive verification
/// prompt, the same live WebView is promoted into a visible verification dialog
/// so the user can complete verification legitimately.
class Anime3rbWebViewSolver {
  Anime3rbWebViewSolver._();

  static final Anime3rbWebViewSolver instance = Anime3rbWebViewSolver._();

  static bool get isSupported =>
      !kIsWeb && Anime3rbAuthWebViewScreen.isSupported;

  final WebviewCookieManager _cookieManager = WebviewCookieManager();
  Future<void> _queue = Future<void>.value();

  Future<T?> _serialized<T>(Future<T?> Function() action) {
    final next = _queue.then<T?>((_) => action(), onError: (_) => action());
    _queue = next.then((_) {}, onError: (_) {});
    return next;
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

  Future<Anime3rbChallengeSolution?> _runCloudflareSession(Uri uri) async {
    return _withWebViewOverlay<Anime3rbChallengeSolution>(
      initialUri: uri,
      title: 'التحقق من Anime3rb',
      subtitle: 'أكمل التحقق الأمني للمتابعة في التصفح والتحميل.',
      invisibleGracePeriod: const Duration(milliseconds: 4500),
      totalTimeout: const Duration(seconds: 90),
      evaluateState: (controller, currentUrl, promoteVisible) async {
        final state = await _evalJson(
          controller,
          '''
(function() {
  var title = (document.title || '').toLowerCase();
  var text = document.body ? (document.body.innerText || '') : '';
  var cfEl = document.querySelector('#challenge-form, #challenge-running, #cf-please-wait, .cf-browser-verification');
  var isCf = !!cfEl ||
    title.indexOf('just a moment') !== -1 ||
    title.indexOf('attention required') !== -1 ||
    title.indexOf('لحظة واحدة') !== -1 ||
    text.indexOf('Checking your browser') !== -1 ||
    text.indexOf('Verify you are human') !== -1 ||
    text.indexOf('Enable JavaScript and cookies') !== -1;
  var hasInteractive = !!document.querySelector('iframe[src*="challenges.cloudflare.com"], input[name="cf-turnstile-response"], .cf-turnstile, #turnstile-wrapper');
  return JSON.stringify({
    isCf: isCf,
    hasInteractive: hasInteractive,
    ready: document.readyState || '',
    len: text.trim().length,
    ua: navigator.userAgent || ''
  });
})()
''',
        );
        if (state == null) return null;
        final isCf = state['isCf'] == true;
        final hasInteractive = state['hasInteractive'] == true;
        final ready = state['ready']?.toString() ?? '';
        final len = (state['len'] as num?)?.toInt() ?? 0;
        final ua = state['ua']?.toString().trim();

        if (isCf && hasInteractive) {
          promoteVisible();
        }
        if (isCf || ready != 'complete') return null;

        final cookies = await _collectCookies(controller, currentUrl);
        if (!cookies.containsKey('cf_clearance') && len < 80) {
          return null;
        }
        final html = await _evalString(
          controller,
          'document.documentElement ? document.documentElement.outerHTML : ""',
        );
        return (
          cookies: cookies,
          html: (html != null && html.trim().isNotEmpty) ? html : null,
          userAgent: (ua != null && ua.isNotEmpty) ? ua : null,
        );
      },
    );
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
      onProgressHook: (controller, progress) async {
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
  var text = document.body ? (document.body.innerText || '') : '';
  var cfChallenge = !!document.querySelector('#challenge-form, #challenge-running, .cf-browser-verification') ||
    title.indexOf('just a moment') !== -1 ||
    title.indexOf('attention required') !== -1 ||
    text.indexOf('Checking your browser') !== -1 ||
    text.indexOf('Verify you are human') !== -1;

  var managedWrap = document.querySelector('.captcha-wrapper, #cf-managed-turnstile');
  var managedVisible = false;
  if (managedWrap) {
    var st = window.getComputedStyle ? window.getComputedStyle(managedWrap) : null;
    if (!st || (st.display !== 'none' && st.visibility !== 'hidden' && st.opacity !== '0')) {
      managedVisible = managedWrap.offsetWidth > 0 || managedWrap.offsetHeight > 0 || managedWrap.childElementCount > 0;
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
      if (window.videojs && typeof window.videojs.getAllPlayers === 'function') {
        var players = window.videojs.getAllPlayers() || [];
        for (var i = 0; i < players.length; i++) {
          var p = players[i];
          var srcs = (typeof p.currentSources === 'function' ? p.currentSources() : null) ||
            (p.options_ && Array.isArray(p.options_.sources) ? p.options_.sources : []);
          for (var j = 0; j < srcs.length; j++) {
            var s = srcs[j];
            if (s && s.src && String(s.src).indexOf('http') === 0) {
              list.push({
                src: String(s.src),
                label: String(s.label || s.res || s.quality || 'HD'),
                premium: Boolean(s.premium)
              });
            }
          }
          if (!list.length && typeof p.currentSrc === 'function') {
            var csrc = p.currentSrc();
            if (csrc && String(csrc).indexOf('http') === 0) {
              list.push({ src: String(csrc), label: 'HD', premium: false });
            }
          }
        }
      }
      if (!list.length) {
        var els = document.querySelectorAll('video source[src], video[src]');
        for (var k = 0; k < els.length; k++) {
          var u = els[k].getAttribute('src') || els[k].currentSrc || '';
          if (u && u.indexOf('http') === 0) {
            list.push({
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
          promoteVisible();
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
    required Future<T?> Function(
      WebViewController controller,
      String currentUrl,
      VoidCallback promoteVisible,
    )
    evaluateState,
    Future<void> Function(WebViewController controller)? onPageStartedHook,
    Future<void> Function(WebViewController controller)? onPageFinishedHook,
    Future<void> Function(WebViewController controller, int progress)?
    onProgressHook,
  }) async {
    final overlay = rootNavigatorKey.currentState?.overlay;
    if (overlay == null) return null;

    final completer = Completer<T?>();
    final visible = ValueNotifier<bool>(false);
    final progress = ValueNotifier<double>(0);
    var currentUrl = initialUri.toString();
    var busyEvaluating = false;
    Timer? pollTimer;
    Timer? revealTimer;
    Timer? overallTimer;
    OverlayEntry? entry;

    late final WebViewController controller;

    void finish(T? value) {
      if (completer.isCompleted) return;
      pollTimer?.cancel();
      revealTimer?.cancel();
      overallTimer?.cancel();
      try {
        entry?.remove();
      } catch (_) {}
      visible.dispose();
      progress.dispose();
      completer.complete(value);
    }

    Future<void> checkNow() async {
      if (completer.isCompleted || busyEvaluating) return;
      busyEvaluating = true;
      try {
        final result = await evaluateState(controller, currentUrl, () {
          if (!completer.isCompleted && !visible.value) {
            visible.value = true;
          }
        });
        if (result != null) {
          finish(result);
        }
      } catch (_) {
        // Keep polling until solved or timed out.
      } finally {
        busyEvaluating = false;
      }
    }

    controller = WebViewController();
    unawaited(controller.setJavaScriptMode(JavaScriptMode.unrestricted));
    unawaited(
      controller.setNavigationDelegate(
        NavigationDelegate(
          onProgress: (p) {
            if (!completer.isCompleted) {
              progress.value = p / 100.0;
              if (onProgressHook != null) {
                unawaited(onProgressHook(controller, p));
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
      ),
    );
    try {
      await controller.setUserAgent(kDefaultBrowserUserAgent);
    } catch (_) {}

    final webViewWidget = WebViewWidget(controller: controller);

    entry = OverlayEntry(
      builder: (context) => ValueListenableBuilder<bool>(
        valueListenable: visible,
        builder: (context, isVisible, child) {
          if (!isVisible) {
            return Positioned(
              left: 0,
              top: 0,
              width: 390,
              height: 640,
              child: IgnorePointer(child: Opacity(opacity: 0.01, child: child)),
            );
          }
          final size = MediaQuery.sizeOf(context);
          final maxWidth = (size.width - 32).clamp(280.0, 520.0);
          final maxHeight = (size.height * 0.72).clamp(360.0, 620.0);
          return Positioned.fill(
            child: Material(
              color: Colors.black54,
              child: SafeArea(
                child: Center(
                  child: Container(
                    width: maxWidth,
                    height: maxHeight,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      borderRadius: BorderRadius.circular(18),
                      boxShadow: const [
                        BoxShadow(
                          color: Colors.black38,
                          blurRadius: 24,
                          offset: Offset(0, 10),
                        ),
                      ],
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
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
                                tooltip: 'إغلاق',
                                icon: const Icon(Icons.close),
                                onPressed: () => finish(null),
                              ),
                            ],
                          ),
                        ),
                        ValueListenableBuilder<double>(
                          valueListenable: progress,
                          builder: (_, value, _) => value > 0 && value < 1
                              ? LinearProgressIndicator(value: value)
                              : const Divider(height: 1),
                        ),
                        Expanded(child: child!),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
        child: webViewWidget,
      ),
    );

    overlay.insert(entry);
    try {
      await controller.loadRequest(initialUri, headers: requestHeaders);
    } catch (_) {
      finish(null);
      return completer.future;
    }

    pollTimer = Timer.periodic(
      const Duration(milliseconds: 450),
      (_) => unawaited(checkNow()),
    );
    revealTimer = Timer(invisibleGracePeriod, () {
      if (!completer.isCompleted) {
        visible.value = true;
      }
    });
    overallTimer = Timer(totalTimeout, () => finish(null));

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
