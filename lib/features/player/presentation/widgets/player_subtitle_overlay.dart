// Use the same Flutter Material widgets as the player.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../settings/presentation/player_settings_provider.dart';
import '../player_controller.dart';
import 'hotstar_player_style.dart';

/// The MediaKit subtitle layer; the native video_view backend renders its own.
class PlayerSubtitleOverlay extends ConsumerWidget {
  const PlayerSubtitleOverlay({
    super.key,
    required this.controller,
    required this.controlsVisible,
  });

  final VideoController controller;
  final ValueListenable<bool> controlsVisible;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(
      playerControllerProvider.select((state) => state.useExoPlayer),
    )) {
      return const SizedBox.shrink();
    }

    final style = ref.watch(
      playerSettingsProvider.select((snapshot) {
        final settings = snapshot.asData?.value;
        return (
          size: settings?.subtitleSize ?? 22.0,
          color: settings?.subtitleColor ?? 0xFFFFFFFF,
          background: settings?.subtitleBackgroundColor ?? 0x00000000,
          opacity: settings?.subtitleBackgroundOpacity ?? 0.0,
        );
      }),
    );

    return _SubtitlePlacement(
      controlsVisible: controlsVisible,
      child: SubtitleView(
        controller: controller,
        configuration: SubtitleViewConfiguration(
          style: TextStyle(
            fontSize: style.size,
            color: Color(style.color),
            backgroundColor: Color(style.background)
                .withValues(alpha: style.opacity),
            shadows: const [
              Shadow(offset: Offset(0, 1), blurRadius: 2, color: Colors.black),
            ],
          ),
          padding: EdgeInsets.zero,
        ),
      ),
    );
  }
}

/// Chrome visibility and vertical position move the existing subtitle view;
/// neither changes the caption or its style.
class _SubtitlePlacement extends ConsumerWidget {
  const _SubtitlePlacement({
    required this.controlsVisible,
    required this.child,
  });

  final ValueListenable<bool> controlsVisible;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final position = ref.watch(
      playerSettingsProvider.select(
        (snapshot) => snapshot.asData?.value.subtitlePosition ?? 100.0,
      ),
    );
    final subtitleOffset =
        (100 - position) * (MediaQuery.sizeOf(context).height * 0.008);

    return ValueListenableBuilder<bool>(
      valueListenable: controlsVisible,
      child: child,
      builder: (context, visible, child) => Positioned(
        bottom:
            (visible ? HotstarPlayerStyle.bottomChromeHeight : 20.0) +
            subtitleOffset,
        left: 20,
        right: 20,
        child: child!,
      ),
    );
  }
}
