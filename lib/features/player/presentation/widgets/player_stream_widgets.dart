import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:lucide_icons_flutter/lucide_icons_200.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:media_kit/media_kit.dart';
import 'package:video_view/video_view.dart' as vv;

import '../player_controller.dart';
import '../player_gesture_handler.dart';
import '../../../../shared/widgets/custom_widgets.dart';
import '../../../settings/presentation/player_settings_provider.dart';
import 'hotstar_player_style.dart';
import 'player_control_components.dart';
import '../../../skip/data/skip_service.dart';

import 'package:animewitcher/core/utils/localized_text.dart';

/// Fades the controls and stops their progress paints after they disappear.
class PlayerChromeFade extends StatefulWidget {
  const PlayerChromeFade({
    super.key,
    required this.visible,
    required this.duration,
    required this.child,
  });

  final bool visible;
  final Duration duration;
  final Widget child;

  @override
  State<PlayerChromeFade> createState() => _PlayerChromeFadeState();
}

class _PlayerChromeFadeState extends State<PlayerChromeFade> {
  late bool _updateTimeline = widget.visible;

  @override
  void didUpdateWidget(PlayerChromeFade oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible) _updateTimeline = true;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: widget.visible ? 1.0 : 0.0,
      duration: widget.duration,
      onEnd: () {
        if (!widget.visible && _updateTimeline) {
          setState(() => _updateTimeline = false);
        }
      },
      child: _PlayerTimelineVisibility(
        updatesEnabled: _updateTimeline,
        child: widget.child,
      ),
    );
  }
}

class _PlayerTimelineVisibility extends InheritedWidget {
  const _PlayerTimelineVisibility({
    required this.updatesEnabled,
    required super.child,
  });

  final bool updatesEnabled;

  @override
  bool updateShouldNotify(_PlayerTimelineVisibility oldWidget) =>
      updatesEnabled != oldWidget.updatesEnabled;
}

/// The timeline handles clock-only updates without rebuilding the controls.
class PlayerProgressBar extends ConsumerStatefulWidget {
  final Player player;
  final vv.VideoController? videoViewController;
  final VoidCallback? onSeekStart;
  final VoidCallback? onSeekEnd;

  /// On TV the scrubber becomes a focusable element: D-pad Left/Right seek by
  /// the configured step and the thumb enlarges while focused. Off TV the
  /// slider stays pointer-only (it is reached by touch/mouse, not focus).
  final bool isTv;
  final FocusNode? focusNode;
  final VoidCallback? onArrowUp;
  final VoidCallback? onArrowDown;

  const PlayerProgressBar({
    super.key,
    required this.player,
    this.videoViewController,
    this.onSeekStart,
    this.onSeekEnd,
    this.isTv = false,
    this.focusNode,
    this.onArrowUp,
    this.onArrowDown,
  });

  @override
  ConsumerState<PlayerProgressBar> createState() => _PlayerProgressBarState();
}

class _PlayerProgressBarState extends ConsumerState<PlayerProgressBar> {
  double? _dragValue;
  late final FocusNode _scrubFocusNode;
  static const double _sliderTrackInset = 24;
  ProviderSubscription<int>? _streamIndexSub;

  @override
  void initState() {
    super.initState();
    _scrubFocusNode = widget.focusNode ?? FocusNode(debugLabel: 'scrubber');
    _watchStreamChanges();
  }

  void _watchStreamChanges() {
    // `currentStreamIndex` ticks every time the active source changes
    // (source picker, quality switch, episode autoplay). Cheap int
    // comparison; no allocations.
    _streamIndexSub = ref.listenManual<int>(
      playerControllerProvider.select((s) => s.currentStreamIndex),
      (prev, next) {
        if (prev != null && prev != next && _dragValue != null && mounted) {
          setState(() => _dragValue = null);
        }
      },
    );
  }

  @override
  void dispose() {
    _streamIndexSub?.close();
    if (widget.focusNode == null) {
      _scrubFocusNode.dispose();
    }
    super.dispose();
  }

