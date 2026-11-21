import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../extensions/providers/witanime_provider.dart';
import '../extensions/providers/witanime_transport.dart';
import '../storage/secure_token_storage.dart';
import '../storage/storage_service.dart';
import 'witanime_account_models.dart';

const String kWitanimeSessionStorageKey = 'witanime_session_v1';

abstract interface class WitanimeAccountBackend {
  Future<WitanimeProfile?> fetchProfile(String sessionCookie);

  Future<WitanimeProfile> updateProfile({
    required String sessionCookie,
    required String displayName,
    String? email,
    String? avatarUrl,
  });

  Future<void> updatePassword({
    required String sessionCookie,
    required String currentPassword,
    required String newPassword,
    required String confirmPassword,
  });

  Future<void> signOut(String sessionCookie);
}

class HttpWitanimeAccountBackend implements WitanimeAccountBackend {
  HttpWitanimeAccountBackend(this._transport, {Uri? origin})
    : _origin = origin ?? Uri.https('witanime.site');

  final WitanimeTransport _transport;
  final Uri _origin;

  String? _extractCsrf(String htmlBody) =>
      RegExp(
        r'''name=["']csrf-token["'][^>]*content=["']([^"']+)["']''',
        caseSensitive: false,
      ).firstMatch(htmlBody)?.group(1) ??
      RegExp(
        r'''input[^>]*name=["']_token["'][^>]*value=["']([^"']+)["']''',
        caseSensitive: false,
      ).firstMatch(htmlBody)?.group(1);

  @override
  Future<WitanimeProfile?> fetchProfile(String sessionCookie) async {
    final uri = _origin.replace(path: '/profile');
    final resp = await _transport.get(
      uri,
      headers: {
        'Cookie': sessionCookie,
        'Accept':
            'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      },
      followRedirects: false,
      operation: 'account_profile',
    );
    if (resp.statusCode == 401 ||
        resp.statusCode == 403 ||
        resp.statusCode == 302) {
      return null;
    }
    if (!resp.isSuccess) {
      throw FormatException('Witanime profile HTTP ${resp.statusCode}');
    }
    return WitanimeProfile.fromProfileHtml(resp.body, baseUri: _origin);
  }

  Future<String> _fetchCsrfToken(String sessionCookie) async {
    final resp = await _transport.get(
      _origin.replace(path: '/profile'),
      headers: {'Cookie': sessionCookie},
      operation: 'account_csrf',
    );
    final token = _extractCsrf(resp.body);
    if (token == null || token.isEmpty) {
      throw const FormatException(
        'يتطلب تعديل الحساب إتمام التحقق من صفحة Witanime الرسمية.',
      );
    }
    return token;
  }

  @override
  Future<WitanimeProfile> updateProfile({
    required String sessionCookie,
    required String displayName,
    String? email,
    String? avatarUrl,
  }) async {
    final csrf = await _fetchCsrfToken(sessionCookie);
    final resp = await _transport.post(
      _origin.replace(path: '/profile'),
      body: {
        '_token': csrf,
        'name': displayName.trim(),
        if (email != null && email.trim().isNotEmpty) 'email': email.trim(),
        if (avatarUrl != null && avatarUrl.trim().isNotEmpty)
          'avatar_url': avatarUrl.trim(),
      },
      headers: {
        'Cookie': sessionCookie,
        'X-CSRF-TOKEN': csrf,
        'Origin': _origin.origin,
        'Referer': '${_origin.origin}/profile',
      },
      operation: 'account_profile_update',
    );
    if (resp.statusCode == 401 || resp.statusCode == 403) {
      throw StateError('انتهت جلسة Witanime أو يلزم التحقق من الموقع.');
    }
    if (!resp.isSuccess && resp.statusCode != 302) {
      throw FormatException('Witanime profile update HTTP ${resp.statusCode}');
    }
    final refreshed = await fetchProfile(sessionCookie);
    return refreshed ??
        WitanimeProfile(
          accountId: email?.trim().isNotEmpty == true
              ? email!.trim()
              : displayName.trim(),
          displayName: displayName.trim(),
          email: email?.trim(),
          avatarUrl: avatarUrl?.trim(),
        );
  }

  @override
  Future<void> updatePassword({
    required String sessionCookie,
    required String currentPassword,
    required String newPassword,
    required String confirmPassword,
  }) async {
    if (newPassword != confirmPassword) {
      throw ArgumentError('كلمتا المرور غير متطابقتين.');
    }
    final csrf = await _fetchCsrfToken(sessionCookie);
    final resp = await _transport.post(
      _origin.replace(path: '/profile/password'),
      body: {
        '_token': csrf,
        'current_password': currentPassword,
        'password': newPassword,
        'password_confirmation': confirmPassword,
      },
      headers: {
        'Cookie': sessionCookie,
        'X-CSRF-TOKEN': csrf,
        'Origin': _origin.origin,
        'Referer': '${_origin.origin}/profile',
      },
      operation: 'account_password_update',
    );
    if (resp.statusCode == 401 || resp.statusCode == 403) {
      throw StateError('انتهت جلسة Witanime أو يلزم التحقق من الموقع.');
    }
    if (!resp.isSuccess && resp.statusCode != 302) {
      throw FormatException('Witanime password update HTTP ${resp.statusCode}');
    }
  }

  @override
  Future<void> signOut(String sessionCookie) async {
    try {
      final csrf = await _fetchCsrfToken(sessionCookie);
      await _transport.post(
        _origin.replace(path: '/logout'),
        body: {'_token': csrf},
        headers: {
          'Cookie': sessionCookie,
          'X-CSRF-TOKEN': csrf,
          'Origin': _origin.origin,
          'Referer': '${_origin.origin}/profile',
        },
        operation: 'account_logout',
      );
    } catch (_) {
      // Local logout must still succeed offline.
    }
  }
}

class _FallbackInMemoryStorage extends StorageService {}

class WitanimeAccountService extends ChangeNotifier {
  WitanimeAccountService({
    required SecureTokenStorage tokenStorage,
    required WitanimeAccountBackend backend,
    Future<bool> Function(Uri)? openWebsite,
  }) : _tokenStorage = tokenStorage,
       _backend = backend,
       _openWebsite =
           openWebsite ??
           ((uri) => launchUrl(uri, mode: LaunchMode.externalApplication));

