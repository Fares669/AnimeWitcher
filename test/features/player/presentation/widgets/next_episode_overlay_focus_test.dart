import 'dart:io';

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/providers/device_info_provider.dart';
import 'package:animewitcher/features/details/presentation/downloaded_file_provider.dart';
import 'package:animewitcher/features/player/presentation/player_controller.dart';
import 'package:animewitcher/features/player/presentation/player_platform_service.dart';
import 'package:animewitcher/features/player/presentation/widgets/animewitcher_player_controls.dart';
import 'package:animewitcher/features/player/presentation/widgets/next_episode_overlay.dart';
import 'package:animewitcher/features/player/presentation/widgets/player_ltr.dart';
import 'package:animewitcher/features/settings/presentation/player_settings_provider.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart' as mk;

const _nextTitle = 'Local episode two';

class _TrackedFocusNode extends FocusNode {
  final _listeners = <VoidCallback>{};

  int get listenerCount => _listeners.length;

  @override
  void addListener(VoidCallback callback) {
    _listeners.add(callback);
    super.addListener(callback);
  }

  @override
  void removeListener(VoidCallback callback) {
    _listeners.remove(callback);
    super.removeListener(callback);
  }
}

FocusNode _focus(String label, {Finder? of}) {
  final matching = find.byWidgetPredicate(
    (widget) => widget is Focus && widget.focusNode?.debugLabel == label,
  );
  return (of == null ? matching : find.descendant(of: of, matching: matching))
      .evaluate()
      .map((element) => (element.widget as Focus).focusNode!)
      .toSet()
      .single;
}

double _focusScale(WidgetTester tester, FocusNode node) => tester
    .widget<AnimatedScale>(
      find.descendant(
        of: find.byWidgetPredicate(
          (widget) => widget is Focus && identical(widget.focusNode, node),
        ),
        matching: find.byType(AnimatedScale),
      ),
    )
    .scale;

Widget _app(Widget body) => MaterialApp(
  theme: ThemeData(splashFactory: InkRipple.splashFactory),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: body),
);

void _wide(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1280, 800);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

class _Settings extends PlayerSettingsNotifier {
  @override
  Future<PlayerSettings> build() async => const PlayerSettings();
}

class _Playback extends PlayerController {
  final episode = Episode(name: _nextTitle, url: 'local-series:2', episode: 2);
  late final item = MultimediaItem(
    title: 'Local series',
    url: 'local-series:',
    posterUrl: '',
    episodes: [episode],
    contentType: MultimediaContentType.series,
  );

  final played = <StreamResult?>[];

  @override
  PlayerState build() => const PlayerState(
    uiPhase: PlaybackUiPhase(kind: PlaybackUiPhaseKind.idle),
  );

  @override
  MultimediaItem get multimediaItem => item;

  @override
  Episode get nextEpisode => episode;

  void showPrompt() {
    state = state.copyWith(
      showNextEpisodeOverlay: true,
      nextEpisodeTitle: _nextTitle,
    );
  }

  @override
  Future<void> playNextEpisode({StreamResult? selectedSource}) async {
    played.add(selectedSource);
    dismissNextEpisodeOverlay();
  }

  @override
  Future<double> getVolumeLevel() async => .25;
}

// The production source chooser still takes its normal local-file branch;
// the test supplies this lookup and records the backend handoff.
class _LocalDownload extends DownloadedFiles {
  _LocalDownload(this.file);

  final File file;
  final lookups = <String>[];

  @override
  Map<String, File?> build() => const {};

  @override
  Future<File?> resolveFile(
    MultimediaItem item, {
    Episode? episode,
    String? logicalId,
  }) async {
    lookups.add(episode?.url ?? item.url);
    return file;
  }
}

