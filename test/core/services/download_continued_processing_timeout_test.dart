import 'dart:async';

import 'package:animewitcher/core/services/download_continued_processing_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.animewitcher.app/download_continued_processing');
  late DownloadContinuedProcessingService service;
  void createService() {
    service = DownloadContinuedProcessingService(
      onSystemCancel: (_) async {},
      forceAvailableForTesting: true,
    );
  }
  tearDown(() async {
    await service.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets('missing start ACK resolves false without blocking controls', (tester) async {
    createService();
    final ack = Completer<Object?>();
    final methods = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      methods.add(call.method);
      return call.method == 'start' ? ack.future : null;
    });
    bool? accepted;
    unawaited(service.start(taskId: 'a', displayName: 'episode').then((value) => accepted = value));
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
    expect(accepted, isFalse);
    await service.stop(taskId: 'a', endSession: true);
    ack.complete(true);
    await tester.pump();
    expect(accepted, isFalse);
    expect(methods, contains('stop'));
  });

  testWidgets('late start ACK cannot revive a stopped session', (tester) async {
    createService();
    final ack = Completer<Object?>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => call.method == 'start' ? ack.future : null);
    bool? accepted;
    unawaited(service.start(taskId: 'a', displayName: 'episode').then((value) => accepted = value));
    await tester.pump();
    await service.stop(taskId: 'a', endSession: true);
    ack.complete(true);
    await tester.pump();
    expect(accepted, isFalse);
  });

  testWidgets('missing update ACK cannot hold successful finish forever', (tester) async {
    createService();
    final ack = Completer<Object?>();
    final methods = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      methods.add(call.method);
      return call.method == 'update' ? ack.future : null;
    });
    unawaited(service.update(taskId: 'a', progress: 1, totalBytes: 100));
    await tester.pump();
    await tester.pump();
    expect(methods, contains('update'));
    var finished = false;
    unawaited(service.finish(taskId: 'a', success: true, status: 'completed', endSession: true)
        .then((_) => finished = true));
    await tester.pump(const Duration(seconds: 6));
    await tester.pump();
    expect(finished, isTrue);
    expect(methods, contains('finish'));
    ack.complete(true);
    await tester.pump();
  });
  testWidgets('missing queue ACK retries once and releases observer queue', (tester) async {
    createService();
    final ack = Completer<Object?>();
    var writes = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'persistNativeQueue') { writes++; return ack.future; }
      return null;
    });
    var done = false;
    int? accepted;
    unawaited(service.persistNativeQueue(maxConcurrent: 1, waiters: const [],
      transferringTaskIds: const [], pausedTaskIds: const []).then((value) {
      accepted = value; done = true;
    }));
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
    await tester.pump(const Duration(seconds: 6));
    expect(done, isTrue);
    expect(accepted, isNull);
    expect(writes, 2);
    expect(service.nativePromotionAvailable, isFalse);
    ack.complete({'acceptedVersion': 1, 'nativePromotionAvailable': true});
    await tester.pump();
    expect(service.nativePromotionAvailable, isFalse);
  });

  testWidgets('coalesced V2 sample bypasses timer and replaces older pending sample', (tester) async {
    createService();
    final speeds = <double>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'update') {
        speeds.add((call.arguments as Map)['speedBytesPerSecond'] as double);
      }
      return true;
    });
    await service.start(taskId: 'a', displayName: 'episode');
    await service.update(taskId: 'a', progress: 0.1, totalBytes: 100,
      speedBytesPerSecond: 10);
    expect(speeds, isEmpty);
    unawaited(service.update(taskId: 'a', progress: 0.2, totalBytes: 100,
      speedBytesPerSecond: 20, immediate: true));
    await tester.pump();
    expect(speeds, [20]);
    await tester.pump(const Duration(seconds: 2));
    expect(speeds, [20]);
  });

}