  String _formatDuration(Duration duration) {
    final absDuration = duration.abs();
    final hours = absDuration.inHours;
    final minutes = absDuration.inMinutes.remainder(60);
    final seconds = absDuration.inSeconds.remainder(60);
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  String _formatRemaining(Duration duration, Duration position) {
    final remaining = duration - position;
    final clamped = remaining.isNegative ? Duration.zero : remaining;
    return '-${_formatDuration(clamped)}';
  }

  Widget _buildTimeHeader({
    required bool isLive,
    required bool showRemaining,
    required Duration duration,
    required Duration displayDuration,
  }) {
    if (isLive) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: _sliderTrackInset),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Container(
            height: 22,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: Colors.red.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(
                color: Colors.red.withValues(alpha: 0.45),
                width: 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.circle, color: Colors.red, size: 7),
                SizedBox(width: 5),
                Text(
                  appText(context, english: 'LIVE', arabic: 'مباشر'),
                  style: TextStyle(
                    color: Colors.red,
                    fontWeight: FontWeight.w800,
                    fontSize: 11,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final shown = showRemaining
        ? _formatRemaining(duration, displayDuration)
        : _formatDuration(displayDuration);
    final label = '$shown / ${_formatDuration(duration)}';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: _sliderTrackInset),
      child: Align(
        alignment: Alignment.centerLeft,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              ref
                  .read(playerSettingsProvider.notifier)
                  .setShowRemainingTime(!showRemaining);
            },
            child: Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                label,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.clip,
                style: const TextStyle(
                  color: HotstarPlayerStyle.primaryText,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final useExoPlayer = ref.watch(
      playerControllerProvider.select((s) => s.useExoPlayer),
    );
    final canSeek = ref.watch(
      playerControllerProvider.select((s) => s.canSeek),
    );

    final skipSegments = ref.watch(
      playerControllerProvider.select((s) => s.skipSegments),
    );

    _scrubFocusNode.canRequestFocus = widget.isTv && canSeek;
    _scrubFocusNode.skipTraversal = !(widget.isTv && canSeek);

    final videoViewController = useExoPlayer
        ? widget.videoViewController
        : null;
    final isLive = ref.watch(playerControllerProvider.select((s) => s.isLive));

    final showRemaining =
        !isLive &&
        (ref.watch(
              playerSettingsProvider.select(
                (s) => s.asData?.value.showRemainingTime,
              ),
            ) ??
            false);

    return _ProgressClock(
      // Keep the existing reset of backend-local gestures on engine switches,
      // but never remount the track on a visibility-only transition.
      key: ValueKey(videoViewController != null),
      player: widget.player,
      videoViewController: videoViewController,
      builder: (context, duration, signals) {
        final durationMs = duration.inMilliseconds.toDouble();
        final fixedPosition = _dragValue == null
            ? null
            : Duration(milliseconds: _dragValue!.toInt());
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (isLive)
              _buildTimeHeader(
                isLive: true,
                showRemaining: false,
                duration: Duration.zero,
                displayDuration: Duration.zero,
              )
            else
              _TimelineTime(
                duration: duration,
                position: signals.position,
                fixedPosition: fixedPosition,
                showRemaining: showRemaining,
                builder: (position) => _buildTimeHeader(
                  isLive: false,
                  showRemaining: showRemaining,
                  duration: duration,
                  displayDuration: position,
                ),
              ),
            SizedBox(
              height: 36,
              child: _SeekBar(
                signals: signals,
                fixedValue: _dragValue,
                durationMs: durationMs,
                min: 0.0,
                max: durationMs > 0 ? durationMs : 1.0,
                step: 30 * 1000.0, // D-pad Left/Right jump 30 seconds.
                focusNode: _scrubFocusNode,
                onArrowUp: widget.onArrowUp,
                onArrowDown: widget.onArrowDown,
                canSeek: canSeek,
                skipSegments: skipSegments,
                onChanged: canSeek
                    ? (val) => setState(() => _dragValue = val)
                    : null,
                onChangeStart: canSeek
                    ? (val) {
                        widget.onSeekStart?.call();
                        setState(() => _dragValue = val);
                      }
                    : null,
                onChangeEnd: canSeek
                    ? (val) {
                        ref
                            .read(playerControllerProvider.notifier)
                            .seekTo(Duration(milliseconds: val.toInt()));
                        widget.onSeekEnd?.call();
                        setState(() => _dragValue = null);
                      }
                    : null,
              ),
            ),
          ],
        );
      },
    );
  }
}

typedef _ProgressSignals = ({
  ValueListenable<Duration> position,
  ValueListenable<Duration> buffer,
});

/// The readout only changes at displayed-second boundaries. Unlike the
/// visual playhead this never needs to follow every backend position sample.
class _TimelineTime extends StatefulWidget {
  const _TimelineTime({
    required this.duration,
    required this.position,
    required this.fixedPosition,
    required this.showRemaining,
    required this.builder,
  });

  final Duration duration;
  final ValueListenable<Duration> position;
  final Duration? fixedPosition;
  final bool showRemaining;
  final Widget Function(Duration position) builder;

  @override
  State<_TimelineTime> createState() => _TimelineTimeState();
}

class _TimelineTimeState extends State<_TimelineTime> {
  Duration get _position => widget.fixedPosition ?? widget.position.value;

  ValueListenable<Duration>? get _livePosition =>
      widget.fixedPosition == null ? widget.position : null;

  late int _second;

  int _displayedSecond() {
    final position = _position;
    if (!widget.showRemaining) return position.inSeconds.abs();
    final remaining = widget.duration - position;
    return remaining.isNegative ? 0 : remaining.inSeconds;
  }

  void _onSample() {
    final second = _displayedSecond();
    if (_second != second) setState(() => _second = second);
  }

  @override
  void initState() {
    super.initState();
    _second = _displayedSecond();
    _livePosition?.addListener(_onSample);
  }

  @override
  void didUpdateWidget(_TimelineTime oldWidget) {
    super.didUpdateWidget(oldWidget);
    final previous = oldWidget.fixedPosition == null
        ? oldWidget.position
        : null;
    final next = _livePosition;
    if (previous != next) {
      previous?.removeListener(_onSample);
      next?.addListener(_onSample);
    }
    _second = _displayedSecond();
  }

  @override
  void dispose() {
    _livePosition?.removeListener(_onSample);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(_position);
}

/// Listens to the backend clock only while the chrome can be seen.
/// Reopening it reads the current snapshot without waiting for a new backend
/// event (e.g. paused playback). Gesture state stays mounted, and other
/// playback listeners are independent.
class _ProgressClock extends StatefulWidget {
  const _ProgressClock({
    super.key,
    required this.player,
    required this.videoViewController,
    required this.builder,
  });

  final Player player;
  final vv.VideoController? videoViewController;
  final Widget Function(
    BuildContext context,
    Duration duration,
    _ProgressSignals signals,
  )
  builder;

  @override
  State<_ProgressClock> createState() => _ProgressClockState();
}

class _ProgressClockState extends State<_ProgressClock> {
  final _subscriptions = <StreamSubscription<Duration>>[];
  Duration _duration = Duration.zero;
  // Position ticks must not invalidate buffered geometry (or vice versa).
  // Keep each signal stable across ticks, and supply the same snapshots to
  // independently painted track parts.
  final _position = ValueNotifier(Duration.zero);
  final _buffer = ValueNotifier(Duration.zero);
  late final _ProgressSignals _signals = (position: _position, buffer: _buffer);
  bool _listening = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncListening();
  }

  @override
  void didUpdateWidget(_ProgressClock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoViewController != widget.videoViewController ||
        (widget.videoViewController == null &&
            oldWidget.player != widget.player)) {
      _detach(oldWidget);
      _syncListening();
    }
  }

  void _syncListening() {
    final enabled =
        context
            .dependOnInheritedWidgetOfExactType<_PlayerTimelineVisibility>()
            ?.updatesEnabled ??
        true;
    if (enabled == _listening) return;
    if (enabled) {
      _attach();
    } else {
      _detach(widget);
    }
  }

