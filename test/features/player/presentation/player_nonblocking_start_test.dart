import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_service.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/logger/app_diagnostics.dart';
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
  media.PlayerStream get stream =>
      _Streams(positions.stream, durations.stream, errors.stream);
  @override
  media.PlatformPlayer? get platform => native;
  @override
  Future<void> open(media.Playable playable, {bool play = true}) async {
    opened.add((playable as media.Media).uri);
    await native?.open(playable, play: play);
    if (!openEnteredSignal.isCompleted) openEnteredSignal.complete();
    await pendingOpen?.future;
    value = value.copyWith(position: Duration.zero, playing: play);
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
  _Streams(this.position, this.duration, this.error);
  @override
  final Stream<Duration> position;
  @override
  final Stream<Duration> duration;
  @override
  Stream<bool> get playing => const Stream.empty();
  @override
  Stream<bool> get completed => const Stream.empty();
  @override
  Stream<bool> get buffering => const Stream.empty();
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
  }) async => File('/saved/${episode!.url}.mp4');
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
  late Directory diagnosticsDirectory;
  setUpAll(() async {
    diagnosticsDirectory = await Directory.systemTemp.createTemp(
      'player-diagnostics-',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => call.method == 'getApplicationSupportDirectory'
              ? diagnosticsDirectory.path
              : '/nonexistent/player-tests',
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dev.fluttercommunity.plus/connectivity_status'),
          (_) async => null,
        );
  });
  tearDownAll(() async {
    await appDiagnostics.setEnabled(false);
    await appDiagnostics.flush();
    await diagnosticsDirectory.delete(recursive: true);
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

  var diagnosticBaseline = 0;

  Future<List<Map<String, dynamic>>> diagnosticEvents() async {
    await appDiagnostics.flush();
    final events = <Map<String, dynamic>>[];
    for (final file in await appDiagnostics.listFiles()) {
      for (final line in await file.readAsLines()) {
        if (line.isNotEmpty) {
          events.add(jsonDecode(line) as Map<String, dynamic>);
        }
      }
    }
    return events.skip(diagnosticBaseline).toList();
  }

  setUp(() async {
    await appDiagnostics.setEnabled(false);
    await appDiagnostics.flush();
    diagnosticBaseline = 0;
    diagnosticBaseline = (await diagnosticEvents()).length;
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
    final url = local ? '/saved/episode.mp4' : 'https://video.test/original.mp4';
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

  Future<_Player> replaceRoute({bool live = false}) async {
    controller.disposeController(player: player);
    final replacement = _Player();
    additionalPlayers.add(replacement);
    final episode = _episode(4);
    final url = live ? 'https://video.test/new.m3u8' : '/saved/replacement.mp4';
    await controller.init(
      player: replacement,
      item: _item(
        [episode],
        url: 'anime-b',
        type: live
            ? MultimediaContentType.livestream
            : MultimediaContentType.anime,
      ),
      videoUrl: url,
      episode: episode,
      selectedSource: live ? StreamResult(url: url, source: 'Live') : null,
    );
    replacement.advance(const Duration(seconds: 5));
    await flush();
    return replacement;
  }

  Future<Completer<void>> pageEntryGate(WidgetTester tester) async {
    // Real IO continuations must not wait on fake-zone microtasks after expiry.
    final gate = (await tester.runAsync(() async => Completer<void>()))!;
    Timer(const Duration(milliseconds: 500), gate.complete);
    return gate;
  }

  Future<({Future<void> done})> prepareEntry(
    WidgetTester tester, {
    required Future<void> localPlaybackReady,
    String url = '/saved/entry.mp4',
    _Player? target,
    _ReadinessNative? native,
  }) async {
    final activePlayer = target ?? player;
    late Future<void> startup;
    await tester.runAsync(() async {
      final activeNative = native ?? (_ReadinessNative()..renderer.complete());
      activePlayer.native = activeNative;
      final episode = _episode(1);
      startup = controller.init(
        player: activePlayer,
        item: _item([episode, _episode(2)]),
        videoUrl: url,
        episode: episode,
        selectedSource: StreamResult(url: url, source: 'Selected'),
        localPlaybackReady: localPlaybackReady,
      );
      await activeNative.readinessReached.future;
    });
    return (done: startup);
  }

  testWidgets('local engine waits until 500 ms from page entry', (
    tester,
  ) async {
    final ready = (await pageEntryGate(tester)).future;
    await tester.pump(const Duration(milliseconds: 200));
    final entry = await prepareEntry(tester, localPlaybackReady: ready);
    expect(player.opened, isEmpty);
    expect(player.state.playing, isFalse);
    await tester.pump(const Duration(milliseconds: 299));
    expect(player.opened, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.runAsync(() => entry.done);
    expect(player.opened, ['/saved/entry.mp4']);
  });

  testWidgets('remote engine does not wait for the local entry deadline', (
    tester,
  ) async {
    final ready = (await pageEntryGate(tester)).future;
    final entry = await prepareEntry(
      tester,
      localPlaybackReady: ready,
      url: 'https://video.test/entry.mp4',
    );
    await tester.runAsync(() => entry.done);
    expect(player.opened, ['https://video.test/entry.mp4']);
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('slow local preparation does not add another 500 ms', (
    tester,
  ) async {
    final ready = (await pageEntryGate(tester)).future;
    final native = (await tester.runAsync(() async => _ReadinessNative()))!;
    final entry = await prepareEntry(
      tester,
      localPlaybackReady: ready,
      native: native,
    );
    await tester.pump(const Duration(milliseconds: 700));
    expect(player.opened, isEmpty);
    await tester.runAsync(() async {
      native.renderer.complete();
      await entry.done;
    });
    expect(player.opened, ['/saved/entry.mp4']);
  });

  testWidgets('leaving before the local deadline prevents engine open', (
    tester,
  ) async {
    final ready = (await pageEntryGate(tester)).future;
    final entry = await prepareEntry(tester, localPlaybackReady: ready);
    await tester.runAsync(
      () async => controller.disposeController(player: player),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.runAsync(() => entry.done);
    expect(player.opened, isEmpty);
  });

  testWidgets(
    'replacement route gets its own deadline and abandons the old open',
    (tester) async {
      final oldReady = (await pageEntryGate(tester)).future;
      final oldEntry = await prepareEntry(tester, localPlaybackReady: oldReady);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.runAsync(
        () async => controller.disposeController(player: player),
      );
      final replacement = (await tester.runAsync(() async => _Player()))!;
      additionalPlayers.add(replacement);
      final ready = (await pageEntryGate(tester)).future;
      final entry = await prepareEntry(
        tester,
        localPlaybackReady: ready,
        target: replacement,
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.runAsync(() => oldEntry.done);
      expect(player.opened, isEmpty);
      expect(replacement.opened, isEmpty);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.runAsync(() => entry.done);
      expect(player.opened, isEmpty);
      expect(replacement.opened, ['/saved/entry.mp4']);
    },
  );

  testWidgets(
    'changing source before the deadline abandons the pending local open',
    (tester) async {
      final ready = (await pageEntryGate(tester)).future;
      final entry = await prepareEntry(tester, localPlaybackReady: ready);
      await tester.runAsync(() async {
        await controller.switchToSource(
          const StreamResult(
            url: 'https://video.test/replacement.mp4',
            source: 'Replacement',
          ),
        );
      });
      expect(player.opened, ['https://video.test/replacement.mp4']);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.runAsync(() => entry.done);
      expect(player.opened, ['https://video.test/replacement.mp4']);
    },
  );

  for (final resumeMs in [0, 90000]) {
    testWidgets(
      'background pause remains effective at the local deadline with bookmark $resumeMs',
      (tester) async {
        history.position = resumeMs;
        player.value = player.value.copyWith(
          duration: const Duration(minutes: 20),
        );
        final ready = (await pageEntryGate(tester)).future;
        final entry = await prepareEntry(tester, localPlaybackReady: ready);
        await tester.runAsync(() async {
          controller.setAppBackgrounded(true);
          await controller.pause(onlyWhileBackgrounded: true);
        });
        expect(player.state.playing, isFalse);
        await tester.pump(const Duration(milliseconds: 500));
        await tester.runAsync(() => entry.done);
        expect(player.opened, ['/saved/entry.mp4']);
        if (resumeMs > 0) {
          expect(player.seeks, [Duration(milliseconds: resumeMs)]);
        }
        expect(player.state.playing, isFalse);
      },
    );
  }

  for (final inPip in [false, true]) {
    testWidgets(
      '${inPip ? 'PiP' : 'returning foreground before the deadline'} allows local autoplay',
      (tester) async {
        final ready = (await pageEntryGate(tester)).future;
        final entry = await prepareEntry(tester, localPlaybackReady: ready);
        await tester.runAsync(() async {
          controller.setAppBackgrounded(true);
          if (inPip) {
            controller.setInPip(true);
          } else {
            await controller.pause(onlyWhileBackgrounded: true);
            controller.setAppBackgrounded(false);
          }
        });
        await tester.pump(const Duration(milliseconds: 500));
        await tester.runAsync(() => entry.done);
        expect(player.state.playing, isTrue);
      },
    );
  }

  testWidgets(
    'next downloaded episode reuses the elapsed page-entry deadline',
    (tester) async {
      final ready = (await pageEntryGate(tester)).future;
      final entry = await prepareEntry(tester, localPlaybackReady: ready);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.runAsync(() async {
        await entry.done;
        player.advance(const Duration(seconds: 5));
        await controller.playNextEpisode();
      });
      expect(player.opened, ['/saved/entry.mp4', '/saved/episode-2.mp4']);
    },
  );

  test('local playback recovery never checks a router connection', () async {
    await startSource(local: true);
    player.errors.add('Connection reset by peer');
    await flush();
    expect(connectivityChecks, 0);
    expect(catalog.streamCalls, 0);
    expect(player.opened, ['/saved/episode.mp4']);
  });

  test('late signed URL recovery cannot reopen a replacement download', () async {
    await startSource();
    final pending = Completer<List<StreamResult>>();
    catalog.pendingStreams = pending;
    player.errors.add('Connection reset by peer');
    await flush();
    expect(catalog.streamCalls, 1, reason: 'Recovery must reach the pending resolver');
    final replacement = await replaceRoute();
    pending.complete([
      StreamResult(url: 'https://video.test/stale.mp4', source: 'Resolved'),
    ]);
    await flush();
    expect(controller.currentState.currentStream?.url, '/saved/replacement.mp4');
    expect(replacement.opened, ['/saved/replacement.mp4']);
  });

  test('late Wi-Fi check cannot reopen a replacement download', () async {
    await startSource();
    final pending = Completer<List<String>>();
    pendingConnectivity = pending;
    player.errors.add('Connection reset by peer');
    await flush();
    expect(connectivityChecks, 1);
    final replacement = await replaceRoute();
    pending.complete(['wifi']);
    await flush();
    expect(replacement.opened, ['/saved/replacement.mp4']);
    expect(catalog.streamCalls, 0);
  });

  test('late manual source resolution cannot hijack a replacement route', () async {
    await startSource(local: true);
    final pending = Completer<List<StreamResult>>();
    catalog.pendingStreams = pending;
    final switching = controller.switchToSource(
      StreamResult(
        url: 'https://video.test/provider-page',
        source: 'Provider',
        requiresResolution: true,
      ),
    );
    await flush();
    expect(catalog.streamCalls, 1);
    final replacement = await replaceRoute();
    pending.complete([
      StreamResult(url: 'https://video.test/stale.mp4', source: 'Resolved'),
    ]);
    expect(await switching, isFalse);
    expect(replacement.opened, ['/saved/replacement.mp4']);
  });

  for (final next in [false, true]) {
    test('late ${next ? 'next' : 'selected'} episode pause cannot reopen a replacement route', () async {
      await startSource(local: true);
      final pending = Completer<void>();
      player.pendingPause = pending;
      final transition = next
          ? controller.playNextEpisode()
          : controller.loadEpisode(_episode(2));
      await flush();
      final replacement = await replaceRoute();
      pending.complete();
      await transition;
      await flush();
      expect(controller.currentEpisode?.url, 'episode-4');
      expect(replacement.opened, ['/saved/replacement.mp4']);
    });
  }

  Future<void> startLive() async {
    final episode = _episode(1);
    await controller.init(
      player: player,
      item: _item([episode], type: MultimediaContentType.livestream),
      videoUrl: 'https://video.test/live.m3u8',
      episode: episode,
      selectedSource: StreamResult(url: 'https://video.test/live.m3u8', source: 'Live'),
    );
    player.advance(const Duration(seconds: 5));
    await flush();
  }

  test('replacement route resets an old pending stall recovery', () async {
    await startLive();
    final pending = Completer<void>();
    player.pendingOpen = pending;
    player.errors.add('Network stalled');
    await flush();
    expect(player.opened, hasLength(2));
    final replacement = await replaceRoute(live: true);
    replacement.errors.add('Network stalled');
    await flush();
    expect(replacement.opened, hasLength(2));
    pending.complete();
    await flush();
  });

  test('old stall completion cannot clear the replacement recovery guard', () async {
    await startLive();
    final oldPending = Completer<void>();
    player.pendingOpen = oldPending;
    player.errors.add('Network stalled');
    await flush();
    expect(player.opened, hasLength(2));
    final replacement = await replaceRoute(live: true);
    final newPending = Completer<void>();
    replacement.pendingOpen = newPending;
    replacement.errors.add('Network stalled');
    await flush();
    expect(replacement.opened, hasLength(2));
    oldPending.complete();
    await flush();
    replacement.advance(const Duration(seconds: 5));
    replacement.errors.add('Network stalled');
    await flush();
    expect(replacement.opened, hasLength(2));
    newPending.complete();
    await flush();
  });

  test('local startup skips network cookie and cache directory preparation', () async {
    final pendingDirectory = Completer<String>();
    var temporaryLookups = 0;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getTemporaryDirectory') {
          temporaryLookups++;
          return pendingDirectory.future;
        }
        return diagnosticsDirectory.path;
      },
    );
    final native = _ReadinessNative()..renderer.complete();
    player.native = native;
    final startup = startSource(local: true);
    try {
      await player.openedSignal.future.timeout(const Duration(seconds: 2));
      expect(temporaryLookups, 0);
      expect(native.properties, isNot(contains('cookies-file')));
      expect(native.properties, isNot(contains('cache-dir')));
    } finally {
      pendingDirectory.complete(diagnosticsDirectory.path);
      await startup;
      messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => call.method == 'getApplicationSupportDirectory'
            ? diagnosticsDirectory.path
            : '/nonexistent/player-tests',
      );
    }
  });

  test('remote startup preserves network cookie and cache properties', () async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => diagnosticsDirectory.path,
    );
    final native = _ReadinessNative()..renderer.complete();
    player.native = native;
    try {
      await startSource();
      expect(native.properties['cookies-file'], endsWith('mpv_cookies.txt'));
      expect(native.properties['cache-dir'], diagnosticsDirectory.path);
    } finally {
      messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => call.method == 'getApplicationSupportDirectory'
            ? diagnosticsDirectory.path
            : '/nonexistent/player-tests',
      );
    }
  });

  test('startup exposes a native property stall before renderer readiness', () async {
    await appDiagnostics.setEnabled(true);
    final pending = Completer<void>();
    final native = _ReadinessNative()..pendingProperties = pending;
    player.native = native;
    final episode = _episode(1);
    final startup = controller.init(
      player: player,
      item: _item([episode]),
      videoUrl: '/saved/episode.mp4',
      episode: episode,
    );
    try {
      await native.firstPropertyWrite.future.timeout(const Duration(seconds: 2));
      expect(native.propertyWrites, 1);
      final events = (await diagnosticEvents()).where(
        (event) => event['sourceSessionId'] == controller.currentState.sourceSessionId,
      );
      final names = events.map((event) => event['event']);
      expect(names, contains('player.properties.begin'));
      expect(names, isNot(contains('player.properties.end')));
      expect(names, isNot(contains('player.native_ready.begin')));
      expect(names, isNot(contains('player.engine_open.begin')));
      expect(native.openEntered, isFalse);
    } finally {
      pending.complete();
      native.renderer.complete();
      await startup;
    }
  });

  test(
    'startup waits for native renderer before taking the shared open lock',
    () async {
      await appDiagnostics.setEnabled(true);
      final native = _ReadinessNative();
      player.native = native;
      final episode = _episode(1);
      final startup = controller.init(
        player: player,
        item: _item([episode]),
        videoUrl: '/saved/episode.mp4',
        episode: episode,
      );
      await native.readinessReached.future.timeout(const Duration(seconds: 1));
      await flush();
      final session = controller.currentState.sourceSessionId;
      var nextEngineCanStart = false;
      final nextEngine = media.NativePlayer.lock.synchronized(
        () => nextEngineCanStart = true,
      );
      try {
        await flush();
        expect(nextEngineCanStart, isTrue);
        expect(native.openEntered, isFalse);
        final events = (await diagnosticEvents()).where(
          (event) => event['sourceSessionId'] == session,
        );
        expect(
          events.map((event) => event['event']),
          contains('player.native_ready.end'),
        );
        expect(
          events.map((event) => event['event']),
          contains('player.renderer_ready.begin'),
        );
        expect(
          events.map((event) => event['event']),
          isNot(contains('player.renderer_ready.end')),
        );
        expect(
          events.map((event) => event['event']),
          isNot(contains('player.engine_open.begin')),
        );
      } finally {
        native.renderer.complete();
        await startup;
        await nextEngine;
      }
      expect(native.openEntered, isTrue);
      expect(player.opened, ['/saved/episode.mp4']);
      final completed = (await diagnosticEvents()).where(
        (event) => event['sourceSessionId'] == session,
      );
      expect(
        completed.map((event) => event['event']),
        contains('player.renderer_ready.end'),
      );
      expect(
        completed.map((event) => event['event']),
        contains('player.engine_open.end'),
      );
    },
  );

  test(
    'late renderer readiness cannot enter an abandoned native open',
    () async {
      await appDiagnostics.setEnabled(true);
      final native = _ReadinessNative();
      player.native = native;
      final episode = _episode(1);
      final startup = controller.init(
        player: player,
        item: _item([episode]),
        videoUrl: '/saved/episode.mp4',
        episode: episode,
      );
      await native.readinessReached.future.timeout(const Duration(seconds: 1));
      await flush();
      final oldSession = controller.currentState.sourceSessionId;
      final replacement = await replaceRoute();
      native.renderer.complete();
      await startup;
      await flush();
      expect(native.openEntered, isFalse);
      expect(player.opened, isEmpty);
      expect(replacement.opened, ['/saved/replacement.mp4']);
      final events = (await diagnosticEvents()).where(
        (event) => event['sourceSessionId'] == oldSession,
      );
      expect(
        events.map((event) => event['event']),
        contains('player.session_stale'),
      );
      expect(
        events.map((event) => event['event']),
        isNot(contains('player.engine_open.begin')),
      );
    },
  );

  test(
    'startup diagnostics omit media secrets and only confirm position once',
    () async {
      await appDiagnostics.setEnabled(true);
      final episode = _episode(1, url: 'private-episode-secret');
      const secret = 'private-media-secret';
      await controller.init(
        player: player,
        item: _item([episode]).copyWith(title: secret),
        videoUrl: '/saved/$secret.mp4',
        episode: episode,
        selectedSource: const StreamResult(
          url: '/saved/$secret.mp4',
          source: secret,
          headers: {'Authorization': 'Bearer private-token-secret'},
        ),
      );
      final session = controller.currentState.sourceSessionId;
      for (var seconds = 1; seconds <= 100; seconds++) {
        player.advance(Duration(seconds: seconds));
      }
      final events = (await diagnosticEvents())
          .where((event) => event['sourceSessionId'] == session)
          .toList();
      expect(
        events.where((event) => event['event'] == 'player.first_position'),
        hasLength(1),
      );
      final text = jsonEncode(events);
      expect(text, isNot(contains(secret)));
      expect(text, isNot(contains('private-token-secret')));
      expect(text, isNot(contains('private-episode-secret')));
      expect(text, isNot(contains('/saved/')));
    },
  );

  test('engine failure diagnostics omit exception messages', () async {
    await appDiagnostics.setEnabled(true);
    final pending = Completer<void>();
    player.pendingOpen = pending;
    final episode = _episode(1);
    final startup = controller.init(
      player: player,
      item: _item([episode]),
      videoUrl: '/saved/private-file-secret.mp4',
      episode: episode,
    );
    await player.openEnteredSignal.future.timeout(const Duration(seconds: 2));
    final session = controller.currentState.sourceSessionId;
    pending.completeError(
      StateError(
        'https://private.test/secret?token=private-token-secret /saved/private-file-secret.mp4',
      ),
    );
    await startup;
    await flush();
    final events = (await diagnosticEvents())
        .where((event) => event['sourceSessionId'] == session)
        .toList();
    expect(
      events.map((event) => event['event']),
      contains('player.engine_open.error'),
    );
    final text = jsonEncode(events);
    expect(text, isNot(contains('private.test')));
    expect(text, isNot(contains('private-token-secret')));
    expect(text, isNot(contains('private-file-secret')));
  });

  for (final pausing in [true, false]) {
    test('${pausing ? 'pause' : 'play'} waits for renderer outside the shared native lock', () async {
      await startSource(local: true);
      final native = _ReadinessNative();
      player.native = native;
      final operation = pausing ? controller.pause() : controller.play();
      await native.readinessReached.future.timeout(const Duration(seconds: 1));
      await flush();
      var nextEngineCanStart = false;
      final nextEngine = media.NativePlayer.lock.synchronized(
        () => nextEngineCanStart = true,
      );
      try {
        await flush();
        expect(nextEngineCanStart, isTrue);
        expect(pausing ? native.pauseEntered : native.playEntered, isFalse);
      } finally {
        native.renderer.complete();
        await operation;
        await nextEngine;
      }
      expect(pausing ? native.pauseEntered : native.playEntered, isTrue);
    });

    test('late renderer cannot ${pausing ? 'pause' : 'play'} an abandoned player', () async {
      await startSource(local: true);
      final native = _ReadinessNative();
      player.native = native;
      final operation = pausing ? controller.pause() : controller.play();
      await native.readinessReached.future.timeout(const Duration(seconds: 1));
      await flush();
      final replacement = await replaceRoute();
      native.renderer.complete();
      await operation;
      expect(pausing ? native.pauseEntered : native.playEntered, isFalse);
      expect(replacement.opened, ['/saved/replacement.mp4']);
    });
  }

  for (final resumeBeforeReady in [true, false]) {
    test('lifecycle pause ${resumeBeforeReady ? 'is cancelled on foreground' : 'dispatches while backgrounded'} after renderer readiness', () async {
      await startSource(local: true);
      final native = _ReadinessNative();
      player.native = native;
      controller.setAppBackgrounded(true);
      final pausing = controller.pause(onlyWhileBackgrounded: true);
      await native.readinessReached.future.timeout(const Duration(seconds: 1));
      await flush();
      if (resumeBeforeReady) controller.setAppBackgrounded(false);
      native.renderer.complete();
      await pausing;
      expect(native.pauseEntered, !resumeBeforeReady);
      expect(player.state.playing, resumeBeforeReady);
    });
  }

  for (final payload in [
    '#EXTM3U\n#EXT-X-TARGETDURATION:12\nhttps://video.test/segment.ts\n',
    '<?xml version="1.0"?><MPD><Period /></MPD>',
    '<!doctype html><html><body>Sign in</body></html>',
  ]) {
    test('local text artifact is rejected before native startup without remote fallback: ${payload.substring(0, 8)}', () async {
      final directory = await Directory.systemTemp.createTemp('aw-local-payload-');
      final file = await File('${directory.path}/episode.mp4').writeAsString(payload);
      try {
        final episode = _episode(1);
        final native = _ReadinessNative();
        player.native = native;
        await controller.init(
          player: player,
          item: _item([episode]),
          videoUrl: file.path,
          episode: episode,
        ).timeout(const Duration(seconds: 1));
        await flush();
        expect(player.opened, isEmpty);
        expect(native.openEntered, isFalse);
        expect(native.propertyWrites, 0);
        expect(controller.currentState.uiPhase.kind, PlaybackUiPhaseKind.error);
        expect(controller.currentState.errorMessage, isNotEmpty);
        expect(catalog.streamCalls, 0);
        expect(connectivityChecks, 0);
        expect(await file.readAsString(), payload);
      } finally {
        player.native?.renderer.complete();
        await directory.delete(recursive: true);
      }
    });
  }

  test('unknown binary local video is left to the native engine', () async {
    final directory = await Directory.systemTemp.createTemp('aw-local-binary-');
    final file = await File('${directory.path}/episode.mp4').writeAsBytes([
      0, 0, 0, 24, 102, 116, 121, 112, 105, 115, 111, 109,
    ]);
    try {
      final episode = _episode(1);
      await controller.init(
        player: player,
        item: _item([episode]),
        videoUrl: file.path,
        episode: episode,
      );
      expect(player.opened, [file.path]);
      expect(controller.currentState.uiPhase.kind, isNot(PlaybackUiPhaseKind.error));
      expect(await file.length(), 12);
    } finally {
      await directory.delete(recursive: true);
    }
  });

  for (final local in [true, false]) {
    test(
      'opens ${local ? 'downloaded' : 'selected streaming'} episode without a cloud bookmark wait',
      () async {
        final episode = _episode(1);
        final url = local
            ? '/saved/episode.mp4'
            : 'https://video.test/episode.mp4';
        final startup = controller.init(
          player: player,
          item: _item([episode]),
          videoUrl: url,
          episode: episode,
          selectedSource: local
              ? null
              : StreamResult(url: url, source: 'Selected'),
        );
        await player.openedSignal.future.timeout(const Duration(seconds: 1));
        expect(
          player.opened,
          [url],
          reason:
              'The engine must open before a hanging cloud request resolves',
        );
        player.advance(const Duration(milliseconds: 100));
        expect(controller.currentState.uiPhase.fullscreenBlocking, isFalse);
        expect(
          account.calls,
          0,
          reason: 'Late player-triggered imports can overwrite newer local progress',
        );
        await startup;
        account.pending.complete();
        await Future<void>.delayed(Duration.zero);
        expect(player.seeks, isEmpty);
        expect(player.opened, [url]);
      },
    );
  }

  test(
    'clamps an oversized bookmark for both seeking and video reveal',
    () async {
      final episode = _episode(1);
      history.position = 90000;
      player.value = player.value.copyWith(
        duration: const Duration(seconds: 20),
      );
      final startup = controller.init(
        player: player,
        item: _item([episode]),
        videoUrl: '/saved/shorter.mp4',
        episode: episode,
      );
      await startup.timeout(const Duration(seconds: 1));
      expect(player.seeks, [const Duration(seconds: 20)]);
      expect(
        player.state.playing,
        isTrue,
        reason: 'Do not wait for the unreachable 90-second bookmark after seeking to 20 seconds',
      );
      expect(controller.currentState.uiPhase.fullscreenBlocking, isFalse);
      await startup;
    },
  );

  test('publishes the full catalog while artwork is pending without altering playback', () async {
    final first = _episode(1);
    // The usable local bookmark keeps this focused on catalog hydration in the baseline.
    history.position = 15000;
    player.value = player.value.copyWith(duration: const Duration(minutes: 20));
    await controller.init(
      player: player,
      item: _item([first]),
      videoUrl: '/saved/episode.mp4',
      episode: first,
    );
    expect(player.opened, ['/saved/episode.mp4']);
    expect(catalog.episodes, hasLength(1));
    expect(catalog.artwork, hasLength(1));
    final phase = controller.currentState.uiPhase;
    final source = controller.currentState.currentStream;
    final session = controller.currentState.sourceSessionId;
    final second = _episode(2);
    catalog.episodes.single.complete([first, second]);
    await Future<void>.delayed(Duration.zero);
    expect(controller.multimediaItem!.episodes!.map((e) => e.url), [
      first.url,
      second.url,
    ]);
    expect(controller.nextEpisode?.url, second.url);
    expect(controller.currentState.uiPhase, same(phase));
    expect(controller.currentState.currentStream, same(source));
    expect(controller.currentState.sourceSessionId, session);
    catalog.artwork.single.complete([
      second.copyWith(posterUrl: 'https://image.test/2.jpg'),
    ]);
    await Future<void>.delayed(Duration.zero);
    expect(controller.nextEpisode?.posterUrl, 'https://image.test/2.jpg');
    expect(player.opened, ['/saved/episode.mp4']);
    expect(catalog.detailCalls, 0);
    expect(catalog.scheduleCalls, 0);
  });
  test(
    'a valid local bookmark stays paused and hidden until the seek settles',
    () async {
      final episode = _episode(1);
      history.position = 15000;
      player.settleSeek = false;
      player.value = player.value.copyWith(
        duration: const Duration(minutes: 20),
      );
      final startup = controller.init(
        player: player,
        item: _item([episode]),
        videoUrl: '/saved/episode.mp4',
        episode: episode,
      );
      await player.seekSignal.future.timeout(const Duration(seconds: 1));
      expect(player.seeks, [const Duration(seconds: 15)]);
      expect(player.state.playing, isFalse);
      expect(controller.currentState.uiPhase.fullscreenBlocking, isTrue);
      player.advance(const Duration(seconds: 15));
      await startup;
      expect(player.state.playing, isTrue);
      expect(controller.currentState.uiPhase.fullscreenBlocking, isFalse);
      expect(account.calls, 0);
    },
  );

  Future<void> startCatalog(
    List<Episode> episodes, {
    String animeUrl = 'anime-a',
    String file = '/saved/episode.mp4',
    MultimediaContentType type = MultimediaContentType.anime,
  }) async {
    history.position = 15000;
    player.value = player.value.copyWith(duration: const Duration(minutes: 20));
    await controller.init(
      player: player,
      item: _item(episodes, url: animeUrl, type: type),
      videoUrl: file,
      episode: episodes.first,
    );
    expect(catalog.episodes, isNotEmpty);
    expect(catalog.artwork, isNotEmpty);
  }

  test('artwork arriving first is retained when the catalog follows', () async {
    final first = _episode(1);
    final second = _episode(2);
    await startCatalog([first]);
    catalog.artwork.single.complete([
      second.copyWith(posterUrl: 'https://image.test/2.jpg'),
    ]);
    await Future<void>.delayed(Duration.zero);
    catalog.episodes.single.complete([first, second]);
    await Future<void>.delayed(Duration.zero);
    expect(controller.nextEpisode?.posterUrl, 'https://image.test/2.jpg');
  });

  test(
    'offline catalog failure keeps saved next and previous episodes usable',
    () async {
      final episodes = [_episode(1), _episode(2), _episode(3)];
      await startCatalog(episodes);
      catalog.episodes.single.completeError(StateError('offline'));
      catalog.artwork.single.completeError(StateError('offline'));
      await Future<void>.delayed(Duration.zero);
      expect(controller.nextEpisode?.url, episodes[1].url);
      await controller.playNextEpisode();
      expect(player.opened.last, '/saved/episode-2.mp4');
      expect(controller.previousEpisode?.url, episodes.first.url);
      expect(controller.nextEpisode?.url, episodes.last.url);
    },
  );

  test(
    'catalog failure does not discard independently fetched artwork',
    () async {
      final first = _episode(1);
      await startCatalog([first]);
      catalog.episodes.single.completeError(StateError('offline catalog'));
      catalog.artwork.single.complete([
        first.copyWith(posterUrl: 'https://image.test/1.jpg'),
      ]);
      await Future<void>.delayed(Duration.zero);
      expect(
        controller.multimediaItem!.episodes!.single.posterUrl,
        'https://image.test/1.jpg',
      );
    },
  );

  for (final sameAnime in [true, false]) {
    test(
      'late metadata cannot overwrite a ${sameAnime ? 'reopened' : 'different'} player route',
      () async {
        await startCatalog([_episode(1)]);
        final replacement = _episode(4);
        await startCatalog(
          [replacement],
          animeUrl: sameAnime ? 'anime-a' : 'anime-b',
          file: '/saved/replacement.mp4',
        );
        catalog.episodes.first.complete([_episode(1), _episode(2)]);
        catalog.artwork.first.complete([
          _episode(1, poster: 'https://stale.test/1.jpg'),
        ]);
        await Future<void>.delayed(Duration.zero);
        expect(controller.multimediaItem!.episodes!.map((e) => e.url), [
          replacement.url,
        ]);
        expect(controller.currentEpisode?.url, replacement.url);
        expect(
          controller.currentState.currentStream?.url,
          '/saved/replacement.mp4',
        );
      },
    );
  }

  test('late metadata after disposal does not mutate the player', () async {
    await startCatalog([_episode(1)]);
    controller.disposeController(player: player);
    await Future<void>.delayed(Duration.zero);
    final disposedState = controller.currentState;
    final savedItem = controller.multimediaItem;
    catalog.episodes.single.complete([_episode(1), _episode(2)]);
    catalog.artwork.single.complete([
      _episode(1, poster: 'https://stale.test/1.jpg'),
    ]);
    await Future<void>.delayed(Duration.zero);
    expect(controller.currentState, same(disposedState));
    expect(controller.multimediaItem, same(savedItem));
  });

  test(
    'background completion keeps an in-place episode switch authoritative',
    () async {
      final first = _episode(1);
      final second = _episode(2);
      await startCatalog([first, second]);
      await controller.loadEpisode(second);
      catalog.episodes.single.complete([first, second, _episode(3)]);
      catalog.artwork.single.complete([
        first.copyWith(posterUrl: 'https://image.test/1.jpg'),
      ]);
      await Future<void>.delayed(Duration.zero);
      expect(controller.currentEpisode?.url, second.url);
      expect(controller.currentState.activeEpisodeUrl, second.url);
      expect(
        controller.currentState.currentStream?.url,
        '/saved/episode-2.mp4',
      );
      expect(controller.nextEpisode?.url, 'episode-3');
      expect(player.opened, ['/saved/episode.mp4', '/saved/episode-2.mp4']);
    },
  );

  test(
    'movie variants keep exact saved identity when absent from the server',
    () async {
      final dubbed = _episode(
        0,
        url: 'movie-dub',
        dubStatus: DubStatus.dubbed,
      ).copyWith(serverName: 'مدبلج', serverNumber: '0');
      final translated = _episode(
        0,
        url: 'movie-sub',
        dubStatus: DubStatus.subbed,
      );
      await startCatalog([dubbed], type: MultimediaContentType.movie);
      catalog.episodes.single.complete([translated]);
      catalog.artwork.single.complete([
        translated.copyWith(posterUrl: 'https://image.test/sub.jpg'),
      ]);
      await Future<void>.delayed(Duration.zero);
      expect(
        controller.multimediaItem!.episodes!.map((e) => e.url),
        containsAll([translated.url, dubbed.url]),
      );
      expect(controller.currentEpisode?.url, dubbed.url);
      expect(controller.currentEpisode?.dubStatus, DubStatus.dubbed);
      expect(controller.currentEpisode?.serverName, 'مدبلج');
      expect(controller.currentState.activeEpisodeUrl, dubbed.url);
      expect(controller.currentState.currentStream?.url, '/saved/episode.mp4');
    },
  );
  test(
    'hydrates the current history hint by URL before dub-aware navigation',
    () async {
      final hint = _episode(1, url: 'dub-1').copyWith(name: '');
      await startCatalog([hint]);
      final dubbed = _episode(
        1,
        url: 'dub-1',
        dubStatus: DubStatus.dubbed,
      ).copyWith(name: 'Server title', serverName: 'مدبلج');
      catalog.episodes.single.complete([
        _episode(1, url: 'sub-1', dubStatus: DubStatus.subbed),
        dubbed,
        _episode(2, url: 'sub-2', dubStatus: DubStatus.subbed),
        _episode(2, url: 'dub-2', dubStatus: DubStatus.dubbed),
      ]);
      await Future<void>.delayed(Duration.zero);
      expect(controller.currentEpisode?.url, hint.url);
      expect(controller.currentEpisode?.dubStatus, DubStatus.dubbed);
      expect(controller.currentEpisode?.name, 'Server title');
      expect(controller.nextEpisode?.url, 'dub-2');
      catalog.artwork.single.complete([
        dubbed.copyWith(posterUrl: 'https://image.test/dub-1.jpg'),
      ]);
      await Future<void>.delayed(Duration.zero);
      expect(
        controller.currentEpisode?.posterUrl,
        'https://image.test/dub-1.jpg',
      );
      expect(controller.currentState.activeEpisodeUrl, hint.url);
      expect(player.opened, ['/saved/episode.mp4']);
    },
  );
  test(
    'episode-list listeners rebuild for both catalog and artwork updates',
    () async {
      final first = _episode(1);
      await startCatalog([first]);
      final updates = <List<Episode>>[];
      final subscription = container.listen(
        playerControllerProvider.select((state) => state.episodes),
        (_, next) => updates.add(next),
      );
      addTearDown(subscription.close);
      catalog.episodes.single.complete([first, _episode(2)]);
      await Future<void>.delayed(Duration.zero);
      expect(updates, hasLength(1));
      expect(updates.single, hasLength(2));
      catalog.artwork.single.complete([
        _episode(2, poster: 'https://image.test/2.jpg'),
      ]);
      await Future<void>.delayed(Duration.zero);
      expect(updates, hasLength(2));
      expect(updates.last.last.posterUrl, 'https://image.test/2.jpg');
    },
  );
}
