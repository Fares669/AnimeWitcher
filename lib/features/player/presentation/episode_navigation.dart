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
  final url = currentEpisode?.url ?? currentEpisodeUrl;
  if (url.isEmpty) return null;
  return episodeAtOffsetInVariant(
    episodes,
    currentUrl: url,
    variant: currentEpisode?.dubStatus ?? DubStatus.none,
    offset: offset,
  );
}

/// The next episode that carries story, skipping any the provider marked
/// filler.
///
/// Returns null when everything after the current episode is filler — there
/// is nothing to jump to, so the caller should fall back to the plain next
/// episode rather than refusing to continue.
Episode? nextStoryEpisode({
  required List<Episode>? episodes,
  required Episode? currentEpisode,
  required String currentEpisodeUrl,
}) {
  final url = currentEpisode?.url ?? currentEpisodeUrl;
  if (url.isEmpty) return null;
  return episodeAtOffsetInVariant(
    episodes,
    currentUrl: url,
    variant: currentEpisode?.dubStatus ?? DubStatus.none,
    skipFiller: true,
  );
}

/// Finds a neighbor without allocating a filtered episode list. The first URL
/// in the requested variant anchors the search even if that row is filler.
Episode? episodeAtOffsetInVariant(
  List<Episode>? episodes, {
  required String currentUrl,
  required DubStatus variant,
  int offset = 1,
  bool skipFiller = false,
}) {
  if (episodes == null || offset == 0) return null;
  bool inVariant(Episode row) =>
      variant == DubStatus.none || row.dubStatus == variant;
  final current = episodes.indexWhere(
    (row) => row.url == currentUrl && inVariant(row),
  );
  if (current < 0) return null;

  final step = offset > 0 ? 1 : -1;
  for (var i = current + step; i >= 0 && i < episodes.length; i += step) {
    final row = episodes[i];
    if (!inVariant(row) || (skipFiller && row.isFiller)) continue;
    offset -= step;
    if (offset == 0) return row;
  }
  return null;
}
