import 'dart:collection';

import 'package:flutter/material.dart';
import '../../../../core/router/app_router.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import '../../../../core/utils/layout_constants.dart';
import '../../../../shared/widgets/cards_wrapper.dart';

import '../../../../core/utils/responsive_breakpoints.dart';
import '../../../../shared/widgets/multimedia_card.dart';
import '../view_all_screen.dart';
import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/extensions/base_provider.dart';
import '../../../../core/utils/image_utils.dart';

class MediaHorizontalList extends StatefulWidget {
  final String title;
  final List<MultimediaItem> mediaList;
  final ViewAllCategory category;
  final void Function(MultimediaItem)? onTap;
  final bool showViewAll;
  final bool fixedPhysicalDirection;
  final String? heroTagPrefix;
  final Future<ProviderMediaPage> Function(int offset)? loadViewAllPage;
  final bool forcePortrait;

  const MediaHorizontalList({
    super.key,
    required this.title,
    required this.mediaList,
    required this.category,
    this.onTap,
    this.showViewAll = true,
    this.fixedPhysicalDirection = true,
    this.heroTagPrefix,
    this.loadViewAllPage,
    this.forcePortrait = false,
  });

  @override
  State<MediaHorizontalList> createState() => _MediaHorizontalListState();
}

class _MediaHorizontalListState extends State<MediaHorizontalList> {
  late ScrollController _scrollController;
  bool _isPortrait = true;

  // Cache the aspect ratio for a given URL to prevent layout shifts
  // when the widget is destroyed and recreated during scrolling. Bounded
  // because a power user can scroll thousands of unique posters over a
  // session; LRU eviction keeps the working set bounded.
  static const int _aspectRatioCacheMax = 5000;
  static final LinkedHashMap<String, bool> _aspectRatioCache =
      LinkedHashMap<String, bool>();

  static bool? _lookupCached(String url) {
    if (!_aspectRatioCache.containsKey(url)) return null;
    // Move to most-recently-used.
    final v = _aspectRatioCache.remove(url)!;
    _aspectRatioCache[url] = v;
    return v;
  }

  static void _storeCached(String url, bool isPortrait) {
    _aspectRatioCache.remove(url);
    _aspectRatioCache[url] = isPortrait;
    while (_aspectRatioCache.length > _aspectRatioCacheMax) {
      _aspectRatioCache.remove(_aspectRatioCache.keys.first);
    }
  }

  bool get _shouldProbeAspectRatio =>
      !widget.forcePortrait &&
      widget.mediaList.isNotEmpty &&
      widget.mediaList.first.contentType == MultimediaContentType.livestream;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();

