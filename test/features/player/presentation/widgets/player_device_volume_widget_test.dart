import 'dart:async';

import 'package:animewitcher/features/player/presentation/player_controller.dart';
import 'package:animewitcher/features/player/presentation/widgets/player_stream_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _DeviceVolume extends PlayerController {
  double device = 0.2;
  bool fail = false;
  Completer<double>? readGate;
  final writes = <double>[];

  @override
  PlayerState build() => const PlayerState();

  void publishSpeed(double speed) {
    state = state.copyWith(playbackSpeed: speed);
  }

  @override
  Future<double> getVolumeLevel() async =>
      readGate == null ? device : await readGate!.future;

  @override
  Future<double> setVolumeLevel(double value) async {
    writes.add(value);
    if (fail) throw StateError('Device rejected volume');
    device = value;
    return value;
  }
}

void main() {
  Future<void> mount(WidgetTester tester, _DeviceVolume controller) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [playerControllerProvider.overrideWith(() => controller)],
        child: const MaterialApp(
          home: Scaffold(body: Center(child: PlayerVolumeControl())),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> tapLevel(WidgetTester tester, double level) async {
    final track = find.byWidgetPredicate(
      (widget) =>
          widget is GestureDetector && widget.onHorizontalDragUpdate != null,
    );
    final rect = tester.getRect(track);
    await tester.tapAt(Offset(rect.left + rect.width * level, rect.center.dy));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('playback state does not redraw the unchanged device volume', (
    tester,
  ) async {
    final controller = _DeviceVolume();
    await mount(tester, controller);
    final slider = find.byTooltip('20%');
    final mute = find.byTooltip('كتم الصوت');
    expect(slider, findsOneWidget);
    expect(mute, findsOneWidget);
    final button = tester.element(mute);
    final originalBounds = tester.getRect(slider);
    var replacements = 0;
    for (var i = 1; i <= 12; i++) {
      final previous = tester.widget(slider);
      controller.publishSpeed(1 + i * .05);
      await tester.pump();
      if (!identical(previous, tester.widget(slider))) replacements++;
      expect(tester.getRect(slider), originalBounds);
      expect(tester.element(mute), same(button));
    }
    debugPrint('C23_VOLUME_WIDGETS replacements=$replacements');
    expect(replacements, 0);

    // The real slider still writes mute and restore under keyboard focus.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.context, isNotNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(controller.writes, [0.0]);
    expect(find.byTooltip('0%'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(controller.writes, [0.0, 0.2]);
    expect(find.byTooltip('20%'), findsOneWidget);
  });

  testWidgets('failed device write restores the actual slider level', (
    tester,
  ) async {
    final controller = _DeviceVolume()..fail = true;
    await mount(tester, controller);
    expect(find.byTooltip('20%'), findsOneWidget);
    await tapLevel(tester, 0.8);
    expect(controller.writes, isNotEmpty);
    expect(find.byTooltip('20%'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('new input is committed while an earlier refresh is pending', (
    tester,
  ) async {
    final controller = _DeviceVolume();
    await mount(tester, controller);
    final oldRead = Completer<double>();
    controller.readGate = oldRead;
    await tapLevel(tester, 0.8);
    controller.readGate = null;
    await tapLevel(tester, 0.6);
    oldRead.complete(0.8);
    await tester.pump();
    expect(controller.writes.length, 2);
    expect(controller.writes.last, closeTo(0.6, 0.001));
    expect(find.byTooltip('60%'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
