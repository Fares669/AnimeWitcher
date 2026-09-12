import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:dio/dio.dart';

import 'download_retry_policy.dart';
import 'download_diagnostic_log.dart';

/// Keep retries short: a permanently dead episode must still yield its queue
/// slot, while transient CDN/radio failures should not force a manual resume.
const int kDownloadRangeRequestAttempts = 3;
const int kDownloadRangeReconnectAttempts = 2;
const int kDownloadResumeProbeBytes = 64 * 1024;
const int kDownloadRangeProgressUpdateBytes = 512 * 1024;
const Duration kDownloadRangeRetryBaseDelay = kDownloadRetryBaseDelay;
const Duration kDownloadRangeProgressUpdateInterval = Duration(
  milliseconds: 250,
);

/// Keep the first request as tolerant as the old implementation. Once a host
/// has answered successfully, reconnects can fail much faster using the same
/// max(observed RTT, minimum) + safety-margin idea as Gopeed.
const Duration kDownloadRangeDefaultResponseTimeout = Duration(seconds: 30);
const Duration kDownloadRangeMinFastFailTimeout = Duration(seconds: 3);
const Duration kDownloadRangeMaxFastFailTimeout = Duration(seconds: 30);
const Duration kDownloadRangeStreamIdleTimeout = Duration(seconds: 30);

/// Compatibility wrappers used by existing tests/callers. The policy itself is
/// centralized in download_retry_policy.dart.
bool isRetryableDownloadHttpStatus(int? status) =>
    isRetryableDownloadStatus(status);

Duration downloadRangeRetryDelay({
  required int retryIndex,
  String? retryAfter,
}) => downloadRetryDelay(
  retryIndex: retryIndex,
  retryAfter: retryAfter,
  jitterUnit: 0.5,
);

/// Gopeed measures a successful connection and then gives later attempts a
/// 50% safety margin, with a three-second floor. AnimeWitcher keeps the old
/// 30-second timeout until it has a baseline so a first request on a slow
/// mobile network is never made more aggressive by this optimization.
Duration downloadRangeFastFailTimeout(Duration? maxSuccessfulConnectTime) {
  if (maxSuccessfulConnectTime == null ||
      maxSuccessfulConnectTime <= Duration.zero) {
    return kDownloadRangeDefaultResponseTimeout;
  }

  final observedMicros = maxSuccessfulConnectTime.inMicroseconds;
  final minimumMicros = kDownloadRangeMinFastFailTimeout.inMicroseconds;
  final maximumMicros = kDownloadRangeMaxFastFailTimeout.inMicroseconds;
  final withMargin = observedMicros >= minimumMicros
      ? observedMicros * 3 ~/ 2
      : minimumMicros;
  return Duration(
    microseconds: withMargin.clamp(minimumMicros, maximumMicros).toInt(),
  );
}

bool shouldRememberDownloadRangeConnectTime({
  required int? statusCode,
  required String? requestedRange,
  required String? contentRange,
}) {
  if (statusCode != 206 || requestedRange == null || contentRange == null) {
    return false;
  }
  final request = RegExp(r'^bytes=(\d+)-(\d*)$')
      .firstMatch(requestedRange.trim().toLowerCase());
  final response = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$')
      .firstMatch(contentRange.trim().toLowerCase());
  if (request == null || response == null) return false;

  final requestStart = int.parse(request[1]!);
  final requestEndText = request[2]!;
  final responseStart = int.parse(response[1]!);
  final responseEnd = int.parse(response[2]!);
  final resourceSize = int.parse(response[3]!);
  if (responseStart != requestStart ||
      responseEnd < responseStart ||
      resourceSize <= responseEnd) {
    return false;
  }
  if (requestEndText.isNotEmpty && responseEnd != int.parse(requestEndText)) {
    return false;
  }
  return true;
}

bool shouldEmitDownloadRangeProgress({
  required int written,
  required int lastReportedWritten,
  required Duration elapsed,
}) =>
    written - lastReportedWritten >= kDownloadRangeProgressUpdateBytes ||
    elapsed >= kDownloadRangeProgressUpdateInterval;

