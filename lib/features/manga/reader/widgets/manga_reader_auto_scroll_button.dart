// Adapted from Mangayomi's ReaderAutoScrollButton (Apache-2.0).
// See docs/third_party/MANGAYOMI_READER_NOTICE.md.
import 'package:flutter/material.dart';

class MangaReaderAutoScrollButton extends StatelessWidget {
  const MangaReaderAutoScrollButton({
    super.key,
    required this.isContinuousMode,
    required this.isUiVisible,
    required this.enabled,
    required this.isPlaying,
    required this.onToggle,
  });

  final bool isContinuousMode;
  final bool isUiVisible;
  final bool enabled;
  final bool isPlaying;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    if (!isContinuousMode || isUiVisible || !enabled) {
      return const SizedBox.shrink();
    }
    return Align(
      alignment: Alignment.bottomRight,
      child: IconButton(
        onPressed: onToggle,
        icon: Icon(
          isPlaying ? Icons.pause_circle : Icons.play_circle,
        ),
      ),
    );
  }
}
