import '../domain/entity/multimedia_item.dart';

/// Episodes in the order the user is meant to see them.
///
/// The order the server returned is the canonical one: the Episodes tab keeps
/// it as-is and the sort toggle only flips it. The player's episode picker uses
/// this same function so the two lists never disagree.
List<Episode> episodesInDisplayOrder(
  Iterable<Episode> episodes, {
  required bool ascending,
}) {
  final ordered = List<Episode>.of(episodes);
  return ascending ? ordered : ordered.reversed.toList(growable: false);
}

/// Sorts items that each represent an episode into the same visible direction
/// used by the anime details page.
///
/// Download records arrive in completion-time order, so unlike
/// [episodesInDisplayOrder] they first need a canonical season/episode sort.
/// Ties preserve their original order. [episodeOf] is a pure lookup.
List<T> episodeItemsInDisplayOrder<T>(
  Iterable<T> items, {
  required Episode? Function(T item) episodeOf,
  required bool ascending,
}) {
  final values = List<T>.of(items, growable: false);
  if (values.length < 2) return values;
  final episodes = values.map(episodeOf).toList(growable: false);
  final positions = _sortPositions(episodes, ascending);
  return List<T>.generate(
    positions.length,
    (i) => values[positions[i]],
    growable: false,
  );
}

List<int> _sortPositions(List<Episode?> episodes, bool ascending) {
  final indices = List<int>.generate(
    episodes.length,
    (index) => index,
    growable: false,
  );
  indices.sort((a, b) {
    final av = episodes[a];
    final bv = episodes[b];
    if (av == null) return bv == null ? a.compareTo(b) : 1;
    if (bv == null) return -1;

    final bySeason = av.season.compareTo(bv.season);
    final comparison = bySeason != 0
        ? bySeason
        : av.episode.compareTo(bv.episode);
    if (comparison == 0) return a.compareTo(b);
    return ascending ? comparison : -comparison;
  });
  return indices;
}
