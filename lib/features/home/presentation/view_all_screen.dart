import 'package:flutter/material.dart';
import 'package:animewitcher/shared/widgets/mouse_drag_refresh_indicator.dart';
import 'package:animewitcher/shared/widgets/app_page_header.dart';

import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/extensions/base_provider.dart';

import 'package:animewitcher/core/router/app_router.dart';

import '../../../core/utils/image_utils.dart';
import '../../../core/utils/localized_text.dart';
import '../../../core/utils/responsive_breakpoints.dart';
import '../../../shared/widgets/catalog_direction.dart';
import '../../../shared/widgets/multimedia_card.dart';
import '../../../shared/widgets/anime_catalog_shimmer.dart';

enum ViewAllCategory {
  popularMovies,
  popularTV,
  nowPlayingMovies,
  onTheAirTV,
  topRatedMovies,
  topRatedTV,
  airingTodayTV,
  trending,

  /// Provider-sourced content from the home screen.
  providerContent,
}

class ViewAllScreen extends StatefulWidget {
  final String title;
  final List<MultimediaItem> initialMediaList;
  final ViewAllCategory category;
  final void Function(MultimediaItem item)? onTap;

  /// Loads exactly one provider page. The page is requested only when the
  /// user approaches the bottom, so View All never downloads the full catalog.
  final Future<ProviderMediaPage> Function(int offset)? loadPage;

  /// The source cursor after the seeded items, when that page is already loaded.
  final int? initialOffset;
  final bool initialHasMore;

  /// Forces portrait cards in this View All grid. Used by sections such as
  /// Latest Added Works so mobile keeps the same compact 3-card row layout
  /// as the home section instead of switching to two landscape cards.
  final bool forcePortrait;

  const ViewAllScreen({
    super.key,
    required this.title,
    required this.initialMediaList,
    required this.category,
    this.onTap,
    this.loadPage,
    this.initialOffset,
    this.initialHasMore = true,
    this.forcePortrait = false,
  });

  @override
  State<ViewAllScreen> createState() => _ViewAllScreenState();
}

class _ViewAllScreenState extends State<ViewAllScreen> {
  final ScrollController _scrollController = ScrollController();
  final List<MultimediaItem> _providerItems = <MultimediaItem>[];
  final Set<String> _providerSeen = <String>{};

  bool _isPortrait = true;
  bool _providerLoading = false;
  bool _providerHasMore = true;
  Object? _providerLoadError;
  int _providerOffset = 0;
  int _emptyProviderPages = 0;

  bool get _isProvider => widget.category == ViewAllCategory.providerContent;

