import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/storage/episode_watch_repository.dart';
import 'package:animewitcher/core/storage/history_repository.dart';
import 'package:animewitcher/core/utils/episode_label.dart';
import 'package:animewitcher/core/utils/episode_order.dart';
import 'package:animewitcher/core/utils/layout_constants.dart';
import 'package:animewitcher/shared/widgets/custom_widgets.dart';
import 'package:animewitcher/shared/widgets/paged_rail.dart';

import '../details_controller.dart';

import 'episode_card.dart';
import 'episode_browse.dart';
import 'episode_download_index.dart';
import 'episode_search.dart';
import 'episode_view_mode.dart';
import 'details_hero_actions.dart';

import 'package:animewitcher/shared/widgets/apple_liquid_glass.dart';

import 'package:animewitcher/core/providers/device_info_provider.dart';
import 'package:animewitcher/core/utils/responsive_breakpoints.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:animewitcher/core/utils/localized_text.dart';

class _EpisodePresentation {
  _EpisodePresentation({
    required List<Episode> episodes,
    required bool ascending,
    required bool isMovie,
    required this.selectedDubStatus,
  }) {
    final standalone =
        !isMovie &&
        isStandaloneEpisodeCatalog(
          episodes.map(
            (episode) => (serverName: episode.serverName, name: episode.name),
          ),
        );
    showLanguageToggle =
        !isMovie &&
        !standalone &&
        episodes.any((episode) => episode.dubStatus == DubStatus.dubbed) &&
        episodes.any((episode) => episode.dubStatus == DubStatus.subbed);
    final filter =
        !isMovie && !standalone && selectedDubStatus != DubStatus.none;
    ordered = episodesInDisplayOrder(
      filter
          ? episodes.where((episode) => episode.dubStatus == selectedDubStatus)
          : episodes,
      ascending: ascending,
    );
  }

  final DubStatus selectedDubStatus;
  late final bool showLanguageToggle;
  late final List<Episode> ordered;
  late final List<List<Episode>> ranges = episodeRangesApply(ordered.length)
      ? episodeRanges(ordered)
      : const <List<Episode>>[];

  int? _projectedRangeIndex;
  List<Episode>? _projectedRange;

  // Range membership uses the static list and display order only. Searching
  // and live watch/download filters can reuse it without revisiting the
  // entire season. Retain only the current range, never its live results.
  List<Episode> rowsInBrowseRange(int? index) {
    if (index == null || index < 0 || index >= ranges.length) {
      _projectedRangeIndex = null;
      _projectedRange = null;
      return ordered;
    }
    if (index != _projectedRangeIndex) {
      _projectedRange = episodeRowsInRange(
        ordered,
        ranges[index],
      ).toList(growable: false);
      _projectedRangeIndex = index;
    }
    return _projectedRange!;
  }
}

bool _sameEpisodeRows(List<Episode> first, List<Episode> second) {
  if (identical(first, second)) return true;
  if (first.length != second.length) return false;
  for (var i = 0; i < first.length; i++) {
    if (!identical(first[i], second[i])) return false;
  }
  return true;
}

/// The controller may publish a fresh list of the same rows when watched
/// state changes. Reuse the static projection in that case, never the live
/// watch/download decisions. The controller replaces published season lists
/// rather than mutating them, and new row objects invalidate the memo.
_EpisodePresentation _useEpisodePresentation(
  List<Episode> episodes,
  DetailsState details,
) {
  final memo =
      useRef<
        ({
          List<Episode> source,
          (bool, bool, DubStatus) options,
          _EpisodePresentation projection,
        })?
      >(null);
  final options = (
    details.isAscending,
    details.isMovie,
    details.selectedDubStatus,
  );
  final previous = memo.value;
  if (previous != null &&
      previous.options == options &&
      _sameEpisodeRows(previous.source, episodes)) {
    if (!identical(previous.source, episodes)) {
      memo.value = (
        source: episodes,
        options: options,
        projection: previous.projection,
      );
    }
    return previous.projection;
  }
  final projection = _EpisodePresentation(
    episodes: episodes,
    ascending: details.isAscending,
    isMovie: details.isMovie,
    selectedDubStatus: details.selectedDubStatus,
  );
  memo.value = (source: episodes, options: options, projection: projection);
  return projection;
}