/// Strong ETags are preferred for `If-Range`; HTTP dates are the standards-
/// compliant fallback. Weak ETags are intentionally ignored because RFC range
/// validation does not allow them for If-Range.
String? downloadIfRangeValidator(Headers headers) {
  final etag = headers.value('etag')?.trim();
  if (etag != null && etag.isNotEmpty && !etag.toLowerCase().startsWith('w/')) {
    return etag;
  }
  final lastModified = headers.value('last-modified')?.trim();
  if (lastModified != null && lastModified.isNotEmpty) return lastModified;
  return null;
}

class DownloadRangeFailure {
  const DownloadRangeFailure({
    required this.action,
    this.statusCode,
    this.resourceSize = -1,
    this.error,
  });

  final DownloadFailureAction action;
  final int? statusCode;
  final int resourceSize;
  final Object? error;
}

/// A cancellable append. Starting returns after the response is validated,
/// leaving the download service's control queue free for pause/cancel.
///
/// Gopeed treats every HTTP range connection as an independently recoverable
/// worker. This keeps AnimeWitcher's native/background architecture, but uses
/// the same principle for the Dart fallback path: if a response stream dies,
/// reconnect from the last durable byte instead of pausing the whole episode.
///
/// Before appending to an existing partial file we also verify a saved prefix
/// against the current resource. If the origin exposes a strong ETag or
/// Last-Modified validator, all remaining requests carry it as `If-Range`.
Stream<T> _cancelRangeStream<T>(Stream<T> source, CancelToken token) async* {
  final iterator = StreamIterator<T>(source);
  try {
    while (!token.isCancelled) {
      final moved = await Future.any<Object?>([
        iterator.moveNext(),
        token.whenCancel.then<Object?>((_) => null),
      ]);
      if (token.isCancelled || moved != true) break;
      yield iterator.current;
    }
  } finally {
    await iterator.cancel();
  }
}

class DownloadRangeTransfer {
  DownloadRangeTransfer(this.dio, {math.Random? random, this.diagnosticLog})
    : _random = random ?? math.Random();

  final DownloadDiagnosticLog? diagnosticLog;
  final Dio dio;
  final math.Random _random;
  final _operations = <String, _RangeOperation>{};
  final _lastFailures = <String, DownloadRangeFailure>{};
  final _maxConnectTimesByOrigin = <String, Duration>{};
  bool _disposed = false;

  bool isActive(String id) => _operations.containsKey(id);
  Set<String> get activeTaskIds => _operations.keys.toSet();
  DownloadRangeFailure? failureFor(String id) => _lastFailures[id];

  /// Verify a visible local prefix against a candidate source without
  /// appending bytes. Multipart URL refresh uses this before retaining old
  /// ranges. The returned validator may be pinned by the caller, but a matching
  /// byte prefix is sufficient when the origin exposes no validator.
  Future<({bool matches, String? validator})> verifyExistingPrefix({
    required String id,
    required String url,
    required Map<String, String> headers,
    required File file,
    required int written,
  }) async {
    if (written <= 0 || !await file.exists() || await file.length() < written) {
      return (matches: false, validator: null);
    }
    final operation = _RangeOperation(id: '$id.identity', canRefreshUrl: false);
    try {
      final probe = await _probeSavedPrefix(
        operation: operation,
        url: url,
        headers: headers,
        spec: _RangeSpec.fromHeaders(headers),
        file: file,
        written: written,
      );
      return (matches: probe != null, validator: probe?.validator);
    } finally {
      operation.token.cancel('Identity probe complete');
    }
  }

  Future<bool> stop(String id) async {
    diagnosticLog?.record('range.stop', {'taskId': id});
    final operation = _operations[id];
    if (operation == null) return false;
    operation.token.cancel('Download stopped');
    await operation.done.future;
    return true;
  }

  Future<void> dispose() async {
    _disposed = true;
    final operations = _operations.values.toList(growable: false);
    for (final operation in operations) {
      operation.token.cancel('Service disposed');
    }
    await Future.wait<void>(
      operations.map((operation) => operation.done.future),
    );
  }

