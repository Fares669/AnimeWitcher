import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/domain/entity/manga.dart';
import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/extensions/base_provider.dart';
import '../../../core/extensions/extension_manager.dart';
import '../../../core/router/app_router.dart';
import '../../../shared/widgets/anime_catalog_shimmer.dart';
import '../../../shared/widgets/app_side_menu.dart';
import '../../../shared/widgets/catalog_direction.dart';
import '../../../shared/widgets/multimedia_card.dart';
import '../../home/presentation/widgets/home_section_header.dart';
import '../../home/presentation/widgets/latest_manga_chapters_section.dart';
import 'manga_home_prefetch.dart';
import 'manga_view_all_screen.dart';

/// Manga on a tab of its own, for a viewer who turned that tab on: the new
/// chapters along the top, then two rows of the most read. Each has its
/// "عرض الكل" for the rest, a page that loads more as it is scrolled. While
/// this tab is on, home leaves manga out.
class MangaHomeScreen extends ConsumerStatefulWidget {
  const MangaHomeScreen({super.key});

  @override
  ConsumerState<MangaHomeScreen> createState() => _MangaHomeScreenState();
}

class _MangaHomeScreenState extends ConsumerState<MangaHomeScreen> {
  List<MangaLatestChapter> _latest = const <MangaLatestChapter>[];
  List<MultimediaItem> _popular = const <MultimediaItem>[];
  bool _loading = false;
  bool _failed = false;
  int _loadGeneration = 0;

  /// Rows of the most read shown here; "عرض الكل" has the rest.
  static const int _popularRows = 2;

