from pathlib import Path
import sys

SOURCE = Path('lib/core/services/download_range_transfer.dart')
TEST = Path('test/core/services/download_range_checkpoint_backpressure_test.dart')

TEST_CONTENT = r'''import 'dart:async';
import 'dart:io';

import 'package:animewitcher/core/services/download_range_transfer.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

const _totalBytes = 2 * 1024 * 1024;
const _chunkBytes = 64 * 1024;

Future<void> _waitForFileLength(File file, int expected) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (DateTime.now().isBefore(deadline)) {
    if (await file.length() >= expected) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  expect(await file.length(), expected,
      reason: 'network ingestion was blocked by a slow persistence callback');
}

Future<HttpServer> _serveRange() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final match = RegExp(r'^bytes=(\d+)-$')
        .firstMatch(request.headers.value('range') ?? '');
    final start = int.tryParse(match?[1] ?? '') ?? 0;
    final response = request.response;
    response.statusCode = HttpStatus.partialContent;
    response.headers.set(
      HttpHeaders.contentRangeHeader,
      'bytes $start-${_totalBytes - 1}/$_totalBytes',
    );
    var offset = start;
    while (offset < _totalBytes) {
      final count = (_totalBytes - offset).clamp(0, _chunkBytes);
      response.add(List<int>.filled(count, offset ~/ _chunkBytes & 0xff));
      await response.flush();
      offset += count;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await response.close();
  });
  return server;
}

void main() {
  test('slow progress checkpoint does not backpressure Range ingestion', () async {
    final directory = await Directory.systemTemp.createTemp('range-dm25-');
    final file = File('${directory.path}/video.part');
    await file.writeAsBytes(const <int>[]);
    final server = await _serveRange();
    final dio = Dio();
    final runner = DownloadRangeTransfer(dio);
    final entered = Completer<void>();
    final release = Completer<void>();
    final finished = Completer<bool>();
    var nonTerminalCalls = 0;

    try {
      final started = await runner.start(
        id: 'episode',
        url: 'http://127.0.0.1:${server.port}/video',
        headers: const <String, String>{},
        file: file,
        existingBytes: 0,
        expectedBytes: _totalBytes,
        onState: (written, total, complete) async {
          if (complete) {
            if (!finished.isCompleted) finished.complete(true);
            return;
          }
          nonTerminalCalls++;
          if (!entered.isCompleted) {
            entered.complete();
            await release.future;
          }
        },
        onPaused: (_, _) async {
          if (!finished.isCompleted) finished.complete(false);
        },
      );
      expect(started, isTrue);
      await entered.future.timeout(const Duration(seconds: 5));

      // The first persistence callback is deliberately blocked. The network
      // receive loop must still drain into the already-flushed file.
      await _waitForFileLength(file, _totalBytes);
      expect(nonTerminalCalls, 1,
          reason: 'only one persistence write may be in flight');
    } finally {
      if (!release.isCompleted) release.complete();
    }

    expect(await finished.future.timeout(const Duration(seconds: 5)), isTrue);
    expect(nonTerminalCalls, lessThanOrEqualTo(2),
        reason: 'intermediate checkpoints must be coalesced to the newest one');

    await runner.stop('episode');
    runner.dispose();
    dio.close(force: true);
    await server.close(force: true);
    await directory.delete(recursive: true);
  });

  test('stop joins an in-flight progress checkpoint before paused boundary', () async {
    final directory = await Directory.systemTemp.createTemp('range-dm25-stop-');
    final file = File('${directory.path}/video.part');
    await file.writeAsBytes(const <int>[]);
    final server = await _serveRange();
    final dio = Dio();
    final runner = DownloadRangeTransfer(dio);
    final entered = Completer<void>();
    final release = Completer<void>();
    final paused = Completer<void>();

    try {
      expect(
        await runner.start(
          id: 'episode',
          url: 'http://127.0.0.1:${server.port}/video',
          headers: const <String, String>{},
          file: file,
          existingBytes: 0,
          expectedBytes: _totalBytes,
          onState: (_, _, complete) async {
            if (!complete && !entered.isCompleted) {
              entered.complete();
              await release.future;
            }
          },
          onPaused: (_, _) async {
            if (!paused.isCompleted) paused.complete();
          },
        ),
        isTrue,
      );
      await entered.future.timeout(const Duration(seconds: 5));
      final stopping = runner.stop('episode');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(paused.isCompleted, isFalse,
          reason: 'pause boundary must wait for prior durable checkpoint');
      expect(runner.isActive('episode'), isTrue);
      release.complete();
      await stopping.timeout(const Duration(seconds: 5));
      expect(paused.isCompleted, isTrue);
      expect(runner.isActive('episode'), isFalse);
    } finally {
      if (!release.isCompleted) release.complete();
      await runner.stop('episode');
      runner.dispose();
      dio.close(force: true);
      await server.close(force: true);
      await directory.delete(recursive: true);
    }
  });
}
'''


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{label}: expected exactly one match, got {count}')
    return text.replace(old, new, 1)

if len(sys.argv) != 2 or sys.argv[1] not in {'tests', 'apply'}:
    raise SystemExit('usage: tests|apply')

TEST.write_text(TEST_CONTENT)
if sys.argv[1] == 'tests':
    raise SystemExit(0)

source = SOURCE.read_text()

old_init = '''    var lastReportedWritten = written;\n    final progressClock = Stopwatch()..start();\n    final total = opened.total;\n'''
new_init = '''    var lastReportedWritten = written;\n    final progressClock = Stopwatch()..start();\n    final checkpoints = _RangeCheckpointWriter(onState);\n    final total = opened.total;\n'''
source = replace_once(source, old_init, new_init, 'checkpoint writer init')

old_progress = '''              await output.flush();\n              await onState(written, total, false);\n              lastReportedWritten = written;\n'''
new_progress = '''              // Flush makes [written] durable before it is published, but do\n              // not make network ingestion wait for Hive/plugin persistence.\n              await output.flush();\n              checkpoints.schedule(written, total, false);\n              lastReportedWritten = written;\n'''
source = replace_once(source, old_progress, new_progress, 'hot progress checkpoint')

old_complete = '''      await onState(written, total, true);\n      complete = true;\n'''
new_complete = '''      // Completion is a correctness boundary: all coalesced progress writes\n      // must settle before the terminal checkpoint can be committed.\n      await checkpoints.flush();\n      await onState(written, total, true);\n      complete = true;\n'''
source = replace_once(source, old_complete, new_complete, 'completion flush')

old_finally = '''      operation.token.cancel();\n      try {\n        if (!complete) {\n          await onPaused(written, total);\n'''
new_finally = '''      operation.token.cancel();\n      try {\n        if (!complete) {\n          // Pause/failure/cancel is also a correctness boundary. Join any\n          // outstanding coalesced write before publishing the paused state.\n          try {\n            await checkpoints.flush();\n          } catch (error) {\n            operation.failure = DownloadRangeFailure(\n              action: DownloadFailureAction.park,\n              error: error,\n            );\n          }\n          await onPaused(written, total);\n'''
source = replace_once(source, old_finally, new_finally, 'pause boundary flush')

anchor = '''class _RangeSpec {\n'''
helper = r'''class _RangeCheckpoint {
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

'''
if source.count(anchor) != 1:
    raise SystemExit(f'helper anchor: expected 1, got {source.count(anchor)}')
source = source.replace(anchor, helper + anchor, 1)
SOURCE.write_text(source)
