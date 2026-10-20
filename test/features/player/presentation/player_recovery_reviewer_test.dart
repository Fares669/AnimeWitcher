import 'dart:async';
import 'dart:io';

import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_service.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/providers/anime_data_source_settings_provider.dart';
import 'package:animewitcher/core/storage/history_repository.dart';
import 'package:animewitcher/core/storage/settings_repository.dart';
import 'package:animewitcher/features/details/presentation/downloaded_file_provider.dart';
import 'package:animewitcher/features/library/presentation/history_provider.dart';
import 'package:animewitcher/features/player/presentation/player_controller_base.dart';
import 'package:animewitcher/features/settings/presentation/player_settings_provider.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart' as media;

class _Player extends Fake implements media.Player {
  final positions = StreamController<Duration>.broadcast(sync: true);
  final durations = StreamController<Duration>.broadcast(sync: true);
  final errors = StreamController<String>.broadcast(sync: true);
  final buffers = StreamController<bool>.broadcast(sync: true);
  bool seekThrows = false;
  bool emitDurationDuringOpen = false;
  final opened = <String>[];
  Completer<void>? pendingPause;
  Completer<void>? pendingOpen;
  _ReadinessNative? native;
  final seeks = <Duration>[];
  final openEnteredSignal = Completer<void>();
  final openedSignal = Completer<void>();
  final seekSignal = Completer<void>();
  bool settleSeek = true;
  media.PlayerState value = const media.PlayerState();

  @override
  media.PlayerState get state => value;
  @override
  media.PlayerStream get stream => _Streams(
    positions.stream,
    durations.stream,
    errors.stream,
    buffers.stream,
  );
  @override
  media.PlatformPlayer? get platform => native;
  @override
  Future<void> open(media.Playable playable, {bool play = true}) async {
    opened.add((playable as media.Media).uri);
    await native?.open(playable, play: play);
    if (!openEnteredSignal.isCompleted) openEnteredSignal.complete();
    await pendingOpen?.future;
    value = value.copyWith(position: Duration.zero, playing: play);
    if (emitDurationDuringOpen) durations.add(value.duration);
    if (!openedSignal.isCompleted) openedSignal.complete();
  }

  @override
  Future<void> pause() async {
    await native?.pause();
    await pendingPause?.future;
    value = value.copyWith(playing: false);
  }

  @override
  Future<void> play() async {
    await native?.play();
    value = value.copyWith(playing: true);
  }

  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
    if (seekThrows) throw StateError("Seek unavailable");
    if (settleSeek) advance(position);
    if (!seekSignal.isCompleted) seekSignal.complete();
  }

  void advance(Duration position) {
    value = value.copyWith(position: position);
    positions.add(position);
  }

  Future<void> close() async {
    await positions.close();
    await durations.close();
    await errors.close();
    await buffers.close();
  }
}

// The native dependency acquires a shared lock before waiting for its renderer.
// Property calls here are no-ops so startup cannot rely on their incidental gate.
class _ReadinessNative extends Fake implements media.NativePlayer {
  final renderer = Completer<void>();
  final readinessReached = Completer<void>();
  final firstPropertyWrite = Completer<void>();
  bool openEntered = false;
  bool pauseEntered = false;
  bool playEntered = false;
  int propertyWrites = 0;
  final properties = <String, String>{};
  Completer<void>? pendingProperties;

  @override
  Future<void> get waitForPlayerInitialization {
    _reachedReadiness();
    return Future.value();
  }

  void _reachedReadiness() {
    if (!readinessReached.isCompleted) readinessReached.complete();
  }

  @override
  Future<void> get waitForVideoControllerInitializationIfAttached =>
      renderer.future;
  @override
  Future<void> setProperty(
    String property,
    String value, {
    bool waitForInitialization = true,
  }) async {
    propertyWrites++;
    properties[property] = value;
    if (!firstPropertyWrite.isCompleted) firstPropertyWrite.complete();
    await pendingProperties?.future;
  }

  @override
  Future<void> open(
    media.Playable playable, {
    bool play = true,
    bool synchronized = true,
  }) => media.NativePlayer.lock.synchronized(() async {
    openEntered = true;
    _reachedReadiness();
    await renderer.future;
  });

  @override
  Future<void> pause({bool synchronized = true}) =>
      media.NativePlayer.lock.synchronized(() async {
        pauseEntered = true;
        _reachedReadiness();
        await renderer.future;
      });

