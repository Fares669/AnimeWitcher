from pathlib import Path
import re


def read(path):
    return Path(path).read_text(encoding='utf-8')


def write(path, text):
    Path(path).write_text(text, encoding='utf-8')


def replace_once(path, old, new, label):
    text = read(path)
    if old not in text:
        raise RuntimeError(f'missing marker for {label} in {path}')
    write(path, text.replace(old, new, 1))


def insert_after(path, marker, insertion, label):
    text = read(path)
    if marker not in text:
        raise RuntimeError(f'missing marker for {label} in {path}')
    write(path, text.replace(marker, marker + insertion, 1))


# The base staged patch deliberately only adds pure helpers/scaffolding. This
# file wires those helpers into the real download lifecycle.
write('lib/core/services/download_parallel.dart', r'''import 'package:background_downloader/background_downloader.dart';

/// 0 = Auto. Manual choices intentionally stay conservative on mobile.
const String kDownloadPartsSettingKey = 'download_parallel_parts';
const int kDownloadPartsAuto = 0;
const int kDownloadPartsMin = 1;
const int kDownloadPartsMax = 8;
const List<int> kDownloadPartChoices = <int>[0, 1, 2, 4, 6, 8];

int normalizeDownloadPartPreference(Object? raw) {
  final value = raw is num ? raw.toInt() : int.tryParse(raw?.toString() ?? '');
  return kDownloadPartChoices.contains(value) ? value! : kDownloadPartsAuto;
}

/// Pick the actual connection count. Parallel mode is never attempted unless
/// the origin proved byte-range support and exposed a trustworthy total size.
int selectAdaptiveDownloadParts({
  required int preference,
  required int totalBytes,
  required bool supportsRanges,
}) {
  if (!supportsRanges || totalBytes <= 0) return 1;
  final normalized = normalizeDownloadPartPreference(preference);
  if (normalized > 0) return normalized;

  const mib = 1024 * 1024;
  if (totalBytes < 80 * mib) return 1;
  if (totalBytes < 250 * mib) return 2;
  if (totalBytes < 700 * mib) return 4;
  if (totalBytes < 1500 * mib) return 6;
  return 8;
}

bool isInternalDownloaderChunk(Task task) =>
    task.group == FileDownloader.chunkGroup;

bool isLogicalEpisodeDownloadTask(Task task) =>
    task is DownloadTask && !isInternalDownloaderChunk(task);

int downloadTaskPartCount(Task task) {
  if (task is ParallelDownloadTask) {
    return task.chunks.clamp(kDownloadPartsMin, kDownloadPartsMax).toInt();
  }
  return 1;
}

/// Convert a not-yet-started logical episode placeholder to the real transfer
/// task. Keep the same taskId so Hive metadata, UI rows and queue ordering stay
/// attached to one episode, never to individual chunks.
DownloadTask buildAdaptiveDownloadTask({
  required DownloadTask template,
  required int parts,
}) {
  final count = parts.clamp(kDownloadPartsMin, kDownloadPartsMax).toInt();
  if (count <= 1 || template is ParallelDownloadTask) return template;
  return ParallelDownloadTask(
    taskId: template.taskId,
    url: template.url,
    filename: template.filename,
    displayName: template.displayName,
    baseDirectory: template.baseDirectory,
    directory: template.directory,
    headers: Map<String, String>.from(template.headers),
    httpRequestMethod: template.httpRequestMethod,
    group: template.group,
    updates: template.updates,
    retries: template.retries,
    allowPause: true,
    metaData: template.metaData,
    chunks: count,
  );
}
''')

write('lib/features/library/presentation/widgets/segmented_download_progress.dart', r'''import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/material.dart';

import '../../../../core/services/download_parallel.dart';

/// One aggregate progress bar with visual chunk boundaries. background_downloader
/// intentionally hides per-chunk updates, so the separators represent the real
/// number of transport chunks without inventing fake per-chunk percentages.
class SegmentedDownloadProgress extends StatelessWidget {
  const SegmentedDownloadProgress({
    super.key,
    required this.task,
    required this.value,
    required this.backgroundColor,
    required this.borderRadius,
  });

  final Task task;
  final double value;
  final Color backgroundColor;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    final parts = downloadTaskPartCount(task);
    final progress = value.clamp(0.0, 1.0).toDouble();
    return Semantics(
      label: parts > 1 ? 'Download progress, $parts parallel parts' : null,
      value: '${(progress * 100).floor()}%',
      child: ClipRRect(
        borderRadius: borderRadius,
        child: SizedBox(
          height: 4,
          child: Stack(
            fit: StackFit.expand,
            children: [
              LinearProgressIndicator(
                value: progress,
                backgroundColor: backgroundColor,
              ),
              if (parts > 1)
                Row(
                  children: List<Widget>.generate(parts * 2 - 1, (index) {
                    if (index.isEven) return const Expanded(child: SizedBox());
                    return Container(
                      width: 1,
                      color: Theme.of(context).colorScheme.surface.withValues(
                        alpha: 0.72,
                      ),
                    );
                  }),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
''')