  Future<bool> start({
    required String id,
    required String url,
    required Map<String, String> headers,
    required File file,
    required int existingBytes,
    required int expectedBytes,
    required Future<void> Function(int written, int total, bool complete)
    onState,
    required Future<void> Function(int written, int total) onPaused,
    Future<void> Function(DownloadRangeFailure failure)? onFailure,
    bool canRefreshUrl = false,
  }) async {
    if (_disposed) return false;
    if (_operations.containsKey(id)) return true;
    _lastFailures.remove(id);
    final operation = _RangeOperation(id: id, canRefreshUrl: canRefreshUrl);
    diagnosticLog?.record('range.start', {
      'taskId': id,
      'bytes': existingBytes,
      'total': expectedBytes,
    });
    _operations[id] = operation;
    var launched = false;
    _OpenedRange? opened;
    try {
      final spec = _RangeSpec.fromHeaders(headers);
      if (!await file.exists() || await file.length() != existingBytes) {
        operation.failure = const DownloadRangeFailure(
          action: DownloadFailureAction.park,
        );
        return false;
      }
      final guardedHeaders = await _guardResumeHeaders(
        operation: operation,
        url: url,
        headers: headers,
        spec: spec,
        file: file,
        written: existingBytes,
      );
      if (guardedHeaders == null) return false;
      opened = await _openWithRetries(
        operation: operation,
        url: url,
        headers: guardedHeaders,
        spec: spec,
        written: existingBytes,
        expectedBytes: expectedBytes,
        attempts: kDownloadRangeRequestAttempts,
      );
      if (opened == null) return false;
      launched = true;
      unawaited(
        _receive(
          id: id,
          operation: operation,
          url: url,
          headers: guardedHeaders,
          spec: spec,
          file: file,
          opened: opened,
          written: existingBytes,
          expectedBytes: expectedBytes,
          onState: onState,
          onPaused: onPaused,
          onFailure: onFailure,
        ),
      );
      return true;
    } catch (error) {
      operation.failure ??= DownloadRangeFailure(
        action: isNoSpaceDownloadError(error)
            ? DownloadFailureAction.stopNoSpace
            : DownloadFailureAction.park,
        error: error,
      );
      return false;
    } finally {
      if (!launched) {
        try {
          operation.token.cancel();
          await _discard(opened?.stream);
          final failure = operation.failure;
          if (failure != null) {
            diagnosticLog?.record('range.failure', {
              'taskId': id,
              'reason': failure.action.name,
              'errorType': failure.error?.runtimeType.toString(),
            });
            _lastFailures[id] = failure;
            if (onFailure != null) await onFailure(failure);
          }
        } finally {
          _operations.remove(id);
          if (!operation.done.isCompleted) operation.done.complete();
        }
      }
    }
  }

  Future<Map<String, String>?> _guardResumeHeaders({
    required _RangeOperation operation,
    required String url,
    required Map<String, String> headers,
    required _RangeSpec spec,
    required File file,
    required int written,
  }) async {
    final guarded = Map<String, String>.from(headers);
    if (written <= 0) return guarded;

    final existing = _headerValue(guarded, 'if-range');
    if (_usableIfRange(existing) != null) return guarded;
    guarded.removeWhere((key, _) => key.toLowerCase() == 'if-range');

    final probe = await _probeSavedPrefix(
      operation: operation,
      url: url,
      headers: guarded,
      spec: spec,
      file: file,
      written: written,
    );
    if (probe == null) return null;
    if (probe.validator != null) {
      guarded['If-Range'] = probe.validator!;
    }
    return guarded;
  }

