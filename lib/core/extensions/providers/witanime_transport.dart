import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../services/app_diagnostics.dart';

/// Sanitized operation names recorded in diagnostics without URLs or secrets.
String classifyWitanimeFailure(Object error, {int? statusCode}) {
  final code =
      statusCode ?? (error is DioException ? error.response?.statusCode : null);
  if (code == 429) return 'rate_limited';
  if (code == 401 || code == 419) return 'auth_required';
  if (code == 403 || code == 503) return 'cloudflare_or_forbidden';
  if (code != null && code >= 400) return 'http_$code';
  if (error is DioException) {
    if (error.type == DioExceptionType.cancel) return 'cancelled';
    if (error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.receiveTimeout ||
        error.type == DioExceptionType.sendTimeout) {
      return 'timeout';
    }
    return 'network_error';
  }
  if (error is FormatException) return 'parse_error';
  return error.runtimeType.toString();
}

void recordWitanimeDiagnostic(
  String operation, {
  required String status,
  required int durationMs,
  String? reason,
  String? errorType,
}) {
  appDiagnostics.record('witanime.operation', <String, Object?>{
    'action': operation,
    'status': status,
    'durationMs': durationMs,
    if (reason != null && reason.isNotEmpty) 'reason': reason,
    if (errorType != null && errorType.isNotEmpty) 'errorType': errorType,
  });
}

class WitanimeHttpResponse {
  const WitanimeHttpResponse({
    required this.statusCode,
    required this.body,
    this.headers = const <String, List<String>>{},
    this.finalUri,
  });

  final int statusCode;
  final String body;
  final Map<String, List<String>> headers;
  final Uri? finalUri;

  String? header(String name) {
    final target = name.toLowerCase();
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == target && entry.value.isNotEmpty) {
        return entry.value.first;
      }
    }
    return null;
  }

  bool get isSuccess => statusCode >= 200 && statusCode < 300;

  bool get hasMediaContent {
    final type = header('content-type')?.split(';').first.trim().toLowerCase();
    final disposition = header('content-disposition')?.toLowerCase() ?? '';
    return type?.startsWith('video/') == true ||
        type == 'application/vnd.apple.mpegurl' ||
        type == 'application/x-mpegurl' ||
        type == 'application/dash+xml' ||
        (type == 'application/octet-stream' &&
            RegExp(r'\.(?:mp4|mkv|webm|m4v|mov|avi|ts)(?:["; ]|$)')
                .hasMatch(disposition));
  }
}

/// Abstract HTTP transport for Witanime catalog, playback, account, and sync.
abstract interface class WitanimeTransport {
  Future<WitanimeHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const {},
    bool followRedirects = true,
    bool inspectMedia = false,
    CancelToken? cancelToken,
    String operation = 'get',
  });

  Future<WitanimeHttpResponse> post(
    Uri uri, {
    Object? body,
    Map<String, String> headers = const {},
    bool followRedirects = true,
    CancelToken? cancelToken,
    String operation = 'post',
  });

  Future<String> fetchHtml(
    Uri uri, {
    CancelToken? cancelToken,
    String operation = 'catalog',
  });

  void close({bool force = false});
}

typedef WitanimeSessionHeaderProvider = Future<Map<String, String>> Function(
  Uri uri,
);

