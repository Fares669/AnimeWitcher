import 'dart:async';
import 'dart:io';

import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/providers/device_info_provider.dart';
import 'package:animewitcher/core/storage/episode_watch_repository.dart';
import 'package:animewitcher/core/storage/history_repository.dart';
import 'package:animewitcher/features/details/presentation/details_controller.dart';
import 'package:animewitcher/features/details/presentation/downloaded_file_provider.dart';
import 'package:animewitcher/features/library/presentation/downloads_provider.dart';
import 'package:animewitcher/features/player/presentation/episode_navigation.dart';
import 'package:animewitcher/features/player/presentation/player_controller.dart';
import 'package:animewitcher/features/player/presentation/player_platform_service.dart';
import 'package:animewitcher/features/player/presentation/widgets/animewitcher_player_controls.dart';
import 'package:animewitcher/features/player/presentation/widgets/next_episode_overlay.dart';
import 'package:animewitcher/features/player/presentation/widgets/player_side_panel.dart';
import 'package:animewitcher/features/settings/presentation/player_settings_provider.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:animewitcher/shared/widgets/app_back_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart' as mk;

class _FixtureBackend extends mk.PlatformPlayer {
  _FixtureBackend() : super(configuration: const mk.PlayerConfiguration()) {
    state = state.copyWith(
      playing: true,
      position: const Duration(seconds: 30),
      duration: const Duration(minutes: 24),
    );
  }
}

class _Player extends PlayerController {
  _Player(this.item, this.activeEpisode);
  final MultimediaItem item;
  final Episode activeEpisode;
  final startedEpisodes = <(Episode, StreamResult?)>[];

  @override
  Future<void> loadEpisode(
    Episode episode, {
    StreamResult? selectedSource,
  }) async {
    startedEpisodes.add((episode, selectedSource));
  }

  @override
  PlayerState build() => PlayerState(
    activeEpisodeUrl: activeEpisode.url,
    uiPhase: const PlaybackUiPhase(kind: PlaybackUiPhaseKind.idle),
  );

  @override
  MultimediaItem get multimediaItem => item;
  @override
  Episode get currentEpisode => activeEpisode;

  @override
  bool get hasEpisodePicker => true;

  @override
  Future<double> getVolumeLevel() async => 0.5;
}

class _Settings extends PlayerSettingsNotifier {
  @override
  Future<PlayerSettings> build() async => const PlayerSettings();
}

class _Details extends DetailsController {
  int starts = 0;

  @override
  DetailsState build(String itemUrl) {
    starts++;
    return const DetailsState();
  }
}

class _Downloads extends DownloadsNotifier {
  int starts = 0;

  @override
  Future<List<DownloadItem>> build() async {
    starts++;
    return const [];
  }
}

class _Files extends DownloadedFiles {
  int checks = 0;
  final selected = <Episode?>[];
  final localSource = Completer<File?>();

  @override
  Future<void> checkFile(MultimediaItem item, {Episode? episode}) async {
    checks++;
  }

  @override
  Future<File?> resolveFile(
    MultimediaItem item, {
    Episode? episode,
    String? logicalId,
  }) {
    selected.add(episode);
    return localSource.future;
  }
}

class _History extends Fake implements HistoryRepository {
  int positions = 0;
  int durations = 0;

  @override
  int getEpisodePosition(
    String url, {
    String? mainUrl,
    int? season,
    int? episode,
  }) {
    positions++;
    return episode == 1 ? 25 : 0;
  }

  @override
  int getEpisodeDuration(
    String url, {
    String? mainUrl,
    int? season,
    int? episode,
  }) {
    durations++;
    return 100;
  }
}

class _Watched extends Fake implements EpisodeWatchRepository {
  int reads = 0;
  bool firstWatched = false;

  @override
  bool isWatched(String mainUrl, Episode episode) {
    reads++;
    return firstWatched && episode.season == 1 && episode.episode == 1;
  }
}

class _NavigationPlayer extends _Player {
  _NavigationPlayer(super.item, super.activeEpisode);

  Episode? _selected;
  Episode get _anchor => _selected ?? activeEpisode;

  @override
  Episode get currentEpisode => _anchor;

  @override
  String get currentEpisodeUrl => _anchor.url;

  @override
  bool get isSeries => true;

  // Preserve the normal controller contract while supplying a local route
  // fixture instead of needing to load a provider or decoder.
  @override
  Episode? get previousEpisode => adjacentEpisode(
    episodes: item.episodes,
    currentEpisode: currentEpisode,
    currentEpisodeUrl: currentEpisodeUrl,
    offset: -1,
  );

