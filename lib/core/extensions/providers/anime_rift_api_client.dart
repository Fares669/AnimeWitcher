import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../network/stale_connection_retry.dart';
import '../../storage/anime_rift_account_scope.dart';
import 'anime_rift_device_descriptor.dart';

class AnimeRiftConfig {
  const AnimeRiftConfig({
    this.firebaseApiKey = const String.fromEnvironment(
      'ANIMERIFT_FIREBASE_API_KEY',
    ),
    this.firebaseAppId = const String.fromEnvironment(
      'ANIMERIFT_FIREBASE_APP_ID',
    ),
    this.signingKey = const String.fromEnvironment('ANIMERIFT_JWT_SECRET'),
  });

  final String firebaseApiKey;
  final String firebaseAppId;
  final String signingKey;
  bool get isConfigured =>
      firebaseApiKey.isNotEmpty &&
      firebaseAppId.isNotEmpty &&
      signingKey.isNotEmpty;

  @override
  String toString() => 'AnimeRiftConfig(configured: $isConfigured)';
}

class AnimeRiftAccessUnavailable implements Exception {
  const AnimeRiftAccessUnavailable({this.statusCode, this.stage, this.failure});
  final int? statusCode;
  final AnimeRiftRequestStage? stage;
  final AnimeRiftFailureKind? failure;

  /// Only known operation labels and an HTTP status are displayed. Never a
  /// gateway response, URL, session token, or request headers.
  String get _safeDiagnostic {
    final operation = switch (stage) {
      AnimeRiftRequestStage.deviceRegistration => 'تسجيل الجهاز',
      AnimeRiftRequestStage.episodeSources => 'قائمة مصادر الحلقة',
      AnimeRiftRequestStage.sourceAvailability => 'صلاحية التشغيل أو التنزيل',
      AnimeRiftRequestStage.directLink => 'استخراج رابط الحلقة',
      AnimeRiftRequestStage.other => 'طلب بيانات Anime Rift',
      null => null,
    };
    final details = <String>[
      if (operation != null) operation,
      if (statusCode != null) 'HTTP $statusCode',
      if (failure != null)
        switch (failure!) {
          AnimeRiftFailureKind.configuration => 'إعدادات الربط غير مكتملة',
          AnimeRiftFailureKind.transport => 'تعذر الوصول إلى الشبكة',
          AnimeRiftFailureKind.invalidResponse => 'استجابة غير صالحة',
        },
    ];
    return details.isEmpty ? '' : ' (${details.join('، ')})';
  }

  @override
  String toString() =>
      'تعذر الاتصال بخدمة Anime Rift$_safeDiagnostic. تحقق من إعدادات المزوّد ثم أعد المحاولة.';
}

enum AnimeRiftRequestStage {
  deviceRegistration,
  episodeSources,
  sourceAvailability,
  directLink,
  other,
}

enum AnimeRiftFailureKind { configuration, transport, invalidResponse }

class AnimeRiftAuthenticationRequired extends AnimeRiftAccessUnavailable {
  const AnimeRiftAuthenticationRequired({super.statusCode});

  @override
  String toString() =>
      'يتطلب هذا الإجراء تسجيل الدخول إلى حساب Anime Rift. حساب AnimeWitcher مستقل عنه.';
}

class AnimeRiftSecureStorageUnavailable extends AnimeRiftAccessUnavailable {
  const AnimeRiftSecureStorageUnavailable();

  @override
  String toString() =>
      'تعذر الوصول إلى التخزين الآمن لجلسة Anime Rift. لم يتم حفظ رمز الدخول.';
}

/// Extracts the numeric overview counters found in Rift's shipped AOT.
///
/// The endpoint returns an `items` map. Missing or malformed counters are
/// omitted rather than mislabeled as zero; this is not an anime-item parser.
Map<String, int> parseMyListOverviewCounts(Map<String, dynamic> response) {
  final items = response['items'];
  if (items is! Map) return <String, int>{};

  const keys = <String>[
    'my_list_favorites',
    'my_list_currently_watching',
    'my_list_plan_to_watch',
    'my_list_finished_watching',
    'my_list_on_hold',
    'my_list_dropped',
    'favorite_characters_count',
  ];
  final result = <String, int>{};
  for (final key in keys) {
    final value = items[key];
    final parsed = value is int
        ? value
        : value is String && RegExp(r'^\d+$').hasMatch(value)
        ? int.tryParse(value)
        : null;
    if (parsed != null && parsed >= 0) result[key] = parsed;
  }
  return result;
}

