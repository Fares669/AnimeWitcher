import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/providers/device_info_provider.dart';
import 'package:animewitcher/features/player/presentation/player_controller.dart';
import 'package:animewitcher/features/player/presentation/player_gesture_handler.dart';
import 'package:animewitcher/features/player/presentation/player_platform_service.dart';
import 'package:animewitcher/features/player/presentation/widgets/animewitcher_player_controls.dart';
import 'package:animewitcher/features/player/presentation/widgets/player_control_components.dart';
import 'package:animewitcher/features/player/presentation/widgets/player_ltr.dart';
import 'package:animewitcher/features/player/presentation/widgets/player_metadata_scrim.dart';
import 'package:animewitcher/features/player/presentation/widgets/player_settings_panel.dart';
import 'package:animewitcher/features/player/presentation/widgets/player_stream_widgets.dart';
import 'package:animewitcher/features/player/presentation/widgets/skip_segment_overlay.dart';
import 'package:animewitcher/features/settings/presentation/player_settings_provider.dart';
import 'package:animewitcher/features/skip/data/skip_service.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:video_view/video_view.dart' as vv;

class _Settings extends PlayerSettingsNotifier {
  @override
  Future<PlayerSettings> build() async => const PlayerSettings();

  void change({
    double? subtitleSize,
    String? preferredPlayer,
    bool? showPlaybackSpeed,
    int? seekDuration,
  }) {
    state = AsyncData(
      state.requireValue.copyWith(
        subtitleSize: subtitleSize,
        preferredPlayer: preferredPlayer,
        showPlaybackSpeed: showPlaybackSpeed,
        seekDuration: seekDuration,
      ),
    );
  }

  @override
  Future<void> setShowRemainingTime(bool value) async {
    state = AsyncData(state.requireValue.copyWith(showRemainingTime: value));
  }
}

class _Controller extends PlayerController {
  _Controller({
    this.segments = const [],
    this.initialVideoView = false,
    this.performSeek,
    this.multimediaItem,
    this.currentEpisode,
  });

  @override
  MultimediaItem? multimediaItem;

  @override
  Episode? currentEpisode;

  @override
  String? get currentEpisodeUrl => currentEpisode?.url;

  @override
  bool get isSeries =>
      multimediaItem?.contentType == MultimediaContentType.anime;

  void changeEpisode(Episode episode) {
    currentEpisode = episode;
    state = state.copyWith(activeEpisodeUrl: episode.url);
  }

  final List<SkipSegment> segments;
  final bool initialVideoView;
  final Future<void> Function(Duration)? performSeek;
  final seeks = <Duration>[];
  final speedWrites = <(double, bool)>[];

  void phase(PlaybackUiPhase value) {
    state = state.copyWith(uiPhase: value);
  }

  @override
  Future<void> setPlaybackSpeed(double rate, {bool persist = false}) async {
    speedWrites.add((rate, persist));
    state = state.copyWith(playbackSpeed: rate);
  }

  @override
  PlayerState build() => PlayerState(
    skipSegments: segments,
    useExoPlayer: initialVideoView,
    isSeekable: initialVideoView,
    uiPhase: const PlaybackUiPhase(kind: PlaybackUiPhaseKind.idle),
  );

  void publishSource(StreamResult source) {
    state = state.copyWith(currentStream: source, streams: [source]);
  }

  void publishSubtitleInventory(List<SubtitleFile> subtitles) {
    state = state.copyWith(externalSubtitles: subtitles);
  }

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

