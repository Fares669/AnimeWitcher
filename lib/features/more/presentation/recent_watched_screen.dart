import 'more_sidebar_shell.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/notification_service.dart';
import '../../../core/storage/history_repository.dart'
    show WatchHistorySnapshot;
import '../../../shared/widgets/catalog_page.dart';
import '../../../shared/widgets/multimedia_card.dart';
import '../../../core/router/app_router.dart';
import '../../library/presentation/history_provider.dart';
import '../../library/presentation/library_lists.dart';

class RecentWatchedScreen extends StatelessWidget {
  const RecentWatchedScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final embedded = MorePaneScope.of(context);
    return CatalogPage(
      title: 'آخر المشاهدات',
      canPop: !embedded && Navigator.of(context).canPop(),
      onBack: () => Navigator.of(context).pop(),
      builder: (context, topInset) => RecentWatchedBody(topPadding: topInset),
    );
  }
}

/// The watch history as a poster grid, latest first, synced from the
/// account when it opens. Long press takes a title off it. The library's
/// "آخر المشاهدات" and the full page both show this.
class RecentWatchedBody extends ConsumerStatefulWidget {
  const RecentWatchedBody({
    super.key,
    this.sort = LibrarySort.added,
    this.topPadding = 0,
    this.isActive = true,
  });

  /// The library filter's order; "latest added" here is latest watched.
  final LibrarySort sort;
  final double topPadding;

  /// A neighbouring phone tab can be mounted before it is selected.
  final bool isActive;

  @override
  ConsumerState<RecentWatchedBody> createState() => _RecentWatchedBodyState();
}

class _RecentWatchedBodyState extends ConsumerState<RecentWatchedBody> {
  bool _initialSyncRunning = false;
  int _refreshGeneration = 0;
  List<HistoryItem>? _sortedSource;
  LibrarySort? _sortedOrder;
  List<HistoryItem> _sortedHistory = const [];

  @override
  void initState() {
    super.initState();
    if (widget.isActive) _refreshOnEntry();
  }

  @override
  void didUpdateWidget(covariant RecentWatchedBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive) _refreshOnEntry();
  }

  void _refreshOnEntry() {
    _initialSyncRunning = true;
    Future<void>.microtask(() async {
      if (mounted && widget.isActive) await _refreshFromServer();
    });
  }

  Future<void> _refreshFromServer() async {
    if (!mounted) return;
    final generation = ++_refreshGeneration;
    try {
      await ref.read(watchHistoryProvider.notifier).refreshFromServer();
    } catch (_) {
      // Keep the last local snapshot available when the network/server is
      // temporarily unavailable. Pull-to-refresh can retry at any time.
    } finally {
      if (mounted && generation == _refreshGeneration) {
        setState(() => _initialSyncRunning = false);
      }
    }
  }

  // Storage normally publishes newest first. Keep the normal sort for
  // equal timestamps because List.sort does not promise stable tie order.
  // Restrict reuse to owned immutable snapshots; providers can be overridden.
  bool _canUsePublishedOrder(List<HistoryItem> source) {
    if (widget.sort != LibrarySort.added || source is! WatchHistorySnapshot) {
      return false;
    }
    for (var i = 1; i < source.length; i++) {
      if (source[i - 1].timestamp <= source[i].timestamp) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final source = ref.watch(watchHistoryProvider);
    if (!identical(_sortedSource, source) || _sortedOrder != widget.sort) {
      _sortedHistory = _canUsePublishedOrder(source)
          ? source
          : sortLibraryHistory(source, widget.sort);
      _sortedSource = source;
      _sortedOrder = widget.sort;
    }
    final history = _sortedHistory;

    return CatalogBody(
      topInset: widget.topPadding,
      isLoading: _initialSyncRunning,
      emptyWidget: const _EmptyRecentWatched(),
      onRefresh: _refreshFromServer,
      itemCount: history.length,
      itemBuilder: (context, index) {
        final historyItem = history[index];
        final item = historyItem.item;
        return MultimediaCard.fromItem(
          key: ValueKey('recent-${item.url}'),
          item: item,
          heroTag: heroTagWithId('recent', item, index, dashed: true),
          onTap: () => item.openDetails(context),
          onLongPress: () {
            HapticFeedback.mediumImpact();
            unawaited(
              ref.read(watchHistoryProvider.notifier).removeForItem(item).then((
                _,
              ) {
                if (!context.mounted) return;
                ref
                    .read(notificationServiceProvider)
                    .showSuccess('تم حذف ${item.title} من آخر المشاهدات');
              }),
            );
          },
        );
      },
    );
  }
}

class _EmptyRecentWatched extends StatelessWidget {
  const _EmptyRecentWatched();

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
              'لا توجد مشاهدات حتى الآن',
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
