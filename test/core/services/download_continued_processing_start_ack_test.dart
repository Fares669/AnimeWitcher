import 'dart:async';

import 'package:animewitcher/core/services/download_continued_processing_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(
    'com.animewitcher.app/download_continued_processing',
  );

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('start reports native rejection so caller can retry later', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'start') return false;
          return true;
        });
    final service = DownloadContinuedProcessingService(
      onSystemCancel: (_) async {},
      forceAvailableForTesting: true,
    );

    try {
      expect(
        await service.start(taskId: 'episode', displayName: 'Episode 1'),
        isFalse,
      );
    } finally {
      await service.dispose();
    }
  });

  test('start reports native acceptance for an installed iOS task', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'start') {
            return 'com.animewitcher.app.download.session';
          }
          return true;
        });
    final service = DownloadContinuedProcessingService(
      onSystemCancel: (_) async {},
      forceAvailableForTesting: true,
    );

    try {
      expect(
        await service.start(taskId: 'episode', displayName: 'Episode 1'),
        isTrue,
      );
    } finally {
      await service.dispose();
    }
  });

  test('native update rejection invalidates the cached iOS session', () async {
    var lost = 0;
    final lostSignal = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'start') {
            return 'com.animewitcher.app.download.session';
          }
          if (call.method == 'update') return false;
          return true;
        });
    final service = DownloadContinuedProcessingService(
      onSystemCancel: (_) async {},
      onSessionLost: () {
        lost++;
        if (!lostSignal.isCompleted) lostSignal.complete();
      },
      forceAvailableForTesting: true,
    );

    try {
      expect(
        await service.start(taskId: 'episode', displayName: 'Episode 1'),
        isTrue,
      );
      await service.update(
        taskId: 'episode',
        progress: .25,
        totalBytes: 100,
        transferredBytes: 25,
      );
      await lostSignal.future.timeout(const Duration(seconds: 2));
      expect(lost, 1);
    } finally {
      await service.dispose();
    }
  });

  test('structured native rejection invalidates the cached iOS session', () async {
    final lostSignal = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'start') {
            return 'com.animewitcher.app.download.session.1';
          }
          if (call.method == 'update') {
            return <String, Object>{'accepted': false, 'owner': 'none'};
          }
          return true;
        });
    final service = DownloadContinuedProcessingService(
      onSystemCancel: (_) async {},
      onSessionLost: () {
        if (!lostSignal.isCompleted) lostSignal.complete();
      },
      forceAvailableForTesting: true,
    );

    try {
      expect(
        await service.start(taskId: 'episode', displayName: 'Episode 1'),
        isTrue,
      );
      await service.update(
        taskId: 'episode',
        progress: .25,
        totalBytes: 100,
        transferredBytes: 25,
        foregroundHandoff: true,
      );
      await lostSignal.future.timeout(const Duration(seconds: 2));
    } finally {
      await service.dispose();
    }
  });

  test('foreground handoff bypasses update sampling and reaches native immediately', () async {
    final updateSignal = Completer<Map<Object?, Object?>>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'start') {
            return 'com.animewitcher.app.download.session.1';
          }
          if (call.method == 'update') {
            final args = Map<Object?, Object?>.from(call.arguments as Map);
            if (!updateSignal.isCompleted) updateSignal.complete(args);
            return <String, Object>{'accepted': true, 'owner': 'dart'};
          }
          return true;
        });
    final service = DownloadContinuedProcessingService(
      onSystemCancel: (_) async {},
      forceAvailableForTesting: true,
    );

    try {
      expect(
        await service.start(taskId: 'episode', displayName: 'Episode 1'),
        isTrue,
      );
      await service.update(
        taskId: 'episode',
        progress: .30,
        totalBytes: 100,
        transferredBytes: 30,
        foregroundHandoff: true,
      );
      final args = await updateSignal.future.timeout(
        const Duration(milliseconds: 250),
      );
      expect(args['foregroundHandoff'], isTrue);
      expect(args['progress'], .30);
    } finally {
      await service.dispose();
    }
  });
}
