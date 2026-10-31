import 'package:flutter/widgets.dart';

import '../domain/entity/multimedia_item.dart';

/// One fetched page for [OffsetPager].
typedef OffsetPage<T> = ({List<T> items, int nextOffset, bool hasMore});

/// The dedupe key catalogue pages use for a [MultimediaItem]: its url,
/// or `id|title` when the url is blank.
String multimediaItemPageKey(MultimediaItem item) =>
    item.url.trim().isEmpty ? '${item.id}|${item.title}' : item.url;

/// The append-only offset pagination machine the catalogue grids
/// share: dedupe by key, advance the offset, track loading, error and
/// whether more pages exist. Widgets own the setState calls; the
/// pager owns the state and the transitions.
class OffsetPager<T> {
  OffsetPager({required this.keyOf, this.stopOnEmptyPage = false});

  final String Function(T item) keyOf;

  /// Stop paging when a page comes back empty even if the source
  /// claims there is more (manga grids page this way).
  final bool stopOnEmptyPage;

  final List<T> items = <T>[];
  final Set<String> _seen = <String>{};
  int offset = 0;
  bool hasMore = true;
  bool loading = false;
  Object? error;

  void reset() {
    items.clear();
    _seen.clear();
    offset = 0;
    hasMore = true;
    loading = false;
    error = null;
  }

  /// Loads the next page. [loading] flips synchronously, before the
  /// fetch is awaited, so callers can rebuild immediately to show it.
  Future<void> loadNext(
    Future<OffsetPage<T>> Function(int offset) fetch,
  ) async {
    if (loading || !hasMore) return;
    loading = true;
    error = null;
    try {
      final page = await fetch(offset);
      for (final item in page.items) {
        if (_seen.add(keyOf(item))) items.add(item);
      }
      offset = page.nextOffset;
      hasMore = page.hasMore && !(stopOnEmptyPage && page.items.isEmpty);
    } catch (e) {
      error = e;
    } finally {
      loading = false;
    }
  }

  /// Whether this scroll position is close enough to the end to ask
  /// for the next page.
  bool shouldLoadMore(ScrollController controller, {double threshold = 500}) {
    return controller.hasClients &&
        !loading &&
        hasMore &&
        controller.position.pixels >=
            controller.position.maxScrollExtent - threshold;
  }
}
