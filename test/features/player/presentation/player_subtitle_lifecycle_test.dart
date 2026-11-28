import 'dart:async';
import 'dart:collection';

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/storage/history_repository.dart';
import 'package:animewitcher/features/player/presentation/player_controller_base.dart';
import 'package:animewitcher/features/settings/presentation/player_settings_provider.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart' as media;

class _Player extends Fake implements media.Player {
  final tracks = StreamController<media.Track>.broadcast(sync: true);
  final positions = StreamController<Duration>.broadcast(sync: true);
  final selections = <media.SubtitleTrack>[];
  final audioSelections = <media.AudioTrack>[];
  final errors = StreamController<String>.broadcast(sync: true);
  final opens = <String>[];
  media.PlayerState value = const media.PlayerState(
    tracks: media.Tracks(subtitle: [media.SubtitleTrack('1', 'Arabic', 'ar')]),
  );
  bool disposed = false;
  Completer<void>? pendingSelection;

  @override
  media.PlayerState get state => value;
  @override
  media.PlatformPlayer? get platform => null;
  @override
  media.PlayerStream get stream =>
      _Streams(tracks.stream, positions.stream, errors.stream);
  @override
  Future<void> open(media.Playable playable, {bool play = true}) async {
    opens.add((playable as media.Media).uri);
  }

  @override
  Future<void> setAudioTrack(media.AudioTrack track) async {
    audioSelections.add(track);
  }

  @override
  Future<void> setSubtitleTrack(media.SubtitleTrack track) async {
    selections.add(track);
    if (disposed) throw AssertionError('[Player] has been disposed');
    await pendingSelection?.future;
    value = value.copyWith(track: value.track.copyWith(subtitle: track));
  }

  void confirmPlayback() {
    value = value.copyWith(position: const Duration(seconds: 1));
    positions.add(value.position);
  }

  Future<void> close() async {
    await tracks.close();
    await positions.close();
    await errors.close();
  }
}

class _Streams extends Fake implements media.PlayerStream {
  _Streams(this.track, this.position, this.error);
  @override
  final Stream<media.Track> track;
  @override
  final Stream<Duration> position;
  @override
  Stream<Duration> get duration => const Stream.empty();
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
}

class _CountedAudio extends ListBase<media.AudioTrack> {
  _CountedAudio(this._tracks);

  final List<media.AudioTrack> _tracks;
  int reads = 0;

  @override
  int get length => _tracks.length;
  @override
  set length(int _) => throw UnsupportedError('Read-only test tracks');
  @override
  media.AudioTrack operator [](int index) {
    reads++;
    return _tracks[index];
  }

  @override
  void operator []=(int index, media.AudioTrack value) =>
      throw UnsupportedError('Read-only test tracks');
}

class _Settings extends PlayerSettingsNotifier {
  @override
  Future<PlayerSettings> build() async => const PlayerSettings();
}

class _History extends Fake implements HistoryRepository {
  @override
  int getPosition(String url) => 0;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ProviderContainer container;
  late PlayerController controller;
  final players = <_Player>[];

