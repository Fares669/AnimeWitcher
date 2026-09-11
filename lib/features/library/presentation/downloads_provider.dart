import 'dart:async';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:animewitcher/core/storage/storage_service.dart';

import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/services/download_concurrency.dart';
import '../../../core/services/download_service.dart';
import '../../../core/utils/download_cleanup.dart';
import 'download_episode_artwork.dart';

part 'downloads_provider.g.dart';

class DownloadItem {
  final Task task;
  final TaskStatus status;
  final double progress;
  final MultimediaItem item;
  final Episode? episode;
  final int timestamp;

  DownloadItem({
    required this.task,
    required this.status,
    required this.progress,
    required this.item,
    this.episode,
    required this.timestamp,
  });

  String get id => task.taskId;
}

bool downloadsPointAtSameTarget(DownloadItem a, DownloadItem b) {
  if (identical(a, b) || a.id == b.id) return true;
  final trackA = downloadTrackingUrl(a.task);
  final trackB = downloadTrackingUrl(b.task);
  if (trackA.isNotEmpty && trackA == trackB) return true;
  final episodeA = a.episode?.url.trim() ?? '';
  final episodeB = b.episode?.url.trim() ?? '';
  if (episodeA.isNotEmpty && episodeA == episodeB) return true;
  if (trackA.isNotEmpty && trackA == episodeB) return true;
  if (trackB.isNotEmpty && trackB == episodeA) return true;
  final fileA = downloadTaskFileKey(a.task);
  final fileB = downloadTaskFileKey(b.task);
  return fileA.isNotEmpty && fileA == fileB;
}

int _statusRank(TaskStatus status) {
  switch (status) {
    case TaskStatus.running:
      return 0;
    case TaskStatus.enqueued:
      return 1;
    case TaskStatus.waitingToRetry:
      return 2;
    case TaskStatus.paused:
      return 3;
    case TaskStatus.complete:
      return 4;
    default:
      return 5;
  }
}

int _keepScore(DownloadItem a, DownloadItem b) {
  final rank = _statusRank(a.status).compareTo(_statusRank(b.status));
  if (rank != 0) return rank;
  return b.timestamp.compareTo(a.timestamp);
}

List<List<DownloadItem>> groupDownloadsByEpisodeOrFile(
  List<DownloadItem> items,
) {
  if (items.isEmpty) return const [];
  final parent = List<int>.generate(items.length, (i) => i);
  int find(int i) {
    var current = i;
    while (parent[current] != current) {
      parent[current] = parent[parent[current]];
      current = parent[current];
    }
    return current;
  }

  void union(int a, int b) {
    final rootA = find(a);
    final rootB = find(b);
    if (rootA != rootB) parent[rootA] = rootB;
  }

  final byTracking = <String, int>{};
  final byFile = <String, int>{};
  void unionKey(Map<String, int> map, String key, int i) {
    if (key.isEmpty) return;
    final previous = map[key];
    if (previous != null) {
      union(i, previous);
    } else {
      map[key] = i;
    }
  }

  for (var i = 0; i < items.length; i++) {
    unionKey(byTracking, downloadTrackingUrl(items[i].task), i);
    unionKey(byTracking, items[i].episode?.url.trim() ?? '', i);
    unionKey(byFile, downloadTaskFileKey(items[i].task), i);
  }

  final groups = <int, List<DownloadItem>>{};
  for (var i = 0; i < items.length; i++) {
    groups.putIfAbsent(find(i), () => []).add(items[i]);
  }
  return groups.values.toList();
}

class CollapsedDownloads {
  const CollapsedDownloads({
    required this.visible,
    required this.extraCompleteRecords,
  });

  /// One row per episode / file, newest active preferred over complete.
  final List<DownloadItem> visible;

  /// Extra complete FileDownloader records to drop from DB+metadata only.
  final List<DownloadItem> extraCompleteRecords;
}

/// Keep one UI row per episode/file. Extra complete records are listed so
/// callers can delete them from the downloader DB without touching the file.
CollapsedDownloads collapseDuplicateDownloads(List<DownloadItem> items) {
  if (items.length <= 1) {
    return CollapsedDownloads(visible: items, extraCompleteRecords: const []);
  }

  final visible = <DownloadItem>[];
  final extraComplete = <DownloadItem>[];
  final keptIds = <String>{};

  for (final group in groupDownloadsByEpisodeOrFile(items)) {
    if (group.length == 1) {
      visible.add(group.first);
      keptIds.add(group.first.id);
      continue;
    }
    final ranked = List<DownloadItem>.from(group)..sort(_keepScore);
    final kept = ranked.first;
    visible.add(kept);
    keptIds.add(kept.id);
    for (final extra in ranked.skip(1)) {
      if (extra.status == TaskStatus.complete) {
        extraComplete.add(extra);
      }
    }
  }

  // Keep the caller's order (FIFO by enqueue timestamp).
  final originalIndex = <String, int>{};
  for (var i = 0; i < items.length; i++) {
    originalIndex.putIfAbsent(items[i].id, () => i);
  }
  visible.sort(
    (a, b) => (originalIndex[a.id] ?? 0).compareTo(originalIndex[b.id] ?? 0),
  );
  return CollapsedDownloads(
    visible: visible,
    extraCompleteRecords: extraComplete
        .where((item) => !keptIds.contains(item.id))
        .toList(),
  );
}

