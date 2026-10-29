import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/material.dart';

import '../../../shared/widgets/confirm_dialog.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../core/services/notification_service.dart';
import 'downloads_provider.dart';

Future<void> confirmAndRemoveDownload(
  BuildContext context,
  WidgetRef ref,
  DownloadItem item,
) async {
  final l10n = AppLocalizations.of(context)!;
  final confirmed = await showConfirmDialog(
    context,
    title: l10n.deleteDownload,
    message: l10n.confirmDeleteDownload,
    confirmLabel: l10n.delete,
    cancelLabel: l10n.cancel,
  );
  if (confirmed && context.mounted) {
    final notifications = ref.read(notificationServiceProvider);
    try {
      await ref.read(downloadsProvider.notifier).removeDownload(item);
    } catch (error) {
      showDownloadActionError(notifications, error);
    }
  }
}

/// The one pause/resume/retry dispatch for a download: failed or
/// missing tasks retry, paused tasks resume, everything else pauses.
Future<void> toggleDownloadPlayback(
  DownloadsNotifier notifier,
  String taskId,
  TaskStatus status,
) async {
  if (status == TaskStatus.failed || status == TaskStatus.notFound) {
    await notifier.retryDownload(taskId);
  } else if (status == TaskStatus.paused) {
    await notifier.resumeDownload(taskId);
  } else {
    await notifier.pauseDownload(taskId);
  }
}

void showDownloadActionError(
  NotificationService notifications,
  Object error, {
  String fallbackMessage = 'Unable to control download',
}) {
  var message = error.toString().trim();
  const stateErrorPrefix = 'Bad state: ';
  if (message.startsWith(stateErrorPrefix)) {
    message = message.substring(stateErrorPrefix.length).trim();
  }
  if (message.isEmpty) message = fallbackMessage;
  notifications.showError(message);
}