  final SecureTokenStorage _tokenStorage;
  final WitanimeAccountBackend _backend;
  final Future<bool> Function(Uri) _openWebsite;

  WitanimeAccountSession? _session;
  bool _storageUnavailable = false;
  bool _busy = false;
  String? _pendingReturnRoute;
  VoidCallback? _onSessionInvalidated;

  WitanimeAccountSession? get session => _session;
  WitanimeProfile? get profile => _session?.profile;
  bool get isSignedIn => _session != null;
  String? get accountId => _session?.accountId;
  bool get isBusy => _busy;
  bool get usingInMemorySessionFallback => _storageUnavailable;
  String? get pendingReturnRoute => _pendingReturnRoute;

  void setOnSessionInvalidated(VoidCallback? callback) {
    _onSessionInvalidated = callback;
  }

  static Uri officialAuthUri(WitanimeAuthAction action) => switch (action) {
    WitanimeAuthAction.signIn => WitanimeProvider.websiteUri('/login'),
    WitanimeAuthAction.register => WitanimeProvider.websiteUri('/register'),
    WitanimeAuthAction.forgotPassword => WitanimeProvider.websiteUri(
      '/forgot-password',
    ),
  };

  Future<void> restoreSession() async {
    try {
      final raw = await _tokenStorage.read(kWitanimeSessionStorageKey);
      final restored = WitanimeAccountSession.tryDecode(raw);
      if (restored != null && _session == null) {
        _session = restored;
        notifyListeners();
      }
    } catch (error) {
      _storageUnavailable = true;
      recordWitanimeDiagnostic(
        'session_restore',
        status: 'memory_fallback',
        durationMs: 0,
        errorType: classifyWitanimeFailure(error),
      );
    }
  }

  Future<void> _persistSession(WitanimeAccountSession session) async {
    _session = session;
    try {
      await _tokenStorage.write(kWitanimeSessionStorageKey, session.encode());
      _storageUnavailable = false;
    } catch (error) {
      // Keep the validated session alive in memory when platform secure
      // storage cannot store secrets.
      _storageUnavailable = true;
      recordWitanimeDiagnostic(
        'session_write',
        status: 'memory_fallback',
        durationMs: 0,
        errorType: classifyWitanimeFailure(error),
      );
    }
    notifyListeners();
  }

  void recordPendingAuthReturnRoute(String? returnRoute) {
    _pendingReturnRoute = returnRoute;
  }

  Future<bool> beginOfficialAuth(
    WitanimeAuthAction action, {
    String? returnRoute,
  }) async {
    _pendingReturnRoute = returnRoute;
    return _openWebsite(officialAuthUri(action));
  }

  Future<bool> openDeleteAccountChannel() =>
      _openWebsite(WitanimeProvider.websiteUri('/privacy'));