/// Build a Downloads row from Hive metadata so tapping تنزيل can show
/// **في الانتظار** before FileDownloader's record exists.
DownloadItem? downloadItemFromTaskMetadata({
  required Task task,
  required TaskStatus status,
  required Map<String, dynamic> metadata,
  double progress = 0,
}) {
  final rawItem = metadata['item'];
  if (rawItem is! Map) return null;
  var storedProgress = progress;
  if (storedProgress < 0 || storedProgress > 1) {
    storedProgress = status == TaskStatus.complete ? 1.0 : 0.0;
  }
  return DownloadItem(
    task: task,
    status: displayDownloadStatus(
      persisted: status,
      queueWaiting: isQueueWaitingMetadata(metadata),
    ),
    progress: storedProgress,
    item: MultimediaItem.fromJson(Map<String, dynamic>.from(rawItem)),
    episode: metadata['episode'] != null
        ? Episode.fromJson(
            Map<String, dynamic>.from(metadata['episode'] as Map),
          )
        : null,
    timestamp: (metadata['timestamp'] as int?) ?? 0,
  );
}

@Riverpod(keepAlive: true)
class DownloadsNotifier extends _$DownloadsNotifier {
  static const Duration _listProgressUiInterval = Duration(seconds: 1);
  final Set<String> _deletingIds = <String>{};
  final Map<String, DateTime> _lastProgressUiUpdate = <String, DateTime>{};

  @override
  Future<List<DownloadItem>> build() async {
    // Listen to updates from DownloadService (broadcast) instead of FileDownloader (single)
    final subscription = ref.read(downloadServiceProvider).updates.listen((
      update,
    ) {
      _handleUpdate(update);
    });

    ref.onDispose(() {
      subscription.cancel();
    });

    return _refreshList();
  }

  Future<List<DownloadItem>> _refreshList() async {
    final records = await FileDownloader().database.allRecords();
    final storage = ref.read(storageServiceProvider);

    final List<DownloadItem> items = [];

    for (final record in records) {
      // Skip non-download tasks and cancelled ones. Failed downloads are kept
      // and shown as paused so the user can resume instead of starting over.
      if (record.task is! DownloadTask) continue;
      if (record.status == TaskStatus.canceled) {
        continue;
      }

      var status = record.status;
      var progress = record.progress;
      if (status == TaskStatus.failed || status == TaskStatus.notFound) {
        status = TaskStatus.paused;
        if (progress < 0 || progress > 1) progress = 0.0;
        unawaited(
          FileDownloader().database.updateRecord(
            TaskRecord(
              record.task,
              TaskStatus.paused,
              progress,
              record.expectedFileSize,
            ),
          ),
        );
      } else if (progress < 0 || progress > 1) {
        // Sentinel progress values from the downloader (failed/paused markers)
        progress = status == TaskStatus.complete ? 1.0 : 0.0;
      }

      final metadata = await storage.getDownloadMetadata(record.task.taskId);
      if (metadata == null) continue;
      final item = downloadItemFromTaskMetadata(
        task: record.task,
        status: status,
        metadata: metadata,
        progress: progress,
      );
      if (item == null) continue;
      items.add(item);
      if (status == TaskStatus.complete) {
        unawaited(
          ensureDownloadedEpisodeArtwork(
            taskId: item.id,
            episode: item.episode,
          ),
        );
      }
    }

    // A user-deleted task is a session tombstone until its native cleanup has
    // fully settled. Never let an unrelated refresh briefly resurrect it.
    items.removeWhere((item) => _deletingIds.contains(item.id));

    // FIFO: oldest first.
    items.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    final collapsed = collapseDuplicateDownloads(items);
    for (final extra in collapsed.extraCompleteRecords) {
      await FileDownloader().database.deleteRecordWithId(extra.task.taskId);
      await storage.removeDownloadMetadata(extra.task.taskId);
      await deleteDownloadedEpisodeArtwork(extra.id);
    }
    return _orderDownloads(collapsed.visible);
  }

