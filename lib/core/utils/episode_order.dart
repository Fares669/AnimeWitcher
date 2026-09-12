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
/// Ties preserve their original order.
List<T> episodeItemsInDisplayOrder<T>(
  Iterable<T> items, {
  required Episode? Function(T item) episodeOf,
  required bool ascending,
}) {
  final indexed = items.indexed.toList(growable: false);
  indexed.sort((a, b) {
    final aEpisode = episodeOf(a.$2);
    final bEpisode = episodeOf(b.$2);

    if (aEpisode == null || bEpisode == null) {
      if (aEpisode == null && bEpisode != null) return 1;
      if (aEpisode != null && bEpisode == null) return -1;
      return a.$1.compareTo(b.$1);
    }

    var comparison = aEpisode.season.compareTo(bEpisode.season);
    if (comparison == 0) {
      comparison = aEpisode.episode.compareTo(bEpisode.episode);
    }
    if (comparison == 0) {
      return a.$1.compareTo(b.$1);
    }
    return ascending ? comparison : -comparison;
  });

  return indexed.map((entry) => entry.$2).toList(growable: false);
}