List<Episode> _browseDetailsEpisodes(
  WidgetRef ref, {
  required MultimediaItem parentItem,
  required _EpisodePresentation presentation,
}) {
  final filter = episodeListFilter.value;
  final candidates = presentation.rowsInBrowseRange(episodeRangeIndex.value);
  if (filter == EpisodeListFilter.all) return candidates;
  EpisodeWatchRepository? watchRepository;
  EpisodeDownloadMembership? completed;
  if (filter == EpisodeListFilter.unwatched) {
    ref.watch(episodeWatchRevisionProvider);
    watchRepository = ref.watch(episodeWatchRepositoryProvider);
  } else if (filter == EpisodeListFilter.downloaded) {
    completed = ref.watch(
      episodeDownloadsForDetailsProvider(episodeDownloadScope(parentItem))
          .select((index) => index.completedEpisodes),
    );
  }
  return browseEpisodes(
    ordered: candidates,
    rangeIndex: null,
    filter: filter,
    isWatched: (episode) =>
        episodeIsWatchedFor(watchRepository!, parentItem, episode),
    isDownloaded: (episode) => completed!.contains(episode.url.trim()),
  );
}

/// What the play button should say for [itemUrl] right now.
///
/// "Play" until there is somewhere to pick up from, then "Resume", and either
/// with the episode named after it — the season too, unless there is only one
/// and naming it would be noise.
///
/// The desktop hero and the handset button row both put this on their own
/// button, and a label that reads one way in one place and another way in the
/// other would be its own small bug.
String detailsPlayActionLabel(
  BuildContext context,
  WidgetRef ref, {
  required MultimediaItem item,
  required String itemUrl,
}) {
  final l10n = AppLocalizations.of(context)!;
  final historyRepo = ref.watch(historyRepositoryProvider);
  final targetEpisode = ref.watch(
    detailsControllerProvider(itemUrl).select((s) => s.targetEpisode),
  );
  final isMovie = ref.watch(
    detailsControllerProvider(itemUrl).select((s) => s.isMovie),
  );
  final seasonMap = ref.watch(
    detailsControllerProvider(itemUrl).select((s) => s.seasonMap),
  );

  final position = targetEpisode != null
      ? historyPositionForItem(
          historyRepo,
          item,
          episodeUrl: targetEpisode.url,
          season: targetEpisode.season,
          episode: targetEpisode.episode,
        )
      : historyPositionForItem(historyRepo, item);

  final label = position > 5000 ? l10n.resume : l10n.play;
  if (targetEpisode == null || isMovie) return label;
  if (targetEpisode.serverName.trim().isNotEmpty) {
    return '$label ${targetEpisode.serverName}';
  }

  return seasonMap.keys.length <= 1
      ? l10n.playEpisodeOnly(label, targetEpisode.episode)
      : l10n.playEpisode(label, targetEpisode.season, targetEpisode.episode);
}

class DetailsSeasonListWrapper extends ConsumerWidget {
  const DetailsSeasonListWrapper({super.key, required this.itemUrl});
  final String itemUrl;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final seasonMap = ref.watch(
      detailsControllerProvider(itemUrl).select((s) => s.seasonMap),
    );
    if (seasonMap.keys.length <= 1) return const SizedBox.shrink();

    final selectedSeason = ref.watch(
      detailsControllerProvider(itemUrl).select((s) => s.selectedSeason),
    );
    final seasons = seasonMap.keys.toList()..sort();

    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: seasons.length,
        separatorBuilder: (_, _) =>
            const SizedBox(width: LayoutConstants.spacingXs),
        itemBuilder: (context, index) {
          final s = seasons[index];
          final isSelected = s == selectedSeason;
          return FilterChip(
            label: Text(AppLocalizations.of(context)!.seasonWithNumber(s)),
            selected: isSelected,
            onSelected: (_) => ref
                .read(detailsControllerProvider(itemUrl).notifier)
                .setSeason(s),
            backgroundColor: isSelected
                ? Theme.of(context).colorScheme.primaryContainer
                : null,
            labelStyle: TextStyle(
              color: isSelected
                  ? Theme.of(context).colorScheme.onPrimaryContainer
                  : null,
            ),
          );
        },
      ),
    );
  }
}

