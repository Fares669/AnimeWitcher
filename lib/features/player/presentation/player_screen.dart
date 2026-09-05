import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:animewitcher/shared/widgets/apple_liquid_glass.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';
import 'package:media_kit/media_kit.dart' hide PlayerState;
import 'package:media_kit_video/media_kit_video.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:video_view/video_view.dart' as vv;
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/utils/immersive_mode.dart';
import '../../../../core/utils/window_controls_visibility.dart';
import '../../../../core/providers/device_info_provider.dart';
import '../../../../features/settings/presentation/player_settings_provider.dart';
import 'widgets/animewitcher_player_controls.dart';
import 'widgets/hotstar_player_style.dart';
import 'widgets/player_ltr.dart';
import 'player_controller.dart';
import 'player_gesture_handler.dart';

TextStyle _getSubtitleTextStyle(String? fontFamily, TextStyle baseStyle) {
  if (fontFamily == null) return baseStyle;
  switch (fontFamily.toLowerCase()) {
    case 'open sans':
      return GoogleFonts.openSans(textStyle: baseStyle);
    case 'poppins':
      return GoogleFonts.poppins(textStyle: baseStyle);
    case 'ubuntu':
      return GoogleFonts.ubuntu(textStyle: baseStyle);
    default:
      return baseStyle.copyWith(fontFamily: fontFamily);
  }
}

class PlayerScreen extends ConsumerStatefulWidget {
  final MultimediaItem item;
  final String videoUrl;
  final String? progressUrl;
  final Episode? episode;
  final StreamResult? selectedSource;

