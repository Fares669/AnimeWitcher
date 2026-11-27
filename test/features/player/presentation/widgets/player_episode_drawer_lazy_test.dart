import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/providers/device_info_provider.dart';
import 'package:animewitcher/core/storage/episode_watch_repository.dart';
import 'package:animewitcher/core/storage/history_repository.dart';
import 'package:animewitcher/features/details/presentation/details_controller.dart';
import 'package:animewitcher/features/details/presentation/downloaded_file_provider.dart';
import 'package:animewitcher/features/library/presentation/downloads_provider.dart';
import 'package:animewitcher/features/player/presentation/player_controller.dart';
import 'package:animewitcher/features/player/presentation/player_platform_service.dart';
import 'package:animewitcher/features/player/presentation/widgets/animewitcher_player_controls.dart';
import 'package:animewitcher/features/player/presentation/widgets/player_side_panel.dart';
import 'package:animewitcher/features/settings/presentation/player_settings_provider.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
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
  @override
  DetailsState build(String itemUrl) => const DetailsState();
}

class _Downloads extends DownloadsNotifier {
  @override
  Future<List<DownloadItem>> build() async => const [];
}

class _Files extends DownloadedFiles {
  @override
  Future<void> checkFile(MultimediaItem item, {Episode? episode}) async {}
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

void main() {
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
        final player = mk.Player(platformPlayer: _FixtureBackend());
        final container = ProviderContainer(
          overrides: [
            deviceProfileProvider.overrideWithValue(
              const AsyncData(DeviceProfile(isTv: true)),
            ),
            playerControllerProvider.overrideWith(
              () => _Player(
                show,
                anchorInViewport ? show.episodes!.first : show.episodes!.last,
              ),
            ),
            playerSettingsProvider.overrideWith(_Settings.new),
            detailsControllerProvider(showUrl).overrideWith(_Details.new),
            downloadsProvider.overrideWith(_Downloads.new),
            downloadedFilesProvider.overrideWith(_Files.new),
            historyRepositoryProvider.overrideWithValue(history),
            episodeWatchRepositoryProvider.overrideWithValue(watched),
          ],
        );
        addTearDown(container.dispose);
        final controlsKey = GlobalKey<AnimeWitcherPlayerControlsState>();
        final chromeVisibility = <bool>[];
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
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

        // The drawer remains mounted for a responsive opening animation and
        // focus, but should not project the whole catalogue while closed.
        expect(watched.reads, inInclusiveRange(1, 80));
        expect(history.positions, watched.reads);
        expect(history.durations, watched.reads);
        expect(find.byType(PlayerEpisodesPanel), findsOneWidget);

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
        expect(watched.reads - beforeAccountRevision, inInclusiveRange(1, 40));

        final l10n = AppLocalizations.of(controlsKey.currentContext!)!;
        final beforeOpen = watched.reads;
        await tester.tap(find.byTooltip(l10n.episodes));
        await tester.pumpAndSettle();
        expect(
          container.read(playerControllerProvider).showEpisodeList,
          isTrue,
        );
        expect(find.byType(PlayerEpisodesPanel), findsOneWidget);
        expect(find.text(l10n.seasonWithNumber(1)), findsOneWidget);
        expect(find.text('Story 1-1'), findsOneWidget);
        expect(find.text('Story 1-2'), findsOneWidget);
        expect(find.text('Story 3-400'), findsNothing);
        expect(watched.reads - beforeOpen, inInclusiveRange(1, 40));
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

        await tester.pumpWidget(const SizedBox.shrink());
        await player.dispose();
        expect(tester.takeException(), isNull);
      },
    );
  }
}