  @override
  void initState() {
    super.initState();
    final prefetched = ref.read(mangaHomeWarmupProvider).open();
    final provider = prefetched == null ? null : _provider();
    final warm = identical(prefetched?.source, provider) ? prefetched : null;
    _latest = warm?.cachedLatest ?? _latest;
    _popular = warm?.cachedPopular ?? _popular;
    // An in-flight request belongs to the first entry. A settled prefetch
    // still seeds the screen and then gets the usual background refresh.
    final latest = warm?.pendingLatest;
    final popular = warm?.pendingPopular;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        _reload(warmSource: provider, warmLatest: latest, warmPopular: popular),
      );
    });
  }

  AnimeWitcherProvider? _provider() =>
      mangaCatalogueOf(ref.read(extensionManagerProvider));

  Future<void> _reload({
    AnimeWitcherProvider? warmSource,
    Future<List<MangaLatestChapter>?>? warmLatest,
    Future<List<MultimediaItem>?>? warmPopular,
  }) async {
    final generation = ++_loadGeneration;
    final provider = _provider();
    setState(() {
      _failed = false;
      _loading = provider != null && _popular.isEmpty;
    });
    if (provider == null) return;
    final useWarmup = identical(provider, warmSource);
    bool isCurrent() => mounted && generation == _loadGeneration;
    Future<void> loadLatest() async {
      try {
        final prefetched = useWarmup && warmLatest != null
            ? await warmLatest
            : null;
        if (!isCurrent()) return;
        final items = prefetched ?? await loadMangaHomeLatest(provider);
        if (isCurrent()) setState(() => _latest = items);
      } catch (_) {}
    }

    unawaited(loadLatest());
    // Rows already on screen stay there while the fresh ones load.
    try {
      final prefetched = useWarmup && warmPopular != null
          ? await warmPopular
          : null;
      if (!isCurrent()) return;
      final items = prefetched ?? await loadMangaHomePopular(provider);
      if (isCurrent()) setState(() => _popular = items);
    } catch (_) {
      if (isCurrent()) setState(() => _failed = true);
    } finally {
      if (isCurrent()) setState(() => _loading = false);
    }
  }

  void _openLatest() {
    final provider = _provider();
    if (provider == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MangaViewAllScreen<MangaLatestChapter>(
          title: 'فصول جديدة',
          load: (offset) async {
            final page = await provider.getLatestMangaPage(
              offset: offset,
              limit: 30,
            );
            return (
              items: page.items,
              nextOffset: page.nextOffset,
              hasMore: page.hasMore,
            );
          },
          itemKey: (entry) => '${entry.manga.url}#${entry.chapter.id}',
          itemBuilder: (context, entry, index) => LatestMangaChapterCard(
            entry: entry,
            heroTag:
                'manga_latest_all_${entry.manga.url}_${entry.chapter.id}_$index',
            onTap: () => _open(context, entry.manga),
          ),
        ),
      ),
    );
  }

  void _openPopular() {
    final provider = _provider();
    if (provider == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MangaViewAllScreen<MultimediaItem>(
          title: 'الأكثر قراءة',
          load: (offset) async {
            final page = await provider.searchMangaPage(
              '',
              const ProviderSearchFilters(),
              offset: offset,
              limit: provider.searchPageSize,
            );
            return (
              items: page.items,
              nextOffset: page.nextOffset,
              hasMore: page.hasMore,
            );
          },
          itemKey: (item) => item.url,
          itemBuilder: (context, item, index) => MultimediaCard.fromItem(
            key: ValueKey<String>('manga-popular-all-${item.url}'),
            item: item,
            heroTag: heroTagWithUrl('manga_popular_all', item, index),
            onTap: () => _open(context, item),
          ),
        ),
      ),
    );
  }

  void _open(BuildContext context, MultimediaItem item) {
    MangaDetailsRoute($extra: MangaDetailsRouteExtra(item: item))
        .push<void>(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final padding = MultimediaCardLayout.catalogGridHorizontalPadding(context);
    final mq = MediaQuery.of(context);

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: _reload,
        child: CustomScrollView(
          key: const PageStorageKey<String>('manga-home'),
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: <Widget>[
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  padding + 8,
                  mq.padding.top + 24,
                  padding + 8,
                  8,
                ),
                child: Row(
                  children: <Widget>[
                    Icon(
                      Icons.menu_book_rounded,
                      color: theme.colorScheme.primary,
                      size: 28,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'المانجا',
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    // The side menu's button, in the corner it comes from.
                    const AppSideMenuButton(),
                  ],
                ),
              ),
            ),
            if (_latest.isNotEmpty)
              SliverToBoxAdapter(
                child: LatestMangaChaptersSection(
                  title: 'فصول جديدة',
                  items: _latest,
                  onTap: (latest) => _open(context, latest.manga),
                  onViewAll: _openLatest,
                ),
              ),
            SliverToBoxAdapter(
              child: HomeSectionHeader(
                key: const ValueKey<String>('manga-popular-header'),
                title: 'الأكثر قراءة',
                action: _popular.isEmpty
                    ? null
                    : HomeViewAllButton(onTap: _openPopular),
              ),
            ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                padding,
                4,
                padding,
                24 + mq.padding.bottom,
              ),
              sliver: _failed && _popular.isEmpty
                  ? SliverToBoxAdapter(
                      child: Center(
                        child: FilledButton.tonalIcon(
                          onPressed: _reload,
                          icon: const Icon(Icons.refresh_rounded),
                          label: Text('إعادة المحاولة'),
                        ),
                      ),
                    )
                  : SliverLayoutBuilder(
                      builder: (context, constraints) {
                        final delegate = mangaPosterGridDelegate(context);
                        final layout = delegate.getLayout(constraints);
                        final columns = layout is SliverGridRegularTileLayout
                            ? layout.crossAxisCount
                            : 3;
                        final shown = columns * _popularRows;
                        final count = _popular.isEmpty && _loading
                            ? shown
                            : _popular.length.clamp(0, shown);
                        return SliverGrid(
                          gridDelegate: delegate,
                          delegate: SliverChildBuilderDelegate((
                            context,
                            index,
                          ) {
                            if (index >= _popular.length) {
                              return const AnimePosterShimmer();
                            }
                            final item = _popular[index];
                            return CatalogDirection(
                              child: MultimediaCard.fromItem(
                                key: ValueKey<String>('manga-home-${item.url}'),
                                item: item,
                                heroTag: heroTagWithUrl(
                                  'manga_home',
                                  item,
                                  index,
                                ),
                                onTap: () => _open(context, item),
                              ),
                            );
                          }, childCount: count),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