# Storage + repository -------------------------------------------------------
insert_after(
    'lib/core/storage/storage_service.dart',
    "import '../services/download_concurrency.dart';\n",
    "import '../services/download_parallel.dart';\n",
    'storage parallel import',
)
replace_once(
    'lib/core/storage/storage_service.dart',
    """  int getDownloadConcurrency() {
    return parseDownloadConcurrency(
      _settingsBox.get(kDownloadConcurrencyStorageKey),
    );
  }

""",
    """  int getDownloadConcurrency() {
    return parseDownloadConcurrency(
      _settingsBox.get(kDownloadConcurrencyStorageKey),
    );
  }

  Future<void> setDownloadParallelParts(int value) async {
    await _settingsBox.put(
      kDownloadPartsSettingKey,
      normalizeDownloadPartPreference(value),
    );
  }

  int getDownloadParallelParts() => normalizeDownloadPartPreference(
    _settingsBox.get(kDownloadPartsSettingKey),
  );

""",
    'storage parallel settings',
)

insert_after(
    'lib/core/storage/settings_repository.dart',
    "import '../services/download_concurrency.dart';\n",
    "import '../services/download_parallel.dart';\n",
    'settings repository import',
)
replace_once(
    'lib/core/storage/settings_repository.dart',
    """  int getDownloadConcurrency() => _storageService.getDownloadConcurrency();

""",
    """  int getDownloadConcurrency() => _storageService.getDownloadConcurrency();

  Future<void> setDownloadParallelParts(int value) =>
      _storageService.setDownloadParallelParts(value);

  int getDownloadParallelParts() => _storageService.getDownloadParallelParts();

""",
    'settings repository accessors',
)

# General settings provider -------------------------------------------------
insert_after(
    'lib/features/settings/presentation/general_settings_provider.dart',
    "import '../../../core/services/download_concurrency.dart';\n",
    "import '../../../core/services/download_parallel.dart';\n",
    'general settings parallel import',
)
replace_once(
    'lib/features/settings/presentation/general_settings_provider.dart',
    """  final int downloadConcurrency;
  final DownloadNotificationPrefs downloadNotifications;
""",
    """  final int downloadConcurrency;
  final int downloadParallelParts;
  final DownloadNotificationPrefs downloadNotifications;
""",
    'general settings field',
)
replace_once(
    'lib/features/settings/presentation/general_settings_provider.dart',
    """    this.downloadConcurrency = kDownloadConcurrencyDefault,
    this.downloadNotifications = const DownloadNotificationPrefs(),
""",
    """    this.downloadConcurrency = kDownloadConcurrencyDefault,
    this.downloadParallelParts = kDownloadPartsAuto,
    this.downloadNotifications = const DownloadNotificationPrefs(),
""",
    'general settings ctor',
)
replace_once(
    'lib/features/settings/presentation/general_settings_provider.dart',
    """    int? downloadConcurrency,
    DownloadNotificationPrefs? downloadNotifications,
""",
    """    int? downloadConcurrency,
    int? downloadParallelParts,
    DownloadNotificationPrefs? downloadNotifications,
""",
    'general settings copy args',
)
replace_once(
    'lib/features/settings/presentation/general_settings_provider.dart',
    """      downloadConcurrency: downloadConcurrency ?? this.downloadConcurrency,
      downloadNotifications:
""",
    """      downloadConcurrency: downloadConcurrency ?? this.downloadConcurrency,
      downloadParallelParts: downloadParallelParts ?? this.downloadParallelParts,
      downloadNotifications:
""",
    'general settings copy body',
)
replace_once(
    'lib/features/settings/presentation/general_settings_provider.dart',
    """      downloadConcurrency: repository.getDownloadConcurrency(),
      downloadNotifications: repository.getDownloadNotificationPrefs(),
""",
    """      downloadConcurrency: repository.getDownloadConcurrency(),
      downloadParallelParts: repository.getDownloadParallelParts(),
      downloadNotifications: repository.getDownloadNotificationPrefs(),
""",
    'general settings build',
)
insert_after(
    'lib/features/settings/presentation/general_settings_provider.dart',
    """  Future<void> setDownloadConcurrency(int value) async {
    await ref
        .read(downloadServiceProvider)
        .applyQueueSettings(maxConcurrent: value);
    state = state.copyWith(
      downloadConcurrency: clampDownloadConcurrency(value),
    );
  }

""",
    """  Future<void> setDownloadParallelParts(int value) async {
    final normalized = normalizeDownloadPartPreference(value);
    await ref
        .read(settingsRepositoryProvider)
        .setDownloadParallelParts(normalized);
    state = state.copyWith(downloadParallelParts: normalized);
  }

""",
    'general settings setter',
)

