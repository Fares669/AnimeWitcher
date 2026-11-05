import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../network/stale_connection_retry.dart';
import '../../storage/anime_rift_account_scope.dart';
import 'anime_rift_device_descriptor.dart';
import 'anime_rift_auth_diagnostic_log.dart';

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
  const AnimeRiftAccessUnavailable({
    this.statusCode,
    this.stage,
    this.failure,
    this.knownReason,
    this.serverCode,
    this.responseKind,
    this.edgeRejected = false,
    this.transportKind,
    this.durationMs,
    this.retryAfterSeconds,
  });
  final int? statusCode;
  final AnimeRiftRequestStage? stage;
  final AnimeRiftFailureKind? failure;
  final AnimeRiftServerReason? knownReason;

  /// A restricted server error identifier, never a free-form server message.
  final String? serverCode;
  final AnimeRiftResponseKind? responseKind;
  final bool edgeRejected;
  final DioExceptionType? transportKind;
  final int? durationMs;
  final int? retryAfterSeconds;

  /// Only known operation labels and an HTTP status are displayed. Never a
  /// gateway response, URL, session token, or request headers.
  String get _safeDiagnostic {
    final operation = switch (stage) {
      AnimeRiftRequestStage.deviceRegistration => 'تسجيل الجهاز',
      AnimeRiftRequestStage.codeSignIn => 'تسجيل الدخول بالرمز',
      AnimeRiftRequestStage.episodeSources => 'قائمة مصادر الحلقة',
      AnimeRiftRequestStage.sourceAvailability => 'صلاحية التشغيل أو التنزيل',
      AnimeRiftRequestStage.directLink => 'استخراج رابط الحلقة',
      AnimeRiftRequestStage.other => 'طلب بيانات Anime Rift',
      null => null,
    };
    final details = <String>[
      if (operation != null) operation,
      if (statusCode != null) 'HTTP $statusCode',
      if (knownReason != null)
        switch (knownReason!) {
          AnimeRiftServerReason.installSourceNotSupported =>
            'مصدر التثبيت غير مدعوم',
          AnimeRiftServerReason.invalidCode => 'رمز الدخول غير صالح',
          AnimeRiftServerReason.unsupportedPlatform => 'المنصة غير مدعومة',
          AnimeRiftServerReason.deviceSuspended => 'الجهاز موقوف',
          AnimeRiftServerReason.integrityVerificationFailed =>
            'فشل التحقق من سلامة التطبيق',
          AnimeRiftServerReason.accessDenied => 'الوصول مرفوض',
          AnimeRiftServerReason.deviceSessionExpired =>
            'انتهت صلاحية جلسة الجهاز',
        },
      if (failure != null)
        switch (failure!) {
          AnimeRiftFailureKind.configuration => 'إعدادات الربط غير مكتملة',
          AnimeRiftFailureKind.transport => 'تعذر الوصول إلى الشبكة',
          AnimeRiftFailureKind.invalidResponse => 'استجابة غير صالحة',
          AnimeRiftFailureKind.registrationCooldown =>
            'تم تأجيل تسجيل الجهاز لتجنب حظر السيرفر',
        },
      if (retryAfterSeconds != null &&
          failure == AnimeRiftFailureKind.registrationCooldown)
        'أعد المحاولة بعد ${((retryAfterSeconds! + 59) ~/ 60)} دقيقة',
    ];
    return details.isEmpty ? '' : ' (${details.join('، ')})';
  }

  @override
  String toString() =>
      'تعذر الاتصال بخدمة Anime Rift$_safeDiagnostic. تحقق من إعدادات المزوّد ثم أعد المحاولة.';
}

enum AnimeRiftRequestStage {
  deviceRegistration,
  codeSignIn,
  episodeSources,
  sourceAvailability,
  directLink,
  other,
}

enum AnimeRiftFailureKind {
  configuration,
  transport,
  invalidResponse,
  registrationCooldown,
}

/// Only explicit server error *codes* found in the original APK are accepted.
enum AnimeRiftServerReason {
  installSourceNotSupported,
  invalidCode,
  unsupportedPlatform,
  deviceSuspended,
  integrityVerificationFailed,
  accessDenied,
  deviceSessionExpired,
}

enum AnimeRiftResponseKind { json, html, text, other }

enum AnimeRiftRegistrationMode { nativeIos, nativeAndroid, androidFallback }

enum AnimeRiftDeviceModelKind { iphone, pixel8Pro, other, unknown }

