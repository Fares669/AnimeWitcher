import 'dart:async';
import 'dart:io';

import 'package:animewitcher/features/player/presentation/player_controller.dart';
import 'package:animewitcher/features/player/presentation/player_gesture_handler.dart';
import 'package:animewitcher/features/player/presentation/player_platform_service.dart';
import 'package:animewitcher/features/player/presentation/player_teardown.dart';
import 'package:animewitcher/features/player/presentation/widgets/animewitcher_player_controls.dart';
import 'package:animewitcher/features/player/presentation/widgets/player_control_components.dart';
import 'package:animewitcher/features/player/presentation/widgets/player_ltr.dart';
import 'package:animewitcher/features/player/presentation/widgets/player_stream_widgets.dart';
import 'package:animewitcher/features/settings/presentation/player_settings_provider.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:animewitcher/shared/widgets/app_back_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart' as mk;

const _openFixture = ValueKey('open-offline-fixture');
const _pipChannel = MethodChannel('animewitcher.controls-teardown.test/pip');

class _PlayerSettings extends PlayerSettingsNotifier {
  @override
  Future<PlayerSettings> build() async => const PlayerSettings();
}

class _SeekController extends PlayerController {
  _SeekController(this.seek);
  final Future<void> Function(Duration) seek;

  @override
  PlayerState build() => const PlayerState(
    uiPhase: PlaybackUiPhase(kind: PlaybackUiPhaseKind.idle),
  );

  @override
  Future<double> getVolumeLevel() async => 0.25;

  @override
  Future<void> seekRelative(Duration amount, {bool fast = false}) =>
      seek(amount);
}

class _GestureSessionProbe extends PlayerGestureHandler {
  final detached = <int?>[];

  @override
  void detachDeviceControls({int? session}) {
    detached.add(session);
    super.detachDeviceControls(session: session);
  }
}

// Deterministic default backend. The optional Linux test below runs the same
// widget path with actual libmpv and a user-provided local MP4.
class _FixtureBackend extends mk.PlatformPlayer {
  _FixtureBackend() : super(configuration: const mk.PlayerConfiguration()) {
    reopen();
  }

  void reopen() {
    state = state.copyWith(
      playing: true,
      position: const Duration(milliseconds: 250),
      duration: const Duration(seconds: 18),
    );
    playingController.add(true);
  }

  @override
  Future<void> seek(Duration duration) async {
    state = state.copyWith(position: duration);
    positionController.add(duration);
  }

  @override
  Future<void> stop() async {
    state = state.copyWith(playing: false);
    playingController.add(false);
  }
}

void _mockVolumeChannels(WidgetTester tester) {
  final messenger = tester.binding.defaultBinaryMessenger;
  for (final channel in const [
    MethodChannel('com.yosemiteyss.flutter_volume_controller/method'),
    MethodChannel('com.yosemiteyss.flutter_volume_controller/event'),
  ]) {
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  }
}

bool _isDisposed(FocusNode node) {
  try {
    ChangeNotifier.debugAssertNotDisposed(node);
    return false;
  } on FlutterError {
    return true;
  }
}

