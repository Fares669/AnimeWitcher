import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/services/download_v2/download_v2_identity.dart';
import '../../../../core/services/download_v2/download_v2_provider.dart';
import '../../../../core/services/notification_service.dart';
import '../../../../core/utils/localized_text.dart';
import '../../../../core/utils/download_progress_data.dart';
import '../../../../core/utils/file_size_formatter.dart';
import '../../../library/presentation/download_progress_v2_provider.dart';
import '../../../library/presentation/download_delete_confirmation.dart';
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
      await toggleDownloadPlayback(
        ref.read(downloadsProvider.notifier),
        data.taskId,
        data.status,
      );
    } catch (error) {
      if (mounted) _showCommandError(error);
    } finally {
      if (mounted) setState(() => _commandInFlight = false);
    }
  }

  void _showCommandError(Object error) {
    showDownloadActionError(
      ref.read(notificationServiceProvider),
      error,
      fallbackMessage: 'تعذر التحكم في التنزيل',
    );
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
    final unknownPageTotal =
        data.completedPages != null &&
        (data.totalPages ?? 0) <= 0 &&
        data.status != TaskStatus.complete;
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
                SizedBox(
                  width: double.infinity,
                  child: Text(
                    switch (data.status) {
                      TaskStatus.failed || TaskStatus.notFound => appText(
                        context,
                        english: 'Download failed',
                        arabic: 'فشل التنزيل',
                      ),
                      TaskStatus.paused => l10n.downloadPaused,
                      TaskStatus.complete => l10n.statusFinished,
                      TaskStatus.canceled => l10n.statusCanceled,
                      TaskStatus.enqueued => l10n.statusQueued,
                      _ => l10n.downloading,
                    },
                    textDirection: Directionality.of(context),
                    textAlign: TextAlign.start,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: Text(
                    widget.title,
                    textDirection: TextDirection.rtl,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: LinearProgressIndicator(
                        value: unknownPageTotal ? null : data.progress,
                        borderRadius: BorderRadius.circular(4),
                        minHeight: 8,
                        backgroundColor: theme.dividerColor.withValues(
                          alpha: 0.1,
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Text(
                      unknownPageTotal
                          ? '--%'
                          : '${(data.progress * 100).toInt()}%',
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

}
