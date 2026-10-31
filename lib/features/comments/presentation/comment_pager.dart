import 'package:flutter/widgets.dart';

import '../../../core/account/animewitcher_comment_models.dart';
import '../../../core/account/firestore_rest_client.dart';
import '../../../core/utils/request_generation.dart';

/// The cursor-pagination machine the three comment screens share:
/// generation-guarded first-page replace and append-with-dedupe,
/// with the loading, cursor and error state in one place. Widgets
/// own the setState calls and pass their own page fetch.
class CommentPager {
  List<AnimeWitcherComment> items = <AnimeWitcherComment>[];
  FirestoreDocument? cursor;
  bool loadingInitial = true;
  bool loadingMore = false;
  bool hasMore = true;
  Object? loadError;

  final RequestGeneration _generation = RequestGeneration();

  /// Whether this scroll position should pull the next page.
  bool shouldLoadMore(ScrollController controller) {
    return controller.hasClients &&
        !loadingInitial &&
        !loadingMore &&
        hasMore &&
        controller.position.extentAfter < 520;
  }

  /// Loads the first page, replacing the items. Completes true when
  /// the result was applied; false when a newer load superseded it
  /// and the caller should leave the UI to that load. The state reset
  /// happens synchronously, before the fetch is awaited.
  Future<bool> loadInitial(
    Future<AnimeWitcherCommentPage> Function(FirestoreDocument? cursor) fetch,
  ) async {
    final generation = _generation.begin();
    loadingInitial = true;
    loadingMore = false;
    hasMore = true;
    cursor = null;
    loadError = null;
    try {
      final page = await fetch(null);
      if (!_generation.isCurrent(generation)) return false;
      items = page.items;
      cursor = page.cursor;
      hasMore = page.hasMore;
      loadingInitial = false;
      return true;
    } catch (error) {
      if (!_generation.isCurrent(generation)) return false;
      loadError = error;
      loadingInitial = false;
      return true;
    }
  }

  /// Appends the next page, skipping comments already shown. A failed
  /// page records [loadError] and reports through [onError] so the
  /// screen can toast it with its own wording.
  Future<bool> loadMore(
    Future<AnimeWitcherCommentPage> Function(FirestoreDocument? cursor) fetch, {
    void Function(Object error)? onError,
  }) async {
    if (loadingInitial || loadingMore || !hasMore) return false;
    final generation = _generation.current;
    loadingMore = true;
    try {
      final page = await fetch(cursor);
      if (!_generation.isCurrent(generation)) return false;
      final existing = items.map((item) => item.path).toSet();
      final additions = page.items
          .where((item) => existing.add(item.path))
          .toList(growable: false);
      items = <AnimeWitcherComment>[...items, ...additions];
      cursor = page.cursor;
      hasMore = page.hasMore;
      loadingMore = false;
      return true;
    } catch (error) {
      if (!_generation.isCurrent(generation)) return false;
      loadingMore = false;
      loadError = error;
      onError?.call(error);
      return true;
    }
  }
}