  @override
  Future<void> play({bool synchronized = true}) =>
      media.NativePlayer.lock.synchronized(() async {
        playEntered = true;
        _reachedReadiness();
        await renderer.future;
      });
}

class _Streams extends Fake implements media.PlayerStream {
  _Streams(this.position, this.duration, this.error, this.buffering);
  @override
  final Stream<Duration> position;
  @override
  final Stream<Duration> duration;
  @override
  Stream<bool> get playing => const Stream.empty();
  @override
  Stream<bool> get completed => const Stream.empty();
  @override
  final Stream<bool> buffering;
  @override
  Stream<double> get rate => const Stream.empty();
  @override
  final Stream<String> error;
  @override
  Stream<media.PlayerLog> get log => const Stream.empty();
  @override
  Stream<media.Track> get track => const Stream.empty();
}

class _Catalog extends AnimeWitcherProvider {
  final episodes = <Completer<List<Episode>>>[];
  final artwork = <Completer<List<Episode>>>[];
  int detailCalls = 0;
  int scheduleCalls = 0;
  int streamCalls = 0;
  Completer<List<StreamResult>>? pendingStreams;
  @override
  String get packageName => 'test.catalog';
  @override
  String get name => 'Test catalog';
  @override
  String get mainUrl => 'https://example.test';
  @override
  String get version => '1';
  @override
  List<String> get languages => const ['ar'];
  @override
  Set<ProviderType> get supportedTypes => const {ProviderType.anime};
  @override
  Future<Map<String, List<MultimediaItem>>> getHome() async => const {};
  @override
  Future<List<MultimediaItem>> search(
    String query, {
    CancelToken? cancelToken,
  }) async => const [];
  @override
  Future<MultimediaItem> getDetails(String url) {
    detailCalls++;
    return Completer<MultimediaItem>().future;
  }

  @override
  Future<NextAiring?> getNextAiring(String url) {
    scheduleCalls++;
    return Completer<NextAiring?>().future;
  }

  @override
  Future<List<StreamResult>> loadStreams(String url) {
    streamCalls++;
    return pendingStreams?.future ??
        Future.error(StateError('Local playback must not resolve sources'));
  }

  @override
  Future<List<Episode>> getEpisodes(String url) {
    final request = Completer<List<Episode>>();
    episodes.add(request);
    return request.future;
  }

  @override
  Future<List<Episode>> getEpisodeMetadata(String url) {
    final request = Completer<List<Episode>>();
    artwork.add(request);
    return request.future;
  }
}

class _Extensions extends ExtensionManager {
  _Extensions(this.catalog);
  final _Catalog catalog;
  @override
  List<AnimeWitcherProvider> build() => [catalog];
}

class _Settings extends PlayerSettingsNotifier {
  @override
  Future<PlayerSettings> build() async => const PlayerSettings();
}

class _ArtworkSettings extends AnimeDataSourceSettingsNotifier {
  @override
  AnimeDataSourceSettings build() => const AnimeDataSourceSettings();
}

class _SettingsRepository extends Fake implements SettingsRepository {
  @override
  T? getPlayerSetting<T>(String key, {T? defaultValue}) =>
      key == 'player_skip_segments' ? false as T : defaultValue;
}

class _HistoryRepository extends Fake implements HistoryRepository {
  int position = 0;
  @override
  int getEpisodePosition(
    String url, {
    String? mainUrl,
    int? season,
    int? episode,
  }) => position;
  @override
  int getPosition(String url) => position;
}

class _Account extends Fake implements AnimeWitcherAccountService {
  final pending = Completer<void>();
  int calls = 0;
  @override
  Future<void> syncContinueWatchingItem(String mainUrl) {
    calls++;
    return pending.future;
  }

  @override
  Future<int> remoteEpisodePosition({
    required String mainUrl,
    required String episodeUrl,
    bool refresh = false,
  }) async => 90000;
}

class _History extends WatchHistory {
  @override
  List<HistoryItem> build() => const [];
  @override
  Future<void> recordOpened(
    MultimediaItem item, {
    String? lastEpisodeUrl,
    int? season,
    int? episode,
    String? episodeTitle,
    String? episodeServerName,
    String? episodeServerNumber,
    String? episodePosterUrl,
  }) async {}
}

