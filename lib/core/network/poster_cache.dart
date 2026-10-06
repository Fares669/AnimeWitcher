import 'dart:async';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../utils/artwork_host_fallback.dart';

/// Where posters are kept on disk.
///
/// The default cache keeps 200 pictures, fewer than a few rows of home and a
/// search; scrolling back found them gone and downloaded them again. Posters
/// are small (MyAnimeList's are about 30 KB) and rarely change, so this keeps
/// thousands, for two months.
final CacheManager posterCacheManager = CacheManager(
  Config(
    'animewitcher_posters',
    stalePeriod: const Duration(days: 60),
    maxNrOfCacheObjects: 4000,
  ),
);

final Set<String> _warmed = <String>{};

/// Downloads posters to disk before they are drawn — a row's worth as soon
/// as its list arrives — so a card shows its picture from disk the moment it
/// is built rather than starting the download then. A few at a time, each
/// at most once per launch; failures are left for the card itself.
void warmPosters(Iterable<String> urls, {int limit = 24}) {
  final todo = <String>[];
  for (final raw in urls) {
    if (todo.length >= limit) break;
    final url = raw.trim();
    if (url.isEmpty || !url.startsWith('http')) continue;
    // A blocked host never answers; asking it only holds a download slot
    // for twenty seconds that every other poster then waits behind.
    if (malArtworkUnreachable.value && isMalArtworkUrl(url)) continue;
    if (_warmed.add(url)) todo.add(url);
  }
  if (todo.isEmpty) return;
  var next = 0;
  Future<void> worker() async {
    while (next < todo.length) {
      final url = todo[next++];
      try {
        await posterCacheManager.getSingleFile(url);
      } catch (_) {
        // The card tries again, and falls back if it must.
      }
    }
  }

  for (var i = 0; i < 6; i++) {
    unawaited(worker());
  }
}