  Future<_ResumeProbe?> _probeSavedPrefix({
    required _RangeOperation operation,
    required String url,
    required Map<String, String> headers,
    required _RangeSpec spec,
    required File file,
    required int written,
  }) async {
    final boundedSize = spec.limit == null
        ? written
        : math.min(written, spec.limit! - spec.origin + 1);
    final probeLength = math.min(boundedSize, kDownloadResumeProbeBytes);
    if (probeLength <= 0) return null;
    final probeStart = spec.origin;
    final probeEnd = probeStart + probeLength - 1;
    final localPrefix = await _readPrefix(file, probeLength);
    if (localPrefix.length != probeLength) return null;

    for (var attempt = 0; attempt < kDownloadRangeRequestAttempts; attempt++) {
      if (operation.token.isCancelled) return null;
      Response<ResponseBody>? response;
      Stream<List<int>>? stream;
      try {
        final requestHeaders = Map<String, String>.from(headers)
          ..removeWhere(
            (key, _) =>
                key.toLowerCase() == 'range' || key.toLowerCase() == 'if-range',
          );
        requestHeaders['Range'] = 'bytes=$probeStart-$probeEnd';
        requestHeaders['Accept-Encoding'] = 'identity';
        response = await _getRangeResponse(
          operation: operation,
          url: url,
          headers: requestHeaders,
          timeoutMessage: 'Resume probe timeout',
        );
        stream = response.data?.stream;
        final status = response.statusCode;
        final decision = planDownloadFailure(
          statusCode: status,
          canRefreshUrl: operation.canRefreshUrl,
          retryIndex: attempt,
          retryAfter: response.headers.value('retry-after'),
          jitterUnit: _random.nextDouble(),
        );
        if (decision.action == DownloadFailureAction.refreshUrl ||
            decision.action == DownloadFailureAction.reconcileRange) {
          operation.failure = DownloadRangeFailure(
            action: decision.action,
            statusCode: status,
            resourceSize: _unsatisfiedRangeSize(response.headers),
          );
          await _discard(stream);
          return null;
        }
        if (decision.shouldRetry) {
          await _discard(stream);
          if (attempt + 1 >= kDownloadRangeRequestAttempts) {
            operation.failure = DownloadRangeFailure(
              action: DownloadFailureAction.park,
              statusCode: status,
            );
            return null;
          }
          await _retryDelay(operation, decision.delay);
          continue;
        }

        final range = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$')
            .firstMatch(response.headers.value('content-range') ?? '');
        if (status != 206 || range == null || stream == null) {
          operation.failure = DownloadRangeFailure(
            action: DownloadFailureAction.park,
            statusCode: status,
          );
          await _discard(stream);
          return null;
        }
        final responseStart = int.parse(range[1]!);
        final responseEnd = int.parse(range[2]!);
        final resourceSize = int.parse(range[3]!);
        if (responseStart != probeStart ||
            responseEnd != probeEnd ||
            responseEnd >= resourceSize) {
          operation.failure = DownloadRangeFailure(
            action: DownloadFailureAction.park,
            statusCode: status,
            resourceSize: resourceSize,
          );
          await _discard(stream);
          return null;
        }

        final remotePrefix = await _readExactStream(stream, probeLength);
        if (remotePrefix == null || !_bytesEqual(localPrefix, remotePrefix)) {
          operation.failure = const DownloadRangeFailure(
            action: DownloadFailureAction.park,
          );
          return null;
        }
        return _ResumeProbe(downloadIfRangeValidator(response.headers));
      } catch (error) {
        await _discard(stream);
        if (operation.token.isCancelled) return null;
        final decision = planDownloadFailure(
          connectionFailure: _isRetryableDownloadError(error),
          noSpaceLeft: isNoSpaceDownloadError(error),
          retryIndex: attempt,
          jitterUnit: _random.nextDouble(),
        );
        if (!decision.shouldRetry ||
            attempt + 1 >= kDownloadRangeRequestAttempts) {
          operation.failure = DownloadRangeFailure(
            action: decision.action == DownloadFailureAction.retry
                ? DownloadFailureAction.park
                : decision.action,
            error: error,
          );
          return null;
        }
        await _retryDelay(operation, decision.delay);
      }
    }
    return null;
  }