# Settings UI ---------------------------------------------------------------
insert_after(
    'lib/features/settings/presentation/widgets/settings_dialogs.dart',
    "import '../../../../core/services/download_concurrency.dart';\n",
    "import '../../../../core/services/download_parallel.dart';\n",
    'settings dialog parallel import',
)
marker = "String downloadNotificationsTitle() => 'إشعارات التنزيل';\n"
parallel_dialog = r'''
String downloadPartsTitle() => 'أجزاء التنزيل';

String downloadPartsSubtitle(int value) {
  final normalized = normalizeDownloadPartPreference(value);
  return normalized == kDownloadPartsAuto ? 'تلقائي' : '$normalized أجزاء';
}

void showDownloadPartsDialog(BuildContext context, WidgetRef ref, int current) {
  final selected = normalizeDownloadPartPreference(current);
  showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      surfaceTintColor: Colors.transparent,
      title: Text(downloadPartsTitle()),
      content: RadioGroup<int>(
        groupValue: selected,
        onChanged: (value) {
          if (value == null) return;
          ref.read(generalSettingsProvider.notifier).setDownloadParallelParts(value);
          Navigator.pop<void>(context);
        },
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: kDownloadPartChoices.map((value) {
              final auto = value == kDownloadPartsAuto;
              return ListTile(
                title: Text(auto ? 'تلقائي' : '$value'),
                subtitle: Text(
                  auto
                      ? 'يختار العدد حسب حجم الملف ودعم الخادم'
                      : value == 1
                          ? 'اتصال واحد'
                          : '$value اتصالات متوازية عند دعم الخادم',
                ),
                leading: Radio<int>(value: value),
                onTap: () {
                  ref.read(generalSettingsProvider.notifier).setDownloadParallelParts(value);
                  Navigator.pop<void>(context);
                },
              );
            }).toList(growable: false),
          ),
        ),
      ),
    ),
  );
}

'''
text = read('lib/features/settings/presentation/widgets/settings_dialogs.dart')
if marker not in text:
    raise RuntimeError('settings dialog insertion marker missing')
write('lib/features/settings/presentation/widgets/settings_dialogs.dart', text.replace(marker, parallel_dialog + marker, 1))

replace_once(
    'lib/features/settings/presentation/settings_screen.dart',
    """                SettingsTile(
                  icon: Icons.notifications_rounded,
                  title: downloadNotificationsTitle(),
""",
    """                SettingsTile(
                  icon: Icons.call_split_rounded,
                  title: downloadPartsTitle(),
                  subtitle: downloadPartsSubtitle(
                    generalSettings.downloadParallelParts,
                  ),
                  onTap: () => showDownloadPartsDialog(
                    context,
                    ref,
                    generalSettings.downloadParallelParts,
                  ),
                ),
                SettingsTile(
                  icon: Icons.notifications_rounded,
                  title: downloadNotificationsTitle(),
""",
    'settings download parts tile',
)

# Downloads progress UI -----------------------------------------------------
insert_after(
    'lib/features/library/presentation/widgets/downloads_tab.dart',
    "import '../../../../core/services/download_concurrency.dart';\n",
    "import 'segmented_download_progress.dart';\n",
    'downloads segmented import',
)
replace_once(
    'lib/features/library/presentation/widgets/downloads_tab.dart',
    """                LinearProgressIndicator(
                  value: progress,
                  backgroundColor: theme.dividerColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(LayoutConstants.radiusSm),
                ),
""",
    """                SegmentedDownloadProgress(
                  task: item.task,
                  value: progress,
                  backgroundColor: theme.dividerColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(LayoutConstants.radiusSm),
                ),
""",
    'downloads segmented progress',
)

# Download service ----------------------------------------------------------
insert_after(
    'lib/core/services/download_service.dart',
    "import 'download_concurrency.dart';\n",
    "import 'download_parallel.dart';\n",
    'download service parallel import',
)

# Chunk tasks are an implementation detail, never logical episode rows.
replace_once(
    'lib/core/services/download_service.dart',
    """    _updatesSubscription = _sharedEvents.stream.listen((update) {
      final trackingUrl = update.task.metaData.isNotEmpty
""",
    """    _updatesSubscription = _sharedEvents.stream.listen((update) {
      if (isInternalDownloaderChunk(update.task)) return;
      final trackingUrl = update.task.metaData.isNotEmpty
""",
    'stream chunk filter',
)

text = read('lib/core/services/download_service.dart')
text = text.replace(
    'if (record.task is! DownloadTask) continue;',
    'if (!isLogicalEpisodeDownloadTask(record.task)) continue;',
)
text = text.replace(
    'if (task is! DownloadTask) continue;',
    'if (!isLogicalEpisodeDownloadTask(task)) continue;',
)
write('lib/core/services/download_service.dart', text)

replace_once(
    'lib/core/services/download_service.dart',
    """    final nativeIds = <String>{
      for (final task in await FileDownloader().allTasks(allGroups: true))
        task.taskId,
    };
""",
    """    final nativeIds = <String>{
      for (final task in await FileDownloader().allTasks(allGroups: true))
        if (isLogicalEpisodeDownloadTask(task)) task.taskId,
    };
""",
    'recovery native logical ids',
)