  void _attach() {
    _listening = true;
    final controller = widget.videoViewController;
    if (controller != null) {
      _duration = Duration(
        milliseconds: controller.mediaInfo.value?.duration ?? 0,
      );
      _position.value = Duration(milliseconds: controller.position.value);
      _buffer.value = Duration.zero;
      controller.position.addListener(_onVideoViewUpdate);
      controller.mediaInfo.addListener(_onVideoViewUpdate);
      return;
    }

    final state = widget.player.state;
    _duration = state.duration;
    _position.value = state.position;
    _buffer.value = state.buffer;
    final stream = widget.player.stream;
    _listen(stream.position, (value) => _position.value = value);
    _listen(stream.duration, _setDuration);
    _listen(stream.buffer, (value) => _buffer.value = value);
  }

  void _listen(Stream<Duration> stream, ValueChanged<Duration> save) {
    _subscriptions.add(
      stream.listen(
        save,
        onError: (Object _, StackTrace _) => save(Duration.zero),
      ),
    );
  }

  void _setDuration(Duration duration) {
    if (_duration != duration) setState(() => _duration = duration);
  }

  void _onVideoViewUpdate() {
    final controller = widget.videoViewController!;
    _setDuration(
      Duration(milliseconds: controller.mediaInfo.value?.duration ?? 0),
    );
    _position.value = Duration(milliseconds: controller.position.value);
  }

  void _detach(_ProgressClock oldWidget) {
    if (!_listening) return;
    _listening = false;
    oldWidget.videoViewController?.position.removeListener(_onVideoViewUpdate);
    oldWidget.videoViewController?.mediaInfo.removeListener(_onVideoViewUpdate);
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
  }

  @override
  void dispose() {
    _detach(widget);
    _position.dispose();
    _buffer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, _duration, _signals);
}

class PlayerPlayPauseButton extends StatelessWidget {
  final Player player;
  final vv.VideoController? videoViewController;
  final bool isLoading;
  final bool isTv;
  final double size;
  final FocusNode? focusNode;
  final VoidCallback? onPressed;

  /// When false the button shows the play/pause icon even while buffering — the
  /// buffering state is surfaced by the centered [PlayerBufferingIndicator]
  /// instead. Used for the corner button on desktop/TV so the spinner isn't
  /// hidden away where it's easy to miss.
  final bool showBufferingSpinner;

  /// The glyph's own size, when it should differ from the button's circle.
  ///
  /// The transport row draws play, back and forward at one size and gives
  /// each a target wider than the mark.
  final double? iconSize;

  /// The glyph's colour. The row that carries the transport paints it in the
  /// app's accent; the centred touch button stays white over the picture.
  ///
  /// [hoverColor] is what it becomes under a pointer, if anything.
  final Color? foregroundColor;
  final Color? hoverColor;

  const PlayerPlayPauseButton({
    super.key,
    required this.player,
    this.videoViewController,
    this.isLoading = false,
    this.isTv = false,
    this.size = 82,
    this.iconSize,
    this.foregroundColor,
    this.hoverColor,
    this.focusNode,
    this.onPressed,
    this.showBufferingSpinner = true,
  });

  @override
  Widget build(BuildContext context) {
    return Consumer(
      builder: (context, ref, _) {
        final isBuffering =
            ref.watch(playerControllerProvider.select((s) => s.isBuffering)) &&
            showBufferingSpinner;
        final useExoPlayer = ref.watch(
          playerControllerProvider.select((s) => s.useExoPlayer),
        );

        if (useExoPlayer && videoViewController != null) {
          return ListenableBuilder(
            listenable: videoViewController!.playbackState,
            builder: (context, _) {
              final isPlaying =
                  videoViewController!.playbackState.value ==
                  vv.VideoControllerPlaybackState.playing;
              return _buildButton(
                isPlaying: isPlaying,
                isSpinning: isBuffering,
              );
            },
          );
        }

        return StreamBuilder<bool>(
          stream: player.stream.playing,
          initialData: player.state.playing,
          builder: (context, snapshot) {
            return _buildButton(
              isPlaying: snapshot.data ?? false,
              isSpinning: isBuffering,
            );
          },
        );
      },
    );
  }

  Widget _buildButton({required bool isPlaying, required bool isSpinning}) {
    return CustomButton(
      focusNode: focusNode,
      onPressed: onPressed ?? () => player.playOrPause(),
      showFocusHighlight: isTv,
      shape: const CircleBorder(),
      child: SizedBox(
        width: size,
        height: size,
        child: Center(
          child: isSpinning
              ? const _PlayerSpinner()
              : _HoverTintedIcon(
                  icon: isPlaying ? LucideIcons200.pause : LucideIcons200.play,
                  color: foregroundColor ?? Colors.white,
                  hoverColor: hoverColor,
                  size: iconSize ?? size * 0.88,
                ),
        ),
      ),
    );
  }
}

/// ±10s seek button shown beside [PlayerPlayPauseButton] in the touch
/// centered overlay. The desktop/TV control row uses [PlayerIconButton]
/// for the same action instead, to match the rest of that row's buttons.
class PlayerSeekButton extends StatelessWidget {
  final bool forward;
  final int seconds;
  final String tooltip;
  final VoidCallback onPressed;
  final double size;

  const PlayerSeekButton({
    super.key,
    required this.forward,
    required this.seconds,
    required this.tooltip,
    required this.onPressed,
    this.size = 52,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: CustomButton(
        onPressed: onPressed,
        shape: const CircleBorder(),
        child: SizedBox(
          width: size,
          height: size,
          child: Center(
            child: SeekIcon(
              forward: forward,
              seconds: seconds,
              size: size * 0.55,
            ),
          ),
        ),
      ),
    );
  }
}

/// Persistent speaker icon + slider for mouse-driven desktop control rows —
/// touch and TV keep their existing swipe/hardware volume handling, so this
/// is only used on desktop where hover+drag makes sense.
class PlayerVolumeControl extends ConsumerStatefulWidget {
  const PlayerVolumeControl({super.key});

  @override
  ConsumerState<PlayerVolumeControl> createState() =>
      _PlayerVolumeControlState();
}

class _PlayerVolumeControlState extends ConsumerState<PlayerVolumeControl> {
  double? _volume;
  double? _dragValue;
  double _lastNonZero = 1.0;

  /// A level waiting for the engine to finish taking the previous one.
  ///
  /// A drag produces changes far faster than the engine can accept them, and
  /// the point of following the drag is that the sound moves with the pointer.
  /// Queueing every step would fall further behind the longer the drag ran,
  /// so only the newest is kept and everything it overtook is dropped.
  double? _pendingLevel;
  bool _committing = false;
  int _refreshSerial = 0;

