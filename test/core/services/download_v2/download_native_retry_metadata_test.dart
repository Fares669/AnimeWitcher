import 'dart:async';
import 'dart:convert';

import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(
    'com.animewitcher.app/download_continued_processing',
  );
  const parentId = 'aw_v2_retry_g1';
  final task = DownloadTask(
    taskId: '$parentId.part.0',
    url: 'https://example.test/video?secret=never-send',
    headers: {'Authorization': 'never-send'},
    group: 'animewitcher_parts',
    metaData: jsonEncode({'parentTaskId': parentId, 'attemptGeneration': 2}),
  );
  final failure = TaskStatusUpdate(
    task,
    TaskStatus.failed,
    TaskHttpException('busy', 429),
  );
  Future<TaskStatusUpdate> resolve(TaskStatusUpdate update) =>
      resolveNativeRangeFailureV2(update, forceAvailableForTesting: true);
  void handler(Future<Object?> Function(MethodCall)? callback) =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, callback);
  tearDown(() => handler(null));

  test(
    'failure waits for exact native identity and transfers only Retry-After',
    () async {
      final ack = Completer<Object?>();
      final calls = <MethodCall>[];
      handler((call) {
        calls.add(call);
        return ack.future;
      });
      var finished = false;
      final pending = resolve(failure).then((value) {
        finished = true;
        return value;
      });
      await Future<void>.delayed(Duration.zero);
      expect(finished, isFalse);
      expect(calls.single.method, 'retryMetadataForRange');
      expect(calls.single.arguments, {
        'taskId': task.taskId,
        'parentTaskId': parentId,
        'attemptGeneration': 2,
      });
      expect(jsonEncode(calls.single.arguments), isNot(contains('never-send')));
      ack.complete({
        'taskId': task.taskId,
        'parentTaskId': parentId,
        'attemptGeneration': 2,
        'httpStatus': 429,
        'retryAfter': '120',
        'Set-Cookie': 'never-copy',
      });
      final result = await pending;
      expect(result.responseHeaders, {'retry-after': '120'});
      expect(result.responseStatusCode, 429);
      expect(result.exception, same(failure.exception));
    },
  );

  test(
    'mismatched generation fails closed rather than granting an early retry',
    () async {
      handler(
        (_) async => {
          'taskId': task.taskId,
          'parentTaskId': parentId,
          'attemptGeneration': 1,
          'httpStatus': 429,
          'retryAfter': '1',
        },
      );
      await expectLater(resolve(failure), throwsStateError);
    },
  );

  test(
    'known empty cache keeps the original status and replayed headers',
    () async {
      handler((_) async => null);
      expect(await resolve(failure), same(failure));
      final replay = failure.copyWith(responseHeaders: {'Retry-After': '180'});
      expect(await resolve(replay), same(replay));
    },
  );

  test('HTTP dates survive and unrelated updates avoid the bridge', () async {
    var calls = 0;
    const date = 'Fri, 16 Oct 2026 08:05:00 GMT';
    handler((_) async {
      calls++;
      return {
        'taskId': task.taskId,
        'parentTaskId': parentId,
        'attemptGeneration': 2,
        'httpStatus': 503,
        'retryAfter': date,
        'responseDate': 'Fri, 16 Oct 2026 08:03:00 GMT',
      };
    });
    expect((await resolve(failure)).responseHeaders, {
      'retry-after': date,
      'date': 'Fri, 16 Oct 2026 08:03:00 GMT',
    });
    final running = TaskStatusUpdate(task, TaskStatus.running);
    expect(await resolve(running), same(running));
    expect(calls, 1);
  });

  test(
    'bridge errors are surfaced to the coordinator for a safe park',
    () async {
      handler((_) async => throw PlatformException(code: 'UNAVAILABLE'));
      await expectLater(resolve(failure), throwsA(isA<PlatformException>()));
      handler((_) async => throw MissingPluginException());
      await expectLater(
        resolve(failure),
        throwsA(isA<MissingPluginException>()),
      );
    },
  );

  testWidgets(
    'lost bridge ACK is bounded and never becomes a bare failed update',
    (tester) async {
      final ack = Completer<Object?>();
      handler((_) => ack.future);
      Object? error;
      final result = resolve(failure).then<void>(
        (_) {},
        onError: (Object value) {
          error = value;
        },
      );
      await tester.pump(const Duration(seconds: 6));
      expect(error, isA<TimeoutException>());
      ack.complete(null);
      await result;
    },
  );
}