/// Allowlisted authentication diagnostics: no request data, tokens, user
/// identifiers, installation IDs, raw exceptions, URLs or response bodies.
enum AnimeRiftAuthEvent {
  registrationStart,
  registrationRejected,
  compatibilityRetry,
  compatibilityAccepted,
  compatibilityRejected,
  registrationFailed,
  registrationAccepted,
  codeSignInStart,
  codeSignInRejected,
  codeSignInAccepted,
  codeSignInInvalidResponse,
  registrationReused,
  registrationDeferred,
  sessionIdentityChecked,
  serverSessionsChecked,
  serverSessionsCheckFailed,
}

class AnimeRiftAuthDiagnostic {
  const AnimeRiftAuthDiagnostic({
    required this.event,
    this.statusCode,
    this.failure,
    this.knownReason,
    this.serverCode,
    this.responseKind,
    this.edgeRejected = false,
    this.transportKind,
    this.durationMs,
    this.retryAfterSeconds,
    this.mode,
    this.attempt,
    this.cooldownSeconds,
    this.nativeMode,
    this.localModel,
    this.advertisedModel,
    this.deviceMismatch,
    this.serverSessionCount,
    this.serverIphoneCount,
    this.serverPixel8ProCount,
    this.serverUnknownCount,
  });

  final AnimeRiftAuthEvent event;
  final int? statusCode;
  final AnimeRiftFailureKind? failure;
  final AnimeRiftServerReason? knownReason;
  final String? serverCode;
  final AnimeRiftResponseKind? responseKind;
  final bool edgeRejected;
  final DioExceptionType? transportKind;
  final int? durationMs;
  final int? retryAfterSeconds;
  final AnimeRiftRegistrationMode? mode;
  final int? attempt;
  final int? cooldownSeconds;
  final AnimeRiftRegistrationMode? nativeMode;
  final AnimeRiftDeviceModelKind? localModel;
  final AnimeRiftDeviceModelKind? advertisedModel;
  final bool? deviceMismatch;
  final int? serverSessionCount;
  final int? serverIphoneCount;
  final int? serverPixel8ProCount;
  final int? serverUnknownCount;