class DetailsActionButtons extends HookConsumerWidget {
  final MultimediaItem item;
  final MultimediaItem? details;
  final String itemUrl;
  final bool vertical;

  const DetailsActionButtons({
    super.key,
    required this.item,
    required this.details,
    required this.itemUrl,
    this.vertical = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final historyRepo = ref.watch(historyRepositoryProvider);
    final targetEpisode = ref.watch(
      detailsControllerProvider(itemUrl).select((s) => s.targetEpisode),
    );
    final isLaunching = ref.watch(
      detailsControllerProvider(itemUrl).select((s) => s.isLaunching),
    );
    final isMovie = ref.watch(
      detailsControllerProvider(itemUrl).select((s) => s.isMovie),
    );
    final seasonMap = ref.watch(
      detailsControllerProvider(itemUrl).select((s) => s.seasonMap),
    );
    final isSingleSeason = seasonMap.keys.length <= 1;

    final playFocusNode = useFocusNode();
    final isTv = ref.watch(deviceProfileProvider).asData?.value.isTv ?? false;
    final isMobile = context.isMobile;

    final btnPadding = EdgeInsets.symmetric(
      vertical: isMobile
          ? LayoutConstants.spacingSm
          : LayoutConstants.spacingMd,
      horizontal: LayoutConstants.spacingMd,
    );

    final pos = targetEpisode != null
        ? historyPositionForItem(
            historyRepo,
            item,
            episodeUrl: targetEpisode.url,
            season: targetEpisode.season,
            episode: targetEpisode.episode,
          )
        : historyPositionForItem(historyRepo, item);
    final dur = targetEpisode != null
        ? historyDurationForItem(
            historyRepo,
            item,
            episodeUrl: targetEpisode.url,
            season: targetEpisode.season,
            episode: targetEpisode.episode,
          )
        : historyDurationForItem(historyRepo, item);

    final playLabel = detailsPlayActionLabel(
      context,
      ref,
      item: item,
      itemUrl: itemUrl,
    );

    final playBtn = CustomButton(
      isPrimary: true,
      focusNode: playFocusNode,
      autofocus: true,
      onPressed:
          (details != null &&
              details!.episodes != null &&
              details!.episodes!.isNotEmpty)
          ? () async {
              await ref
                  .read(
                    detailsControllerProvider(detailsControllerKey(item))
                        .notifier,
                  )
                  .handlePlayPress(context, details!);

              // Phase 10 Fix: TV Focus restoration on return from player
              if (context.mounted && isTv) {
                playFocusNode.requestFocus();
              }
            }
          : null,
      child: Padding(
        padding: btnPadding,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: isLaunching
              ? [
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(width: LayoutConstants.spacingXs),
                  Text(AppLocalizations.of(context)!.resolving),
                ]
              : [
                  const Icon(Icons.play_arrow_rounded),
                  const SizedBox(width: LayoutConstants.spacingXs),
                  Flexible(
                    child: Text(
                      playLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
        ),
      ),
    );

    // Preferred quality is configured globally in Settings.
    // Movies and one-episode titles download from the episode card, not a
    // second primary button next to Play.
    final isLivestream = item.contentType == MultimediaContentType.livestream;

    Widget progressWidget = const SizedBox.shrink();
    if (pos > 0 && dur > 0 && !isLivestream) {
      final progress = (pos / dur).clamp(0.0, 1.0);
      progressWidget = Padding(
        padding: const EdgeInsets.only(bottom: 16.0, left: 8.0, right: 8.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(100), // Stadium style
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 6,
                backgroundColor: Theme.of(context).colorScheme.onSurface
                    .withValues(alpha: 0.1),
                valueColor: AlwaysStoppedAnimation<Color>(
                  Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Icon(
                  Icons.history_toggle_off_rounded,
                  size: 14,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 4),
                Text(
                  "${AppLocalizations.of(context)!.percentWatched((progress * 100).toInt())}${!isMovie && targetEpisode != null ? (isSingleSeason ? ' • E${targetEpisode.episode}' : ' • S${targetEpisode.season} E${targetEpisode.episode}') : ''}",
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.2,
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [progressWidget, playBtn],
    );
  }
}

/// One column in portrait; two side-by-side cards in phone landscape.
class SliverEpisodeCardGrid extends StatelessWidget {
  const SliverEpisodeCardGrid({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.mainAxisSpacing = 12,
    this.crossAxisSpacing = 8,
  });

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final double mainAxisSpacing;
  final double crossAxisSpacing;

  @override
  Widget build(BuildContext context) {
    final crossAxisCount = ResponsiveBreakpoints.episodeCrossAxisCount(context);
    final rowCount = (itemCount / crossAxisCount).ceil();

    return SliverList.separated(
      itemCount: rowCount,
      separatorBuilder: (_, _) => SizedBox(height: mainAxisSpacing),
      itemBuilder: (context, rowIndex) {
        final startIndex = rowIndex * crossAxisCount;
        // A single card already determines its row height. IntrinsicHeight
        // adds a speculative layout pass to every newly visible episode.
        if (crossAxisCount == 1) return itemBuilder(context, startIndex);
        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < crossAxisCount; i++)
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(
                      left: i == 0 ? 0 : crossAxisSpacing / 2,
                      right: i == crossAxisCount - 1 ? 0 : crossAxisSpacing / 2,
                    ),
                    child: startIndex + i < itemCount
                        ? itemBuilder(context, startIndex + i)
                        : const SizedBox.shrink(),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class SliverDetailsEpisodeList extends HookConsumerWidget {
  final MultimediaItem parentItem;
  final String itemUrl;
  final bool isMovie;
  final Animation<double>? transition;
  final Offset transitionOffset;

  const SliverDetailsEpisodeList({
    super.key,
    required this.parentItem,
    required this.itemUrl,
    required this.isMovie,
    this.transition,
    this.transitionOffset = Offset.zero,
  });

  Widget _withTransition(Widget child, {Key? key}) {
    final animation = transition;
    if (animation == null) return child;

    return FadeTransition(
      key: key,
      opacity: animation,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: transitionOffset,
          end: Offset.zero,
        ).animate(animation),
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detailsState = isMovie
        ? const DetailsState()
        : ref.watch(detailsControllerProvider(itemUrl));
    final episodes =
        detailsState.seasonMap[detailsState.selectedSeason] ??
        const <Episode>[];
    final presentation = _useEpisodePresentation(episodes, detailsState);
    if (isMovie || episodes.isEmpty) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    return ListenableBuilder(
      listenable: episodeBrowseListenable,
      builder: (_, _) => Consumer(
        builder: (context, ref, _) => _buildSliverEpisodes(
          context,
          presentation: presentation,
          displayedEpisodes: _browseDetailsEpisodes(
            ref,
            parentItem: parentItem,
            presentation: presentation,
          ),
          details: detailsState.item ?? detailsState.details.asData?.value,
        ),
      ),
    );
  }

  Widget _buildSliverEpisodes(
    BuildContext context, {
    required _EpisodePresentation presentation,
    required List<Episode> displayedEpisodes,
    required MultimediaItem? details,
  }) {
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: _withTransition(
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.only(
                    bottom: LayoutConstants.spacingMd,
                  ),
                  child: EpisodeBrowseBar(
                    episodes: presentation.ordered,
                    ranges: presentation.ranges,
                    leading: DetailsEpisodeFilterBar(
                      itemUrl: itemUrl,
                      visible: presentation.showLanguageToggle,
                      selected: presentation.selectedDubStatus,
                    ),
                    trailing: DetailsEpisodeSortButton(itemUrl: itemUrl),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(
                    bottom: LayoutConstants.spacingMd,
                  ),
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: DetailsHeroPlayPill(
                      item: parentItem,
                      details: details,
                      itemUrl: itemUrl,
                    ),
                  ),
                ),
              ],
            ),
            key: const ValueKey<String>('details-episode-controls-reveal'),
          ),
        ),
        if (displayedEpisodes.isEmpty)
          const SliverToBoxAdapter(child: EpisodeBrowseEmpty()),
        SliverEpisodeCardGrid(
          itemCount: displayedEpisodes.length,
          itemBuilder: (_, index) {
            final ep = displayedEpisodes[index];
            return _withTransition(
              EpisodeCard(
                key: ValueKey(ep.url),
                episode: ep,
                parentItem: parentItem,
                // Rows on the page, as the PC and tablet list has them: no
                // panel round each one, only the current or chosen
                // episode filled.
                plain: true,
              ),
            );
          },
        ),
      ],
    );
  }
}

class DetailsEpisodeFilterBar extends ConsumerWidget {
  final String itemUrl;

  const DetailsEpisodeFilterBar({
    super.key,
    required this.itemUrl,
    required this.visible,
    required this.selected,
  });

  final bool visible;
  final DubStatus selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!visible) return const SizedBox.shrink();
    return SizedBox(
      height: 40,
      child: _buildLanguageToggle(context, ref, selected),
    );
  }

  Widget _buildLanguageToggle(
    BuildContext context,
    WidgetRef ref,
    DubStatus selected,
  ) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      padding: const EdgeInsets.all(4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _LanguageButton(
            label: AppLocalizations.of(context)!.sub,
            isSelected: selected == DubStatus.subbed,
            onTap: () => ref
                .read(detailsControllerProvider(itemUrl).notifier)
                .setDubStatus(DubStatus.subbed),
          ),
          const SizedBox(width: 4),
          _LanguageButton(
            label: AppLocalizations.of(context)!.dub,
            isSelected: selected == DubStatus.dubbed,
            onTap: () => ref
                .read(detailsControllerProvider(itemUrl).notifier)
                .setDubStatus(DubStatus.dubbed),
          ),
        ],
      ),
    );
  }
}