/// Only verified identity fields are retained. Rift's full profile is not
/// needed for authentication or local storage partitioning.
class AnimeRiftAccountIdentity {
  const AnimeRiftAccountIdentity({
    required this.id,
    this.displayName,
    this.isVerified = true,
  });

  final String id;
  final String? displayName;

  /// Old secure sessions lacked a profile ID. Their partition is token-based.
  final bool isVerified;

  static String? _safeField(Object? value, {int maxLength = 256}) {
    if (value is! String) return null;
    final text = value.trim();
    return text.isNotEmpty &&
            text.length <= maxLength &&
            !text.contains(RegExp(r'[\x00-\x1f\x7f]'))
        ? text
        : null;
  }

  static AnimeRiftAccountIdentity? fromProfile(Map<dynamic, dynamic> profile) {
    String? id;
    for (final key in const ['_id', 'id', 'userId', 'user_id']) {
      id = _safeField(profile[key]);
      if (id != null) break;
    }
    if (id == null) return null;
    String? name;
    for (final key in const ['displayName', 'username', 'name']) {
      name = _safeField(profile[key], maxLength: 120);
      if (name != null) break;
    }
    return AnimeRiftAccountIdentity(id: id, displayName: name);
  }
}

/// Isolated, experimental catalog transport. Never inherits account credentials.
/// The embedded compatibility signing configuration is extractable from binaries;
/// it must not be treated as a server-side secret or used for account privileges.
class AnimeRiftApiClient {
  AnimeRiftApiClient({
    this.config = const AnimeRiftConfig(),
    Dio? dio,
    FlutterSecureStorage? secureStorage,
    Future<AnimeRiftDeviceDescriptor> Function(String legacyBuildId)?
    deviceDescriptorLoader,
  }) : _dio = dio ?? createAnimeWitcherDio(),
       _secureStorage = secureStorage ?? _defaultSecureStorage,
       _loadDeviceDescriptor =
           deviceDescriptorLoader ?? AnimeRiftDeviceDescriptor.detect;

