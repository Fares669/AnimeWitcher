import 'more_sidebar_shell.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/notification_service.dart';
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
  });

  /// The library filter's order; "latest added" here is latest watched.
  final LibrarySort sort;
  final double topPadding;

  @override
  ConsumerState<RecentWatchedBody> createState() => _RecentWatchedBodyState();
}

class _RecentWatchedBodyState extends ConsumerState<RecentWatchedBody> {
  bool _initialSyncRunning = true;

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
    final history = sortLibraryHistory(
      ref.watch(watchHistoryProvider),
      widget.sort,
    );

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
          heroTag: 'recent-${item.id}-$index',
          onTap: () =>
              DetailsRoute($extra: DetailsRouteExtra(item: item))
                  .push<void>(context),
          onLongPress: () {
            HapticFeedback.mediumImpact();
            unawaited(
              ref
                  .read(watchHistoryProvider.notifier)
                  .removeFromHistory(item.url)
                  .then((_) {
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
