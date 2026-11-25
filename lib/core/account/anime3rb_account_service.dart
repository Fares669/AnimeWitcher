import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:url_launcher/url_launcher.dart';

import '../extensions/providers/anime3rb_provider.dart';
import '../extensions/providers/anime3rb_transport.dart';
import '../extensions/providers/anime3rb_webview_solver.dart';
import '../storage/secure_token_storage.dart';
import '../storage/storage_service.dart';
import '../utils/digit_normalization.dart';
import 'anime3rb_account_models.dart';
import 'anime3rb_livewire.dart';

const String kAnime3rbSessionStorageKey = 'anime3rb_account_session_v1';

typedef Anime3rbAuthResult = ({Anime3rbProfile profile, String? returnRoute});

abstract interface class Anime3rbAccountBackend {
  Future<Anime3rbProfile?> fetchProfile(String sessionCookie);

  Future<Anime3rbProfile> updateProfile({
    required String sessionCookie,
    required String displayName,
    required String email,
  });

  Future<void> updatePassword({
    required String sessionCookie,
    required String currentPassword,
    required String password,
    required String passwordConfirmation,
  });

  Future<void> logoutOtherBrowserSessions({
    required String sessionCookie,
    required String password,
  });

  Future<List<Anime3rbNotificationItem>> fetchNotifications(
    String sessionCookie,
  );

  Future<void> markNotificationsRead(String sessionCookie);

  Future<({List<Anime3rbReportIssueOption> issues, List<Anime3rbReportScopeOption> scopes, bool blocked, String? blockedMessage})>
  fetchReportForm({
    required String sessionCookie,
    required Uri episodeUri,
  });

  Future<void> submitEpisodeReport({
    required String sessionCookie,
    required Uri episodeUri,
    required int issueId,
    required String scope,
    String? videosNumbers,
    String message = '',
  });

  Future<void> signOut(String sessionCookie);
}

class HttpAnime3rbAccountBackend implements Anime3rbAccountBackend {
  HttpAnime3rbAccountBackend(this._transport, {Uri? origin})
    : _origin = origin ?? Uri.parse(Anime3rbProvider.originUrl);

  final Anime3rbTransport _transport;
  final Uri _origin;

  Uri _uri(String path) => _origin.resolve(path);

  Map<String, String> _cookieHeaders(String cookie) {
    final trimmed = cookie.trim();
    return trimmed.isEmpty
        ? const <String, String>{}
        : <String, String>{'Cookie': trimmed};
  }

  @override
  Future<Anime3rbProfile?> fetchProfile(String sessionCookie) async {
    final trimmed = sessionCookie.trim();
    if (trimmed.isEmpty) return null;
    final uri = _uri('/user/profile');
    final resp = await _transport.get(
      uri,
      headers: {
        'Accept':
            'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        ..._cookieHeaders(trimmed),
      },
      operation: 'account_profile',
    );
    if (resp.statusCode == 401 ||
        resp.statusCode == 403 ||
        resp.statusCode == 419 ||
        Anime3rbLivewireClient.isLoginUri(resp.finalUri)) {
      return null;
    }
    if (!resp.isSuccess) {
      throw Anime3rbLivewireException(
        'تعذر التحقق من جلسة Anime3rb (HTTP ${resp.statusCode}).',
        statusCode: resp.statusCode,
      );
    }
    return parseProfileFromHtml(
      resp.body,
      baseUri: resp.finalUri ?? uri,
      sessionCookie: trimmed,
    );
  }

  @override
  Future<Anime3rbProfile> updateProfile({
    required String sessionCookie,
    required String displayName,
    required String email,
  }) async {
    await Anime3rbLivewireClient.callComponent(
      transport: _transport,
      pageUri: _uri('/user/profile'),
      componentName: 'profile.update-profile-information-form',
      method: 'updateProfileInformation',
      updates: <String, Object?>{
        'state.name': displayName.trim(),
        'state.email': email.trim(),
      },
      headers: _cookieHeaders(sessionCookie),
      operation: 'account_update_profile',
    );
    final refreshed = await fetchProfile(sessionCookie);
    if (refreshed == null) {
      throw const Anime3rbAuthRequiredException();
    }
    return refreshed;
  }

