import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../utils/artwork_host_fallback.dart';
import 'poster_warm_queue.dart';

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

final _posterWarmQueue = PosterWarmQueue(
  fetch: (url) async {
    await posterCacheManager.getSingleFile(url);
  },
  // A blocked host can hold a download slot until its request times out.
  isBlocked: (url) => malArtworkUnreachable.value && isMalArtworkUrl(url),
);

/// Warms posters across rows without filling the shared download queue.
/// Recent URLs are not attempted again; cards handle retries.
void warmPosters(Iterable<String> urls, {int limit = 24}) =>
    _posterWarmQueue.enqueue(urls, limit: limit);