class _ContinueWatching extends ContinueWatchingNotifier {
  @override
  List<HistoryItem> build() => const [];
  @override
  Future<void> saveProgress(
    MultimediaItem item,
    int position,
    int duration, {
    String? lastStreamUrl,
    String? lastEpisodeUrl,
    int? season,
    int? episode,
    String? episodeTitle,
    String? episodeServerName,
    String? episodeServerNumber,
    String? episodePosterUrl,
  }) async {}
}

class _Files extends DownloadedFiles {
  @override
  Map<String, File?> build() => const {};
  @override
  Future<File?> resolveFile(
    MultimediaItem item, {
    Episode? episode,
    String? logicalId,
  }) async => null;
}

Episode _episode(
  int number, {
  String? url,
  String? poster,
  DubStatus dubStatus = DubStatus.none,
}) => Episode(
  name: 'Episode $number',
  url: url ?? 'episode-$number',
  season: 1,
  episode: number,
  posterUrl: poster,
  dubStatus: dubStatus,
);
MultimediaItem _item(
  List<Episode> episodes, {
  String url = 'anime-a',
  MultimediaContentType type = MultimediaContentType.anime,
}) => MultimediaItem(
  title: 'Saved show',
  url: url,
  posterUrl: '',
  contentType: type,
  provider: 'test.catalog',
  episodes: episodes,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory testDirectory;
  setUpAll(() async {
    testDirectory = await Directory.systemTemp.createTemp('player-startup-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => call.method == 'getApplicationSupportDirectory'
              ? testDirectory.path
              : '/nonexistent/player-tests',
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dev.fluttercommunity.plus/connectivity_status'),
          (_) async => null,
        );
  });
  tearDownAll(() async {
    await testDirectory.delete(recursive: true);
  });

  late ProviderContainer container;
  late PlayerController controller;
  late _Catalog catalog;
  late _Player player;
  late _Account account;
  late _HistoryRepository history;
  final additionalPlayers = <_Player>[];
  int connectivityChecks = 0;
  Completer<List<String>>? pendingConnectivity;

  setUp(() async {
    connectivityChecks = 0;
    pendingConnectivity = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dev.fluttercommunity.plus/connectivity'),
          (call) async {
            if (call.method != 'check') return null;
            connectivityChecks++;
            return pendingConnectivity?.future ?? <String>['wifi'];
          },
        );
    catalog = _Catalog();
    player = _Player();
    account = _Account();
    history = _HistoryRepository();
    container = ProviderContainer(
      overrides: [
        extensionManagerProvider.overrideWith(() => _Extensions(catalog)),
        activeProviderProvider.overrideWithValue(catalog),
        playerSettingsProvider.overrideWith(_Settings.new),
        animeDataSourceSettingsProvider.overrideWith(_ArtworkSettings.new),
        settingsRepositoryProvider.overrideWithValue(_SettingsRepository()),
        historyRepositoryProvider.overrideWithValue(history),
        animeWitcherAccountServiceProvider.overrideWithValue(account),
        watchHistoryProvider.overrideWith(_History.new),
        continueWatchingProvider.overrideWith(_ContinueWatching.new),
        downloadedFilesProvider.overrideWith(_Files.new),
      ],
    );
    await container.read(playerSettingsProvider.future);
    controller = container.read(playerControllerProvider.notifier);
  });
  tearDown(() async {
    container.dispose();
    if (!account.pending.isCompleted) account.pending.complete();
    for (final request in [...catalog.episodes, ...catalog.artwork]) {
      if (!request.isCompleted) request.complete(const []);
    }
    await Future<void>.delayed(Duration.zero);
    await player.close();
    for (final extra in additionalPlayers) {
      await extra.close();
    }
    additionalPlayers.clear();
  });

  Future<void> flush() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> startSource({bool local = false, bool live = false}) async {
    final episode = _episode(1);
    final url = local
        ? '/saved/episode.mp4'
        : 'https://video.test/original.mp4';
    await controller.init(
      player: player,
      item: _item([episode, _episode(2)]),
      videoUrl: url,
      episode: episode,
      selectedSource: local
          ? null
          : StreamResult(
              url: url,
              source: 'Selected',
              refreshUrl: live ? null : 'https://video.test/refresh',
            ),
    );
    player.advance(const Duration(seconds: 5));
    await flush();
  }

  for (final background in [false, true]) {
    test(
      'reviewer: ${background ? "background" : "pause"} during connectivity prevents reopen and resume',
      () async {
        await startSource(live: true);
        player.value = player.value.copyWith(
          duration: const Duration(minutes: 24),
        );
        player.advance(const Duration(seconds: 90));
        pendingConnectivity = Completer<List<String>>();
        player.errors.add('Network stalled');
        await Future<void>.delayed(const Duration(milliseconds: 2100));
        expect(connectivityChecks, 1);
        if (background) controller.setAppBackgrounded(true);
        await controller.pause(onlyWhileBackgrounded: background);
        pendingConnectivity!.complete(<String>['wifi']);
        await flush();
        expect(player.opened, hasLength(1));
        expect(player.state.playing, isFalse);
        expect(player.state.position, const Duration(seconds: 90));
        if (background) controller.setAppBackgrounded(false);
        await controller.play();
        await flush();
        expect(
          player.opened,
          hasLength(2),
          reason: 'Cancelled attempt must release its lock so explicit play can recover',
        );
        expect(player.state.position, const Duration(seconds: 90));
        expect(player.state.playing, isTrue);
      },
    );
  }

  for (final emitDuration in [false, true]) {
    test(
      'reviewer: fallback restoration does not trigger nested refresh, duration race=$emitDuration',
      () async {
        await startSource();
        player.value = player.value.copyWith(
          duration: const Duration(minutes: 24),
        );
        player.advance(const Duration(seconds: 90));
        final fallback = StreamResult(
          url: 'https://video.test/fallback.mp4',
          source: 'Fallback',
          refreshUrl: 'https://video.test/fallback-refresh',
        );
        // Seed the source list without external health checks; source loading and recovery remain real.
        // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
        controller.state = controller.currentState.copyWith(
          streams: [controller.currentState.currentStream!, fallback],
        );
        player.emitDurationDuringOpen = emitDuration;
        catalog.pendingStreams = Completer<List<StreamResult>>();
        player.errors.add('Network stalled');
        await Future<void>.delayed(const Duration(milliseconds: 2100));
        expect(catalog.streamCalls, 1);
        catalog.pendingStreams!.completeError(StateError('HTTP 401 expired'));
        await flush();
        expect(player.opened, [
          'https://video.test/original.mp4',
          'https://video.test/fallback.mp4',
        ]);
        expect(
          catalog.streamCalls,
          1,
          reason: 'A restored fallback must play without refreshing again',
        );
        expect(player.state.position, const Duration(seconds: 90));
        expect(player.state.playing, isTrue);
        expect(controller.currentState.currentStream?.url, fallback.url);
      },
    );
  }

  test(
    'reviewer: next episode clears the pause marker and can recover',
    () async {
      await startSource(live: true);
      await controller.playNextEpisode(
        selectedSource: StreamResult(
          url: 'https://video.test/episode-2.mp4',
          source: 'Selected',
        ),
      );
      player.value = player.value.copyWith(
        duration: const Duration(minutes: 24),
      );
      player.advance(const Duration(seconds: 90));
      await flush();
      expect(player.state.playing, isTrue);
      player.errors.add('Network stalled on next episode');
      await Future<void>.delayed(const Duration(milliseconds: 2100));
      await flush();
      expect(
        connectivityChecks,
        1,
        reason: 'Internal transition pause must not block new episode recovery',
      );
      expect(player.opened, hasLength(3));
    },
  );

  test('reviewer: duration-owned failed fallback seek stays paused and fails over once', () async {
    await startSource();
    player.value = player.value.copyWith(duration: const Duration(minutes: 24));
    player.advance(const Duration(seconds: 90));
    final fallback = StreamResult(
      url: 'https://video.test/fallback.mp4',
      source: 'Fallback',
    );
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    controller.state = controller.currentState.copyWith(
      streams: [controller.currentState.currentStream!, fallback],
    );
    player.emitDurationDuringOpen = true;
    player.seekThrows = true;
    catalog.pendingStreams = Completer<List<StreamResult>>();
    player.errors.add('Network stalled');
    await Future<void>.delayed(const Duration(milliseconds: 2100));
    catalog.pendingStreams!.completeError(StateError('HTTP 401 expired'));
    await flush();
    expect(player.opened, hasLength(2));
    expect(player.seeks, [const Duration(seconds: 90)]);
    expect(player.state.position, Duration.zero);
    expect(player.state.playing, isFalse);
    expect(controller.currentState.uiPhase.kind.name, 'error');
    expect(controller.currentState.sourceAttempts.first.status.name, 'failed');
  });

  test(
    'reviewer: repeated restore failure is bounded and never plays zero',
    () async {
      await startSource(live: true);
      player.value = player.value.copyWith(
        duration: const Duration(minutes: 24),
      );
      player.advance(const Duration(seconds: 90));
      player.seekThrows = true;
      player.errors.add('Network stalled');
      await Future<void>.delayed(const Duration(milliseconds: 8300));
      await flush();
      expect(connectivityChecks, 3);
      expect(player.opened, hasLength(4));
      expect(player.seeks, List.filled(3, const Duration(seconds: 90)));
      expect(player.state.playing, isFalse);
      expect(player.state.position, Duration.zero);
      expect(controller.currentState.uiPhase.kind.name, 'error');
    },
  );

  test('reviewer: explicit play failed refresh uses bounded retries rather than holding forever', () async {
    await startSource(live: true);
    player.value = player.value.copyWith(duration: const Duration(minutes: 24));
    player.advance(const Duration(seconds: 90));
    pendingConnectivity = Completer<List<String>>();
    player.errors.add('Network stalled');
    await Future<void>.delayed(const Duration(milliseconds: 2100));
    pendingConnectivity!.complete(<String>['none']);
    await flush();
    expect(connectivityChecks, 1);
    expect(player.opened, hasLength(1));
    pendingConnectivity = null;
    player.seekThrows = true;
    await controller.play();
    await Future<void>.delayed(const Duration(milliseconds: 6300));
    await flush();
    expect(
      connectivityChecks,
      4,
      reason: 'Offline check plus exactly three failed restore attempts',
    );
    expect(player.opened, hasLength(4));
    expect(player.seeks, List.filled(3, const Duration(seconds: 90)));
    expect(player.state.playing, isFalse);
    expect(player.state.position, Duration.zero);
    expect(controller.currentState.uiPhase.kind.name, 'error');
  });

  for (final lifecyclePause in [false, true]) {
    test(
      'reviewer: foreground resumes a recovery held before background, lifecycle pause=$lifecyclePause',
      () async {
        await startSource(live: true);
        player.value = player.value.copyWith(
          duration: const Duration(minutes: 24),
        );
        player.advance(const Duration(seconds: 90));
        final pendingPause = Completer<void>();
        player.pendingPause = pendingPause;
        player.errors.add('Network stalled');
        await Future<void>.delayed(const Duration(milliseconds: 2100));
        await flush();
        expect(player.opened, hasLength(2));
        expect(
          player.state.playing,
          isFalse,
          reason: 'Recovery opened held, so screen records it was not playing',
        );
        controller.setAppBackgrounded(true);
        final backgroundPause = lifecyclePause
            ? controller.pause(onlyWhileBackgrounded: true)
            : Future<void>.value();
        await flush();
        pendingPause.complete();
        await backgroundPause;
        await flush();
        player.pendingPause = null;
        expect(player.state.playing, isFalse);
        controller.setAppBackgrounded(false);
        // Match PlayerScreen: wasPlayingBeforeBackground was false, so no explicit play call here.
        await flush();
        expect(player.opened, hasLength(3));
        expect(player.state.playing, isTrue);
        expect(player.state.position, const Duration(seconds: 90));
      },
    );
  }

  test(
    'reviewer: pausing a fallback restore does not mark source failed',
    () async {
      await startSource();
      player.value = player.value.copyWith(
        duration: const Duration(minutes: 24),
      );
      player.advance(const Duration(seconds: 90));
      final fallback = StreamResult(
        url: 'https://video.test/fallback.mp4',
        source: 'Fallback',
      );
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      controller.state = controller.currentState.copyWith(
        streams: [controller.currentState.currentStream!, fallback],
      );
      final pendingPause = Completer<void>();
      player.pendingPause = pendingPause;
      catalog.pendingStreams = Completer<List<StreamResult>>();
      player.errors.add('Network stalled');
      await Future<void>.delayed(const Duration(milliseconds: 2100));
      catalog.pendingStreams!.completeError(StateError('HTTP 401 expired'));
      await flush();
      expect(player.opened, hasLength(2));
      final userPause = controller.pause();
      await flush();
      pendingPause.complete();
      await userPause;
      await flush();
      expect(player.state.playing, isFalse);
      expect(controller.currentState.uiPhase.kind.name, isNot('error'));
      expect(player.opened, hasLength(2));
      player.pendingPause = null;
      await controller.play();
      await flush();
      expect(player.opened, hasLength(3));
      expect(player.state.playing, isTrue);
      expect(player.state.position, const Duration(seconds: 90));
    },
  );
}