  @override
  Future<void> updatePassword({
    required String sessionCookie,
    required String currentPassword,
    required String password,
    required String passwordConfirmation,
  }) async {
    await Anime3rbLivewireClient.callComponent(
      transport: _transport,
      pageUri: _uri('/user/profile'),
      componentName: 'profile.update-password-form',
      method: 'updatePassword',
      updates: <String, Object?>{
        'state.current_password': currentPassword,
        'state.password': password,
        'state.password_confirmation': passwordConfirmation,
      },
      headers: _cookieHeaders(sessionCookie),
      operation: 'account_update_password',
    );
  }

  @override
  Future<void> logoutOtherBrowserSessions({
    required String sessionCookie,
    required String password,
  }) async {
    await Anime3rbLivewireClient.callComponent(
      transport: _transport,
      pageUri: _uri('/user/profile'),
      componentName: 'profile.logout-other-browser-sessions-form',
      method: 'logoutOtherBrowserSessions',
      updates: <String, Object?>{'password': password},
      headers: _cookieHeaders(sessionCookie),
      operation: 'account_logout_other_sessions',
    );
  }

  @override
  Future<List<Anime3rbNotificationItem>> fetchNotifications(
    String sessionCookie,
  ) async {
    final pageUri = _uri('/user/profile');
    final pageResp = await _transport.get(
      pageUri,
      headers: {
        'Accept':
            'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        ..._cookieHeaders(sessionCookie),
      },
      operation: 'account_notifications_page',
    );
    if (pageResp.statusCode == 401 ||
        Anime3rbLivewireClient.isLoginUri(pageResp.finalUri)) {
      throw const Anime3rbAuthRequiredException();
    }
    final doc = html_parser.parse(pageResp.body);
    final comp = Anime3rbLivewireClient.findComponent(
      doc,
      'notification.index-notifications',
    );
    if (comp == null) return const <Anime3rbNotificationItem>[];

    var html = comp.element?.outerHtml ?? '';
    if (comp.lazyPayload != null) {
      final res = await Anime3rbLivewireClient.callComponent(
        transport: _transport,
        pageUri: pageResp.finalUri ?? pageUri,
        componentName: 'notification.index-notifications',
        method: '__lazyLoad',
        params: <Object?>[comp.lazyPayload],
        snapshotOverride: comp.snapshot,
        csrfOverride: Anime3rbLivewireClient.extractCsrfToken(doc),
        updateUriOverride: Anime3rbLivewireClient.extractUpdateUri(
          doc,
          pageResp.finalUri ?? pageUri,
        ),
        headers: _cookieHeaders(sessionCookie),
        operation: 'account_notifications_lazy',
      );
      html = res.html ?? html;
    }
    return parseNotificationsFromHtml(html, baseUri: _origin);
  }

  @override
  Future<void> markNotificationsRead(String sessionCookie) async {
    await Anime3rbLivewireClient.callComponent(
      transport: _transport,
      pageUri: _uri('/user/profile'),
      componentName: 'notification.index-notifications',
      method: 'read',
      headers: _cookieHeaders(sessionCookie),
      operation: 'account_notifications_read',
    );
  }

  @override
  Future<
    ({
      List<Anime3rbReportIssueOption> issues,
      List<Anime3rbReportScopeOption> scopes,
      bool blocked,
      String? blockedMessage,
    })
  >
  fetchReportForm({
    required String sessionCookie,
    required Uri episodeUri,
  }) async {
    final pageResp = await _transport.get(
      episodeUri,
      headers: {
        'Accept':
            'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        ..._cookieHeaders(sessionCookie),
      },
      operation: 'report_form_page',
    );
    if (pageResp.statusCode == 401 ||
        Anime3rbLivewireClient.isLoginUri(pageResp.finalUri)) {
      throw const Anime3rbAuthRequiredException();
    }
    if (pageResp.isCloudflareChallenge) {
      throw Anime3rbBrowserRequiredException(
        'يتطلب فتح نموذج الإبلاغ إكمال التحقق من المتصفح.',
        watchUrl: episodeUri,
      );
    }
    final doc = html_parser.parse(pageResp.body);
    final comp = Anime3rbLivewireClient.findComponent(doc, 'video.report-issue');
    if (comp == null) {
      return const (
        issues: <Anime3rbReportIssueOption>[],
        scopes: Anime3rbReportScopeOption.defaults,
        blocked: false,
        blockedMessage: null,
      );
    }

    var snapshotJson = comp.snapshot;
    if (comp.lazyPayload != null) {
      final lazyRes = await Anime3rbLivewireClient.callComponent(
        transport: _transport,
        pageUri: pageResp.finalUri ?? episodeUri,
        componentName: 'video.report-issue',
        method: '__lazyLoad',
        params: <Object?>[comp.lazyPayload],
        snapshotOverride: comp.snapshot,
        csrfOverride: Anime3rbLivewireClient.extractCsrfToken(doc),
        updateUriOverride: Anime3rbLivewireClient.extractUpdateUri(
          doc,
          pageResp.finalUri ?? episodeUri,
        ),
        headers: _cookieHeaders(sessionCookie),
        operation: 'report_form_lazy',
      );
      if (lazyRes.snapshot != null && lazyRes.snapshot!.isNotEmpty) {
        snapshotJson = lazyRes.snapshot!;
      }
    }
    return parseReportFormFromSnapshot(snapshotJson);
  }