  @override
  void initState() {
    super.initState();
    if (_isProvider) {
      _scrollController.addListener(_onScroll);
    }

    for (final item in widget.initialMediaList) {
      final key = _itemKey(item);
      if (_providerSeen.add(key)) _providerItems.add(item);
    }

    if (widget.forcePortrait) {
      _isPortrait = true;
    } else if (widget.initialMediaList.isNotEmpty) {
      _checkAspectRatio();
    }

    if (_isProvider) {
      _providerOffset = widget.initialOffset ?? 0;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _providerHasMore = widget.loadPage != null && widget.initialHasMore;
        if (!_providerHasMore) return;
        if (widget.initialOffset == null || _providerItems.isEmpty) {
          _loadNextProviderPage();
        } else {
          _ensureProviderFill(onlyIfNotScrollable: true);
        }
      });
    }
  }

  String _itemKey(MultimediaItem item) {
    final url = item.url.trim();
    if (url.isNotEmpty) {
      final uri = Uri.tryParse(url);
      if (uri != null &&
          (uri.host == 'animewitcher.com' ||
              uri.host == 'www.animewitcher.com') &&
          uri.pathSegments.length >= 2 &&
          uri.pathSegments.first == 'watch') {
        return 'animewitcher:watch:${uri.pathSegments[1]}';
      }
      return url;
    }
    return '${item.id}|${item.title}|${item.posterUrl}';
  }

  Future<void> _loadNextProviderPage() async {
    final loader = widget.loadPage;
    if (!_isProvider || loader == null || _providerLoading) {
      return;
    }
    if (!_providerHasMore && _providerLoadError == null) {
      return;
    }

    final requestedOffset = _providerOffset;
    setState(() {
      _providerLoading = true;
      _providerLoadError = null;
    });

    try {
      final page = await loader(requestedOffset)
          .timeout(const Duration(seconds: 30));
      if (!mounted) return;
      if (page.hasMore && page.nextOffset <= requestedOffset) {
        throw StateError('The provider page cursor did not advance.');
      }

      final previousCount = _providerItems.length;
      for (final item in page.items) {
        if (_providerSeen.add(_itemKey(item))) {
          _providerItems.add(item);
        }
      }

      setState(() {
        if (page.nextOffset > requestedOffset) {
          _providerOffset = page.nextOffset;
        }
        _providerHasMore = page.hasMore;
        _providerLoading = false;
        _emptyProviderPages = _providerItems.length == previousCount
            ? _emptyProviderPages + 1
            : 0;
        // Sparse catalogues may skip ranks, but never spin through them forever.
        if (_providerHasMore && _emptyProviderPages >= 3) {
          _providerLoadError = StateError(
            'No new titles in consecutive pages.',
          );
        }
      });

      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _ensureProviderFill(),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _providerLoading = false;
        _providerLoadError = error;
      });
    }
  }

  void _ensureProviderFill({bool onlyIfNotScrollable = false}) {
    if (!mounted ||
        !_providerHasMore ||
        _providerLoading ||
        _providerLoadError != null) {
      return;
    }
    if (!_scrollController.hasClients ||
        (onlyIfNotScrollable
            ? _scrollController.position.maxScrollExtent <= 0
            : _scrollController.position.extentAfter <= 500)) {
      _loadNextProviderPage();
    }
  }

  Future<void> _retryProviderPage() {
    _emptyProviderPages = 0;
    return _loadNextProviderPage();
  }

  Future<void> _checkAspectRatio() async {
    if (widget.forcePortrait || widget.initialMediaList.isEmpty) return;
    final url = widget.initialMediaList.first.posterImageUrl;
    if (url.isEmpty) return;
    final isPortrait = await ImageUtils.isImagePortrait(url);
    if (mounted && _isPortrait != isPortrait) {
      setState(() => _isPortrait = isPortrait);
    }
  }

  void _onScroll() {
    if (!_isProvider ||
        !_scrollController.hasClients ||
        _providerLoadError != null) {
      return;
    }
    if (_scrollController.position.pixels <
        _scrollController.position.maxScrollExtent - 500) {
      return;
    }
    _loadNextProviderPage();
  }

  @override
  void dispose() {
    if (_isProvider) {
      _scrollController.removeListener(_onScroll);
    }
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final items = _isProvider ? _providerItems : widget.initialMediaList;
    final isLoading = _isProvider && _providerLoading;
    final hasProviderLoadError = _isProvider && _providerLoadError != null;

    final isDesktop = context.isDesktop;
    final maxExtent = isDesktop
        ? (_isPortrait ? 240.0 : 340.0)
        : (_isPortrait ? 150.0 : 220.0);
    final gridHorizontalPadding = _isPortrait
        ? MultimediaCardLayout.catalogGridHorizontalPadding(context)
        : 16.0;
    final gridCrossAxisSpacing = _isPortrait
        ? MultimediaCardLayout.catalogGridCrossAxisSpacing(context)
        : 16.0;
    final gridMainAxisSpacing = _isPortrait
        ? MultimediaCardLayout.catalogGridMainAxisSpacing(context)
        : 16.0;
    // Derived from the same helper the grid delegate uses, so the trailing
    // shimmer tiles always complete the last row instead of guessing.
    final crossAxisCount = ResponsiveBreakpoints.animeGridCrossAxisCount(
      context,
      maxCrossAxisExtent: maxExtent,
      crossAxisSpacing: gridCrossAxisSpacing,
      horizontalPadding: gridHorizontalPadding,
      handsetPortraitCrossAxisCount: _isPortrait
          ? MultimediaCardLayout.handsetPortraitGridColumns
          : null,
    );
    final childAspectRatio = MultimediaCardLayout.gridAspectRatio(
      isPortrait: _isPortrait,
      isDesktop: isDesktop,
    );
    final headerTop = appPageHeaderContentTopInset(context);

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppPageAppBar(
        title: widget.title,
        onBack: () => Navigator.of(context).maybePop(),
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Theme.of(context).scaffoldBackgroundColor.withValues(alpha: 0.8),
              Theme.of(context).scaffoldBackgroundColor,
            ],
            stops: const [0, 0.3],
          ),
        ),
        child: hasProviderLoadError && items.isEmpty
            ? MouseDragRefreshIndicator(
                onRefresh: _retryProviderPage,
                child: ListView(
                  padding: EdgeInsets.only(top: headerTop),
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: [
                    SizedBox(height: MediaQuery.sizeOf(context).height * 0.2),
                    _ProviderPageLoadError(
                      isEmptyCatalog: true,
                      onRetry: _retryProviderPage,
                    ),
                  ],
                ),
              )
            : CatalogDirection(
                child: GridView.builder(
                  controller: _scrollController,
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: EdgeInsets.fromLTRB(
                    gridHorizontalPadding,
                    headerTop + 16,
                    gridHorizontalPadding,
                    16,
                  ),
                  gridDelegate: ResponsiveBreakpoints.animeGridDelegate(
                    context,
                    maxCrossAxisExtent: maxExtent,
                    childAspectRatio: childAspectRatio,
                    crossAxisSpacing: gridCrossAxisSpacing,
                    mainAxisSpacing: gridMainAxisSpacing,
                    handsetPortraitCrossAxisCount: _isPortrait
                        ? MultimediaCardLayout.handsetPortraitGridColumns
                        : null,
                    horizontalPadding: gridHorizontalPadding,
                  ),
                  itemCount:
                      items.length +
                      (isLoading
                          ? crossAxisCount
                          : (hasProviderLoadError ? 1 : 0)),
                  itemBuilder: (context, index) {
                    if (index >= items.length) {
                      if (hasProviderLoadError) {
                        return _ProviderPageLoadError(
                          compact: true,
                          onRetry: _retryProviderPage,
                        );
                      }
                      return AnimePosterShimmer(isPortrait: _isPortrait);
                    }

                    final item = items[index];
                    final uniqueTag =
                        'view_all_${widget.category.name}_${item.id}_$index';

                    return MultimediaCard.fromItem(
                      key: ValueKey(_itemKey(item)),
                      item: item,
                      heroTag: uniqueTag,
                      isPortrait: _isPortrait,
                      onTap: () {
                        if (widget.onTap != null) {
                          widget.onTap!(item);
                        } else {
                          DetailsRoute($extra: DetailsRouteExtra(item: item))
                              .push<void>(context);
                        }
                      },
                    );
                  },
                ),
              ),
      ),
    );
  }
}

