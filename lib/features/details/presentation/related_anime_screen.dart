import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/account/animewitcher_character_models.dart';
import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/extensions/extension_manager.dart';
import '../../../core/router/app_router.dart';
import '../../../shared/widgets/anime_catalog_shimmer.dart';
import '../../../shared/widgets/apple_liquid_glass.dart';
import 'widgets/details_poster_grid.dart';

class RelatedAnimeScreen extends ConsumerStatefulWidget {
  const RelatedAnimeScreen({
    super.key,
    required this.source,
  });

  final MultimediaItem source;

  @override
  ConsumerState<RelatedAnimeScreen> createState() => _RelatedAnimeScreenState();
}

class _RelatedAnimeScreenState extends ConsumerState<RelatedAnimeScreen> {
  final List<MultimediaItem> _items = <MultimediaItem>[];
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_load());
    });
  }

  Future<void> _load() async {
    final provider = ref.read(activeProviderProvider);
    if (provider == null) {
      if (mounted) {
        setState(() {
          _error = StateError('AnimeWitcher Native unavailable');
          _loading = false;
        });
      }
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await provider.getRelatedPage(
        widget.source.url,
        includeAll: true,
      );
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(page.items);
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

  MultimediaItem _inheritProvider(MultimediaItem child) {
    final childProvider = child.provider?.trim();
    if (childProvider != null && childProvider.isNotEmpty) return child;
    final parentProvider = widget.source.provider?.trim();
    if (parentProvider == null || parentProvider.isEmpty) return child;
    return child.copyWith(provider: parentProvider);
  }

  @override
  Widget build(BuildContext context) {
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
              child: const Align(
                alignment: Alignment.centerRight,
                child: Directionality(
                  textDirection: TextDirection.rtl,
                  child: Text(animeWitcherRelatedTabLabel),
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
      body: _loading
          ? const AnimeCatalogShimmer()
          : _error != null
              ? Center(
                  child: FilledButton.tonalIcon(
                    onPressed: _load,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('إعادة المحاولة'),
                  ),
                )
              : _items.isEmpty
                  ? const Center(child: Text(animeWitcherRelatedEmptyMessage))
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 110),
                        children: [
                          DetailsPosterGrid(
                            keyPrefix: 'related-all',
                            items: _items,
                            showRelationBadge: true,
                            onItemTap: (item) {
                              final target = _inheritProvider(item);
                              DetailsRoute(
                                $extra: DetailsRouteExtra(item: target),
                              ).push<void>(context);
                            },
                          ),
                        ],
                      ),
                    ),
    );
  }
}