  final AnimeRiftConfig config;
  final Dio _dio;
  final FlutterSecureStorage _secureStorage;
  final Future<AnimeRiftDeviceDescriptor> Function(String legacyBuildId)
  _loadDeviceDescriptor;
  AnimeRiftDeviceDescriptor? _deviceDescriptor;
  static const _identityKey = 'animerift.api.installation.v1';
  static const _sessionKey = 'animerift.user.session.v1';
  static const _defaultBase = 'https://gateway.embrassme.top/api/v4';
  static const _defaultSecureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(
      storageNamespace: 'animerift_auth',
      resetOnError: false,
    ),
    iOptions: IOSOptions(
      accountName: 'com.animewitcher.animerift.auth',
      accessibility: KeychainAccessibility.first_unlock_this_device,
      synchronizable: false,
    ),
    mOptions: MacOsOptions(
      accountName: 'com.animewitcher.animerift.auth',
      accessibility: KeychainAccessibility.first_unlock_this_device,
      synchronizable: false,
    ),
  );
  static final _random = Random.secure();
  String _base = _defaultBase;
  Map<String, String>? _identity;
  String? _accessToken;
  AnimeRiftAccountIdentity? _accountIdentity;
  Future<void>? _identityLoading;
  Future<bool>? _restoringSession;
  Future<void> _pendingSessionStorage = Future<void>.value();
  int _sessionEpoch = 0;
  bool _sessionRestoreAttempted = false;
  Future<void>? _initializing;
  bool _registered = false;
  bool get isConfigured => config.isConfigured;
  bool get isAccountLinked => _accessToken != null;
  AnimeRiftAccountIdentity? get accountIdentity => _accountIdentity;

  static String _randomText(int length) {
    const alphabet =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    return List.generate(
      length,
      (_) => alphabet[_random.nextInt(alphabet.length)],
    ).join();
  }

  Future<void> _loadIdentity() {
    if (_identity != null) return Future<void>.value();
    return _identityLoading ??= _loadIdentityOnce().whenComplete(() {
      _identityLoading = null;
    });
  }

  Future<void> _loadIdentityOnce() async {
    if (_identity != null) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_identityKey);
    if (raw != null) {
      try {
        final value = Map<String, String>.from(jsonDecode(raw) as Map);
        if ([
          'fid',
          'deviceId',
          'buildId',
        ].every((k) => value[k]?.isNotEmpty == true)) {
          _identity = value;
          return;
        }
      } catch (_) {
        // Recover only this provider's corrupt installation descriptor.
      }
    }
    final fid = _randomText(22);
    _identity = {
      'fid': fid,
      'deviceId': '$fid:APA91b${_randomText(80)}',
      'buildId': 'AP2A.240805.${100000 + _random.nextInt(899999)}.015',
    };
    await prefs.setString(_identityKey, jsonEncode(_identity));
  }

  Future<Map<String, dynamic>> _send(
    String url, {
    required Map<String, String> headers,
    String method = 'GET',
    Object? body,
    Map<String, dynamic>? query,
    CancelToken? cancelToken,
    int? expectedStatus,
  }) async {
    final stage = _requestStage(url);
    try {
      final response = await _dio.request<dynamic>(
        url,
        data: body,
        queryParameters: query,
        cancelToken: cancelToken,
        options: Options(
          method: method,
          headers: headers,
          followRedirects: false,
          sendTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 30),
          validateStatus: (_) => true,
        ),
      );
      final status = response.statusCode ?? 0;
      if (status < 200 ||
          status >= 300 ||
          (expectedStatus != null && status != expectedStatus)) {
        throw AnimeRiftAccessUnavailable(statusCode: status, stage: stage);
      }
      final dynamic value = response.data is String
          ? jsonDecode(response.data as String)
          : response.data;
      if (value is! Map) {
        throw AnimeRiftAccessUnavailable(
          stage: stage,
          failure: AnimeRiftFailureKind.invalidResponse,
        );
      }
      return Map<String, dynamic>.from(value);
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) rethrow;
      throw AnimeRiftAccessUnavailable(
        statusCode: e.response?.statusCode,
        stage: stage,
        failure: e.response == null ? AnimeRiftFailureKind.transport : null,
      );
    } on AnimeRiftAccessUnavailable {
      rethrow;
    } catch (_) {
      throw AnimeRiftAccessUnavailable(
        stage: stage,
        failure: AnimeRiftFailureKind.invalidResponse,
      );
    }
  }

  static AnimeRiftRequestStage _requestStage(String url) {
    final path = Uri.tryParse(url)?.path;
    return switch (path) {
      '/api/v4/auth/register/device' =>
        AnimeRiftRequestStage.deviceRegistration,
      '/api/v4/library/episode/sources' => AnimeRiftRequestStage.episodeSources,
      '/api/v4/library/episode/source/can_play' =>
        AnimeRiftRequestStage.sourceAvailability,
      '/api/v4/library/episode/source/direct_link' =>
        AnimeRiftRequestStage.directLink,
      _ => AnimeRiftRequestStage.other,
    };
  }

  Future<void> _firebaseConfiguration() async {
    final appParts = config.firebaseAppId.split(':');
    if (appParts.length < 3 || !RegExp(r'^\d+$').hasMatch(appParts[1])) return;
    final project = appParts[1];
    final headers = {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'x-goog-api-key': config.firebaseApiKey,
    };
    try {
      final installation = await _send(
        'https://firebaseinstallations.googleapis.com/v1/projects/$project/installations',
        headers: headers,
        method: 'POST',
        body: {
          'fid': _identity!['fid'],
          'appId': config.firebaseAppId,
          'authVersion': 'FIS_v2',
          'sdkVersion': 'a:19.1.0',
        },
      );
      final fid = installation['fid'];
      final auth = installation['authToken'];
      final token = auth is Map ? auth['token'] : null;
      if (fid is! String || fid.isEmpty || token is! String || token.isEmpty) {
        return;
      }
      _identity!['fid'] = fid;
      _identity!['deviceId'] =
          '$fid:${_identity!['deviceId']!.split(':').last}';
      final remote = await _send(
        'https://firebaseremoteconfig.googleapis.com/v1/projects/$project/namespaces/firebase:fetch',
        method: 'POST',
        headers: {...headers, 'X-Goog-Firebase-Installations-Auth': token},
        body: {
          'appId': config.firebaseAppId,
          'appInstanceId': fid,
          'appInstanceIdToken': token,
          'appVersion': '3.13.5',
          'appBuild': '68',
          'sdkVersion': '23.0.1',
          'packageName': 'com.riftapps.animerift',
          'analyticsUserProperties': <String, String>{},
        },
      );
      final entries = remote['entries'];
      final candidate = entries is Map
          ? entries['anime_rift_android_gateway_base_url_v4']
          : null;
      final uri = candidate is String
          ? Uri.tryParse(candidate.replaceAll('"', ''))
          : null;
      if (uri != null &&
          uri.scheme == 'https' &&
          const {
            'gateway.anime-rift.com',
            'gateway.embrassme.top',
          }.contains(uri.host) &&
          uri.userInfo.isEmpty &&
          !uri.hasQuery &&
          !uri.hasFragment &&
          (!uri.hasPort || uri.port == 443) &&
          uri.path == '/api/v4') {
        _base = uri.toString();
      }
    } on AnimeRiftAccessUnavailable {
      // Firebase is optional for the tested gateway registration path. A failed
      // configuration fetch does not authorize a fallback to another provider.
    }
  }

  Map<String, String> _headers(String scope, {bool includeUserToken = true}) {
    final device = _deviceDescriptor!;
    String encode(Object value) =>
        base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final unsigned =
        '${encode({'alg': 'HS256', 'typ': 'JWT'})}.${encode({'scope': scope, 'exp': now + 60, 'iat': now})}';
    final signature = base64Url
        .encode(
          Hmac(
            sha256,
            utf8.encode(config.signingKey),
          ).convert(utf8.encode(unsigned)).bytes,
        )
        .replaceAll('=', '');
    return {
      'x-device-os-id': device.osId,
      'user-agent': 'Dart/3.10 (dart:io)',
      'x-device-release-version': '3.13.5',
      'x-firebase-app-check': 'null',
      'authorization': 'Bearer ${includeUserToken ? _accessToken : null}',
      'content-type': 'application/json; charset=UTF-8',
      if (device.installSource case final source?)
        'x-installation-source': source,
      'integrity': 'Bearer $unsigned.$signature',
      'accept': 'application/json',
      'x-firebase-id': _identity!['fid']!,
      'x-device-id': _identity!['deviceId']!,
      'x-device-timezone': DateTime.now().toIso8601String(),
      'x-device-language': 'ar',
      'x-platform': 'Mobile',
      'x-os': device.os,
    };
  }

  Future<void> _initialize() async {
    await _loadIdentity();
    try {
      await restoreAccountSession();
    } on AnimeRiftSecureStorageUnavailable {
      // Public catalogue access remains available as a guest. Explicit account
      // actions still surface the secure-storage failure to the user.
    }
    await _firebaseConfiguration();
    // Read the actual Android/iOS platform information. The legacy synthetic
    // Android descriptor remains in use only on other operating systems.
    final device = await _loadDeviceDescriptor(_identity!['buildId']!);
    _deviceDescriptor = device;
    await _send(
      '$_base/auth/register/device',
      headers: _headers('USER.AUTH.DEVICE.REGISTER'),
      method: 'POST',
      body: {
        'deviceId': _identity!['deviceId'],
        'current_app_version': '3.13.5',
        'device_os': device.os,
        'device_environment': 'production',
        'device_info': jsonEncode(device.details),
        if (device.installSource case final source?) 'install_source': source,
        'deviceOsId': device.osId,
        'firebaseInstallationId': _identity!['fid'],
        'apn_token': null,
        'install_mode': 2,
      },
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_identityKey, jsonEncode(_identity));
    _registered = true;
  }

  Future<void> _ensureReady() async {
    if (!isConfigured) {
      throw const AnimeRiftAccessUnavailable(
        failure: AnimeRiftFailureKind.configuration,
      );
    }
    if (_registered) return;
    final pending = _initializing ??= _initialize();
    try {
      await pending;
    } finally {
      if (identical(_initializing, pending)) _initializing = null;
    }
  }

  static bool _validAccessToken(String value) =>
      value.isNotEmpty &&
      value.length <= 8192 &&
      !value.contains(RegExp(r'[\x00-\x20\x7f]'));

  Future<T> _withSessionStorage<T>(Future<T> Function() action) async {
    final previous = _pendingSessionStorage;
    final completed = Completer<void>();
    _pendingSessionStorage = completed.future;
    await previous;
    try {
      return await action();
    } finally {
      completed.complete();
    }
  }

  Future<bool> restoreAccountSession() =>
      _restoringSession ??= _restoreAccountSession().whenComplete(() {
        _restoringSession = null;
      });

  Future<bool> _restoreAccountSession() async {
    await _loadIdentity();
    if (_sessionRestoreAttempted) return isAccountLinked;
    final epoch = _sessionEpoch;
    try {
      return await _withSessionStorage(() async {
        if (epoch != _sessionEpoch) return isAccountLinked;
        final raw = await _secureStorage.read(key: _sessionKey);
        if (epoch != _sessionEpoch) return isAccountLinked;
        if (raw == null || raw.isEmpty) {
          _sessionRestoreAttempted = true;
          AnimeRiftLocalAccountScope.reset();
          return false;
        }
        Map<dynamic, dynamic>? decoded;
        try {
          final value = jsonDecode(raw);
          if (value is Map) decoded = value;
        } on FormatException {
          // Only the corrupt Rift credential is discarded.
        }
        final storedAccountId = AnimeRiftAccountIdentity._safeField(
          decoded?['accountId'],
        );
        if (decoded?['version'] != 1 ||
            decoded?['deviceId'] != _identity!['deviceId'] ||
            decoded?['token'] is! String ||
            !_validAccessToken(decoded!['token'] as String)) {
          await _secureStorage.delete(key: _sessionKey);
          if (epoch == _sessionEpoch) {
            _sessionRestoreAttempted = true;
            AnimeRiftLocalAccountScope.reset();
          }
          return isAccountLinked;
        }
        final token = decoded['token'] as String;
        // Preserve pre-partition Rift sessions: they have a real token but no
        // server profile ID. A token-derived partition isolates that legacy
        // session without incorrectly claiming any other user's library.
        final accountId =
            storedAccountId ?? 'legacy:${sha256.convert(utf8.encode(token))}';
        final name = AnimeRiftAccountIdentity._safeField(
          decoded['displayName'],
          maxLength: 120,
        );
        _accessToken = token;
        _accountIdentity = AnimeRiftAccountIdentity(
          id: accountId,
          displayName: name,
          isVerified: storedAccountId != null,
        );
        AnimeRiftLocalAccountScope.activate(accountId);
        _sessionRestoreAttempted = true;
        return true;
      });
    } catch (_) {
      // A fresh client must not expose a stale previous Rift account's local
      // partition while its own secure credentials cannot be restored.
      if (epoch == _sessionEpoch && _accessToken == null) {
        _accountIdentity = null;
        AnimeRiftLocalAccountScope.reset();
      }
      throw const AnimeRiftSecureStorageUnavailable();
    }
  }

  Future<void> signInWithCode(String code) async {
    final value = code.trim();
    if (value.isEmpty ||
        value.length > 256 ||
        value.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
      throw ArgumentError('Invalid Anime Rift sign-in code');
    }
    final epoch = ++_sessionEpoch;
    await _ensureReady();
    if (epoch != _sessionEpoch) throw const AnimeRiftAccessUnavailable();
    final response = await _send(
      '$_base/auth/sign-in/with-code',
      headers: _headers('USER.AUTH.SIGN_IN_WITH_CODE', includeUserToken: false),
      method: 'POST',
      body: {'code': value},
    );
    final items = response['items'];
    final profile = items is Map ? items['profile'] : null;
    final token = items is Map ? items['token'] : null;
    if (profile is! Map || token is! String || !_validAccessToken(token)) {
      throw const AnimeRiftAccessUnavailable();
    }
    // The verified sign-in contract guarantees a profile map, but has not
    // established a required field name for its stable identifier.
    final identity =
        AnimeRiftAccountIdentity.fromProfile(profile) ??
        AnimeRiftAccountIdentity(
          id: 'legacy:${sha256.convert(utf8.encode(token))}',
          isVerified: false,
        );
    final stored = jsonEncode({
      'version': 1,
      'deviceId': _identity!['deviceId'],
      'token': token,
      if (identity.isVerified) 'accountId': identity.id,
      if (identity.displayName != null) 'displayName': identity.displayName,
    });
    final applied = await _withSessionStorage(() async {
      if (epoch != _sessionEpoch) return false;
      try {
        await _secureStorage.write(key: _sessionKey, value: stored);
      } catch (_) {
        throw const AnimeRiftSecureStorageUnavailable();
      }
      if (epoch != _sessionEpoch) return false;
      _accessToken = token;
      _accountIdentity = identity;
      AnimeRiftLocalAccountScope.activate(identity.id);
      _sessionRestoreAttempted = true;
      return true;
    });
    if (!applied) throw const AnimeRiftAccessUnavailable();
  }

  Future<void> signOut() async {
    ++_sessionEpoch;
    await _withSessionStorage(() async {
      try {
        await _secureStorage.delete(key: _sessionKey);
      } catch (_) {
        throw const AnimeRiftSecureStorageUnavailable();
      }
      _accessToken = null;
      _accountIdentity = null;
      AnimeRiftLocalAccountScope.reset();
      _sessionRestoreAttempted = true;
    });
  }

  /// Read-only cloud account endpoints recovered from the shipped Rift AOT.
  /// These intentionally return the server's opaque response map: item and
  /// pagination schemas are not yet verified with an authenticated account.
  /// They never accept a caller-supplied path, method, scope or request body.
  Future<Map<String, dynamic>> fetchFavoriteAnime({CancelToken? cancelToken}) =>
      _readAccountData(
        'favorite/anime/all',
        'USER.FAVORITES.ANIME.ALL',
        cancelToken: cancelToken,
      );

  /// Known Rift list values recovered alongside `/my_list/all?my_list=`.
  /// Other values cannot be used to construct account API URLs.
  Future<Map<String, dynamic>> fetchMyList(
    String category, {
    CancelToken? cancelToken,
  }) {
    if (!const {
      'favorite',
      'currently',
      'want_to',
      'finished',
      'later',
      'dropped',
    }.contains(category)) {
      throw ArgumentError('Invalid Anime Rift list category');
    }
    return _readAccountData(
      'my_list/all',
      'USER.MY_LIST.GET_ALL',
      query: {'my_list': category},
      cancelToken: cancelToken,
    );
  }

  Future<Map<String, dynamic>> fetchMyListOverview({
    CancelToken? cancelToken,
  }) => _readAccountData(
    'my_list/overview',
    'USER.MY_LIST.OVERVIEW',
    cancelToken: cancelToken,
  );

  Future<Map<String, dynamic>> fetchWatchHistoryLatest({
    CancelToken? cancelToken,
  }) => _readAccountData(
    'watch_history/latest',
    'USER.WATCH_HISTORY.VIEW.LATEST',
    cancelToken: cancelToken,
  );

  Future<Map<String, dynamic>> fetchWatchHistoryFull({
    CancelToken? cancelToken,
  }) => _readAccountData(
    'watch_history/full',
    'USER.WATCH_HISTORY.VIEW.FULL',
    cancelToken: cancelToken,
  );

  /// Native AOT 0xaafb8c -> 0xaae770 -> 0x5c6d90: PUT, not POST.
  /// Follow/unfollow are desired-state operations, never a toggle on retry.
  Future<Map<String, dynamic>> setFavoriteAnime(
    String animeId,
    bool favorite, {
    required String accountHash,
  }) {
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(animeId)) {
      throw ArgumentError('Invalid Anime Rift anime ID');
    }
    return _readAccountData(
      'favorite/anime/${favorite ? 'follow' : 'un_follow'}',
      'USER.FAVORITES.ANIME.FOLLOW',
      method: 'PUT',
      body: {'animeId': animeId},
      accountHash: accountHash,
      expectedStatus: 202,
    );
  }

  Future<Map<String, dynamic>> _readAccountData(
    String path,
    String scope, {
    Map<String, dynamic>? query,
    CancelToken? cancelToken,
    String method = 'GET',
    Map<String, dynamic>? body,
    String? accountHash,
    int? expectedStatus,
  }) async {
    if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
    // Reject guests before performing gateway registration or network requests.
    if (!await restoreAccountSession()) {
      throw const AnimeRiftAuthenticationRequired();
    }
    final token = _accessToken;
    if (token == null) throw const AnimeRiftAuthenticationRequired();
    final epoch = _sessionEpoch;
    void requireSession() {
      final identity = _accountIdentity;
      if (epoch != _sessionEpoch ||
          _accessToken != token ||
          (accountHash != null &&
              (identity == null ||
                  sha256.convert(utf8.encode(identity.id.trim())).toString() !=
                      accountHash))) {
        throw const AnimeRiftAuthenticationRequired();
      }
    }

    requireSession();
    await _ensureReady();
    requireSession();
    if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
    try {
      final response = await _send(
        '$_base/$path',
        method: method,
        body: body,
        headers: _headers(scope),
        expectedStatus: expectedStatus,
        query: query,
        cancelToken: cancelToken,
      );
      // Never expose data fetched for a previous Rift account after a switch.
      requireSession();
      return response;
    } on AnimeRiftAccessUnavailable catch (error) {
      if (error.statusCode == 401 || error.statusCode == 403) {
        throw AnimeRiftAuthenticationRequired(statusCode: error.statusCode);
      }
      rethrow;
    }
  }

  Future<Map<String, dynamic>> request(
    String path,
    String scope, {
    String method = 'GET',
    Map<String, dynamic>? body,
    Map<String, dynamic>? query,
    CancelToken? cancelToken,
  }) async {
    final allowedPath =
        RegExp(r'^library/[A-Za-z0-9_/-]+$').hasMatch(path) ||
        path == 'character/all' ||
        RegExp(r'^character/details/[A-Za-z0-9_-]+$').hasMatch(path);
    if (!allowedPath || path.contains('..')) {
      throw ArgumentError('Invalid Anime Rift catalog path');
    }
    if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
    await _ensureReady();
    if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
    final sessionEpoch = _sessionEpoch;
    final sessionToken = _accessToken;
    void requireSameSession() {
      if (sessionEpoch != _sessionEpoch || sessionToken != _accessToken) {
        throw const AnimeRiftAuthenticationRequired();
      }
    }

    try {
      final response = await _send(
        '$_base/$path',
        headers: _headers(scope),
        method: method,
        body: body,
        query: query,
        cancelToken: cancelToken,
      );
      requireSameSession();
      return response;
    } on AnimeRiftAccessUnavailable catch (e) {
      requireSameSession();
      // 403 can mean source entitlement, suspended device or access policy,
      // not expired registration. Never replay a denied stateful POST.
      if (e.statusCode != 401) rethrow;
      if (sessionToken != null ||
          path == 'library/episode/source/can_play' ||
          path == 'library/episode/source/direct_link') {
        throw AnimeRiftAuthenticationRequired(statusCode: e.statusCode);
      }
      // Only known repeatable requests may be sent after re-registration.
      if (method != 'GET' &&
          path != 'library/episode/sources' &&
          path != 'library/all' &&
          path != 'library/search') {
        rethrow;
      }
      _registered = false;
      await _ensureReady();
      requireSameSession();
      if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
      try {
        final response = await _send(
          '$_base/$path',
          headers: _headers(scope),
          method: method,
          body: body,
          query: query,
          cancelToken: cancelToken,
        );
        requireSameSession();
        return response;
      } on AnimeRiftAccessUnavailable catch (retryError) {
        requireSameSession();
        if (_accessToken != null &&
            (retryError.statusCode == 401 || retryError.statusCode == 403)) {
          throw AnimeRiftAuthenticationRequired(
            statusCode: retryError.statusCode,
          );
        }
        rethrow;
      }
    }
  }
}