/// [Dio]-backed transport preserving browser-like defaults and duration/error
/// telemetry without logging credentials, cookies, or full URLs.
class DioWitanimeTransport implements WitanimeTransport {
  DioWitanimeTransport({Dio? dio, this._sessionHeaders})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 15),
              responseType: ResponseType.plain,
              validateStatus: (status) => status != null && status < 600,
              headers: const {
                'User-Agent': defaultUserAgent,
                'Accept-Language': 'ar,en-US;q=0.9,en;q=0.8',
              },
            ),
          ),
      _ownsDio = dio == null;

  static const String defaultUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

  final Dio _dio;
  final bool _ownsDio;
  final WitanimeSessionHeaderProvider? _sessionHeaders;
  final Map<String, String> _witanimeCookies = <String, String>{};
  String? _lastAuthCookie;

  static bool _isWitanimeHost(Uri uri) =>
      uri.host == 'witanime.site' || uri.host.endsWith('.witanime.site');

  static bool _hasHeaderCaseInsensitive(
    Map<String, String> headers,
    String key,
  ) {
    final target = key.toLowerCase();
    return headers.keys.any((k) => k.toLowerCase() == target);
  }

  static void _applyClientHintsIfChrome(
    Map<String, String> target,
    Map<String, String> explicit,
    String ua,
  ) {
    if (!ua.contains('Chrome/')) return;
    final major = RegExp(r'Chrome/(\d+)').firstMatch(ua)?.group(1) ?? '131';
    final platform = ua.contains('Android')
        ? '"Android"'
        : ua.contains('Macintosh')
        ? '"macOS"'
        : ua.contains('Linux')
        ? '"Linux"'
        : '"Windows"';
    final hints = <String, String>{
      'sec-ch-ua':
          '"Google Chrome";v="$major", "Chromium";v="$major", "Not_A Brand";v="24"',
      'sec-ch-ua-mobile': ua.contains('Mobile') ? '?1' : '?0',
      'sec-ch-ua-platform': platform,
    };
    for (final entry in hints.entries) {
      if (!_hasHeaderCaseInsensitive(explicit, entry.key) &&
          !_hasHeaderCaseInsensitive(target, entry.key)) {
        target[entry.key] = entry.value;
      }
    }
  }

  static Map<String, String> _parseCookieHeader(String raw) {
    final parsed = <String, String>{};
    for (final part in raw.split(';')) {
      final eq = part.indexOf('=');
      if (eq <= 0) continue;
      final name = part.substring(0, eq).trim();
      final value = part.substring(eq + 1).trim();
      if (name.isEmpty || value.isEmpty) continue;
      parsed[name] = value;
    }
    return parsed;
  }

  void _absorbSetCookies(Uri uri, Map<String, List<String>> headers) {
    if (!_isWitanimeHost(uri)) return;
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() != 'set-cookie') continue;
      for (final rawSetCookie in entry.value) {
        final segments = rawSetCookie.split(';');
        if (segments.isEmpty) continue;
        final pair = segments.first.trim();
        final eq = pair.indexOf('=');
        if (eq <= 0) continue;
        final name = pair.substring(0, eq).trim();
        final value = pair.substring(eq + 1).trim();
        if (name.isEmpty) continue;
        final expired = segments.skip(1).any((attr) {
          final lower = attr.trim().toLowerCase();
          return lower == 'max-age=0' || lower.startsWith('max-age=-');
        });
        if (expired || value.isEmpty || value.toLowerCase() == 'deleted') {
          _witanimeCookies.remove(name);
        } else {
          _witanimeCookies[name] = value;
        }
      }
    }
  }

  Future<Map<String, String>> _mergedHeaders(
    Uri uri,
    Map<String, String> explicit,
  ) async {
    final merged = <String, String>{};
    if (_isWitanimeHost(uri)) {
      String? authCookie;
      if (_sessionHeaders != null) {
        final authHeaders = await _sessionHeaders(uri);
        for (final entry in authHeaders.entries) {
          if (entry.key.toLowerCase() == 'cookie') {
            authCookie = entry.value.trim();
          } else {
            merged[entry.key] = entry.value;
          }
        }
      }
      if (authCookie != _lastAuthCookie) {
        _lastAuthCookie = authCookie;
        _witanimeCookies.clear();
        if (authCookie != null && authCookie.isNotEmpty) {
          _witanimeCookies.addAll(_parseCookieHeader(authCookie));
        }
      }
      if (_witanimeCookies.isNotEmpty) {
        merged['Cookie'] = _witanimeCookies.entries
            .map((entry) => '${entry.key}=${entry.value}')
            .join('; ');
      }
      final activeUa =
          explicit['User-Agent'] ??
          explicit['user-agent'] ??
          merged['User-Agent'] ??
          _dio.options.headers['User-Agent']?.toString() ??
          defaultUserAgent;
      _applyClientHintsIfChrome(merged, explicit, activeUa);
    }
    merged.addAll(explicit);
    return merged;
  }

  @override
  Future<WitanimeHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const {},
    bool followRedirects = true,
    bool inspectMedia = false,
    CancelToken? cancelToken,
    String operation = 'get',
  }) async {
    final elapsed = Stopwatch()..start();
    try {
      final merged = await _mergedHeaders(uri, headers);
      final requestCancel = inspectMedia ? CancelToken() : cancelToken;
      if (inspectMedia && cancelToken != null) {
        unawaited(cancelToken.whenCancel.then(requestCancel!.cancel));
      }
      final response = await _dio.getUri<Object>(
        uri,
        cancelToken: requestCancel,
        options: Options(
          headers: merged,
          followRedirects: followRedirects,
          responseType: inspectMedia ? ResponseType.stream : ResponseType.plain,
          validateStatus: (status) => status != null && status < 600,
        ),
      );
      _absorbSetCookies(uri, response.headers.map);
      final statusCode = response.statusCode ?? 0;
      final data = response.data;
      var body = data is String ? data : '';
      if (data is ResponseBody) {
        final metadata = WitanimeHttpResponse(
          statusCode: statusCode,
          body: '',
          headers: response.headers.map,
        );
        if (metadata.hasMediaContent) {
          await data.stream.listen(null).cancel();
          requestCancel?.cancel();
        } else {
          const maxPageBytes = 2 * 1024 * 1024;
          final bytes = BytesBuilder(copy: false);
          await for (final chunk in data.stream) {
            final remaining = maxPageBytes - bytes.length;
            bytes.add(
              chunk.length <= remaining
                  ? chunk
                  : Uint8List.sublistView(chunk, 0, remaining),
            );
            if (bytes.length >= maxPageBytes) {
              requestCancel?.cancel();
              break;
            }
          }
          body = utf8.decode(bytes.takeBytes(), allowMalformed: true);
        }
      }
      recordWitanimeDiagnostic(
        operation,
        status: statusCode >= 400 ? 'http_error' : 'ok',
        durationMs: elapsed.elapsedMilliseconds,
        reason: statusCode >= 400 ? 'http_$statusCode' : null,
      );
      return WitanimeHttpResponse(
        statusCode: statusCode,
        body: body,
        headers: response.headers.map,
        finalUri: response.realUri,
      );
    } catch (error) {
      recordWitanimeDiagnostic(
        operation,
        status: 'failed',
        durationMs: elapsed.elapsedMilliseconds,
        errorType: classifyWitanimeFailure(error),
      );
      rethrow;
    }
  }

  @override
  Future<WitanimeHttpResponse> post(
    Uri uri, {
    Object? body,
    Map<String, String> headers = const {},
    bool followRedirects = true,
    CancelToken? cancelToken,
    String operation = 'post',
  }) async {
    final elapsed = Stopwatch()..start();
    try {
      final merged = await _mergedHeaders(uri, headers);
      final response = await _dio.postUri<String>(
        uri,
        data: body,
        cancelToken: cancelToken,
        options: Options(
          headers: merged,
          followRedirects: followRedirects,
          responseType: ResponseType.plain,
          validateStatus: (status) => status != null && status < 600,
        ),
      );
      _absorbSetCookies(uri, response.headers.map);
      final statusCode = response.statusCode ?? 0;
      recordWitanimeDiagnostic(
        operation,
        status: statusCode >= 400 ? 'http_error' : 'ok',
        durationMs: elapsed.elapsedMilliseconds,
        reason: statusCode >= 400 ? 'http_$statusCode' : null,
      );
      return WitanimeHttpResponse(
        statusCode: statusCode,
        body: response.data ?? '',
        headers: response.headers.map,
        finalUri: response.realUri,
      );
    } catch (error) {
      recordWitanimeDiagnostic(
        operation,
        status: 'failed',
        durationMs: elapsed.elapsedMilliseconds,
        errorType: classifyWitanimeFailure(error),
      );
      rethrow;
    }
  }

  @override
  Future<String> fetchHtml(
    Uri uri, {
    CancelToken? cancelToken,
    String operation = 'catalog',
  }) async {
    final response = await get(
      uri,
      headers: const {
        'Accept':
            'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      },
      followRedirects: false,
      cancelToken: cancelToken,
      operation: operation,
    );
    if (response.statusCode == 429) {
      throw const FormatException('Witanime rate limit reached');
    }
    if (!response.isSuccess) {
      throw FormatException('Witanime HTTP ${response.statusCode}');
    }
    if (response.body.trim().isEmpty) {
      throw const FormatException('Witanime catalog response is empty');
    }
    return response.body;
  }

  @override
  void close({bool force = false}) {
    if (_ownsDio) _dio.close(force: force);
  }
}
