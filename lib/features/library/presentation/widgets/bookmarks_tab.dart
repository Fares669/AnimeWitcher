import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/account/account_providers.dart';
import '../../../../core/extensions/extension_manager.dart';
import '../../../../core/storage/provider_local_library.dart';
import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/router/app_router.dart';
import '../../../../core/utils/layout_constants.dart';
import '../../../../core/utils/localized_text.dart';
import '../../../../core/utils/responsive_breakpoints.dart';
import '../../../../shared/widgets/catalog_direction.dart';
import '../../../../shared/widgets/anime_catalog_shimmer.dart';
import '../../../../shared/widgets/multimedia_card.dart';
import '../../../settings/presentation/account_screen.dart';
import '../library_auth.dart';
import '../library_lists.dart';
import '../library_provider.dart';
import '../library_media_kind.dart';

import '../library_state.dart';

class BookmarksTab extends ConsumerStatefulWidget {
  const BookmarksTab({super.key, this.sort});

  /// The order from the library's filter; the stored order when null.
  final LibrarySort? sort;

  @override
  ConsumerState<BookmarksTab> createState() => _BookmarksTabState();
}

class _BookmarksTabState extends ConsumerState<BookmarksTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final libraryState = ref.watch(libraryProvider);
    final page = ref
        .read(libraryProvider.notifier)
        .pageInfo(libraryState.mediaKind, libraryState.category);
    final content = switch (libraryState) {
      LibraryLoading() => const AnimeCatalogShimmer(),
      LibraryError(message: final msg) => Center(child: Text(msg)),
      LibraryEmpty() =>
        page.hasMore
            ? LibraryItemsGrid(
                items: const [],
                totalCount: page.total,
                hasMore: true,
                loadingMore: page.loading,
                loadFailed: page.loadFailed,
                onLoadMore: () => ref
                    .read(libraryProvider.notifier)
                    .loadNextPage(
                      mediaKind: libraryState.mediaKind,
                      category: libraryState.category,
                    ),
              )
            : LibraryEmptyState(mediaKind: libraryState.mediaKind),
      LibrarySuccess(items: final items) => LibraryItemsGrid(
        items: widget.sort == null
            ? items
            : sortLibraryItems(items, widget.sort!),
        totalCount: page.total,
        hasMore: page.hasMore,
        loadingMore: page.loading,
        loadFailed: page.loadFailed,
        onLoadMore: () => ref
            .read(libraryProvider.notifier)
            .loadNextPage(
              mediaKind: libraryState.mediaKind,
              category: libraryState.category,
            ),
      ),
    };
    return content;
  }
}

/// Opens [item] on its own details page, anime or manga.
void openLibraryItem(BuildContext context, MultimediaItem item) {
  if (item.contentType == MultimediaContentType.manga) {
    MangaDetailsRoute($extra: MangaDetailsRouteExtra(item: item))
        .push<void>(context);
    return;
  }
  item.openDetails(context);
}

/// The library's poster grid. [labels], when given, names the list each
/// title came from in a tag on its poster, as the phone's search does.
class LibraryItemsGrid extends StatelessWidget {
  const LibraryItemsGrid({
    super.key,
    required this.items,
    this.labels,
    this.heroPrefix = 'lib_bookmark',
    this.onLongPress,
    this.totalCount,
    this.hasMore = false,
    this.loadingMore = false,
    this.loadFailed = false,
    this.onLoadMore,
  });

  final List<MultimediaItem> items;
  final List<String>? labels;
  final String heroPrefix;
  final void Function(MultimediaItem item)? onLongPress;
  final int? totalCount;
  final bool hasMore;
  final bool loadingMore;
  final bool loadFailed;
  final Future<void> Function()? onLoadMore;