# Reserve an app-level episode slot during the short enqueued->running window.
old_occupied = r'''  int _occupiedSlotCount(List<TaskRecord> records) {
    final occupying = <String>{};
    for (final record in records) {
      final taskId = record.task.taskId;
      if (_userPausedIds.contains(taskId)) continue;
      if (occupiesDownloadSlot(
        status: record.status,
        queueWaiting: _queueWaitingIds.contains(taskId),
      )) {
        occupying.add(taskId);
      }
    }
    occupying.addAll(_startingTaskIds);
    occupying.removeAll(_userPausedIds);
    occupying.removeAll(_restackingWaiterIds);
    return occupying.length;
  }
'''
new_occupied = r'''  int _occupiedSlotCount(List<TaskRecord> records) {
    final occupying = <String>{};
    for (final record in records) {
      if (!isLogicalEpisodeDownloadTask(record.task)) continue;
      final taskId = record.task.taskId;
      if (_userPausedIds.contains(taskId)) continue;
      if (reservesDownloadSlot(
        status: record.status,
        queueWaiting: _queueWaitingIds.contains(taskId),
      )) {
        occupying.add(taskId);
      }
    }
    occupying.addAll(_startingTaskIds);
    occupying.removeAll(_userPausedIds);
    occupying.removeAll(_restackingWaiterIds);
    return occupying.length;
  }
'''
replace_once('lib/core/services/download_service.dart', old_occupied, new_occupied, 'occupied slot reservation')

# Make liveness lookup ignore internal chunk DownloadTasks.
replace_once(
    'lib/core/services/download_service.dart',
    """    final byId = await FileDownloader().taskForId(taskId);
    if (byId is DownloadTask) return byId;
""",
    """    final byId = await FileDownloader().taskForId(taskId);
    if (byId is DownloadTask && !isInternalDownloaderChunk(byId)) return byId;
""",
    'live task direct chunk filter',
)

# A Parallel ResumeData payload is JSON chunk state, not iOS URLSession base64.
# Never feed it to the custom Swift normal-download promoter.
replace_once(
    'lib/core/services/download_service.dart',
    """    try {
      // ignore: invalid_use_of_visible_for_testing_member
      final resume = await FileDownloader().downloaderForTesting.getResumeData(
        task.taskId,
      );
      if (resume != null && resume.data.isNotEmpty) {
        payload['resumeDataBase64'] = resume.data;
      }
    } catch (_) {}
""",
    """    if (task is! ParallelDownloadTask) {
      try {
        // ignore: invalid_use_of_visible_for_testing_member
        final resume = await FileDownloader().downloaderForTesting.getResumeData(
          task.taskId,
        );
        if (resume != null && resume.data.isNotEmpty) {
          payload['resumeDataBase64'] = resume.data;
        }
      } catch (_) {}
    }
""",
    'parallel swift resume guard',
)

# Fresh-task adaptive conversion and safe parallel resume.
resume_marker = '  Future<bool> _resumeDownloadTask(DownloadTask task) async {\n'
text = read('lib/core/services/download_service.dart')
if resume_marker not in text:
    raise RuntimeError('resume method marker missing')
adaptive_methods = r'''  Future<DownloadTask> _adaptiveTaskForFreshStart(
    DownloadTask template, {
    int knownTotalBytes = -1,
  }) async {
    if (template is ParallelDownloadTask) return template;
    final preference = _ref
        .read(storageServiceProvider)
        .getDownloadParallelParts();
    if (preference == 1) return template;

    final metadata = await getMetadata(template.url, headers: template.headers);
    final total = knownTotalBytes > 0
        ? knownTotalBytes
        : (metadata?.size ?? -1);
    final parts = selectAdaptiveDownloadParts(
      preference: preference,
      totalBytes: total,
      supportsRanges: metadata?.supportsRanges ?? false,
    );
    return buildAdaptiveDownloadTask(template: template, parts: parts);
  }

  Future<bool> _enqueueFreshAdaptiveTask(
    DownloadTask template, {
    int knownTotalBytes = -1,
  }) async {
    final task = await _adaptiveTaskForFreshStart(
      template,
      knownTotalBytes: knownTotalBytes,
    );
    final previous = await FileDownloader().database.recordForId(task.taskId);
    if (previous != null) {
      await FileDownloader().database.updateRecord(
        TaskRecord(
          task,
          TaskStatus.enqueued,
          previous.progress,
          previous.expectedFileSize,
        ),
      );
    }
    return FileDownloader().enqueue(task);
  }

'''
write('lib/core/services/download_service.dart', text.replace(resume_marker, adaptive_methods + resume_marker, 1))

old_resume = re.compile(
    r"  Future<bool> _resumeDownloadTask\(DownloadTask task\) async \{.*?\n  \}\n\n  Future<bool> _resumeUsingPartialFile",
    re.S,
)
text = read('lib/core/services/download_service.dart')
match = old_resume.search(text)
if not match:
    raise RuntimeError('resume method block not found')
