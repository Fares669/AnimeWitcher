import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_cookie_manager_flutter/webview_cookie_manager.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../../../core/account/witanime_account_models.dart';
import '../../../../core/account/witanime_account_service.dart';

typedef WitanimeBrowserAuthResult = ({
  WitanimeProfile profile,
  String? returnRoute,
});

/// Parses a `document.cookie` JS evaluation result into cookie name/value pairs.
Map<String, String> parseWitanimeDocumentCookies(Object? rawResult) {
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

String formatWitanimeCookieHeader(Map<String, String> cookies) =>
    cookies.entries.map((entry) => '${entry.key}=${entry.value}').join('; ');

bool isWitanimeHostUri(Uri uri) =>
    uri.host == 'witanime.site' || uri.host.endsWith('.witanime.site');

bool isWitanimeAuthFormPath(String path) {
  final normalized = path.trim().toLowerCase();
  return normalized == '/login' ||
      normalized == '/register' ||
      normalized == '/forgot-password' ||
      normalized.startsWith('/reset-password') ||
      normalized.startsWith('/password/reset') ||
      normalized.startsWith('/cdn-cgi/');
}

/// In-app browser session for Witanime sign-in / registration that captures
/// the authenticated session cookie automatically and closes immediately.
class WitanimeAuthWebViewScreen extends ConsumerStatefulWidget {
  const WitanimeAuthWebViewScreen({super.key, required this.action});

  final WitanimeAuthAction action;

  static bool get isSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.macOS);

  static Future<WitanimeBrowserAuthResult?> open(
    BuildContext context, {
    required WitanimeAuthAction action,
  }) => Navigator.of(context, rootNavigator: true).push<WitanimeBrowserAuthResult>(
    MaterialPageRoute<WitanimeBrowserAuthResult>(
      fullscreenDialog: true,
      builder: (_) => WitanimeAuthWebViewScreen(action: action),
    ),
  );

  @override
  ConsumerState<WitanimeAuthWebViewScreen> createState() =>
      _WitanimeAuthWebViewScreenState();
}

class _WitanimeAuthWebViewScreenState
    extends ConsumerState<WitanimeAuthWebViewScreen> {
  final WebviewCookieManager _cookieManager = WebviewCookieManager();
  late final WebViewController _controller;

  double _progress = 0;
  bool _verifying = false;
  bool _completed = false;
  String? _pendingCheckUrl;
  Timer? _urlChangeTimer;

  String get _title => switch (widget.action) {
    WitanimeAuthAction.signIn => 'تسجيل الدخول إلى Witanime',
    WitanimeAuthAction.register => 'إنشاء حساب Witanime',
    WitanimeAuthAction.forgotPassword => 'استعادة كلمة مرور Witanime',
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
            setState(() => _progress = progress.clamp(0, 100) / 100.0);
          },
          onPageStarted: (_) {
            if (!mounted) return;
            setState(() => _progress = 0.08);
          },
          onPageFinished: (url) {
            if (!mounted) return;
            setState(() => _progress = 1.0);
            _urlChangeTimer?.cancel();
            unawaited(_attemptSessionCapture(url));
          },
          onUrlChange: (change) {
            final url = change.url;
            if (url == null || _completed) return;
            final uri = Uri.tryParse(url);
            if (uri == null ||
                !isWitanimeHostUri(uri) ||
                isWitanimeAuthFormPath(uri.path)) {
              return;
            }
            _urlChangeTimer?.cancel();
            _urlChangeTimer = Timer(const Duration(milliseconds: 350), () {
              if (mounted && !_completed) {
                unawaited(_attemptSessionCapture(url));
              }
            });
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
    if (widget.action == WitanimeAuthAction.signIn ||
        widget.action == WitanimeAuthAction.register) {
      try {
        await _cookieManager.clearCookies();
      } catch (_) {
        // Ignore cookie clearing failures and continue loading the auth page.
      }
    }
    if (!mounted || _completed) return;
    await _controller.loadRequest(
      WitanimeAccountService.officialAuthUri(widget.action),
    );
  }

  Future<bool> _pageLooksAuthenticated() async {
    try {
      final result = await _controller.runJavaScriptReturningResult(
        'Boolean(document.querySelector(\'form[action*="/logout"], a[href*="/logout"]\'))',
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
      cookies.addAll(parseWitanimeDocumentCookies(jsCookies));
    } catch (_) {
      // Fallback to native cookie store only.
    }

    for (final target in <String>{currentUrl, 'https://witanime.site'}) {
      try {
        final nativeCookies = await _cookieManager.getCookies(target);
        for (final cookie in nativeCookies) {
          final name = cookie.name.trim();
          final value = cookie.value.trim();
          if (name.isEmpty || value.isEmpty) continue;
          cookies[name] = value;
        }
      } catch (_) {
        // Ignore platform cookie store lookup failure on one target.
      }
    }
    return formatWitanimeCookieHeader(cookies);
  }

  Future<void> _attemptSessionCapture(String url) async {
    if (_completed || !mounted) return;
    final uri = Uri.tryParse(url);
    if (uri == null || !isWitanimeHostUri(uri)) return;

    if (_verifying) {
      _pendingCheckUrl = url;
      return;
    }

    final onAuthForm = isWitanimeAuthFormPath(uri.path);
    final looksSignedIn = await _pageLooksAuthenticated();
    if (onAuthForm && !looksSignedIn) return;

    if (!mounted || _completed) return;
    setState(() => _verifying = true);
    try {
      final accountService = ref.read(witanimeAccountServiceProvider);
      final csrfToken = await _readCsrfToken();

      var cookieHeader = await _collectCookieHeader(url);
      var result = await accountService.tryCompleteBrowserAuth(
        sessionCookie: cookieHeader,
        csrfToken: csrfToken,
      );

      if (result == null &&
          (looksSignedIn || uri.path.toLowerCase().startsWith('/profile'))) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
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
      if (mounted) {
        setState(() => _verifying = false);
      }
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
                            'جارٍ ربط جلسة Witanime تلقائيًا...',
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
