import 'package:flutter/material.dart';

import '../../core/utils/localized_text.dart';

/// Recoverable full-page state for catalog requests that could not reach the
/// network. It deliberately remains scrollable so pull-to-refresh works even
/// when there are no cards to scroll.
class RecoverableNetworkState extends StatefulWidget {
  const RecoverableNetworkState({
    super.key,
    required this.onRetry,
    this.onOpenDownloads,
  });

  final Future<void> Function() onRetry;
  final VoidCallback? onOpenDownloads;

  @override
  State<RecoverableNetworkState> createState() =>
      _RecoverableNetworkStateState();
}

class _RecoverableNetworkStateState extends State<RecoverableNetworkState>
    with NetworkRetryState<RecoverableNetworkState> {
  @override
  Future<void> Function() get onRetry => widget.onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return RefreshIndicator.adaptive(
      onRefresh: retry,
      child: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Center(
                child: Semantics(
                  liveRegion: true,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.wifi_off_rounded,
                        size: 72,
                        color: theme.colorScheme.error,
                      ),
                      const SizedBox(height: 20),
                      Text(
                        appText(
                          context,
                          english: 'Unable to connect',
                          arabic: 'تعذر الاتصال بالإنترنت',
                        ),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        appText(
                          context,
                          english:
                              'Check your connection, then try again or continue with downloaded episodes.',
                          arabic:
                              'تحقق من اتصالك ثم أعد المحاولة، أو تابع الحلقات التي نزّلتها مسبقًا.',
                        ),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 28),
                      Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          buildRetryButton(context),
                          OutlinedButton.icon(
                            onPressed: widget.onOpenDownloads,
                            icon: const Icon(
                              Icons.download_for_offline_rounded,
                            ),
                            label: Text(
                              appText(
                                context,
                                english: 'Downloads',
                                arabic: 'التنزيلات',
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Shares the in-flight retry guard between the button and any refresh gesture.
mixin NetworkRetryState<T extends StatefulWidget> on State<T> {
  bool _isRetrying = false;

  Future<void> Function() get onRetry;

  Future<void> retry() async {
    if (_isRetrying) return;
    setState(() => _isRetrying = true);
    try {
      await onRetry();
    } finally {
      if (mounted) setState(() => _isRetrying = false);
    }
  }

  Widget buildRetryButton(BuildContext context) {
    return FilledButton.icon(
      onPressed: _isRetrying ? null : retry,
      icon: _isRetrying
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.refresh_rounded),
      label: Text(appText(context, english: 'Retry', arabic: 'إعادة المحاولة')),
    );
  }
}
