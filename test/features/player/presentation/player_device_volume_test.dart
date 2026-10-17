import 'package:animewitcher/features/player/presentation/player_platform_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_volume_controller/flutter_volume_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final service = PlayerPlatformService();
  final calls = <MethodCall>[];
  var volume = '0.2';
  var failWrite = false;

  setUp(() {
    calls.clear();
    volume = '0.2';
    failWrite = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(FlutterVolumeController.methodChannel, (
          call,
        ) async {
          calls.add(call);
          if (call.method == 'getVolume') return volume;
          if (call.method == 'setVolume' && failWrite) {
            throw PlatformException(code: 'unavailable');
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(FlutterVolumeController.methodChannel, null);
  });

  test('reads existing device level without changing it', () async {
    expect(await service.getVolumeLevel(), 0.2);
    expect(calls.map((call) => call.method), ['getVolume']);
  });

  test('changes device volume with unity engine gain', () async {
    final gains = <double>[];
    expect(
      await service.setVolumeLevel(
        0.8,
        setEngineVolume: (gain) async {
          gains.add(gain);
        },
      ),
      0.8,
    );
    expect(gains, [1.0]);
    expect(calls.single.method, 'setVolume');
    expect(calls.single.arguments['volume'], 0.8);
  });

  test('device range clamps both ends including mute', () async {
    await service.setVolumeLevel(2, setEngineVolume: (_) async {});
    await service.setVolumeLevel(-1, setEngineVolume: (_) async {});
    expect(calls.map((call) => call.arguments['volume']), [1.0, 0.0]);
  });

  test('write failure is not reported as a successful level', () async {
    failWrite = true;
    await expectLater(
      service.setVolumeLevel(0.8, setEngineVolume: (_) async {}),
      throwsA(isA<PlatformException>()),
    );
  });

  test(
    'Android volume keys use a native step on coarse output devices',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final gains = <double>[];
      await service.changeVolume(
        0.05,
        setEngineVolume: (value) async {
          gains.add(value);
        },
      );
      expect(gains, [1.0]);
      expect(calls.first.method, 'raiseVolume');
      expect(calls.first.arguments.containsKey('step'), isFalse);
      expect(calls.last.method, 'getVolume');
    },
  );

  test('invalid level never reaches device or engine', () async {
    final gains = <double>[];
    await expectLater(
      service.setVolumeLevel(
        double.nan,
        setEngineVolume: (v) async {
          gains.add(v);
        },
      ),
      throwsArgumentError,
    );
    expect(calls, isEmpty);
    expect(gains, isEmpty);
  });
}