new_resume = r'''  Future<bool> _resumeDownloadTask(DownloadTask task) async {
    final live = await _liveNativeTaskFor(
      taskId: task.taskId,
      trackingUrl: downloadTrackingUrl(task),
    );
    if (live != null) {
      final record = await FileDownloader().database.recordForId(live.taskId);
      if (record != null && isLiveNativeDownloadStatus(record.status)) {
        await _attachToLiveNativeTask(task, live: live);
        return true;
      }
    }

    final saved = await _savedProgressFor(task);
    final trackingUrl = downloadTrackingUrl(task);
    if (saved.progress > 0) {
      _publishProgress(
        trackingUrl: trackingUrl,
        taskId: task.taskId,
        progress: saved.progress,
        totalSize: saved.totalSize,
        status: TaskStatus.paused,
      );
    }

    if (task is ParallelDownloadTask) {
      // A started parallel parent may only continue from the plugin's chunk
      // ResumeData. Never reinterpret it as a single partial file and never
      // fresh-enqueue the parent after bytes may have been written.
      try {
        // ignore: invalid_use_of_visible_for_testing_member
        final resumeData = await FileDownloader().downloaderForTesting
            .getResumeData(task.taskId);
        if (resumeData != null && resumeData.data.isNotEmpty) {
          return await FileDownloader().resume(task);
        }
      } catch (_) {}
      return false;
    }

    return resumeOrRestartDownload(
      canResume: () => FileDownloader().taskCanResume(task),
      resume: () => FileDownloader().resume(task),
      resumeFromPartial: () => _resumeUsingPartialFile(task),
      restart: () => _enqueueFreshAdaptiveTask(
        task,
        knownTotalBytes: saved.totalSize,
      ),
      savedProgress: saved.progress,
      existingPartialBytes: saved.partialBytes,
      expectedBytes: saved.totalSize,
    );
  }

  Future<bool> _resumeUsingPartialFile'''
text = text[:match.start()] + new_resume + text[match.end():]
write('lib/core/services/download_service.dart', text)

# Defensive guard even if a future caller bypasses _resumeDownloadTask.
replace_once(
    'lib/core/services/download_service.dart',
    """  Future<bool> _resumeUsingPartialFile(DownloadTask task) async {
    String destinationPath;
""",
    """  Future<bool> _resumeUsingPartialFile(DownloadTask task) async {
    if (task is ParallelDownloadTask) return false;
    String destinationPath;
""",
    'parallel partial guard',
)

# App-owned waiter: do not enqueue/restack a waiting episode into a disabled HQ.
old_enqueue_waiter = re.compile(
    r"  Future<void> _enqueueExistingTaskAsWaiterUnlocked\(DownloadTask task\) async \{.*?\n  \}\n\n  Future<DownloadTask> _adaptiveTaskForFreshStart",
    re.S,
)
text = read('lib/core/services/download_service.dart')
match = old_enqueue_waiter.search(text)
if not match:
    raise RuntimeError('enqueue waiter block not found')
new_enqueue_waiter = r'''  Future<void> _enqueueExistingTaskAsWaiterUnlocked(DownloadTask task) async {
    final trackingUrl = downloadTrackingUrl(task);
    final live = await _liveNativeTaskFor(
      taskId: task.taskId,
      trackingUrl: trackingUrl,
    );
    if (live != null) {
      final record = await FileDownloader().database.recordForId(live.taskId);
      if (record != null &&
          reservesDownloadSlot(
            status: record.status,
            queueWaiting: _queueWaitingIds.contains(live.taskId),
          )) {
        await _attachToLiveNativeTask(task, live: live);
        return;
      }
    }

    final previous = await FileDownloader().database.recordForId(task.taskId);
    final progress = previous?.progress ?? 0.0;
    final totalSize = previous?.expectedFileSize ?? -1;
    _queueWaitingIds.add(task.taskId);
    _waitingPayloads[task.taskId] = _waitingPayloadFor(task);
    _rememberSessionTask(task.taskId);
    await _ref
        .read(storageServiceProvider)
        .patchDownloadMetadata(task.taskId, queueWaiting: true);
    await FileDownloader().database.updateRecord(
      TaskRecord(task, TaskStatus.paused, progress, totalSize),
    );
    _publishProgress(
      trackingUrl: trackingUrl,
      taskId: task.taskId,
      progress: progress,
      totalSize: totalSize,
      status: TaskStatus.enqueued,
    );
    _updatesController.add(TaskStatusUpdate(task, TaskStatus.enqueued));
  }

  Future<DownloadTask> _adaptiveTaskForFreshStart'''
text = text[:match.start()] + new_enqueue_waiter + text[match.end():]
write('lib/core/services/download_service.dart', text)

