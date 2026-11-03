import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../network/stale_connection_retry.dart';

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
  const AnimeRiftAccessUnavailable({this.statusCode});
  final int? statusCode;

  @override
  String toString() =>
      'تعذر الاتصال بخدمة Anime Rift. تحقق من إعدادات المزوّد ثم أعد المحاولة.';
}

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

/// Isolated, experimental catalog transport. Never inherits account credentials.
/// The embedded compatibility signing configuration is extractable from binaries;
/// it must not be treated as a server-side secret or used for account privileges.
class AnimeRiftApiClient {
  AnimeRiftApiClient({
    this.config = const AnimeRiftConfig(),
    Dio? dio,
    FlutterSecureStorage? secureStorage,
  }) : _dio = dio ?? createAnimeWitcherDio(),
       _secureStorage = secureStorage ?? _defaultSecureStorage;

  final AnimeRiftConfig config;
  final Dio _dio;
  final FlutterSecureStorage _secureStorage;
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
  Object? _sessionRestoreError;
  bool _sessionRestoreAttempted = false;
  Future<void>? _initializing;
  bool _registered = false;
  bool get isConfigured => config.isConfigured;
  bool get isAccountLinked => _accessToken != null;

  static String _randomText(int length) {
    const alphabet =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    return List.generate(
      length,
      (_) => alphabet[_random.nextInt(alphabet.length)],
    ).join();
  }

  Future<void> _loadIdentity() async {
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
  }) async {
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
      if (status < 200 || status >= 300)
        throw AnimeRiftAccessUnavailable(statusCode: status);
      final dynamic value = response.data is String
          ? jsonDecode(response.data as String)
          : response.data;
      if (value is! Map) throw const AnimeRiftAccessUnavailable();
      return Map<String, dynamic>.from(value);
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) rethrow;
      throw const AnimeRiftAccessUnavailable();
    } on AnimeRiftAccessUnavailable {
      rethrow;
    } catch (_) {
      throw const AnimeRiftAccessUnavailable();
    }
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
      if (fid is! String || fid.isEmpty || token is! String || token.isEmpty)
        return;
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
      'x-device-os-id': _identity!['buildId']!,
      'user-agent': 'Dart/3.10 (dart:io)',
      'x-device-release-version': '3.13.5',
      'x-firebase-app-check': 'null',
      'authorization': 'Bearer ${includeUserToken ? _accessToken : null}',
      'content-type': 'application/json; charset=UTF-8',
      'x-installation-source': 'IS_INSTALLED_FROM_PLAY_PACKAGE_INSTALLER',
      'integrity': 'Bearer $unsigned.$signature',
      'accept': 'application/json',
      'x-firebase-id': _identity!['fid']!,
      'x-device-id': _identity!['deviceId']!,
      'x-device-timezone': DateTime.now().toIso8601String(),
      'x-device-language': 'ar',
      'x-platform': 'Mobile',
      'x-os': 'android',
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
    final build = _identity!['buildId']!;
    // Legacy gateway protocol descriptor, not a claim about the host platform.
    // This compatibility path has not been verified on a physical iOS device.
    final info = {
      'model': 'Pixel 8 Pro',
      'brand': 'google',
      'manufacturer': 'Google',
      'device': 'google',
      'hardware': 'qcom',
      'product': 'google',
      'androidVersion': '14',
      'sdkInt': 34,
      'securityPatch': '2025-01-01',
      'isPhysicalDevice': true,
      'supportedAbis': ['arm64-v8a'],
      'tags': 'release-keys',
      'type': 'user',
      'buildId': build,
      'host': 'build-server-client',
      'fingerprint':
          'google/Pixel 8 Pro/google:14/$build/V.1e9a_client:user/release-keys',
    };
    await _send(
      '$_base/auth/register/device',
      headers: _headers('USER.AUTH.DEVICE.REGISTER'),
      method: 'POST',
      body: {
        'deviceId': _identity!['deviceId'],
        'current_app_version': '3.13.5',
        'device_os': 'android',
        'device_environment': 'production',
        'device_info': jsonEncode(info),
        'install_source': 'IS_INSTALLED_FROM_PLAY_PACKAGE_INSTALLER',
        'deviceOsId': build,
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
    if (!isConfigured) throw const AnimeRiftAccessUnavailable();
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

  Future<bool> restoreAccountSession() async {
    await _loadIdentity();
    if (_sessionRestoreAttempted) {
      if (_sessionRestoreError != null) {
        throw const AnimeRiftSecureStorageUnavailable();
      }
      return isAccountLinked;
    }
    _sessionRestoreAttempted = true;
    try {
      final raw = await _secureStorage.read(key: _sessionKey);
      if (raw == null || raw.isEmpty) return false;
      final decoded = jsonDecode(raw);
      if (decoded is! Map ||
          decoded['version'] != 1 ||
          decoded['deviceId'] != _identity!['deviceId'] ||
          decoded['token'] is! String ||
          !_validAccessToken(decoded['token'] as String)) {
        await _secureStorage.delete(key: _sessionKey);
        return false;
      }
      _accessToken = decoded['token'] as String;
      return true;
    } catch (error) {
      _sessionRestoreError = error;
      throw const AnimeRiftSecureStorageUnavailable();
    }
  }

  Future<void> signInWithCode(String code) async {
    final value = code.trim();
    if (value.isEmpty ||
        value.length > 256 ||
        value.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
      throw ArgumentError.value(
        code,
        'code',
        'Invalid Anime Rift sign-in code',
      );
    }
    await _ensureReady();
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
    final stored = jsonEncode({
      'version': 1,
      'deviceId': _identity!['deviceId'],
      'token': token,
    });
    try {
      await _secureStorage.write(key: _sessionKey, value: stored);
    } catch (_) {
      throw const AnimeRiftSecureStorageUnavailable();
    }
    _accessToken = token;
    _sessionRestoreAttempted = true;
    _sessionRestoreError = null;
  }

  Future<void> signOut() async {
    try {
      await _secureStorage.delete(key: _sessionKey);
    } catch (_) {
      throw const AnimeRiftSecureStorageUnavailable();
    }
    _accessToken = null;
    _sessionRestoreAttempted = true;
    _sessionRestoreError = null;
  }

  Future<Map<String, dynamic>> request(
    String path,
    String scope, {
    String method = 'GET',
    Map<String, dynamic>? body,
    Map<String, dynamic>? query,
    CancelToken? cancelToken,
  }) async {
    if (!RegExp(r'^library/[A-Za-z0-9_/-]+$').hasMatch(path) ||
        path.contains('..')) {
      throw ArgumentError('Invalid Anime Rift catalog path');
    }
    if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
    await _ensureReady();
    if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
    try {
      return await _send(
        '$_base/$path',
        headers: _headers(scope),
        method: method,
        body: body,
        query: query,
        cancelToken: cancelToken,
      );
    } on AnimeRiftAccessUnavailable catch (e) {
      if (e.statusCode != 401 && e.statusCode != 403) rethrow;
      _registered = false;
      await _ensureReady();
      if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
      try {
        return await _send(
          '$_base/$path',
          headers: _headers(scope),
          method: method,
          body: body,
          query: query,
          cancelToken: cancelToken,
        );
      } on AnimeRiftAccessUnavailable catch (retryError) {
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