  Future<_OpenedRange?> _openWithRetries({
    required _RangeOperation operation,
    required String url,
    required Map<String, String> headers,
    required _RangeSpec spec,
    required int written,
    required int expectedBytes,
    required int attempts,
  }) async {
    for (var attempt = 0; attempt < attempts; attempt++) {
      if (operation.token.isCancelled) return null;
      Response<ResponseBody>? response;
      Stream<List<int>>? stream;
      try {
        final start = spec.origin + written;
        final requestHeaders = Map<String, String>.from(headers)
          ..removeWhere((key, _) => key.toLowerCase() == 'range');
        requestHeaders['Range'] = 'bytes=$start-${spec.limit ?? ''}';
        requestHeaders['Accept-Encoding'] = 'identity';
        response = await _getRangeResponse(
          operation: operation,
          url: url,
          headers: requestHeaders,
          timeoutMessage: 'Range response timeout',
        );
        stream = response.data?.stream;
        final status = response.statusCode;
        final decision = planDownloadFailure(
          statusCode: status,
          canRefreshUrl: operation.canRefreshUrl,
          retryIndex: attempt,
          retryAfter: response.headers.value('retry-after'),
          jitterUnit: _random.nextDouble(),
        );
        if (decision.action == DownloadFailureAction.refreshUrl ||
            decision.action == DownloadFailureAction.reconcileRange) {
          operation.failure = DownloadRangeFailure(
            action: decision.action,
            statusCode: status,
            resourceSize: _unsatisfiedRangeSize(response.headers),
          );
          await _discard(stream);
          return null;
        }
        if (decision.shouldRetry) {
          await _discard(stream);
          if (attempt + 1 >= attempts) {
            operation.failure = DownloadRangeFailure(
              action: DownloadFailureAction.park,
              statusCode: status,
            );
            return null;
          }
          await _retryDelay(operation, decision.delay);
          continue;
        }

        final range = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$')
            .firstMatch(response.headers.value('content-range') ?? '');
        if (status != 206 || range == null || stream == null) {
          operation.failure = DownloadRangeFailure(
            action: DownloadFailureAction.park,
            statusCode: status,
          );
          await _discard(stream);
          return null;
        }
        final ifRange = _usableIfRange(
          _headerValue(requestHeaders, 'if-range'),
        );
        if (ifRange != null &&
            !_responseMatchesIfRange(response.headers, ifRange)) {
          operation.failure = const DownloadRangeFailure(
            action: DownloadFailureAction.park,
          );
          await _discard(stream);
          return null;
        }
        final responseStart = int.parse(range[1]!);
        final end = int.parse(range[2]!);
        final resourceSize = int.parse(range[3]!);
        final total = spec.limit == null
            ? resourceSize
            : spec.limit! - spec.origin + 1;
        if (responseStart != start ||
            end < start ||
            end >= resourceSize ||
            end != (spec.limit ?? resourceSize - 1) ||
            (expectedBytes > 0 && total != expectedBytes) ||
            written >= total) {
          operation.failure = DownloadRangeFailure(
            action: DownloadFailureAction.park,
            statusCode: status,
            resourceSize: resourceSize,
          );
          await _discard(stream);
          return null;
        }
        return _OpenedRange(stream: stream, total: total);
      } catch (error) {
        await _discard(stream);
        if (operation.token.isCancelled) return null;
        final decision = planDownloadFailure(
          connectionFailure: _isRetryableDownloadError(error),
          noSpaceLeft: isNoSpaceDownloadError(error),
          retryIndex: attempt,
          jitterUnit: _random.nextDouble(),
        );
        if (!decision.shouldRetry || attempt + 1 >= attempts) {
          operation.failure = DownloadRangeFailure(
            action: decision.action == DownloadFailureAction.retry
                ? DownloadFailureAction.park
                : decision.action,
            error: error,
          );
          return null;
        }
        await _retryDelay(operation, decision.delay);
      }
    }
    return null;
  }

  Future<void> _retryDelay(_RangeOperation operation, Duration delay) async {
    diagnosticLog?.record('http.retry', {
      'taskId': operation.id,
      'delayMs': delay.inMilliseconds,
    });
    final elapsed = Completer<void>();
    final timer = Timer(delay, elapsed.complete);
    try {
      await Future.any<void>([
        elapsed.future,
        operation.token.whenCancel.then<void>((_) {}),
      ]);
    } finally {
      timer.cancel();
    }
  }

