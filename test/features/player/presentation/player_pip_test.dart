import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:animewitcher/features/player/presentation/player_chrome_actions.dart';
import 'package:animewitcher/features/player/presentation/player_pip.dart';
import 'package:animewitcher/features/player/presentation/player_platform_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PlayerPip.shouldShowButton', () {
    test('shows on Android phones when the settings toggle is on', () {
      expect(
        PlayerPip.shouldShowButton(showPip: true, isAndroid: true, isTv: false),
        isTrue,
      );
    });

    test('hides on iOS even when the settings toggle is on', () {
      expect(
        PlayerPip.shouldShowButton(
          showPip: true,
          isAndroid: false,
          isTv: false,
        ),
        isFalse,
      );
    });

    test('hides when the player-controls toggle is off', () {
      expect(
        PlayerPip.shouldShowButton(
          showPip: false,
          isAndroid: true,
          isTv: false,
        ),
        isFalse,
      );
    });

    test('hides on TV, desktop, and devices without system PiP', () {
      expect(
        PlayerPip.shouldShowButton(showPip: true, isAndroid: true, isTv: true),
        isFalse,
      );
      expect(
        PlayerPip.shouldShowButton(
          showPip: true,
          isAndroid: false,
          isTv: false,
        ),
        isFalse,
      );
      expect(
        PlayerPip.shouldShowButton(
          showPip: true,
          isAndroid: true,
          isTv: false,
          pipAvailable: false,
        ),
        isFalse,
      );
    });
  });

  group('PlayerPip.clampAspectRatio', () {
    test('keeps a normal 16:9 size', () {
      expect(PlayerPip.clampAspectRatio(1920, 1080), (1920, 1080));
    });

    test('falls back to 16:9 when size is missing', () {
      expect(PlayerPip.clampAspectRatio(0, 0), (16, 9));
    });

    test('clamps ultra-wide and ultra-tall ratios', () {
      expect(PlayerPip.clampAspectRatio(4000, 100), (239, 100));
      expect(PlayerPip.clampAspectRatio(100, 4000), (100, 239));
    });
  });

  group('PlayerPip.modeFromNative', () {
    test('reads Android bool payloads', () {
      expect(PlayerPip.modeFromNative(true).active, isTrue);
      expect(PlayerPip.modeFromNative(false).active, isFalse);
    });
  });

  group('PlayerChromeActions', () {
    test('places PiP immediately left of rotate', () {
      final actions = PlayerChromeActions.visible(
        showPlaybackSpeed: false,
        supportsPlaybackSpeed: true,
        showPip: true,
        pipSupported: true,
        showRotate: true,
        canRotate: true,
        showEpisodes: true,
        hasEpisodePicker: true,
        showResize: false,
        isDesktop: false,
        anime4kOn: false,
        anime4kSupported: true,
      );

      expect(actions, [
        PlayerChromeAction.pip,
        PlayerChromeAction.rotate,
        PlayerChromeAction.episodes,
      ]);
    });

    test('keeps PiP left of rotate when speed is also visible', () {
      final actions = PlayerChromeActions.visible(
        showPlaybackSpeed: true,
        supportsPlaybackSpeed: true,
        showPip: true,
        pipSupported: true,
        showRotate: true,
        canRotate: true,
        showEpisodes: false,
        hasEpisodePicker: true,
        showResize: true,
        isDesktop: false,
        anime4kOn: false,
        anime4kSupported: true,
      );

      expect(
        actions.indexOf(PlayerChromeAction.pip),
        actions.indexOf(PlayerChromeAction.rotate) - 1,
      );
    });

    test('omits PiP when the settings toggle is off', () {
      final actions = PlayerChromeActions.visible(
        showPlaybackSpeed: false,
        supportsPlaybackSpeed: true,
        showPip: false,
        pipSupported: true,
        showRotate: true,
        canRotate: true,
        showEpisodes: false,
        hasEpisodePicker: false,
        showResize: false,
        isDesktop: false,
        anime4kOn: false,
        anime4kSupported: true,
      );

      expect(actions, [PlayerChromeAction.rotate]);
    });

    List<PlayerChromeAction> withAnime4k({
      required bool on,
      required bool supported,
    }) {
      return PlayerChromeActions.visible(
        showPlaybackSpeed: false,
        supportsPlaybackSpeed: false,
        showPip: false,
        pipSupported: false,
        showRotate: false,
        canRotate: false,
        showEpisodes: false,
        hasEpisodePicker: false,
        showResize: true,
        isDesktop: false,
        anime4kOn: on,
        anime4kSupported: supported,
      );
    }

    test('the Anime4K button appears only once a mode is chosen', () {
      expect(
        withAnime4k(on: false, supported: true),
        <PlayerChromeAction>[PlayerChromeAction.resize],
      );
      expect(
        withAnime4k(on: true, supported: true),
        <PlayerChromeAction>[
          PlayerChromeAction.anime4k,
          PlayerChromeAction.resize,
        ],
      );
    });

    test('it stays hidden on a backend that cannot run shaders', () {
      // The adaptive player used for DRM has no GLSL stage; offering the
      // panel there would let someone change a setting that never reaches
      // the picture they are looking at.
      expect(
        withAnime4k(on: true, supported: false),
        <PlayerChromeAction>[PlayerChromeAction.resize],
      );
    });

    test('it sits beside resize, both being about how the picture looks', () {
      final actions = PlayerChromeActions.visible(
        showPlaybackSpeed: true,
        supportsPlaybackSpeed: true,
        showPip: false,
        pipSupported: false,
        showRotate: false,
        canRotate: false,
        showEpisodes: true,
        hasEpisodePicker: true,
        showResize: true,
        isDesktop: true,
        anime4kOn: true,
        anime4kSupported: true,
      );
      expect(actions, <PlayerChromeAction>[
        PlayerChromeAction.playbackSpeed,
        PlayerChromeAction.episodes,
        PlayerChromeAction.anime4k,
        PlayerChromeAction.resize,
        PlayerChromeAction.desktopFullscreen,
      ]);
    });
  });

  group('PlayerPlatformService PiP channel', () {
    const channel = MethodChannel('com.animewitcher.app.player/pip.test');
    late PlayerPlatformService service;
    late List<MethodCall> calls;

    setUp(() {
      calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (call.method == 'enterPip') return true;
            if (call.method == 'isPipAvailable') return true;
            return null;
          });
      service = PlayerPlatformService(pipChannel: channel, nativePip: true);
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('enterPip calls the official system method with video size', () async {
      final ok = await service.enterPip(
        isPlaying: true,
        width: 1920,
        height: 1080,
      );

      expect(ok, isTrue);
      expect(calls, hasLength(1));
      expect(calls.single.method, 'enterPip');
      expect(calls.single.arguments, {
        'isPlaying': true,
        'width': 1920,
        'height': 1080,
      });
    });

    test(
      'updatePipSession sends the settings-gated auto-enter payload',
      () async {
        await service.updatePipSession(
          active: true,
          enabled: false,
          isPlaying: true,
          width: 1280,
          height: 720,
        );

        expect(calls.single.method, 'updatePip');
        expect(calls.single.arguments, {
          'isPlaying': true,
          'width': 1280,
          'height': 720,
          'active': true,
          'enabled': false,
        });
      },
    );

    test('isPipAvailable queries the host activity', () async {
      expect(await service.isPipAvailable(), isTrue);
      expect(calls.single.method, 'isPipAvailable');
    });

    test('skips native calls when system PiP is not used', () async {
      final desktop = PlayerPlatformService(
        pipChannel: channel,
        nativePip: false,
      );

      expect(await desktop.enterPip(isPlaying: true), isFalse);
      expect(await desktop.isPipAvailable(), isFalse);
      await desktop.updatePipSession(
        active: true,
        enabled: true,
        isPlaying: true,
      );
      expect(calls, isEmpty);
    });
  });
}
