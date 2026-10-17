import 'dart:collection';

import 'package:flutter/material.dart';

import '../../../../core/router/app_router.dart';
import '../../../../core/utils/layout_constants.dart';
import '../../../../shared/widgets/paged_rail.dart';

import '../../../../core/utils/responsive_breakpoints.dart';
import '../../../../shared/widgets/multimedia_card.dart';
import '../view_all_screen.dart';
import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/extensions/base_provider.dart';
import '../../../../core/utils/image_utils.dart';
import 'home_section_header.dart';

class MediaHorizontalList extends StatefulWidget {
  final String title;
  final List<MultimediaItem> mediaList;
  final ViewAllCategory category;
  final void Function(MultimediaItem)? onTap;
  final bool showViewAll;
  final String? heroTagPrefix;
  final Future<ProviderMediaPage> Function(int offset)? loadViewAllPage;
  final int? initialViewAllOffset;
  final bool initialViewAllHasMore;
  final bool showWhenEmpty;
  final bool forcePortrait;

  const MediaHorizontalList({
    super.key,
    required this.title,
    required this.mediaList,
    required this.category,
    this.onTap,
    this.showViewAll = true,
    this.heroTagPrefix,
    this.loadViewAllPage,
    this.initialViewAllOffset,
    this.initialViewAllHasMore = true,
    this.showWhenEmpty = false,
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

  @override
  Widget build(BuildContext context) {
    if (widget.mediaList.isEmpty && !widget.showWhenEmpty) {
      return const SizedBox.shrink();
    }
    final isDesktop = context.isDesktop;
    final isHandsetLandscape = context.isHandsetLandscape;
    final isPortrait = widget.forcePortrait || _isPortrait;
    final double spacing = isDesktop
        ? LayoutConstants.spacingLg
        : isHandsetLandscape
        ? ResponsiveBreakpoints.handsetLandscapeGridMaxSpacing
        : LayoutConstants.spacingSm;
    // Shared helper: rail, shimmer and grid all derive their poster width
    // from MultimediaCardLayout so the reserved height always matches.
    final double cardWidth = MultimediaCardLayout.cardWidth(
      context,
      isPortrait: isPortrait,
      horizontalPadding: isDesktop
          ? LayoutConstants.dashboardContentPadding
          : LayoutConstants.spacingMd,
      spacing: spacing,
    );

    final double listHeight = MultimediaCardLayout.listHeight(
      cardWidth,
      isPortrait: isPortrait,
      isDesktop: isDesktop,
    );

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HomeSectionHeader(
            title: widget.title,
            // No arrows: the rail is dragged with the mouse and carried by
            // the wheel, and a pair of chevrons in every header was two more
            // things to look at on a page made of artwork.
            action: widget.showViewAll
                ? HomeViewAllButton(
                    onTap: () {
                      ViewAllRoute(
                        $extra: ViewAllRouteExtra(
                          title: widget.title,
                          initialMediaList: widget.mediaList,
                          category: widget.category,
                          onTap: widget.onTap,
                          loadPage: widget.loadViewAllPage,
                          initialOffset: widget.initialViewAllOffset,
                          initialHasMore: widget.initialViewAllHasMore,
                          forcePortrait: widget.forcePortrait,
                        ),
                      ).push<void>(context);
                    },
                  )
                : null,
          ),
          if (widget.mediaList.isNotEmpty)
            SizedBox(
              height: listHeight,
              child: PagedRail(
                controller: _scrollController,
                itemExtent: cardWidth + spacing,
                clipBehavior: Clip.none,
                padding: EdgeInsets.symmetric(
                  horizontal: isDesktop
                      ? LayoutConstants.dashboardContentPadding
                      : LayoutConstants.spacingMd,
                ),
                itemCount: widget.mediaList.length,
                itemBuilder: (context, index) {
                  final item = widget.mediaList[index];
                  final itemTitle = item.title;
                  final prefix = widget.heroTagPrefix ?? 'list';
                  final uniqueTag =
                      '${prefix}_${widget.title}_${item.id}_${itemTitle.hashCode}_$index';

                  // itemExtent hands children TIGHT width constraints, so a
                  // SizedBox(width:) would be overridden and the card would
                  // stretch across the whole stride (losing the inter-card
                  // gap). Padding deflates the constraints instead, keeping
                  // the card at [cardWidth] with [spacing] as the trailing
                  // gap. The ValueKey is load-bearing: home_rails_rtl_test
                  // locates rail items through it.
                  return Padding(
                    key: ValueKey('${widget.title}-rail-$index'),
                    padding: EdgeInsetsDirectional.only(end: spacing),
                    child: MultimediaCard.fromItem(
                      item: item,
                      heroTag: uniqueTag,
                      isPortrait: isPortrait,
                      onTap: () {
                        if (widget.onTap != null) {
                          widget.onTap!(item);
                        } else {
                          DetailsRoute($extra: DetailsRouteExtra(item: item))
                              .push<void>(context);
                        }
                      },
                    ),
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