  Future<Response<ResponseBody>> _getRangeResponse({
    required _RangeOperation operation,
    required String url,
    required Map<String, String> headers,
    required String timeoutMessage,
  }) async {
    final requestToken = CancelToken();
    unawaited(
      operation.token.whenCancel.then((_) {
        if (!requestToken.isCancelled) {
          requestToken.cancel('Parent range transfer stopped');
        }
      }),
    );

    final responseTimeout = _responseTimeoutFor(url);
    diagnosticLog?.record('http.request', {
      'taskId': operation.id,
      'range': headers['Range'],
      'timeoutMs': responseTimeout.inMilliseconds,
    });
    final clock = Stopwatch()..start();
    try {
      final response = await dio
          .get<ResponseBody>(
            url,
            cancelToken: requestToken,
            options: Options(
              headers: headers,
              responseType: ResponseType.stream,
              receiveTimeout: kDownloadRangeStreamIdleTimeout,
              sendTimeout: const Duration(seconds: 15),
              validateStatus: (_) => true,
            ),
          )
          .timeout(
            responseTimeout,
            onTimeout: () {
              requestToken.cancel(timeoutMessage);
              throw TimeoutException(timeoutMessage);
            },
          );
      diagnosticLog?.record('http.response', {
        'taskId': operation.id,
        'httpStatus': response.statusCode,
        'elapsedMs': clock.elapsedMilliseconds,
      });
      String? requestedRange;
      for (final entry in headers.entries) {
        if (entry.key.toLowerCase() == 'range') {
          requestedRange = entry.value;
          break;
        }
      }
      if (shouldRememberDownloadRangeConnectTime(
        statusCode: response.statusCode,
        requestedRange: requestedRange,
        contentRange: response.headers.value('content-range'),
      )) {
        _rememberConnectTime(url, clock.elapsed);
      }
      return response;
    } catch (error) {
      diagnosticLog?.record('http.error', {
        'taskId': operation.id,
        'errorType': error.runtimeType.toString(),
        'elapsedMs': clock.elapsedMilliseconds,
      });
      rethrow;
    } finally {
      clock.stop();
    }
  }

  Duration _responseTimeoutFor(String url) =>
      downloadRangeFastFailTimeout(_maxConnectTimesByOrigin[_originKey(url)]);

  void _rememberConnectTime(String url, Duration elapsed) {
    if (elapsed <= Duration.zero) return;
    final key = _originKey(url);
    final previous = _maxConnectTimesByOrigin[key];
    if (previous == null || elapsed > previous) {
      _maxConnectTimesByOrigin[key] = elapsed;
    }
  }

  String _originKey(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return url;
    if (uri.scheme == 'http' || uri.scheme == 'https') {
      return uri.origin.toLowerCase();
    }
    return '${uri.scheme.toLowerCase()}://${uri.host.toLowerCase()}';
  }

  bool _isRetryableDownloadError(Object error) {
    if (error is TimeoutException ||
        error is SocketException ||
        error is HttpException) {
      return true;
    }
    if (error is DioException) {
      if (error.type == DioExceptionType.cancel) return false;
      final status = error.response?.statusCode;
      if (isRetryableDownloadStatus(status)) return true;
      switch (error.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.receiveTimeout:
        case DioExceptionType.transformTimeout:
        case DioExceptionType.connectionError:
        case DioExceptionType.unknown:
          return true;
        case DioExceptionType.badCertificate:
        case DioExceptionType.badResponse:
        case DioExceptionType.cancel:
          return false;
      }
    }
    return false;
  }