  @override
  Future<void> submitEpisodeReport({
    required String sessionCookie,
    required Uri episodeUri,
    required int issueId,
    required String scope,
    String? videosNumbers,
    String message = '',
  }) async {
    await Anime3rbLivewireClient.callComponent(
      transport: _transport,
      pageUri: episodeUri,
      componentName: 'video.report-issue',
      method: 'submit',
      params: <Object?>[
        <String, Object?>{
          'issue_id': issueId,
          'scope': scope,
          'videos_numbers': scope == 'multiple' ? videosNumbers : null,
          'message': message,
          'page_url': episodeUri.toString(),
          'user_agent': 'AnimeWitcher',
        },
      ],
      headers: _cookieHeaders(sessionCookie),
      operation: 'report_submit',
    );
  }

  @override
  Future<void> signOut(String sessionCookie) async {
    try {
      final profileResp = await _transport.get(
        _uri('/user/profile'),
        headers: _cookieHeaders(sessionCookie),
        operation: 'account_logout_csrf',
      );
      final doc = html_parser.parse(profileResp.body);
      final csrf = Anime3rbLivewireClient.extractCsrfToken(doc);
      if (csrf == null || csrf.isEmpty) return;
      await _transport.post(
        _uri('/logout'),
        body: '_token=${Uri.encodeQueryComponent(csrf)}',
        headers: <String, String>{
          'Content-Type': 'application/x-www-form-urlencoded',
          ..._cookieHeaders(sessionCookie),
        },
        operation: 'account_logout',
      );
    } catch (_) {
      // Best-effort remote sign-out.
    }
  }
}

