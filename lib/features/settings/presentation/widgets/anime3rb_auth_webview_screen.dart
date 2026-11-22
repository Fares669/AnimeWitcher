import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_cookie_manager_flutter/webview_cookie_manager.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../../../core/account/anime3rb_account_models.dart';
import '../../../../core/account/anime3rb_account_service.dart';

typedef Anime3rbBrowserAuthResult = ({
  Anime3rbProfile profile,
  String? returnRoute,
});

Map<String, String> parseAnime3rbDocumentCookies(Object? rawResult) {
  if (rawResult == null) return const <String, String>{};
  var text = rawResult.toString().trim();
  if (text.isEmpty || text == 'null' || text == 'undefined') {
    return const <String, String>{};
  }
  if (text.length >= 2 && text.startsWith('"') && text.endsWith('"')) {
    try {
      final decoded = jsonDecode(text);
      if (decoded is String) text = decoded;
    } catch (_) {
      text = text.substring(1, text.length - 1);
    }
  }
  final parsed = <String, String>{};
  for (final part in text.split(';')) {
    final idx = part.indexOf('=');
    if (idx <= 0) continue;
    final name = part.substring(0, idx).trim();
    final value = part.substring(idx + 1).trim();
    if (name.isEmpty || value.isEmpty) continue;
    parsed[name] = value;
  }
  return parsed;
}

String formatAnime3rbCookieHeader(Map<String, String> cookies) =>
    cookies.entries.map((entry) => '${entry.key}=${entry.value}').join('; ');

bool isAnime3rbHostUri(Uri uri) =>
    uri.host == 'anime3rb.com' || uri.host.endsWith('.anime3rb.com');

bool isAnime3rbAuthFormPath(String path) {
  final normalized = path.trim().toLowerCase();
  return normalized == '/login' ||
      normalized == '/register' ||
      normalized == '/forgot-password' ||
      normalized.startsWith('/reset-password') ||
      normalized.startsWith('/password/reset') ||
      normalized.startsWith('/cdn-cgi/');
}

class Anime3rbAuthWebViewScreen extends ConsumerStatefulWidget {
  const Anime3rbAuthWebViewScreen({super.key, required this.action});

  final Anime3rbAuthAction action;

  static bool get isSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.macOS);

  static Future<Anime3rbBrowserAuthResult?> open(
    BuildContext context, {
    required Anime3rbAuthAction action,
  }) => Navigator.of(context, rootNavigator: true).push<Anime3rbBrowserAuthResult>(
    MaterialPageRoute<Anime3rbBrowserAuthResult>(
      fullscreenDialog: true,
      builder: (_) => Anime3rbAuthWebViewScreen(action: action),
    ),
  );

  @override
  ConsumerState<Anime3rbAuthWebViewScreen> createState() =>
      _Anime3rbAuthWebViewScreenState();
}

