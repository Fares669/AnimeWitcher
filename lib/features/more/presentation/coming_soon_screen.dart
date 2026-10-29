import 'more_sidebar_shell.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/account/account_providers.dart';
import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/extensions/extension_manager.dart';
import '../../../core/extensions/providers/animewitcher_native_provider.dart';
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
  final List<MultimediaItem> _items = <MultimediaItem>[];
  final Set<String> _seen = <String>{};
  AnimeWitcherNativeProvider? _provider;
  bool _loading = false;
  bool _hasMore = true;
  Object? _error;
  int _offset = 0;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadNext());
  }

  AnimeWitcherNativeProvider? _resolveProvider() {
    final active = ref.read(activeProviderProvider);
    if (active is AnimeWitcherNativeProvider) return active;
    for (final provider in ref.read(extensionManagerProvider)) {
      if (provider is AnimeWitcherNativeProvider) return provider;
    }
    return null;
  }

  void _onScroll() {
    if (!_controller.hasClients || _loading || !_hasMore) return;
    if (_controller.position.pixels >=
        _controller.position.maxScrollExtent - 500) {
      _loadNext();
    }
  }

  Future<void> _loadNext() async {
    if (_loading || !_hasMore) return;
    final provider = _provider ??= _resolveProvider();
    if (provider == null) {
      if (mounted) {
        setState(() => _error = StateError('AnimeWitcher Native unavailable'));
      }
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await provider.getUpcomingPage(offset: _offset);
      if (!mounted) return;
      setState(() {
        for (final item in page.items) {
          final key = item.url.trim().isEmpty
              ? '${item.id}|${item.title}'
              : item.url;
          if (_seen.add(key)) _items.add(item);
        }
        _offset = page.nextOffset;
        _hasMore = page.hasMore;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  Future<void> _refresh() async {
    setState(() {
      _items.clear();
      _seen.clear();
      _offset = 0;
      _hasMore = true;
      _error = null;
      _loading = false;
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

    final embedded = MorePaneScope.of(context);
    return CatalogPage(
      title: 'القادم قريبًا',
      canPop: !embedded && Navigator.of(context).canPop(),
      onBack: () => Navigator.of(context).pop(),
      builder: (context, topInset) => CatalogBody(
        topInset: topInset,
        isLoading: _loading,
        errorMessage: _items.isEmpty && _error != null
            ? 'تعذر تحميل الأعمال القادمة'
            : null,
        onRetry: _refresh,
        emptyMessage: 'لا توجد أعمال قادمة حاليًا',
        onRefresh: _refresh,
        scrollController: _controller,
        footer: _loading || (_error != null && _hasMore)
            ? CatalogFooter.loading
            : CatalogFooter.none,
        footerBuilder: (context, _) => _error != null
            ? IconButton(
                tooltip: 'إعادة المحاولة',
                onPressed: _loadNext,
                icon: const Icon(Icons.refresh_rounded),
              )
            : const AnimePosterShimmer(),
        itemCount: _items.length,
        itemBuilder: (context, index) {
          final item = _items[index];
          return MultimediaCard.fromItem(
            key: ValueKey('coming-${item.url}'),
            item: item,
            heroTag: 'coming-${item.id}-$index',
            onTap: () =>
                DetailsRoute($extra: DetailsRouteExtra(item: item))
                    .push<void>(context),
          );
        },
      ),
    );
  }
}