    if (_shouldProbeAspectRatio) {
      final url = widget.mediaList.first.posterImageUrl;
      final cached = _lookupCached(url);
      if (cached != null) {
        _isPortrait = cached;
      } else {
        _checkAspectRatio();
      }
    }
  }

  @override
  void didUpdateWidget(MediaHorizontalList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_shouldProbeAspectRatio) {
      if (!_isPortrait) setState(() => _isPortrait = true);
      return;
    }
    if (oldWidget.mediaList != widget.mediaList || oldWidget.forcePortrait) {
      final url = widget.mediaList.first.posterImageUrl;
      final cached = _lookupCached(url);
      if (cached != null) {
        if (_isPortrait != cached) {
          setState(() => _isPortrait = cached);
        }
      } else {
        _checkAspectRatio();
      }
    }
  }

  Future<void> _checkAspectRatio() async {
    if (!_shouldProbeAspectRatio) return;
    final url = widget.mediaList.first.posterImageUrl;
    if (url.isEmpty) return;
    final isPortrait = await ImageUtils.isImagePortrait(url);
    _storeCached(url, isPortrait);
    if (mounted && _isPortrait != isPortrait) {
      setState(() {
        _isPortrait = isPortrait;
      });
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollBy(double delta) {
    if (!_scrollController.hasClients) return;
    final target = (_scrollController.offset + delta).clamp(
      0.0,
      _scrollController.position.maxScrollExtent,
    );
    _scrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.mediaList.isEmpty) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context)!;
    final localeDirection = Directionality.of(context);
    final layoutDirection = widget.fixedPhysicalDirection
        ? TextDirection.ltr
        : localeDirection;

    final isHandsetLandscape = context.isHandsetLandscape;
    final isDesktopLandscape = context.isDesktopLandscape;
    final isDesktop = context.isDesktop;
    final isPortrait = widget.forcePortrait || _isPortrait;
    final double spacing = isDesktop
        ? LayoutConstants.spacingLg
        : LayoutConstants.spacingSm;
    final double cardWidth = isHandsetLandscape
        ? ResponsiveBreakpoints.handsetLandscapeAnimeCardWidth(
            context,
            horizontalPadding: LayoutConstants.spacingMd,
            spacing: spacing,
          )
        : isDesktopLandscape
        ? ResponsiveBreakpoints.desktopLandscapeAnimeCardWidth(
            context,
            horizontalPadding: LayoutConstants.dashboardContentPadding,
            spacing: spacing,
          )
        : isDesktop
        ? (isPortrait ? 200.0 : 300.0)
        : (isPortrait ? 130.0 : 200.0);

    final double listHeight = MultimediaCardLayout.listHeight(
      cardWidth,
      isPortrait: isPortrait,
    );

    return Directionality(
      textDirection: layoutDirection,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header Row
        Padding(
          padding: EdgeInsets.fromLTRB(
            isDesktop
                ? LayoutConstants.dashboardContentPadding
                : LayoutConstants.spacingMd,
            LayoutConstants.spacingLg,
            isDesktop
                ? LayoutConstants.dashboardContentPadding
                : LayoutConstants.spacingMd,
            LayoutConstants.spacingSm,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Title with Blue Underline Accent
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.title,
                      textDirection: localeDirection,
                      textAlign: TextAlign.left,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: isDesktop ? 24 : 20,
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Container(
                      width: isDesktop ? 30 : 20, // Accent width
                      height: 3,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primary,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ],
                ),
              ),

              // Desktop arrow buttons — before the View All chip
              if (isDesktop) ...[
                const SizedBox(width: 8),
                _HeaderArrowButton(
                  icon: Icons.arrow_back_ios_new,
                  onTap: () => _scrollBy(-400),
                ),
                const SizedBox(width: 4),
                _HeaderArrowButton(
                  icon: Icons.arrow_forward_ios,
                  onTap: () => _scrollBy(400),
                ),
              ],

              if (widget.showViewAll)
                const SizedBox(width: LayoutConstants.spacingXs),

              if (widget.showViewAll)
                CardsWrapper(
                  onTap: () {
                    // Push on the root GoRouter stack (same as DetailsRoute) so
                    // View All covers AppScaffold and the bottom taskbar.
                    ViewAllRoute(
                      $extra: ViewAllRouteExtra(
                        title: widget.title,
                        initialMediaList: widget.mediaList,
                        category: widget.category,
                        onTap: widget.onTap,
                        loadPage: widget.loadViewAllPage,
                        forcePortrait: widget.forcePortrait,
                      ),
                    ).push<void>(context);
                  },
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: LayoutConstants.spacingSm,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      children: [
                        Text(
                          l10n.viewAll,
                          textDirection: localeDirection,
                          style: TextStyle(
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurface.withValues(alpha: 0.7),
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(
                          Icons.arrow_forward_ios,
                          size: 10,
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 0.7),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),

        // List — no DesktopScrollWrapper overlay; arrows are in the header
        SizedBox(
          height: listHeight, // Adjusted for 2:3 ratio within list
          child: Builder(
            builder: (context) {
              return ListView.builder(
                controller: _scrollController,
                clipBehavior: Clip.none,
                padding: EdgeInsets.symmetric(
                  horizontal: isDesktop
                      ? LayoutConstants.dashboardContentPadding
                      : LayoutConstants.spacingMd,
                ),
                scrollDirection: Axis.horizontal,
                itemCount: widget.mediaList.length,
                itemExtent: cardWidth + spacing,
                itemBuilder: (context, index) {
                  final item = widget.mediaList[index];
                  final itemTitle = item.title;
                  final prefix = widget.heroTagPrefix ?? 'list';
                  final uniqueTag =
                      '${prefix}_${widget.title}_${item.id}_${itemTitle.hashCode}_$index';

                  return Directionality(
                    textDirection: localeDirection,
                    child: Padding(
                      padding: EdgeInsets.only(right: spacing),
                      child: MultimediaCard.fromItem(
                        item: item,
                        heroTag: uniqueTag,
                        isPortrait: isPortrait,
                        onTap: () {
                          if (widget.onTap != null) {
                            widget.onTap!(item);
                          } else {
                            DetailsRoute(
                              $extra: DetailsRouteExtra(item: item),
                            ).push<void>(context);
                          }
                        },
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
      ),
    );
  }
}

/// Small arrow button used in section headers on desktop.
class _HeaderArrowButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _HeaderArrowButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return CardsWrapper(
      scaleFactor: 1.01,
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 28,
        height: 28,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(
            alpha: 0.4,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon, size: 12, color: theme.colorScheme.onSurface),
      ),
    );
  }
}
