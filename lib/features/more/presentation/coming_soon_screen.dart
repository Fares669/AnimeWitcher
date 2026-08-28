import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:animewitcher/shared/widgets/apple_liquid_glass.dart';

import '../../../core/account/account_providers.dart';
import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/extensions/extension_manager.dart';
import '../../../core/extensions/providers/animewitcher_native_provider.dart';
import '../../../core/utils/responsive_breakpoints.dart';
import '../../../shared/widgets/anime_catalog_shimmer.dart';
import '../../../shared/widgets/catalog_ltr.dart';
import '../../../shared/widgets/multimedia_card.dart';
import '../../details/presentation/details_screen.dart';

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

  bool _isArabic(BuildContext context) =>
      Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';

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
    final isArabic = _isArabic(context);
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
              onBack: () => Navigator.of(context).pop(),
              child: Align(
                alignment: isArabic
                    ? Alignment.centerRight
                    : Alignment.centerLeft,
                child: Directionality(
                  textDirection: isArabic
                      ? TextDirection.rtl
                      : TextDirection.ltr,
                  child: Text(isArabic ? 'القادم قريبًا' : 'Coming soon'),
                ),
              ),
            ),
            leading: appleUsesPersistentLiquidGlassHeader
                ? null
                : AppleLiquidGlassBackButton(
                    onPressed: () => Navigator.of(context).pop(),
                  ),
            elevation: 0,
          ),
        ),
      ),
      body: _buildBody(isArabic),
    );
  }

  Widget _buildBody(bool isArabic) {
    if (_items.isEmpty && _loading) {
      return const AnimeCatalogShimmer();
    }
    if (_items.isEmpty && _error != null) {
      return _LoadError(
        message: isArabic
            ? 'تعذر تحميل الأعمال القادمة'
            : 'Could not load upcoming titles',
        onRetry: _refresh,
      );
    }
    if (_items.isEmpty) {
      return Center(
        child: Text(
          isArabic ? 'لا توجد أعمال قادمة حاليًا' : 'No upcoming titles',
        ),
      );
    }

    final isDesktop = context.isDesktop;
    final extra = _loading || (_error != null && _hasMore) ? 1 : 0;
    return RefreshIndicator(
      onRefresh: _refresh,
      child: CatalogLtr(
        child: GridView.builder(
          controller: _controller,
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 110),
          gridDelegate: ResponsiveBreakpoints.animeGridDelegate(
            context,
            maxCrossAxisExtent: isDesktop ? 240 : 150,
            childAspectRatio: MultimediaCardLayout.gridAspectRatio(
              isPortrait: true,
              isDesktop: isDesktop,
            ),
            crossAxisSpacing: 16,
            mainAxisSpacing: 16,
          ),
          itemCount: _items.length + extra,
          itemBuilder: (context, index) {
            if (index >= _items.length) {
              if (_error != null) {
                return IconButton(
                  tooltip: isArabic ? 'إعادة المحاولة' : 'Retry',
                  onPressed: _loadNext,
                  icon: const Icon(Icons.refresh_rounded),
                );
              }
              return const AnimePosterShimmer();
            }
            final item = _items[index];
            return MultimediaCard.fromItem(
              key: ValueKey('coming-${item.url}'),
              item: item,
              heroTag: 'coming-${item.id}-$index',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => DetailsScreen(item: item),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _LoadError extends StatelessWidget {
  const _LoadError({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_rounded, size: 42),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: () => onRetry(),
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('إعادة المحاولة'),
            ),
          ],
        ),
      ),
    );
  }
}
