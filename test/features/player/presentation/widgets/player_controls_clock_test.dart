import 'dart:async';
import 'dart:io';

import 'package:animewitcher/features/player/presentation/player_controller.dart';
import 'package:animewitcher/features/player/presentation/player_gesture_handler.dart';
import 'package:animewitcher/features/player/presentation/player_platform_service.dart';
import 'package:animewitcher/features/player/presentation/widgets/animewitcher_player_controls.dart';
import 'package:animewitcher/features/player/presentation/widgets/player_ltr.dart';
import 'package:animewitcher/features/player/presentation/widgets/player_stream_widgets.dart';
import 'package:animewitcher/features/settings/presentation/player_settings_provider.dart';
import 'package:animewitcher/features/skip/data/skip_service.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:video_view/video_view.dart' as vv;

class _Settings extends PlayerSettingsNotifier {
  @override
  Future<PlayerSettings> build() async => const PlayerSettings();

  @override
  Future<void> setShowRemainingTime(bool value) async {
    state = AsyncData(state.requireValue.copyWith(showRemainingTime: value));
  }
}

class _Controller extends PlayerController {
  _Controller({this.segments = const [], this.performSeek});

  final List<SkipSegment> segments;
  final Future<void> Function(Duration)? performSeek;
  final seeks = <Duration>[];

  @override
  PlayerState build() => PlayerState(
    skipSegments: segments,
    uiPhase: const PlaybackUiPhase(kind: PlaybackUiPhaseKind.idle),
  );

  void useVideoView(bool value) {
    state = state.copyWith(useExoPlayer: value, isSeekable: value);
  }

  @override
  Future<double> getVolumeLevel() async => 0.25;

  @override
  Future<void> seekTo(Duration position, {bool fast = false}) async {
    seeks.add(position);
    await performSeek?.call(position);
  }
}

// Count a delivery to each subscriber, not just each backend event.
class _CountedDurationStream extends StreamView<Duration> {
  _CountedDurationStream(super.stream);

  int deliveries = 0;