# Promotion must not have a second blind enqueue fallback.
old_promote = re.compile(
    r"  Future<bool> _promoteWaitingTask\(DownloadTask task\) async \{.*?\n  \}\n\n  void _publishProgress",
    re.S,
)
text = read('lib/core/services/download_service.dart')
match = old_promote.search(text)
if not match:
    raise RuntimeError('promote waiter block not found')
new_promote = r'''  Future<bool> _promoteWaitingTask(DownloadTask task) async {
    final live = await _liveNativeTaskFor(
      taskId: task.taskId,
      trackingUrl: downloadTrackingUrl(task),
    );
    if (live != null) {
      await _attachToLiveNativeTask(task, live: live);
      return true;
    }

    final wasWaiting = _queueWaitingIds.contains(task.taskId) ||
        isQueueWaitingMetadata(
          await _ref.read(storageServiceProvider).getDownloadMetadata(task.taskId),
        );
    _queueWaitingIds.remove(task.taskId);
    _waitingPayloads.remove(task.taskId);
    await _ref
        .read(storageServiceProvider)
        .patchDownloadMetadata(task.taskId, queueWaiting: false);
    _startingTaskIds.add(task.taskId);
    try {
      final started = await _resumeDownloadTask(task);
      if (!started && wasWaiting) {
        _queueWaitingIds.add(task.taskId);
        _waitingPayloads[task.taskId] = _waitingPayloadFor(task);
        final record = await FileDownloader().database.recordForId(task.taskId);
        await FileDownloader().database.updateRecord(
          TaskRecord(
            task,
            TaskStatus.paused,
            record?.progress ?? 0,
            record?.expectedFileSize ?? -1,
          ),
        );
        await _ref
            .read(storageServiceProvider)
            .patchDownloadMetadata(task.taskId, queueWaiting: true);
      }
      return started;
    } finally {
      _startingTaskIds.remove(task.taskId);
    }
  }

  void _publishProgress'''
text = text[:match.start()] + new_promote + text[match.end():]
write('lib/core/services/download_service.dart', text)

# User resume: when N is full, re-enter the app-owned queue instead of calling
# resume() and relying on the now-disabled HoldingQueue.
replace_once(
    'lib/core/services/download_service.dart',
    """      if (startNow) {
        _queueWaitingIds.remove(taskId);
        _waitingPayloads.remove(taskId);
        await _ref
            .read(storageServiceProvider)
            .patchDownloadMetadata(taskId, queueWaiting: false);
      }
      // resume() enqueues with resumeData. HoldingQueue holds it when N is
      // full — never a fresh GET from byte 0.
      await _resumeDownloadTask(downloadTask);

      for (final waiterId in plan.waitersToRestack) {
""",
    """      if (startNow) {
        _queueWaitingIds.remove(taskId);
        _waitingPayloads.remove(taskId);
        await _ref
            .read(storageServiceProvider)
            .patchDownloadMetadata(taskId, queueWaiting: false);
        await _resumeDownloadTask(downloadTask);
      } else {
        await _enqueueExistingTaskAsWaiterUnlocked(downloadTask);
      }

      for (final waiterId in plan.waitersToRestack) {
""",
    'user resume queue gate',
)

# Initial enqueue: one logical episode slot, with a normal placeholder while
# waiting. Only a promoted/starting episode is converted to ParallelDownloadTask.
start_pattern = re.compile(
    r"      final task = DownloadTask\(\n        url: url,.*?\n      \);\n\n      if \(kDebugMode\) debugPrint\('\[DownloadService\] Enqueuing task\.\.\.'\);",
    re.S,
)
text = read('lib/core/services/download_service.dart')
match = start_pattern.search(text)
if not match:
    raise RuntimeError('start task construction block not found')
base_task = r'''      final task = DownloadTask(
        url: url,
        filename: filename,
        displayName: filename,
        baseDirectory: baseDir,
        directory: taskDirectory,
        headers: headers ?? {},
        updates: Updates.statusAndProgress,
        retries: kDownloadTaskRetries,
        allowPause: true,
        metaData: trackingUrl ?? url,
      );

      if (kDebugMode) debugPrint('[DownloadService] Enqueuing task...');'''
text = text[:match.start()] + base_task + text[match.end():]
write('lib/core/services/download_service.dart', text)

old_start_try = re.compile(
    r"        _startingTaskIds\.add\(task\.taskId\);\n        _waitingPayloads\[task\.taskId\] = _waitingPayloadFor\(task\);.*?\n        return true;\n",
    re.S,
)
text = read('lib/core/services/download_service.dart')
match = old_start_try.search(text)
if not match:
    raise RuntimeError('start enqueue body not found')
