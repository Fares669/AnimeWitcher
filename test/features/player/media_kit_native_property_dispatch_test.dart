import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

void main() {
  final clip = Platform.environment['ANIMEWITCHER_TEST_LOCAL_CLIP'];
  final mpv = Platform.environment['ANIMEWITCHER_TEST_LIBMPV'];

  test(
    'native property dispatch keeps position, source changes and observers live',
    () async {
      // Linux headless opt-in, like the player controls/Back smoke tests.
      final previousTest = NativePlayer.test;
      NativePlayer.test = true;
      addTearDown(() => NativePlayer.test = previousTest);
      MediaKit.ensureInitialized(libmpv: mpv);
      final temp = await Directory.systemTemp.createTemp('property-dispatch-');
      addTearDown(() => temp.delete(recursive: true));
      final file = File(clip!);
      final suffix = file.uri.pathSegments.last.split('.').last;
      final first = await file.copy('${temp.path}/first.$suffix');
      final second = await file.copy('${temp.path}/second.$suffix');

      final player = Player(
        configuration: const PlayerConfiguration(muted: true),
      );
      addTearDown(player.dispose);
      final native = player.platform! as NativePlayer;
      final paths = StreamController<String>.broadcast();
      addTearDown(paths.close);
      await native.observeProperty('path', (path) async => paths.add(path));
      addTearDown(() => native.unobserveProperty('path'));

      const timeout = Duration(seconds: 5);
      Future<void> openAndWait(File source) async {
        final seenPath = paths.stream
            .firstWhere((path) => path.endsWith(source.uri.pathSegments.last))
            .timeout(timeout);
        final position = player.stream.position
            .firstWhere(
              (position) => position >= const Duration(milliseconds: 200),
            )
            .timeout(timeout);
        await player.open(Media(source.uri.toString()));
        await Future.wait([seenPath, position]);
        expect(player.state.duration, greaterThan(const Duration(seconds: 1)));
        expect(player.state.playing, isTrue);
        expect(player.state.playlist.medias.single.uri, source.path);
      }

      await openAndWait(first);
      final paused = player.stream.playing
          .firstWhere((playing) => !playing)
          .timeout(timeout);
      await player.pause();
      await paused;

      final duration = player.state.duration;
      final target = duration ~/ 2;
      final sought = player.stream.position
          .firstWhere(
            (position) =>
                (position - target).abs() < const Duration(milliseconds: 250),
          )
          .timeout(timeout);
      await player.seek(target);
      final pausedPosition = await sought;
      expect(player.state.playing, isFalse);

      final resumed = player.stream.position
          .firstWhere((position) => position > pausedPosition)
          .timeout(timeout);
      await player.play();
      await resumed;

      await player.stop();
      expect(player.state.position, Duration.zero);
      await openAndWait(second);
    },
    skip: !Platform.isLinux || clip == null || mpv == null,
    timeout: const Timeout(Duration(seconds: 28)),
  );
}
