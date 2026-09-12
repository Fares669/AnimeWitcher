import 'dart:async';

enum DownloadServiceReadinessState { idle, initializing, ready }

enum DownloadServiceUnavailableReason { initializationFailed, disposed }

final class DownloadServiceUnavailableException implements Exception {
  final DownloadServiceUnavailableReason reason;
  final Object? cause;
  final bool retryable;

  const DownloadServiceUnavailableException._({
    required this.reason,
    required this.retryable,
    this.cause,
  });

  factory DownloadServiceUnavailableException.initializationFailed(
    Object cause,
  ) => DownloadServiceUnavailableException._(
    reason: DownloadServiceUnavailableReason.initializationFailed,
    retryable: true,
    cause: cause,
  );

  factory DownloadServiceUnavailableException.disposed() =>
      const DownloadServiceUnavailableException._(
        reason: DownloadServiceUnavailableReason.disposed,
        retryable: false,
      );

  @override
  String toString() =>
      'DownloadServiceUnavailableException(${reason.name}, retryable: $retryable, cause: $cause)';
}

/// Coalesces every caller onto one initialization/recovery attempt.
///
/// A failed attempt is deliberately forgotten so the next command can retry.
/// The Future returned to concurrent callers is the exact same object, making
/// recovery completion a single ordering boundary for all public controls.
final class DownloadServiceReadinessBarrier {
  Future<void>? _inFlight;
  bool _ready = false;

  DownloadServiceReadinessState get state {
    if (_ready) return DownloadServiceReadinessState.ready;
    if (_inFlight != null) return DownloadServiceReadinessState.initializing;
    return DownloadServiceReadinessState.idle;
  }

  bool get isReady => _ready;

  Future<void> ensureReady(Future<void> Function() initialize) {
    if (_ready) return Future<void>.value();
    final existing = _inFlight;
    if (existing != null) return existing;

    final completer = Completer<void>();
    final attempt = completer.future;
    _inFlight = attempt;

    Future<void>.sync(initialize).then(
      (_) {
        _ready = true;
        if (identical(_inFlight, attempt)) _inFlight = null;
        completer.complete();
      },
      onError: (Object error, StackTrace stack) {
        if (identical(_inFlight, attempt)) _inFlight = null;
        final unavailable = error is DownloadServiceUnavailableException
            ? error
            : DownloadServiceUnavailableException.initializationFailed(error);
        completer.completeError(unavailable, stack);
      },
    );

    return attempt;
  }
}