new_start_try = r'''        final storage = _ref.read(storageServiceProvider);
        final maxConcurrent = clampDownloadConcurrency(
          storage.getDownloadConcurrency(),
        );
        final occupied = _occupiedSlotCount(
          await FileDownloader().database.allRecords(),
        );
        final startNow = occupied < maxConcurrent;
        final expectedBytes = totalBytes > 0 ? totalBytes : -1;

        _waitingPayloads[task.taskId] = _waitingPayloadFor(task);
        _rememberSessionTask(task.taskId);
        await storage.saveDownloadMetadata(
          task.taskId,
          item,
          episode: episode,
          trackingUrl: trackingUrl ?? url,
          filePath: path,
          queueWaiting: !startNow,
        );
        _ref.read(activeDownloadsProvider.notifier).add(trackingUrl ?? url);

        if (!startNow) {
          _queueWaitingIds.add(task.taskId);
          await FileDownloader().database.updateRecord(
            TaskRecord(task, TaskStatus.paused, 0, expectedBytes),
          );
          _publishProgress(
            trackingUrl: trackingUrl ?? url,
            taskId: task.taskId,
            progress: 0,
            totalSize: expectedBytes,
            status: TaskStatus.enqueued,
          );
          _updatesController.add(TaskStatusUpdate(task, TaskStatus.enqueued));
          await _persistNativeWaitingSnapshot();
          unawaited(_syncSessionOverlay());
          return true;
        }

        _startingTaskIds.add(task.taskId);
        final transferTask = await _adaptiveTaskForFreshStart(
          task,
          knownTotalBytes: expectedBytes,
        );
        _updatesController.add(
          TaskStatusUpdate(transferTask, TaskStatus.enqueued),
        );
        final success = await FileDownloader().enqueue(transferTask);
        if (kDebugMode) {
          debugPrint(
            '[DownloadService] Enqueue result: $success '
            '(parts=${downloadTaskPartCount(transferTask)})',
          );
        }

        if (!success) {
          _waitingPayloads.remove(task.taskId);
          _forgetSessionTask(task.taskId);
          await storage.removeDownloadMetadata(task.taskId);
          _ref
              .read(activeDownloadsProvider.notifier)
              .remove(trackingUrl ?? url);
          _updatesController.add(
            TaskStatusUpdate(transferTask, TaskStatus.canceled),
          );
          return false;
        }

        await _persistNativeWaitingSnapshot();
        unawaited(_syncSessionOverlay());
        return true;
'''
text = text[:match.start()] + new_start_try + text[match.end():]
write('lib/core/services/download_service.dart', text)

# Range capability probe ----------------------------------------------------
metadata_pattern = re.compile(
    r"  Future<DownloadMetadata\?> getMetadata\(.*?\n  \}\n\n  /// Stores an episode's intro/credits",
    re.S,
)
text = read('lib/core/services/download_service.dart')
match = metadata_pattern.search(text)
if not match:
    raise RuntimeError('metadata method block not found')
new_metadata = r'''  Future<DownloadMetadata?> getMetadata(
    String url, {
    Map<String, String>? headers,
  }) async {
    try {
      int? size;
      String? mimeType;
      var supportsRanges = false;

      try {
        final response = await _dio
            .head<dynamic>(
              url,
              options: Options(headers: headers, followRedirects: true),
            )
            .timeout(const Duration(seconds: 10));
        size = int.tryParse(response.headers.value('content-length') ?? '');
        mimeType = response.headers.value('content-type');
        final acceptRanges = response.headers.value('accept-ranges');
        supportsRanges = acceptRanges?.toLowerCase().contains('bytes') == true;
      } catch (_) {}

      // A 206 response is stronger evidence than Accept-Ranges and also covers
      // hosts that reject HEAD. Stream and cancel immediately so a bad server
      // that ignores Range cannot buffer a whole episode into memory.
      if (size == null || !supportsRanges) {
        try {
          final response = await _dio
              .get<dynamic>(
                url,
                options: Options(
                  headers: {...?headers, 'Range': 'bytes=0-0'},
                  followRedirects: true,
                  responseType: ResponseType.stream,
                  validateStatus: (status) =>
                      status != null && (status == 200 || status == 206),
                ),
              )
              .timeout(const Duration(seconds: 10));
          final contentRange = response.headers.value('content-range');
          if (response.statusCode == 206 && contentRange != null) {
            supportsRanges = true;
            final total = contentRange.split('/').last;
            size = int.tryParse(total) ?? size;
          } else {
            final contentLength = int.tryParse(
              response.headers.value('content-length') ?? '',
            );
            if (contentLength != null && contentLength > 1) {
              size ??= contentLength;
            }
          }
          mimeType ??= response.headers.value('content-type');
          final body = response.data;
          if (body is ResponseBody) {
            final subscription = body.stream.listen(null);
            await subscription.cancel();
          }
        } catch (_) {}
      }

      return DownloadMetadata(
        size: size,
        mimeType: mimeType,
        supportsRanges: supportsRanges,
      );
    } catch (_) {
      return null;
    }
  }

  /// Stores an episode's intro/credits'''
text = text[:match.start()] + new_metadata + text[match.end():]
write('lib/core/services/download_service.dart', text)

replace_once(
    'lib/core/services/download_service.dart',
    """class DownloadMetadata {
  final int? size;
  final String? mimeType;

  DownloadMetadata({this.size, this.mimeType});
""",
    """class DownloadMetadata {
  final int? size;
  final String? mimeType;
  final bool supportsRanges;

  DownloadMetadata({
    this.size,
    this.mimeType,
    this.supportsRanges = false,
  });
""",
    'download metadata range flag',
)

