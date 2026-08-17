import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skystream/shared/widgets/apple_liquid_glass.dart';

import '../../../core/services/notification_service.dart';
import '../../../core/utils/responsive_breakpoints.dart';
import '../../../shared/widgets/multimedia_card.dart';
import '../../details/presentation/details_screen.dart';
import '../../library/presentation/history_provider.dart';

class RecentWatchedScreen extends ConsumerStatefulWidget {
  const RecentWatchedScreen({super.key});

  @override
  ConsumerState<RecentWatchedScreen> createState() => _RecentWatchedScreenState();
}

class _RecentWatchedScreenState extends ConsumerState<RecentWatchedScreen> {
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
    final history = ref.watch(watchHistoryProvider).toList(growable: false)
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));

    Widget body;
    if (_initialSyncRunning && history.isEmpty) {
      body = const Center(child: CircularProgressIndicator());
    } else if (history.isEmpty) {
      body = RefreshIndicator(
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
      body = RefreshIndicator(
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
                ref.read(notificationServiceProvider).showSuccess(
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
                alignment: isArabic ? Alignment.centerRight : Alignment.centerLeft,
                child: Directionality(
                  textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
                  child: Text(isArabic ? 'آخر المشاهدات' : 'Recently watched'),
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
      body: body,
    );
  }
}

class _RecentWatchedGrid extends StatelessWidget {
  const _RecentWatchedGrid({
    required this.items,
    required this.onRemove,
  });

  final List<HistoryItem> items;
  final ValueChanged<HistoryItem> onRemove;

  @override
  Widget build(BuildContext context) {
    final isDesktop = context.isDesktop;
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 110),
      gridDelegate: ResponsiveBreakpoints.animeGridDelegate(
        context,
        maxCrossAxisExtent: isDesktop ? 240 : 150,
        childAspectRatio: isDesktop ? 0.58 : 0.55,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final history = items[index];
        final item = history.item;
        return MultimediaCard(
          key: ValueKey('recent-${item.url}'),
          imageUrl: item.posterImageUrl,
          title: item.title,
          heroTag: 'recent-${item.id}-$index',
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => DetailsScreen(item: item),
            ),
          ),
          onLongPress: () => onRemove(history),
        );
      },
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