class _Anime3rbAuthWebViewScreenState
    extends ConsumerState<Anime3rbAuthWebViewScreen> {
  final WebviewCookieManager _cookieManager = WebviewCookieManager();
  late final WebViewController _controller;

  double _progress = 0;
  bool _verifying = false;
  bool _completed = false;
  String? _pendingCheckUrl;
  Timer? _urlChangeTimer;

  String get _title => switch (widget.action) {
    Anime3rbAuthAction.signIn => 'تسجيل الدخول إلى Anime3rb',
    Anime3rbAuthAction.register => 'إنشاء حساب Anime3rb',
    Anime3rbAuthAction.forgotPassword => 'استعادة كلمة مرور Anime3rb',
  };

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) {
            if (!mounted) return;
            setState(() => _progress = progress / 100.0);
          },
          onUrlChange: (change) {
            final nextUrl = change.url;
            if (nextUrl == null) return;
            _urlChangeTimer?.cancel();
            _urlChangeTimer = Timer(const Duration(milliseconds: 500), () {
              unawaited(_attemptSessionCapture(nextUrl));
            });
          },
          onPageFinished: (url) {
            _urlChangeTimer?.cancel();
            unawaited(_attemptSessionCapture(url));
          },
        ),
      );
    unawaited(_loadInitialPage());
  }

  @override
  void dispose() {
    _urlChangeTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadInitialPage() async {
    if (widget.action == Anime3rbAuthAction.signIn ||
        widget.action == Anime3rbAuthAction.register) {
      try {
        await _cookieManager.clearCookies();
      } catch (_) {}
    }
    if (!mounted || _completed) return;
    await _controller.loadRequest(
      Anime3rbAccountService.officialAuthUri(widget.action),
    );
  }

  Future<bool> _pageLooksAuthenticated() async {
    try {
      final result = await _controller.runJavaScriptReturningResult(
        'Boolean(document.querySelector(\'form[action*="/logout"], a[href*="/user/profile"]\'))',
      );
      return result == true || result.toString().toLowerCase() == 'true';
    } catch (_) {
      return false;
    }
  }

  Future<String?> _readCsrfToken() async {
    try {
      final raw = await _controller.runJavaScriptReturningResult(
        "document.querySelector('meta[name=\"csrf-token\"]')?.getAttribute('content') ?? ''",
      );
      var value = raw.toString().trim();
      if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
        try {
          final decoded = jsonDecode(value);
          if (decoded is String) value = decoded;
        } catch (_) {
          value = value.substring(1, value.length - 1);
        }
      }
      return value.trim().isEmpty ? null : value.trim();
    } catch (_) {
      return null;
    }
  }

  Future<String> _collectCookieHeader(String currentUrl) async {
    final cookies = <String, String>{};
    try {
      final jsCookies = await _controller.runJavaScriptReturningResult(
        'document.cookie',
      );
      cookies.addAll(parseAnime3rbDocumentCookies(jsCookies));
    } catch (_) {}

    for (final target in <String>{currentUrl, 'https://anime3rb.com'}) {
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
    return formatAnime3rbCookieHeader(cookies);
  }

  Future<void> _attemptSessionCapture(String url) async {
    if (_completed || !mounted) return;
    final uri = Uri.tryParse(url);
    if (uri == null || !isAnime3rbHostUri(uri)) return;

    if (_verifying) {
      _pendingCheckUrl = url;
      return;
    }

    final onAuthForm = isAnime3rbAuthFormPath(uri.path);
    final looksSignedIn = await _pageLooksAuthenticated();
    if (onAuthForm && !looksSignedIn) return;

    if (!mounted || _completed) return;
    setState(() => _verifying = true);
    try {
      final accountService = ref.read(anime3rbAccountServiceProvider);
      final csrfToken = await _readCsrfToken();

      var cookieHeader = await _collectCookieHeader(url);
      var result = await accountService.tryCompleteBrowserAuth(
        sessionCookie: cookieHeader,
        csrfToken: csrfToken,
      );

      if (result == null &&
          (looksSignedIn || uri.path.toLowerCase().startsWith('/user/profile'))) {
        await Future<void>.delayed(const Duration(milliseconds: 350));
        if (!mounted || _completed) return;
        cookieHeader = await _collectCookieHeader(url);
        result = await accountService.tryCompleteBrowserAuth(
          sessionCookie: cookieHeader,
          csrfToken: csrfToken,
        );
      }

      if (!mounted || _completed) return;
      if (result != null) {
        _completed = true;
        _urlChangeTimer?.cancel();
        Navigator.of(context).pop(result);
      }
    } finally {
      if (mounted) setState(() => _verifying = false);
      final pending = _pendingCheckUrl;
      _pendingCheckUrl = null;
      if (pending != null && mounted && !_completed) {
        unawaited(_attemptSessionCapture(pending));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'إغلاق',
          icon: const Icon(Icons.close_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(_title),
        actions: [
          IconButton(
            tooltip: 'إعادة التحميل',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () => _controller.reload(),
          ),
        ],
        bottom: _progress < 1.0
            ? PreferredSize(
                preferredSize: const Size.fromHeight(3),
                child: LinearProgressIndicator(value: _progress),
              )
            : null,
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (_verifying)
            Positioned(
              left: 16,
              right: 16,
              bottom: 16,
              child: SafeArea(
                child: Material(
                  elevation: 4,
                  color: colors.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    child: Row(
                      children: [
                        SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'جارٍ ربط جلسة Anime3rb تلقائيًا...',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
