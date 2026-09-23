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
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.68),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Text(
            '$currentPage/$totalPages',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}