  /// Device volume uses the same range regardless of the playback engine.
  double get _maxVolume =>
      ref.read(playerControllerProvider).supportsVolumeBoost ? 2.0 : 1.0;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    final serial = ++_refreshSerial;
    try {
      final level = await ref
          .read(playerControllerProvider.notifier)
          .getVolumeLevel();
      if (!mounted ||
          serial != _refreshSerial ||
          _committing ||
          _dragValue != null) {
        return;
      }
      final clamped = level.clamp(0.0, _maxVolume);
      setState(() {
        _volume = clamped;
        if (clamped > 0) _lastNonZero = clamped;
      });
    } catch (_) {
      if (!mounted || serial != _refreshSerial) return;
      ref
          .read(playerGestureHandlerProvider.notifier)
          .showToast('تعذّر قراءة صوت الجهاز', Icons.error_outline);
    }
  }

  Future<void> _commit(double value) async {
    _refreshSerial++;
    if (_committing) {
      _pendingLevel = value;
      return;
    }
    _committing = true;
    try {
      var next = value;
      while (true) {
        if (!mounted) return;
        await ref.read(playerControllerProvider.notifier).setVolumeLevel(next);
        final queued = _pendingLevel;
        if (queued == null) {
          if (_dragValue == null) unawaited(_refresh());
          return;
        }
        _pendingLevel = null;
        next = queued;
      }
    } catch (_) {
      _pendingLevel = null;
      if (!mounted) return;
      setState(() => _dragValue = null);
      unawaited(_refresh());
      ref
          .read(playerGestureHandlerProvider.notifier)
          .showToast('تعذّر تغيير صوت الجهاز', Icons.error_outline);
    } finally {
      _committing = false;
    }
  }

  void _toggleMute() {
    final current = _dragValue ?? _volume ?? 1.0;
    final target = current > 0 ? 0.0 : _lastNonZero;
    setState(() {
      _volume = target;
      _dragValue = null;
    });
    unawaited(_commit(target));
  }

  IconData _iconFor(double value) =>
      value <= 0.0 ? LucideIcons200.volumeX : LucideIcons200.volume2;

  /// Where on the track the recording's own level sits.
  ///
  /// Not proportional: with amplification available, the range a viewer
  /// actually adjusts in — silence to full — takes the first 60% of the
  /// track and the gain beyond it shares the rest. A linear split would put
  /// every ordinary level in the left half of a short slider.
  static const double _normalFraction = 0.6;

  double _fractionFor(double value, double maxVolume) {
    if (maxVolume <= 1.0) return (value / maxVolume).clamp(0.0, 1.0);
    if (value <= 1.0) return (value * _normalFraction).clamp(0.0, 1.0);
    return (_normalFraction +
            ((value - 1.0) / (maxVolume - 1.0)) * (1 - _normalFraction))
        .clamp(0.0, 1.0);
  }

  double _valueFor(double fraction, double maxVolume) {
    final f = fraction.clamp(0.0, 1.0);
    if (maxVolume <= 1.0) return f * maxVolume;
    if (f <= _normalFraction) return (f / _normalFraction).clamp(0.0, 1.0);
    return 1.0 +
        ((f - _normalFraction) / (1 - _normalFraction)) * (maxVolume - 1.0);
  }

  /// White until the recording's own level, then warming through amber into
  /// red — the further past it, the hotter.
  Color _boostColor(double value, double maxVolume) {
    if (value <= 1.0 || maxVolume <= 1.0) return Colors.white;
    final t = ((value - 1.0) / (maxVolume - 1.0)).clamp(0.0, 1.0);
    return Color.lerp(const Color(0xFFF97316), const Color(0xFFDC2626), t)!;
  }

  // Icons the gesture handler's OSD uses for a volume (not brightness)
  // change - keyboard shortcuts and scroll/swipe volume adjustments only
  // surface through that OSD state, so this is how the slider notices them.
  static final Set<IconData> _volumeOsdIcons = {
    Icons.volume_off,
    Icons.volume_mute,
    Icons.volume_down,
    Icons.volume_up,
    Icons.campaign,
  };

  @override
  Widget build(BuildContext context) {
    ref.listen<PlayerGestureState>(playerGestureHandlerProvider, (
      previous,
      next,
    ) {
      if (_dragValue != null) return; // don't fight an active drag
      if (!next.showOSD || next.osdValue == null) return;
      if (!_volumeOsdIcons.contains(next.osdIcon)) return;
      final clamped = next.osdValue!.clamp(0.0, _maxVolume);
      setState(() {
        _volume = clamped;
        if (clamped > 0) _lastNonZero = clamped;
      });
    });

    // Keep listening to the ceiling, not to unrelated playback state.
    final supportsBoost = ref.watch(
      playerControllerProvider.select((state) => state.supportsVolumeBoost),
    );
    final maxVolume = supportsBoost ? 2.0 : 1.0;
    final display = (_dragValue ?? _volume ?? 1.0).clamp(0.0, maxVolume);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        PlayerIconButton(
          icon: _iconFor(display),
          tooltip: appText(context, english: 'Mute', arabic: 'كتم الصوت'),
          onPressed: _toggleMute,
        ),
        // Held left to right so the track fills away from the speaker in
        // Arabic too, the way a level reads.
        Directionality(
          textDirection: TextDirection.ltr,
          child: Tooltip(
            message: '${(display * 100).round()}%',
            child: _VolumeTrack(
              fraction: _fractionFor(display, maxVolume),
              boostFraction: maxVolume > 1.0 ? _normalFraction : 1.0,
              boostColor: _boostColor(display, maxVolume),
              boosting: display > 1.0,
              onFraction: (fraction) {
                final value = _valueFor(fraction, maxVolume);
                setState(() => _dragValue = value);
                // The sound follows the pointer rather than waiting for it to
                // be let go.
                unawaited(_commit(value));
              },
              onFractionEnd: (fraction) {
                final value = _valueFor(fraction, maxVolume);
                setState(() {
                  _volume = value;
                  if (value > 0) _lastNonZero = value;
                  _dragValue = null;
                });
                unawaited(_commit(value));
              },
            ),
          ),
        ),
        if (display > 1.0) ...[
          const SizedBox(width: 8),
          Text(
            '${(display * 100).round()}%',
            style: TextStyle(
              color: _boostColor(display, maxVolume),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ],
    );
  }
}