  @override
  Widget build(BuildContext context) {
    final isDesktop = context.isDesktop;
    final gridHorizontalPadding =
        MultimediaCardLayout.catalogGridHorizontalPadding(context);
    // Poster *width* budget per column, the same the other grids use.
    final double maxCardWidth = isDesktop ? 240.0 : 150.0;
    final colors = Theme.of(context).colorScheme;

    return _LoadUnderfilledPage(
      loadedCount: items.length,
      hasMore: hasMore,
      loading: loadingMore,
      failed: loadFailed,
      onLoadMore: onLoadMore,
      child: CatalogDirection(
        child: NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (notification is ScrollUpdateNotification &&
                notification.metrics.axis == Axis.vertical &&
                hasMore &&
                !loadingMore &&
                !loadFailed &&
                onLoadMore != null &&
                notification.metrics.extentAfter < 500) {
              onLoadMore!();
            }
            return false;
          },
          child: GridView.builder(
            padding: EdgeInsets.fromLTRB(
              gridHorizontalPadding,
              LayoutConstants.spacingMd,
              gridHorizontalPadding,
              100,
            ),
            gridDelegate: ResponsiveBreakpoints.animeGridDelegate(
              context,
              maxCrossAxisExtent: maxCardWidth,
              childAspectRatio: MultimediaCardLayout.gridAspectRatio(
                isPortrait: true,
                isDesktop: isDesktop,
              ),
              crossAxisSpacing:
                  MultimediaCardLayout.catalogGridCrossAxisSpacing(context),
              mainAxisSpacing: MultimediaCardLayout.catalogGridMainAxisSpacing(
                context,
              ),
              handsetPortraitCrossAxisCount:
                  MultimediaCardLayout.handsetPortraitGridColumns,
              horizontalPadding: gridHorizontalPadding,
            ),
            itemCount:
                items.length +
                (loadingMore
                    ? 3
                    : hasMore
                    ? 1
                    : 0),
            itemBuilder: (context, index) {
              if (index >= items.length) {
                return Center(
                  key: ValueKey<String>(
                    'library-lazy-loading-${index - items.length}',
                  ),
                  child: loadingMore
                      ? const AnimePosterShimmer()
                      : TextButton(
                          onPressed: () {
                            onLoadMore?.call();
                          },
                          child: Text(
                            loadFailed
                                ? 'إعادة المحاولة'
                                : totalCount == null
                                ? 'تحميل المزيد'
                                : '${items.length} / $totalCount',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                );
              }
              final item = items[index];
              final card = MultimediaCard.fromItem(
                key: ValueKey(item.url),
                item: item,
                heroTag: heroTagWithUrl(heroPrefix, item, index),
                onTap: () => openLibraryItem(context, item),
                onLongPress: onLongPress == null
                    ? null
                    : () => onLongPress!(item),
              );
              final label = labels?[index];
              if (label == null) return card;
              return Stack(
                children: [
                  Positioned.fill(child: card),
                  PositionedDirectional(
                    top: 6,
                    start: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: colors.surface.withValues(alpha: 0.86),
                        borderRadius: BorderRadius.circular(99),
                      ),
                      child: Text(
                        label,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: colors.primary,
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// A short final row does not produce scroll updates. Trigger exactly one
/// request at that row size so an underfilled library can still advance.
class _LoadUnderfilledPage extends StatefulWidget {
  const _LoadUnderfilledPage({
    required this.loadedCount,
    required this.hasMore,
    required this.loading,
    required this.failed,
    required this.onLoadMore,
    required this.child,
  });

  final int loadedCount;
  final bool hasMore;
  final bool loading;
  final bool failed;
  final Future<void> Function()? onLoadMore;
  final Widget child;

  @override
  State<_LoadUnderfilledPage> createState() => _LoadUnderfilledPageState();
}

class _LoadUnderfilledPageState extends State<_LoadUnderfilledPage> {
  int? _requestedForCount;

  @override
  void didUpdateWidget(covariant _LoadUnderfilledPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.loadedCount != widget.loadedCount || !widget.hasMore) {
      _requestedForCount = null;
    }
  }

  @override
  Widget build(BuildContext context) =>
      NotificationListener<ScrollMetricsNotification>(
        onNotification: (notification) {
          final metrics = notification.metrics;
          if (metrics.axis == Axis.vertical &&
              metrics.maxScrollExtent <= 0 &&
              widget.hasMore &&
              !widget.loading &&
              !widget.failed &&
              widget.onLoadMore != null &&
              _requestedForCount != widget.loadedCount) {
            _requestedForCount = widget.loadedCount;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) widget.onLoadMore?.call();
            });
          }
          return false;
        },
        child: widget.child,
      );
}

/// Said in place of an empty list; for anime while signed out, the way in.
class LibraryEmptyState extends ConsumerWidget {
  const LibraryEmptyState({super.key, required this.mediaKind});

  final LibraryMediaKind mediaKind;

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      _buildEmpty(context, ref, mediaKind);

  Widget _buildEmpty(
    BuildContext context,
    WidgetRef ref,
    LibraryMediaKind mediaKind,
  ) {
    final isManga = mediaKind == LibraryMediaKind.manga;
    final localOnly =
        !isManga &&
        ref.watch(activeProviderProvider)?.packageName == animeRiftProviderId;
    final signedIn =
        isManga ||
        localOnly ||
        (ref
                .watch(animeWitcherAccountControllerProvider)
                .asData
                ?.value
                .isSignedIn ??
            false);
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              signedIn
                  ? Icons.bookmark_outline_rounded
                  : Icons.lock_outline_rounded,
              size: 64,
              color: Theme.of(context).dividerColor,
            ),
            const SizedBox(height: 16),
            Text(
              signedIn
                  ? appText(
                      context,
                      english: isManga
                          ? 'No manga in this list yet'
                          : 'No titles in this list yet',
                      arabic: isManga
                          ? 'لا توجد مانجا في هذه القائمة بعد'
                          : 'لا توجد أعمال في هذه القائمة بعد',
                    )
                  : librarySignInRequiredMessage(),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            if (!signedIn) ...[
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () =>
                    Navigator.of(context, rootNavigator: true).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const AnimeWitcherAccountScreen(),
                      ),
                    ),
                style: FilledButton.styleFrom(
                  backgroundColor: colors.primary,
                  foregroundColor: colors.onPrimary,
                ),
                child: Text(
                  appText(context, english: 'Sign in', arabic: 'تسجيل الدخول'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
