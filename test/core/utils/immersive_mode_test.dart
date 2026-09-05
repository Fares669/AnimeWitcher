import 'package:animewitcher/core/utils/immersive_mode.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('coming back out of full screen on Android', () {
    final plan = immersivePlan(false, ImmersivePlatform.android);

    test('ends on edge-to-edge', () {
      // This app targets API 36, where the system ignores every mode but
      // edge-to-edge — so whatever else is asked for, the last word has to be
      // the one a current phone will actually listen to.
      expect(plan.last, const ImmersiveStep(SystemUiMode.edgeToEdge));
    });

    test('still asks the old way first, for a phone that answers it', () {
      expect(
        plan.first,
        const ImmersiveStep(
          SystemUiMode.manual,
          overlays: SystemUiOverlay.values,
        ),
      );
    });

    test('never re-applies the overlays it is escaping', () {
      // restoreSystemUIOverlays re-asserts the state the embedder is holding,
      // which after a spell of full screen is the hidden one. It is not part
      // of the plan, and the plan is the whole of what gets sent.
      expect(plan.length, 2);
    });
  });

  test('going full screen on Android is the sticky mode', () {
    expect(immersivePlan(true, ImmersivePlatform.android), const [
      ImmersiveStep(SystemUiMode.immersiveSticky),
    ]);
  });

  group('iOS, which answers only one call', () {
    test('hides by naming no overlays', () {
      expect(immersivePlan(true, ImmersivePlatform.ios), const [
        ImmersiveStep(SystemUiMode.manual, overlays: <SystemUiOverlay>[]),
      ]);
    });

    test('shows by naming them all', () {
      // Never edge-to-edge or the sticky mode: those go over the channel
      // Android implements and iOS does nothing with them, which is how the
      // bar came to stay hidden after the switch was turned off.
      final plan = immersivePlan(false, ImmersivePlatform.ios);
      expect(plan, const [
        ImmersiveStep(SystemUiMode.manual, overlays: SystemUiOverlay.values),
      ]);
      expect(plan.every((step) => step.mode == SystemUiMode.manual), isTrue);
    });
  });
}
