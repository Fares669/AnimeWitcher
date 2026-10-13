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
  final opened = <String>[];
  final seeks = <Duration>[];
  media.PlayerState value = const media.PlayerState();

  @override
  media.PlayerState get state => value;
  @override
  media.PlayerStream get stream => _Streams(positions.stream, durations.stream);
  @override
  dynamic get platform => null;
  @override
  Future<void> open(media.Playable playable, {bool play = true}) async {
    opened.add((playable as media.Media).uri);
    value = value.copyWith(position: Duration.zero, playing: play);
  }

  @override
  Future<void> pause() async => value = value.copyWith(playing: false);
  @override
  Future<void> play() async => value = value.copyWith(playing: true);
  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
    advance(position);
  }

  void advance(Duration position) {
    value = value.copyWith(position: position);
    positions.add(position);
  }

  Future<void> close() async {
    await positions.close();
    await durations.close();
  }
}

class _Streams extends Fake implements media.PlayerStream {
  _Streams(this.position, this.duration);
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
  Stream<String> get error => const Stream.empty();
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
  Future<List<StreamResult>> loadStreams(String url) async =>
      throw StateError('Local playback must not resolve sources');
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
  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dev.fluttercommunity.plus/connectivity_status'),
          (_) async => null,
        );
  });

  late ProviderContainer container;
  late PlayerController controller;
  late _Catalog catalog;
  late _Player player;
  late _Account account;
  late _HistoryRepository history;

  setUp(() async {
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
        await Future<void>.delayed(Duration.zero);
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
      await Future<void>.delayed(Duration.zero);
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
}
