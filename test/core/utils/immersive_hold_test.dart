import 'package:animewitcher/core/utils/immersive_mode.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late List<MethodCall> calls;

  setUp(() {
    calls = <MethodCall>[];
    debugImmersivePlatformOverride = ImmersivePlatform.android;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method.startsWith('SystemChrome.')) calls.add(call);
          return null;
        });
  });

  tearDown(() {
    cancelImmersiveHold();
    debugImmersivePlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  List<MethodCall> modeCalls() => calls
      .where((call) => call.method == 'SystemChrome.setEnabledSystemUIMode')
      .toList();

  /// Tells the app what the system just did with its bars, the way the
  /// embedder does.
  Future<void> reportOverlaysVisible() async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          SystemChannels.platform.name,
          SystemChannels.platform.codec.encodeMethodCall(
            const MethodCall('SystemChrome.systemUIChange', <bool>[true]),
          ),
          (_) {},
        );
  }

  testWidgets('the choice is asked for again after the floor, not inside it', (
    tester,
  ) async {
    holdImmersiveFullScreen(true);
    await tester.pump();
    expect(modeCalls().length, 1);

    // Something puts the bars back straight away — the relayout behind the
    // player closing. Asking again now would land inside Android's one
    // second floor and be dropped, so nothing should go out yet.
    await reportOverlaysVisible();
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      modeCalls().length,
      1,
      reason: 'a request inside the floor is thrown away by the system',
    );

    // Once the floor has passed, the choice is put again.
    await tester.pump(immersiveChangeFloor);
    expect(modeCalls().length, greaterThan(1));
    expect(modeCalls().last.arguments, contains('immersiveSticky'));

    cancelImmersiveHold();
  });

  testWidgets('a window that changes shape is answered too', (tester) async {
    holdImmersiveFullScreen(true);
    await tester.pump();
    final before = modeCalls().length;

    tester.view.physicalSize = const Size(1080, 2400);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pump();
    await tester.pump(immersiveChangeFloor);

    expect(modeCalls().length, greaterThan(before));
    cancelImmersiveHold();
  });

  testWidgets('the hold lets go, and stops answering afterwards', (
    tester,
  ) async {
    holdImmersiveFullScreen(true);
    await tester.pump(immersiveHoldWindow + const Duration(seconds: 1));
    final after = modeCalls().length;

    await reportOverlaysVisible();
    tester.view.physicalSize = const Size(1080, 2400);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pump();
    await tester.pump(immersiveChangeFloor * 2);

    expect(
      modeCalls().length,
      after,
      reason:
          'what the bars do long after leaving is not the player\'s business',
    );
  });

  testWidgets('showing the bars is not defended, only hiding them', (
    tester,
  ) async {
    // The visible state is where everything else in the system is trying to
    // get back to, so there is nothing to hold it against.
    holdImmersiveFullScreen(false);
    await tester.pump();
    final after = modeCalls().length;

    await reportOverlaysVisible();
    await tester.pump(immersiveChangeFloor * 2);

    expect(modeCalls().length, after);
  });

  testWidgets('nothing is held off a phone', (tester) async {
    debugImmersivePlatformOverride = null;
    holdImmersiveFullScreen(true);
    await tester.pump(immersiveChangeFloor * 2);
    expect(calls, isEmpty);
  });
}