# Do not expose a parallel parent to the custom Swift normal-file waiter.
# Brand-new overflow rows are intentionally plain DownloadTask placeholders.
text = read('lib/core/services/download_service.dart')
needle = """      if (isNativeWaitingSnapshotWaiter(
        status: record.status,
        queueWaiting: leftoverWaiting,
        userPaused: false,
      )) {
"""
replacement = """      if (isNativeWaitingSnapshotWaiter(
        status: record.status,
        queueWaiting: leftoverWaiting,
        userPaused: false,
      ) && task is! ParallelDownloadTask) {
"""
if needle not in text:
    raise RuntimeError('native snapshot waiter marker missing')
write('lib/core/services/download_service.dart', text.replace(needle, replacement, 1))

# Tests ---------------------------------------------------------------------
write('test/core/services/download_parallel_test.dart', r'''import 'package:animewitcher/core/services/download_parallel.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('adaptive parallel downloads', () {
    test('normalizes supported manual values and junk to Auto', () {
      for (final value in <int>[0, 1, 2, 4, 6, 8]) {
        expect(normalizeDownloadPartPreference(value), value);
      }
      expect(normalizeDownloadPartPreference(null), 0);
      expect(normalizeDownloadPartPreference(3), 0);
      expect(normalizeDownloadPartPreference(99), 0);
    });

    test('never splits without proven Range support and size', () {
      expect(
        selectAdaptiveDownloadParts(
          preference: 8,
          totalBytes: 900 * 1024 * 1024,
          supportsRanges: false,
        ),
        1,
      );
      expect(
        selectAdaptiveDownloadParts(
          preference: 8,
          totalBytes: -1,
          supportsRanges: true,
        ),
        1,
      );
    });

    test('Auto scales conservatively up to eight parts', () {
      const mib = 1024 * 1024;
      expect(selectAdaptiveDownloadParts(preference: 0, totalBytes: 40 * mib, supportsRanges: true), 1);
      expect(selectAdaptiveDownloadParts(preference: 0, totalBytes: 100 * mib, supportsRanges: true), 2);
      expect(selectAdaptiveDownloadParts(preference: 0, totalBytes: 400 * mib, supportsRanges: true), 4);
      expect(selectAdaptiveDownloadParts(preference: 0, totalBytes: 900 * mib, supportsRanges: true), 6);
      expect(selectAdaptiveDownloadParts(preference: 0, totalBytes: 2 * 1024 * mib, supportsRanges: true), 8);
    });

    test('builds one logical parent with the same taskId', () {
      final normal = DownloadTask(
        taskId: 'episode-12',
        url: 'https://example.com/episode.mp4',
        filename: 'episode.mp4',
        displayName: 'Episode 12',
        directory: 'downloads',
        headers: const {'Referer': 'https://example.com'},
        updates: Updates.statusAndProgress,
        allowPause: true,
        metaData: 'episode:12',
      );
      final parallel = buildAdaptiveDownloadTask(template: normal, parts: 4);
      expect(parallel, isA<ParallelDownloadTask>());
      expect(parallel.taskId, normal.taskId);
      expect(parallel.filename, normal.filename);
      expect(parallel.metaData, normal.metaData);
      expect(downloadTaskPartCount(parallel), 4);
    });

    test('internal chunks are never logical episode tasks', () {
      final child = DownloadTask(
        url: 'https://example.com/episode.mp4',
        group: FileDownloader.chunkGroup,
      );
      final parent = ParallelDownloadTask(
        url: 'https://example.com/episode.mp4',
        chunks: 4,
      );
      expect(isInternalDownloaderChunk(child), isTrue);
      expect(isLogicalEpisodeDownloadTask(child), isFalse);
      expect(isLogicalEpisodeDownloadTask(parent), isTrue);
    });
  });
}
''')

# Update old queue fixtures to the new explicit app-owned waiter model.
# A waiter is now queueWaiting=true; a native enqueued parent with false is a
# short-lived reservation, not a queue item.
path = 'test/core/services/download_concurrency_test.dart'
text = read(path)
text = text.replace(
    "test('native snapshot waiters are HQ enqueued + leftover parked, never user-paused'",
    "test('native snapshot waiters are explicit app waiters, never user-paused'",
)
# Keep the helper expectation aligned with explicit persisted waiters.
text = text.replace(
    """      expect(
        isNativeWaitingSnapshotWaiter(
          status: TaskStatus.enqueued,
          queueWaiting: false,
          userPaused: false,
        ),
        isTrue,
      );""",
    """      expect(
        isNativeWaitingSnapshotWaiter(
          status: TaskStatus.enqueued,
          queueWaiting: false,
          userPaused: false,
        ),
        isFalse,
      );""",
    1,
)
write(path, text)

print('Applied complete adaptive parallel download integration')