@visibleForTesting
Anime3rbProfile? parseProfileFromHtml(
  String html, {
  Uri? baseUri,
  String? sessionCookie,
}) {
  final origin = baseUri ?? Uri.parse(Anime3rbProvider.originUrl);
  final doc = html_parser.parse(html);
  if (!Anime3rbLivewireClient.looksAuthenticatedDocument(doc, finalUri: baseUri)) {
    return null;
  }

  String? accountId;
  String? displayName;
  String? email;
  String? userSlug;
  String? avatarUrl;
  String? xtreamUsername;
  String? xtreamQuality;
  final watchingProgress = <String, Anime3rbWatchingProgress>{};

  final profileComp = Anime3rbLivewireClient.findComponent(
    doc,
    'profile.update-profile-information-form',
  );
  final snapshotMap = profileComp?.decodedSnapshot;
  if (snapshotMap != null) {
    final data = snapshotMap['data'];
    if (data is Map) {
      final photoUrl = data['profile_photo_url']?.toString().trim();
      if (photoUrl != null && photoUrl.isNotEmpty) {
        avatarUrl = origin.resolve(photoUrl).toString();
      }
      final rawState = data['state'];
      final stateMap = switch (rawState) {
        List list when list.isNotEmpty && list.first is Map =>
          Map<String, dynamic>.from(list.first as Map),
        Map map => Map<String, dynamic>.from(map),
        _ => null,
      };
      if (stateMap != null) {
        accountId = stateMap['id']?.toString().trim();
        displayName = stateMap['name']?.toString().trim();
        userSlug = stateMap['slug']?.toString().trim();
        email = stateMap['email']?.toString().trim();
        if ((avatarUrl == null || avatarUrl.isEmpty) &&
            stateMap['profile_photo_path'] != null) {
          final path = stateMap['profile_photo_path'].toString().trim();
          if (path.isNotEmpty) {
            avatarUrl = origin.resolve('/storage/$path').toString();
          }
        }
        if ((avatarUrl == null || avatarUrl.isEmpty) &&
            stateMap['profile_photo_url'] != null) {
          final url = stateMap['profile_photo_url'].toString().trim();
          if (url.isNotEmpty) {
            avatarUrl = origin.resolve(url).toString();
          }
        }
        _extractWatchingListFromState(stateMap['data'], watchingProgress);
      }
    }
  }

  final iptvComp = Anime3rbLivewireClient.findComponent(
    doc,
    'profile.iptv-credentials',
  );
  final iptvData = iptvComp?.decodedSnapshot?['data'];
  if (iptvData is Map) {
    xtreamUsername = iptvData['xtream_username']?.toString().trim();
    xtreamQuality = iptvData['xtream_quality']?.toString().trim();
  }

  // Fallback header link extraction: /titles/{userSlug}/watching
  if (userSlug == null || userSlug.isEmpty) {
    for (final a in doc.querySelectorAll('a[href*="/titles/"]')) {
      final href = a.attributes['href']?.trim() ?? '';
      final uri = origin.resolve(href);
      final segs = uri.pathSegments.where((s) => s.isNotEmpty).toList();
      if (segs.length == 3 &&
          segs[0] == 'titles' &&
          (segs[2] == 'watching' || segs[2] == 'ratings')) {
        userSlug = segs[1];
        break;
      }
    }
  }

  if (displayName == null || displayName.isEmpty) {
    displayName = doc
        .querySelector('input[name="name"], input[wire\\:model*="state.name"]')
        ?.attributes['value']
        ?.trim();
  }
  displayName ??= userSlug;
  userSlug ??= accountId;
  accountId ??= userSlug;
  if (userSlug == null ||
      userSlug.isEmpty ||
      displayName == null ||
      displayName.isEmpty ||
      accountId == null ||
      accountId.isEmpty) {
    return null;
  }

  if (sessionCookie != null && sessionCookie.isNotEmpty) {
    final cookieMap = _parseWatchingListFromCookie(sessionCookie);
    for (final entry in cookieMap.entries) {
      final existing = watchingProgress[entry.key];
      if (existing == null ||
          entry.value.updatedAtMillis >= existing.updatedAtMillis) {
        watchingProgress[entry.key] = entry.value;
      }
    }
  }

  var unreadCount = 0;
  final notifIconText =
      doc
          .querySelector('[wire\\:name="notification.notifications-icon"] .sr-only')
          ?.text ??
      doc
          .querySelector('[wire\\:name="notification.notifications-icon"]')
          ?.text ??
      '';
  final numMatch = RegExp(
    r'(\d+)',
  ).firstMatch(normalizeLocalizedDigits(notifIconText));
  if (numMatch != null) {
    unreadCount = int.tryParse(numMatch.group(1)!) ?? 0;
  }

  return Anime3rbProfile(
    accountId: accountId,
    userSlug: userSlug,
    displayName: displayName,
    email: (email != null && email.isNotEmpty) ? email : null,
    avatarUrl: avatarUrl,
    xtreamUsername: (xtreamUsername != null && xtreamUsername.isNotEmpty)
        ? xtreamUsername
        : null,
    xtreamQuality: (xtreamQuality != null && xtreamQuality.isNotEmpty)
        ? xtreamQuality
        : null,
    unreadNotifications: unreadCount,
    watchingProgress: watchingProgress,
  );
}

void _extractWatchingListFromState(
  Object? rawUserData,
  Map<String, Anime3rbWatchingProgress> out,
) {
  final userDataMap = switch (rawUserData) {
    List list when list.isNotEmpty && list.first is Map =>
      Map<String, dynamic>.from(list.first as Map),
    Map map => Map<String, dynamic>.from(map),
    _ => null,
  };
  if (userDataMap == null) return;
  final rawWatching = userDataMap['watching-list'];
  final watchingMap = switch (rawWatching) {
    List list when list.isNotEmpty && list.first is Map =>
      Map<String, dynamic>.from(list.first as Map),
    Map map => Map<String, dynamic>.from(map),
    _ => null,
  };
  if (watchingMap == null) return;
  for (final entry in watchingMap.entries) {
    if (entry.key == 'updated_at') continue;
    final value = entry.value is List && (entry.value as List).isNotEmpty
        ? (entry.value as List).first
        : entry.value;
    final parsed = Anime3rbWatchingProgress.fromJson(entry.key, value);
    if (parsed != null) out[parsed.slug] = parsed;
  }
}

