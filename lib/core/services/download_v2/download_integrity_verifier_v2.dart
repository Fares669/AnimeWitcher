import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import '../../utils/local_video_payload_probe.dart';

/// Result of validating the final artifact produced by the transport package.
final class DownloadIntegrityResult {
  const DownloadIntegrityResult.valid(
    int bytes, {
    this.completedPages,
    this.totalPages,
  }) : assert(bytes > 0),
       isValid = true,
       bytes = bytes,
       reason = null;

  const DownloadIntegrityResult.invalid(
    String reason, {
    this.completedPages,
    this.totalPages,
  }) : assert(reason != ''),
       isValid = false,
       bytes = null,
       reason = reason;

  final bool isValid;
  final int? bytes;
  final String? reason;
  final int? completedPages;
  final int? totalPages;
}

/// Verifies only stable final-file properties owned by AnimeWitcher.
///
/// Transport completion is not logical completion until this verifier accepts
/// the final artifact. Resume/chunk state remains owned by background_downloader.
final class DownloadIntegrityVerifierV2 {
  const DownloadIntegrityVerifierV2();

  DownloadStartupIntegritySessionV2 startupSession() =>
      DownloadStartupIntegritySessionV2._(this);

  Future<DownloadIntegrityResult> verify(
    File file, {
    int? expectedBytes,
    // Opt in only for newly completed transfers. Existing completed records
    // retain their original integrity semantics and must not be deleted by a
    // startup migration; playback separately checks recognizable text payloads.
    bool rejectNonVideoPayload = false,
  }) {
    final path = file.path;
    // Async file calls share Dart's I/O queue with stalled DNS lookups.
    return Isolate.run(
      () => _verifyPath(path, expectedBytes, rejectNonVideoPayload),
    );
  }

  static DownloadIntegrityResult _verifyPath(
    String path,
    int? expectedBytes,
    bool rejectNonVideoPayload,
  ) {
    final file = File(path);
    if (!file.existsSync()) {
      return const DownloadIntegrityResult.invalid('missing');
    }

    final bytes = file.lengthSync();
    if (bytes <= 0) {
      return const DownloadIntegrityResult.invalid('empty');
    }

    if (expectedBytes != null && expectedBytes > 0 && bytes != expectedBytes) {
      return const DownloadIntegrityResult.invalid('size-mismatch');
    }

    if (rejectNonVideoPayload) {
      final problem = probeLocalVideoPayloadSync(file);
      if (problem != null) {
        return DownloadIntegrityResult.invalid(problem.reason);
      }
    }

    return DownloadIntegrityResult.valid(bytes);
  }
}

// These records contain only the inputs for a single filesystem read, not
// startup destination ownership or the recovered transport.
typedef _StartupIntegrityRequest = ({String path, int? expectedBytes});
typedef _StartupIntegrityFailure = ({Object error, StackTrace stack});

/// A serial, short-lived worker for already completed video files on startup.
///
/// Each request reads the live path when the manager reaches that record. A
/// successful read is not cached or used to authorize later playback/deletion.
final class DownloadStartupIntegritySessionV2 {
  DownloadStartupIntegritySessionV2._(this._verifier);

  final DownloadIntegrityVerifierV2 _verifier;
  Isolate? _isolate;
  ReceivePort? _responses;
  StreamIterator<Object?>? _messages;
  SendPort? _requests;
  bool _busy = false;
  bool _closed = false;
  bool _workerUnavailable = false;

  Future<DownloadIntegrityResult> verify(
    File file, {
    int? expectedBytes,
  }) async {
    if (_closed || _busy) {
      throw StateError('Startup verification is closed or already running');
    }
    _busy = true;
    try {
      if (!_workerUnavailable) {
        Object? response;
        try {
          final requests = _requests ??= await _start();
          requests.send((path: file.path, expectedBytes: expectedBytes));
          response = await _nextMessage();
          if (response is! DownloadIntegrityResult &&
              response is! _StartupIntegrityFailure) {
            throw StateError('Startup verification worker stopped');
          }
        } catch (_) {
          // A failed spawn/worker is a transport failure, not evidence that a
          // file is invalid. Retry this read via the usual one-off verifier.
          _workerUnavailable = true;
          _releaseWorker();
        }
        if (response is DownloadIntegrityResult) return response;
        if (response case _StartupIntegrityFailure(
          :final error,
          :final stack,
        )) {
          Error.throwWithStackTrace(error, stack);
        }
      }
      if (_closed) throw StateError('Startup verification is closed');
      return await _verifier.verify(file, expectedBytes: expectedBytes);
    } finally {
      _busy = false;
    }
  }

  Future<SendPort> _start() async {
    final responses = ReceivePort();
    _responses = responses;
    _messages = StreamIterator<Object?>(responses);
    final isolate = await Isolate.spawn(
      _runStartupIntegrityWorker,
      responses.sendPort,
      onError: responses.sendPort,
      onExit: responses.sendPort,
    );
    if (_closed) {
      isolate.kill(priority: Isolate.immediate);
      throw StateError('Startup verification is closed');
    }
    _isolate = isolate;
    final requests = await _nextMessage();
    if (requests is! SendPort) {
      throw StateError('Startup verification worker failed to start');
    }
    return requests;
  }

  Future<Object?> _nextMessage() async {
    final messages = _messages;
    if (messages == null || !await messages.moveNext()) return null;
    return messages.current;
  }

  void _releaseWorker() {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    unawaited(_messages?.cancel());
    _messages = null;
    _responses?.close();
    _responses = null;
    _requests = null;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _releaseWorker();
  }
}

void _runStartupIntegrityWorker(SendPort responses) {
  final requests = ReceivePort();
  requests.listen((Object? message) {
    final request = message as _StartupIntegrityRequest;
    try {
      responses.send(
        DownloadIntegrityVerifierV2._verifyPath(
          request.path,
          request.expectedBytes,
          false,
        ),
      );
    } catch (error, stack) {
      responses.send((error: error, stack: stack));
    }
  });
  responses.send(requests.sendPort);
}
