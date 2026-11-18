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
}

/// Abstract HTTP transport for Witanime catalog, playback, account, and sync.
abstract interface class WitanimeTransport {
  Future<WitanimeHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const {},
    bool followRedirects = true,
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
  DioWitanimeTransport({
    Dio? dio,
    WitanimeSessionHeaderProvider? sessionHeaders,
  }) : _dio =
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
       _ownsDio = dio == null,
       _sessionHeaders = sessionHeaders;

  static const String defaultUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

  final Dio _dio;
  final bool _ownsDio;
  final WitanimeSessionHeaderProvider? _sessionHeaders;

  static bool _isWitanimeHost(Uri uri) =>
      uri.host == 'witanime.site' || uri.host.endsWith('.witanime.site');

  Future<Map<String, String>> _mergedHeaders(
    Uri uri,
    Map<String, String> explicit,
  ) async {
    final merged = <String, String>{};
    if (_sessionHeaders != null && _isWitanimeHost(uri)) {
      merged.addAll(await _sessionHeaders(uri));
    }
    merged.addAll(explicit);
    return merged;
  }

  @override
  Future<WitanimeHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const {},
    bool followRedirects = true,
    CancelToken? cancelToken,
    String operation = 'get',
  }) async {
    final elapsed = Stopwatch()..start();
    try {
      final merged = await _mergedHeaders(uri, headers);
      final response = await _dio.getUri<String>(
        uri,
        cancelToken: cancelToken,
        options: Options(
          headers: merged,
          followRedirects: followRedirects,
          responseType: ResponseType.plain,
          validateStatus: (status) => status != null && status < 600,
        ),
      );
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
