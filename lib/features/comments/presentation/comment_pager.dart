import 'dart:collection';

import 'package:flutter/widgets.dart';

import '../../../core/account/animewitcher_comment_models.dart';
import '../../../core/account/firestore_rest_client.dart';
import '../../../core/utils/request_generation.dart';

/// The cursor-pagination machine the three comment screens share:
/// generation-guarded first-page replace and append-with-dedupe,
/// with the loading, cursor and error state in one place. Widgets
/// own the setState calls and pass their own page fetch.
class CommentPager {
  List<AnimeWitcherComment> _items = <AnimeWitcherComment>[];
  late List<AnimeWitcherComment> _view = UnmodifiableListView(_items);
  List<AnimeWitcherComment> get items => _view;

  // Needed only past the first page and while there are still pages to append.
  Set<String>? _paths;

  void replaceAt(int index, AnimeWitcherComment replacement) {
    if (_paths != null && replacement.path != _items[index].path) {
      _paths = null;
    }
    _items[index] = replacement;
  }

  void removePath(String path) {
    _items.removeWhere((item) => item.path == path);
    _paths?.remove(path);
  }

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
      // Never retain a mutable alias to the provider's page.
      _items = page.items.toList();
      _view = UnmodifiableListView(_items);
      _paths = null;
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
      if (page.items.isNotEmpty) _append(page.items);
      if (!page.hasMore) _paths = null;
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

  void _append(List<AnimeWitcherComment> incoming) {
    final existing = _paths ??= _items.map((item) => item.path).toSet();
    final start = _items.length;
    try {
      for (final item in incoming) {
        if (existing.add(item.path)) _items.add(item);
      }
    } catch (_) {
      // As with a failed fetch, keep the previously committed page intact.
      _items.removeRange(start, _items.length);
      _paths = null;
      rethrow;
    }
  }
}
