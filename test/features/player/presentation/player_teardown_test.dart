import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:animewitcher/core/logger/app_diagnostics.dart';
import 'package:animewitcher/features/player/presentation/player_teardown.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

class _Player extends Fake implements Player {
  _Player(this.stopResult);
  final Future<void> stopResult;
  int stops = 0;

  @override
  PlatformPlayer? get platform => null;

  @override
  Future<void> stop() {
    stops++;
    return stopResult;
  }
}

class _Native extends Fake implements NativePlayer {
  _Native({bool pendingRenderer = false, bool pendingPlayer = false}) {
    if (!pendingPlayer) initialized.complete();
    if (!pendingRenderer) renderer.complete();
  }

  final initialized = Completer<void>();
  final renderer = Completer<void>();
  final commands = <List<String>>[];
  final properties = <String, String>{};
  bool stopEntered = false;
  bool disposeEntered = false;
  bool stopped = false;
  bool disposed = false;

  @override
  Future<void> get waitForPlayerInitialization => initialized.future;
  @override
  Future<void> get waitForVideoControllerInitializationIfAttached =>
      renderer.future;

  @override
  Future<void> command(
    List<String> command, {
    bool waitForInitialization = true,
  }) async {
    if (waitForInitialization) {
      await initialized.future;
      await renderer.future;
    }
    commands.add(command);
  }

  @override
  Future<void> setProperty(
    String property,
    String value, {
    bool waitForInitialization = true,
  }) async {
    if (waitForInitialization) {
      await initialized.future;
      await renderer.future;
    }
    properties[property] = value;
  }

  @override
  Future<void> stop({
    bool open = false,
    bool notify = true,
    bool synchronized = true,
  }) {
    Future<void> stop() async {
      stopEntered = true;
      await initialized.future;
      await renderer.future;
      stopped = true;
    }

    return synchronized ? NativePlayer.lock.synchronized(stop) : stop();
  }

  @override
  Future<void> dispose({bool synchronized = true}) {
    Future<void> dispose() async {
      disposeEntered = true;
      await initialized.future;
      await renderer.future;
      disposed = true;
    }

    return synchronized ? NativePlayer.lock.synchronized(dispose) : dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory diagnosticsDirectory;
  setUpAll(() async {
    diagnosticsDirectory = await Directory.systemTemp.createTemp(
      'teardown-diagnostics-',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => diagnosticsDirectory.path,
        );
  });
  tearDownAll(() async {
    await appDiagnostics.setEnabled(false);
    await appDiagnostics.flush();
    await diagnosticsDirectory.delete(recursive: true);
  });

  Future<List<String>> diagnosticEventNames() async {
    await appDiagnostics.flush();
    final names = <String>[];
    for (final file in await appDiagnostics.listFiles()) {
      names.addAll(
        (await file.readAsLines())
            .where((line) => line.isNotEmpty)
            .map(
              (line) =>
                  (jsonDecode(line) as Map<String, dynamic>)['event'] as String,
            ),
      );
    }
    return names;
  }

  testWidgets('exit finishes when native stop remains behind a hung open', (
    tester,
  ) async {
    await tester.runAsync(() => appDiagnostics.setEnabled(true));
    final pendingStop = Completer<void>();
    final player = _Player(pendingStop.future);
    var exited = false;
    unawaited(stopPlayerBeforeExit(player).then((_) => exited = true));
    await tester.pump(const Duration(seconds: 2));
    expect(exited, isTrue);
    expect(player.stops, 1);
    final timedOut = await tester.runAsync(diagnosticEventNames);
    expect(timedOut, contains('player.teardown_stop.begin'));
    expect(timedOut, contains('player.teardown_stop.timeout'));
    expect(timedOut, isNot(contains('player.teardown_stop.end')));
    pendingStop.complete();
    await tester.pump();
    expect(
      await tester.runAsync(diagnosticEventNames),
      contains('player.teardown_stop.end'),
    );
    await tester.runAsync(() => appDiagnostics.setEnabled(false));
  });

  for (final disposing in [false, true]) {
    testWidgets(
      '${disposing ? 'dispose' : 'stop'} waits for the renderer outside the shared native lock',
      (tester) async {
        final native = _Native(pendingRenderer: true);
        final player = Player(platformPlayer: native);
        final cleanup = disposing
            ? disposePlayerAfterExit(player)
            : stopPlayerBeforeExit(player);
        var nextEngineCanStart = false;
        final nextEngine = NativePlayer.lock.synchronized(
          () => nextEngineCanStart = true,
        );
        try {
          await tester.pump();
          expect(nextEngineCanStart, isTrue);
          expect(
            disposing ? native.disposeEntered : native.stopEntered,
            isFalse,
          );
        } finally {
          native.renderer.complete();
          await cleanup;
          await nextEngine;
        }
        expect(disposing ? native.disposed : native.stopped, isTrue);
      },
    );
  }

  testWidgets(
    'raw stop interrupts a busy native open without taking its global lock',
    (tester) async {
      final busyEngine = Completer<void>();
      final busy = NativePlayer.lock.synchronized(() => busyEngine.future);
      final native = _Native();
      final player = Player(platformPlayer: native);
      var exited = false;
      final cleanup = stopPlayerBeforeExit(player).then((_) => exited = true);
      try {
        await tester.pump();
        expect(native.commands, [
          <String>['stop'],
        ]);
        expect(native.properties['mute'], 'yes');
        expect(native.stopped, isFalse);
        await tester.pump(const Duration(seconds: 2));
        expect(exited, isTrue);
      } finally {
        busyEngine.complete();
        await busy;
        await cleanup;
        await tester.pump();
      }
      expect(native.stopped, isTrue);
    },
  );

  testWidgets('raw stop waits until a native player handle exists', (
    tester,
  ) async {
    final native = _Native(pendingPlayer: true);
    final cleanup = stopPlayerBeforeExit(Player(platformPlayer: native));
    try {
      await tester.pump();
      expect(native.commands, isEmpty);
      expect(native.stopEntered, isFalse);
    } finally {
      native.initialized.complete();
      await cleanup;
    }
    expect(native.commands, [
      <String>['stop'],
    ]);
    expect(native.stopped, isTrue);
  });

  test('exit awaits a normal stop before completing', () async {
    final pendingStop = Completer<void>();
    final player = _Player(pendingStop.future);
    var exited = false;
    final stopping = stopPlayerBeforeExit(player).then((_) => exited = true);
    await Future<void>.delayed(Duration.zero);
    expect(exited, isFalse);
    pendingStop.complete();
    await stopping;
    expect(exited, isTrue);
    expect(player.stops, 1);
  });

  testWidgets('a stop failure arriving after exit is safely consumed', (
    tester,
  ) async {
    final pendingStop = Completer<void>();
    var exited = false;
    unawaited(
      stopPlayerBeforeExit(_Player(pendingStop.future))
          .then((_) => exited = true),
    );
    await tester.pump(const Duration(seconds: 2));
    expect(exited, isTrue);
    pendingStop.completeError(StateError('Disposed native player'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