  setUp(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity_status'),
      (_) async => null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => '/nonexistent/player-subtitle-tests',
    );
    container = ProviderContainer(
      overrides: [
        playerSettingsProvider.overrideWith(_Settings.new),
        historyRepositoryProvider.overrideWithValue(_History()),
      ],
    );
    controller = container.read(playerControllerProvider.notifier);
  });
  tearDown(() async {
    container.dispose();
    for (final player in players) {
      await player.close();
    }
    players.clear();
  });

  Future<_Player> start({
    String name = 'original',
    List<SubtitleFile>? subtitles,
  }) async {
    final player = _Player();
    players.add(player);
    await controller.init(
      player: player,
      item: MultimediaItem(
        title: 'Saved movie',
        url: name,
        posterUrl: '',
        contentType: MultimediaContentType.movie,
        provider: 'Remote',
      ),
      videoUrl: 'https://video.test/$name.mp4',
      selectedSource: StreamResult(
        url: 'https://video.test/$name.mp4',
        source: 'Selected',
        subtitles: subtitles,
      ),
    );
    player.confirmPlayback();
    return player;
  }

  testWidgets('audio failover keeps rendition order and source', (
    tester,
  ) async {
    const auto = media.AudioTrack('auto', null, null);
    const off = media.AudioTrack('no', 'Default off', null);
    const laterOff = media.AudioTrack('no', 'Duplicate off', null);
    const first = media.AudioTrack('1', 'First', 'ja');
    const duplicate = media.AudioTrack('1', 'Duplicate', 'en');
    const second = media.AudioTrack('2', 'Second', 'en');
    const third = media.AudioTrack('3', 'Third', 'ar');
    final player = await start();
    const original = 'https://video.test/original.mp4';
    const replacement = 'https://video.test/replacement.mp4';

    _CountedAudio install(List<media.AudioTrack> audio) {
      final counted = _CountedAudio(audio);
      player.value = player.value.copyWith(
        tracks: media.Tracks(audio: counted),
      );
      return counted;
    }

    Future<void> switchSource(String url) async {
      // Do not carry the fake position forward into the seek-back path.
      player.value = player.value.copyWith(position: Duration.zero);
      expect(
        await controller.switchToSource(
          StreamResult(url: url, source: 'Mirror'),
        ),
        isTrue,
      );
    }

    final firstInventory = install([
      auto,
      off,
      first,
      duplicate,
      second,
      third,
    ]);
    player.errors.add('FFmpeg: ERROR DECODING AUDIO');
    expect(player.audioSelections.single, same(second));
    expect(player.opens, [original]);
    expect(player.value.position, const Duration(seconds: 1));
    // An immediate repeat is debounced, without examining the inventory again.
    final firstReads = firstInventory.reads;
    player.errors.add('FFmpeg: ERROR DECODING AUDIO');
    expect(firstInventory.reads, firstReads);
    expect(player.audioSelections, hasLength(1));

    await switchSource(replacement);
    final exhausted = install([auto, first, duplicate, off, laterOff]);
    player.errors.add('FFmpeg: ERROR DECODING AUDIO');
    expect(player.audioSelections.last, same(off));
    expect(player.opens, [original, replacement]);

    await switchSource(original);
    final recorded = install([auto, off, first, second, third]);
    // A track was actually selected and mpv then reports Off before the error.
    player.tracks.add(media.Track(audio: first));
    player.tracks.add(media.Track(audio: off));
    player.errors.add('FFmpeg: ERROR DECODING AUDIO');
    expect(player.audioSelections.last, same(second));
    expect(player.opens, [original, replacement, original]);

    final reads = [firstReads, exhausted.reads, recorded.reads];
    expect(player.audioSelections.map((track) => track.id), ['2', 'no', '2']);
    debugPrint('C25_AUDIO_TRACKS reads=$reads selections=2/no/2');
    const stock = bool.fromEnvironment('C25_STOCK');
    expect(reads, stock ? [8, 11, 4] : [5, 5, 4]);
  });

  testWidgets('subtitle fallback still selects for the active source', (
    tester,
  ) async {
    final player = await start();
    await tester.pump(const Duration(seconds: 2));
    expect(player.selections.map((track) => track.id), ['1']);
  });

  testWidgets(
    'route exit cancels delayed subtitle selection and its listener',
    (tester) async {
      final player = await start();
      controller.disposeController(player: player);
      player.disposed = true;
      expect(player.tracks.hasListener, isFalse);
      await tester.pump(const Duration(seconds: 3));
      expect(player.selections, isEmpty);
    },
  );

  testWidgets('provider disposal cancels delayed subtitle selection', (
    tester,
  ) async {
    final player = await start();
    container.dispose();
    player.disposed = true;
    expect(player.tracks.hasListener, isFalse);
    await tester.pump(const Duration(seconds: 3));
    expect(player.selections, isEmpty);
  });

  testWidgets('old route timeout cannot select on a replacement player', (
    tester,
  ) async {
    final old = await start();
    await tester.pump(const Duration(seconds: 1));
    controller.disposeController(player: old);
    old.disposed = true;
    final replacement = await start(name: 'replacement');
    await tester.pump(const Duration(seconds: 1));
    expect(replacement.selections, isEmpty);
    await tester.pump(const Duration(seconds: 1));
    expect(replacement.selections.map((track) => track.id), ['1']);
    expect(old.selections, isEmpty);
  });

  testWidgets('source replacement cancels the previous subtitle timeout', (
    tester,
  ) async {
    final player = await start();
    await tester.pump(const Duration(seconds: 1));
    player.value = player.value.copyWith(position: Duration.zero);
    expect(
      await controller.switchToSource(
        const StreamResult(
          url: 'https://video.test/replacement.mp4',
          source: 'Replacement',
        ),
      ),
      isTrue,
    );
    await tester.pump(const Duration(seconds: 1));
    expect(player.selections, isEmpty);
    await tester.pump(const Duration(seconds: 1));
    expect(player.selections.map((track) => track.id), ['1']);
  });

  testWidgets(
    'track readiness cancels the fallback while selection is pending',
    (tester) async {
      final player = await start();
      final pending = Completer<void>();
      player.pendingSelection = pending;
      player.tracks.add(player.state.track);
      await tester.pump();
      expect(player.selections, hasLength(1));
      await tester.pump(const Duration(seconds: 3));
      expect(player.selections, hasLength(1));
      pending.complete();
      await tester.pump();
    },
  );

  testWidgets('selection failure after route exit is handled as stale work', (
    tester,
  ) async {
    final player = await start();
    final pending = Completer<void>();
    player.pendingSelection = pending;
    player.tracks.add(player.state.track);
    await tester.pump();
    controller.disposeController(player: player);
    pending.completeError(AssertionError('[Player] has been disposed'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(player.selections, hasLength(1));
  });

  testWidgets(
    'active subtitle selection failures are safely handled',
    (tester) async {
      final player = await start();
      final pending = Completer<void>();
      player.pendingSelection = pending;
      player.tracks.add(player.state.track);
      await tester.pump();
      pending.completeError(
        StateError('active subtitle failure'),
        StackTrace.fromString(
          '#0 NativePlayer.setSubtitleTrack '
          '(package:media_kit/src/player/native/player/real.dart:1090:7)',
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(player.selections, hasLength(1));

    },
  );

  testWidgets('external subtitles still take precedence over embedded ones', (
    tester,
  ) async {
    final player = await start(
      subtitles: [
        SubtitleFile(
          url: 'https://video.test/subtitle.vtt',
          label: 'Arabic',
          lang: 'ar',
        ),
      ],
    );
    await tester.pump(const Duration(seconds: 2));
    expect(player.selections.single.id, 'https://video.test/subtitle.vtt');
    expect(player.selections.single.uri, isTrue);
  });

  testWidgets('an existing subtitle choice is preserved', (tester) async {
    final player = await start();
    player.value = player.value.copyWith(
      track: player.value.track.copyWith(
        subtitle: const media.SubtitleTrack('user-selected', 'English', 'en'),
      ),
    );
    await tester.pump(const Duration(seconds: 2));
    expect(player.selections, isEmpty);
  });
}