  const PlayerScreen({
    super.key,
    required this.item,
    required this.videoUrl,
    this.progressUrl,
    this.episode,
    this.selectedSource,
  });

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen>
    with WidgetsBindingObserver {
  late final Player _player;
  late final VideoController _videoController; // media_kit renderer
  late final vv.VideoController
  _videoViewController; // video_view (ExoPlayer/AVPlayer)

  final ValueNotifier<BoxFit> _videoFit = ValueNotifier(BoxFit.contain);
  // Mirrors AnimeWitcherPlayerControlsState._isVisible, fed by its
  // onVisibilityChanged callback. Starts false to match the child's
  // initial state; the child will push true once it decides controls
  // should be visible (immediately on TV; on duration-load elsewhere).
  // Used here for subtitle Y-offset computation and the TV back-to-hide
  // intercept in PopScope.
  final ValueNotifier<bool> _controlsVisible = ValueNotifier(false);

  void _syncWindowControls() {
    windowControlsHidden.value = !_controlsVisible.value;
  }

  final GlobalKey<AnimeWitcherPlayerControlsState> _controlsKeyFinal =
      GlobalKey();

  // The persistent root key handler. It always stays focusable (it is the
  // parent of the ExcludeFocus'd chrome), so when the controls hide we route
  // focus back here and the next remote/keyboard press is guaranteed to be
  // seen â the single mechanism that keeps D-pad alive after auto-hide.
  final FocusNode _rootFocusNode = FocusNode(debugLabel: 'player_root');

  // Some TVs deliver a single Back press through two channels (a goBack
  // KeyEvent *and* a route pop). This timestamp de-dupes them so one physical
  // press performs exactly one back action â see [_consumeBack].
  DateTime? _lastBackAt;

  bool _isExiting = false;
  bool _isTv = false;
  bool _isTablet = false;
  bool _wasPlayingBeforeBackground = false;
  bool _spaceHeldForSpeed = false;
  double? _speedBeforeSpaceHold;
  Timer? _spaceHoldTimer;
  Timer? _startupTimeoutTimer;

  late final PlayerController _playerController;
  ProviderSubscription<AsyncValue<PlayerSettings>>? _settingsSub;
  ProviderSubscription<PlayerState>? _playerStateSub;

  @override
  void initState() {
    super.initState();
    MediaKit.ensureInitialized();
    WidgetsBinding.instance.addObserver(this);

    // The window's caption buttons are painted over the video, so they follow
    // the player's own controls in and out of view.
    _controlsVisible.addListener(_syncWindowControls);
    _syncWindowControls();

    final deviceProfile = ref.read(deviceProfileProvider).asData?.value;
    _isTv = deviceProfile?.isTv ?? false;
    _isTablet = deviceProfile?.isTablet ?? false;

    // Full screen for the duration, through the same helper the setting uses
    // — iOS answers only one of these calls, and asking it for Android's
    // sticky mode left the bar sitting on the picture. Held, because opening
    // an episode turns the phone to landscape and the window that comes back
    // from that carries the bars in their default state.
    holdImmersiveFullScreen(true);
    WakelockPlus.enable();

    // Keep the renderer buffer bounded; mpv has its own adaptive demuxer cache.
    _player = Player(
      configuration: const PlayerConfiguration(
        bufferSize: 64 * 1024 * 1024, // 64 MB
      ),
    );

    // Increase network timeout to allow TorrServer to pre-buffer
    if (_player.platform is NativePlayer) {
      final native = _player.platform as NativePlayer;
      native.setProperty('network-timeout', '120');
      native.setProperty('force-seekable', 'yes');
      // Increase metadata probing depth to match VLC (resolves missing language tags)
      native.setProperty('demuxer-lavf-probesize', '33554432'); // 32MB
      // 30s covers the worst-case HLS segment duration; shorter values cause
      // mpv to miss video tracks in streams with 30s segments.
      native.setProperty('demuxer-lavf-analyzeduration', '30');
      // Enable verbose HLS/lavf logging in debug so variant selection and
      // segment fetch errors are visible in logcat.
      if (kDebugMode) {
        native.setProperty('msg-level', 'hls=v,lavf=v,ffmpeg/demuxer=v');
      }
      // Disable native MPV subtitle rendering on the video surface.
      // media_kit sets this at creation when libass=false, but MPV resets
      // it when a new file is opened. We re-assert it here and in
      // _applyPlaybackProperties / applySubtitleSettings as well.
      native.setProperty('sub-visibility', 'no');
    }
    _videoController = VideoController(_player);

    // Phase 8: Initialize video_view engine (ExoPlayer on Android, AVPlayer on iOS/macOS)
    _videoViewController = vv.VideoController(autoPlay: true);

    _settingsSub = ref.listenManual<AsyncValue<PlayerSettings>>(
      playerSettingsProvider,
      (_, next) {
        final settings = next.asData?.value;
        if (settings == null) return;
        if (settings.defaultResizeMode == "Zoom") {
          _videoFit.value = BoxFit.cover;
        } else if (settings.defaultResizeMode == "Stretch") {
          _videoFit.value = BoxFit.fill;
        }
      },
      fireImmediately: true,
    );

    _playerController = ref.read(playerControllerProvider.notifier);
    _playerStateSub = ref.listenManual<PlayerState>(playerControllerProvider, (
      _,
      __,
    ) {
      // The startup timeout is only for the period before the first real
      // playback frame. Once position advances, runtime buffering/source
      // switching must never be allowed to eject the user from the player.
      if (_playerController.hasConfirmedPlaybackFrame) {
        _startupTimeoutTimer?.cancel();
        _startupTimeoutTimer = null;
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _isExiting) return;
      _playerController.init(
        player: _player,
        item: widget.item,
        videoUrl: widget.videoUrl,
        progressUrl: widget.progressUrl,
        episode: widget.episode,
        selectedSource: widget.selectedSource,
        videoViewController: _videoViewController,
      );
    });

    // Do not leave the user trapped on a source that never becomes playable.
    // This timer is strictly a FIRST-FRAME timeout. It is cancelled as soon as
    // real playback is confirmed, so later buffering/retries cannot pop the route.
    _startupTimeoutTimer = Timer(const Duration(seconds: 30), () {
      if (!mounted) return;
      _startupTimeoutTimer = null;
      if (!_playerController.hasConfirmedPlaybackFrame) {
        unawaited(_handleBack());
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Desktop platforms (Windows, macOS, Linux) do not have mobile OS background
    // restrictions or socket freezes when minimized/unfocused; users expect playback
    // to continue in the background on desktop.
    if (!Platform.isAndroid && !Platform.isIOS) {
      return;
    }

    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _playerController.setAppBackgrounded(true);
      final ctrl = ref.read(playerControllerProvider);
      _wasPlayingBeforeBackground = ctrl.useExoPlayer
          ? _videoViewController.playbackState.value ==
                vv.VideoControllerPlaybackState.playing
          : _player.state.playing;
      _playerController.saveProgress();

      // Tear down any in-flight space-hold speed boost. If the user is
      // holding space (2Ã speed) and the OS backgrounds the app, the
      // KeyUp event is lost â leaving the state machine stuck with
      // _spaceHeldForSpeed=true forever. Subsequent space taps would
      // see the wrong branch. Reset speed back to whatever the user had
      // before the hold so we resume at the right rate.
      _spaceHoldTimer?.cancel();
      _spaceHoldTimer = null;
      if (_spaceHeldForSpeed) {
        final previousSpeed = _speedBeforeSpaceHold ?? 1.0;
        _spaceHeldForSpeed = false;
        _speedBeforeSpaceHold = null;
        unawaited(_playerController.setPlaybackSpeed(previousSpeed));
      }

      if (_playerController.isInPip) {
        return;
      }

      final showPip =
          ref.read(playerSettingsProvider).asData?.value.showPip ?? true;
      final isTv = ref.read(deviceProfileProvider).asData?.value.isTv ?? false;
      final allowAutoPip =
          showPip && !isTv && Platform.isAndroid && _wasPlayingBeforeBackground;
      if (allowAutoPip) {
        // Official auto-enter PiP (Android 12+) starts while the app is
        // backgrounding. Keep the stream playing so the system can snapshot
        // it; pausing here would cancel PiP.
        return;
      } else {
        _playerController.pause();
      }
    } else if (state == AppLifecycleState.resumed) {
      _playerController.setAppBackgrounded(false);
      // Wakelock: re-acquire whenever the engine is currently playing on
      // resume â not just when WE auto-paused on background. External
      // play sources (media-session play from a notification, Bluetooth
      // headphones, Android Auto) can flip playing=true while the app
      // is backgrounded; the user then foregrounds the app to a playing
      // stream with NO wakelock, and the screen sleeps during playback.
      // (H-PLAYER-4)
      final ctrl = ref.read(playerControllerProvider);
      final isCurrentlyPlaying = ctrl.useExoPlayer
          ? _videoViewController.playbackState.value ==
                vv.VideoControllerPlaybackState.playing
          : _player.state.playing;
      if (isCurrentlyPlaying) {
        WakelockPlus.enable();
      }

      // Only auto-play if we paused for backgrounding â don't override the
      // user's explicit pause-before-background intent.
      if (_wasPlayingBeforeBackground) {
        _wasPlayingBeforeBackground = false;
        WakelockPlus.enable();
        _playerController.play();
      }
    }
  }

  void _updateResizeMode(BoxFit mode) {
    if (mounted) _videoFit.value = mode;
  }

  @override
  void dispose() {
    applePersistentGlassHeaderController.hide(this);
    WidgetsBinding.instance.removeObserver(this);

    // Restore the system UI FIRST, before any disposal that could throw and
    // skip this. Full screen is set for all mobile in initState, so it must
    // always be cleared on exit (on FireTV, leaving it active also makes the
    // system swallow hardware back-button events).
    //
    // Which calls that takes, and in which order, is decided per platform in
    // immersive_mode.dart - the two phones answer different ones.
    if (Platform.isAndroid || Platform.isIOS) {
      // Orientation first, then the bars: turning the phone back to portrait
      // reconfigures the window, and asking after that change rather than
      // before it means the request is not the one being overwritten.
      if (!_isTv) {
        if (_isTablet) {
          SystemChrome.setPreferredOrientations([]);
        } else {
          SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
        }
      }
      // The bars come back. Full screen belongs to watching an episode, and
      // this is the end of one.
      applyImmersiveFullScreen(false);
    }

    _settingsSub?.close();
    _playerStateSub?.close();
    _playerController.disposeController(player: _player);

    _player.dispose();
    _videoViewController.dispose();
    _controlsVisible.removeListener(_syncWindowControls);
    windowControlsHidden.value = false;
    _controlsVisible.dispose();
    _videoFit.dispose();
    _rootFocusNode.dispose();

    WakelockPlus.disable();

    // Restore brightness if the user adjusted it via the gesture handler.
    // Without this, exiting the player leaves the device at whatever dim
    // value the user set, until they manually adjust again (audit H4).
    // Idempotent and safe on platforms without an override active.
    unawaited(ScreenBrightness().resetApplicationScreenBrightness());
    _spaceHoldTimer?.cancel();
    if (_spaceHeldForSpeed) {
      // The long-press boost is intentionally non-persistent. Both engines
      // were disposed above, so a late rate change can only fail while the
      // screen is leaving and must not be scheduled.
      _spaceHeldForSpeed = false;
      _speedBeforeSpaceHold = null;
    }
    if (!Platform.isAndroid && !Platform.isIOS) {
      try {
        windowManager.setFullScreen(false);
      } catch (e) {
        if (kDebugMode) debugPrint('PlayerScreen.dispose: $e');
      }
    }
    _startupTimeoutTimer?.cancel();
    super.dispose();
  }

  bool _isPlayActivationKey(KeyEvent event) =>
      event.logicalKey == LogicalKeyboardKey.select ||
      event.logicalKey == LogicalKeyboardKey.enter ||
      event.logicalKey == LogicalKeyboardKey.mediaPlayPause;

  /// Root key handler. Deliberately small: when a control is focused it stays
  /// out of the way so native directional traversal + the focused control's
  /// own activation run; it only acts when *no* control is focused (controls
  /// hidden / video-only) or for global media shortcuts on desktop.
  ///
  /// `primaryFocus == node` means the root node itself holds focus â i.e. no
  /// chrome control is focused. This is how we tell "hidden / video-only" from
  /// "a button is focused" without any manual focus bookkeeping.
  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    final rootHasFocus = FocusManager.instance.primaryFocus == node;

    // Escape (desktop/keyboard) â dismiss via the single guarded handler.
    // Hardware/remote Back is intentionally NOT handled here: on Android/TV it
    // is delivered reliably to PopScope (the navigation channel), and the
    // redundant goBack KeyEvent must stay unhandled so the two deliveries can't
    // both act and walk past a dismissal into exiting the player. Desktop has
    // no PopScope-back, so Escape is its dismissal key.
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      return _consumeBack() ? KeyEventResult.handled : KeyEventResult.ignored;
    }

    // Space-hold â 2Ã speed (non-TV). Only when no control is focused, so
    // Space still activates a focused button normally.
    if (!_isTv &&
        rootHasFocus &&
        event.logicalKey == LogicalKeyboardKey.space) {
      if (event is KeyDownEvent) {
        _spaceHoldTimer ??= Timer(const Duration(milliseconds: 260), () {
          if (!mounted || _spaceHeldForSpeed) return;
          _spaceHeldForSpeed = true;
          _speedBeforeSpaceHold = ref
              .read(playerControllerProvider)
              .playbackSpeed;
          unawaited(
            ref.read(playerControllerProvider.notifier).setPlaybackSpeed(2.0),
          );
          ref
              .read(playerGestureHandlerProvider.notifier)
              .showToast("2.0x", Icons.fast_forward_rounded);
        });
        return KeyEventResult.handled;
      }
      if (event is KeyRepeatEvent) {
        if (!_spaceHeldForSpeed) {
          _spaceHoldTimer?.cancel();
          _spaceHoldTimer = null;
          _spaceHeldForSpeed = true;
          _speedBeforeSpaceHold = ref
              .read(playerControllerProvider)
              .playbackSpeed;
          unawaited(
            ref.read(playerControllerProvider.notifier).setPlaybackSpeed(2.0),
          );
          ref
              .read(playerGestureHandlerProvider.notifier)
              .showToast("2.0x", Icons.fast_forward_rounded);
        }
        return KeyEventResult.handled;
      }
      if (event is KeyUpEvent) {
        _spaceHoldTimer?.cancel();
        _spaceHoldTimer = null;
        if (!_spaceHeldForSpeed) {
          _controlsKeyFinal.currentState?.togglePlayPause();
          _controlsKeyFinal.currentState?.onUserInteraction();
          return KeyEventResult.handled;
        }
        final previousSpeed = _speedBeforeSpaceHold ?? 1.0;
        _spaceHeldForSpeed = false;
        _speedBeforeSpaceHold = null;
        unawaited(
          ref
              .read(playerControllerProvider.notifier)
              .setPlaybackSpeed(previousSpeed),
        );
        ref
            .read(playerGestureHandlerProvider.notifier)
            .showToast(
              "${previousSpeed.toStringAsFixed(1).replaceAll(RegExp(r'\.0$'), '')}x",
              Icons.play_arrow_rounded,
            );
        return KeyEventResult.handled;
      }
    }

    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    // A chrome control is focused: let it activate (select/enter/space via
    // Shortcuts + Material) and let arrows drive directional traversal. On
    // desktop we still honor the media convention of â/â/â/â seeking/volume.
    if (!rootHasFocus) {
      if (!_isTv) {
        if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
          _controlsKeyFinal.currentState?.triggerSeek(true);
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
          _controlsKeyFinal.currentState?.triggerSeek(false);
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
          _controlsKeyFinal.currentState?.changeVolume(0.05);
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
          _controlsKeyFinal.currentState?.changeVolume(-0.05);
          return KeyEventResult.handled;
        }
      }
      return KeyEventResult.ignored;
    }

    // From here the root has focus â no control is focused (controls hidden
    // or video-only). On TV, if controls are visible, we recover focus.
    if (_isTv && _controlsVisible.value) {
      if (event.logicalKey == LogicalKeyboardKey.arrowUp ||
          event.logicalKey == LogicalKeyboardKey.arrowDown ||
          event.logicalKey == LogicalKeyboardKey.arrowLeft ||
          event.logicalKey == LogicalKeyboardKey.arrowRight ||
          _isPlayActivationKey(event)) {
        _controlsKeyFinal.currentState?.showControls();
        return KeyEventResult.handled;
      }
    }

    if (_isTv && !_controlsVisible.value) {
      if (event.logicalKey == LogicalKeyboardKey.goBack ||
          event.logicalKey == LogicalKeyboardKey.escape) {
        return KeyEventResult.ignored;
      }
      // First press just wakes the chrome (focus lands on play/pause). It does
      // NOT toggle playback â pressing OK again, now that play/pause is focused,
      // is what pauses/plays. (Avoids the jarring "OK pauses then shows chrome".)
      _controlsKeyFinal.currentState?.showControls();
      return KeyEventResult.handled;
    }

    // Global media shortcuts (root-focused on any platform).
    if (_isPlayActivationKey(event)) {
      _controlsKeyFinal.currentState?.togglePlayPause();
      _controlsKeyFinal.currentState?.onUserInteraction();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyM) {
      _controlsKeyFinal.currentState?.toggleMute();
      _controlsKeyFinal.currentState?.onUserInteraction();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyZ) {
      _controlsKeyFinal.currentState?.cycleResize();
      _controlsKeyFinal.currentState?.onUserInteraction();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyF) {
      _controlsKeyFinal.currentState?.toggleFullscreen();
      _controlsKeyFinal.currentState?.onUserInteraction();
      return KeyEventResult.handled;
    }

    // TV with controls already visible but focus on root (rare/transient) â
    // leave arrows for traversal.
    if (_isTv) return KeyEventResult.ignored;

    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _controlsKeyFinal.currentState?.changeVolume(0.05);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _controlsKeyFinal.currentState?.changeVolume(-0.05);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _controlsKeyFinal.currentState?.triggerSeek(true);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _controlsKeyFinal.currentState?.triggerSeek(false);
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  /// The single Back-handling decision, shared by the root key handler and
  /// PopScope. Performs at most one dismissal â close the sources panel, else
  /// (on TV, while playing) hide the controls â and de-dupes the duplicate Back
  /// delivery within a short window. Returns true when the press was consumed
  /// (the caller must NOT exit); false when there's nothing left to dismiss.
  bool _consumeBack() {
    final now = DateTime.now();
    if (_lastBackAt != null &&
        now.difference(_lastBackAt!) < const Duration(milliseconds: 200)) {
      // Near-instant duplicate delivery of the same physical press â swallow
      // it. Short enough not to eat an intentional fast double-press.
      return true;
    }
    if (_controlsKeyFinal.currentState?.isFullscreen == true) {
      _lastBackAt = now;
      unawaited(_controlsKeyFinal.currentState?.toggleFullscreen());
      return true;
    }
    final s = ref.read(playerControllerProvider);
    if (s.showEpisodeList) {
      _lastBackAt = now;
      _controlsKeyFinal.currentState?.closeActivePanel();
      return true;
    }
    if (_isTv && _controlsVisible.value) {
      final isPlaying =
          ref.read(playerControllerProvider.select((s) => s.useExoPlayer))
          ? _videoViewController.playbackState.value ==
                vv.VideoControllerPlaybackState.playing
          : _player.state.playing;
      if (isPlaying) {
        _lastBackAt = now;
        _controlsKeyFinal.currentState?.hideControls();
        return true;
      }
    }
    return false;
  }

  Future<void> _handleBack() async {
    if (!context.mounted || _isExiting) return;
    _isExiting = true;
    _startupTimeoutTimer?.cancel();
    // Invalidate startup/resume work BEFORE stop yields. A late cloud bookmark
    // must not reopen the engine after stop, or target a subsequently opened route.
    _playerController.disposeController(player: _player);

    // Silence the audio before leaving rather than relying on disposal to do
    // it. Player.dispose() reaches its own stop() only after awaiting player
    // and video-controller initialisation, all inside a lock — so a
    // synchronous dispose() can start that and return, leaving the episode
    // audible over whatever screen comes next.
    try {
      await _player.stop();
    } catch (e) {
      if (kDebugMode) debugPrint('PlayerScreen._handleBack stop: $e');
    }
    try {
      // The native engine only carries live streams, but it is closed the
      // same way rather than left to whatever teardown happens later.
      _videoViewController.close();
    } catch (e) {
      if (kDebugMode) debugPrint('PlayerScreen._handleBack close: $e');
    }

    if (!Platform.isAndroid && !Platform.isIOS) {
      try {
        await windowManager.setFullScreen(false);
        await Future<void>.delayed(const Duration(seconds: 1));
      } catch (e) {
        if (kDebugMode) debugPrint('PlayerScreen._handleBack: $e');
      }
    }

    if (mounted) context.pop();
  }

  void _publishPersistentPlayerHeader({required bool controlsVisible}) {
    if (!mounted || !appleUsesPersistentLiquidGlassHeader) return;
    final route = ModalRoute.of(context);
    if (route?.isCurrent == false) return;

    // Keep the player registered as the top persistent header owner even when
    // its chrome is hidden. During blocking startup/error screens the Flutter
    // top bar reserves space for the native iOS control, so the native back
    // button must stay visible even before normal player controls appear.
    final playerState = ref.read(playerControllerProvider);
    final showBack =
        controlsVisible ||
        playerState.uiPhase.fullscreenBlocking ||
        playerState.errorMessage != null;
    applePersistentGlassHeaderController.show(
      ApplePersistentGlassHeaderConfig(
        owner: this,
        route: route,
        onBack: showBack ? () => unawaited(_handleBack()) : null,
        backTooltip: AppLocalizations.of(context)!.goBack,
        backForegroundColor: Theme.of(context).colorScheme.primary,
        backFallbackColor: Colors.black54,
        trailingButtons: const <AppleLiquidGlassToolbarButton>[],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (appleUsesPersistentLiquidGlassHeader) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _publishPersistentPlayerHeader(controlsVisible: _controlsVisible.value);
      });
    }

    final errorMessage = ref.watch(
      playerControllerProvider.select((s) => s.errorMessage),
    );
    final isLoading = ref.watch(
      playerControllerProvider.select((s) => s.isLoading),
    );

    if (errorMessage != null) {
      return PlayerLtr(
        child: Scaffold(
          body: SafeArea(
            child: Stack(
              children: [
                Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.error_outline,
                          color: Colors.red,
                          size: 56,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          AppLocalizations.of(context)!.playbackError,
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          errorMessage,
                          style: Theme.of(context).textTheme.bodyLarge,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 24),
                        ElevatedButton.icon(
                          autofocus: true,
                          onPressed: _handleBack,
                          icon: const Icon(Icons.arrow_back),
                          label: Text(AppLocalizations.of(context)!.goBack),
                        ),
                      ],
                    ),
                  ),
                ),
                // iOS uses the single route-independent native back control.
                // Other platforms keep the existing local player affordance.
                if (!appleUsesPersistentLiquidGlassHeader)
                  Positioned(
                    top: 8,
                    left: 8,
                    child: AppleLiquidGlassBackButton(
                      size: 48,
                      foregroundColor: Colors.white,
                      fallbackColor: Colors.transparent,
                      tooltip: AppLocalizations.of(context)!.goBack,
                      onPressed: _handleBack,
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    }

    return PlayerLtr(
      child: ValueListenableBuilder<bool>(
        valueListenable: _controlsVisible,
        builder: (context, controlsVisible, _) {
          return PopScope(
            canPop: false,
            onPopInvokedWithResult: (didPop, result) async {
              if (didPop) return;
              // Single guarded path (shared with the root key handler): close the
              // sources panel, else hide TV controls. Only exit when nothing is
              // left to dismiss. The de-dupe inside prevents the dual Back
              // delivery (KeyEvent + route-pop) from skipping a step into exit.
              if (_consumeBack()) return;
              await _handleBack();
            },
            child: Scaffold(
              body: Focus(
                focusNode: _rootFocusNode,
                autofocus: true,
                onKeyEvent: _handleKey,
                // Map the TV remote OK key (select) to ActivateIntent so the
                // focused control activates natively (Enter/Space/gameButtonA are
                // already mapped by WidgetsApp). When no control is focused this
                // bubbles up to the root handler instead.
                child: Shortcuts(
                  shortcuts: const <ShortcutActivator, Intent>{
                    SingleActivator(LogicalKeyboardKey.select):
                        ActivateIntent(),
                  },
                  child: Stack(
                    children: [
                      RepaintBoundary(
                        child: ValueListenableBuilder<BoxFit>(
                          valueListenable: _videoFit,
                          builder: (_, fit, child) => Center(
                            // Phase 8: Switch engine based on stream type
                            child: Consumer(
                              builder: (context, ref, _) {
                                final useExoPlayer = ref.watch(
                                  playerControllerProvider.select(
                                    (s) => s.useExoPlayer,
                                  ),
                                );
                                if (useExoPlayer) {
                                  return vv.VideoView(
                                    controller: _videoViewController,
                                    videoFit: fit,
                                  );
                                }
                                return Video(
                                  controller: _videoController,
                                  fit: fit,
                                  subtitleViewConfiguration:
                                      const SubtitleViewConfiguration(
                                        visible: false,
                                        style: TextStyle(
                                          color: Colors.transparent,
                                        ),
                                      ),
                                  controls: (state) => const SizedBox.shrink(),
                                );
                              },
                            ),
                          ),
                        ),
                      ),
                      Consumer(
                        builder: (context, ref, _) {
                          final useExoPlayer = ref.watch(
                            playerControllerProvider.select(
                              (s) => s.useExoPlayer,
                            ),
                          );
                          if (useExoPlayer) {
                            return const SizedBox.shrink();
                          }

                          final subtitleSettings = ref
                              .watch(playerSettingsProvider)
                              .asData
                              ?.value;

                          return Positioned(
                            bottom:
                                (controlsVisible
                                    ? HotstarPlayerStyle.bottomChromeHeight
                                    : 20.0) +
                                ((100 -
                                        (subtitleSettings?.subtitlePosition ??
                                            100.0)) *
                                    (MediaQuery.sizeOf(context).height *
                                        0.008)),
                            left: 20,
                            right: 20,
                            child: SubtitleView(
                              controller: _videoController,
                              configuration: SubtitleViewConfiguration(
                                style: TextStyle(
                                  fontSize:
                                      subtitleSettings?.subtitleSize ?? 22.0,
                                  color: Color(
                                    subtitleSettings?.subtitleColor ??
                                        0xFFFFFFFF,
                                  ),
                                  backgroundColor:
                                      Color(
                                        subtitleSettings
                                                ?.subtitleBackgroundColor ??
                                            0x00000000,
                                      ).withValues(
                                        alpha:
                                            subtitleSettings
                                                ?.subtitleBackgroundOpacity ??
                                            0.0,
                                      ),
                                  shadows: const [
                                    Shadow(
                                      offset: Offset(0, 1),
                                      blurRadius: 2,
                                      color: Colors.black,
                                    ),
                                  ],
                                ),
                                padding: EdgeInsets.zero,
                              ),
                            ),
                          );
                        },
                      ),
                      Positioned.fill(
                        child: RepaintBoundary(
                          child: AnimeWitcherPlayerControls(
                            key: _controlsKeyFinal,
                            isLoading: isLoading,
                            player: _player,
                            videoViewController: _videoViewController,
                            title: widget.item.title,
                            backdropUrl: widget.item.backdropImageUrl,
                            logoUrl: widget.item.logoUrl,
                            onResize: _updateResizeMode,
                            onBackPointer: _handleBack,
                            onRequestRootFocus: () =>
                                _rootFocusNode.requestFocus(),
                            onVisibilityChanged: (v) {
                              if (!mounted) return;
                              _controlsVisible.value = v;
                              _publishPersistentPlayerHeader(
                                controlsVisible: v,
                              );
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class AnimeWitcherEmbeddedSubtitleView extends ConsumerStatefulWidget {
  final Player player;
  final bool controlsVisible;

  const AnimeWitcherEmbeddedSubtitleView({
    super.key,
    required this.player,
    required this.controlsVisible,
  });

  @override
  ConsumerState<AnimeWitcherEmbeddedSubtitleView> createState() =>
      _AnimeWitcherEmbeddedSubtitleViewState();
}

class _AnimeWitcherEmbeddedSubtitleViewState
    extends ConsumerState<AnimeWitcherEmbeddedSubtitleView> {
  bool _customFontLoaded = false;

  @override
  void initState() {
    super.initState();
    _loadCustomFontIfNeeded();
  }

  @override
  void didUpdateWidget(covariant AnimeWitcherEmbeddedSubtitleView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _loadCustomFontIfNeeded();
  }

  Future<void> _loadCustomFontIfNeeded() async {
    final settings = ref.read(playerSettingsProvider).value;
    if (settings == null) return;

    final path = settings.subTypefaceFilePath;
    if (path != null && path.isNotEmpty && !_customFontLoaded) {
      try {
        final file = File(path);
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          final fontLoader = FontLoader('CustomSubtitleFont');
          fontLoader.addFont(Future.value(ByteData.sublistView(bytes)));
          await fontLoader.load();
          if (mounted) {
            setState(() {
              _customFontLoaded = true;
            });
          }
        }
      } catch (e) {
        debugPrint("Failed to load custom font: $e");
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings =
        ref.watch(playerSettingsProvider).value ?? const PlayerSettings();

    return StreamBuilder<List<String>>(
      stream: widget.player.stream.subtitle,
      initialData: const [],
      builder: (context, snapshot) {
        final lines = snapshot.data ?? const [];
        if (lines.isEmpty) return const SizedBox.shrink();

        // Map font family
        String? fontFamily;
        const List<String> builtInFonts = [
          'Normal (system sans-serif)',
          'Trebuchet MS',
          'Netflix Sans',
          'Google Sans',
          'Open Sans',
          'Futura',
          'Consola',
          'Gotham',
          'Lucida Grande',
          'STIX General',
          'Times New Roman',
          'Verdana',
          'Ubuntu',
          'Comic Sans',
          'Poppins',
        ];

        if (settings.subTypefaceFilePath != null && _customFontLoaded) {
          fontFamily = 'CustomSubtitleFont';
        } else if (settings.subTypeface != null &&
            settings.subTypeface! >= 0 &&
            settings.subTypeface! < builtInFonts.length) {
          if (settings.subTypeface == 0) {
            fontFamily = null;
          } else {
            fontFamily = builtInFonts[settings.subTypeface!];
          }
        }

        final fontSize = settings.subFixedTextSize ?? 22.0;

        final baseStyle = TextStyle(
          fontSize: fontSize,
          fontWeight: settings.subBold ? FontWeight.bold : FontWeight.normal,
          fontStyle: settings.subItalic ? FontStyle.italic : FontStyle.normal,
          color: Color(settings.subForegroundColor),
        );

        final textStyle = _getSubtitleTextStyle(fontFamily, baseStyle);

        final edgeColor = Color(settings.subEdgeColor);

        final alignmentCode = settings.subAlignment ?? 2;
        final alignment = switch (alignmentCode) {
          1 => Alignment.bottomLeft,
          3 => Alignment.bottomRight,
          4 => Alignment.centerLeft,
          5 => Alignment.center,
          6 => Alignment.centerRight,
          7 => Alignment.topLeft,
          8 => Alignment.topCenter,
          9 => Alignment.topRight,
          _ => Alignment.bottomCenter, // 2
        };

        final crossAxisAlignment = switch (alignmentCode) {
          1 || 4 || 7 => CrossAxisAlignment.start,
          3 || 6 || 9 => CrossAxisAlignment.end,
          _ => CrossAxisAlignment.center,
        };

        final textAlign = switch (alignmentCode) {
          1 || 4 || 7 => TextAlign.left,
          3 || 6 || 9 => TextAlign.right,
          _ => TextAlign.center,
        };

        Widget buildTextLine(String line) {
          // Clean formatting tags (like HTML tags <...> or ASS tags {...})
          var cleanedLine = line
              .replaceAll(RegExp(r'<[^>]*>'), '')
              .replaceAll(RegExp(r'\{[^}]*\}'), '')
              .trim();

          if (settings.subUpperCase) {
            cleanedLine = cleanedLine.toUpperCase();
          }

          if (cleanedLine.isEmpty) return const SizedBox.shrink();

          final List<Widget> children = [];

          // Edge type outline
          if (settings.subEdgeType == 1) {
            children.add(
              Text(
                cleanedLine,
                style: textStyle.copyWith(
                  color: null,
                  foreground: Paint()
                    ..style = PaintingStyle.stroke
                    ..strokeWidth = settings.subEdgeSize ?? 2.0
                    ..color = edgeColor,
                ),
                textAlign: textAlign,
              ),
            );
          }

          List<Shadow>? shadows;
          if (settings.subEdgeType == 2) {
            shadows = [
              Shadow(
                offset: const Offset(-1, -1),
                color: edgeColor.withValues(alpha: 0.5),
              ),
              Shadow(
                offset: const Offset(1, 1),
                color: Colors.white.withValues(alpha: 0.5),
              ),
            ];
          } else if (settings.subEdgeType == 3) {
            shadows = [
              Shadow(
                offset: const Offset(2, 2),
                blurRadius: 2.0,
                color: edgeColor,
              ),
            ];
          } else if (settings.subEdgeType == 4) {
            shadows = [
              Shadow(offset: const Offset(1, 1), color: edgeColor),
              Shadow(
                offset: const Offset(2, 2),
                color: edgeColor.withValues(alpha: 0.5),
              ),
            ];
          }

          children.add(
            Text(
              cleanedLine,
              style: textStyle.copyWith(shadows: shadows),
              textAlign: textAlign,
            ),
          );

          Widget resultLine = Stack(children: children);

          final bgColor = Color(settings.subBackgroundColor);
          if (bgColor.a > 0 && settings.subBackgroundOpacity > 0) {
            final paddingVal =
                2.0 + (settings.subBackgroundRadius ?? 0.0) * 0.5;
            resultLine = Container(
              padding: EdgeInsets.symmetric(
                horizontal: paddingVal,
                vertical: 2.0,
              ),
              decoration: BoxDecoration(
                color: bgColor.withValues(alpha: settings.subBackgroundOpacity),
                borderRadius: settings.subBackgroundRadius != null
                    ? BorderRadius.circular(settings.subBackgroundRadius!)
                    : BorderRadius.zero,
              ),
              child: resultLine,
            );
          }

          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 2.0),
            child: resultLine,
          );
        }

        return Positioned.fill(
          child: SafeArea(
            top: alignment.y < 0,
            bottom: alignment.y > 0,
            child: Padding(
              padding: EdgeInsets.only(
                left: 20.0,
                right: 20.0,
                top: 0.0,
                bottom: alignment.y > 0
                    ? (widget.controlsVisible ? 60.0 : 20.0)
                    : 0.0,
              ),
              child: Align(
                alignment: alignment,
                child: Transform.translate(
                  offset: Offset(
                    0.0,
                    alignment.y >= 0
                        ? -settings.subElevation.toDouble()
                        : settings.subElevation.toDouble(),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: crossAxisAlignment,
                    children: lines.map(buildTextLine).toList(),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