  List<DownloadItem> _orderDownloads(List<DownloadItem> items) {
    final active = <DownloadItem>[];
    final completed = <DownloadItem>[];
    for (final item in items) {
      if (isActiveDownloadStatus(item.status)) {
        active.add(item);
      } else {
        completed.add(item);
      }
    }
    active.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    completed.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return [...active, ...completed];
  }

  Future<void> _handleUpdate(TaskUpdate update) async {
    if (state.value == null || _deletingIds.contains(update.task.taskId))
      return;

    // DownloadService already exposes sampled live metrics. Keep the durable
    // list snapshot to the same one-second cadence so the whole downloads page
    // does not rebuild for every native didWriteData packet.
    if (update is TaskProgressUpdate &&
        update.progress >= 0 &&
        update.progress < 1) {
      final now = DateTime.now();
      final last = _lastProgressUiUpdate[update.task.taskId];
      if (last != null && now.difference(last) < _listProgressUiInterval) {
        return;
      }
      _lastProgressUiUpdate[update.task.taskId] = now;
    }

    final List<DownloadItem> currentList = state.value!;
    final index = currentList.indexWhere(
      (item) => item.id == update.task.taskId,
    );

    if (index != -1) {
      final existing = currentList[index];
      double newProgress = existing.progress;
      TaskStatus newStatus = existing.status;

      if (update is TaskProgressUpdate) {
        if (update.progress >= 0 && update.progress <= 1) {
          newProgress = update.progress;
        }
      } else if (update is TaskStatusUpdate) {
        newStatus = update.status;
        if (update.status == TaskStatus.complete) newProgress = 1.0;
      }

      if (newStatus == TaskStatus.canceled) {
        // User delete and enqueue rollback already drop metadata. A canceled
        // event must not leave a ghost row.
        final newList = List<DownloadItem>.from(currentList)..removeAt(index);
        state = AsyncData(newList);
      } else {
        // Failures are remapped to paused by DownloadService before broadcast,
        // but keep this guard so a raw failed event can never wipe the row.
        if (newStatus == TaskStatus.failed ||
            newStatus == TaskStatus.notFound) {
          newStatus = TaskStatus.paused;
        }
        final updatedItem = DownloadItem(
          task: existing.task,
          status: newStatus,
          progress: newProgress.clamp(0.0, 1.0),
          item: existing.item,
          episode: existing.episode,
          timestamp: existing.timestamp,
        );

        if (newStatus == TaskStatus.complete) {
          unawaited(
            ensureDownloadedEpisodeArtwork(
              taskId: updatedItem.id,
              episode: updatedItem.episode,
            ),
          );
        }

        final newList = List<DownloadItem>.from(currentList);
        newList[index] = updatedItem;
        if (isActiveDownloadStatus(existing.status) &&
            !isActiveDownloadStatus(newStatus)) {
          state = AsyncData(_orderDownloads(newList));
        } else {
          state = AsyncData(newList);
        }
      }
    } else {
      // New download: show the row as soon as Hive metadata exists, even if
      // FileDownloader has not written the record yet (HQ overflow).
      if (update is TaskStatusUpdate &&
          update.task is DownloadTask &&
          isActiveDownloadStatus(update.status)) {
        final metadata = await ref
            .read(storageServiceProvider)
            .getDownloadMetadata(update.task.taskId);
        final incoming = metadata == null
            ? null
            : downloadItemFromTaskMetadata(
                task: update.task,
                status: update.status,
                metadata: metadata,
              );
        if (incoming != null) {
          final collapsed = collapseDuplicateDownloads([
            ...currentList,
            incoming,
          ]);
          state = AsyncData(_orderDownloads(collapsed.visible));
          return;
        }
      }
      state = AsyncData(await _refreshList());
    }
  }

  Future<void> removeDownload(DownloadItem item) async {
    await removeDownloads([item]);
  }