  @override
  Episode? get nextEpisode => adjacentEpisode(
    episodes: item.episodes,
    currentEpisode: currentEpisode,
    currentEpisodeUrl: currentEpisodeUrl,
    offset: 1,
  );

  @override
  Episode? get nextStoryEpisodeOrNull => nextStoryEpisode(
    episodes: item.episodes,
    currentEpisode: currentEpisode,
    currentEpisodeUrl: currentEpisodeUrl,
  );

  void showFillerPrompt() {
    state = state.copyWith(
      showNextEpisodeOverlay: true,
      nextEpisodeTitle: 'Next filler',
    );
  }

  void select(Episode episode) {
    _selected = episode;
    state = state.copyWith(activeEpisodeUrl: episode.url);
  }
}

void main() {
  testWidgets('player chrome refreshes neighbors and its filler prompt', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final messenger = tester.binding.defaultBinaryMessenger;
    for (final channel in const [
      MethodChannel('com.yosemiteyss.flutter_volume_controller/method'),
      MethodChannel('com.yosemiteyss.flutter_volume_controller/event'),
    ]) {
      messenger.setMockMethodCallHandler(channel, (_) async => null);
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    }

    final source = [
      for (var i = 0; i < 1200; i++)
        Episode(
          name: 'Story $i',
          url: 'local-nav:$i',
          episode: i,
          dubStatus: i.isEven ? DubStatus.subbed : DubStatus.dubbed,
          isFiller: i > 1000 && i < 1120,
        ),
    ];
    final show = MultimediaItem(
      title: 'Navigation fixture',
      url: 'local-navigation-fixture',
      posterUrl: '',
      contentType: MultimediaContentType.series,
      episodes: source,
    );
    final controller = _NavigationPlayer(show, source[1000]);
    final player = mk.Player(platformPlayer: _FixtureBackend());
    final history = _History();
    final watched = _Watched();
    final chromeVisibility = <bool>[];
    final controlsKey = GlobalKey<AnimeWitcherPlayerControlsState>();
    try {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            deviceProfileProvider.overrideWithValue(
              const AsyncData(DeviceProfile(isTv: true)),
            ),
            playerControllerProvider.overrideWith(() => controller),
            playerSettingsProvider.overrideWith(_Settings.new),
            detailsControllerProvider(show.url).overrideWith(_Details.new),
            downloadsProvider.overrideWith(_Downloads.new),
            downloadedFilesProvider.overrideWith(_Files.new),
            historyRepositoryProvider.overrideWithValue(history),
            episodeWatchRepositoryProvider.overrideWithValue(watched),
          ],
          child: MaterialApp(
            locale: const Locale('ar'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: AnimeWitcherPlayerControls(
                key: controlsKey,
                player: player,
                platformService: PlayerPlatformService(nativePip: false),
                onVisibilityChanged: chromeVisibility.add,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final l10n = AppLocalizations.of(controlsKey.currentContext!)!;
      expect(find.byTooltip('السابق'), findsOneWidget);
      expect(find.byTooltip(l10n.next), findsOneWidget);
      final initialDuration = player.state.duration;

      final priorChromeChanges = chromeVisibility.length;
      for (var i = 0; i < 12; i++) {
        await tester.tapAt(Offset(i.isEven ? 390 : 850, 330));
        await tester.pumpAndSettle();
      }
      expect(chromeVisibility.length - priorChromeChanges, 12);
      expect(chromeVisibility.last, isTrue);
      expect(player.state.duration, initialDuration);

      final prompt = find.byType(NextEpisodeOverlay);
      expect(prompt, findsNothing);
      controller.showFillerPrompt();
      await tester.pumpAndSettle();
      expect(prompt, findsOneWidget);
      final overlay = tester.widget<NextEpisodeOverlay>(prompt);
      expect(overlay.nextEpisodeIsFiller, isTrue);
      expect(overlay.skipFillerLabel, 'الحلقة 1120');
      controller.dismissNextEpisodeOverlay();
      await tester.pumpAndSettle();
      expect(prompt, findsNothing);
      controller.select(source[1198]);
      await tester.pumpAndSettle();
      expect(find.byTooltip('السابق'), findsOneWidget);
      expect(find.byTooltip(l10n.next), findsNothing);
      controller.select(source.first);
      await tester.pumpAndSettle();
      expect(find.byTooltip('السابق'), findsNothing);
      expect(find.byTooltip(l10n.next), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await player.dispose();
    }
    expect(tester.takeException(), isNull);
  });

  for (final anchorInViewport in [true, false]) {
    testWidgets(
      'player projects only laid-out drawer rows, anchor visible: $anchorInViewport',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 720);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final messenger = tester.binding.defaultBinaryMessenger;
        for (final channel in const [
          MethodChannel('com.yosemiteyss.flutter_volume_controller/method'),
          MethodChannel('com.yosemiteyss.flutter_volume_controller/event'),
        ]) {
          messenger.setMockMethodCallHandler(channel, (_) async => null);
          addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        }

        const showUrl = 'https://fixture.test/long-series';
        final show = MultimediaItem(
          title: 'Long series',
          url: showUrl,
          posterUrl: '',
          contentType: MultimediaContentType.anime,
          episodes: [
            for (var season = 1; season <= 3; season++)
              for (var episode = 1; episode <= 400; episode++)
                Episode(
                  name: 'Story $season-$episode',
                  url: '$showUrl/$season/$episode',
                  season: season,
                  episode: episode,
                ),
          ],
        );
        final history = _History();
        final watched = _Watched();
        final details = _Details();
        final downloads = _Downloads();
        final files = _Files();
        final controller = _Player(
          show,
          anchorInViewport ? show.episodes!.first : show.episodes!.last,
        );
        final player = mk.Player(platformPlayer: _FixtureBackend());
        final container = ProviderContainer(
          overrides: [
            deviceProfileProvider.overrideWithValue(
              const AsyncData(DeviceProfile(isTv: true)),
            ),
            playerControllerProvider.overrideWith(() => controller),
            playerSettingsProvider.overrideWith(_Settings.new),
            detailsControllerProvider(detailsControllerKey(show))
                .overrideWith(() => details),
            downloadsProvider.overrideWith(() => downloads),
            downloadedFilesProvider.overrideWith(() => files),
            historyRepositoryProvider.overrideWithValue(history),
            episodeWatchRepositoryProvider.overrideWithValue(watched),
          ],
        );
        addTearDown(container.dispose);
        final controlsKey = GlobalKey<AnimeWitcherPlayerControlsState>();
        final navigator = GlobalKey<NavigatorState>();
        final chromeVisibility = <bool>[];
        const open = Key('open-drawer-player-fixture');
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              navigatorKey: navigator,
              locale: const Locale('ar'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: TextButton(
                  key: open,
                  onPressed: () => navigator.currentState!.push(
                    MaterialPageRoute<void>(
                      builder: (_) => Scaffold(
                        body: AnimeWitcherPlayerControls(
                          key: controlsKey,
                          player: player,
                          platformService: PlayerPlatformService(
                            nativePip: false,
                          ),
                          onVisibilityChanged: chromeVisibility.add,
                          onBackPointer: () => navigator.currentState!.pop(),
                        ),
                      ),
                    ),
                  ),
                  child: const Text('Open fixture'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.byKey(open));
        await tester.pumpAndSettle();
        final panel = find.byType(PlayerEpisodesPanel);
        final shell = find.byType(PlayerSidePanel);
        final slide = find.descendant(
          of: shell,
          matching: find.byType(OverflowBox),
        );
        double slideWidth() => tester.getSize(slide).width;

        // The shell exists at width zero to keep the opening slide. The
        // never-opened drawer must not touch the catalog's panel providers or
        // project any history/download row before it is revealed.
        expect(shell, findsOneWidget);
        expect(slideWidth(), 0);
        expect(panel, findsNothing);
        expect(
          (
            details.starts,
            downloads.starts,
            files.checks,
            watched.reads,
            history.positions,
            history.durations,
          ),
          (0, 0, 0, 0, 0, 0),
        );

        // A tap over the closed drawer still reaches the player chrome.
        await tester.tapAt(const Offset(1050, 360));
        await tester.pumpAndSettle();
        expect(chromeVisibility.last, isFalse);
        // A different tap position avoids the player's double-tap gesture.
        await tester.tapAt(const Offset(1190, 360));
        await tester.pumpAndSettle();
        expect(chromeVisibility.last, isTrue);

        final beforeAccountRevision = watched.reads;
        container.read(accountDataRevisionProvider.notifier).bump();
        await tester.pump();
        expect(watched.reads, beforeAccountRevision);
        expect(details.starts, 0);
        expect(downloads.starts, 0);
        expect(files.checks, 0);

        final l10n = AppLocalizations.of(controlsKey.currentContext!)!;
        final beforeOpen = watched.reads;
        await tester.tap(find.byTooltip(l10n.episodes));
        await tester.pump();
        expect(panel, findsOneWidget);
        final openingElement = tester.element(panel);
        expect(slideWidth(), 0);
        await tester.pump(const Duration(milliseconds: 80));
        expect(slideWidth(), inExclusiveRange(0, 437.5));
        await tester.pumpAndSettle();
        expect(slideWidth(), 437.5);
        expect(
          container.read(playerControllerProvider).showEpisodeList,
          isTrue,
        );
        expect(details.starts, 1);
        expect(downloads.starts, 1);
        expect(files.checks, greaterThan(0));
        expect(panel, findsOneWidget);
        expect(find.text(l10n.seasonWithNumber(1)), findsOneWidget);
        expect(find.text('Story 1-1'), findsOneWidget);
        expect(find.text('Story 1-2'), findsOneWidget);
        expect(find.text('Story 3-400'), findsNothing);
        expect(watched.reads - beforeOpen, inInclusiveRange(1, 80));
        expect(history.positions, watched.reads);
        expect(history.durations, watched.reads);
        expect(
          FocusManager.instance.primaryFocus?.debugLabel,
          anchorInViewport
              ? 'episodes_panel_anchor'
              : isNot('episodes_panel_anchor'),
        );
        final currentProgress = find.byWidgetPredicate(
          (widget) => widget is LinearProgressIndicator && widget.value == .25,
        );
        expect(currentProgress, findsOneWidget);

        // Focus still traverses within the open drawer. Watch/history updates are
        // visible in the row instead of requiring a close/reopen.
        if (anchorInViewport) {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
          await tester.pumpAndSettle();
          expect(
            FocusManager.instance.primaryFocus?.debugLabel,
            isNot('episodes_panel_anchor'),
          );
        }
        final beforeRevision = watched.reads;
        watched.firstWatched = true;
        container.read(episodeWatchRevisionProvider.notifier).bump();
        await tester.pumpAndSettle();
        expect(currentProgress, findsNothing);
        expect(
          find.byWidgetPredicate(
            (widget) => widget is LinearProgressIndicator && widget.value == 1,
          ),
          findsOneWidget,
        );
        expect(watched.reads - beforeRevision, inInclusiveRange(1, 40));

        // Scrolling eagerly projected every off-screen row before; it now creates
        // the actual entering rows on demand. The same close/reopen focus path
        // retains the already rendered list and returns to the current episode.
        final list = find.descendant(
          of: find.byType(PlayerEpisodesPanel),
          matching: find.byType(ListView),
        );
        final scroll = find.descendant(
          of: list,
          matching: find.byType(Scrollable),
        );
        double scrollOffset() =>
            tester.state<ScrollableState>(scroll).position.pixels;
        await tester.drag(list, const Offset(0, -250));
        await tester.pumpAndSettle();
        final previousOffset = scrollOffset();
        expect(previousOffset, greaterThan(0));
        final close = MaterialLocalizations.of(controlsKey.currentContext!)
            .closeButtonTooltip;
        await tester.tap(find.byTooltip(close));
        await tester.pumpAndSettle();
        expect(
          container.read(playerControllerProvider).showEpisodeList,
          isFalse,
        );
        await tester.tap(find.byTooltip(l10n.episodes));
        await tester.pumpAndSettle();
        expect(
          container.read(playerControllerProvider).showEpisodeList,
          isTrue,
        );
        expect(
          FocusManager.instance.primaryFocus?.debugLabel,
          anchorInViewport
              ? 'episodes_panel_anchor'
              : isNot('episodes_panel_anchor'),
        );
        // Without a mounted anchor, retain the scroll position on reopening.
        if (!anchorInViewport) expect(scrollOffset(), previousOffset);
        expect(tester.element(panel), same(openingElement));

        if (anchorInViewport) {
          final next = show.episodes![1];
          await tester.tap(find.text(next.name));
          await tester.pumpAndSettle();
          expect(
            container.read(playerControllerProvider).showEpisodeList,
            isFalse,
          );
          expect(tester.element(panel), same(openingElement));
          expect(files.selected, [next]);
          expect(controller.startedEpisodes, isEmpty);
          // The actual playback launcher finishes a local source only after
          // the side panel has closed. It must still use this row's episode.
          files.localSource.complete(File('/fixture/c15-local-episode.mp4'));
          await tester.pumpAndSettle();
          expect(controller.startedEpisodes.single.$1, same(next));
          expect(controller.startedEpisodes.single.$2?.source, 'محلي');
        } else {
          controlsKey.currentState!.closeActivePanel();
          await tester.pumpAndSettle();
        }
        expect(chromeVisibility.last, isTrue);
        await tester.tap(find.byType(AppBackButton).hitTestable());
        await tester.pumpAndSettle();
        expect(find.byKey(open), findsOneWidget);
        expect(shell, findsNothing);
        expect(openingElement.mounted, isFalse);
        expect(
          FocusManager.instance.primaryFocus?.debugLabel,
          isNot('episodes_panel_anchor'),
        );

        await tester.pumpWidget(const SizedBox.shrink());
        await player.dispose();
        expect(tester.takeException(), isNull);
      },
    );
  }
}
