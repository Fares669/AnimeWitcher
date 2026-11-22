import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../network/http_defaults.dart';
import '../../services/app_diagnostics.dart';
import '../provider_stream_exception.dart';

class Anime3rbBrowserRequiredException
    implements ProviderBrowserRequiredException {
  const Anime3rbBrowserRequiredException(this.message, {this.watchUrl});

  @override
  final String message;
  @override
  final Uri? watchUrl;

  @override
  String toString() => message;
}

class Anime3rbRateLimitException implements ProviderRateLimitException {
  const Anime3rbRateLimitException([
    this.message = 'تجاوزت حد الطلبات على Anime3rb، انتظر قليلًا ثم أعد المحاولة.',
  ]);

  @override
  final String message;

  @override
  bool get canTryNextSource => false;

  @override
  String toString() => message;
}

class Anime3rbSourceUnavailableException
    implements ProviderSourceUnavailableException {
  const Anime3rbSourceUnavailableException([
    this.message = 'تعذّر تحميل هذا السيرفر من Anime3rb، جرّب سيرفرًا أو جودة أخرى.',
  ]);

  @override
  final String message;

  @override
  String toString() => message;
}

/// Sanitized operation outcome names for diagnostics without URLs or secrets.
String classifyAnime3rbFailure(Object error, {int? statusCode}) {
  final code =
      statusCode ?? (error is DioException ? error.response?.statusCode : null);
  if (code == 429) return 'rate_limited';
  if (code == 401 || code == 419) return 'auth_required';
  if (code == 403 || code == 503) return 'cloudflare_or_forbidden';
  if (code != null && code >= 400) return 'http_$code';
  if (error is TimeoutException) return 'timeout';
  if (error is DioException) {
    if (error.error is TimeoutException) return 'timeout';
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

void recordAnime3rbDiagnostic(
  String operation, {
  required String status,
  required int durationMs,
  String? reason,
  String? errorType,
}) {
  appDiagnostics.record('anime3rb.operation', <String, Object?>{
    'action': operation,
    'status': status,
    'durationMs': durationMs,
    if (reason != null && reason.isNotEmpty) 'reason': reason,
    if (errorType != null && errorType.isNotEmpty) 'errorType': errorType,
  });
}

class Anime3rbHttpResponse {
  const Anime3rbHttpResponse({
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

  bool get isCloudflareChallenge {
    if (header('cf-mitigated')?.toLowerCase() == 'challenge') return true;
    if (statusCode != 403 && statusCode != 503) return false;
    final lower = body.toLowerCase();
    return lower.contains('just a moment') ||
        lower.contains('challenges.cloudflare.com') ||
        lower.contains('cf-browser-verification') ||
        lower.contains('cf-turnstile');
  }

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

/// Abstract HTTP transport for Anime3rb catalog, Livewire RPC, and playback.
abstract interface class Anime3rbTransport {
  Future<Anime3rbHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const {},
    bool followRedirects = true,
    bool inspectMedia = false,
    CancelToken? cancelToken,
    String operation = 'get',
  });

  Future<Anime3rbHttpResponse> post(
    Uri uri, {
    Object? body,
    Map<String, String> headers = const {},
    bool followRedirects = true,
    CancelToken? cancelToken,
    String operation = 'post',
  });

  Future<Anime3rbHttpResponse> put(
    Uri uri, {
    Object? body,
    Map<String, String> headers = const {},
    bool followRedirects = true,
    CancelToken? cancelToken,
    String operation = 'put',
  });

  Future<Anime3rbHttpResponse> delete(
    Uri uri, {
    Object? body,
    Map<String, String> headers = const {},
    bool followRedirects = true,
    CancelToken? cancelToken,
    String operation = 'delete',
  });

  Future<String> fetchHtml(
    Uri uri, {
    Map<String, String> headers = const {},
    CancelToken? cancelToken,
    String operation = 'catalog',
  });

  void close({bool force = false});
}

typedef Anime3rbChallengeSolution = ({
  Map<String, String> cookies,
  String? html,
  String? userAgent,
});

typedef Anime3rbChallengeResolver =
    Future<Anime3rbChallengeSolution?> Function(
      Uri uri, {
      Map<String, String> currentCookies,
    });

typedef Anime3rbSessionHeaderProvider = Future<Map<String, String>> Function(
  Uri uri,
);

/// [Dio]-backed transport keeping browser defaults, client hints, and per-host
/// session cookies across `anime3rb.com` and `vid3rb.com`.
class DioAnime3rbTransport implements Anime3rbTransport {
  DioAnime3rbTransport({
    Dio? dio,
    this._sessionHeaders,
    Anime3rbChallengeResolver? challengeResolver,
  }) : _challengeResolver = challengeResolver,
       _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 15),
               receiveTimeout: const Duration(seconds: 15),
               responseType: ResponseType.plain,
               validateStatus: (status) => status != null && status < 600,
               headers: const {
                 'User-Agent': kDefaultBrowserUserAgent,
                 'Accept-Language': 'ar,en-US;q=0.9,en;q=0.8',
               },
             ),
           ),
       _ownsDio = dio == null;

  final Dio _dio;
  final bool _ownsDio;
  final Anime3rbSessionHeaderProvider? _sessionHeaders;
  final Anime3rbChallengeResolver? _challengeResolver;
  final Map<String, Map<String, String>> _cookiesByDomain = {};
  final Map<String, String?> _lastAuthCookies = {};
  String? _overrideUserAgent;

  String get effectiveUserAgent =>
      (_overrideUserAgent != null && _overrideUserAgent!.isNotEmpty)
      ? _overrideUserAgent!
      : kDefaultBrowserUserAgent;

  static const _hostRequestTimeout = Duration(seconds: 10);

  static String? _cookieDomain(Uri uri) {
    final host = uri.host.toLowerCase();
    if (host == 'anime3rb.com' || host.endsWith('.anime3rb.com')) {
      return 'anime3rb.com';
    }
    if (host == 'vid3rb.com' || host.endsWith('.vid3rb.com')) {
      return 'vid3rb.com';
    }
    return null;
  }

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
    final domain = _cookieDomain(uri);
    if (domain == null) return;
    final jar = _cookiesByDomain.putIfAbsent(domain, () => <String, String>{});
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
          jar.remove(name);
        } else {
          jar[name] = value;
        }
      }
    }
  }

  Future<Map<String, String>> _mergedHeaders(
    Uri uri,
    Map<String, String> explicit,
  ) async {
    final merged = <String, String>{};
    final domain = _cookieDomain(uri);
    if (domain != null) {
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
      final jar = _cookiesByDomain.putIfAbsent(domain, () => <String, String>{});
      if (authCookie != _lastAuthCookies[domain]) {
        _lastAuthCookies[domain] = authCookie;
        if (authCookie != null && authCookie.isNotEmpty) {
          jar.addAll(_parseCookieHeader(authCookie));
        }
      }
      if (jar.isNotEmpty) {
        merged['Cookie'] = jar.entries
            .map((entry) => '${entry.key}=${entry.value}')
            .join('; ');
      }
      if (_overrideUserAgent != null &&
          _overrideUserAgent!.isNotEmpty &&
          !_hasHeaderCaseInsensitive(explicit, 'User-Agent')) {
        merged['User-Agent'] = _overrideUserAgent!;
      }
      final activeUa =
          explicit['User-Agent'] ??
          explicit['user-agent'] ??
          merged['User-Agent'] ??
          _dio.options.headers['User-Agent']?.toString() ??
          kDefaultBrowserUserAgent;
      _applyClientHintsIfChrome(merged, explicit, activeUa);
    }
    merged.addAll(explicit);
    return merged;
  }

  /// Records cookies returned from an external WebView solve/login into the
  /// transport cookie jar for [uri]'s domain.
  void absorbCookies(Uri uri, Map<String, String> cookies) {
    final domain = _cookieDomain(uri);
    if (domain == null || cookies.isEmpty) return;
    final jar = _cookiesByDomain.putIfAbsent(domain, () => <String, String>{});
    for (final entry in cookies.entries) {
      final k = entry.key.trim();
      final v = entry.value.trim();
      if (k.isNotEmpty && v.isNotEmpty) {
        jar[k] = v;
      }
    }
  }

  Future<Anime3rbChallengeSolution?> _resolveChallengeIfPossible(
    Uri uri,
    Anime3rbHttpResponse blockedResponse,
    CancelToken? cancelToken,
  ) async {
    if (_challengeResolver == null ||
        !blockedResponse.isCloudflareChallenge ||
        cancelToken?.isCancelled == true) {
      return null;
    }
    final domain = _cookieDomain(uri);
    final current = domain == null
        ? const <String, String>{}
        : Map<String, String>.unmodifiable(
            _cookiesByDomain[domain] ?? const <String, String>{},
          );
    final solution = await _challengeResolver(uri, currentCookies: current);
    if (solution == null) return null;
    absorbCookies(uri, solution.cookies);
    if (solution.userAgent != null && solution.userAgent!.trim().isNotEmpty) {
      _overrideUserAgent = solution.userAgent!.trim();
    }
    return solution;
  }

  ({CancelToken? token, Timer? timer}) _requestCancellation(
    String operation,
    CancelToken? upstream, {
    bool inspectMedia = false,
  }) {
    final isHostRequest = operation.startsWith('host_');
    if (!inspectMedia && !isHostRequest) return (token: upstream, timer: null);
    final token = CancelToken();
    if (upstream?.isCancelled == true) {
      token.cancel(upstream?.cancelError?.error);
    } else if (upstream != null) {
      unawaited(
        upstream.whenCancel.then((error) {
          if (!token.isCancelled) token.cancel(error.error);
        }),
      );
    }
    final timer = isHostRequest
        ? Timer(_hostRequestTimeout, () {
            if (!token.isCancelled) {
              token.cancel(TimeoutException(operation, _hostRequestTimeout));
            }
          })
        : null;
    return (token: token, timer: timer);
  }

  @override
  Future<Anime3rbHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const {},
    bool followRedirects = true,
    bool inspectMedia = false,
    CancelToken? cancelToken,
    String operation = 'get',
  }) async {
    final first = await _getOnce(
      uri,
      headers: headers,
      followRedirects: followRedirects,
      inspectMedia: inspectMedia,
      cancelToken: cancelToken,
      operation: operation,
    );
    final solution = await _resolveChallengeIfPossible(uri, first, cancelToken);
    if (solution == null) return first;

    final retried = await _getOnce(
      uri,
      headers: headers,
      followRedirects: followRedirects,
      inspectMedia: inspectMedia,
      cancelToken: cancelToken,
      operation: '${operation}_cf_retry',
    );
    if (retried.isCloudflareChallenge &&
        followRedirects &&
        !inspectMedia &&
        solution.html != null &&
        solution.html!.trim().isNotEmpty) {
      final webViewResp = Anime3rbHttpResponse(
        statusCode: 200,
        body: solution.html!,
        finalUri: uri,
      );
      if (!webViewResp.isCloudflareChallenge) {
        return webViewResp;
      }
    }
    return retried;
  }

  Future<Anime3rbHttpResponse> _getOnce(
    Uri uri, {
    Map<String, String> headers = const {},
    bool followRedirects = true,
    bool inspectMedia = false,
    CancelToken? cancelToken,
    String operation = 'get',
  }) async {
    final elapsed = Stopwatch()..start();
    final request = _requestCancellation(
      operation,
      cancelToken,
      inspectMedia: inspectMedia,
    );
    try {
      final merged = await _mergedHeaders(uri, headers);
      final requestCancel = request.token;
      final response = inspectMedia
          ? await _dio.getUri<ResponseBody>(
              uri,
              cancelToken: requestCancel,
              options: Options(
                headers: merged,
                followRedirects: followRedirects,
                responseType: ResponseType.stream,
                validateStatus: (status) => status != null && status < 600,
              ),
            )
          : await _dio.getUri<String>(
              uri,
              cancelToken: requestCancel,
              options: Options(
                headers: merged,
                followRedirects: followRedirects,
                responseType: ResponseType.plain,
                validateStatus: (status) => status != null && status < 600,
              ),
            );
      _absorbSetCookies(uri, response.headers.map);
      final statusCode = response.statusCode ?? 0;
      final data = response.data;
      var body = switch (data) {
        final String text => text,
        Map<Object?, Object?> _ || List<Object?> _ => jsonEncode(data),
        _ => '',
      };
      if (data is ResponseBody) {
        final metadata = Anime3rbHttpResponse(
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
      recordAnime3rbDiagnostic(
        operation,
        status: statusCode >= 400 ? 'http_error' : 'ok',
        durationMs: elapsed.elapsedMilliseconds,
        reason: statusCode >= 400 ? 'http_$statusCode' : null,
      );
      return Anime3rbHttpResponse(
        statusCode: statusCode,
        body: body,
        headers: response.headers.map,
        finalUri: response.realUri,
      );
    } catch (error) {
      recordAnime3rbDiagnostic(
        operation,
        status: 'failed',
        durationMs: elapsed.elapsedMilliseconds,
        errorType: classifyAnime3rbFailure(error),
      );
      rethrow;
    } finally {
      request.timer?.cancel();
    }
  }

  @override
  Future<Anime3rbHttpResponse> post(
    Uri uri, {
    Object? body,
    Map<String, String> headers = const {},
    bool followRedirects = true,
    CancelToken? cancelToken,
    String operation = 'post',
  }) => _sendWithBody(
    'POST',
    uri,
    body: body,
    headers: headers,
    followRedirects: followRedirects,
    cancelToken: cancelToken,
    operation: operation,
  );

  @override
  Future<Anime3rbHttpResponse> put(
    Uri uri, {
    Object? body,
    Map<String, String> headers = const {},
    bool followRedirects = true,
    CancelToken? cancelToken,
    String operation = 'put',
  }) => _sendWithBody(
    'PUT',
    uri,
    body: body,
    headers: headers,
    followRedirects: followRedirects,
    cancelToken: cancelToken,
    operation: operation,
  );

  @override
  Future<Anime3rbHttpResponse> delete(
    Uri uri, {
    Object? body,
    Map<String, String> headers = const {},
    bool followRedirects = true,
    CancelToken? cancelToken,
    String operation = 'delete',
  }) => _sendWithBody(
    'DELETE',
    uri,
    body: body,
    headers: headers,
    followRedirects: followRedirects,
    cancelToken: cancelToken,
    operation: operation,
  );

  Future<Anime3rbHttpResponse> _sendWithBody(
    String method,
    Uri uri, {
    Object? body,
    Map<String, String> headers = const {},
    bool followRedirects = true,
    CancelToken? cancelToken,
    required String operation,
  }) async {
    final first = await _sendWithBodyOnce(
      method,
      uri,
      body: body,
      headers: headers,
      followRedirects: followRedirects,
      cancelToken: cancelToken,
      operation: operation,
    );
    final solution = await _resolveChallengeIfPossible(
      uri,
      first,
      cancelToken,
    );
    if (solution == null) return first;
    return _sendWithBodyOnce(
      method,
      uri,
      body: body,
      headers: headers,
      followRedirects: followRedirects,
      cancelToken: cancelToken,
      operation: '${operation}_cf_retry',
    );
  }

  Future<Anime3rbHttpResponse> _sendWithBodyOnce(
    String method,
    Uri uri, {
    Object? body,
    Map<String, String> headers = const {},
    bool followRedirects = true,
    CancelToken? cancelToken,
    required String operation,
  }) async {
    final elapsed = Stopwatch()..start();
    final request = _requestCancellation(operation, cancelToken);
    try {
      final merged = await _mergedHeaders(uri, headers);
      final response = await _dio.requestUri<String>(
        uri,
        data: body,
        cancelToken: request.token,
        options: Options(
          method: method,
          headers: merged,
          followRedirects: followRedirects,
          responseType: ResponseType.plain,
          validateStatus: (status) => status != null && status < 600,
        ),
      );
      _absorbSetCookies(uri, response.headers.map);
      final statusCode = response.statusCode ?? 0;
      recordAnime3rbDiagnostic(
        operation,
        status: statusCode >= 400 ? 'http_error' : 'ok',
        durationMs: elapsed.elapsedMilliseconds,
        reason: statusCode >= 400 ? 'http_$statusCode' : null,
      );
      return Anime3rbHttpResponse(
        statusCode: statusCode,
        body: response.data ?? '',
        headers: response.headers.map,
        finalUri: response.realUri,
      );
    } catch (error) {
      recordAnime3rbDiagnostic(
        operation,
        status: 'failed',
        durationMs: elapsed.elapsedMilliseconds,
        errorType: classifyAnime3rbFailure(error),
      );
      rethrow;
    } finally {
      request.timer?.cancel();
    }
  }

  @override
  Future<String> fetchHtml(
    Uri uri, {
    Map<String, String> headers = const {},
    CancelToken? cancelToken,
    String operation = 'catalog',
  }) async {
    final response = await get(
      uri,
      headers: {
        'Accept':
            'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        ...headers,
      },
      followRedirects: true,
      cancelToken: cancelToken,
      operation: operation,
    );
    if (response.statusCode == 429) {
      throw const Anime3rbRateLimitException();
    }
    if (response.isCloudflareChallenge) {
      throw Anime3rbBrowserRequiredException(
        'يتطلب الوصول إلى Anime3rb إكمال تحقق Cloudflare في المتصفح.',
        watchUrl: uri,
      );
    }
    if (!response.isSuccess) {
      throw FormatException('Anime3rb HTTP ${response.statusCode}');
    }
    if (response.body.trim().isEmpty) {
      throw const FormatException('Anime3rb response is empty');
    }
    return response.body;
  }

  @override
  void close({bool force = false}) {
    if (_ownsDio) _dio.close(force: force);
  }
}
