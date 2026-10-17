import 'dart:async';

import 'package:animewitcher/features/player/presentation/player_controller.dart';
import 'package:animewitcher/features/player/presentation/widgets/player_stream_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _DeviceVolume extends PlayerController {
  double device = 0.2;
  bool fail = false;
  Completer<double>? readGate;
  final writes = <double>[];

  @override
  PlayerState build() => const PlayerState();

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
