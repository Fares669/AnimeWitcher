import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/utils/image_fallbacks.dart';

/// Combines a newly fetched details item with the card that opened the page.
///
/// AnimeWitcher occasionally returns a sparse details document for movies and
/// one-episode titles. In that case the search/home card can contain better
/// artwork than the details response. Never replace usable card artwork with
/// an empty value, and use the single episode thumbnail as a final fallback.
MultimediaItem mergeDetailsItem({
  required MultimediaItem fallback,
  required MultimediaItem incoming,
  List<Episode>? episodes,
}) {
  final resolvedEpisodes = episodes ?? incoming.episodes ?? fallback.episodes;
  final incomingPoster = AppImageFallbacks.poster(incoming.posterUrl);
  final fallbackPoster = AppImageFallbacks.poster(fallback.posterUrl);
  final incomingBanner = AppImageFallbacks.optional(incoming.bannerUrl);
  final fallbackBanner = AppImageFallbacks.optional(fallback.bannerUrl);
  final incomingFullPoster = AppImageFallbacks.poster(incoming.fullPosterUrl);
  final fallbackFullPoster = AppImageFallbacks.poster(fallback.fullPosterUrl);

  final poster =
      incomingPoster ??
      fallbackPoster ??
      _firstEpisodeArtwork(resolvedEpisodes) ??
      incomingBanner ??
      fallbackBanner ??
      '';
  final banner = incomingBanner ?? fallbackBanner ?? poster;
  final fullPoster =
      _distinctFullPoster(incomingFullPoster, incomingPoster) ??
      _distinctFullPoster(fallbackFullPoster, fallbackPoster) ??
      incomingFullPoster ??
      fallbackFullPoster ??
      poster;

  final incomingTitle = incoming.title.trim();
  final incomingDescription = incoming.description?.trim();
  final fallbackDescription = fallback.description?.trim();

  return incoming.copyWith(
    title: incomingTitle.isNotEmpty ? incoming.title : fallback.title,
    posterUrl: poster,
    fullPosterUrl: fullPoster,
    bannerUrl: banner,
    logoUrl:
        AppImageFallbacks.optional(incoming.logoUrl) ??
        AppImageFallbacks.optional(fallback.logoUrl) ??
        '',
    description: incomingDescription?.isNotEmpty == true
        ? incoming.description
        : fallbackDescription?.isNotEmpty == true
        ? fallback.description
        : null,
    episodes: resolvedEpisodes,
  );
}

// The screen and controller both merge details repeatedly. Only inspect the
// episode catalog when neither title poster has already resolved.
String? _firstEpisodeArtwork(List<Episode>? episodes) {
  if (episodes == null) return null;
  for (final episode in episodes) {
    final artwork = AppImageFallbacks.optional(episode.posterUrl);
    if (artwork != null) return artwork;
  }
  return null;
}

/// A full-size URL only counts when it is actually larger than the catalog
/// poster. Otherwise the opening card's stored large artwork is kept.
String? _distinctFullPoster(String? fullPoster, String? displayPoster) {
  if (fullPoster == null || fullPoster.isEmpty) return null;
  if (displayPoster != null && fullPoster == displayPoster) return null;
  return fullPoster;
}

/// Reuses one rendered item across rebuilds of the same Details route.
///
/// Keep the controller's merge and the general model constructor unchanged:
/// their callers can supply mutable or unsorted episode catalogs.
final class DetailsRouteItemMerge {
  static final _growableEpisodeListType = <Episode>[].runtimeType;
  static final _fixedEpisodeListType = List<Episode>.empty().runtimeType;

  ({
    MultimediaItem fallback,
    MultimediaItem incoming,
    List<Episode> episodes,
    MultimediaItem? rendered,
  })?
  _previous;

  MultimediaItem resolve({
    required MultimediaItem fallback,
    required MultimediaItem incoming,
    required List<Episode>? episodes,
  }) {
    // Subclasses can override the fields that the merge reads. Never memoize
    // those; check only the plain model fields on the optimized path.
    final catalog =
        fallback.runtimeType == MultimediaItem &&
            incoming.runtimeType == MultimediaItem
        ? episodes ?? incoming.episodes ?? fallback.episodes
        : null;
    final previous = _previous;
    final sameInput =
        previous != null &&
        identical(fallback, previous.fallback) &&
        identical(incoming, previous.incoming) &&
        identical(catalog, previous.episodes);
    final cached = sameInput ? previous.rendered : null;
    if (cached != null && _sameStrictEpisodeOrder(catalog!, cached.episodes!)) {
      return cached;
    }

    final rendered = mergeDetailsItem(
      fallback: fallback,
      incoming: incoming,
      episodes: episodes,
    );
    // Leave repeated noncanonical inputs on the existing merge path without
    // rescanning them. A fresh input can still qualify.
    if (sameInput && cached == null) return rendered;
    // Never reuse an episode-artwork fallback. Matching a nonempty rendered
    // URL to a raw title poster proves that poster already supplied artwork.
    // Also leave custom List implementations alone.
    _previous =
        catalog != null &&
            catalog.length > 1 &&
            (catalog.runtimeType == _growableEpisodeListType ||
                catalog.runtimeType == _fixedEpisodeListType) &&
            rendered.posterUrl.isNotEmpty &&
            (rendered.posterUrl == incoming.posterUrl ||
                rendered.posterUrl == fallback.posterUrl)
        ? (
            fallback: fallback,
            incoming: incoming,
            episodes: catalog,
            rendered: _sameStrictEpisodeOrder(catalog, rendered.episodes!)
                ? rendered
                : null,
          )
        : null;
    return rendered;
  }

  static bool _sameStrictEpisodeOrder(
    List<Episode> catalog,
    List<Episode> rendered,
  ) {
    if (catalog.length != rendered.length) return false;
    var previousSeason = 0;
    var previousNumber = 0;
    for (var i = 0, length = catalog.length; i < length; i++) {
      final episode = catalog[i];
      // Identity detects in-place list edits even when Episode.== would
      // accept a replacement. Take the original sort path for ties, because
      // List.sort does not guarantee a stable order for equal keys.
      if (!identical(episode, rendered[i]) || episode.runtimeType != Episode) {
        return false;
      }
      final season = episode.season;
      final number = episode.episode;
      if (i > 0 &&
          (season < previousSeason ||
              (season == previousSeason && number <= previousNumber))) {
        return false;
      }
      previousSeason = season;
      previousNumber = number;
    }
    return true;
  }
}
