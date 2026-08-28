import 'package:flutter/material.dart';
import 'package:animewitcher/shared/widgets/apple_liquid_glass.dart';

import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/extensions/base_provider.dart';
import 'package:animewitcher/features/details/presentation/details_screen.dart';
import '../../../core/utils/image_utils.dart';
import '../../../core/utils/localized_text.dart';
import '../../../core/utils/responsive_breakpoints.dart';
import '../../../shared/widgets/catalog_ltr.dart';
import '../../../shared/widgets/multimedia_card.dart';
import '../../../shared/widgets/shimmer_placeholder.dart';

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
  late final int? _persistentHeaderBranchIndex;

  bool get _isProvider => widget.category == ViewAllCategory.providerContent;

  @override
  void initState() {
    super.initState();
    // Bind this pushed page to the branch it originated from. Using a fixed
    // Home branch lets the retained Home/Search/Library route publish its
    // native Liquid Glass controls above this page when opened from another
    // branch. Capturing the active branch keeps the current route authoritative.
    _persistentHeaderBranchIndex =
        applePersistentGlassHeaderController.activeBranchIndex;
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
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _providerHasMore = widget.loadPage != null;
        if (_providerHasMore) _loadNextProviderPage();
      });
    }
  }

  String _itemKey(MultimediaItem item) {
    final url = item.url.trim();
    if (url.isNotEmpty) return url;
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
      final page = await loader(requestedOffset);
      if (!mounted) return;

      for (final item in page.items) {
        if (_providerSeen.add(_itemKey(item))) {
          _providerItems.add(item);
        }
      }

      setState(() {
        final fallbackAdvance = page.items.isNotEmpty ? page.items.length : 1;
        _providerOffset = page.nextOffset > requestedOffset
            ? page.nextOffset
            : requestedOffset + fallbackAdvance;
        _providerHasMore =
            page.hasMore &&
            (page.nextOffset > requestedOffset || page.items.isNotEmpty);
        _providerLoading = false;
        _providerLoadError = null;
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

  void _ensureProviderFill() {
    if (!mounted || !_providerHasMore || _providerLoading) return;
    if (!_scrollController.hasClients ||
        _scrollController.position.maxScrollExtent <
            _scrollController.position.viewportDimension * 0.65) {
      _loadNextProviderPage();
    }
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
    if (!_isProvider || !_scrollController.hasClients) return;
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
    final screenWidth = MediaQuery.sizeOf(context).width;
    final crossAxisCount = context.isDesktopLandscape
        ? ResponsiveBreakpoints.desktopLandscapeAnimeColumns
        : context.isHandsetLandscape
        ? ResponsiveBreakpoints.handsetLandscapeAnimeColumns
        : (screenWidth / maxExtent).ceil().clamp(1, 20);
    final childAspectRatio = MultimediaCardLayout.gridAspectRatio(
      isPortrait: _isPortrait,
      isDesktop: isDesktop,
    );
    final isArabic =
        Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';

    return Scaffold(
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(kToolbarHeight),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: AppBar(
            automaticallyImplyLeading: false,
            centerTitle: false,
            titleSpacing: 16,
            title: ApplePersistentGlassHeaderScope(
              enabled: Navigator.of(context).canPop(),
              branchIndex: _persistentHeaderBranchIndex,
              onBack: () => Navigator.of(context).maybePop(),
              child: Align(
                alignment: isArabic
                    ? Alignment.centerRight
                    : Alignment.centerLeft,
                child: Directionality(
                  textDirection: isArabic
                      ? TextDirection.rtl
                      : TextDirection.ltr,
                  child: Text(
                    widget.title,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ),
            leading: appleUsesPersistentLiquidGlassHeader
                ? null
                : IconButton(
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).backButtonTooltip,
                    icon: const Icon(Icons.arrow_back_ios_new_rounded),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
            elevation: 0,
          ),
        ),
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
            ? RefreshIndicator(
                onRefresh: _loadNextProviderPage,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: [
                    SizedBox(height: MediaQuery.sizeOf(context).height * 0.2),
                    _ProviderPageLoadError(
                      isEmptyCatalog: true,
                      onRetry: _loadNextProviderPage,
                    ),
                  ],
                ),
              )
            : CatalogLtr(
                child: GridView.builder(
                  controller: _scrollController,
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(16),
                  gridDelegate: ResponsiveBreakpoints.animeGridDelegate(
                    context,
                    maxCrossAxisExtent: maxExtent,
                    childAspectRatio: childAspectRatio,
                    crossAxisSpacing: 16,
                    mainAxisSpacing: 16,
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
                          onRetry: _loadNextProviderPage,
                        );
                      }
                      return ShimmerPlaceholder(borderRadius: 12);
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
                          Navigator.of(context).push<void>(
                            MaterialPageRoute<void>(
                              builder: (_) => DetailsScreen(item: item),
                            ),
                          );
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
        const Icon(Icons.cloud_off_rounded, size: 40),
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
        ),
        const SizedBox(height: 10),
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