  Future<({WitanimeProfile profile, String? returnRoute})?>
  _verifyAndPersistSession({
    required String sessionCookie,
    String? csrfToken,
  }) async {
    _busy = true;
    notifyListeners();
    try {
      final verified = await _backend.fetchProfile(sessionCookie);
      if (verified == null) return null;
      final next = WitanimeAccountSession(
        sessionCookie: sessionCookie,
        csrfToken: csrfToken?.trim(),
        profile: verified,
        updatedAtMillis: DateTime.now().millisecondsSinceEpoch,
      );
      await _persistSession(next);
      final route = _pendingReturnRoute;
      _pendingReturnRoute = null;
      return (profile: verified, returnRoute: route);
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Checks whether [sessionCookie] represents an authenticated session and
  /// activates it when verified. Returns `null` if not yet authenticated.
  Future<({WitanimeProfile profile, String? returnRoute})?>
  tryCompleteBrowserAuth({
    required String sessionCookie,
    String? csrfToken,
  }) async {
    final trimmed = sessionCookie.trim();
    if (trimmed.isEmpty) return null;
    try {
      return await _verifyAndPersistSession(
        sessionCookie: trimmed,
        csrfToken: csrfToken,
      );
    } catch (_) {
      return null;
    }
  }

  /// Verifies [sessionCookie] against Witanime's `/profile` before activating
  /// the account or opening its library. Returns any recorded return route.
  Future<({WitanimeProfile profile, String? returnRoute})> completeBrowserAuth({
    required String sessionCookie,
    String? csrfToken,
  }) async {
    final trimmed = sessionCookie.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('يرجى إدخال رمز أو كوكي جلسة Witanime.');
    }
    final result = await _verifyAndPersistSession(
      sessionCookie: trimmed,
      csrfToken: csrfToken,
    );
    if (result == null) {
      throw StateError('تعذر تأكيد هوية حساب Witanime بهذه الجلسة.');
    }
    return result;
  }

  Future<WitanimeProfile?> refreshProfile() async {
    final current = _session;
    if (current == null) return null;
    final fetched = await _backend.fetchProfile(current.sessionCookie);
    if (fetched == null) {
      await signOut(notifyRemote: false);
      return null;
    }
    if (_session?.accountId != current.accountId) return _session?.profile;
    await _persistSession(
      WitanimeAccountSession(
        sessionCookie: current.sessionCookie,
        csrfToken: current.csrfToken,
        profile: fetched,
        updatedAtMillis: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    return fetched;
  }

  Future<WitanimeProfile> updateProfile({
    required String displayName,
    String? email,
    String? avatarUrl,
  }) async {
    final current = _session;
    if (current == null) {
      throw StateError('سجّل الدخول إلى حساب Witanime أولًا.');
    }
    _busy = true;
    notifyListeners();
    try {
      final updated = await _backend.updateProfile(
        sessionCookie: current.sessionCookie,
        displayName: displayName,
        email: email,
        avatarUrl: avatarUrl,
      );
      await _persistSession(
        WitanimeAccountSession(
          sessionCookie: current.sessionCookie,
          csrfToken: current.csrfToken,
          profile: updated,
          updatedAtMillis: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      return updated;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> updatePassword({
    required String currentPassword,
    required String newPassword,
    required String confirmPassword,
  }) async {
    final current = _session;
    if (current == null) {
      throw StateError('سجّل الدخول إلى حساب Witanime أولًا.');
    }
    _busy = true;
    notifyListeners();
    try {
      await _backend.updatePassword(
        sessionCookie: current.sessionCookie,
        currentPassword: currentPassword,
        newPassword: newPassword,
        confirmPassword: confirmPassword,
      );
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> signOut({bool notifyRemote = true}) async {
    final current = _session;
    _session = null;
    _pendingReturnRoute = null;
    if (notifyRemote && current != null) {
      await _backend.signOut(current.sessionCookie);
    }
    try {
      await _tokenStorage.delete(kWitanimeSessionStorageKey);
    } catch (_) {
      // Best-effort cleanup when storage backend is unavailable.
    }
    _onSessionInvalidated?.call();
    notifyListeners();
  }
}

final witanimeTransportProvider = Provider<WitanimeTransport>((ref) {
  final transport = DioWitanimeTransport(
    sessionHeaders: (_) async {
      final cookie = ref.read(witanimeAccountServiceProvider).session?.sessionCookie;
      return cookie == null || cookie.isEmpty
          ? const <String, String>{}
          : <String, String>{'Cookie': cookie};
    },
  );
  ref.onDispose(() => transport.close(force: true));
  return transport;
});

final witanimeAccountServiceProvider = Provider<WitanimeAccountService>((ref) {
  final transport = DioWitanimeTransport();
  late final SecureTokenStorage tokenStorage;
  try {
    tokenStorage = ref.watch(secureTokenStorageProvider);
  } catch (_) {
    tokenStorage = SecureTokenStorage(_FallbackInMemoryStorage());
  }
  final service = WitanimeAccountService(
    tokenStorage: tokenStorage,
    backend: HttpWitanimeAccountBackend(transport),
  );
  unawaited(service.restoreSession());
  ref.onDispose(() {
    transport.close(force: true);
    service.dispose();
  });
  return service;
});

final witanimeAccountRevisionProvider = NotifierProvider<
    _WitanimeAccountRevisionNotifier, int>(_WitanimeAccountRevisionNotifier.new);

class _WitanimeAccountRevisionNotifier extends Notifier<int> {
  @override
  int build() {
    final service = ref.watch(witanimeAccountServiceProvider);
    void onChanged() => state++;
    service.addListener(onChanged);
    ref.onDispose(() => service.removeListener(onChanged));
    return 0;
  }
}