  @override
  StreamSubscription<Duration> listen(
    void Function(Duration)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => super.listen(
    (value) {
      deliveries++;
      onData?.call(value);
    },
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
}

class _FixtureMediaKit extends mk.PlatformPlayer {
  _FixtureMediaKit() : super(configuration: const mk.PlayerConfiguration()) {
    state = state.copyWith(
      playing: true,
      duration: const Duration(seconds: 18),
      buffer: const Duration(seconds: 5),
    );

    final streams = stream;
    positionEvents = _CountedDurationStream(streams.position);
    durationEvents = _CountedDurationStream(streams.duration);
    bufferEvents = _CountedDurationStream(streams.buffer);
    stream = mk.PlayerStream(
      streams.playlist,
      streams.playing,
      streams.completed,
      positionEvents,
      durationEvents,
      streams.volume,
      streams.rate,
      streams.pitch,
      streams.buffering,
      streams.bufferingPercentage,
      bufferEvents,
      streams.playlistMode,
      streams.shuffle,
      streams.audioParams,
      streams.videoParams,
      streams.audioBitrate,
      streams.audioDevice,
      streams.audioDevices,
      streams.track,
      streams.tracks,
      streams.width,
      streams.height,
      streams.subtitle,
      streams.log,
      streams.error,
    );
  }

  late final _CountedDurationStream positionEvents;
  late final _CountedDurationStream durationEvents;
  late final _CountedDurationStream bufferEvents;

  ({int position, int duration, int buffer}) get deliveries => (
    position: positionEvents.deliveries,
    duration: durationEvents.deliveries,
    buffer: bufferEvents.deliveries,
  );

  void tick(int ms, {int? durationMs, int? bufferMs}) {
    final position = Duration(milliseconds: ms);
    final duration = durationMs == null
        ? state.duration
        : Duration(milliseconds: durationMs);
    final buffer = bufferMs == null
        ? state.buffer
        : Duration(milliseconds: bufferMs);
    state = state.copyWith(
      position: position,
      duration: duration,
      buffer: buffer,
    );
    positionController.add(position);
    if (durationMs != null) durationController.add(duration);
    if (bufferMs != null) bufferController.add(buffer);
  }
}

// This verifies the vendored controller's Dart listeners/handoff, not an
// Android ExoPlayer or Apple AVPlayer device.
class _FixtureVideoView extends vv.VideoController {
  _FixtureVideoView() : super.create();

  void tick(int ms, {int? durationMs}) {
    if (durationMs != null) {
      // ignore: invalid_use_of_protected_member
      mediaInfo.value = vv.VideoControllerMediaInfo(
        durationMs,
        const {},
        const {},
        'local fixture',
      );
    }
    // ignore: invalid_use_of_protected_member
    position.value = ms;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void _mockVolume(WidgetTester tester) {
  final messenger = tester.binding.defaultBinaryMessenger;
  for (final channel in const [
    MethodChannel('com.yosemiteyss.flutter_volume_controller/method'),
    MethodChannel('com.yosemiteyss.flutter_volume_controller/event'),
  ]) {
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  }
}

Future<void> _mount(
  WidgetTester tester,
  mk.Player player,
  _Controller controller, {
  vv.VideoController? videoView,
}) async {
  _mockVolume(tester);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        playerControllerProvider.overrideWith(() => controller),
        playerSettingsProvider.overrideWith(_Settings.new),
      ],
      child: MaterialApp(
        theme: ThemeData(splashFactory: InkRipple.splashFactory),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: PlayerLtr(
            child: AnimeWitcherPlayerControls(
              player: player,
              videoViewController: videoView,
              platformService: PlayerPlatformService(nativePip: false),
              title: 'Offline fixture',
              onBackPointer: () {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder get _seekBar =>
    find.byWidgetPredicate((w) => w.runtimeType.toString() == '_SeekBar');

Finder get _seekTrack => find.descendant(
  of: find.byType(PlayerProgressBar),
  matching: find.byWidgetPredicate(
    (w) => w is GestureDetector && w.onHorizontalDragUpdate != null,
  ),
);

// Two distinct points avoid classifying quick test taps as a double tap.
const _showPoint = Offset(198, 288);
const _hidePoint = Offset(612, 289);

Future<({int scheduled, int seekBuilds})> _clockWork(
  WidgetTester tester,
  void Function(int) tick,
  int samples,
) async {
  var scheduled = 0;
  var seekBuilds = 0;
  final previousHook = debugOnRebuildDirtyWidget;
  debugOnRebuildDirtyWidget = (element, builtOnce) {
    previousHook?.call(element, builtOnce);
    if (element.widget.runtimeType.toString() == '_SeekBar') seekBuilds++;
  };
  try {
    await tester.idle();
    expect(tester.binding.hasScheduledFrame, isFalse);
    for (var i = 0; i < samples; i++) {
      tick(i);
      // Flush the backend notification before the test pumps. This counts
      // automatic Flutter scheduling, not manually requested test frames.
      await tester.idle();
      if (tester.binding.hasScheduledFrame) scheduled++;
      await tester.pump(const Duration(milliseconds: 50));
    }
    return (scheduled: scheduled, seekBuilds: seekBuilds);
  } finally {
    debugOnRebuildDirtyWidget = previousHook;
  }
}

void main() {
  testWidgets('settled hidden MediaKit clock does not schedule seek UI', (
    tester,
  ) async {
    final source = _FixtureMediaKit();
    final player = mk.Player(platformPlayer: source);
    final controller = _Controller();
    try {
      await _mount(tester, player, controller);
      await tester.tapAt(_showPoint);
      await tester.pumpAndSettle();
      final seekState = tester.state(_seekBar);
      source.tick(2400, bufferMs: 7000);
      await tester.idle(); // Deliver broadcasts before the UI frame.
      await tester.pump();
      expect(find.text('0:02 / 0:18'), findsOneWidget);

      await tester.tapAt(_hidePoint);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      source.tick(3500, bufferMs: 8000);
      await tester.idle(); // Deliver broadcasts before the UI frame.
      await tester.pump();
      expect(
        find.text('0:03 / 0:18'),
        findsOneWidget,
        reason: 'The still-visible fade-out must keep updating.',
      );
      await tester.pumpAndSettle();

      // Duration, position and buffer all change while the chrome is hidden.
      final before = source.deliveries;
      final work = await _clockWork(tester, (i) {
        source.tick(
          4300 + i * 350,
          durationMs: 18500 + i,
          bufferMs: 9500 + i * 400,
        );
      }, 24);
      final after = source.deliveries;
      expect(
        (
          position: after.position - before.position,
          duration: after.duration - before.duration,
          buffer: after.buffer - before.buffer,
        ),
        // The parent still needs duration changes to reveal chrome on load.
        (position: 0, duration: 24, buffer: 0),
        reason: 'Do not deliver clock events to invisible seek controls.',
      );

      final gestures = ProviderScope.containerOf(
        tester.element(find.byType(AnimeWitcherPlayerControls)),
      ).read(playerGestureHandlerProvider.notifier);
      expect(gestures.getPosition?.call(), source.state.position);

      await tester.tapAt(_showPoint);
      await tester.pump();
      expect(find.text('0:12 / 0:18'), findsOneWidget);
      expect(identical(tester.state(_seekBar), seekState), isTrue);
      await tester.pumpAndSettle();
      await tester.tap(find.text('0:12 / 0:18'));
      await tester.pumpAndSettle();
      expect(find.text('-0:06 / 0:18'), findsOneWidget);

      final track = tester.getRect(_seekTrack);
      await tester.tapAt(Offset(track.left + track.width / 2, track.center.dy));
      await tester.pump();
      expect(controller.seeks.single.inMilliseconds, closeTo(9262, 3));
      expect(work, (
        scheduled: 0,
        seekBuilds: 0,
      ), reason: "Settled hidden MediaKit clock must not drive frames.");
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await player.dispose();
    }
  });

  testWidgets('hidden VideoView clock catches up and switches to MediaKit', (
    tester,
  ) async {
    final source = _FixtureMediaKit()..tick(1000);
    final player = mk.Player(platformPlayer: source);
    final videoView = _FixtureVideoView()..tick(5100, durationMs: 29000);
    final controller = _Controller();
    try {
      await _mount(tester, player, controller, videoView: videoView);
      await tester.tapAt(_showPoint);
      await tester.pumpAndSettle();
      final mediaKitState = tester.state(_seekBar);
      expect(find.text('0:01 / 0:18'), findsOneWidget);
      controller.useVideoView(true);
      await tester.pumpAndSettle();
      expect(find.text('0:05 / 0:29'), findsOneWidget);
      expect(videoView.position.listeners.length, 1);
      expect(videoView.mediaInfo.listeners.length, 2);
      expect(
        identical(tester.state(_seekBar), mediaKitState),
        isFalse,
        reason: 'Changing engine retains the previous gesture reset.',
      );

      await tester.tapAt(_hidePoint);
      await tester.pumpAndSettle();
      expect(videoView.position.listeners, isEmpty);
      expect(videoView.mediaInfo.listeners.length, 1);
      final work = await _clockWork(tester, (i) {
        videoView.tick(7000 + i * 500, durationMs: 36000 + i * 600);
        source.tick(
          4000 + i * 300,
          durationMs: 19000 + i * 400,
          bufferMs: 5500 + i * 120,
        );
      }, 12);
      final gestures = ProviderScope.containerOf(
        tester.element(find.byType(AnimeWitcherPlayerControls)),
      ).read(playerGestureHandlerProvider.notifier);
      expect(
        gestures.getPosition?.call(),
        Duration(milliseconds: videoView.position.value),
        reason: 'Gesture seed reads the active backend even while hidden.',
      );

      await tester.tapAt(_showPoint);
      await tester.pumpAndSettle();
      expect(find.text('0:12 / 0:42'), findsOneWidget);
      expect(videoView.position.listeners.length, 1);
      expect(videoView.mediaInfo.listeners.length, 2);

      // Switching backends while hidden still attaches only on reveal.
      await tester.tapAt(_hidePoint);
      await tester.pumpAndSettle();
      controller.useVideoView(false);
      await tester.pumpAndSettle();
      expect(videoView.position.listeners, isEmpty);
      expect(videoView.mediaInfo.listeners.length, 1);
      await tester.tapAt(_showPoint);
      await tester.pumpAndSettle();
      expect(find.text('0:07 / 0:23'), findsOneWidget);
      expect(gestures.getPosition?.call(), source.state.position);

      // Interrupt a fade-out and verify the clock stays live on reveal.
      await tester.tapAt(_hidePoint);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tapAt(_showPoint);
      await tester.pumpAndSettle();
      source.tick(9200);
      await tester.idle(); // Deliver broadcasts before the UI frame.
      await tester.pump();
      expect(find.text('0:09 / 0:23'), findsOneWidget);
      expect(work, (
        scheduled: 0,
        seekBuilds: 0,
      ), reason: 'Settled hidden VideoView clock must not drive frames.');
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      videoView.dispose();
      await player.dispose();
    }
  });

  // Same optional, local fixture as the player Back test. No network fetch,
  // native output window, Android engine, or physical audio is required.
  final clip = Platform.environment['ANIMEWITCHER_TEST_LOCAL_CLIP'];
  final mpv = Platform.environment['ANIMEWITCHER_TEST_LIBMPV'];
  testWidgets(
    'native offline controls keep skip and seek live while clock hides',
    (tester) async {
      final previous = mk.NativePlayer.test;
      mk.NativePlayer.test = true;
      addTearDown(() => mk.NativePlayer.test = previous);
      final player = (await tester.runAsync(() async {
        mk.MediaKit.ensureInitialized(libmpv: mpv);
        final native = mk.Player(
          configuration: const mk.PlayerConfiguration(muted: true),
        );
        final ready = native.stream.position.firstWhere(
          (p) => p >= const Duration(milliseconds: 200),
        );
        await native.open(mk.Media(Uri.file(clip!).toString()));
        await ready.timeout(const Duration(seconds: 5));
        return native;
      }))!;
      final seeks = <Future<void>>[];
      final controller = _Controller(
        segments: [SkipSegment(startTime: 0, endTime: 7, type: SkipType.intro)],
        performSeek: (position) async {
          seeks.add(tester.runAsync(() => player.seek(position)));
        },
      );
      final previousHook = debugOnRebuildDirtyWidget;
      try {
        await _mount(tester, player, controller);
        final skip = find.text('تخطي المقدمة');
        for (var i = 0; i < 20 && skip.evaluate().isEmpty; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 55)),
          );
          await tester.pump(const Duration(milliseconds: 55));
        }
        expect(skip, findsOneWidget);
        await tester.pumpAndSettle();

        final start = player.state.position;
        var seekBuilds = 0;
        debugOnRebuildDirtyWidget = (element, _) {
          if (element.widget.runtimeType.toString() == '_SeekBar') seekBuilds++;
        };
        for (var i = 0; i < 14; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 70)),
          );
          await tester.pump(const Duration(milliseconds: 70));
        }
        expect(
          player.state.position - start,
          greaterThan(const Duration(milliseconds: 550)),
        );
        expect(skip, findsOneWidget);
        debugOnRebuildDirtyWidget = previousHook;

        await tester.tapAt(_showPoint);
        await tester.pumpAndSettle();
        final passed = player.state.position.inSeconds.toString().padLeft(
          2,
          '0',
        );
        final total = player.state.duration.inSeconds.toString().padLeft(
          2,
          '0',
        );
        expect(find.text('0:$passed / 0:$total'), findsOneWidget);
        final track = tester.getRect(_seekTrack);
        await tester.tapAt(
          Offset(track.left + track.width * .6, track.center.dy),
        );
        await tester.pump();
        await Future.wait(seeks);
        await tester.runAsync(() async {
          const target = Duration(seconds: 9);
          if (player.state.position >= target) return;
          await player.stream.position
              .firstWhere((p) => p >= target)
              .timeout(const Duration(seconds: 3));
        });
        expect(
          player.state.position,
          greaterThanOrEqualTo(const Duration(seconds: 9)),
        );
        expect(
          seekBuilds,
          0,
          reason: 'Native playback should not rebuild hidden seek UI.',
        );
      } finally {
        debugOnRebuildDirtyWidget = previousHook;
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(player.dispose);
      }
    },
    skip: !Platform.isLinux || clip == null || mpv == null,
  );
}