class _PlayerSpinner extends StatelessWidget {
  const _PlayerSpinner();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: 42,
      height: 42,
      child: CircularProgressIndicator(color: Colors.white, strokeWidth: 3.5),
    );
  }
}

class PlayerBufferingIndicator extends StatelessWidget {
  final bool isVisible;

  /// On touch the play/pause button lives in the screen centre and shows its
  /// own spinner, so this indicator is suppressed while the controls are
  /// visible. On desktop/TV the play/pause button is in the corner, so the
  /// centered indicator stays shown even with controls visible — otherwise a
  /// stall is easy to miss.
  final bool isTouch;

  const PlayerBufferingIndicator({
    super.key,
    this.isVisible = false,
    this.isTouch = false,
  });

  @override
  Widget build(BuildContext context) {
    return Consumer(
      builder: (context, ref, _) {
        final isBuffering = ref.watch(
          playerControllerProvider.select((s) => s.isBuffering),
        );
        final isLoading = ref.watch(
          playerControllerProvider.select((s) => s.isLoading),
        );

        if (!isBuffering && !isLoading) return const SizedBox.shrink();
        // Touch + controls visible → the centered play/pause spinner covers it.
        if (isVisible && isTouch) return const SizedBox.shrink();
        // While the blocking loading UI is up, defer to it.
        if (isLoading) return const SizedBox.shrink();

        return const IgnorePointer(child: Center(child: _PlayerSpinner()));
      },
    );
  }
}

class _TrackInterval {
  final double start;
  final double end;
  final bool isSkipSegment;

  _TrackInterval({
    required this.start,
    required this.end,
    required this.isSkipSegment,
  });
}

class _SeekBar extends StatefulWidget {
  final _ProgressSignals signals;
  final double? fixedValue;
  final double durationMs;
  final double min;
  final double max;
  final double step;
  final FocusNode? focusNode;
  final VoidCallback? onArrowUp;
  final VoidCallback? onArrowDown;
  final bool canSeek;
  final List<SkipSegment> skipSegments;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeStart;
  final ValueChanged<double>? onChangeEnd;

  const _SeekBar({
    required this.signals,
    required this.fixedValue,
    required this.durationMs,
    required this.min,
    required this.max,
    required this.step,
    this.focusNode,
    this.onArrowUp,
    this.onArrowDown,
    required this.canSeek,
    required this.skipSegments,
    this.onChanged,
    this.onChangeStart,
    this.onChangeEnd,
  });

  double get value =>
      (fixedValue ?? signals.position.value.inMilliseconds.toDouble()).clamp(
        min,
        max,
      );

  _TrackMotion motion(double width) => (
    signals: signals,
    fixedValue: fixedValue,
    min: min,
    max: max,
    durationMs: durationMs,
    width: width,
  );