  @override
  String toString() =>
      'AnimeRift auth: ${event.name}'
      '${statusCode == null ? '' : ' HTTP $statusCode'}'
      '${failure == null ? '' : ' ${failure!.name}'}'
      '${knownReason == null ? '' : ' ${knownReason!.name}'}'
      '${serverCode == null ? '' : ' serverCode=$serverCode'}'
      '${responseKind == null ? '' : ' response=${responseKind!.name}'}'
      '${edgeRejected ? ' edgeRejected' : ''}'
      '${transportKind == null ? '' : ' transport=${transportKind!.name}'}'
      '${durationMs == null ? '' : ' durationMs=$durationMs'}'
      '${mode == null ? '' : ' mode=${mode!.name}'}'
      '${cooldownSeconds == null ? '' : ' cooldownSeconds=$cooldownSeconds'}'
      '${nativeMode == null ? '' : ' nativeMode=${nativeMode!.name}'}'
      '${localModel == null ? '' : ' localModel=${localModel!.name}'}'
      '${advertisedModel == null ? '' : ' advertisedModel=${advertisedModel!.name}'}'
      '${deviceMismatch == null ? '' : ' deviceMismatch=$deviceMismatch'}'
      '${serverSessionCount == null ? '' : ' serverSessions=$serverSessionCount'}'
      '${serverIphoneCount == null ? '' : ' serverIphones=$serverIphoneCount'}'
      '${serverPixel8ProCount == null ? '' : ' serverPixels=$serverPixel8ProCount'}'
      '${serverUnknownCount == null ? '' : ' serverUnknown=$serverUnknownCount'}';
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
    void Function(AnimeRiftAuthDiagnostic diagnostic)? onAuthDiagnostic,
    DateTime Function()? clock,
  }) : _dio = dio ?? createAnimeWitcherDio(),
       _secureStorage = secureStorage ?? _defaultSecureStorage,
       _loadDeviceDescriptor =
           deviceDescriptorLoader ?? AnimeRiftDeviceDescriptor.detect,
       _onAuthDiagnostic = onAuthDiagnostic,
       _clock = clock ?? DateTime.now;

  final AnimeRiftConfig config;
  final Dio _dio;
  final FlutterSecureStorage _secureStorage;
  final Future<AnimeRiftDeviceDescriptor> Function(String legacyBuildId)
  _loadDeviceDescriptor;
  AnimeRiftDeviceDescriptor? _deviceDescriptor;
  AnimeRiftDeviceDescriptor? _nativeDeviceDescriptor;
  AnimeRiftRegistrationMode? _registrationMode;
  final void Function(AnimeRiftAuthDiagnostic diagnostic)? _onAuthDiagnostic;
  final DateTime Function() _clock;

  void _authLog(
    AnimeRiftAuthEvent event, {
    int? statusCode,
    AnimeRiftFailureKind? failure,
    AnimeRiftServerReason? knownReason,
    String? serverCode,
    AnimeRiftResponseKind? responseKind,
    bool edgeRejected = false,
    DioExceptionType? transportKind,
    int? durationMs,
    int? retryAfterSeconds,
    AnimeRiftRegistrationMode? mode,
    int? attempt,
    int? cooldownSeconds,
    AnimeRiftRegistrationMode? nativeMode,
    AnimeRiftDeviceModelKind? localModel,
    AnimeRiftDeviceModelKind? advertisedModel,
    bool? deviceMismatch,
    int? serverSessionCount,
    int? serverIphoneCount,
    int? serverPixel8ProCount,
    int? serverUnknownCount,
  }) {
    final diagnostic = AnimeRiftAuthDiagnostic(
      event: event,
      statusCode: statusCode,
      failure: failure,
      knownReason: knownReason,
      serverCode: serverCode,
      responseKind: responseKind,
      edgeRejected: edgeRejected,
      transportKind: transportKind,
      durationMs: durationMs,
      retryAfterSeconds: retryAfterSeconds,
      mode: mode,
      attempt: attempt,
      cooldownSeconds: cooldownSeconds,
      nativeMode: nativeMode,
      localModel: localModel,
      advertisedModel: advertisedModel,
      deviceMismatch: deviceMismatch,
      serverSessionCount: serverSessionCount,
      serverIphoneCount: serverIphoneCount,
      serverPixel8ProCount: serverPixel8ProCount,
      serverUnknownCount: serverUnknownCount,
    );
    // Safe for release logs: only enum labels and a numeric HTTP status.
    developer.log(diagnostic.toString(), name: 'anime_rift.auth');
    AnimeRiftAuthDiagnosticLog.shared.record(diagnostic);
    _onAuthDiagnostic?.call(diagnostic);
  }

  void _logRegistrationError(
    AnimeRiftAuthEvent event,
    AnimeRiftAccessUnavailable error, {
    required AnimeRiftRegistrationMode mode,
    required int attempt,
    int? cooldownSeconds,
  }) => _authLog(
    event,
    statusCode: error.statusCode,
    failure: error.failure,
    knownReason: error.knownReason,
    serverCode: error.serverCode,
    responseKind: error.responseKind,
    edgeRejected: error.edgeRejected,
    transportKind: error.transportKind,
    durationMs: error.durationMs,
    retryAfterSeconds: error.retryAfterSeconds,
    mode: mode,
    attempt: attempt,
    cooldownSeconds: cooldownSeconds,
  );

  static const _identityKey = 'animerift.api.installation.v1';
  static const _registrationSuccessKey =
      'animerift.api.registration.successAt.v1';
  static const _registrationAndroidKey =
      'animerift.api.registration.android.v1';
  static const _registrationBlockedKey =
      'animerift.api.registration.blockedUntil.v1';
  static const _registrationFailuresKey =
      'animerift.api.registration.failures.v1';
  static const _registrationForcedAtKey =
      'animerift.api.registration.forcedAt.v1';
  static const _registrationReuseMs = 5 * 60 * 1000;
  // Serializes registrations from separate client instances in the same app.
  static Future<void> _registrationGate = Future<void>.value();
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
  bool _forceRegistration = false;
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
    Duration? diagnosticTimeout,
  }) async {
    final stage = _requestStage(url);
    final stopwatch = Stopwatch()..start();
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
          sendTimeout: diagnosticTimeout ?? const Duration(seconds: 15),
          receiveTimeout: diagnosticTimeout ?? const Duration(seconds: 30),
          validateStatus: (_) => true,
        ),
      );
      final status = response.statusCode ?? 0;
      if (status < 200 ||
          status >= 300 ||
          (expectedStatus != null && status != expectedStatus)) {
        throw AnimeRiftAccessUnavailable(
          statusCode: status,
          stage: stage,
          knownReason: _recognizedServerReason(response.data),
          serverCode: _serverErrorCode(response.data),
          responseKind: _responseKind(response.data),
          edgeRejected: _isEdgeRejected(response.headers),
          durationMs: stopwatch.elapsedMilliseconds,
          retryAfterSeconds: _retryAfterSeconds(response.headers),
        );
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
        knownReason: _recognizedServerReason(e.response?.data),
        serverCode: _serverErrorCode(e.response?.data),
        responseKind: e.response == null
            ? null
            : _responseKind(e.response?.data),
        edgeRejected:
            e.response != null && _isEdgeRejected(e.response!.headers),
        transportKind: e.type,
        durationMs: stopwatch.elapsedMilliseconds,
        retryAfterSeconds: e.response == null
            ? null
            : _retryAfterSeconds(e.response!.headers),
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

  static AnimeRiftServerReason? _recognizedServerReason(Object? value) {
    final code = _serverErrorCode(value);
    return switch (code) {
      'INSTALL_SOURCE_NOT_SUPPORTED' =>
        AnimeRiftServerReason.installSourceNotSupported,
      'UNSUPPORTED_PLATFORM' => AnimeRiftServerReason.unsupportedPlatform,
      'DEVICE_SUSPENDED' => AnimeRiftServerReason.deviceSuspended,
      'INTEGRITY_VERIFICATION_FAILED' =>
        AnimeRiftServerReason.integrityVerificationFailed,
      'ACCESS_DENIED' => AnimeRiftServerReason.accessDenied,
      'DEVICE_SESSION_EXPIRED' => AnimeRiftServerReason.deviceSessionExpired,
      'invalidCode' => AnimeRiftServerReason.invalidCode,
      _ => null,
    };
  }

  /// Accept a short error *identifier* only; never persist response messages,
  /// headers, raw bodies, arbitrary IDs or diagnostic traces.
  static String? _serverErrorCode(Object? value) {
    Object? response = value;
    if (response is String) {
      try {
        response = jsonDecode(response);
      } catch (_) {
        return null;
      }
    }
    if (response is! Map) return null;
    final error = response['error'];
    final codes = <Object?>[
      response['code'],
      response['errorCode'],
      response['error_code'],
      error is Map ? error['code'] : error,
      if (error is Map) error['errorCode'],
      if (error is Map) error['error_code'],
    ];
    for (final candidate in codes) {
      if (candidate == 'invalidCode') return 'invalidCode';
      if (candidate is! String) continue;
      final code = candidate.trim();
      // A secret (JWT, token, arbitrary message) must not become a log entry.
      if (code.length < 3 ||
          code.length > 64 ||
          !RegExp(r'^[A-Z][A-Z0-9_]*$').hasMatch(code) ||
          !code.contains('_') ||
          RegExp(r'TOKEN|PASSWORD|SECRET|API_KEY|JWT|BEARER|AUTHORIZATION')
              .hasMatch(code)) {
        continue;
      }
      return code;
    }
    return null;
  }

  static AnimeRiftResponseKind _responseKind(Object? response) {
    if (response is Map) return AnimeRiftResponseKind.json;
    if (response is String) {
      final text = response.trimLeft();
      if (text.startsWith('<!DOCTYPE') ||
          text.startsWith('<html') ||
          text.startsWith('<HTML'))
        return AnimeRiftResponseKind.html;
      if (text.startsWith('{')) return AnimeRiftResponseKind.json;
      return AnimeRiftResponseKind.text;
    }
    return AnimeRiftResponseKind.other;
  }

  static bool _isEdgeRejected(Headers headers) =>
      (headers.value('server') ?? '').toLowerCase() == 'cloudflare';

  int? _retryAfterSeconds(Headers headers) {
    final value = headers.value('retry-after')?.trim();
    if (value == null || value.length > 80) return null;
    final seconds = int.tryParse(value);
    if (seconds != null) return seconds.clamp(0, 86400);
    DateTime? date;
    try {
      date = HttpDate.parse(value);
    } on FormatException {
      // HTTP Retry-After permits either seconds or an RFC 7231 date.
    }
    if (date == null) return null;
    return (date.difference(_clock().toUtc()).inSeconds).clamp(0, 86400);
  }

  static AnimeRiftRequestStage _requestStage(String url) {
    final path = Uri.tryParse(url)?.path;
    return switch (path) {
      '/api/v4/auth/register/device' =>
        AnimeRiftRequestStage.deviceRegistration,
      '/api/v4/auth/sign-in/with-code' => AnimeRiftRequestStage.codeSignIn,
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

  /// Prevent separate provider instances from performing overlapping register
  /// requests, even if they initialize on the same frame.
  static Future<T> _serializeRegistration<T>(Future<T> Function() task) async {
    final preceding = _registrationGate;
    final done = Completer<void>();
    _registrationGate = done.future;
    await preceding;
    try {
      return await task();
    } finally {
      done.complete();
    }
  }

  static AnimeRiftRegistrationMode _nativeMode(AnimeRiftDeviceDescriptor d) =>
      d.os == 'ios'
      ? AnimeRiftRegistrationMode.nativeIos
      : AnimeRiftRegistrationMode.nativeAndroid;

  /// Map device model data to a fixed category, never a name provided by the
  /// device or gateway (which may include a user's personal device name).
  static AnimeRiftDeviceModelKind _modelKind(Object? input) {
    Object? data = input;
    if (data is Map) {
      data =
          data['model'] ??
          data['modelName'] ??
          data['deviceName'] ??
          data['deviceInfo'];
    }
    if (data is! String) return AnimeRiftDeviceModelKind.unknown;
    final value = data.trim();
    if (value.isEmpty || value.length > 4096) {
      return AnimeRiftDeviceModelKind.unknown;
    }
    if (value.startsWith('{')) {
      try {
        return _modelKind(jsonDecode(value));
      } catch (_) {
        return AnimeRiftDeviceModelKind.unknown;
      }
    }
    final lowered = value.toLowerCase();
    if (lowered.contains('pixel 8 pro')) {
      return AnimeRiftDeviceModelKind.pixel8Pro;
    }
    if (lowered.startsWith('iphone')) {
      return AnimeRiftDeviceModelKind.iphone;
    }
    return AnimeRiftDeviceModelKind.other;
  }

  void _logDeviceIdentity() {
    final native = _nativeDeviceDescriptor;
    final advertised = _deviceDescriptor;
    if (native == null || advertised == null) return;
    _authLog(
      AnimeRiftAuthEvent.sessionIdentityChecked,
      nativeMode: _nativeMode(native),
      mode: _registrationMode,
      localModel: _modelKind(native.details),
      advertisedModel: _modelKind(advertised.details),
      deviceMismatch:
          native.os != advertised.os ||
          _modelKind(native.details) != _modelKind(advertised.details),
    );
  }

  /// Original Rift AOT references GET /sessions/all with this scope. It is a
  /// one-time read-only diagnostic after linking on iOS, not a registration
  /// attempt. Aggregate only known device categories; no session IDs or names.
  Future<void> _checkServerSessionModels(int epoch, String token) async {
    if (_nativeDeviceDescriptor?.os != 'ios' ||
        epoch != _sessionEpoch ||
        _accessToken != token)
      return;
    try {
      final data = await _send(
        '$_base/sessions/all',
        headers: _headers('SETTINGS.SESSIONS.ALL'),
        diagnosticTimeout: const Duration(seconds: 5),
      );
      if (epoch != _sessionEpoch || _accessToken != token) return;
      final value = data['items'];
      final Object? records = value is List
          ? value
          : value is Map
          ? value['items'] ?? value['sessions']
          : data['sessions'];
      if (records is! List) {
        _authLog(
          AnimeRiftAuthEvent.serverSessionsCheckFailed,
          failure: AnimeRiftFailureKind.invalidResponse,
        );
        return;
      }
      var iphones = 0;
      var pixels = 0;
      var unknown = 0;
      for (final record in records) {
        final kind = record is Map
            ? _modelKind(record['deviceInfo'])
            : AnimeRiftDeviceModelKind.unknown;
        switch (kind) {
          case AnimeRiftDeviceModelKind.iphone:
            iphones++;
          case AnimeRiftDeviceModelKind.pixel8Pro:
            pixels++;
          case AnimeRiftDeviceModelKind.unknown:
            unknown++;
          case AnimeRiftDeviceModelKind.other:
            break;
        }
      }
      _authLog(
        AnimeRiftAuthEvent.serverSessionsChecked,
        serverSessionCount: records.length,
        serverIphoneCount: iphones,
        serverPixel8ProCount: pixels,
        serverUnknownCount: unknown,
      );
    } on AnimeRiftAccessUnavailable catch (error) {
      if (epoch != _sessionEpoch || _accessToken != token) return;
      _authLog(
        AnimeRiftAuthEvent.serverSessionsCheckFailed,
        statusCode: error.statusCode,
        failure: error.failure,
        knownReason: error.knownReason,
        serverCode: error.serverCode,
        transportKind: error.transportKind,
      );
    } catch (_) {
      if (epoch != _sessionEpoch || _accessToken != token) return;
      _authLog(
        AnimeRiftAuthEvent.serverSessionsCheckFailed,
        failure: AnimeRiftFailureKind.invalidResponse,
      );
    }
  }

  int _cooldownFor(AnimeRiftAccessUnavailable error, int failures) {
    final base = switch (error.statusCode) {
      429 => 1800,
      403 => 600,
      int status when status >= 400 && status < 500 => 300,
      int status when status >= 500 => 90,
      _ => 60,
    };
    final multiplier = 1 << (failures - 1).clamp(0, 2);
    return max(min(base * multiplier, 3600), error.retryAfterSeconds ?? 0);
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
    final native = await _loadDeviceDescriptor(_identity!['buildId']!);
    _nativeDeviceDescriptor = native;
    _deviceDescriptor = native;
    await _serializeRegistration(() async {
      final prefs = await SharedPreferences.getInstance();
      final nowMs = _clock().toUtc().millisecondsSinceEpoch;
      final blockedUntil = prefs.getInt(_registrationBlockedKey) ?? 0;
      if (nowMs < blockedUntil) {
        final seconds = ((blockedUntil - nowMs) / 1000).ceil();
        _authLog(
          AnimeRiftAuthEvent.registrationDeferred,
          failure: AnimeRiftFailureKind.registrationCooldown,
          mode: _nativeMode(native),
          cooldownSeconds: seconds,
        );
        throw AnimeRiftAccessUnavailable(
          stage: AnimeRiftRequestStage.deviceRegistration,
          failure: AnimeRiftFailureKind.registrationCooldown,
          retryAfterSeconds: seconds,
        );
      }
      // Reuse a recent *successful* registration; refreshing the UI or
      // reopening the app must not flood the gateway with identical requests.
      final succeededAt = prefs.getInt(_registrationSuccessKey);
      if (_forceRegistration) {
        final forcedAt = prefs.getInt(_registrationForcedAtKey);
        if (forcedAt != null &&
            nowMs >= forcedAt &&
            nowMs - forcedAt < _registrationReuseMs) {
          final seconds = ((_registrationReuseMs - (nowMs - forcedAt)) / 1000)
              .ceil();
          _authLog(
            AnimeRiftAuthEvent.registrationDeferred,
            failure: AnimeRiftFailureKind.registrationCooldown,
            mode: _nativeMode(native),
            cooldownSeconds: seconds,
          );
          throw AnimeRiftAccessUnavailable(
            stage: AnimeRiftRequestStage.deviceRegistration,
            failure: AnimeRiftFailureKind.registrationCooldown,
            retryAfterSeconds: seconds,
          );
        }
        await prefs.setInt(_registrationForcedAtKey, nowMs);
      }
      if (!_forceRegistration &&
          succeededAt != null &&
          nowMs >= succeededAt &&
          nowMs - succeededAt < _registrationReuseMs) {
        final reusedFallback = prefs.getBool(_registrationAndroidKey) == true;
        if (reusedFallback) {
          _deviceDescriptor = AnimeRiftDeviceDescriptor.emulatedAndroid(
            _identity!['buildId']!,
          );
        }
        _registrationMode = reusedFallback
            ? AnimeRiftRegistrationMode.androidFallback
            : _nativeMode(native);
        _authLog(
          AnimeRiftAuthEvent.registrationReused,
          mode: reusedFallback
              ? AnimeRiftRegistrationMode.androidFallback
              : _nativeMode(native),
        );
        return;
      }
      final nativeMode = _nativeMode(native);
      var mode = nativeMode;
      var attempt = 1;
      _authLog(
        AnimeRiftAuthEvent.registrationStart,
        mode: nativeMode,
        attempt: 1,
      );
      try {
        try {
          await _registerDevice(native);
          _authLog(
            AnimeRiftAuthEvent.registrationAccepted,
            mode: nativeMode,
            attempt: 1,
          );
        } on AnimeRiftAccessUnavailable catch (error) {
          _logRegistrationError(
            AnimeRiftAuthEvent.registrationRejected,
            error,
            mode: nativeMode,
            attempt: 1,
          );
          if (native.os != 'ios' || !_canRetryAndroidCompatibility(error)) {
            rethrow;
          }
          // Only a server-confirmed platform/install-source mismatch allows
          // one Android compatibility request. Generic 403 does not.
          mode = AnimeRiftRegistrationMode.androidFallback;
          attempt = 2;
          _deviceDescriptor = AnimeRiftDeviceDescriptor.emulatedAndroid(
            _identity!['buildId']!,
          );
          _authLog(
            AnimeRiftAuthEvent.compatibilityRetry,
            statusCode: error.statusCode,
            knownReason: error.knownReason,
            serverCode: error.serverCode,
            mode: mode,
            attempt: 2,
          );
          try {
            await _registerDevice(_deviceDescriptor!);
            _authLog(
              AnimeRiftAuthEvent.compatibilityAccepted,
              mode: mode,
              attempt: 2,
            );
          } on AnimeRiftAccessUnavailable catch (fallbackError) {
            _deviceDescriptor = native;
            _logRegistrationError(
              AnimeRiftAuthEvent.compatibilityRejected,
              fallbackError,
              mode: mode,
              attempt: 2,
            );
            rethrow;
          }
        }
      } on AnimeRiftAccessUnavailable catch (error) {
        final failures = (prefs.getInt(_registrationFailuresKey) ?? 0) + 1;
        final seconds = _cooldownFor(error, failures);
        await prefs.setInt(_registrationFailuresKey, failures);
        await prefs.setInt(
          _registrationBlockedKey,
          _clock().toUtc().millisecondsSinceEpoch + seconds * 1000,
        );
        _logRegistrationError(
          AnimeRiftAuthEvent.registrationFailed,
          error,
          mode: mode,
          attempt: attempt,
          cooldownSeconds: seconds,
        );
        rethrow;
      }
      await prefs.setInt(
        _registrationSuccessKey,
        _clock().toUtc().millisecondsSinceEpoch,
      );
      await prefs.setBool(
        _registrationAndroidKey,
        mode == AnimeRiftRegistrationMode.androidFallback,
      );
      await prefs.remove(_registrationBlockedKey);
      await prefs.remove(_registrationFailuresKey);
      await prefs.setString(_identityKey, jsonEncode(_identity));
      _registrationMode = mode;
    });
    _registered = true;
    _logDeviceIdentity();
  }

  /// Generic HTTP 403 can be a device ban: retrying it as Android doubles
  /// suspicious traffic. Only known platform/install-source errors qualify.
  static bool _canRetryAndroidCompatibility(AnimeRiftAccessUnavailable error) {
    return error.stage == AnimeRiftRequestStage.deviceRegistration &&
        error.statusCode != null &&
        error.statusCode! >= 400 &&
        error.statusCode! < 500 &&
        error.statusCode != 401 &&
        error.statusCode != 429 &&
        (error.knownReason == AnimeRiftServerReason.installSourceNotSupported ||
            error.knownReason == AnimeRiftServerReason.unsupportedPlatform);
  }

  Future<void> _registerDevice(AnimeRiftDeviceDescriptor device) async {
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
    _authLog(AnimeRiftAuthEvent.codeSignInStart);
    await _ensureReady();
    if (epoch != _sessionEpoch) throw const AnimeRiftAccessUnavailable();
    late final Map<String, dynamic> response;
    try {
      response = await _send(
        '$_base/auth/sign-in/with-code',
        headers: _headers(
          'USER.AUTH.SIGN_IN_WITH_CODE',
          includeUserToken: false,
        ),
        method: 'POST',
        body: {'code': value},
      );
    } on AnimeRiftAccessUnavailable catch (error) {
      _authLog(
        AnimeRiftAuthEvent.codeSignInRejected,
        statusCode: error.statusCode,
        failure: error.failure,
        knownReason: error.knownReason,
      );
      rethrow;
    }
    final items = response['items'];
    final profile = items is Map ? items['profile'] : null;
    final token = items is Map ? items['token'] : null;
    if (profile is! Map || token is! String || !_validAccessToken(token)) {
      _authLog(AnimeRiftAuthEvent.codeSignInInvalidResponse);
      throw const AnimeRiftAccessUnavailable(
        stage: AnimeRiftRequestStage.codeSignIn,
        failure: AnimeRiftFailureKind.invalidResponse,
      );
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
    _authLog(AnimeRiftAuthEvent.codeSignInAccepted);
    _logDeviceIdentity();
    // A diagnostic failure never blocks a successful sign-in or alters the
    // account session. It performs no registration or destructive operation.
    unawaited(_checkServerSessionModels(epoch, token));
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

  /// Native Rift AOT 0xab0728-0xab07c4: PUT /my_list/bookmark with
  /// animeId/is_my_list/custom_list_id and USER.MY_LIST.BOOKMARK.
  /// Only built-in lists are supported. A null list requests removal;
  /// callers must verify the server's resulting membership before acking.
  Future<Map<String, dynamic>> setMyListCategory(
    String animeId,
    String? category, {
    required String accountHash,
  }) {
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(animeId)) {
      throw ArgumentError('Invalid Anime Rift anime ID');
    }
    if (category != null &&
        !const {
          'currently',
          'want_to',
          'finished',
          'later',
          'dropped',
        }.contains(category)) {
      throw ArgumentError('Invalid Anime Rift category');
    }
    return _readAccountData(
      'my_list/bookmark',
      'USER.MY_LIST.BOOKMARK',
      method: 'PUT',
      body: {
        'animeId': animeId,
        'is_my_list': category,
        'custom_list_id': null,
      },
      accountHash: accountHash,
      expectedStatus: 202,
    );
  }

  /// Verified in the shipped AOT at 0xaaea38-0xaaeb98: four required fields,
  /// PUT /watch_history/watch, with the user's own Rift bearer credential.
  /// Sending viewed=false unmarks this episode (not the whole anime).
  Future<Map<String, dynamic>> setEpisodeViewed(
    String animeId,
    int episodeNumber,
    bool viewed, {
    required String accountHash,
  }) {
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(animeId) ||
        episodeNumber <= 0 ||
        episodeNumber > 100000) {
      throw ArgumentError('Invalid Rift anime or episode number');
    }
    return _readAccountData(
      'watch_history/watch',
      'USER.WATCH_HISTORY.WATCHED',
      method: 'PUT',
      body: {
        'animeId': animeId,
        'viewed': viewed,
        'episode_number': episodeNumber,
        'useLastInteractedEpisode': false,
      },
      accountHash: accountHash,
    );
  }

  /// Rift has five independent rating dimensions, not Witcher's single
  /// rating. The AOT emits doubles for all five fields and optional review.
  Future<Map<String, dynamic>> rateAnime(
    String animeId, {
    required num general,
    required num story,
    required num characters,
    required num animation,
    required num music,
    required String accountHash,
  }) {
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(animeId)) {
      throw ArgumentError('Invalid Rift anime ID');
    }
    final scores = [general, story, characters, animation, music];
    if (scores.any((score) => !score.isFinite || score < 1 || score > 10)) {
      throw ArgumentError('Rift rating dimensions must each be 1–10');
    }
    return _readAccountData(
      'my_list/rate',
      'USER.MY_LIST.RATE',
      method: 'PUT',
      body: {
        'animeId': animeId,
        'general_rating': general.toDouble(),
        'story_rating': story.toDouble(),
        'characters_rating': characters.toDouble(),
        'animation_rating': animation.toDouble(),
        'music_rating': music.toDouble(),
      },
      accountHash: accountHash,
    );
  }

  Future<Map<String, dynamic>> fetchAnimeRating(
    String animeId, {
    required String accountHash,
  }) {
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(animeId)) {
      throw ArgumentError('Invalid Anime Rift anime ID');
    }
    // Use the account-authenticated details, not the cached guest catalog
    // response: the original APK exposes per-user interactions here.
    return _readAccountData(
      'library/details/$animeId',
      'ANIME.LIBRARY.DETAILS',
      accountHash: accountHash,
    );
  }

  /// Native AOT 0xad6898-0xad6910: PUT clear/one; id is the watch-history
  /// record ID (not the anime ID). check_last_episode is true in the APK.
  Future<Map<String, dynamic>> removeWatchHistoryRecord(
    String recordId,
    String animeId, {
    required String accountHash,
  }) {
    final safeId = RegExp(r'^[A-Za-z0-9_-]+$');
    if (!safeId.hasMatch(recordId) || !safeId.hasMatch(animeId)) {
      throw ArgumentError('Invalid Rift history record/anime IDs');
    }
    return _readAccountData(
      'watch_history/clear/one',
      'USER.WATCH_HISTORY.CLEAR_ONE',
      method: 'PUT',
      body: {'id': recordId, 'animeId': animeId, 'check_last_episode': true},
      accountHash: accountHash,
    );
  }

  /// Native AOT 0xad91d4-0xad9254: PUT clear/multi with the selected
  /// history record IDs. Do not attempt this with unverified IDs.
  Future<Map<String, dynamic>> removeWatchHistoryMany(
    List<String> recordIds, {
    required String accountHash,
  }) {
    if (recordIds.isEmpty ||
        recordIds.length > 10000 ||
        recordIds.any((id) => !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id))) {
      throw ArgumentError('Invalid Rift history record IDs');
    }
    return _readAccountData(
      'watch_history/clear/multi',
      'USER.WATCH_HISTORY.CLEAR_MANY',
      method: 'PUT',
      body: {'ids': recordIds},
      accountHash: accountHash,
    );
  }

  /// Rift APK comment-create request uses eventId and comment: the comment
  /// event is the anime ID or episode ID, not both catalogue filter IDs.
  /// Comment creation is always authenticated; the catalog account is never
  /// substituted for the separate AnimeRift identity.
  Future<Map<String, dynamic>> createComment({
    required String animeId,
    String? episodeId,
    String? parentId,
    required String text,
  }) {
    final body = commentTargetFields(
      eventId: episodeId ?? animeId,
      parentId: parentId,
    );
    final content = text.trim();
    if (content.isEmpty || content.length > 5000) {
      throw ArgumentError('Invalid Anime Rift comment');
    }
    return _readAccountData(
      'comment/create',
      'COMMENTS.CREATE',
      method: 'POST',
      body: {...body, 'comment': content},
    );
  }

  static Map<String, dynamic> commentTargetFields({
    required String eventId,
    String? parentId,
  }) {
    final valid = RegExp(r'^[A-Za-z0-9._~-]+$');
    if (!valid.hasMatch(eventId) ||
        (parentId != null && !valid.hasMatch(parentId))) {
      throw ArgumentError('Invalid Anime Rift comment target');
    }
    return {'eventId': eventId, if (parentId != null) 'parentId': parentId};
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
        path == 'comment/all' && method == 'GET' ||
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
      _forceRegistration = true;
      try {
        await _ensureReady();
      } finally {
        _forceRegistration = false;
      }
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