  Future<void> removeDownloads(List<DownloadItem> items) async {
    if (items.isEmpty) return;
    final downloadService = ref.read(downloadServiceProvider);
    final storage = ref.read(storageServiceProvider);
    final current = List<DownloadItem>.from(state.value ?? items);

    // Resolve the logical rows synchronously first and hide them before any
    // filesystem/native await. The old order deleted the file first and, when
    // an active worker still owned it, `stillExists` caused us to skip cancel
    // entirely — leaving a stuck row that could never disappear.
    final toRemove = <String, DownloadItem>{};
    for (final requested in items) {
      toRemove[requested.id] = requested;
      for (final candidate in current) {
        if (downloadsPointAtSameTarget(requested, candidate)) {
          toRemove[candidate.id] = candidate;
        }
      }
    }

    final droppedIds = toRemove.keys.toSet();
    _deletingIds.addAll(droppedIds);
    for (final id in droppedIds) {
      _lastProgressUiUpdate.remove(id);
    }

    if (state.value != null) {
      state = AsyncData(
        state.value!.where((item) => !droppedIds.contains(item.id)).toList(),
      );
    }

    for (final item in toRemove.values) {
      final trackingUrl = downloadTrackingUrl(item.task);
      ref.read(activeDownloadsProvider.notifier).remove(trackingUrl);
      ref.read(downloadProgressProvider.notifier).remove(trackingUrl);
      ref.read(downloadChunkProgressProvider.notifier).remove(item.id);
    }

    // Capture possible final/partial paths before cancel removes metadata. This
    // is cleanup-only work: the card is already gone and controls are free.
    final filesToDelete = <String, File>{};
    for (final item in toRemove.values) {
      try {
        final taskPath = await item.task.filePath();
        if (taskPath.isNotEmpty) filesToDelete[taskPath] = File(taskPath);
      } catch (_) {}
      try {
        final resolved = await downloadService
            .resolveDownloadedFile(item.task, item.item, episode: item.episode)
            .timeout(const Duration(milliseconds: 750));
        if (resolved != null) filesToDelete[resolved.path] = resolved;
      } catch (_) {}
    }

    // Stop ownership and tombstone DB/Hive first. Every step is best-effort so
    // one stale URLSession worker can never prevent the logical delete.
    for (final item in toRemove.values) {
      final trackingUrl = downloadTrackingUrl(item.task);
      if (shouldCancelDownload(item.status)) {
        try {
          await downloadService
              .cancelDownload(item.task.taskId, trackingUrl)
              .timeout(const Duration(seconds: 3));
        } catch (_) {
          // Timeout only releases the UI cleanup path; cancelDownload continues
          // settling its native Future in the background.
        }
      }
      try {
        await FileDownloader().database.deleteRecordWithId(item.task.taskId);
      } catch (_) {}
      try {
        await storage.removeDownloadMetadata(item.task.taskId);
      } catch (_) {}
      try {
        await deleteDownloadedEpisodeArtwork(item.id);
      } catch (_) {}
    }

    final deletedPaths = <String>{};
    for (final file in filesToDelete.values) {
      if (!deletedPaths.add(file.path)) continue;
      try {
        await downloadService
            .deleteDownloadedFile(file)
            .timeout(const Duration(seconds: 2));
      } catch (_) {
        try {
          if (await file.exists()) await file.delete(recursive: true);
        } catch (_) {}
      }
    }
  }

  void _setOptimisticStatus(String taskId, TaskStatus status) {
    final current = state.value;
    if (current == null) return;
    final index = current.indexWhere((item) => item.id == taskId);
    if (index < 0) return;

    final existing = current[index];
    final trackingUrl = downloadTrackingUrl(existing.task);
    final live = ref.read(downloadProgressProvider)[trackingUrl];
    final progress = live?.progress ?? existing.progress;
    final updated = DownloadItem(
      task: existing.task,
      status: status,
      progress: progress,
      item: existing.item,
      episode: existing.episode,
      timestamp: existing.timestamp,
    );
    final next = List<DownloadItem>.from(current)..[index] = updated;
    state = AsyncData(next);

    ref
        .read(downloadProgressProvider.notifier)
        .update(
          trackingUrl,
          DownloadProgressData(
            taskId: taskId,
            progress: progress,
            networkSpeed: status == TaskStatus.running
                ? (live?.networkSpeed ?? 0)
                : 0,
            timeRemaining: status == TaskStatus.running
                ? (live?.timeRemaining ?? Duration.zero)
                : Duration.zero,
            totalSize: live?.totalSize ?? -1,
            status: status,
          ),
        );
  }

  Future<void> pauseDownload(String taskId) async {
    final outcome = await ref
        .read(downloadServiceProvider)
        .pauseDownloadOutcome(taskId);
    if (outcome == DownloadCommandOutcome.paused) {
      _setOptimisticStatus(taskId, TaskStatus.paused);
      return;
    }
    state = AsyncData(await _refreshList());
  }

  Future<void> resumeDownload(String taskId) async {
    final outcome = await ref
        .read(downloadServiceProvider)
        .resumeDownloadOutcome(taskId);
    switch (outcome) {
      case DownloadCommandOutcome.running:
      case DownloadCommandOutcome.attached:
        _setOptimisticStatus(taskId, TaskStatus.running);
      case DownloadCommandOutcome.queued:
        _setOptimisticStatus(taskId, TaskStatus.enqueued);
      default:
        state = AsyncData(await _refreshList());
    }
  }
}
