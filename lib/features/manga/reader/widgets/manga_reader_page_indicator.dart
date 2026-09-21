// Adapted from Mangayomi's PageIndicator (Apache-2.0).
// See docs/third_party/MANGAYOMI_READER_NOTICE.md.
import 'package:flutter/material.dart';

class MangaReaderPageIndicator extends StatelessWidget {
  const MangaReaderPageIndicator({
    super.key,
    required this.visible,
    required this.currentPage,
    required this.totalPages,
  });

  final bool visible;
  final int currentPage;
  final int totalPages;

  @override
  Widget build(BuildContext context) {
    if (!visible || totalPages <= 0) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.bottomCenter,
      child: Text(
        '$currentPage / $totalPages',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 20,
          shadows: <Shadow>[
            Shadow(offset: Offset(-1, -1), blurRadius: 1),
            Shadow(offset: Offset(1, -1), blurRadius: 1),
            Shadow(offset: Offset(1, 1), blurRadius: 1),
            Shadow(offset: Offset(-1, 1), blurRadius: 1),
          ],
        ),
        textAlign: TextAlign.center,
      ),
    );
  }
}
