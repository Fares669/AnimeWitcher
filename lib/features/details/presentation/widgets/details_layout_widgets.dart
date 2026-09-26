import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
import '../../../library/presentation/downloads_provider.dart';

import 'package:animewitcher/core/extensions/extension_manager.dart';

import 'episode_card.dart';
import 'episode_browse.dart';
import 'episode_search.dart';
import 'episode_view_mode.dart';
import 'details_hero_actions.dart';
import 'package:animewitcher/shared/widgets/apple_liquid_glass.dart';

import 'package:animewitcher/core/providers/device_info_provider.dart';
import 'package:animewitcher/core/utils/responsive_breakpoints.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:animewitcher/core/utils/localized_text.dart';

bool _shouldFilterEpisodesByDub(
  DetailsState detailsState,
  List<Episode> episodes,
) {
  if (detailsState.isMovie ||
      detailsState.selectedDubStatus == DubStatus.none) {
    return false;
  }
  return !isStandaloneEpisodeCatalog([
    for (final episode in episodes)
      (serverName: episode.serverName, name: episode.name),
  ]);
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
      ? historyRepo.getEpisodePosition(
          targetEpisode.url,
          mainUrl: item.url,
          season: targetEpisode.season,
          episode: targetEpisode.episode,
        )
      : historyRepo.getPosition(item.url);

  final label = position > 5000 ? l10n.resume : l10n.play;
  if (targetEpisode == null || isMovie) return label;

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
        ? historyRepo.getEpisodePosition(
            targetEpisode.url,
            mainUrl: item.url,
            season: targetEpisode.season,
            episode: targetEpisode.episode,
          )
        : historyRepo.getPosition(item.url);
    final dur = targetEpisode != null
        ? historyRepo.getEpisodeDuration(
            targetEpisode.url,
            mainUrl: item.url,
            season: targetEpisode.season,
            episode: targetEpisode.episode,
          )
        : historyRepo.getDuration(item.url);

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
                  .read(detailsControllerProvider(item.url).notifier)
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
                  Text(playLabel),
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
                backgroundColor: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.1),
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

class SliverDetailsDesktopEpisodeGrid extends ConsumerWidget {
  final MultimediaItem parentItem;
  final String itemUrl;
  final bool isMovie;

