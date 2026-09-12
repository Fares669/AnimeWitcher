import 'dart:async';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/services/download_service.dart';
import '../../../../core/utils/download_time_remaining.dart';
import '../../../../core/utils/file_size_formatter.dart';
import '../../../library/presentation/widgets/segmented_download_progress.dart';

import 'package:animewitcher/l10n/generated/app_localizations.dart';

class DownloadProgressDialog extends ConsumerStatefulWidget {
  final String title;
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
  String? _downloadTaskId;
  Task? _downloadTask;
  bool _taskLookupInFlight = false;
  bool _initialTaskLookupAttempted = false;
  bool _transferTaskLookupAttempted = false;

  void _dismissOnce() {
    if (_dismissRequested) return;
    _dismissRequested = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
      Navigator.of(context).pop();
    });
  }

  Future<void> _cancelDownload(DownloadProgressData data) async {
    if (_dismissRequested) return;
    _dismissRequested = true;
    final navigator = Navigator.of(context);
    final service = ref.read(downloadServiceProvider);
    try {
      final outcome = await service.cancelDownloadOutcome(
        data.taskId,
        widget.trackingUrl,
      );
      if (outcome != DownloadCommandOutcome.terminal &&
          outcome != DownloadCommandOutcome.alreadyComplete) {
        if (mounted) setState(() => _dismissRequested = false);
        return;
      }
      if (mounted && ModalRoute.of(context)?.isCurrent == true) {
        navigator.pop();
      }
    } catch (_) {
      if (mounted) {
        setState(() => _dismissRequested = false);
      }
      rethrow;
    }
  }

  void _ensureDownloadTask(DownloadProgressData data) {
    final taskId = data.taskId;
    if (_downloadTaskId != taskId) {
      _downloadTaskId = taskId;
      _downloadTask = null;
      _taskLookupInFlight = false;
      _initialTaskLookupAttempted = false;
      _transferTaskLookupAttempted = false;
    }

    final transferStarted =
        data.progress > 0 ||
        data.status == TaskStatus.running ||
        data.status == TaskStatus.paused;
    final shouldLookup =
        !_initialTaskLookupAttempted ||
        (transferStarted &&
            !_transferTaskLookupAttempted &&
            _downloadTask is! ParallelDownloadTask);
    if (!shouldLookup || _taskLookupInFlight) return;

    _taskLookupInFlight = true;
    if (!_initialTaskLookupAttempted) {
      _initialTaskLookupAttempted = true;
    } else if (transferStarted) {
      _transferTaskLookupAttempted = true;
    }
    unawaited(_resolveDownloadTask(taskId));
  }

  Future<void> _resolveDownloadTask(String taskId) async {
    Task? task;
    try {
      task = await FileDownloader().taskForId(taskId);
      task ??= (await FileDownloader().database.recordForId(taskId))?.task;
    } catch (_) {}

    if (!mounted || _downloadTaskId != taskId) return;
    setState(() {
      _downloadTask = task;
      _taskLookupInFlight = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final progressMap = ref.watch(downloadProgressProvider);
    final data = progressMap[widget.trackingUrl];

    if (data == null) {
      // A cancellation removes the progress entry before its Future
      // completes. Guarding this route close prevents the dialog rebuild and
      // the cancel handler from popping both the dialog and the anime page.
      _dismissOnce();
      return const SizedBox.shrink();
    }

    _ensureDownloadTask(data);
    final chunkProgress = ref.watch(downloadChunkProgressProvider)[data.taskId];
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
                  data.status == TaskStatus.paused
                      ? l10n.downloadPaused
                      : l10n.downloading,
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
                      child: _downloadTask == null
                          ? LinearProgressIndicator(
                              value: data.progress,
                              borderRadius: BorderRadius.circular(4),
                              minHeight: 8,
                            )
                          : SegmentedDownloadProgress(
                              task: _downloadTask!,
                              value: data.progress,
                              chunkProgress: chunkProgress,
                              backgroundColor: theme.dividerColor.withValues(
                                alpha: 0.1,
                              ),
                              borderRadius: BorderRadius.circular(4),
                              height: 8,
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
                      formatDownloadSizePair(
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
                      formatDownloadTimeRemaining(context, data, l10n),
                      valueTextDirection:
                          Localizations.localeOf(context).languageCode == 'ar'
                          ? TextDirection.rtl
                          : TextDirection.ltr,
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (data.progress < 1.0) ...[
                      TextButton(
                        onPressed: () => _cancelDownload(data),
                        style: TextButton.styleFrom(
                          foregroundColor: theme.colorScheme.error,
                        ),
                        child: Text(l10n.cancel),
                      ),
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: () async {
                          final service = ref.read(downloadServiceProvider);
                          if (data.status == TaskStatus.paused) {
                            await service.resumeDownloadOutcome(data.taskId);
                          } else {
                            await service.pauseDownloadOutcome(data.taskId);
                          }
                        },
                        child: Text(
                          data.status == TaskStatus.paused
                              ? l10n.resume
                              : l10n.pause,
                        ),
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
              textDirection:
                  Localizations.localeOf(context).languageCode == 'ar'
                  ? TextDirection.rtl
                  : TextDirection.ltr,
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