  Future<void> _receive({
    required String id,
    required _RangeOperation operation,
    required String url,
    required Map<String, String> headers,
    required _RangeSpec spec,
    required File file,
    required _OpenedRange opened,
    required int written,
    required int expectedBytes,
    required Future<void> Function(int, int, bool) onState,
    required Future<void> Function(int, int) onPaused,
    required Future<void> Function(DownloadRangeFailure failure)? onFailure,
  }) async {
    RandomAccessFile? output;
    var complete = false;
    var current = opened;
    var reconnects = 0;
    var lastReportedWritten = written;
    final progressClock = Stopwatch()..start();
    final checkpoints = _RangeCheckpointWriter(onState);
    final total = opened.total;
    try {
      output = await file.open(mode: FileMode.append);
      while (!operation.token.isCancelled && written < total) {
        Object? streamError;
        try {
          await for (final bytes in _cancelRangeStream(
            current.stream.timeout(kDownloadRangeStreamIdleTimeout),
            operation.token,
          )) {
            if (operation.token.isCancelled) break;
            if (written + bytes.length > total) {
              throw const FormatException('Range body is too long');
            }
            await output.writeFrom(bytes);
            written += bytes.length;
            if (shouldEmitDownloadRangeProgress(
              written: written,
              lastReportedWritten: lastReportedWritten,
              elapsed: progressClock.elapsed,
            )) {
              // Flush makes [written] durable before it is published, but do
              // not make network ingestion wait for Hive/plugin persistence.
              await output.flush();
              checkpoints.schedule(written, total, false);
              lastReportedWritten = written;
              progressClock.reset();
            }
          }
        } catch (error) {
          streamError = error;
          if (isNoSpaceDownloadError(error)) {
            operation.failure = DownloadRangeFailure(
              action: DownloadFailureAction.stopNoSpace,
              error: error,
            );
          }
        }

        if (written == total && !operation.token.isCancelled) break;
        if (operation.token.isCancelled ||
            operation.failure?.action == DownloadFailureAction.stopNoSpace ||
            streamError is FormatException ||
            reconnects >= kDownloadRangeReconnectAttempts) {
          throw streamError ??
              const FormatException('Range body is incomplete');
        }

        reconnects++;
        await output.flush();
        final reconnectDecision = planDownloadFailure(
          connectionFailure: true,
          retryIndex: reconnects - 1,
          jitterUnit: _random.nextDouble(),
        );
        await _retryDelay(operation, reconnectDecision.delay);
        final reopened = await _openWithRetries(
          operation: operation,
          url: url,
          headers: headers,
          spec: spec,
          written: written,
          expectedBytes: expectedBytes,
          attempts: kDownloadRangeRequestAttempts,
        );
        if (reopened == null || reopened.total != total) {
          throw const FormatException('Could not reconnect range body');
        }
        current = reopened;
      }

      await output.flush();
      await output.close();
      output = null;
      if (written != total || operation.token.isCancelled) {
        throw const FormatException('Range body is incomplete');
      }
      // Completion is a correctness boundary: all coalesced progress writes
      // must settle before the terminal checkpoint can be committed.
      await checkpoints.flush();
      await onState(written, total, true);
      complete = true;
    } catch (error) {
      operation.failure ??= DownloadRangeFailure(
        action: isNoSpaceDownloadError(error)
            ? DownloadFailureAction.stopNoSpace
            : DownloadFailureAction.park,
        error: error,
      );
      // Keep every durable byte. The next explicit resume starts exactly from
      // [written] if the bounded automatic reconnects were exhausted.
    } finally {
      try {
        if (output != null) {
          await output.flush();
          await output.close();
          output = null;
        }
      } catch (error) {
        operation.failure = DownloadRangeFailure(
          action: isNoSpaceDownloadError(error)
              ? DownloadFailureAction.stopNoSpace
              : DownloadFailureAction.park,
          error: error,
        );
      }
      operation.token.cancel();
      try {
        if (!complete) {
          // Pause/failure/cancel is also a correctness boundary. Join any
          // outstanding coalesced write before publishing the paused state.
          try {
            await checkpoints.flush();
          } catch (error) {
            operation.failure = DownloadRangeFailure(
              action: DownloadFailureAction.park,
              error: error,
            );
          }
          await onPaused(written, total);
          final failure = operation.failure;
          if (failure != null) {
            diagnosticLog?.record('range.failure', {
              'taskId': id,
              'reason': failure.action.name,
              'errorType': failure.error?.runtimeType.toString(),
            });
            _lastFailures[id] = failure;
            if (onFailure != null) await onFailure(failure);
          }
        } else {
          _lastFailures.remove(id);
        }
      } catch (error) {
        // Async checkpoint observers must not strand stop() or escape as an
        // unhandled error from the detached receive future. Bytes stay on disk.
        _lastFailures[id] = DownloadRangeFailure(
          action: DownloadFailureAction.park,
          error: error,
        );
      } finally {
        _operations.remove(id);
        if (!operation.done.isCompleted) operation.done.complete();
      }
    }
  }

  Future<List<int>> _readPrefix(File file, int length) async {
    final bytes = <int>[];
    await for (final chunk in file.openRead(0, length)) {
      bytes.addAll(chunk);
    }
    return bytes;
  }

  Future<List<int>?> _readExactStream(
    Stream<List<int>> stream,
    int length,
  ) async {
    final bytes = <int>[];
    try {
      await for (final chunk in stream.timeout(
        kDownloadRangeStreamIdleTimeout,
      )) {
        if (bytes.length + chunk.length > length) return null;
        bytes.addAll(chunk);
      }
    } catch (_) {
      return null;
    }
    return bytes.length == length ? bytes : null;
  }

  bool _bytesEqual(List<int> first, List<int> second) {
    if (first.length != second.length) return false;
    for (var index = 0; index < first.length; index++) {
      if (first[index] != second[index]) return false;
    }
    return true;
  }