  void setPlaying(bool playing) {
    state = state.copyWith(playing: playing);
    playingController.add(playing);
  }

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
  GlobalKey? paintBoundaryKey,
  VoidCallback? onBack,
  bool tv = false,
}) async {
  _mockVolume(tester);
  final controls = PlayerLtr(
    child: AnimeWitcherPlayerControls(
      player: player,
      videoViewController: videoView,
      platformService: PlayerPlatformService(nativePip: false),
      title: 'Offline fixture',
      onBackPointer: onBack ?? () {},
    ),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        playerControllerProvider.overrideWith(() => controller),
        playerSettingsProvider.overrideWith(_Settings.new),
        if (tv)
          deviceProfileProvider.overrideWithValue(
            const AsyncData(DeviceProfile(isTv: true)),
          ),
      ],
      child: MaterialApp(
        theme: ThemeData(splashFactory: InkRipple.splashFactory),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: paintBoundaryKey == null
              ? controls
              : RepaintBoundary(key: paintBoundaryKey, child: controls),
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

  testWidgets('visible clock moves its playhead without rebuilding the track', (
    tester,
  ) async {
    final source = _FixtureMediaKit()
      ..tick(3000, durationMs: 120000, bufferMs: 42000);
    final player = mk.Player(platformPlayer: source);
    final key = GlobalKey();
    final controller = _Controller(
      segments: [
        SkipSegment(startTime: 15, endTime: 27, type: SkipType.intro),
        SkipSegment(startTime: 31.5, endTime: 35.8, type: SkipType.recap),
        SkipSegment(startTime: 100, endTime: 120, type: SkipType.outro),
      ],
    );
    final previousHook = debugOnRebuildDirtyWidget;
    try {
      await _mount(tester, player, controller, paintBoundaryKey: key);
      await tester.tapAt(_showPoint);
      await tester.pumpAndSettle();
      final track = tester.getRect(_seekTrack);
      final state = tester.state(_seekBar);
      final theme = Theme.of(tester.element(_seekBar)).colorScheme;
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(key),
      );
      expect(find.text('0:03 / 2:00'), findsOneWidget);

      // Large deliberate jumps provide unambiguous played, buffered and
      // untouched pixel samples without rounding at an interval boundary.
      Future<void> paintAt(int ms, int bufferMs) async {
        source.tick(ms, bufferMs: bufferMs);
        await tester.idle();
        await tester.pump();
        final shot = boundary.toImageSync();
        try {
          final data = await tester.runAsync(
            () => shot.toByteData(format: ui.ImageByteFormat.rawRgba),
          );
          expect(data, isNotNull);
          final centerY = boundary.globalToLocal(track.center).dy.round();
          final trackOrigin = boundary.globalToLocal(track.topLeft).dx;
          Color sample(double ratio, {int dy = 0}) {
            final x = (trackOrigin + track.width * ratio).round();
            final offset = (shot.width * (centerY + dy) + x) * 4;
            return Color.fromARGB(
              data!.getUint8(offset + 3),
              data.getUint8(offset),
              data.getUint8(offset + 1),
              data.getUint8(offset + 2),
            );
          }

          // 4 px from the centre is outside the bar (5 px) but within the
          // 14 px circular playhead. Verify both positions on the real track.
          expect(sample(ms / 120000, dy: 4), theme.primary);
          expect(sample(0.12), theme.primary);
          expect(sample(0.45), isNot(sample(0.93)));
        } finally {
          shot.dispose();
        }
      }

      await paintAt(42000, 68000);
      await paintAt(64000, 88000);
      expect(find.text('1:04 / 2:00'), findsOneWidget);
      expect(tester.getRect(_seekTrack), track);

      source.tick(3000, bufferMs: 43000);
      await tester.idle();
      await tester.pump();
      var seekBuilds = 0;
      var labelBuilds = 0;
      debugOnRebuildDirtyWidget = (element, built) {
        previousHook?.call(element, built);
        if (element.widget.runtimeType.toString() == '_SeekBar') seekBuilds++;
        if (element.widget case Text(data: final String text)
            when text.endsWith(' / 2:00')) {
          labelBuilds++;
        }
      };
      final before = source.deliveries;
      for (var i = 1; i <= 96; i++) {
        source.tick(3000 + i * 33, bufferMs: 43000 + i * 25);
        await tester.idle();
        await tester.pump();
      }
      debugOnRebuildDirtyWidget = previousHook;
      final after = source.deliveries;
      expect(after.position - before.position, 192);
      expect(after.buffer - before.buffer, 96);
      expect(seekBuilds, 0);
      expect(labelBuilds, 3);
      expect(find.text('0:06 / 2:00'), findsOneWidget);

      await tester.tap(find.text('0:06 / 2:00'));
      await tester.pumpAndSettle();
      expect(find.text('-1:53 / 2:00'), findsOneWidget);
      source.tick(7001, bufferMs: 46000);
      await tester.idle();
      await tester.pump();
      expect(find.text('-1:52 / 2:00'), findsOneWidget);

      await tester.tapAt(
        Offset(track.left + track.width * .55, track.center.dy),
      );
      await tester.pump();
      expect(controller.seeks.single.inMilliseconds, closeTo(66000, 2));
      expect(tester.state(_seekBar), same(state));
    } finally {
      debugOnRebuildDirtyWidget = previousHook;
      await tester.pumpWidget(const SizedBox.shrink());
      await player.dispose();
    }
  });

  testWidgets('Arabic controls reuse chrome on unrelated preference changes', (
    tester,
  ) async {
    final source = _FixtureMediaKit()
      ..tick(3000, durationMs: 120000, bufferMs: 42000);
    final player = mk.Player(platformPlayer: source);
    final imageKey = GlobalKey();
    final controller = _Controller();
    var backs = 0;

    try {
      await _mount(
        tester,
        player,
        controller,
        paintBoundaryKey: imageKey,
        onBack: () => backs++,
      );
      await tester.tapAt(_showPoint);
      await tester.pumpAndSettle();
      final controls = find.byType(AnimeWitcherPlayerControls);
      final settings = ProviderScope.containerOf(
        tester.element(controls),
      ).read(playerSettingsProvider.notifier) as _Settings;
      final top = find.byType(PlayerTopBar);
      final bottom = find.byType(PlayerBottomBar);
      final panel = find.byType(PlayerSettingsPanel);
      final speedTab = find.text('السرعة');
      final gear = find.byKey(const ValueKey<String>('playerSettingsButton'));
      expect(gear, findsOneWidget);
      expect(AppLocalizations.of(tester.element(controls))!.localeName, 'ar');

      Future<String> shot() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(imageKey),
        );
        final image = boundary.toImageSync();
        try {
          final rgba = await tester.runAsync(
            () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
          );
          return sha256.convert(rgba!.buffer.asUint8List()).toString();
        } finally {
          image.dispose();
        }
      }

      await tester.tap(gear);
      await tester.pumpAndSettle();
      expect(speedTab, findsOneWidget);
      await tester.tap(speedTab);
      await tester.pumpAndSettle();
      expect(find.text('1x'), findsOneWidget);
      final hashes = [await shot()];
      final panelBounds = tester.getRect(panel);
      final replaces = [0, 0, 0];
      final probes = [top, bottom, panel];
      for (var i = 1; i <= 8; i++) {
        final before = [for (final probe in probes) tester.widget(probe)];
        settings.change(
          subtitleSize: 22 + i.toDouble(),
          preferredPlayer: i.isOdd ? 'mpv' : 'vlc',
        );
        await tester.pump(const Duration(milliseconds: 16));
        for (var j = 0; j < probes.length; j++) {
          if (!identical(before[j], tester.widget(probes[j]))) replaces[j]++;
        }
        expect(tester.getRect(panel), panelBounds);
      }
      hashes.add(await shot());
      expect(hashes.last, hashes.first);
      expect(replaces, [0, 0, 0]);

      // Speed still applies through the same request and updates selection.
      await tester.tap(find.text('1.5x'));
      await tester.pumpAndSettle();
      expect(controller.speedWrites, [(1.5, true)]);
      expect(tester.widget<PlayerSettingsPanel>(panel).speed, 1.5);
      hashes.add(await shot());

      // A relevant persisted setting still hides the speed tab, and showing
      // it again exposes the same speed through the existing panel.
      settings.change(showPlaybackSpeed: false);
      await tester.pumpAndSettle();
      expect(speedTab, findsNothing);
      settings.change(showPlaybackSpeed: true, seekDuration: 15);
      await tester.pumpAndSettle();
      expect(speedTab, findsOneWidget);
      expect(tester.widget<PlayerSettingsPanel>(panel).speed, 1.5);
      expect(find.byTooltip('تقديم 15 ثوانٍ'), findsOneWidget);
      hashes.add(await shot());

      // Opening a source replaces the chrome with the loading variant.
      controller.phase(
        const PlaybackUiPhase(
          kind: PlaybackUiPhaseKind.openingSource,
          fullscreenBlocking: true,
        ),
      );
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsWidgets);
      expect(panel, findsNothing);
      // Back in the loading view still reaches the caller's same handler.
      tester.widget<PlayerTopBar>(top).onBack!.call();
      expect(backs, 1);
      controller.phase(const PlaybackUiPhase(kind: PlaybackUiPhaseKind.idle));
      await tester.pumpAndSettle();
      expect(panel, findsOneWidget);
      expect(tester.takeException(), isNull);
      debugPrint(
        'C23_PLAYER_PREFS replacements=${replaces.join('/')} rgba=${hashes.join(',')}',
      );
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await player.dispose();
    }
  });

  testWidgets('subtitle inventory does not redraw Arabic player chrome', (
    tester,
  ) async {
    final mediaKit = _FixtureMediaKit()..tick(3100, durationMs: 24000);
    final player = mk.Player(platformPlayer: mediaKit);
    final videoView = _FixtureVideoView()..tick(8200, durationMs: 26000);
    final controller = _Controller();
    final boundaryKey = GlobalKey();
    var backs = 0;

    Future<String> shot() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(boundaryKey),
      );
      final image = boundary.toImageSync();
      try {
        final rgba = await tester.runAsync(
          () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
        );
        return sha256.convert(rgba!.buffer.asUint8List()).toString();
      } finally {
        image.dispose();
      }
    }

    try {
      final controls = find.byType(AnimeWitcherPlayerControls);
      final top = find.byType(PlayerTopBar);
      final bottom = find.byType(PlayerBottomBar);
      await _mount(
        tester,
        player,
        controller,
        videoView: videoView,
        paintBoundaryKey: boundaryKey,
        onBack: () => backs++,
        tv: true,
      );
      final context = tester.element(controls);
      final container = ProviderScope.containerOf(context);
      expect(AppLocalizations.of(context)!.localeName, 'ar');
      expect(
        Directionality.of(tester.element(find.byType(PlayerLtr))),
        TextDirection.rtl,
      );
      expect(Directionality.of(context), TextDirection.ltr);
      expect(tester.widget<PlayerTopBar>(top).isTv, isTrue);

      final counts = <int>[];
      final hashes = <String>[];
      for (final adaptive in [false, true]) {
        // Separate metadata-only notifications from a real backend/source
        // transition: the latter must still redraw and take the new clock.
        final source = StreamResult(
          url: adaptive
              ? 'https://fixture.test/adaptive.m3u8'
              : 'https://fixture.test/main.mp4',
          source: adaptive ? 'Adaptive' : 'File',
        );
        controller.publishSource(source);
        controller.useVideoView(adaptive);
        await tester.pumpAndSettle();
        expect(
          container.read(playerControllerProvider).currentStream,
          same(source),
        );
        final clock = adaptive ? '0:08 / 0:26' : '0:03 / 0:24';
        expect(find.text(clock), findsOneWidget);
        final focus = FocusManager.instance.primaryFocus;
        final rgba = await shot();
        hashes.add(rgba);
        var replacements = 0;
        for (var i = 0; i < 8; i++) {
          final previous = [tester.widget(top), tester.widget(bottom)];
          final inventory = [
            for (final language in ['ar', 'ja', 'en'])
              SubtitleFile(
                url: 'https://fixture.test/${source.source}/$i/$language.vtt',
                label: language,
                lang: language,
              ),
          ];
          controller.publishSubtitleInventory(inventory);
          await tester.pump();
          final selected = container.read(playerControllerProvider);
          expect(selected.currentStream, same(source));
          expect(selected.externalSubtitles, same(inventory));
          expect(FocusManager.instance.primaryFocus, same(focus));
          if (!identical(previous[0], tester.widget(top))) replacements++;
          if (!identical(previous[1], tester.widget(bottom))) replacements++;
        }
        counts.add(replacements);
        expect(await shot(), rgba);
        expect(find.text(clock), findsOneWidget);
      }

      // The real controls still place the Back button in the D-pad focus
      // chain, and keyboard activation calls the same route callback.
      final backNode = tester.widget<PlayerTopBar>(top).backFocusNode!;
      backNode.requestFocus();
      await tester.pumpAndSettle();
      expect(backNode.hasPrimaryFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(backs, 1);
      debugPrint(
        'C25_TRACK_CHROME replacements=$counts rgba=${hashes.join(",")}',
      );
      const stock = bool.fromEnvironment('C25_STOCK');
      expect(counts, stock ? [16, 16] : [0, 0]);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await player.dispose();
    }
  });

  testWidgets('paused player metadata reuses rendered content', (tester) async {
    final source = _FixtureMediaKit();
    final player = mk.Player(platformPlayer: source);
    final tags = [
      'Drama',
      'Adventure',
      'Fantasy',
      'Action',
      'Comedy',
      'Sci-fi',
    ];
    final controller = _Controller(
      multimediaItem: MultimediaItem(
        title: 'Offline painted metadata',
        url: 'local:show',
        posterUrl: '',
        logoUrl: '',
        description: '  A synopsis with surrounding whitespace.  ',
        contentType: MultimediaContentType.anime,
        tags: tags,
        year: 2020,
        score: 7.5,
      ),
      currentEpisode: Episode(
        name: 'Numbered episode',
        url: 'local:ep2',
        season: 1,
        episode: 2,
      ),
    );
    final paintKey = GlobalKey();
    final scrim = find.byType(PlayerMetadataScrim);
    Finder textInScrim(String value) =>
        find.descendant(of: scrim, matching: find.text(value));
    final title = textInScrim('Offline painted metadata');
    const metadataPrefix = 'Drama, Adventure, Fantasy, Action, Comedy, Sci-fi';
    const plotText = 'A synopsis with surrounding whitespace.';
    final initialMeta = textInScrim(
      '$metadataPrefix  •  2020  •  S1:E2  •  ⭐ 7.5',
    );
    final plot = textInScrim(plotText);
    var backs = 0;

    Future<String> shot() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(paintKey),
      );
      final image = boundary.toImageSync();
      try {
        final rgba = await tester.runAsync(
          () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
        );
        return sha256.convert(rgba!.buffer.asUint8List()).toString();
      } finally {
        image.dispose();
      }
    }

    try {
      await _mount(
        tester,
        player,
        controller,
        paintBoundaryKey: paintKey,
        onBack: () => backs++,
      );
      final controls = find.byType(AnimeWitcherPlayerControls);
      expect(AppLocalizations.of(tester.element(controls))!.localeName, 'ar');
      await tester.pump(const Duration(seconds: 9));
      expect(title, findsNothing);
      source.setPlaying(false);
      await tester.idle();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 7999));
      expect(title, findsNothing);
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pumpAndSettle();
      expect(title, findsOneWidget);
      expect(initialMeta, findsOneWidget);
      expect(plot, findsOneWidget);
      expect(tester.widget<Text>(title).textDirection, TextDirection.ltr);
      final probes = [title, initialMeta, plot];
      final rects = [for (final probe in probes) tester.getRect(probe)];
      final hashes = [await shot()];
      final settings = ProviderScope.containerOf(
        tester.element(controls),
      ).read(playerSettingsProvider.notifier) as _Settings;
      final replacements = [0, 0, 0];
      for (var i = 1; i <= 8; i++) {
        final before = [for (final probe in probes) tester.widget(probe)];
        final oldScrim = tester.widget(scrim);
        settings.change(seekDuration: 10 + i);
        await controller.setPlaybackSpeed(1 + i / 10);
        await tester.pump(const Duration(milliseconds: 16));
        expect(identical(oldScrim, tester.widget(scrim)), isFalse);
        for (var j = 0; j < probes.length; j++) {
          if (!identical(before[j], tester.widget(probes[j]))) {
            replacements[j]++;
          }
          expect(tester.getRect(probes[j]), rects[j]);
        }
      }
      hashes.add(await shot());
      expect(hashes.last, hashes.first);
      expect(replacements, [0, 0, 0]);

      // The item owns a mutable tag list: even an in-place edit must refresh.
      tags[0] = 'Mystery';
      await controller.setPlaybackSpeed(2);
      await tester.pump();
      const editedTags = 'Mystery, Adventure, Fantasy, Action, Comedy, Sci-fi';
      final retagged = textInScrim('$editedTags  •  2020  •  S1:E2  •  ⭐ 7.5');
      expect(initialMeta, findsNothing);
      expect(retagged, findsOneWidget);
      hashes.add(await shot());

      controller.changeEpisode(
        Episode(name: 'مترجم', url: 'local:special', serverName: 'مترجم'),
      );
      await tester.pump();
      final newMeta = textInScrim('$editedTags  •  2020  •  مترجم  •  ⭐ 7.5');
      expect(retagged, findsNothing);
      expect(newMeta, findsOneWidget);
      hashes.add(await shot());

      source.setPlaying(true);
      await tester.idle();
      await tester.pump();
      await tester.pumpAndSettle();
      final retainedAfterResume = newMeta.evaluate().length;
      if (retainedAfterResume > 0) {
        final fade = find.descendant(of: scrim, matching: find.byType(Opacity));
        expect(tester.widget<Opacity>(fade).opacity, 0);
      }
      expect(retainedAfterResume, 0);
      hashes.add(await shot());

      controller.phase(
        const PlaybackUiPhase(
          kind: PlaybackUiPhaseKind.openingSource,
          fullscreenBlocking: true,
        ),
      );
      await tester.pump();
      expect(scrim, findsNothing);
      expect(find.byType(CircularProgressIndicator), findsWidgets);
      tester.widget<PlayerTopBar>(find.byType(PlayerTopBar)).onBack!.call();
      expect(backs, 1);
      expect(tester.takeException(), isNull);
      debugPrint(
        'C24_PLAYER_INFO replacements=${replacements.join('/')} retained=$retainedAfterResume rgba=${hashes.join(',')}',
      );
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await player.dispose();
    }
  });

  testWidgets('position and buffer invalidate only their played track parts', (
    tester,
  ) async {
    final source = _FixtureMediaKit()
      ..tick(3000, durationMs: 120000, bufferMs: 42000);
    final player = mk.Player(platformPlayer: source);
    final key = GlobalKey();
    final controller = _Controller(
      segments: [
        SkipSegment(startTime: 15, endTime: 27, type: SkipType.intro),
        SkipSegment(startTime: 31.5, endTime: 35.8, type: SkipType.recap),
        SkipSegment(startTime: 100, endTime: 120, type: SkipType.outro),
      ],
    );

    try {
      await _mount(tester, player, controller, paintBoundaryKey: key);
      await tester.tapAt(_showPoint);
      await tester.pumpAndSettle();
      final track = tester.getRect(_seekTrack);
      final seekState = tester.state(_seekBar);
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(key),
      );
      final theme = Theme.of(tester.element(_seekBar)).colorScheme;

      Future<({int played, int buffered, int thumb, int frames})> measure(
        void Function(int) tick,
      ) async {
        final played = <RenderClipRRect>[];
        final buffered = <RenderClipRRect>[];
        final clips = find.descendant(
          of: _seekBar,
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is ClipRRect &&
                widget.clipper.runtimeType.toString() == '_TimelineClipper',
          ),
        );
        for (final clip in clips.evaluate()) {
          final widget = clip.widget as ClipRRect;
          final renderObject = clip.renderObject as RenderClipRRect;
          final box = widget.child as ColoredBox;
          (box.color == Colors.white.withValues(alpha: 0.25)
                  ? buffered
                  : played)
              .add(renderObject);
        }
        expect(played.length, 6);
        expect(buffered.length, 6);
        final playheadOffset = tester.renderObject<RenderBox>(
          find.descendant(
            of: _seekBar,
            matching: find.byWidgetPredicate(
              (widget) => widget.runtimeType.toString() == '_PlayheadOffset',
            ),
          ),
        );

        var playedDirty = 0;
        var bufferedDirty = 0;
        var thumbDirty = 0;
        var frames = 0;
        for (var i = 1; i <= 18; i++) {
          expect(played.every((part) => !part.debugNeedsPaint), isTrue);
          expect(buffered.every((part) => !part.debugNeedsPaint), isTrue);
          expect(playheadOffset.debugNeedsPaint, isFalse, reason: 'tick $i');
          expect(tester.binding.hasScheduledFrame, isFalse);
          tick(i);
          await tester.idle();
          playedDirty += played.where((part) => part.debugNeedsPaint).length;
          bufferedDirty += buffered
              .where((part) => part.debugNeedsPaint)
              .length;
          if (playheadOffset.debugNeedsPaint) thumbDirty++;
          if (tester.binding.hasScheduledFrame) frames++;
          await tester.pump();
        }
        return (
          played: playedDirty,
          buffered: bufferedDirty,
          thumb: thumbDirty,
          frames: frames,
        );
      }

      Color sample(ByteData rgba, ui.Image shot, double ratio, {int dy = 0}) {
        final center = boundary.globalToLocal(track.center);
        final start = boundary.globalToLocal(track.topLeft).dx;
        final x = (start + track.width * ratio).round();
        final offset = (shot.width * (center.dy.round() + dy) + x) * 4;
        return Color.fromARGB(
          rgba.getUint8(offset + 3),
          rgba.getUint8(offset),
          rgba.getUint8(offset + 1),
          rgba.getUint8(offset + 2),
        );
      }

      // The player is visible and advancing; the same render objects persist.
      final positionWork = await measure((i) => source.tick(42000 + i * 60));
      final bufferWork = await measure(
        (i) => source.tick(43080, bufferMs: 68000 + i * 60),
      );
      final frame = boundary.toImageSync();
      try {
        final rgba = (await tester.runAsync(
          () => frame.toByteData(format: ui.ImageByteFormat.rawRgba),
        ))!;
        expect(sample(rgba, frame, 43080 / 120000, dy: 4), theme.primary);
        expect(sample(rgba, frame, .12), theme.primary);
        expect(sample(rgba, frame, .45), isNot(sample(rgba, frame, .93)));
      } finally {
        frame.dispose();
      }
      expect(find.text('0:43 / 2:00'), findsOneWidget);

      final drag = await tester.startGesture(
        Offset(track.left + track.width * .43, track.center.dy),
      );
      await drag.moveBy(Offset(track.width * .06, 0));
      await tester.pumpAndSettle();
      await drag.moveBy(Offset(track.width * .06, 0));
      await tester.pumpAndSettle();
      final labels = find.descendant(
        of: find.byType(PlayerProgressBar),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Text && (widget.data?.endsWith(' / 2:00') ?? false),
        ),
      );
      final heldLabel = tester.widget<Text>(labels).data;
      final scrubWork = await measure((i) => source.tick(45000 + i * 60));
      expect(tester.widget<Text>(labels).data, heldLabel);
      expect(controller.seeks, isEmpty);

      // Buffer progress keeps invalidating only its own track during a scrub.
      final scrubBufferWork = await measure(
        (i) => source.tick(46080, bufferMs: 70000 + i * 50),
      );
      expect(tester.widget<Text>(labels).data, heldLabel);
      await drag.up();
      await tester.pumpAndSettle();
      expect(controller.seeks.single.inMilliseconds, closeTo(66000, 3));
      expect(tester.widget<Text>(labels).data, '0:46 / 2:00');
      expect(tester.state(_seekBar), same(seekState));
      expect(tester.getRect(_seekTrack), track);
      debugPrint(
        'C27 checked player clip invalidations: '
        'position=$positionWork buffer=$bufferWork '
        'heldPosition=$scrubWork heldBuffer=$scrubBufferWork',
      );
      // The first seek sample fills four additional intervals across the jump.
      expect(positionWork, (played: 22, buffered: 0, thumb: 18, frames: 18));
      expect(bufferWork, (played: 0, buffered: 18, thumb: 0, frames: 18));
      expect(scrubWork, (played: 0, buffered: 0, thumb: 0, frames: 0));
      // After rebuilding for a held scrub, a clip may conservatively
      // initialize on its first sample before stable widths are suppressed.
      expect(scrubBufferWork, (played: 0, buffered: 23, thumb: 0, frames: 18));
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await player.dispose();
    }
  });

  for (final useVideoView in [false, true]) {
    final backend = useVideoView ? 'VideoView' : 'MediaKit';
    testWidgets('Arabic saturated seek fills stay clean on $backend', (
      tester,
    ) async {
      final mkBackend = _FixtureMediaKit()
        ..tick(3000, durationMs: 120000, bufferMs: 42000);
      final player = mk.Player(platformPlayer: mkBackend);
      final vvBackend = useVideoView
          ? (_FixtureVideoView()..tick(3000, durationMs: 120000))
          : null;
      final controller = _Controller(
        initialVideoView: useVideoView,
        segments: [
          SkipSegment(startTime: 15, endTime: 27, type: SkipType.intro),
          SkipSegment(startTime: 31.5, endTime: 35.8, type: SkipType.recap),
          SkipSegment(startTime: 100, endTime: 120, type: SkipType.outro),
        ],
      );
      final key = GlobalKey();
      var backs = 0;

      void tick(int ms, {int? durationMs, int? bufferMs}) {
        if (vvBackend != null) {
          vvBackend.tick(ms, durationMs: durationMs);
        } else {
          mkBackend.tick(ms, durationMs: durationMs, bufferMs: bufferMs);
        }
      }

      Future<String> shot() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(key),
        );
        final image = boundary.toImageSync();
        try {
          final data = (await tester.runAsync(
            () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
          ))!;
          return sha256
              .convert(
                data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
              )
              .toString();
        } finally {
          image.dispose();
        }
      }

      try {
        await _mount(
          tester,
          player,
          controller,
          videoView: vvBackend,
          paintBoundaryKey: key,
          onBack: () => backs++,
        );
        final controls = find.byType(AnimeWitcherPlayerControls);
        final l10n = AppLocalizations.of(tester.element(controls))!;
        expect(l10n.localeName, 'ar');
        await tester.tapAt(_showPoint);
        await tester.pumpAndSettle();
        expect(find.text('0:03 / 2:00'), findsOneWidget);
        final hashes = [await shot()];
        final playedFills = find.descendant(
          of: _seekBar,
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is ClipRRect &&
                widget.clipper.runtimeType.toString() == '_TimelineClipper' &&
                (widget.child! as ColoredBox).color !=
                    Colors.white.withValues(alpha: .25),
          ),
        );
        final clips = tester
            .renderObjectList<RenderClipRRect>(playedFills)
            .toList(growable: false);
        expect(clips.length, 6);
        var invalidated = 0;
        for (var i = 1; i <= 18; i++) {
          expect(clips.every((clip) => !clip.debugNeedsPaint), isTrue);
          tick(3000 + 83 * i);
          await tester.idle();
          invalidated += clips.where((clip) => clip.debugNeedsPaint).length;
          await tester.pump();
        }
        expect(invalidated, 18);
        expect(find.text('0:04 / 2:00'), findsOneWidget);
        hashes.add(await shot());

        // Several backend samples can arrive before Flutter paints a frame.
        // The moving clip must paint its final (not first) fractional width.
        for (var i = 1; i <= 12; i++) {
          tick(4499 + 9 * i);
          await tester.idle();
        }
        final burstDirty = clips.where((clip) => clip.debugNeedsPaint).length;
        expect(burstDirty, 1);
        await tester.pump();
        hashes.add(await shot());

        // Cross a segment boundary in both directions, keeping the exact
        // fractional geometry, then activate the actual localized skip pill.
        final skip = find.byType(SkipPill);
        tick(14999, bufferMs: 56531);
        await tester.idle();
        await tester.pumpAndSettle();
        expect(skip, findsNothing);
        hashes.add(await shot());

        tick(15000, bufferMs: 56545);
        await tester.idle();
        await tester.pumpAndSettle();
        expect(find.text(l10n.skipIntro), findsOneWidget);
        hashes.add(await shot());

        tick(14997, bufferMs: 56548);
        await tester.idle();
        await tester.pumpAndSettle();
        expect(skip, findsNothing);
        hashes.add(await shot());

        tick(31505, bufferMs: 70283);
        await tester.idle();
        await tester.pumpAndSettle();
        expect(find.text(l10n.skipRecap), findsOneWidget);
        final skipFocus = tester.widget<SkipPill>(skip).focusNode;
        skipFocus.requestFocus();
        await tester.pumpAndSettle();
        expect(skipFocus.hasFocus, isTrue);
        hashes.add(await shot());
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(controller.seeks, [const Duration(milliseconds: 35800)]);
        await tester.pump(const Duration(milliseconds: 2001));
        tick(46017, durationMs: 121000, bufferMs: 72781);
        await tester.idle();
        await tester.pumpAndSettle();
        expect(skip, findsNothing);
        expect(find.text('0:46 / 2:01'), findsOneWidget);
        expect(skipFocus.hasFocus, isFalse);
        hashes.add(await shot());

        final track = tester.getRect(_seekTrack);
        await tester.tapAt(
          Offset(track.left + track.width * .55, track.center.dy),
        );
        await tester.pump();
        expect(controller.seeks.length, 2);
        expect(controller.seeks.last.inMilliseconds, closeTo(66550, 3));
        tester.widget<PlayerTopBar>(find.byType(PlayerTopBar)).onBack!.call();
        expect(backs, 1);
        expect(tester.takeException(), isNull);
        debugPrint(
          'C27_TIMELINE $backend dirty=$invalidated rgba=${hashes.join(',')}',
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await player.dispose();
        vvBackend?.dispose();
      }
    });
  }

  testWidgets('TV seek steps and drag use the latest clock without relayout', (
    tester,
  ) async {
    final source = _FixtureMediaKit()
      ..tick(21030, durationMs: 120000, bufferMs: 50000);
    final player = mk.Player(platformPlayer: source);
    final controller = _Controller();
    final focus = FocusNode(debugLabel: 'test scrubber');
    var seekStarts = 0;
    var seekEnds = 0;
    try {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            playerControllerProvider.overrideWith(() => controller),
            playerSettingsProvider.overrideWith(_Settings.new),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: PlayerLtr(
                child: PlayerProgressBar(
                  player: player,
                  isTv: true,
                  focusNode: focus,
                  onSeekStart: () => seekStarts++,
                  onSeekEnd: () => seekEnds++,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      focus.requestFocus();
      await tester.pumpAndSettle();
      expect(focus.hasFocus, isTrue);
      expect(find.text('0:21 / 2:00'), findsOneWidget);

      source.tick(22950);
      await tester.idle();
      await tester.pump();
      // The playback can advance again during the debounce without
      // overwriting the viewer's chosen target.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(find.text('0:52 / 2:00'), findsOneWidget);
      source.tick(23020);
      await tester.idle();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('0:52 / 2:00'), findsOneWidget);
      expect(controller.seeks, isEmpty);
      await tester.pump(const Duration(milliseconds: 301));
      expect(controller.seeks, [const Duration(milliseconds: 52950)]);
      expect(find.text('0:23 / 2:00'), findsOneWidget);
      expect((seekStarts, seekEnds), (1, 1));

      final rect = tester.getRect(_seekTrack);
      final drag = await tester.startGesture(
        Offset(rect.left + rect.width * .4, rect.center.dy),
      );
      await drag.moveBy(Offset(rect.width * .08, 0));
      await tester.pump();
      await drag.moveBy(Offset(rect.width * .1, 0));
      await tester.pump();
      await drag.up();
      await tester.pumpAndSettle();
      expect(controller.seeks.length, greaterThanOrEqualTo(2));
      expect(controller.seeks.last.inMilliseconds, closeTo(69600, 55));
      expect(seekStarts, seekEnds);
      expect(focus.hasFocus, isTrue);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      focus.dispose();
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
