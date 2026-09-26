/// Finding your way through a long series: the episodes in blocks of a
/// hundred, as the big streaming apps split One Piece, and a filter for the
/// ones not yet watched or already downloaded, as Aniyomi has it.
library;

import 'package:flutter/material.dart';

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/storage/episode_watch_repository.dart';

import '../../../library/presentation/downloads_provider.dart';

/// Which episodes the list shows.
enum EpisodeListFilter { all, unwatched, downloaded }

/// The episodes in a block: a hundred to a block, the size the streaming
/// apps' blocks come to.
const int episodeRangeSize = 100;

/// A series only gets blocks once it runs past one of them.
bool episodeRangesApply(int count) => count > episodeRangeSize;

/// The block the list is showing, by its place among [episodeRanges]; null
/// for every episode. Reset when a details page opens.
final ValueNotifier<int?> episodeRangeIndex = ValueNotifier<int?>(null);

/// The filter the list is showing. Reset when a details page opens.
final ValueNotifier<EpisodeListFilter> episodeListFilter =
    ValueNotifier<EpisodeListFilter>(EpisodeListFilter.all);

/// A details page starts on every episode.
void resetEpisodeBrowse() {
  episodeRangeIndex.value = null;
  episodeListFilter.value = EpisodeListFilter.all;
}

/// [episodes] in blocks of [episodeRangeSize], first episode first,
/// whichever way the list itself is sorted.
List<List<Episode>> episodeRanges(List<Episode> episodes) {
  final ascending = List<Episode>.of(episodes)
    ..sort((a, b) => a.episode.compareTo(b.episode));
  return <List<Episode>>[
    for (var start = 0; start < ascending.length; start += episodeRangeSize)
      ascending.sublist(
        start,
        (start + episodeRangeSize).clamp(0, ascending.length),
      ),
  ];
}

/// "801–900", the numbers a block runs from and to.
String episodeRangeLabel(List<Episode> range) {
  if (range.isEmpty) return '';
  final first = range.first.episode;
  final last = range.last.episode;
  return first == last ? '$first' : '$first–$last';
}

/// [ordered] cut to the block at [rangeIndex] and to [filter], its order
/// kept. A block past the end, as after a season change, means every one.
List<Episode> browseEpisodes({
  required List<Episode> ordered,
  required int? rangeIndex,
  required EpisodeListFilter filter,
  required bool Function(Episode) isWatched,
  required bool Function(Episode) isDownloaded,
}) {
  Set<String>? inRange;
  if (rangeIndex != null && episodeRangesApply(ordered.length)) {
    final ranges = episodeRanges(ordered);
    if (rangeIndex >= 0 && rangeIndex < ranges.length) {
      inRange = {for (final episode in ranges[rangeIndex]) episode.url};
    }
  }
  return <Episode>[
    for (final episode in ordered)
      if ((inRange == null || inRange.contains(episode.url)) &&
          switch (filter) {
            EpisodeListFilter.all => true,
            EpisodeListFilter.unwatched => !isWatched(episode),
            EpisodeListFilter.downloaded => isDownloaded(episode),
          })
        episode,
  ];
}

/// Either notifier changing: what a list showing the episodes rebuilds on.
final Listenable episodeBrowseListenable = Listenable.merge(<Listenable>[
  episodeRangeIndex,
  episodeListFilter,
]);

/// [ordered] as the list shows it, reading watched and downloaded the way
/// the episode cards do.
List<Episode> browseEpisodesFor({
  required MultimediaItem parentItem,
  required List<Episode> ordered,
  required EpisodeWatchRepository watchRepository,
  required List<DownloadItem> downloads,
}) {
  final filter = episodeListFilter.value;
  final rangeIndex = episodeRangeIndex.value;
  if (filter == EpisodeListFilter.all && rangeIndex == null) return ordered;
  return browseEpisodes(
    ordered: ordered,
    rangeIndex: rangeIndex,
    filter: filter,
    isWatched: (episode) => watchRepository.isWatched(parentItem.url, episode),
    isDownloaded: (episode) =>
        completedEpisodeDownload(downloads, parentItem, episode) != null,
  );
}

/// The block menu, when the series runs past one block, and the filter
/// chips beside it.
class EpisodeBrowseBar extends StatelessWidget {
  const EpisodeBrowseBar({super.key, required this.episodes});

  /// Every episode of the season, before any block or filter.
  final List<Episode> episodes;

  @override
  Widget build(BuildContext context) {
    final arabic =
        Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';
    String t(String en, String ar) => arabic ? ar : en;
    final colors = Theme.of(context).colorScheme;
    final ranges = episodeRangesApply(episodes.length)
        ? episodeRanges(episodes)
        : const <List<Episode>>[];

    return ListenableBuilder(
      listenable: episodeBrowseListenable,
      builder: (context, _) {
        final current = episodeRangeIndex.value;
        final rangeIndex = current != null && current < ranges.length
            ? current
            : null;
        final filter = episodeListFilter.value;
        Widget chip(EpisodeListFilter value, String label) => FilterChip(
          key: ValueKey<String>('episode-filter-${value.name}'),
          label: Text(label),
          selected: filter == value,
          showCheckmark: false,
          onSelected: (_) => episodeListFilter.value = value,
        );
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            if (ranges.isNotEmpty)
              PopupMenuButton<int>(
                key: const ValueKey<String>('episode-range-menu'),
                tooltip: t('Episode range', 'نطاق الحلقات'),
                initialValue: rangeIndex ?? -1,
                onSelected: (value) =>
                    episodeRangeIndex.value = value < 0 ? null : value,
                itemBuilder: (_) => <PopupMenuEntry<int>>[
                  PopupMenuItem<int>(
                    value: -1,
                    child: Text(t('All episodes', 'كل الحلقات')),
                  ),
                  for (var i = 0; i < ranges.length; i++)
                    PopupMenuItem<int>(
                      key: ValueKey<String>('episode-range-$i'),
                      value: i,
                      child: Text(
                        '${t('Episodes', 'الحلقات')} '
                        '${episodeRangeLabel(ranges[i])}',
                      ),
                    ),
                ],
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: colors.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(99),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Icon(
                        Icons.format_list_numbered_rounded,
                        size: 18,
                        color: colors.primary,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        rangeIndex == null
                            ? t('All episodes', 'كل الحلقات')
                            : '${t('Episodes', 'الحلقات')} '
                                  '${episodeRangeLabel(ranges[rangeIndex])}',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(width: 4),
                      const Icon(Icons.arrow_drop_down_rounded, size: 20),
                    ],
                  ),
                ),
              ),
            chip(EpisodeListFilter.all, t('All', 'الكل')),
            chip(EpisodeListFilter.unwatched, t('Unwatched', 'لم تُشاهد')),
            chip(EpisodeListFilter.downloaded, t('Downloaded', 'المُنزّلة')),
          ],
        );
      },
    );
  }
}

/// Said in place of the list when a block or filter leaves nothing to show.
class EpisodeBrowseEmpty extends StatelessWidget {
  const EpisodeBrowseEmpty({super.key});

  @override
  Widget build(BuildContext context) {
    final arabic =
        Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28),
      child: Center(
        child: Text(
          arabic ? 'لا توجد حلقات هنا' : 'No episodes here',
          key: const ValueKey<String>('episode-browse-empty'),
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
