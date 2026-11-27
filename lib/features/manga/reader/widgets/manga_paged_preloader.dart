import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../../../../core/domain/entity/manga.dart';
import '../../../../core/utils/manga_image_request_headers.dart';

/// Keep compressed source files ready near the current spread. Never decode
/// a page for prefetch: the reader's native tiler owns visible image pixels.
class MangaPagedPreloader {
  MangaPagedPreloader({Future<void> Function(MangaPage)? fetch})
    : _fetch = fetch ?? _cacheFile;

  final Future<void> Function(MangaPage) _fetch;
  List<MangaPage> _pages = const [];
  final _ready = <int>{};
  List<int> _wanted = const [];
  bool _running = false;
  bool _disposed = false;

  static Future<void> _cacheFile(MangaPage page) async {
    await DefaultCacheManager().getSingleFile(
      page.imageUrl,
      headers: mangaImageRequestHeaders(page.headers),
    );
  }

  /// Look ahead from the end of the visible spread, alternated with the
  /// nearest earlier pages. At most one background transfer is in flight.
  void update(
    List<MangaPage> pages, {
    required int firstVisible,
    required int lastVisible,
    required int distance,
  }) {
    if (_disposed) return;
    if (!identical(_pages, pages)) _ready.clear();
    _pages = pages;
    final window = distance.clamp(0, 20);
    _wanted = [
      for (var step = 1; step <= window; step++) ...[
        if (lastVisible + step < pages.length) lastVisible + step,
        if (firstVisible - step >= 0) firstVisible - step,
      ],
    ];
    _ready.retainAll(_wanted.toSet());
    if (!_running && _wanted.isNotEmpty) _drain();
  }

  Future<void> _drain() async {
    _running = true;
    try {
      while (!_disposed) {
        final index = _wanted.indexWhere((index) => !_ready.contains(index));
        if (index < 0) return;
        final pageIndex = _wanted[index];
        final pages = _pages;
        final page = pages[pageIndex];
        final scheme = Uri.tryParse(page.imageUrl)?.scheme;
        if (scheme == 'http' || scheme == 'https') {
          try {
            await _fetch(page);
          } catch (_) {
            // A speculative miss must never prevent the real page from
            // loading (or retrying) through the visible reader.
          }
        }
        if (!_disposed &&
            identical(_pages, pages) &&
            _wanted.contains(pageIndex)) {
          _ready.add(pageIndex);
        }
      }
    } finally {
      _running = false;
    }
  }

  void dispose() {
    _disposed = true;
    _wanted = const [];
    _pages = const [];
    _ready.clear();
  }
}