Map<String, Anime3rbWatchingProgress> _parseWatchingListFromCookie(
  String cookieHeader,
) {
  for (final part in cookieHeader.split(';')) {
    final eq = part.indexOf('=');
    if (eq <= 0) continue;
    final name = part.substring(0, eq).trim();
    if (name != 'watching-list') continue;
    var raw = part.substring(eq + 1).trim();
    try {
      raw = Uri.decodeComponent(raw);
    } catch (_) {}
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const <String, Anime3rbWatchingProgress>{};
      final out = <String, Anime3rbWatchingProgress>{};
      for (final entry in decoded.entries) {
        final key = entry.key.toString();
        if (key == 'updated_at') continue;
        final parsed = Anime3rbWatchingProgress.fromJson(key, entry.value);
        if (parsed != null) out[parsed.slug] = parsed;
      }
      return out;
    } catch (_) {
      return const <String, Anime3rbWatchingProgress>{};
    }
  }
  return const <String, Anime3rbWatchingProgress>{};
}

@visibleForTesting
List<Anime3rbNotificationItem> parseNotificationsFromHtml(
  String html, {
  Uri? baseUri,
}) {
  final origin = baseUri ?? Uri.parse(Anime3rbProvider.originUrl);
  final doc = html_parser.parse(html);
  final items = <Anime3rbNotificationItem>[];
  for (final anchor in doc.querySelectorAll('a[href]')) {
    final href = anchor.attributes['href']?.trim() ?? '';
    if (href.isEmpty || href == '#') continue;
    final text = anchor.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isEmpty || text == 'لا إشعارات') continue;
    final unread =
        anchor.classes.any((c) => c.contains('bg-') || c.contains('unread')) ||
        anchor.querySelector('.bg-primary-500, .bg-blue-500') != null;
    items.add(
      Anime3rbNotificationItem(
        id: '${items.length}_$href',
        title: text,
        url: origin.resolve(href).toString(),
        unread: unread,
      ),
    );
  }
  return items;
}

@visibleForTesting
({
  List<Anime3rbReportIssueOption> issues,
  List<Anime3rbReportScopeOption> scopes,
  bool blocked,
  String? blockedMessage,
})
parseReportFormFromSnapshot(String snapshotJson) {
  try {
    final decoded = jsonDecode(snapshotJson);
    if (decoded is! Map) {
      return const (
        issues: <Anime3rbReportIssueOption>[],
        scopes: Anime3rbReportScopeOption.defaults,
        blocked: false,
        blockedMessage: null,
      );
    }
    final data = decoded['data'];
    if (data is! Map) {
      return const (
        issues: <Anime3rbReportIssueOption>[],
        scopes: Anime3rbReportScopeOption.defaults,
        blocked: false,
        blockedMessage: null,
      );
    }
    final list = Anime3rbReportIssueOption.unwrapLivewireList(data['issuesTree']);
    final issues = <Anime3rbReportIssueOption>[];
    for (final raw in list) {
      final parsed = Anime3rbReportIssueOption.fromJson(raw);
      if (parsed != null) issues.add(parsed);
    }
    return (
      issues: issues,
      scopes: Anime3rbReportScopeOption.defaults,
      blocked: data['reportingBlocked'] == true,
      blockedMessage: data['reportingBlockedMessage']?.toString(),
    );
  } catch (_) {
    return const (
      issues: <Anime3rbReportIssueOption>[],
      scopes: Anime3rbReportScopeOption.defaults,
      blocked: false,
      blockedMessage: null,
    );
  }
}

class Anime3rbAccountService extends ChangeNotifier {
  Anime3rbAccountService({
    required SecureTokenStorage tokenStorage,
    required Anime3rbAccountBackend backend,
    Future<bool> Function(Uri)? openWebsite,
  }) : _tokenStorage = tokenStorage,
       _backend = backend,
       _openWebsite = openWebsite ?? _defaultOpenWebsite;

