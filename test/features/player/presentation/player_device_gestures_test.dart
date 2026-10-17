import 'dart:async';

import 'package:animewitcher/features/player/presentation/player_gesture_handler.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('github.com/aaassseee/screen_brightness');
  late ProviderContainer container;
  late PlayerGestureHandler handler;
  final calls = <MethodCall>[];
  var permission = true;
  Completer<void>? writeGate;
  Completer<double>? readGate;

  setUp(() {
    calls.clear();
    permission = true;
    writeGate = null;
    readGate = null;
    container = ProviderContainer();
    handler = container.read(playerGestureHandlerProvider.notifier);
    handler.getMaxVolumeLevel = () => 1;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          switch (call.method) {
            case 'getSystemScreenBrightness':
              return readGate == null ? 0.25 : await readGate!.future;
            case 'canChangeSystemBrightness':
              return permission;
            case 'setSystemScreenBrightness':
              if (!permission) throw PlatformException(code: '-1');
              await writeGate?.future;
          }
          return null;
        });
  });

  tearDown(() {
    container.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<void> startBrightness() => handler.handleDragStart(
    DragStartDetails(globalPosition: const Offset(150, 100)),
    600,
    400,
  );
  void drag(double delta) => handler.handleDragUpdate(
    DragUpdateDetails(
      globalPosition: const Offset(150, 100),
      delta: Offset(0, delta),
      primaryDelta: delta,
    ),
  );
  Future<void> flush() => Future<void>.delayed(Duration.zero);

  test('brightness starts at device level and writes system setting', () async {
    await startBrightness();
    expect(container.read(playerGestureHandlerProvider).osdValue, 0.25);
    expect(calls.map((call) => call.method), [
      'resetApplicationScreenBrightness',
      'getSystemScreenBrightness',
    ]);
    drag(-30);
    await flush();
    final write = calls.last;
    expect(write.method, 'setSystemScreenBrightness');
    expect(write.arguments['brightness'], closeTo(0.35, 0.0001));
  });

  test('zero brightness is minimum, not an app-only auto override', () async {
    await startBrightness();
    drag(300);
    await flush();
    expect(calls.last.method, 'setSystemScreenBrightness');
    expect(calls.last.arguments['brightness'], 0.0);
    expect(container.read(playerGestureHandlerProvider).osdLabel, 'Brightness');
  });

  test('rapid changes keep only newest pending device write', () async {
    await startBrightness();
    writeGate = Completer<void>();
    drag(-30);
    await flush();
    drag(-30);
    drag(-30);
    expect(
      calls.where((c) => c.method == 'setSystemScreenBrightness').length,
      1,
    );
    writeGate!.complete();
    await flush();
    await flush();
    final values = calls
        .where((c) => c.method == 'setSystemScreenBrightness')
        .map((c) => c.arguments['brightness'])
        .toList();
    expect(values.length, 2);
    expect(values.last, closeTo(0.55, 0.0001));
  });

  test('permission denial stops drag and explains required grant', () async {
    permission = false;
    await startBrightness();
    drag(-30);
    await flush();
    await flush();
    final state = container.read(playerGestureHandlerProvider);
    expect(state.activeDragMode, PlayerDragMode.none);
    expect(state.osdValue, isNull);
    expect(state.osdLabel, contains('إعدادات النظام'));
    drag(-30);
    expect(
      calls.where((c) => c.method == 'setSystemScreenBrightness').length,
      1,
    );
  });

  test('release during device read cannot resurrect a drag', () async {
    readGate = Completer<double>();
    final start = startBrightness();
    await flush();
    handler.handleDragEnd(DragEndDetails());
    readGate!.complete(0.25);
    await start;
    expect(
      container.read(playerGestureHandlerProvider).activeDragMode,
      PlayerDragMode.none,
    );
  });

  test('hardware volume updates UI without writing device settings', () {
    handler.syncDeviceVolume(0.4);
    expect(container.read(playerGestureHandlerProvider).osdValue, 0.4);
    expect(calls, isEmpty);
  });

  test(
    'release displays actual hardware step observed during volume drag',
    () async {
      handler.getVolumeLevel = () async => 0.2;
      handler.setVolumeLevel = (value) async => value;
      await handler.handleDragStart(
        DragStartDetails(globalPosition: const Offset(450, 100)),
        600,
        400,
      );
      drag(-45);
      await flush();
      handler.syncDeviceVolume(1 / 3);
      expect(
        container.read(playerGestureHandlerProvider).osdValue,
        closeTo(0.35, 0.001),
      );
      handler.handleDragEnd(DragEndDetails());
      expect(container.read(playerGestureHandlerProvider).osdValue, 1 / 3);
    },
  );

  test(
    'actual level is published when the final write settles after release',
    () async {
      final gate = Completer<double>();
      handler.getVolumeLevel = () async => 0.2;
      handler.setVolumeLevel = (_) => gate.future;
      await handler.handleDragStart(
        DragStartDetails(globalPosition: const Offset(450, 100)),
        600,
        400,
      );
      drag(-45);
      handler.syncDeviceVolume(1 / 3);
      handler.handleDragEnd(DragEndDetails());
      gate.complete(0.35);
      await flush();
      expect(container.read(playerGestureHandlerProvider).osdValue, 1 / 3);
    },
  );

  test('closing controls drops pending writes', () async {
    await startBrightness();
    writeGate = Completer<void>();
    drag(-30);
    await flush();
    drag(-30);
    handler.detachDeviceControls();
    writeGate!.complete();
    await flush();
    expect(
      calls.where((c) => c.method == 'setSystemScreenBrightness').length,
      1,
    );
    expect(container.read(playerGestureHandlerProvider).showOSD, isFalse);
  });
}
