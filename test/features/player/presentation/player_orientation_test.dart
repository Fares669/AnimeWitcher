import 'dart:async';

import 'package:animewitcher/features/player/presentation/player_platform_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final requests = <List<dynamic>>[];
  final applied = <List<dynamic>>[];
  Completer<void>? pendingLandscape;
  var failLandscape = false;
  var failPortrait = false;

  setUp(() {
    requests.clear();
    applied.clear();
    pendingLandscape = null;
    failLandscape = false;
    failPortrait = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method != 'SystemChrome.setPreferredOrientations') {
            return null;
          }
          final orientations = List<dynamic>.from(call.arguments as List);
          requests.add(orientations);
          if (failPortrait &&
              orientations.contains('DeviceOrientation.portraitUp')) {
            throw PlatformException(code: 'restoration_failed');
          }
          if (orientations.contains('DeviceOrientation.landscapeLeft')) {
            await pendingLandscape?.future;
            if (failLandscape) throw PlatformException(code: 'rotation_failed');
          }
          applied.add(orientations);
          return null;
        });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets('$platform restores portrait after pending landscape request', (
      tester,
    ) async {
      final service = PlayerPlatformService();
      pendingLandscape = Completer<void>();
      service.updateOrientation(1920, 1080);
      await tester.pump();
      expect(requests.single, [
        'DeviceOrientation.landscapeLeft',
        'DeviceOrientation.landscapeRight',
      ]);
      var restored = false;
      final restoration = service
          .restoreOrientation(isTablet: false, isTv: false)
          .then((_) => restored = true);
      service.updateOrientation(1920, 1080);
      await tester.pump();
      try {
        expect(restored, isFalse);
        expect(requests, hasLength(1));
      } finally {
        pendingLandscape!.complete();
      }
      await tester.pump();
      await restoration;
      expect(requests.last, ['DeviceOrientation.portraitUp']);
      expect(applied.last, ['DeviceOrientation.portraitUp']);
      expect(requests, hasLength(2));
      await service.restoreOrientation(isTablet: false, isTv: false);
      service.updateOrientation(1920, 1080);
      await tester.pump();
      expect(requests, hasLength(2));
    }, variant: TargetPlatformVariant.only(platform));
  }

  testWidgets('queued metadata cannot relock orientation after exit starts', (
    tester,
  ) async {
    final service = PlayerPlatformService();
    service.updateOrientation(1920, 1080);
    service.updateOrientation(1920, 1080);
    await service.restoreOrientation(isTablet: false, isTv: false);
    expect(requests, [
      ['DeviceOrientation.portraitUp'],
    ]);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('manual rotation is ignored once exit starts', (tester) async {
    final service = PlayerPlatformService();
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (value) {
            context = value;
            return const SizedBox();
          },
        ),
      ),
    );
    await service.restoreOrientation(isTablet: false, isTv: false);
    service.toggleOrientation(context);
    await tester.pump();
    expect(requests, [
      ['DeviceOrientation.portraitUp'],
    ]);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  test('tablet returns to system rotation', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await PlayerPlatformService().restoreOrientation(
      isTablet: true,
      isTv: false,
    );
    expect(requests, [<dynamic>[]]);
  });

  test('TV and desktop exit do not force portrait', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await PlayerPlatformService().restoreOrientation(
      isTablet: false,
      isTv: true,
    );
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    await PlayerPlatformService().restoreOrientation(
      isTablet: false,
      isTv: false,
    );
    expect(requests, isEmpty);
  });

  testWidgets('failed playback rotation does not prevent exit restoration', (
    tester,
  ) async {
    final service = PlayerPlatformService();
    failLandscape = true;
    service.updateOrientation(1920, 1080);
    await tester.pump();
    await service.restoreOrientation(isTablet: false, isTv: false);
    expect(requests.last, ['DeviceOrientation.portraitUp']);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets(
    'a failed restore does not strand navigation or reopen rotation',
    (tester) async {
      final service = PlayerPlatformService();
      failPortrait = true;
      await service.restoreOrientation(isTablet: false, isTv: false);
      service.updateOrientation(1920, 1080);
      await tester.pump();
      expect(requests, [
        ['DeviceOrientation.portraitUp'],
      ]);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets('a new player can rotate after the previous route restored', (
    tester,
  ) async {
    await PlayerPlatformService().restoreOrientation(
      isTablet: false,
      isTv: false,
    );
    final nextPlayer = PlayerPlatformService();
    nextPlayer.updateOrientation(1920, 1080);
    await tester.pump();
    expect(requests.last, [
      'DeviceOrientation.landscapeLeft',
      'DeviceOrientation.landscapeRight',
    ]);
    nextPlayer.updateOrientation(1080, 1920);
    await tester.pump();
    expect(requests.last, [
      'DeviceOrientation.portraitUp',
      'DeviceOrientation.portraitDown',
    ]);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
}