class _ProviderPageLoadError extends StatelessWidget {
  const _ProviderPageLoadError({
    required this.onRetry,
    this.compact = false,
    this.isEmptyCatalog = false,
  });

  final Future<void> Function() onRetry;
  final bool compact;
  final bool isEmptyCatalog;

  @override
  Widget build(BuildContext context) {
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.cloud_off_rounded, size: compact ? 24 : 40),
        const SizedBox(height: 10),
        Text(
          appText(
            context,
            english: isEmptyCatalog
                ? 'Could not load results.'
                : 'Could not load more results.',
            arabic: isEmptyCatalog
                ? 'تعذر تحميل النتائج.'
                : 'تعذر تحميل المزيد من النتائج.',
          ),
          textAlign: TextAlign.center,
          style: compact ? Theme.of(context).textTheme.bodySmall : null,
        ),
        const SizedBox(height: 10),
        if (compact)
          TextButton(
            onPressed: onRetry,
            style: TextButton.styleFrom(padding: const EdgeInsets.all(4)),
            child: Text(
              appText(context, english: 'Retry', arabic: 'إعادة المحاولة'),
            ),
          )
        else
          FilledButton.tonalIcon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: Text(
              appText(context, english: 'Retry', arabic: 'إعادة المحاولة'),
            ),
          ),
      ],
    );

    return compact
        ? Center(
            child: Padding(padding: const EdgeInsets.all(8), child: content),
          )
        : Center(
            child: Padding(padding: const EdgeInsets.all(24), child: content),
          );
  }
}