  const SliverDetailsDesktopEpisodeGrid({
    super.key,
    required this.parentItem,
    required this.itemUrl,
    required this.isMovie,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (isMovie) return const SliverToBoxAdapter(child: SizedBox.shrink());

    final detailsState = ref.watch(detailsControllerProvider(itemUrl));
    var episodes = detailsState.seasonMap[detailsState.selectedSeason] ?? [];

    if (episodes.isEmpty) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }

    // Apply Language Filter
    if (_shouldFilterEpisodesByDub(detailsState, episodes)) {
      episodes = episodes
          .where((e) => e.dubStatus == detailsState.selectedDubStatus)
          .toList();
    }

    // Episode list UI v2: show every filtered episode without range batching.
    final displayedEpisodes = episodesInDisplayOrder(
      episodes,
      ascending: detailsState.isAscending,
    );

    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(bottom: LayoutConstants.spacingMd),
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 12,
              children: [
                Text(
                  AppLocalizations.of(context)!.episodes,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                DetailsEpisodeFilterBar(itemUrl: itemUrl),
              ],
            ),
          ),
        ),
        SliverLayoutBuilder(
          builder: (context, constraints) {
            final double crossAxisExtent = constraints.crossAxisExtent;
            final int crossAxisCount = (crossAxisExtent / 480).ceil().clamp(
              1,
              5,
            );
            final int rowCount = (displayedEpisodes.length / crossAxisCount)
                .ceil();

            return SliverList.separated(
              itemCount: rowCount,
              separatorBuilder: (_, _) => const SizedBox(height: 16),
              itemBuilder: (context, rowIndex) {
                final int startIndex = rowIndex * crossAxisCount;
                final int endIndex = (startIndex + crossAxisCount).clamp(
                  0,
                  displayedEpisodes.length,
                );
                final rowEpisodes = displayedEpisodes.sublist(
                  startIndex,
                  endIndex,
                );

                return IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < crossAxisCount; i++)
                        Expanded(
                          child: Padding(
                            padding: EdgeInsets.only(
                              left: i == 0 ? 0 : 8,
                              right: i == crossAxisCount - 1 ? 0 : 8,
                            ),
                            child: i < rowEpisodes.length
                                ? EpisodeCard(
                                    key: ValueKey(rowEpisodes[i].url),
                                    episode: rowEpisodes[i],
                                    parentItem: parentItem,
                                  )
                                : const SizedBox.shrink(),
                          ),
                        ),
                    ],
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

/// One column in portrait; two side-by-side cards in phone landscape.
class SliverEpisodeCardGrid extends StatelessWidget {
  const SliverEpisodeCardGrid({
    super.key,
    required this.children,
    this.mainAxisSpacing = 12,
    this.crossAxisSpacing = 8,
  });

  final List<Widget> children;
  final double mainAxisSpacing;
  final double crossAxisSpacing;

  @override
  Widget build(BuildContext context) {
    final crossAxisCount = ResponsiveBreakpoints.episodeCrossAxisCount(context);
    final rowCount = children.isEmpty
        ? 0
        : (children.length / crossAxisCount).ceil();

    return SliverList.separated(
      itemCount: rowCount,
      separatorBuilder: (_, _) => SizedBox(height: mainAxisSpacing),
      itemBuilder: (context, rowIndex) {
        final startIndex = rowIndex * crossAxisCount;
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
                    child: startIndex + i < children.length
                        ? children[startIndex + i]
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

class SliverDetailsEpisodeList extends ConsumerWidget {
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

  Widget _withTransition(Widget child) {
    final animation = transition;
    if (animation == null) return child;

    return FadeTransition(
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
    if (isMovie) return const SliverToBoxAdapter(child: SizedBox.shrink());

    final detailsState = ref.watch(detailsControllerProvider(itemUrl));
    var episodes = detailsState.seasonMap[detailsState.selectedSeason] ?? [];

    if (episodes.isEmpty) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }

    // Apply Language Filter
    if (_shouldFilterEpisodesByDub(detailsState, episodes)) {
      episodes = episodes
          .where((e) => e.dubStatus == detailsState.selectedDubStatus)
          .toList();
    }

    final orderedEpisodes = episodesInDisplayOrder(
      episodes,
      ascending: detailsState.isAscending,
    );
    // Read the way the episode cards read them, so the filter agrees with
    // what each card says.
    ref.watch(episodeWatchRevisionProvider);
    final watchRepository = ref.watch(episodeWatchRepositoryProvider);
    final downloads =
        ref.watch(downloadsProvider).value ?? const <DownloadItem>[];

    return ListenableBuilder(
      listenable: episodeBrowseListenable,
      builder: (context, _) {
        final displayedEpisodes = browseEpisodesFor(
          parentItem: parentItem,
          ordered: orderedEpisodes,
          watchRepository: watchRepository,
          downloads: downloads,
        );
        return _buildSliverEpisodes(
          context,
          allEpisodes: orderedEpisodes,
          displayedEpisodes: displayedEpisodes,
          selectionActive: detailsState.selectedEpisodeKeys.isNotEmpty,
        );
      },
    );
  }

  Widget _buildSliverEpisodes(
    BuildContext context, {
    required List<Episode> allEpisodes,
    required List<Episode> displayedEpisodes,
    required bool selectionActive,
  }) {
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(bottom: LayoutConstants.spacingMd),
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 12,
              children: [
                Text(
                  AppLocalizations.of(context)!.episodes,
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                ),
                DetailsEpisodeFilterBar(itemUrl: itemUrl),
              ],
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(bottom: LayoutConstants.spacingMd),
            child: EpisodeBrowseBar(episodes: allEpisodes),
          ),
        ),
        if (displayedEpisodes.isEmpty)
          const SliverToBoxAdapter(child: EpisodeBrowseEmpty()),
        SliverEpisodeCardGrid(
          children: [
            for (final ep in displayedEpisodes)
              _withTransition(
                EpisodeCard(
                  key: ValueKey(ep.url),
                  episode: ep,
                  parentItem: parentItem,
                  // Rows on the page, as the PC and tablet list has them: no
                  // panel round each one, only the current or chosen
                  // episode filled.
                  plain: true,
                ),
              ),
          ],
        ),
        if (selectionActive)
          const SliverToBoxAdapter(child: SizedBox(height: 132)),
      ],
    );
  }
}

class DetailsEpisodeFilterBar extends ConsumerWidget {
  final String itemUrl;

  const DetailsEpisodeFilterBar({super.key, required this.itemUrl});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detailsState = ref.watch(detailsControllerProvider(itemUrl));

    final allEpisodes =
        detailsState.seasonMap[detailsState.selectedSeason] ?? [];

    // Movies (and AnimeWitcher مترجم/مدبلج catalogs) list every variant as its
    // own row. Do not show a ترجمة/دبلجة filter that would hide half of them.
    final isStandaloneCatalog = isStandaloneEpisodeCatalog([
      for (final episode in allEpisodes)
        (serverName: episode.serverName, name: episode.name),
    ]);
    final hasDub = allEpisodes.any((e) => e.dubStatus == DubStatus.dubbed);
    final hasSub = allEpisodes.any((e) => e.dubStatus == DubStatus.subbed);
    final showLanguageToggle =
        !detailsState.isMovie && !isStandaloneCatalog && hasDub && hasSub;
    final selectedDub = detailsState.selectedDubStatus;

    return SizedBox(
      height: 40,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showLanguageToggle) ...[
            _buildLanguageToggle(context, ref, selectedDub),
            const SizedBox(width: 8),
          ],
          // The same capsule the view modes beside it wear: a grey rounded
          // box next to two glass ones read as a control from another page.
          AppleLiquidGlassSurface(
            borderRadius: BorderRadius.circular(20),
            interactive: true,
            fallbackColor: kDetailsHeroGlassFallback,
            fallbackBorder: BorderSide(
              color: Theme.of(
                context,
              ).colorScheme.onSurfaceVariant.withValues(alpha: 0.12),
            ),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: () => ref
                    .read(detailsControllerProvider(itemUrl).notifier)
                    .toggleSort(),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Icon(
                    detailsState.isAscending
                        ? Icons.arrow_downward_rounded
                        : Icons.arrow_upward_rounded,
                    size: 22,
                    // The same colour as the view-mode glyphs it sits beside.
                    // Painting it in the accent while they stayed neutral made
                    // one button of a row of four look like a different kind
                    // of control.
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
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
                ? Theme.of(
                    context,
                  ).colorScheme.primary.withValues(alpha: 40 / 255)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: _isFocused
                  ? Colors.white
                  : (widget.isSelected
                        ? Theme.of(
                            context,
                          ).colorScheme.primary.withValues(alpha: 80 / 255)
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

class DetailsChip extends StatelessWidget {
  final String label;

  const DetailsChip({super.key, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: Text(
        label,
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w500),
      ),
    );
  }
}

class DetailsProviderChip extends ConsumerWidget {
  final String providerName;

  const DetailsProviderChip({super.key, required this.providerName});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    bool isDebug = false;
    String displayName = providerName;
    try {
      final manager = ref.read(extensionManagerProvider.notifier);
      final p = manager.getAllProviders().firstWhere(
        (p) => p.packageName == providerName || p.name == providerName,
      );
      displayName = p.name;
      if (p.isDebug) {
        isDebug = true;
      }
    } catch (e) {
      if (kDebugMode) debugPrint('DetailsProviderChip.build: $e');
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Theme.of(context).colorScheme.primary.withValues(alpha: 0.15),
            Theme.of(context).colorScheme.primary.withValues(alpha: 0.05),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
          width: 0.5,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.extension_rounded,
            size: 14,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 4),
          Text(
            displayName.toUpperCase(),
            style: TextStyle(
              color: Theme.of(context).colorScheme.primary,
              fontSize: 11,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.5,
            ),
          ),
          if (isDebug) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.redAccent.withValues(alpha: 0.9),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                appText(context, english: 'DEBUG', arabic: 'تصحيح'),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 8,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Non-sliver desktop episode grid for use inside [DetailsDesktopHero]'s
/// [SingleChildScrollView]. Mirrors [SliverDetailsDesktopEpisodeGrid] but
/// uses [LayoutBuilder] + [Column] instead of sliver equivalents.
class DetailsDesktopEpisodeColumn extends ConsumerWidget {
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
    if (isMovie) return const SizedBox.shrink();

    final detailsState = ref.watch(detailsControllerProvider(itemUrl));
    var episodes = detailsState.seasonMap[detailsState.selectedSeason] ?? [];

    if (episodes.isEmpty) return const SizedBox.shrink();

    if (_shouldFilterEpisodesByDub(detailsState, episodes)) {
      episodes = episodes
          .where(
            (episode) => episode.dubStatus == detailsState.selectedDubStatus,
          )
          .toList(growable: false);
    }

    final orderedEpisodes = episodesInDisplayOrder(
      episodes,
      ascending: detailsState.isAscending,
    );
    ref.watch(episodeWatchRevisionProvider);
    final watchRepository = ref.watch(episodeWatchRepositoryProvider);
    final downloads =
        ref.watch(downloadsProvider).value ?? const <DownloadItem>[];

    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        episodeSearchQuery,
        episodeBrowseListenable,
      ]),
      builder: (context, _) {
        final query = episodeSearchQuery.value;
        final browsed = browseEpisodesFor(
          parentItem: parentItem,
          ordered: orderedEpisodes,
          watchRepository: watchRepository,
          downloads: downloads,
        );
        final displayedEpisodes = query.trim().isEmpty
            ? browsed
            : browsed
                  .where(
                    (episode) => episodeMatchesQuery(
                      number: episode.episode,
                      name: episode.name,
                      query: query,
                    ),
                  )
                  .toList(growable: false);
        return _buildEpisodesSection(
          context,
          displayedEpisodes,
          query,
          allEpisodes: orderedEpisodes,
          selectionActive: detailsState.selectedEpisodeKeys.isNotEmpty,
        );
      },
    );
  }

  Widget _buildEpisodesSection(
    BuildContext context,
    List<Episode> displayedEpisodes,
    String query, {
    required List<Episode> allEpisodes,
    required bool selectionActive,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: LayoutConstants.spacingMd),
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 12,
            children: [
              Text(
                AppLocalizations.of(context)!.episodes,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const EpisodeSearchButton(),
                  const EpisodeViewModeToggle(),
                  DetailsEpisodeFilterBar(itemUrl: itemUrl),
                ],
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: LayoutConstants.spacingMd),
          child: EpisodeBrowseBar(episodes: allEpisodes),
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
                // One row to flick along. Lazy by construction, so the length
                // of the series costs nothing here.
                // A rail rather than a bare horizontal list: a mouse cannot
                // drag one of those, and a wheel over it scrolls the page
                // behind instead — so the row could be seen and not moved.
                // This is the same rail the home screen rows use, drag and all.
                return SizedBox(
                  height: 268,
                  child: PagedRail(
                    itemExtent: 316,
                    itemCount: displayedEpisodes.length,
                    padding: EdgeInsets.zero,
                    itemBuilder: (context, index) => Padding(
                      padding: const EdgeInsets.only(right: 16),
                      child: SizedBox(
                        width: 300,
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
        if (selectionActive) const SizedBox(height: 132),
      ],
    );
  }
}
