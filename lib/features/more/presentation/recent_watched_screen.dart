import 'more_sidebar_shell.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:animewitcher/shared/widgets/mouse_drag_refresh_indicator.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:animewitcher/shared/widgets/apple_liquid_glass.dart';

import '../../../core/services/notification_service.dart';
import '../../../core/utils/responsive_breakpoints.dart';
import '../../../shared/widgets/anime_catalog_shimmer.dart';
import '../../../shared/widgets/catalog_direction.dart';
import '../../../shared/widgets/multimedia_card.dart';
import '../../details/presentation/details_screen.dart';
import '../../library/presentation/history_provider.dart';
import '../../library/presentation/library_lists.dart';
import '../../../core/utils/window_controls_inset.dart';

class RecentWatchedScreen extends StatelessWidget {
  const RecentWatchedScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final isArabic =
        Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';
    return Scaffold(
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(kToolbarHeight),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: AppBar(
            automaticallyImplyLeading: false,
            centerTitle: false,
            titleSpacing: 16,
            // Leave the window's caption buttons their corner; the
            // title is aligned to that same edge in Arabic.
            actions: const <Widget>[WindowControlsGap()],
            title: ApplePersistentGlassHeaderScope(
              enabled:
                  !MorePaneScope.of(context) && Navigator.of(context).canPop(),
              onBack: () => Navigator.of(context).pop(),
              child: Align(
                alignment: isArabic
                    ? Alignment.centerRight
                    : Alignment.centerLeft,
                child: Directionality(
                  textDirection: isArabic
                      ? TextDirection.rtl
                      : TextDirection.ltr,
                  child: Text(isArabic ? 'آخر المشاهدات' : 'Recently watched'),
                ),
              ),
            ),
            leading:
                appleUsesPersistentLiquidGlassHeader ||
                    MorePaneScope.of(context)
                ? null
                : AppleLiquidGlassBackButton(
                    onPressed: () => Navigator.of(context).pop(),
                  ),
            elevation: 0,
          ),
        ),
      ),
      body: const RecentWatchedBody(),
    );
  }
}

/// The watch history as a poster grid, latest first, synced from the
/// account when it opens. Long press takes a title off it. The library's
/// "آخر المشاهدات" and the full page both show this.
class RecentWatchedBody extends ConsumerStatefulWidget {
  const RecentWatchedBody({super.key, this.sort = LibrarySort.added});

  /// The library filter's order; "latest added" here is latest watched.
  final LibrarySort sort;

  @override
  ConsumerState<RecentWatchedBody> createState() => _RecentWatchedBodyState();
}

class _RecentWatchedBodyState extends ConsumerState<RecentWatchedBody> {
  bool _initialSyncRunning = true;

  bool _isArabic(BuildContext context) =>
      Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';

  @override
  void initState() {
    super.initState();
    Future<void>.microtask(_refreshFromServer);
  }

  Future<void> _refreshFromServer() async {
    try {
      await ref.read(watchHistoryProvider.notifier).refreshFromServer();
    } catch (_) {
      // Keep the last local snapshot available when the network/server is
      // temporarily unavailable. Pull-to-refresh can retry at any time.
    } finally {
      if (mounted) setState(() => _initialSyncRunning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isArabic = _isArabic(context);
    final history = sortLibraryHistory(
      ref.watch(watchHistoryProvider),
      widget.sort,
    );

    Widget body;
    if (_initialSyncRunning && history.isEmpty) {
      body = const AnimeCatalogShimmer();
    } else if (history.isEmpty) {
      body = MouseDragRefreshIndicator(
        onRefresh: _refreshFromServer,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(
              height: MediaQuery.sizeOf(context).height * 0.65,
              child: _EmptyRecentWatched(isArabic: isArabic),
            ),
          ],
        ),
      );
    } else {
      body = MouseDragRefreshIndicator(
        onRefresh: _refreshFromServer,
        child: _RecentWatchedGrid(
          items: history,
          onRemove: (historyItem) {
            HapticFeedback.mediumImpact();
            unawaited(
              ref
                  .read(watchHistoryProvider.notifier)
                  .removeFromHistory(historyItem.item.url)
                  .then((_) {
                    if (!context.mounted) return;
                    ref
                        .read(notificationServiceProvider)
                        .showSuccess(
                          isArabic
                              ? 'تم حذف ${historyItem.item.title} من آخر المشاهدات'
                              : '${historyItem.item.title} removed from recent history',
                        );
                  }),
            );
          },
        ),
      );
    }

    return body;
  }
}

class _RecentWatchedGrid extends StatelessWidget {
  const _RecentWatchedGrid({required this.items, required this.onRemove});

  final List<HistoryItem> items;
  final ValueChanged<HistoryItem> onRemove;

  @override
  Widget build(BuildContext context) {
    final isDesktop = context.isDesktop;
    return CatalogDirection(
      child: GridView.builder(
        padding: EdgeInsets.fromLTRB(
          MultimediaCardLayout.catalogGridHorizontalPadding(context),
          16,
          MultimediaCardLayout.catalogGridHorizontalPadding(context),
          110,
        ),
        gridDelegate: ResponsiveBreakpoints.animeGridDelegate(
          context,
          maxCrossAxisExtent: isDesktop ? 240 : 150,
          childAspectRatio: MultimediaCardLayout.gridAspectRatio(
            isPortrait: true,
            isDesktop: isDesktop,
          ),
          crossAxisSpacing: MultimediaCardLayout.catalogGridCrossAxisSpacing(
            context,
          ),
          mainAxisSpacing: MultimediaCardLayout.catalogGridMainAxisSpacing(
            context,
          ),
          handsetPortraitCrossAxisCount:
              MultimediaCardLayout.handsetPortraitGridColumns,
          horizontalPadding: MultimediaCardLayout.catalogGridHorizontalPadding(
            context,
          ),
        ),
        itemCount: items.length,
        itemBuilder: (context, index) {
          final history = items[index];
          final item = history.item;
          return MultimediaCard.fromItem(
            key: ValueKey('recent-${item.url}'),
            item: item,
            heroTag: 'recent-${item.id}-$index',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => DetailsScreen(item: item),
              ),
            ),
            onLongPress: () => onRemove(history),
          );
        },
      ),
    );
  }
}

class _EmptyRecentWatched extends StatelessWidget {
  const _EmptyRecentWatched({required this.isArabic});

  final bool isArabic;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.history_rounded, size: 52, color: colors.primary),
            const SizedBox(height: 14),
            Text(
              isArabic ? 'لا توجد مشاهدات حتى الآن' : 'Nothing watched yet',
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
