import '../../../core/domain/entity/multimedia_item.dart';

/// Returns the episode directly before or after the active episode.
///
/// The sequence preserves the provider order and, when the active episode has
/// a subtitle/dub variant, stays within that same variant. This matches the
/// existing next-episode behavior while making both list boundaries explicit.
Episode? adjacentEpisode({
  required List<Episode>? episodes,
  required Episode? currentEpisode,
  required String currentEpisodeUrl,
  required int offset,
}) {
  if (episodes == null || episodes.isEmpty || offset == 0) return null;

  final sequence = currentEpisode != null &&
          currentEpisode.dubStatus != DubStatus.none
      ? episodes
          .where((episode) => episode.dubStatus == currentEpisode.dubStatus)
          .toList(growable: false)
      : episodes;
  final currentUrl = currentEpisode?.url ?? currentEpisodeUrl;
  final currentIndex = sequence.indexWhere((episode) => episode.url == currentUrl);
  final adjacentIndex = currentIndex + offset;
  if (currentIndex < 0 ||
      adjacentIndex < 0 ||
      adjacentIndex >= sequence.length) {
    return null;
  }
  return sequence[adjacentIndex];
}
