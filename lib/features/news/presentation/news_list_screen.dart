import 'package:flutter/material.dart';
import 'package:animewitcher/shared/widgets/mouse_drag_refresh_indicator.dart';
import 'package:animewitcher/shared/widgets/app_page_header.dart';

import '../../../core/extensions/base_provider.dart';
import '../../../core/domain/entity/multimedia_item.dart';
import '../../home/presentation/widgets/news_card.dart';
import 'news_utils.dart';

class NewsListScreen extends StatefulWidget {
  const NewsListScreen({
    super.key,
    required this.initialItems,
    required this.loadPage,
    this.onOpen,
    this.onAnimeTap,
  });

  final List<NewsItem> initialItems;
  final Future<ProviderNewsPage> Function(int offset, int limit) loadPage;
  final void Function(NewsItem item)? onOpen;
  final void Function(NewsItem item)? onAnimeTap;

  @override
  State<NewsListScreen> createState() => _NewsListScreenState();
}

class _NewsListScreenState extends State<NewsListScreen> {
  late final ScrollController _scrollController;
  late List<NewsItem> _items;
  bool _hasMore = true;
  bool _isLoading = false;
  int _nextOffset = 0;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController()..addListener(_onScroll);
    _items = List<NewsItem>.from(widget.initialItems);
    if (_items.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadMore());
    }
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    if (_scrollController.position.extentAfter < 500) {
      _loadMore();
    }
  }

  Future<void> _loadMore() async {
    if (_isLoading || !_hasMore) return;
    setState(() => _isLoading = true);
    try {
      final page = await widget.loadPage(_nextOffset, 20);
      if (!mounted) return;
      final merged = <String, NewsItem>{
        for (final item in _items) item.id: item,
        for (final item in page.items) item.id: item,
      };
      setState(() {
        _items = merged.values.toList(growable: false);
        _nextOffset = page.nextOffset;
        _hasMore = page.hasMore;
      });
    } catch (_) {
      if (mounted) setState(() => _hasMore = false);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _refresh() async {
    try {
      final page = await widget.loadPage(0, 20);
      if (!mounted) return;
      setState(() {
        _items = page.items;
        _nextOffset = page.nextOffset;
        _hasMore = page.hasMore;
      });
    } catch (_) {
      // Keep the already visible articles when refresh is unavailable.
    }
  }

  @override
  Widget build(BuildContext context) {
    final isArabic = Localizations.localeOf(context).languageCode == 'ar';
    final size = MediaQuery.sizeOf(context);
    final columns = newsListColumnCount(size);
    final landscapeExtent = newsListLandscapeMainAxisExtent(
      size: size,
      padding: MediaQuery.paddingOf(context),
    );
    final headerTop = appPageHeaderContentTopInset(context);
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppPageAppBar(
        title: isArabic ? 'الأخبار' : 'News',
        onBack: () => Navigator.of(context).maybePop(),
      ),
      body: MouseDragRefreshIndicator(
        onRefresh: _refresh,
        child: columns == 1
            ? ListView.separated(
                controller: _scrollController,
                padding: EdgeInsets.fromLTRB(12, headerTop + 12, 12, 28),
                physics: const AlwaysScrollableScrollPhysics(),
                itemCount: _items.length + (_isLoading ? 1 : 0),
                separatorBuilder: (_, index) {
                  if (index >= _items.length - 1)
                    return const SizedBox.shrink();
                  return const SizedBox(height: 12);
                },
                itemBuilder: (context, index) =>
                    _newsItem(context, index, expandToFill: false),
              )
            : GridView.builder(
                controller: _scrollController,
                padding: EdgeInsets.fromLTRB(12, headerTop + 12, 12, 28),
                physics: const AlwaysScrollableScrollPhysics(),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  mainAxisExtent: landscapeExtent,
                ),
                itemCount: _items.length + (_isLoading ? 1 : 0),
                itemBuilder: (context, index) =>
                    _newsItem(context, index, expandToFill: true),
              ),
      ),
    );
  }

  Widget _newsItem(
    BuildContext context,
    int index, {
    required bool expandToFill,
  }) {
    if (index >= _items.length) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    final item = _items[index];
    final onOpen = widget.onOpen == null
        ? () {
            openNewsUrl(item);
          }
        : () {
            widget.onOpen!(item);
          };
    return NewsCard(
      item: item,
      compact: false,
      expandToFill: expandToFill,
      onOpen: onOpen,
      onAnimeTap: widget.onAnimeTap == null
          ? null
          : () => widget.onAnimeTap!(item),
    );
  }
}