class _PausedMediaKit extends mk.PlatformPlayer {
  _PausedMediaKit() : super(configuration: const mk.PlayerConfiguration()) {
    state = state.copyWith(
      playing: false,
      duration: const Duration(seconds: 18),
    );
  }
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

void main() {
  testWidgets('TV prompt releases its borrowed Play Now focus callbacks', (
    tester,
  ) async {
    _wide(tester);
    final node = _TrackedFocusNode();
    final open = ValueNotifier(false);
    var dismissed = 0;
    var played = 0;
    final retained = <int>[];
    final live = <int>[];
    var sent = 0;
    try {
      await tester.pumpWidget(
        _app(
          ValueListenableBuilder<bool>(
            valueListenable: open,
            builder: (context, show, _) => Stack(
              children: [
                if (show)
                  NextEpisodeOverlay(
                    focusNode: node,
                    nextEpisodeTitle: _nextTitle,
                    isTv: true,
                    isPlaying: false,
                    onPlayNext: () {
                      played++;
                      open.value = false;
                    },
                    onDismiss: () {
                      dismissed++;
                      open.value = false;
                    },
                  ),
              ],
            ),
          ),
        ),
      );
      final overlay = find.byType(NextEpisodeOverlay);
      for (var i = 0; i < 8; i++) {
        open.value = true;
        await tester.pumpAndSettle();
        expect(overlay, findsOneWidget);
        node.requestFocus();
        await tester.pumpAndSettle();
        expect(node.hasPrimaryFocus, isTrue);
        expect(_focusScale(tester, node), 1.03);
        live.add(node.listenerCount);
        if (i.isEven) {
          final cancel = _focus('next_ep_cancel', of: overlay);
          cancel.requestFocus();
          await tester.pumpAndSettle();
          expect(cancel.hasPrimaryFocus, isTrue);
          expect(_focusScale(tester, node), 1);
          expect(_focusScale(tester, cancel), 1.03);
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        } else {
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        }
        sent++;
        await tester.pumpAndSettle();
        expect(overlay, findsNothing);
        retained.add(node.listenerCount);
      }
      expect((sent, dismissed, played), (8, 4, 4));
      // Includes Flutter Focus's own active attachment. No change listener
      // from the closed prompt should remain on the borrowed node.
      debugPrint('next_prompt_focus live=$live retained=$retained');
      expect(retained, List.filled(8, 0));
      expect(live.toSet(), hasLength(1));
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      open.dispose();
      node.dispose();
    }
  });

  testWidgets('TV controls route D-pad up, Cancel and Play Now locally', (
    tester,
  ) async {
    _wide(tester);
    _mockVolume(tester);
    final controller = _Playback();
    final localDownload = _LocalDownload(File('/synthetic/local-episode2.mp4'));
    final player = mk.Player(platformPlayer: _PausedMediaKit());
    try {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            deviceProfileProvider.overrideWith(
              (ref) async => const DeviceProfile(isTv: true),
            ),
            playerControllerProvider.overrideWith(() => controller),
            playerSettingsProvider.overrideWith(_Settings.new),
            downloadedFilesProvider.overrideWith(() => localDownload),
          ],
          child: _app(
            Consumer(
              builder: (context, ref, _) {
                if (!ref.watch(deviceProfileProvider).hasValue) {
                  return const SizedBox.shrink();
                }
                return PlayerLtr(
                  child: AnimeWitcherPlayerControls(
                    player: player,
                    platformService: PlayerPlatformService(nativePip: false),
                    onBackPointer: () {},
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final overlay = find.byType(NextEpisodeOverlay);
      final retained = <bool>[];
      for (var i = 0; i < 4; i++) {
        controller.showPrompt();
        await tester.pumpAndSettle();
        final next = _focus('next_episode_prompt', of: overlay);
        final scrubber = _focus('controls_scrubber');
        scrubber.requestFocus();
        await tester.pumpAndSettle();
        expect(scrubber.hasPrimaryFocus, isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pumpAndSettle();
        expect(next.hasPrimaryFocus, isTrue);
        if (i.isEven) {
          final cancel = _focus('next_ep_cancel', of: overlay);
          cancel.requestFocus();
          await tester.pumpAndSettle();
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        } else {
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        }
        await tester.pumpAndSettle();
        expect(overlay, findsNothing);
        // ignore: invalid_use_of_protected_member
        retained.add(next.hasListeners);
      }
      expect(localDownload.lookups, List.filled(2, controller.episode.url));
      expect(
        controller.played.map((source) => source?.url),
        List.filled(2, localDownload.file.uri.toString()),
      );
      debugPrint('next_controls_focus retained=$retained');
      expect(retained, List.filled(4, false));
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await player.dispose();
    }
  });
}
