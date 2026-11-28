import 'package:flutter/material.dart';

/// Marks filler episodes consistently in the episode and downloads lists.
Widget buildEpisodeFillerBadge() {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(
      color: const Color(0xFFD32F2F),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(
      'فلر',
      style: const TextStyle(
        color: Colors.white,
        fontSize: 10,
        fontWeight: FontWeight.w800,
      ),
    ),
  );
}