Future<void> _exerciseBack(
  WidgetTester tester,
  mk.Player player, {
  bool native = false,
  VoidCallback? reopenFixture,
}) async {
  _mockVolumeChannels(tester);
  final messenger = tester.binding.defaultBinaryMessenger;
  final pipCalls = <MethodCall>[];
  messenger.setMockMethodCallHandler(_pipChannel, (call) async {
    pipCalls.add(call);
    return null;
  });
  addTearDown(() => messenger.setMockMethodCallHandler(_pipChannel, null));

  Future<void> runEngine(Future<void> Function() operation) async {
    if (native) {
      await tester.runAsync(operation);
    } else {
      await operation();
    }
  }

  final seekTargets = <Duration>[];
  Future<void>? seek;
  Future<void>? back;
  Future<void> seekBy(Duration amount) {
    final target = player.state.position + amount;
    seekTargets.add(target);
    return seek = runEngine(() => player.seek(target));
  }

  final gestures = _GestureSessionProbe();
  final controlsKey = GlobalKey<AnimeWitcherPlayerControlsState>();

  Widget buildPlaybackRoute(BuildContext context) => Scaffold(
    body: PlayerLtr(
      child: Focus(
        autofocus: true,
        onKeyEvent: (_, event) {
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.arrowRight) {
            // Same controls entry as the player's forward keyboard shortcut.
            controlsKey.currentState!.triggerSeek(false);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: AnimeWitcherPlayerControls(
          key: controlsKey,
          title: 'Offline fixture',
          player: player,
          platformService: PlayerPlatformService(
            pipChannel: _pipChannel,
            nativePip: false,
          ),
          onBackPointer: () {
            back = runEngine(() => stopPlayerBeforeExit(player)).then((_) {
              if (context.mounted) Navigator.of(context).pop();
            });
          },
        ),
      ),
    ),
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        playerControllerProvider.overrideWith(() => _SeekController(seekBy)),
        playerSettingsProvider.overrideWith(_PlayerSettings.new),
        playerGestureHandlerProvider.overrideWith(() => gestures),
      ],
      child: MaterialApp(
        theme: ThemeData(splashFactory: InkRipple.splashFactory),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              key: _openFixture,
              onPressed: () => Navigator.of(context).push<void>(
                PageRouteBuilder<void>(
                  transitionDuration: Duration.zero,
                  reverseTransitionDuration: Duration.zero,
                  pageBuilder: (context, _, _) => buildPlaybackRoute(context),
                ),
              ),
              child: const Text('Open downloaded fixture'),
            ),
          ),
        ),
      ),
    ),
  );

  Future<void> openAndBack() async {
    seek = null;
    back = null;
    seekTargets.clear();
    final priorDetaches = gestures.detached.length;
    await tester.tap(find.byKey(_openFixture));
    await tester.pumpAndSettle();
    expect(player.state.playing, isTrue);
    expect(player.state.duration, greaterThan(const Duration(seconds: 10)));

    final timers = <Timer>[];
    try {
      await runZoned(
        () async {
          // Reveal the chrome, then arm the still-playing seek feedback.
          await tester.tapAt(tester.getCenter(find.byKey(controlsKey)));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 330));
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
          await tester.pump();
          expect(seek, isNotNull);
          await seek!;
          const jumped = Duration(seconds: 10);
          expect(seekTargets.single, greaterThan(jumped));
          if (native && player.state.position < jumped) {
            await tester.runAsync(() async {
              if (player.state.position >= jumped) return;
              await player.stream.position
                  .firstWhere((position) => position >= jumped)
                  .timeout(const Duration(seconds: 2));
            });
          }
          expect(player.state.position, greaterThanOrEqualTo(jumped));
          expect(timers.any((timer) => timer.isActive), isTrue);

          final focusNodes = [
            tester
                .widget<PlayerTopBar>(find.byType(PlayerTopBar))
                .backFocusNode!,
            tester
                .widget<PlayerProgressBar>(find.byType(PlayerProgressBar))
                .focusNode!,
          ];
          expect(focusNodes.where(_isDisposed), isEmpty);

          // Use the visible control, not direct widget removal.
          await tester.tap(find.byType(AppBackButton));
          expect(back, isNotNull);
          await back!;
          await tester.pumpAndSettle();
          final error = tester.takeException();
          final orphanTimers = timers.where((timer) => timer.isActive).length;
          final liveFocus = focusNodes
              .where((node) => !_isDisposed(node))
              .length;
          expect(
            (
              error == null,
              orphanTimers,
              liveFocus,
              gestures.detached.length - priorDetaches,
            ),
            (true, 0, 0, 1),
            reason:
                'Back must release UI resources even with native PiP unavailable. '
                'Framework exception: $error',
          );
          expect(gestures.detached.last, isNotNull);
          expect(pipCalls, isEmpty);
          expect(player.state.playing, isFalse);
          expect(find.byType(AnimeWitcherPlayerControls), findsNothing);
          expect(find.byKey(_openFixture), findsOneWidget);
        },
        zoneSpecification: ZoneSpecification(
          createTimer: (_, parent, zone, duration, callback) {
            final timer = parent.createTimer(zone, duration, callback);
            if (duration == const Duration(seconds: 1) ||
                duration == const Duration(seconds: 3)) {
              timers.add(timer);
            }
            return timer;
          },
        ),
      );
    } finally {
      // Test hygiene for a baseline failure; counts are taken before canceling.
      for (final timer in timers) {
        timer.cancel();
      }
    }
  }

  await openAndBack();
  if (reopenFixture != null) {
    // Keep the ProviderScope alive. A fresh controls widget must get a new
    // device session after Back, not inherit focus/timers from the first.
    reopenFixture();
    await openAndBack();
    expect(gestures.detached.toSet(), hasLength(2));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('player Back releases focus, timers and gestures without PiP', (
    tester,
  ) async {
    final fixture = _FixtureBackend();
    final player = mk.Player(platformPlayer: fixture);
    try {
      await _exerciseBack(tester, player, reopenFixture: fixture.reopen);
    } finally {
      await player.dispose();
    }
  });

  test(
    'PiP bridge can explicitly deactivate without a widget or settings ref',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(_pipChannel, (call) async {
        calls.add(call);
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(_pipChannel, null));

      // Override only the service's existing transport switch, not dart:io's
      // platform or Android's Activity. This checks the wire contract only.
      final service = PlayerPlatformService(
        pipChannel: _pipChannel,
        nativePip: true,
      );
      await service.updatePipSession(
        active: false,
        enabled: false,
        isPlaying: false,
      );
      expect(calls.single.method, 'updatePip');
      expect(calls.single.arguments, {
        'active': false,
        'enabled': false,
        'isPlaying': false,
        'width': 16,
        'height': 9,
      });
    },
  );

  // Opt-in Linux smoke; set both paths to absolute local files. A synthetic
  // H.264 clip with >12 seconds duration works; no media or SDK is fetched.
  final clip = Platform.environment['ANIMEWITCHER_TEST_LOCAL_CLIP'];
  final mpv = Platform.environment['ANIMEWITCHER_TEST_LIBMPV'];
  testWidgets(
    'player Back releases the actual local libmpv playback controls',
    (tester) async {
      final priorTestMode = mk.NativePlayer.test;
      mk.NativePlayer.test = true; // decode with null video/audio output
      addTearDown(() => mk.NativePlayer.test = priorTestMode);
      final player = (await tester.runAsync(() async {
        mk.MediaKit.ensureInitialized(libmpv: mpv);
        final result = mk.Player(
          configuration: const mk.PlayerConfiguration(muted: true),
        );
        final progress = result.stream.position.firstWhere(
          (position) => position >= const Duration(milliseconds: 200),
        );
        await result.open(mk.Media(Uri.file(clip!).toString()));
        await progress.timeout(const Duration(seconds: 5));
        return result;
      }))!;
      try {
        await _exerciseBack(tester, player, native: true);
      } finally {
        await tester.runAsync(player.dispose);
      }
    },
    skip: !Platform.isLinux || clip == null || mpv == null,
  );
}