class DetailsEpisodeSortButton extends ConsumerWidget {
  const DetailsEpisodeSortButton({super.key, required this.itemUrl});

  final String itemUrl;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ascending = ref.watch(
      detailsControllerProvider(itemUrl).select((state) => state.isAscending),
    );
    return SizedBox(
      height: 40,
      child: AppleLiquidGlassSurface(
        borderRadius: BorderRadius.circular(20),
        interactive: true,
        fallbackColor: kDetailsHeroGlassFallback,
        fallbackBorder: BorderSide(
          color: Theme.of(context).colorScheme.onSurfaceVariant
              .withValues(alpha: 0.12),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            key: const ValueKey<String>('episode-sort-toggle'),
            borderRadius: BorderRadius.circular(20),
            onTap: () => ref
                .read(detailsControllerProvider(itemUrl).notifier)
                .toggleSort(),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Icon(
                ascending
                    ? Icons.arrow_downward_rounded
                    : Icons.arrow_upward_rounded,
                size: 22,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LanguageButton extends StatefulWidget {
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _LanguageButton({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  State<_LanguageButton> createState() => _LanguageButtonState();
}

class _LanguageButtonState extends State<_LanguageButton> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onFocusChange: (hasFocus) => setState(() => _isFocused = hasFocus),
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(8),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: widget.isSelected
                ? Theme.of(context).colorScheme.primary
                      .withValues(alpha: 40 / 255)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: _isFocused
                  ? Colors.white
                  : (widget.isSelected
                        ? Theme.of(context).colorScheme.primary
                              .withValues(alpha: 80 / 255)
                        : Colors.transparent),
              width: _isFocused ? 2 : 1,
            ),
          ),
          child: Text(
            widget.label,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: widget.isSelected
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.onSurfaceVariant,
              fontWeight: widget.isSelected
                  ? FontWeight.bold
                  : FontWeight.normal,
            ),
          ),
        ),
      ),
    );
  }
}

