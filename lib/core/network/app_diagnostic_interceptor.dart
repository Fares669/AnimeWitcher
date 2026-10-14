import 'package:dio/dio.dart';

import '../logger/app_diagnostics.dart';

int _nextRequestId = 0;

class _RequestTrace {
  _RequestTrace() : id = _nextRequestId = (_nextRequestId % 1000000000) + 1;

  final int id;
  int attempt = 0;
  Stopwatch timer = Stopwatch();
}

/// Metadata-only HTTP diagnostics. Expando never keeps a request alive.
class AppDiagnosticInterceptor extends Interceptor {
  AppDiagnosticInterceptor({
    AppDiagnostics? diagnostics,
    this.operation = 'shared_http',
  }) : _diagnostics = diagnostics ?? appDiagnostics;

  final AppDiagnostics _diagnostics;
  final String operation;
  final Expando<_RequestTrace> _traces = Expando<_RequestTrace>();

  Map<String, Object?> _fields(RequestOptions options, _RequestTrace trace) => {
    'request_id': trace.id,
    'attempt': trace.attempt,
    'operation': operation,
    'method': switch (options.method.length <= 16
        ? options.method.toUpperCase()
        : 'OTHER') {
      'GET' => 'GET',
      'POST' => 'POST',
      'PUT' => 'PUT',
      'PATCH' => 'PATCH',
      'DELETE' => 'DELETE',
      'HEAD' => 'HEAD',
      'OPTIONS' => 'OPTIONS',
      _ => 'OTHER',
    },
  };

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (_diagnostics.enabled) {
      final trace = _traces[options] ??= _RequestTrace();
      trace.attempt++;
      trace.timer = Stopwatch()..start();
      _diagnostics.record('network_start', fields: _fields(options, trace));
    }
    handler.next(options);
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    final trace = _traces[response.requestOptions];
    if (trace != null) {
      trace.timer.stop();
      _diagnostics.record(
        'network_finish',
        fields: {
          ..._fields(response.requestOptions, trace),
          'status': response.statusCode,
          'duration_ms': trace.timer.elapsedMilliseconds,
        },
      );
    }
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final trace = _traces[err.requestOptions];
    if (trace != null) {
      trace.timer.stop();
      _diagnostics.recordError(
        'network_error',
        err,
        err.stackTrace,
        fields: {
          ..._fields(err.requestOptions, trace),
          'status': err.response?.statusCode,
          'duration_ms': trace.timer.elapsedMilliseconds,
          'error_type': err.type.name,
        },
      );
    }
    handler.next(err);
  }
}

/// Attach once, including when a client receives a caller-supplied Dio.
void attachAppDiagnosticInterceptor(Dio dio, {required String operation}) {
  if (dio.interceptors.any(
    (interceptor) => interceptor is AppDiagnosticInterceptor,
  )) {
    return;
  }
  dio.interceptors.insert(0, AppDiagnosticInterceptor(operation: operation));
}
