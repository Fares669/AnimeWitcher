import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import 'http_defaults.dart';

const String kStaleConnectionRetriedExtra = 'staleConnectionRetried';

/// Socket / connection failures left over after the radio comes back.
///
/// Dart's [HttpClient] keeps idle sockets. After airplane mode or a Wi-Fi
/// drop those sockets look alive until the next write, so Retry fails
/// immediately and the catalog stays on the offline screen.
bool isStaleNetworkError(DioException error) {
  switch (error.type) {
    case DioExceptionType.cancel:
      return false;
    case DioExceptionType.connectionError:
    case DioExceptionType.connectionTimeout:
      return true;
    case DioExceptionType.unknown:
      final inner = error.error;
      return inner is SocketException || inner is HttpException;
    default:
      return false;
  }
}

/// [HttpClient] adapter that can drop its connection pool after reconnect.
class ResettableIoHttpClientAdapter implements HttpClientAdapter {
  ResettableIoHttpClientAdapter() : _inner = _createInner();

  IOHttpClientAdapter _inner;

  static IOHttpClientAdapter _createInner() {
    return IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        client.idleTimeout = const Duration(seconds: 10);
        // Keep Dart range-recovery on the same 16-connection ceiling as the
        // native slow-start manager. This is a ceiling, not an eager fan-out.
        client.maxConnectionsPerHost = 16;
        return client;
      },
    );
  }

  void reset() {
    _inner.close(force: true);
    _inner = _createInner();
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    return _inner.fetch(options, requestStream, cancelFuture);
  }

  @override
  void close({bool force = false}) => _inner.close(force: force);
}

void resetStaleHttpClient(Dio dio) {
  final adapter = dio.httpClientAdapter;
  if (adapter is ResettableIoHttpClientAdapter) {
    adapter.reset();
  }
}

/// Retries a request once after a stale-socket error, on a fresh [HttpClient].
class StaleConnectionRetryInterceptor extends Interceptor {
  StaleConnectionRetryInterceptor(this._dio);

  final Dio _dio;

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    if (err.requestOptions.extra[kStaleConnectionRetriedExtra] == true ||
        !isStaleNetworkError(err)) {
      handler.next(err);
      return;
    }
    resetStaleHttpClient(_dio);
    err.requestOptions.extra[kStaleConnectionRetriedExtra] = true;
    try {
      final response = await _dio.fetch<dynamic>(err.requestOptions);
      handler.resolve(response);
    } on DioException catch (retryError) {
      handler.next(retryError);
    }
  }
}

Dio createAnimeWitcherDio({
  Duration connectTimeout = const Duration(seconds: 15),
  Duration receiveTimeout = const Duration(seconds: 15),
  HttpClientAdapter? httpClientAdapter,
}) {
  final dio = Dio(
    BaseOptions(
      connectTimeout: connectTimeout,
      receiveTimeout: receiveTimeout,
      headers: const {'User-Agent': kDefaultBrowserUserAgent},
    ),
  );
  dio.httpClientAdapter = httpClientAdapter ?? ResettableIoHttpClientAdapter();
  dio.interceptors.add(StaleConnectionRetryInterceptor(dio));
  return dio;
}
