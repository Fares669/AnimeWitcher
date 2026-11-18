import 'more_sidebar_shell.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/account/account_providers.dart';
import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/extensions/extension_manager.dart';
import '../../../../core/extensions/native_provider_resolution.dart';
import '../../../core/utils/offset_pager.dart';
import '../../../shared/widgets/anime_catalog_shimmer.dart';
import '../../../shared/widgets/catalog_page.dart';
import '../../../shared/widgets/multimedia_card.dart';
import '../../../core/router/app_router.dart';

class ComingSoonScreen extends ConsumerStatefulWidget {
  const ComingSoonScreen({super.key});

  @override
  ConsumerState<ComingSoonScreen> createState() => _ComingSoonScreenState();
}

class _ComingSoonScreenState extends ConsumerState<ComingSoonScreen> {
  final ScrollController _controller = ScrollController();
  OffsetPager<MultimediaItem> _pager = OffsetPager<MultimediaItem>(
    keyOf: multimediaItemPageKey,
  );
  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadNext());
  }

  void _onScroll() {
    if (_pager.shouldLoadMore(_controller)) _loadNext();
  }

  Future<void> _loadNext() async {
    if (!mounted) return;
    final pager = _pager;
    if (pager.loading || !pager.hasMore) return;
    final active = ref.read(activeProviderProvider);
    final provider = active?.supportsUpcoming == true
        ? active
        : ref.nativeProvider;
    if (provider == null) {
      if (mounted) {
        setState(() => _pager.error = nativeProviderUnavailable());
      }
      return;
    }
    final future = pager.loadNext(
      (offset) => provider
          .getUpcomingPage(offset: offset)
          .then(
            (page) => (
              items: page.items,
              nextOffset: page.nextOffset,
              hasMore: page.hasMore,
            ),
          ),
    );
    setState(() {});
    await future;
    if (mounted && identical(pager, _pager)) setState(() {});
  }

  Future<void> _refresh() async {
    setState(() {
      _pager = OffsetPager<MultimediaItem>(keyOf: multimediaItemPageKey);
    });
    await _loadNext();
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(accountDataRevisionProvider, (previous, next) {
      if (previous == next) return;
      unawaited(_refresh());
    });
    ref.listen(activeProviderProvider, (previous, next) {
      if (previous?.packageName != next?.packageName &&
          (previous?.supportsUpcoming == true || next?.supportsUpcoming == true)) {
        unawaited(_refresh());
      }
    });

    final embedded = MorePaneScope.of(context);
    return CatalogPage(
      title: 'القادم قريبًا',
      canPop: !embedded && Navigator.of(context).canPop(),
      onBack: () => Navigator.of(context).pop(),
      builder: (context, topInset) => CatalogBody(
        topInset: topInset,
        isLoading: _pager.loading,
        errorMessage: _pager.items.isEmpty && _pager.error != null
            ? 'تعذر تحميل الأعمال القادمة'
            : null,
        onRetry: _refresh,
        emptyMessage: 'لا توجد أعمال قادمة حاليًا',
        onRefresh: _refresh,
        scrollController: _controller,
        footer: _pager.loading || (_pager.error != null && _pager.hasMore)
            ? CatalogFooter.loading
            : CatalogFooter.none,
        footerBuilder: (context, _) => _pager.error != null
            ? IconButton(
                tooltip: 'إعادة المحاولة',
                onPressed: _loadNext,
                icon: const Icon(Icons.refresh_rounded),
              )
            : const AnimePosterShimmer(),
        itemCount: _pager.items.length,
        itemBuilder: (context, index) {
          final item = _pager.items[index];
          return MultimediaCard.fromItem(
            key: ValueKey('coming-${item.url}'),
            item: item,
            heroTag: heroTagWithId('coming', item, index, dashed: true),
            onTap: () => item.openDetails(context),
          );
        },
      ),
    );
  }
}
