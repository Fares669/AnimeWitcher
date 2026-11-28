import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/utils/offset_pager.dart';
import '../../../core/utils/responsive_breakpoints.dart';
import '../../../shared/widgets/anime_catalog_shimmer.dart';
import '../../../shared/widgets/app_page_header.dart';
import '../../../shared/widgets/catalog_direction.dart';
import '../../../shared/widgets/multimedia_card.dart';

/// One page of a manga list: its items, where the next page starts, and
/// whether there is one.
typedef MangaViewAllPage<T> = ({List<T> items, int nextOffset, bool hasMore});

/// A manga section of the manga tab in full — "فصول جديدة" or "الأكثر قراءة"
/// — as a poster grid that loads the next page as it is scrolled.
class MangaViewAllScreen<T> extends StatefulWidget {
  const MangaViewAllScreen({
    super.key,
    required this.title,
    required this.load,
    required this.itemKey,
    required this.itemBuilder,
  });

  final String title;

  /// The page starting at an offset.
  final Future<MangaViewAllPage<T>> Function(int offset) load;

  /// What tells two items apart, so a page that repeats one shows it once.
  final String Function(T item) itemKey;

  final Widget Function(BuildContext context, T item, int index) itemBuilder;

  @override
  State<MangaViewAllScreen<T>> createState() => _MangaViewAllScreenState<T>();
}

class _MangaViewAllScreenState<T> extends State<MangaViewAllScreen<T>> {
  final ScrollController _scroll = ScrollController();
  late OffsetPager<T> _pager = _newPager();

  OffsetPager<T> _newPager() =>
      OffsetPager<T>(keyOf: widget.itemKey, stopOnEmptyPage: true);

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_loadMore()));
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    // An in-flight append keeps its own pager, never the refreshed one.
    final retired = _pager;
    setState(() {
      _pager = _newPager();
      // Release the previous catalog while its network response settles.
      retired.reset();
    });
    await _loadMore();
  }

  Future<void> _loadMore() async {
    if (!mounted || _pager.loading || !_pager.hasMore) return;
    final pager = _pager;
    bool isCurrent() => mounted && identical(pager, _pager);
    final future = pager.loadNext((offset) async {
      final page = await widget.load(offset);
      if (isCurrent()) return page;
      // Don't traverse, deduplicate or retain an obsolete page.
      return (items: <T>[], nextOffset: offset, hasMore: false);
    });
    setState(() {});
    await future;
    if (!isCurrent()) return;
    setState(() {});
    // Fill a viewport whose first page is too short to scroll.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (isCurrent()) _onScroll();
    });
  }

  void _onScroll() {
    if (!mounted || !_scroll.hasClients) return;
    if (_scroll.position.extentAfter < 800) unawaited(_loadMore());
  }

  @override
  Widget build(BuildContext context) {
    final padding = MultimediaCardLayout.catalogGridHorizontalPadding(context);
    final bottom = MediaQuery.paddingOf(context).bottom;

    final headerTop = appPageHeaderContentTopInset(context);
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppPageAppBar(
        title: widget.title,
        onBack: () => Navigator.of(context).maybePop(),
      ),
      body: Directionality(
        textDirection: TextDirection.rtl,
        child: RefreshIndicator(
          onRefresh: _reload,
          child: CustomScrollView(
            controller: _scroll,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: <Widget>[
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  padding,
                  headerTop + 12,
                  padding,
                  24 + bottom,
                ),
                sliver: _pager.error != null && _pager.items.isEmpty
                    ? SliverToBoxAdapter(
                        child: Center(
                          child: FilledButton.tonalIcon(
                            onPressed: _reload,
                            icon: const Icon(Icons.refresh_rounded),
                            label: Text('إعادة المحاولة'),
                          ),
                        ),
                      )
                    : SliverGrid(
                        gridDelegate: mangaPosterGridDelegate(context),
                        delegate: SliverChildBuilderDelegate(
                          (context, index) {
                            if (index >= _pager.items.length) {
                              return const AnimePosterShimmer();
                            }
                            return CatalogDirection(
                              child: widget.itemBuilder(
                                context,
                                _pager.items[index],
                                index,
                              ),
                            );
                          },
                          childCount: _pager.items.isEmpty && _pager.loading
                              ? AnimeCatalogShimmer.initialCount(context)
                              : _pager.items.length +
                                    (_pager.loading
                                        ? AnimeCatalogShimmer.loadMoreCount
                                        : 0),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The manga tab's poster grid, the same on its page and in full.
SliverGridDelegate mangaPosterGridDelegate(BuildContext context) {
  final padding = MultimediaCardLayout.catalogGridHorizontalPadding(context);
  return ResponsiveBreakpoints.animeGridDelegate(
    context,
    maxCrossAxisExtent: 200,
    childAspectRatio: MultimediaCardLayout.portraitGridAspectRatio,
    crossAxisSpacing: MultimediaCardLayout.catalogGridCrossAxisSpacing(context),
    mainAxisSpacing: MultimediaCardLayout.catalogGridMainAxisSpacing(context),
    handsetPortraitCrossAxisCount:
        MultimediaCardLayout.handsetPortraitGridColumns,
    horizontalPadding: padding,
  );
}
