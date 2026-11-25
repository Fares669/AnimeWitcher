import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:animewitcher/core/utils/responsive_breakpoints.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/utils/layout_constants.dart';

import 'package:animewitcher/features/home/presentation/widgets/continue_watching_card.dart';
import 'package:animewitcher/features/home/presentation/widgets/home_section_header.dart';
import 'package:animewitcher/features/library/presentation/history_provider.dart';
import 'package:animewitcher/shared/widgets/desktop_scroll_wrapper.dart';
import 'package:animewitcher/shared/widgets/paged_rail.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:animewitcher/core/services/notification_service.dart';

class ContinueWatchingSection extends ConsumerStatefulWidget {
  final String title;
  final List<HistoryItem> items;
  final double? topPadding;

  const ContinueWatchingSection({
    super.key,
    required this.title,
    required this.items,
    this.topPadding,
  });

  @override
  ConsumerState<ContinueWatchingSection> createState() =>
      _ContinueWatchingSectionState();
}

class _ContinueWatchingSectionState
    extends ConsumerState<ContinueWatchingSection> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) return const SizedBox.shrink();

    final isLarge = context.isTabletOrLarger;

    final double width = isLarge ? 360.0 : 280.0;
    final double listHeight = isLarge ? 200.0 : 150.0;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HomeSectionHeader(
            title: widget.title,
            topPadding: widget.topPadding ?? 24,
            bottomPadding: 12,
            action: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(LayoutConstants.radiusMd),
                hoverColor: Colors.red.withValues(alpha: 0.15),
                onTap: () {
                  final l10n = AppLocalizations.of(context)!;
                  final providerId = ref
                      .read(activeProviderProvider)
                      ?.packageName;
                  showDialog<void>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: Text(l10n.clearAllHistory),
                      content: Text(l10n.confirmClearHistory),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: Text(l10n.cancel),
                        ),
                        TextButton(
                          onPressed: () {
                            ref
                                .read(continueWatchingProvider.notifier)
                                .clearAllFor(providerId);
                            Navigator.pop(context);
                            ref
                                .read(notificationServiceProvider)
                                .showSuccess(l10n.watchHistoryCleared);
                          },
                          child: Text(
                            l10n.clearAll,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.delete_outline,
                        size: 16,
                        color: Colors.red,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        AppLocalizations.of(context)!.clearAll,
                        style: const TextStyle(
                          color: Colors.red,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          SizedBox(
            height: listHeight,
            child: DesktopScrollWrapper(
              controller: _scrollController,
              showButtons: isLarge, // Show nav buttons on desktop and TV
              // Stride-aligned (one card per click) so the rail's snap
              // logic doesn't re-animate after a button click.
              scrollAmount: width + 16,
              child: Builder(
                builder: (context) {
                  const double spacing = 16.0;
                  return PagedRail(
                    controller: _scrollController,
                    itemExtent: width + spacing,
                    physics: const BouncingScrollPhysics(
                      parent: AlwaysScrollableScrollPhysics(),
                    ),
                    padding: EdgeInsets.symmetric(
                      horizontal: isLarge
                          ? LayoutConstants.dashboardContentPadding
                          : 16,
                      vertical: 8,
                    ),
                    itemCount: widget.items.length,
                    itemBuilder: (context, index) {
                      final historyItem = widget.items[index];
                      // itemExtent hands children TIGHT width constraints, so
                      // the SizedBox(width:) would be overridden and the card
                      // would stretch across the whole stride (losing the
                      // 16px gap). Padding deflates the constraints instead.
                      return Padding(
                        padding: const EdgeInsetsDirectional.only(end: spacing),
                        child: ContinueWatchingCard(
                          key: ValueKey(historyItem.item.url),
                          historyItem: historyItem,
                          width: width,
                          isLarge: isLarge,
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
