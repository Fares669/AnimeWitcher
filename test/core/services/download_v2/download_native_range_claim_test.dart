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
  const parentId = 'aw_v2_claim_g1';
  DownloadTask task({int generation = 2, String parent = parentId}) =>
      DownloadTask(
        taskId: '$parentId.part.7',
        url: 'https://example.invalid/video?secret=never-send',
        headers: {'Authorization': 'never-send', 'Range': 'bytes=70-79'},
        filename: '7.part',
        group: 'animewitcher_parts',
        metaData: jsonEncode({
          'parentTaskId': parent,
          'attemptGeneration': generation,
        }),
      );

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets('missing disk-space ACK stays unknown and cannot lock the assembler', (tester) async {
    final ack = Completer<int>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) => ack.future);
    var finished = false;
    int? available;
    final probe = availableDownloadStorageBytesV2('/downloads').then((value) {
      finished = true;
      available = value;
    });
    await tester.pump(const Duration(seconds: 6));
    final bounded = finished;
    ack.complete(123);
    await probe;
    expect(bounded, isTrue);
    expect(available, isNull, reason: 'a lost native ACK cannot claim known headroom');
  });

  test(
    'claim sends identity only and preserves native ownership rejection',
    () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return false;
          });
      expect(
        await claimNativeRangeForDartV2(
          task(),
          observedAtMillis: 100,
          forceAvailableForTesting: true,
        ),
        isFalse,
      );
      expect(calls.single.method, 'claimRangeForDart');
      expect(calls.single.arguments, {
        'taskId': '$parentId.part.7',
        'parentTaskId': parentId,
        'attemptGeneration': 2,
        'nativeOwnerAbsent': true,
        'observedAtMillis': 100,
      });
      expect(jsonEncode(calls.single.arguments), isNot(contains('never-send')));
    },
  );

  test('only an acknowledged claim permits Dart to enqueue', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => true);
    expect(
      await claimNativeRangeForDartV2(
        task(),
        observedAtMillis: 100,
        forceAvailableForTesting: true,
      ),
      isTrue,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => null);
    await expectLater(
      claimNativeRangeForDartV2(
        task(),
        observedAtMillis: 100,
        forceAvailableForTesting: true,
      ),
      throwsStateError,
    );
  });

  test('ambiguous native errors never permit a duplicate writer', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
          throw PlatformException(code: 'QUEUE_WRITE_FAILED');
        });
    await expectLater(
      claimNativeRangeForDartV2(
        task(),
        observedAtMillis: 100,
        forceAvailableForTesting: true,
      ),
      throwsA(isA<PlatformException>()),
    );
  });

  test(
    'invalid generation and parent identity fail before platform work',
    () async {
      var calls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async {
            calls++;
            return true;
          });
      for (final invalid in [
        task(generation: 0),
        task(parent: 'aw_v2_other_g1'),
      ]) {
        await expectLater(
          claimNativeRangeForDartV2(
            invalid,
            observedAtMillis: 100,
            forceAvailableForTesting: true,
          ),
          throwsStateError,
        );
      }
      expect(calls, 0);
    },
  );

  test(
    'pre-refill native builds keep their existing package-only transport',
    () async {
      // MissingPluginException means this binary has no native range claimant.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async {
            throw MissingPluginException();
          });
      expect(
        await claimNativeRangeForDartV2(
          task(),
          observedAtMillis: 100,
          forceAvailableForTesting: true,
        ),
        isTrue,
      );
    },
  );
}