  final SecureTokenStorage _tokenStorage;
  final Anime3rbAccountBackend _backend;
  final Future<bool> Function(Uri) _openWebsite;

  Anime3rbAccountSession? _session;
  bool _busy = false;
  bool _storageUnavailable = false;
  String? _pendingReturnRoute;
  VoidCallback? _onSessionInvalidated;

  static Future<bool> _defaultOpenWebsite(Uri uri) =>
      launchUrl(uri, mode: LaunchMode.externalApplication);

  Anime3rbAccountSession? get session => _session;
  Anime3rbProfile? get profile => _session?.profile;
  bool get isSignedIn => _session != null;
  String? get accountId => _session?.accountId;
  bool get isBusy => _busy;
  bool get usingInMemorySessionFallback => _storageUnavailable;
  String? get pendingReturnRoute => _pendingReturnRoute;

  void setOnSessionInvalidated(VoidCallback? callback) {
    _onSessionInvalidated = callback;
  }

  static Uri officialAuthUri(Anime3rbAuthAction action) => switch (action) {
    Anime3rbAuthAction.signIn => Anime3rbProvider.websiteUri('/login'),
    Anime3rbAuthAction.register => Anime3rbProvider.websiteUri('/register'),
    Anime3rbAuthAction.forgotPassword => Anime3rbProvider.websiteUri(
      '/forgot-password',
    ),
  };

  /// Returns a Cookie header containing the user's session cookies plus the
  /// synchronized `watching-list` progress cookie when available.
  String requestCookieHeader() {
    final current = _session;
    if (current == null) return '';
    return _withUpdatedWatchingCookie(
      current.sessionCookie,
      current.profile.watchingProgress,
    );
  }

  static String _withUpdatedWatchingCookie(
    String baseCookie,
    Map<String, Anime3rbWatchingProgress> progressMap,
  ) {
    if (progressMap.isEmpty) return baseCookie;
    final parts = <String>[];
    for (final raw in baseCookie.split(';')) {
      final eq = raw.indexOf('=');
      if (eq <= 0) continue;
      final name = raw.substring(0, eq).trim();
      final value = raw.substring(eq + 1).trim();
      if (name.isEmpty || value.isEmpty || name == 'watching-list') continue;
      parts.add('$name=$value');
    }
    var latestAt = 0;
    final jsonMap = <String, Object?>{};
    for (final entry in progressMap.values) {
      jsonMap[entry.slug] = entry.toCookieJson();
      if (entry.updatedAtMillis > latestAt) latestAt = entry.updatedAtMillis;
    }
    jsonMap['updated_at'] = latestAt > 0
        ? latestAt
        : DateTime.now().millisecondsSinceEpoch;
    parts.add('watching-list=${Uri.encodeComponent(jsonEncode(jsonMap))}');
    return parts.join('; ');
  }

  Future<void> restoreSession() async {
    try {
      final raw = await _tokenStorage.read(kAnime3rbSessionStorageKey);
      final restored = Anime3rbAccountSession.tryDecode(raw);
      if (restored != null && _session == null) {
        _session = restored;
        notifyListeners();
      }
    } catch (error) {
      _storageUnavailable = true;
      recordAnime3rbDiagnostic(
        'session_restore',
        status: 'memory_fallback',
        durationMs: 0,
        errorType: classifyAnime3rbFailure(error),
      );
    }
  }

  Future<void> _persistSession(Anime3rbAccountSession session) async {
    _session = session;
    try {
      await _tokenStorage.write(kAnime3rbSessionStorageKey, session.encode());
      _storageUnavailable = false;
    } catch (error) {
      _storageUnavailable = true;
      recordAnime3rbDiagnostic(
        'session_write',
        status: 'memory_fallback',
        durationMs: 0,
        errorType: classifyAnime3rbFailure(error),
      );
    }
    notifyListeners();
  }

  void recordPendingAuthReturnRoute(String? returnRoute) {
    _pendingReturnRoute = returnRoute;
  }

  Future<bool> beginOfficialAuth(
    Anime3rbAuthAction action, {
    String? returnRoute,
  }) async {
    _pendingReturnRoute = returnRoute;
    return _openWebsite(officialAuthUri(action));
  }