  @override
  State<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<_SeekBar> {
  late final FocusNode _focusNode;
  bool _isFocused = false;
  bool _isDragging = false;
  Timer? _seekCommitTimer;
  late final VoidCallback _focusListener;

  bool _isTrackHovered = false;
  double _hoverX = 0.0;
  double? _lastDragValue;

  @override
  void initState() {
    super.initState();
    _focusNode = widget.focusNode ?? FocusNode();
    _focusListener = () {
      if (mounted) setState(() => _isFocused = _focusNode.hasFocus);
    };
    _focusNode.addListener(_focusListener);
  }

  @override
  void dispose() {
    _seekCommitTimer?.cancel();
    _focusNode.removeListener(_focusListener);
    if (widget.focusNode == null) {
      _focusNode.dispose();
    }
    super.dispose();
  }

  void _handleDpadSeek(double newValue) {
    if (!_isDragging) {
      setState(() {
        _isDragging = true;
      });
      widget.onChangeStart?.call(newValue);
    }
    widget.onChanged?.call(newValue);

    _seekCommitTimer?.cancel();
    _seekCommitTimer = Timer(const Duration(milliseconds: 500), () {
      widget.onChangeEnd?.call(newValue);
      setState(() {
        _isDragging = false;
      });
    });
  }

  double _getValueFromOffset(double localX, double trackWidth) {
    if (trackWidth <= 0) return widget.min;
    final ratio = (localX / trackWidth).clamp(0.0, 1.0);
    return widget.min + ratio * (widget.max - widget.min);
  }

  String _formatDuration(double ms) {
    if (ms.isNaN || ms.isInfinite) return '0:00';
    final duration = Duration(milliseconds: ms.toInt());
    final int hours = duration.inHours;
    final int minutes = duration.inMinutes.remainder(60);
    final int seconds = duration.inSeconds.remainder(60);

    final String secondsStr = seconds.toString().padLeft(2, '0');
    if (hours > 0) {
      final String minutesStr = minutes.toString().padLeft(2, '0');
      return '$hours:$minutesStr:$secondsStr';
    } else {
      return '$minutes:$secondsStr';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      canRequestFocus: widget.canSeek,
      skipTraversal: !widget.canSeek,
      onKeyEvent: (node, event) {
        if (!widget.canSeek) return KeyEventResult.ignored;
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
          return KeyEventResult.ignored;
        }

        final logicalKey = event.logicalKey;

        // Left arrow: decrease value
        if (logicalKey == LogicalKeyboardKey.arrowLeft) {
          final newValue = (widget.value - widget.step).clamp(
            widget.min,
            widget.max,
          );
          if (newValue != widget.value) {
            _handleDpadSeek(newValue);
          }
          return KeyEventResult.handled;
        }

        // Right arrow: increase value
        if (logicalKey == LogicalKeyboardKey.arrowRight) {
          final newValue = (widget.value + widget.step).clamp(
            widget.min,
            widget.max,
          );
          if (newValue != widget.value) {
            _handleDpadSeek(newValue);
          }
          return KeyEventResult.handled;
        }

        // Up arrow: move focus up
        if (logicalKey == LogicalKeyboardKey.arrowUp) {
          if (widget.onArrowUp != null) {
            widget.onArrowUp!();
            return KeyEventResult.handled;
          }
          final success = _focusNode.focusInDirection(TraversalDirection.up);
          if (!success) {
            _focusNode.previousFocus();
          }
          return KeyEventResult.handled;
        }

        // Down arrow: move focus down
        if (logicalKey == LogicalKeyboardKey.arrowDown) {
          if (widget.onArrowDown != null) {
            widget.onArrowDown!();
            return KeyEventResult.handled;
          }
          final success = _focusNode.focusInDirection(TraversalDirection.down);
          if (!success) {
            _focusNode.nextFocus();
          }
          return KeyEventResult.handled;
        }

        return KeyEventResult.ignored;
      },
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          border: _isFocused
              ? Border.all(
                  color: Theme.of(context).colorScheme.primary,
                  width: 2,
                )
              : Border.all(color: Colors.transparent, width: 2),
        ),
        padding: EdgeInsets.symmetric(
          horizontal: _isFocused ? 6.0 : 8.0,
          vertical: _isFocused ? 2.0 : 4.0,
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final trackWidth = constraints.maxWidth;
            final motion = widget.motion(trackWidth);
            final progressWidth = _trackExtent(motion, buffered: false);

            // Calculate track intervals based on skip segments
            final List<_TrackInterval> intervals = [];
            if (widget.max <= widget.min || widget.skipSegments.isEmpty) {
              intervals.add(
                _TrackInterval(
                  start: 0.0,
                  end: trackWidth,
                  isSkipSegment: false,
                ),
              );
            } else {
              final List<_TrackInterval> rawIntervals = [];
              for (final seg in widget.skipSegments) {
                final double startMs = seg.startTime * 1000.0;
                final double endMs = seg.endTime * 1000.0;
                final double startRatio = (startMs / (widget.max - widget.min))
                    .clamp(0.0, 1.0);
                final double endRatio = (endMs / (widget.max - widget.min))
                    .clamp(0.0, 1.0);
                if (startRatio < endRatio) {
                  rawIntervals.add(
                    _TrackInterval(
                      start: startRatio * trackWidth,
                      end: endRatio * trackWidth,
                      isSkipSegment: true,
                    ),
                  );
                }
              }

              rawIntervals.sort((a, b) => a.start.compareTo(b.start));

              double currentX = 0.0;
              for (final seg in rawIntervals) {
                if (seg.start > currentX) {
                  intervals.add(
                    _TrackInterval(
                      start: currentX,
                      end: seg.start,
                      isSkipSegment: false,
                    ),
                  );
                }
                final double segStart = seg.start.clamp(currentX, trackWidth);
                final double segEnd = seg.end.clamp(segStart, trackWidth);
                if (segStart < segEnd) {
                  intervals.add(
                    _TrackInterval(
                      start: segStart,
                      end: segEnd,
                      isSkipSegment: true,
                    ),
                  );
                  currentX = segEnd;
                }
              }
              if (currentX < trackWidth) {
                intervals.add(
                  _TrackInterval(
                    start: currentX,
                    end: trackWidth,
                    isSkipSegment: false,
                  ),
                );
              }
            }

            // Adjust intervals to introduce a 2px visual gap (seam)
            final List<_TrackInterval> visualIntervals = [];
            for (final interval in intervals) {
              double start = interval.start;
              double end = interval.end;
              if (start > 0.0) {
                start += 1.0;
              }
              if (end < trackWidth) {
                end -= 1.0;
              }
              if (start < end) {
                visualIntervals.add(
                  _TrackInterval(
                    start: start,
                    end: end,
                    isSkipSegment: interval.isSkipSegment,
                  ),
                );
              }
            }

            // Precompute heights for each interval depending on hover position
            final List<double> intervalHeights = [];
            for (final interval in visualIntervals) {
              final bool isIntervalHovered =
                  (_isTrackHovered || _isDragging) &&
                  _hoverX >= interval.start &&
                  _hoverX <= interval.end;
              intervalHeights.add(isIntervalHovered ? 7.0 : 5.0);
            }

            // Thumb grows (but stays a round handle) while hovering anywhere
            // on the track or actively dragging — always visible at rest so
            // the scrubber reads as a persistent handle rather than a marker
            // that only appears on interaction.
            final bool isMorphed = _isDragging || _isTrackHovered;

            final double thumbWidth;
            final double thumbHeight;
            final double thumbRadius;
            final double thumbOpacity;

            if (isMorphed) {
              thumbWidth = 18.0;
              thumbHeight = 18.0;
              thumbRadius = 9.0;
              thumbOpacity = 1.0;
            } else if (_isFocused) {
              thumbWidth = 16.0;
              thumbHeight = 16.0;
              thumbRadius = 8.0;
              thumbOpacity = 1.0;
            } else {
              thumbWidth = 14.0;
              thumbHeight = 14.0;
              thumbRadius = 7.0;
              thumbOpacity = 1.0;
            }

            return MouseRegion(
              onEnter: (_) {
                if (widget.canSeek) {
                  setState(() => _isTrackHovered = true);
                }
              },
              onExit: (_) {
                setState(() {
                  _isTrackHovered = false;
                  _hoverX = 0.0;
                });
              },
              onHover: (event) {
                if (widget.canSeek) {
                  setState(() => _hoverX = event.localPosition.dx);
                }
              },
              cursor: widget.canSeek
                  ? SystemMouseCursors.click
                  : SystemMouseCursors.basic,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragStart: widget.canSeek
                    ? (details) {
                        setState(() {
                          _isDragging = true;
                          _hoverX = details.localPosition.dx;
                        });
                        final val = _getValueFromOffset(
                          details.localPosition.dx,
                          trackWidth,
                        );
                        _lastDragValue = val;
                        widget.onChangeStart?.call(val);
                      }
                    : null,
                onHorizontalDragUpdate: widget.canSeek
                    ? (details) {
                        setState(() {
                          _hoverX = details.localPosition.dx;
                        });
                        final val = _getValueFromOffset(
                          details.localPosition.dx,
                          trackWidth,
                        );
                        _lastDragValue = val;
                        widget.onChanged?.call(val);
                      }
                    : null,
                onHorizontalDragEnd: widget.canSeek
                    ? (details) {
                        setState(() {
                          _isDragging = false;
                        });
                        widget.onChangeEnd?.call(
                          _lastDragValue ?? widget.value,
                        );
                      }
                    : null,
                onTapDown: widget.canSeek
                    ? (details) {
                        final val = _getValueFromOffset(
                          details.localPosition.dx,
                          trackWidth,
                        );
                        widget.onChangeStart?.call(val);
                        widget.onChanged?.call(val);
                        widget.onChangeEnd?.call(val);
                      }
                    : null,
                child: Container(
                  height: 36.0,
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 12.0),
                  child: Stack(
                    alignment: Alignment.centerLeft,
                    clipBehavior: Clip.none,
                    children: [
                      // 1. Track Background segments
                      for (int i = 0; i < visualIntervals.length; i++)
                        Positioned(
                          left: visualIntervals[i].start,
                          width:
                              visualIntervals[i].end - visualIntervals[i].start,
                          child: Align(
                            alignment: Alignment.center,
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 150),
                              curve: const Cubic(0.4, 0.0, 0.2, 1.0),
                              height: intervalHeights[i],
                              width: double.infinity,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(4.0),
                                color: visualIntervals[i].isSkipSegment
                                    ? HotstarPlayerStyle.skipSegment.withValues(
                                        alpha: 0.35,
                                      )
                                    : const Color(
                                        0x4DCFDEF6,
                                      ), // rgba(207, 222, 246, 0.30)
                              ),
                            ),
                          ),
                        ),

                      // These fills keep their layout. Only their clip changes
                      // on a position/buffer event.
                      for (final buffered in const [true, false])
                        for (var i = 0; i < visualIntervals.length; i++)
                          _buildIntervalFill(
                            visualIntervals[i],
                            motion,
                            intervalHeights[i],
                            buffered: buffered,
                          ),

                      // 3.5 Hover Vertical Line (only when hovered and not dragging)
                      if (_isTrackHovered && !_isDragging)
                        (() {
                          final int hoveredIntervalIndex = visualIntervals
                              .indexWhere(
                                (interval) =>
                                    _hoverX >= interval.start &&
                                    _hoverX <= interval.end,
                              );
                          final double height = hoveredIntervalIndex != -1
                              ? intervalHeights[hoveredIntervalIndex]
                              : 8.0;

                          return Positioned(
                            left: _hoverX,
                            child: FractionalTranslation(
                              translation: const Offset(-0.5, 0.0),
                              child: Align(
                                alignment: Alignment.center,
                                child: Container(
                                  width: 1.5,
                                  height: height,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          );
                        }()),

                      // 3.6 Hover/Drag Timestamp Tooltip (visible on hover and during active drag)
                      if (_isTrackHovered || _isDragging)
                        (() {
                          final double tooltipPositionX =
                              (_isDragging && _hoverX == 0.0)
                              ? progressWidth
                              : _hoverX;

                          return Positioned(
                            left: tooltipPositionX.clamp(
                              20.0,
                              trackWidth - 20.0,
                            ),
                            top: -38.0, // Float higher above the seek bar
                            child: FractionalTranslation(
                              translation: const Offset(-0.5, 0.0),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10.0,
                                  vertical: 5.0,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(
                                    0xE61A1A1A,
                                  ), // rgba(26, 26, 26, 0.9) - dark grey
                                  borderRadius: BorderRadius.circular(
                                    16.0,
                                  ), // Pill shape
                                  border: Border.all(
                                    color: Colors.white.withValues(alpha: 0.15),
                                    width: 0.5,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(
                                        alpha: 0.25,
                                      ),
                                      blurRadius: 4.0,
                                      offset: const Offset(0.0, 2.0),
                                    ),
                                  ],
                                ),
                                child: Text(
                                  _formatDuration(
                                    _getValueFromOffset(
                                      tooltipPositionX,
                                      trackWidth,
                                    ),
                                  ),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 11.0,
                                    fontWeight: FontWeight.w700,
                                    fontFeatures: [
                                      FontFeature.tabularFigures(),
                                    ], // Tabular/monospace figures
                                    height: 1.0,
                                  ),
                                ),
                              ),
                            ),
                          );
                        }()),

                      // The thumb also follows the clock in paint. Its
                      // independently animated hover/focus size is unchanged.
                      if (widget.canSeek)
                        Positioned(
                          left: 0,
                          child: IgnorePointer(
                            child: _PlayheadOffset(
                              motion: motion,
                              child: FractionalTranslation(
                                translation: const Offset(-0.5, 0.0),
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 150),
                                  curve: const Cubic(0.4, 0.0, 0.2, 1.0),
                                  width: thumbWidth,
                                  height: thumbHeight,
                                  decoration: BoxDecoration(
                                    color: Theme.of(context).colorScheme.primary
                                        .withValues(alpha: thumbOpacity),
                                    borderRadius: BorderRadius.circular(
                                      thumbRadius,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildIntervalFill(
    _TrackInterval interval,
    _TrackMotion motion,
    double height, {
    required bool buffered,
  }) {
    return Positioned(
      left: interval.start,
      width: interval.end - interval.start,
      child: Align(
        alignment: Alignment.center,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          curve: const Cubic(0.4, 0.0, 0.2, 1.0),
          height: height,
          width: double.infinity,
          child: ClipRRect(
            clipper: _TimelineClipper(
              motion,
              interval.start,
              buffered: buffered,
            ),
            child: ColoredBox(
              color: buffered
                  ? Colors.white.withValues(alpha: 0.25)
                  : interval.isSkipSegment
                  ? HotstarPlayerStyle.skipSegment
                  : Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
      ),
    );
  }
}

/// Stable seek geometry; its signals change paint, not widget layout.
typedef _TrackMotion = ({
  _ProgressSignals signals,
  double? fixedValue,
  double min,
  double max,
  double durationMs,
  double width,
});

extension on _TrackMotion {
  // A drag or D-pad preview has a fixed playhead. Playback still updates
  // its snapshot, but it can no longer change that playhead's pixels.
  ValueListenable<Duration>? get livePlayhead =>
      fixedValue == null ? signals.position : null;
}

double _trackExtent(_TrackMotion motion, {required bool buffered}) {
  if (buffered) {
    return motion.durationMs > 0
        ? (motion.signals.buffer.value.inMilliseconds / motion.durationMs)
                  .clamp(0.0, 1.0) *
              motion.width
        : 0.0;
  }
  final value =
      motion.fixedValue ?? motion.signals.position.value.inMilliseconds;
  final range = motion.max - motion.min;
  return range > 0
      ? ((value - motion.min) / range).clamp(0.0, 1.0) * motion.width
      : 0.0;
}

class _TimelineClipper extends CustomClipper<RRect> {
  _TimelineClipper(this.motion, this.start, {required this.buffered})
    : super(reclip: buffered ? motion.signals.buffer : motion.livePlayhead);

  final _TrackMotion motion;
  final double start;
  final bool buffered;

  @override
  RRect getClip(Size size) {
    final width = (_trackExtent(motion, buffered: buffered) - start).clamp(
      0.0,
      size.width,
    );
    return RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, width, size.height),
      const Radius.circular(4),
    );
  }

  @override
  bool shouldReclip(_TimelineClipper oldClipper) =>
      oldClipper.motion != motion ||
      oldClipper.start != start ||
      oldClipper.buffered != buffered;
}

class _PlayheadOffset extends SingleChildRenderObjectWidget {
  const _PlayheadOffset({required this.motion, required super.child});

  final _TrackMotion motion;

  @override
  _RenderPlayheadOffset createRenderObject(BuildContext context) =>
      _RenderPlayheadOffset(motion);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderPlayheadOffset renderObject,
  ) => renderObject.motion = motion;
}

/// The thumb is decorative (the whole track handles pointer/keyboard input).
/// Its translation cannot affect layout or hit testing.
class _RenderPlayheadOffset extends RenderProxyBox {
  _RenderPlayheadOffset(this._motion);

  _TrackMotion _motion;

  set motion(_TrackMotion value) {
    if (value == _motion) return;
    final previous = _motion.livePlayhead;
    _motion = value;
    final next = value.livePlayhead;
    if (attached && previous != next) {
      previous?.removeListener(markNeedsPaint);
      next?.addListener(markNeedsPaint);
    }
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _motion.livePlayhead?.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _motion.livePlayhead?.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final thumb = child;
    if (thumb == null) return;
    context.paintChild(
      thumb,
      offset + Offset(_trackExtent(_motion, buffered: false), 0),
    );
  }
}

/// The volume track, drawn rather than themed.
///
/// A [Slider] paints one colour either side of its thumb, and this track has
/// three things to say: the level so far, how much of that is amplification
/// the recording never carried, and the room left. Two rounded bars and a dot
/// say all three, and the whole strip answers a click anywhere along it.
class _VolumeTrack extends StatelessWidget {
  const _VolumeTrack({
    required this.fraction,
    required this.boostFraction,
    required this.boostColor,
    required this.boosting,
    required this.onFraction,
    required this.onFractionEnd,
  });

  final double fraction;

  /// Where the recording's own level sits along the track.
  final double boostFraction;
  final Color boostColor;
  final bool boosting;
  final ValueChanged<double> onFraction;
  final ValueChanged<double> onFractionEnd;

  static const double _width = 108;
  static const double _height = 8;
  static const double _thumb = 14;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final filled = (_width * fraction).clamp(0.0, _width);
    final breakStop = fraction <= 0
        ? 0.0
        : (boostFraction / fraction).clamp(0.0, 1.0);

    // The whole strip is the target, not the eight-point bar: a level is
    // worth hitting without aiming.
    return SizedBox(
      width: _width,
      height: _thumb + 12,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (details) => onFractionEnd(_at(details.localPosition.dx)),
        onHorizontalDragUpdate: (details) =>
            onFraction(_at(details.localPosition.dx)),
        onHorizontalDragEnd: (_) => onFractionEnd(fraction),
        child: Stack(
          alignment: Alignment.centerLeft,
          clipBehavior: Clip.none,
          children: [
            Container(
              height: _height,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            // The stretch of track that is amplification, marked before it is
            // reached. A viewer should be able to see where the recording's
            // own level ends without having to push past it first.
            if (boostFraction < 1)
              Positioned(
                left: _width * boostFraction,
                right: 0,
                child: Container(
                  height: _height,
                  decoration: BoxDecoration(
                    color: const Color(0xFFDC2626).withValues(alpha: 0.32),
                    borderRadius: const BorderRadius.horizontal(
                      right: Radius.circular(999),
                    ),
                  ),
                ),
              ),
            SizedBox(
              width: filled,
              child: Container(
                height: _height,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  color: boosting ? null : accent.withValues(alpha: 0.92),
                  gradient: boosting
                      ? LinearGradient(
                          stops: <double>[breakStop, breakStop, 1],
                          colors: <Color>[
                            accent.withValues(alpha: 0.92),
                            const Color(0xFFF97316),
                            boostColor,
                          ],
                        )
                      : null,
                ),
              ),
            ),
            Positioned(
              left: filled - _thumb / 2,
              child: Container(
                width: _thumb,
                height: _thumb,
                decoration: BoxDecoration(
                  color: boosting ? boostColor : accent,
                  shape: BoxShape.circle,
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x99000000),
                      blurRadius: 8,
                      offset: Offset(0, 2),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  double _at(double dx) => (dx / _width).clamp(0.0, 1.0);
}

/// An icon that answers the pointer with a colour.
///
/// The buttons around it are [PlayerIconButton]s, which do this for
/// themselves; play and pause draw their own glyph and had nothing to say
/// when the pointer arrived.
class _HoverTintedIcon extends StatefulWidget {
  const _HoverTintedIcon({
    required this.icon,
    required this.color,
    required this.size,
    this.hoverColor,
  });

  final IconData icon;
  final Color color;
  final Color? hoverColor;
  final double size;

  @override
  State<_HoverTintedIcon> createState() => _HoverTintedIconState();
}

class _HoverTintedIconState extends State<_HoverTintedIcon> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final hover = widget.hoverColor;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 120),
        child: Icon(
          widget.icon,
          key: ValueKey<bool>(_hovered && hover != null),
          color: _hovered && hover != null ? hover : widget.color,
          size: widget.size,
        ),
      ),
    );
  }
}
