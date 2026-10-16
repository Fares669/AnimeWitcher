import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/services/download_v2/download_v2_identity.dart';
import '../../../../core/services/download_v2/download_v2_provider.dart';
import '../../../../core/services/notification_service.dart';
import '../../../../core/utils/localized_text.dart';
import '../../../../core/utils/download_time_remaining.dart';
import '../../../../core/utils/file_size_formatter.dart';
import '../../../library/presentation/download_progress_v2_provider.dart';
import '../../../library/presentation/downloads_provider.dart';

import 'package:animewitcher/l10n/generated/app_localizations.dart';

class DownloadProgressDialog extends ConsumerStatefulWidget {
  final String title;

  /// Logical download identity, with tracking URL compatibility for old rows.
  final String trackingUrl;

  const DownloadProgressDialog({
    super.key,
    required this.title,
    required this.trackingUrl,
  });

  static void show(BuildContext context, String title, String trackingUrl) {
    showDialog<void>(
      context: context,
      builder: (context) =>
          DownloadProgressDialog(title: title, trackingUrl: trackingUrl),
    );
  }

  @override
  ConsumerState<DownloadProgressDialog> createState() =>
      _DownloadProgressDialogState();
}

class _DownloadProgressDialogState
    extends ConsumerState<DownloadProgressDialog> {
  bool _dismissRequested = false;
  bool _commandInFlight = false;

  void _dismissOnce() {
    if (_dismissRequested) return;
    _dismissRequested = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
      Navigator.of(context).pop();
    });
  }

  DownloadItem? _itemForTask(String taskId) {
    final items = ref.read(downloadsProvider).value;
    if (items == null) return null;
    for (final item in items) {
      if (item.id == taskId) return item;
    }
    return null;
  }

  Future<void> _cancelDownload(DownloadProgressData data) async {
    if (_dismissRequested || _commandInFlight) return;
    final item = _itemForTask(data.taskId);
    final logical = item?.logicalId?.trim();
    if (logical == null || logical.isEmpty) return;

    setState(() {
      _dismissRequested = true;
      _commandInFlight = true;
    });
    final navigator = Navigator.of(context);
    try {
      await ref
          .read(downloadManagerV2Provider)
          .cancel(DownloadLogicalId(logical));
      if (mounted && ModalRoute.of(context)?.isCurrent == true) {
        navigator.pop();
      }
    } catch (error) {
      if (mounted) {
        setState(() => _dismissRequested = false);
        _showCommandError(error);
      }
    } finally {
      if (mounted) setState(() => _commandInFlight = false);
    }
  }

  Future<void> _togglePause(DownloadProgressData data) async {
    if (_commandInFlight || _dismissRequested) return;
    setState(() => _commandInFlight = true);
    try {
      final notifier = ref.read(downloadsProvider.notifier);
      if (data.status == TaskStatus.failed ||
          data.status == TaskStatus.notFound) {
        await notifier.retryDownload(data.taskId);
      } else if (data.status == TaskStatus.paused) {
        await notifier.resumeDownload(data.taskId);
      } else {
        await notifier.pauseDownload(data.taskId);
      }
    } catch (error) {
      if (mounted) _showCommandError(error);
    } finally {
      if (mounted) setState(() => _commandInFlight = false);
    }
  }

  void _showCommandError(Object error) {
    var message = error.toString().trim();
    const stateErrorPrefix = 'Bad state: ';
    if (message.startsWith(stateErrorPrefix)) {
      message = message.substring(stateErrorPrefix.length).trim();
    }
    if (message.isEmpty) message = 'تعذر التحكم في التنزيل';
    ref.read(notificationServiceProvider).showError(message);
  }

  @override
  Widget build(BuildContext context) {
    final progressMap = ref.watch(downloadProgressProvider);
    final data = progressMap[widget.trackingUrl];

    if (data == null) {
      // A cancellation removes the V2 presentation entry before its Future
      // completes. Guard the route close so rebuilding cannot pop the page
      // beneath this dialog.
      _dismissOnce();
      return const SizedBox.shrink();
    }

    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  switch (data.status) {
                    TaskStatus.failed || TaskStatus.notFound => appText(
                      context,
                      english: 'Download failed',
                      arabic: 'فشل التنزيل',
                    ),
                    TaskStatus.paused => l10n.downloadPaused,
                    TaskStatus.complete => l10n.statusFinished,
                    TaskStatus.canceled => l10n.statusCanceled,
                    _ => l10n.downloading,
                  },
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  widget.title,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: LinearProgressIndicator(
                        value: data.progress,
                        borderRadius: BorderRadius.circular(4),
                        minHeight: 8,
                        backgroundColor: theme.dividerColor.withValues(
                          alpha: 0.1,
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Text(
                      '${(data.progress * 100).toInt()}%',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(
                      Icons.data_usage_rounded,
                      size: 16,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      data.completedPages != null
                          ? formatDownloadPageCount(
                              completedPages: data.completedPages,
                              totalPages: data.totalPages,
                              pageLabel: appText(
                                context,
                                english: 'pages',
                                arabic: 'صفحة',
                              ),
                            )
                          : formatDownloadSizePair(
                              totalBytes: data.totalSize,
                              progress: data.progress,
                              fractionDigits: 2,
                            ),
                      textDirection: TextDirection.ltr,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _buildInfoItem(
                      context,
                      Icons.speed_rounded,
                      l10n.speed,
                      formatDownloadSpeed(data, l10n),
                      valueTextDirection: TextDirection.ltr,
                    ),
                    _buildInfoItem(
                      context,
                      Icons.timer_outlined,
                      l10n.remaining,
                      formatDownloadTimeRemaining(data, l10n),
                      valueTextDirection: TextDirection.rtl,
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (data.status != TaskStatus.complete &&
                        data.status != TaskStatus.canceled) ...[
                      TextButton(
                        onPressed: _commandInFlight
                            ? null
                            : () => _cancelDownload(data),
                        style: TextButton.styleFrom(
                          foregroundColor: theme.colorScheme.error,
                        ),
                        child: Text(l10n.cancel),
                      ),
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: _commandInFlight
                            ? null
                            : () => _togglePause(data),
                        child: Text(switch (data.status) {
                          TaskStatus.failed ||
                          TaskStatus.notFound => l10n.retry,
                          TaskStatus.paused => l10n.resume,
                          _ => l10n.pause,
                        }),
                      ),
                      const SizedBox(width: 8),
                    ],
                    TextButton(
                      onPressed: _dismissOnce,
                      child: Text(l10n.close),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInfoItem(
    BuildContext context,
    IconData icon,
    String label,
    String value, {
    TextDirection? valueTextDirection,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 16, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 4),
            Text(
              label,
              textDirection: TextDirection.rtl,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          value,
          textDirection: valueTextDirection ?? TextDirection.ltr,
          style: Theme.of(context).textTheme.bodyLarge
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}