  String? _headerValue(Map<String, String> headers, String name) {
    final lower = name.toLowerCase();
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == lower) return entry.value.trim();
    }
    return null;
  }

  String? _usableIfRange(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    if (trimmed.toLowerCase().startsWith('w/')) return null;
    return trimmed;
  }

  bool _responseMatchesIfRange(Headers headers, String validator) {
    if (validator.startsWith('"')) {
      final etag = headers.value('etag')?.trim();
      return etag == null || etag.isEmpty || etag == validator;
    }
    final lastModified = headers.value('last-modified')?.trim();
    return lastModified == null ||
        lastModified.isEmpty ||
        lastModified == validator;
  }

  int _unsatisfiedRangeSize(Headers headers) {
    final match = RegExp(r'^bytes \*/(\d+)$')
        .firstMatch(headers.value('content-range') ?? '');
    return match == null ? -1 : int.parse(match[1]!);
  }

  Future<void> _discard(Stream<List<int>>? stream) async {
    if (stream == null) return;
    try {
      final subscription = stream.listen(null, onError: (_) {});
      await subscription.cancel();
    } catch (_) {}
  }
}

bool isNoSpaceDownloadError(Object error) {
  if (error is! FileSystemException) return false;
  final code = error.osError?.errorCode;
  if (code == 28 || code == 112)
    return true; // POSIX ENOSPC / Windows disk full
  final message = '${error.message} ${error.osError?.message ?? ''}'
      .toLowerCase();
  return message.contains('no space left') ||
      message.contains('disk full') ||
      message.contains('not enough space');
}

class _RangeCheckpoint {
  const _RangeCheckpoint(this.written, this.total, this.complete);

  final int written;
  final int total;
  final bool complete;
}

/// Serializes persistence observers without serializing network ingestion.
/// While one callback is in flight, newer progress replaces older pending
/// progress. [flush] is used at lifecycle boundaries to recover the old
/// fail-closed ordering without paying storage latency on every network chunk.
class _RangeCheckpointWriter {
  _RangeCheckpointWriter(this._callback);

  final Future<void> Function(int written, int total, bool complete) _callback;
  _RangeCheckpoint? _pending;
  Future<void>? _drainFuture;
  Object? _failure;
  StackTrace? _failureStack;

  void schedule(int written, int total, bool complete) {
    _pending = _RangeCheckpoint(written, total, complete);
    _startDrain();
  }

  void _startDrain() {
    if (_drainFuture != null || _pending == null) return;
    _drainFuture = _drain();
  }

  Future<void> _drain() async {
    try {
      while (true) {
        final next = _pending;
        if (next == null) break;
        _pending = null;
        if (_failure != null) continue;
        try {
          await _callback(next.written, next.total, next.complete);
        } catch (error, stack) {
          _failure = error;
          _failureStack = stack;
        }
      }
    } finally {
      _drainFuture = null;
      if (_pending != null) _startDrain();
    }
  }

  Future<void> flush() async {
    while (_pending != null || _drainFuture != null) {
      _startDrain();
      final drain = _drainFuture;
      if (drain != null) await drain;
    }
    final failure = _failure;
    if (failure != null) {
      Error.throwWithStackTrace(failure, _failureStack ?? StackTrace.current);
    }
  }
}

class _RangeSpec {
  const _RangeSpec(this.origin, this.limit);

  final int origin;
  final int? limit;

  factory _RangeSpec.fromHeaders(Map<String, String> headers) {
    final value = headers.entries
        .where((entry) => entry.key.toLowerCase() == 'range')
        .map((entry) => entry.value)
        .firstOrNull;
    final bounded = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(value ?? '');
    if (bounded == null) return const _RangeSpec(0, null);
    return _RangeSpec(int.parse(bounded[1]!), int.parse(bounded[2]!));
  }
}

class _OpenedRange {
  const _OpenedRange({required this.stream, required this.total});

  final Stream<List<int>> stream;
  final int total;
}

class _ResumeProbe {
  const _ResumeProbe(this.validator);
  final String? validator;
}

class _RangeOperation {
  _RangeOperation({required this.id, required this.canRefreshUrl});
  final String id;

  final bool canRefreshUrl;
  final token = CancelToken();
  final done = Completer<void>();
  DownloadRangeFailure? failure;
}