/// Desktop episode grid laid out inside the details page's scroll view.
class DetailsDesktopEpisodeColumn extends HookConsumerWidget {
  final MultimediaItem parentItem;
  final String itemUrl;
  final bool isMovie;

  const DetailsDesktopEpisodeColumn({
    super.key,
    required this.parentItem,
    required this.itemUrl,
    required this.isMovie,
  });

  Widget _buildEpisodeRow(
    List<Episode> episodes,
    int rowIndex,
    int crossAxisCount, {
    bool plain = false,
    bool vertical = false,
  }) {
    final startIndex = rowIndex * crossAxisCount;
    final endIndex = (startIndex + crossAxisCount).clamp(0, episodes.length);
    final rowEpisodes = episodes.sublist(startIndex, endIndex);

    if (crossAxisCount == 1) {
      return EpisodeCard(
        key: ValueKey(rowEpisodes.single.url),
        episode: rowEpisodes.single,
        parentItem: parentItem,
        plain: plain,
        vertical: vertical,
      );
    }

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var index = 0; index < crossAxisCount; index++)
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(
                  left: index == 0 ? 0 : 8,
                  right: index == crossAxisCount - 1 ? 0 : 8,
                ),
                child: index < rowEpisodes.length
                    ? EpisodeCard(
                        key: ValueKey(rowEpisodes[index].url),
                        episode: rowEpisodes[index],
                        parentItem: parentItem,
                        plain: plain,
                        vertical: vertical,
                      )
                    : const SizedBox.shrink(),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detailsState = isMovie
        ? const DetailsState()
        : ref.watch(detailsControllerProvider(itemUrl));
    final episodes =
        detailsState.seasonMap[detailsState.selectedSeason] ??
        const <Episode>[];
    final presentation = _useEpisodePresentation(episodes, detailsState);
    if (isMovie || episodes.isEmpty) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        episodeSearchQuery,
        episodeBrowseListenable,
      ]),
      builder: (_, _) => Consumer(
        builder: (context, ref, _) {
          final query = episodeSearchQuery.value;
          final browsed = _browseDetailsEpisodes(
            ref,
            parentItem: parentItem,
            presentation: presentation,
          );
          final search = EpisodeSearchQuery(query);
          final displayedEpisodes = search.isEmpty
              ? browsed
              : browsed
                    .where(
                      (episode) =>
                          search.matches(episode.episode, episode.name),
                    )
                    .toList(growable: false);
          return _buildEpisodesSection(
            context,
            displayedEpisodes,
            query,
            presentation: presentation,
            details: detailsState.item ?? detailsState.details.asData?.value,
          );
        },
      ),
    );
  }

  Widget _buildEpisodesSection(
    BuildContext context,
    List<Episode> displayedEpisodes,
    String query, {
    required _EpisodePresentation presentation,
    required MultimediaItem? details,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: LayoutConstants.spacingMd),
          child: Wrap(
            spacing: 10,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: const <Widget>[
              EpisodeSearchButton(),
              EpisodeViewModeToggle(),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: LayoutConstants.spacingMd),
          child: EpisodeBrowseBar(
            episodes: presentation.ordered,
            ranges: presentation.ranges,
            leading: DetailsEpisodeFilterBar(
              itemUrl: itemUrl,
              visible: presentation.showLanguageToggle,
              selected: presentation.selectedDubStatus,
            ),
            trailing: DetailsEpisodeSortButton(itemUrl: itemUrl),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: LayoutConstants.spacingMd),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: DetailsHeroPlayPill(
              item: parentItem,
              details: details,
              itemUrl: itemUrl,
            ),
          ),
        ),
        if (displayedEpisodes.isEmpty && query.trim().isEmpty)
          const EpisodeBrowseEmpty()
        else if (displayedEpisodes.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(
              vertical: LayoutConstants.spacingLg,
            ),
            child: Text(
              appText(
                context,
                english: 'No episode matches "$query"',
                arabic: 'لا توجد حلقة تطابق "$query"',
              ),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          )
        else
          ValueListenableBuilder<EpisodeViewMode>(
            valueListenable: episodeViewMode,
            builder: (context, mode, _) {
              if (mode == EpisodeViewMode.rail) {
                const cardWidth = 300.0;
                // One row to flick along. Lazy by construction, so the length
                // of the series costs nothing here.
                // A rail rather than a bare horizontal list: a mouse cannot
                // drag one of those, and a wheel over it scrolls the page
                // behind instead — so the row could be seen and not moved.
                // This is the same rail the home screen rows use, drag and all.
                return SizedBox(
                  height: EpisodeCard.railHeight(context, width: cardWidth),
                  child: PagedRail(
                    itemExtent: cardWidth + 16,
                    itemCount: displayedEpisodes.length,
                    padding: EdgeInsets.zero,
                    itemBuilder: (context, index) => Padding(
                      padding: const EdgeInsets.only(right: 16),
                      child: SizedBox(
                        width: cardWidth,
                        child: EpisodeCard(
                          key: ValueKey(displayedEpisodes[index].url),
                          episode: displayedEpisodes[index],
                          parentItem: parentItem,
                          vertical: true,
                          plain: true,
                          showDescription: false,
                        ),
                      ),
                    ),
                  ),
                );
              }

              return LayoutBuilder(
                builder: (context, constraints) {
                  // One card to a row reads as a list; several reads as a wall
                  // of artwork. The same card either way, given more or less
                  // room to lay itself out in.
                  final crossAxisCount = mode == EpisodeViewMode.list
                      ? 1
                      : (constraints.maxWidth / 330).ceil().clamp(1, 6);
                  final rowCount = (displayedEpisodes.length / crossAxisCount)
                      .ceil();

                  // Short and ordinary runs flow into the page, so the whole
                  // thing scrolls as one. A very long one keeps a viewport of
                  // its own: a thousand-episode series would otherwise build a
                  // thousand cards to show a dozen.
                  const flowLimit = 80;
                  if (displayedEpisodes.length <= flowLimit) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (var rowIndex = 0; rowIndex < rowCount; rowIndex++)
                          Padding(
                            padding: EdgeInsets.only(
                              bottom: rowIndex == rowCount - 1 ? 0 : 16,
                            ),
                            child: _buildEpisodeRow(
                              displayedEpisodes,
                              rowIndex,
                              crossAxisCount,
                              plain: true,
                              vertical: mode == EpisodeViewMode.grid,
                            ),
                          ),
                      ],
                    );
                  }

                  final viewportHeight = MediaQuery.sizeOf(context).height;
                  final availableHeight = (viewportHeight - 160)
                      .clamp(220.0, 820.0)
                      .toDouble();
                  final maximumHeight = (viewportHeight * 0.72)
                      .clamp(220.0, availableHeight)
                      .toDouble();

                  return SizedBox(
                    height: maximumHeight,
                    child: Scrollbar(
                      child: ListView.separated(
                        primary: false,
                        padding: EdgeInsets.zero,
                        scrollCacheExtent: const ScrollCacheExtent.pixels(700),
                        keyboardDismissBehavior:
                            ScrollViewKeyboardDismissBehavior.onDrag,
                        itemCount: rowCount,
                        separatorBuilder: (_, _) => const SizedBox(height: 16),
                        // The same rows the shorter lists get: without these
                        // a long series fell back to the defaults and drew
                        // the old boxed card, so One Piece looked like a
                        // different app to a twelve-episode season.
                        itemBuilder: (context, rowIndex) => _buildEpisodeRow(
                          displayedEpisodes,
                          rowIndex,
                          crossAxisCount,
                          plain: true,
                          vertical: mode == EpisodeViewMode.grid,
                        ),
                      ),
                    ),
                  );
                },
              );
            },
          ),
      ],
    );
  }
}