  Future<Anime3rbAuthResult?> _verifyAndPersistSession({
    required String sessionCookie,
    String? csrfToken,
  }) async {
    _busy = true;
    notifyListeners();
    try {
      final verified = await _backend.fetchProfile(sessionCookie);
      if (verified == null) return null;
      final next = Anime3rbAccountSession(
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

  Future<Anime3rbAuthResult?> tryCompleteBrowserAuth({
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

  Future<Anime3rbAuthResult> completeBrowserAuth({
    required String sessionCookie,
    String? csrfToken,
  }) async {
    final trimmed = sessionCookie.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('يرجى إدخال كوكي جلسة Anime3rb.');
    }
    final result = await _verifyAndPersistSession(
      sessionCookie: trimmed,
      csrfToken: csrfToken,
    );
    if (result == null) {
      throw StateError('تعذر تأكيد هوية حساب Anime3rb بهذه الجلسة.');
    }
    return result;
  }

  Future<Anime3rbProfile?> refreshProfile() async {
    final current = _session;
    if (current == null) return null;
    final fetched = await _backend.fetchProfile(requestCookieHeader());
    if (fetched == null) {
      await signOut(notifyRemote: false);
      return null;
    }
    if (_session?.accountId != current.accountId) return _session?.profile;
    final mergedProgress = Map<String, Anime3rbWatchingProgress>.from(
      current.profile.watchingProgress,
    )..addAll(fetched.watchingProgress);
    final updatedProfile = fetched.copyWith(
      counts: current.profile.counts,
      watchingProgress: mergedProgress,
    );
    await _persistSession(
      current.copyWith(
        profile: updatedProfile,
        updatedAtMillis: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    return updatedProfile;
  }

  Future<void> updateCachedCounts(Anime3rbListCounts counts) async {
    final current = _session;
    if (current == null) return;
    await _persistSession(
      current.copyWith(
        profile: current.profile.copyWith(counts: counts),
        updatedAtMillis: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  Future<void> updateComntoToken({
    required String? token,
    String? refreshToken,
  }) async {
    final current = _session;
    if (current == null) return;
    await _persistSession(
      current.copyWith(
        comntoToken: token,
        comntoRefreshToken: refreshToken,
        clearComnto: token == null || token.isEmpty,
      ),
    );
  }

  Future<void> recordEpisodeProgress({
    required String animeUrl,
    required int episodeNumber,
    required double timeSeconds,
    required double progressPercent,
  }) async {
    final current = _session;
    if (current == null || episodeNumber <= 0) return;
    final slug = Anime3rbProvider.slugFromUrl(animeUrl);
    if (slug == null || slug.isEmpty) return;
    final nextProgress = Map<String, Anime3rbWatchingProgress>.from(
      current.profile.watchingProgress,
    );
    nextProgress[slug] = Anime3rbWatchingProgress(
      slug: slug,
      episodeNumber: episodeNumber,
      timeSeconds: timeSeconds,
      progressPercent: progressPercent.clamp(0.0, 100.0),
      updatedAtMillis: DateTime.now().millisecondsSinceEpoch,
    );
    await _persistSession(
      current.copyWith(
        profile: current.profile.copyWith(watchingProgress: nextProgress),
      ),
    );
  }

  Future<Anime3rbProfile> updateProfile({
    required String displayName,
    required String email,
  }) async {
    final current = _session;
    if (current == null) {
      throw const Anime3rbAuthRequiredException();
    }
    _busy = true;
    notifyListeners();
    try {
      final updated = await _backend.updateProfile(
        sessionCookie: current.sessionCookie,
        displayName: displayName,
        email: email,
      );
      await _persistSession(
        current.copyWith(
          profile: updated.copyWith(
            counts: current.profile.counts,
            watchingProgress: current.profile.watchingProgress,
          ),
          updatedAtMillis: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      return _session!.profile;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> updatePassword({
    required String currentPassword,
    required String password,
    required String passwordConfirmation,
  }) async {
    final current = _session;
    if (current == null) {
      throw const Anime3rbAuthRequiredException();
    }
    _busy = true;
    notifyListeners();
    try {
      await _backend.updatePassword(
        sessionCookie: current.sessionCookie,
        currentPassword: currentPassword,
        password: password,
        passwordConfirmation: passwordConfirmation,
      );
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> logoutOtherBrowserSessions(String password) async {
    final current = _session;
    if (current == null) {
      throw const Anime3rbAuthRequiredException();
    }
    _busy = true;
    notifyListeners();
    try {
      await _backend.logoutOtherBrowserSessions(
        sessionCookie: current.sessionCookie,
        password: password,
      );
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<List<Anime3rbNotificationItem>> fetchNotifications() async {
    final current = _session;
    if (current == null) {
      throw const Anime3rbAuthRequiredException();
    }
    return _backend.fetchNotifications(current.sessionCookie);
  }

  Future<void> markNotificationsRead() async {
    final current = _session;
    if (current == null) return;
    await _backend.markNotificationsRead(current.sessionCookie);
    await _persistSession(
      current.copyWith(
        profile: current.profile.copyWith(unreadNotifications: 0),
      ),
    );
  }

  Future<
    ({
      List<Anime3rbReportIssueOption> issues,
      List<Anime3rbReportScopeOption> scopes,
      bool blocked,
      String? blockedMessage,
    })
  >
  fetchReportForm(Uri episodeUri) async {
    final current = _session;
    if (current == null) {
      throw const Anime3rbAuthRequiredException();
    }
    return _backend.fetchReportForm(
      sessionCookie: current.sessionCookie,
      episodeUri: episodeUri,
    );
  }

  Future<void> submitEpisodeReport({
    required Uri episodeUri,
    required int issueId,
    required String scope,
    String? videosNumbers,
    String message = '',
  }) async {
    final current = _session;
    if (current == null) {
      throw const Anime3rbAuthRequiredException();
    }
    await _backend.submitEpisodeReport(
      sessionCookie: current.sessionCookie,
      episodeUri: episodeUri,
      issueId: issueId,
      scope: scope,
      videosNumbers: videosNumbers,
      message: message,
    );
  }

  Future<void> signOut({bool notifyRemote = true}) async {
    final current = _session;
    _session = null;
    _pendingReturnRoute = null;
    if (notifyRemote && current != null) {
      await _backend.signOut(current.sessionCookie);
    }
    try {
      await _tokenStorage.delete(kAnime3rbSessionStorageKey);
    } catch (_) {}
    _onSessionInvalidated?.call();
    notifyListeners();
  }
}

final anime3rbTransportProvider = Provider<Anime3rbTransport>((ref) {
  final transport = DioAnime3rbTransport(
    sessionHeaders: (_) async {
      final cookie = ref
          .read(anime3rbAccountServiceProvider)
          .requestCookieHeader();
      return cookie.isEmpty
          ? const <String, String>{}
          : <String, String>{'Cookie': cookie};
    },
    challengeResolver: (uri, {currentCookies = const <String, String>{}}) =>
        Anime3rbWebViewSolver.instance.solveCloudflareChallenge(
          uri,
          currentCookies: currentCookies,
        ),
  );
  ref.onDispose(() => transport.close(force: true));
  return transport;
});

final anime3rbAccountServiceProvider = Provider<Anime3rbAccountService>((ref) {
  final transport = DioAnime3rbTransport();
  late final SecureTokenStorage tokenStorage;
  try {
    tokenStorage = ref.watch(secureTokenStorageProvider);
  } catch (_) {
    tokenStorage = SecureTokenStorage(_FallbackInMemoryStorage());
  }
  final service = Anime3rbAccountService(
    tokenStorage: tokenStorage,
    backend: HttpAnime3rbAccountBackend(transport),
  );
  unawaited(service.restoreSession());
  ref.onDispose(() {
    transport.close(force: true);
    service.dispose();
  });
  return service;
});

final anime3rbAccountRevisionProvider =
    NotifierProvider<_Anime3rbAccountRevisionNotifier, int>(
      _Anime3rbAccountRevisionNotifier.new,
    );

class _Anime3rbAccountRevisionNotifier extends Notifier<int> {
  @override
  int build() {
    final service = ref.watch(anime3rbAccountServiceProvider);
    void onChanged() => state++;
    service.addListener(onChanged);
    ref.onDispose(() => service.removeListener(onChanged));
    return 0;
  }
}

class _FallbackInMemoryStorage extends StorageService {}
