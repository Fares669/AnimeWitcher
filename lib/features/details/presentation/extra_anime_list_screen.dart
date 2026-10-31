import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/account/animewitcher_character_models.dart';
import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/extensions/base_provider.dart';
import '../../../core/extensions/extension_manager.dart';
import '../../../core/router/app_router.dart';
import '../../../shared/widgets/catalog_page.dart';
import '../../../shared/widgets/multimedia_card.dart';
import 'widgets/details_poster_grid.dart';

typedef ExtraAnimeListLoader =
    Future<List<MultimediaItem>> Function(AnimeWitcherProvider provider);

class ExtraAnimeListScreen extends ConsumerStatefulWidget {
  const ExtraAnimeListScreen({
    super.key,
    required this.source,
    required this.title,
    required this.emptyMessage,
    required this.keyPrefix,
    required this.load,
    this.showRelationBadge = false,
  });

  factory ExtraAnimeListScreen.related({
    Key? key,
    required MultimediaItem source,
  }) {
    return ExtraAnimeListScreen(
      key: key,
      source: source,
      title: animeWitcherRelatedTabLabel,
      emptyMessage: animeWitcherRelatedEmptyMessage,
      keyPrefix: 'related-all',
      showRelationBadge: true,
      load: (provider) async {
        final page = await provider.getRelatedPage(
          source.url,
          includeAll: true,
        );
        return page.items;
      },
    );
  }

  factory ExtraAnimeListScreen.similar({
    Key? key,
    required MultimediaItem source,
  }) {
    return ExtraAnimeListScreen(
      key: key,
      source: source,
      title: animeWitcherSimilarTabLabel,
      emptyMessage: animeWitcherSimilarEmptyMessage,
      keyPrefix: 'similar-all',
      load: (provider) async {
        final page = await provider.getRecommendationsPage(
          source.url,
          includeAll: true,
        );
        return page.items;
      },
    );
  }

  final MultimediaItem source;
  final String title;
  final String emptyMessage;
  final String keyPrefix;
  final ExtraAnimeListLoader load;
  final bool showRelationBadge;

  @override
  ConsumerState<ExtraAnimeListScreen> createState() =>
      _ExtraAnimeListScreenState();
}

class RelatedAnimeScreen extends StatelessWidget {
  const RelatedAnimeScreen({super.key, required this.source});

  final MultimediaItem source;

  @override
  Widget build(BuildContext context) {
    return ExtraAnimeListScreen.related(source: source);
  }
}

class SimilarAnimeScreen extends StatelessWidget {
  const SimilarAnimeScreen({super.key, required this.source});

  final MultimediaItem source;

  @override
  Widget build(BuildContext context) {
    return ExtraAnimeListScreen.similar(source: source);
  }
}

class _ExtraAnimeListScreenState extends ConsumerState<ExtraAnimeListScreen> {
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
      final items = await widget.load(provider);
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(items);
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
    return CatalogPage(
      title: widget.title,
      onBack: () => Navigator.of(context).pop(),
      builder: (context, topInset) => CatalogBody(
        topInset: topInset,
        isLoading: _loading,
        errorMessage: _error != null ? 'تعذر تحميل النتائج' : null,
        onRetry: _load,
        emptyMessage: widget.emptyMessage,
        onRefresh: _load,
        crossAxisSpacingFallback: detailsExtraTabCrossAxisSpacing,
        mainAxisSpacingFallback: detailsExtraTabMainAxisSpacing,
        itemCount: _items.length,
        itemBuilder: (context, index) {
          final item = _items[index];
          return MultimediaCard.fromItem(
            key: ValueKey('${widget.keyPrefix}-$index'),
            item: item,
            heroTag: heroTagWithUrl(widget.keyPrefix, item, index),
            showRelationBadge: widget.showRelationBadge,
            onTap: () {
              final target = _inheritProvider(item);
              DetailsRoute(
                $extra: DetailsRouteExtra(item: target),
              ).push<void>(context);
            },
          );
        },
      ),
    );
  }
}


