import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/utils/responsive_breakpoints.dart';
import '../../../core/utils/window_controls_inset.dart';
import '../../../shared/widgets/anime_catalog_shimmer.dart';
import '../../../shared/widgets/app_back_button.dart';
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
  final List<T> _items = <T>[];
  final Set<String> _seen = <String>{};
  int _nextOffset = 0;
  bool _hasMore = true;
  bool _loading = false;
  bool _failed = false;

  bool get _arabic =>
      Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';

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
    setState(() {
      _items.clear();
      _seen.clear();
      _nextOffset = 0;
      _hasMore = true;
      _failed = false;
    });
    await _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    setState(() => _loading = true);
    try {
      final page = await widget.load(_nextOffset);
      if (!mounted) return;
      setState(() {
        _items.addAll(
          page.items.where((item) => _seen.add(widget.itemKey(item))),
        );
        _nextOffset = page.nextOffset;
        _hasMore = page.hasMore && page.items.isNotEmpty;
        _failed = false;
      });
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
    // A first page too short to scroll never asks for the next one.
    WidgetsBinding.instance.addPostFrameCallback((_) => _onScroll());
  }

  void _onScroll() {
    if (!mounted || !_scroll.hasClients) return;
    if (_scroll.position.extentAfter < 800) unawaited(_loadMore());
  }

  @override
  Widget build(BuildContext context) {
    final padding = MultimediaCardLayout.catalogGridHorizontalPadding(context);
    final bottom = MediaQuery.paddingOf(context).bottom;

    return Scaffold(
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(kToolbarHeight),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: AppBar(
            automaticallyImplyLeading: false,
            centerTitle: false,
            titleSpacing: 16,
            leading: const AppBackButton(),
            title: Align(
              alignment: _arabic
                  ? Alignment.centerRight
                  : Alignment.centerLeft,
              child: Directionality(
                textDirection: _arabic
                    ? TextDirection.rtl
                    : TextDirection.ltr,
                child: Text(widget.title),
              ),
            ),
            actions: const <Widget>[WindowControlsGap()],
          ),
        ),
      ),
      body: Directionality(
        textDirection: _arabic ? TextDirection.rtl : TextDirection.ltr,
        child: RefreshIndicator(
          onRefresh: _reload,
          child: CustomScrollView(
          controller: _scroll,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: <Widget>[
            SliverPadding(
              padding: EdgeInsets.fromLTRB(padding, 12, padding, 24 + bottom),
              sliver: _failed && _items.isEmpty
                  ? SliverToBoxAdapter(
                      child: Center(
                        child: FilledButton.tonalIcon(
                          onPressed: _reload,
                          icon: const Icon(Icons.refresh_rounded),
                          label: Text(_arabic ? 'إعادة المحاولة' : 'Retry'),
                        ),
                      ),
                    )
                  : SliverGrid(
                      gridDelegate: mangaPosterGridDelegate(context),
                      delegate: SliverChildBuilderDelegate(
                        (context, index) {
                          if (index >= _items.length) {
                            return const AnimePosterShimmer();
                          }
                          return CatalogDirection(
                            child: widget.itemBuilder(
                              context,
                              _items[index],
                              index,
                            ),
                          );
                        },
                        childCount: _items.length + (_loading ? 6 : 0),
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
