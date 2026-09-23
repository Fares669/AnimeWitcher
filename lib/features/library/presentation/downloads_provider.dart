import 'dart:async';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:path/path.dart' as p;
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/domain/entity/manga.dart';
import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/services/download_concurrency.dart';
import '../../../core/services/download_v2/download_v2_identity.dart';
import '../../../core/services/download_v2/download_v2_models.dart';
import '../../../core/services/download_v2/download_v2_provider.dart';
import '../../../core/storage/storage_service.dart';
import 'download_episode_artwork.dart';

part 'downloads_provider.g.dart';

class DownloadItem {
  final Task task;
  final TaskStatus status;
  final double progress;
  final MultimediaItem item;
  final Episode? episode;
  final MangaChapter? chapter;
  final DownloadMediaKind mediaKind;
  final String? logicalId;
  final int timestamp;
  final String trackingUrl;
  final String destinationPath;
  final int parallelChunks;
  final int? transferredBytes;
  final int? totalBytes;
  final double networkSpeedMBps;
  final Duration timeRemaining;

  DownloadItem({
    required this.task,
    required this.status,
    required this.progress,
    required this.item,
    this.episode,
    this.chapter,
    this.mediaKind = DownloadMediaKind.videoEpisode,
    this.logicalId,
    required this.timestamp,
    String? trackingUrl,
    String? destinationPath,
    int? parallelChunks,
    this.transferredBytes,
    this.totalBytes,
    this.networkSpeedMBps = -1,
    this.timeRemaining = Duration.zero,
  }) : trackingUrl = trackingUrl ?? task.metaData,
       destinationPath = destinationPath ?? '',
       parallelChunks = parallelChunks ??
           (task is ParallelDownloadTask ? task.chunks : 1);

  String get id => task.taskId;
}

bool downloadsPointAtSameTarget(DownloadItem a, DownloadItem b) {
  if (identical(a, b) || a.id == b.id) return true;
  final logicalA = a.logicalId?.trim();
  final logicalB = b.logicalId?.trim();
  if (logicalA != null &&
      logicalA.isNotEmpty &&
      logicalB != null &&
      logicalB.isNotEmpty) {
    return logicalA == logicalB;
  }

  // Defensive fallback for malformed/incomplete presentation rows.
  final trackA = a.trackingUrl.trim();
  final trackB = b.trackingUrl.trim();
  if (trackA.isNotEmpty && trackA == trackB) return true;
  final chapterA = a.chapter?.url.trim() ?? '';
  final chapterB = b.chapter?.url.trim() ?? '';
  if (chapterA.isNotEmpty && chapterA == chapterB) return true;
  final episodeA = a.episode?.url.trim() ?? '';
  final episodeB = b.episode?.url.trim() ?? '';
  if (episodeA.isNotEmpty && episodeA == episodeB) return true;
  if (trackA.isNotEmpty && trackA == episodeB) return true;
  if (trackB.isNotEmpty && trackB == episodeA) return true;
  final fileA = a.destinationPath.trim();
  final fileB = b.destinationPath.trim();
  return fileA.isNotEmpty && fileA == fileB;
}

DownloadItem? completedMangaChapterDownload(
  List<DownloadItem> downloads,
  MangaChapter chapter,
) {
  final mangaId = chapter.mangaId.trim();
  final chapterId = chapter.id.trim();
  final logicalId = mangaId.isNotEmpty && chapterId.isNotEmpty
      ? logicalDownloadIdForMangaChapter(
          mangaId: mangaId,
          chapterId: chapterId,
        ).value
      : null;
  final chapterUrl = chapter.url.trim();

  for (final item in downloads) {
    if (item.status != TaskStatus.complete ||
        item.mediaKind != DownloadMediaKind.mangaChapter) {
      continue;
    }
    if (logicalId != null && item.logicalId?.trim() == logicalId) return item;
    final downloadedChapter = item.chapter;
    if (downloadedChapter != null &&
        downloadedChapter.mangaId.trim() == mangaId &&
        downloadedChapter.id.trim() == chapterId) {
      return item;
    }
    if (chapterUrl.isNotEmpty &&
        (item.trackingUrl.trim() == chapterUrl ||
            downloadedChapter?.url.trim() == chapterUrl)) {
      return item;
    }
  }
  return null;
}

DownloadItem? completedEpisodeDownload(
  List<DownloadItem> downloads,
  MultimediaItem parentItem,
  Episode episode,
) {
  final parentUrl = parentItem.url.trim();
  final episodeUrl = episode.url.trim();
  for (final item in downloads) {
    if (item.status != TaskStatus.complete ||
        item.mediaKind != DownloadMediaKind.videoEpisode) {
      continue;
    }
    if (parentUrl.isNotEmpty && item.item.url.trim() != parentUrl) continue;
    if (episodeUrl.isNotEmpty &&
        (item.trackingUrl.trim() == episodeUrl ||
            item.episode?.url.trim() == episodeUrl)) {
      return item;
    }
  }
  return null;
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

  final byLogicalId = <String, int>{};
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
    final logicalId = items[i].logicalId?.trim();
    if (logicalId != null && logicalId.isNotEmpty) {
      unionKey(byLogicalId, logicalId, i);
      continue;
    }
    unionKey(byTracking, items[i].trackingUrl.trim(), i);
    unionKey(byTracking, items[i].episode?.url.trim() ?? '', i);
    unionKey(byFile, items[i].destinationPath.trim(), i);
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

  final List<DownloadItem> visible;
  final List<DownloadItem> extraCompleteRecords;
}

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
      if (extra.status == TaskStatus.complete) extraComplete.add(extra);
    }
  }

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

@Riverpod(keepAlive: true)
class DownloadsNotifier extends _$DownloadsNotifier {
  static const Duration _refreshInterval = Duration(seconds: 1);
  static const Duration _durableRefreshInterval = Duration(seconds: 30);

  final Set<String> _deletingIds = <String>{};
  final Set<String> _artworkScheduledIds = <String>{};
  List<LogicalDownloadRecordV2> _records = const <LogicalDownloadRecordV2>[];
  Map<String, Map<String, dynamic>> _metadataByTaskId =
      const <String, Map<String, dynamic>>{};
  StreamSubscription<List<LogicalDownloadRecordV2>>? _recordsSubscription;
  Timer? _refreshTimer;
  Timer? _durableRefreshTimer;
  Future<void>? _durableReloadInFlight;

  @override
  Future<List<DownloadItem>> build() async {
    final manager = ref.read(downloadManagerV2Provider);
    await manager.initialize();

    _records = await ref.read(logicalDownloadStoreV2Provider).all();
    _metadataByTaskId = await ref
        .read(storageServiceProvider)
        .getAllDownloadMetadata();

    _recordsSubscription = manager.records.listen((records) {
      _records = records;
      unawaited(_reloadMetadataAndRefresh());
    });

    // Progress is ephemeral manager state. Project it from memory every second;
    // do not scan both Hive boxes on the UI isolate for every progress tick.
    _refreshTimer = Timer.periodic(_refreshInterval, (_) {
      _refreshPresentationState();
    });
    // Keep a much slower durable reconciliation as a lifecycle/race safety net.
    _durableRefreshTimer = Timer.periodic(_durableRefreshInterval, (_) {
      unawaited(_reloadDurableState());
    });

    ref.onDispose(() {
      unawaited(_recordsSubscription?.cancel());
      _refreshTimer?.cancel();
      _durableRefreshTimer?.cancel();
    });

    return _projectList();
  }

  void _refreshPresentationState() {
    state = AsyncData(_projectList());
  }

  Future<void> _reloadMetadataAndRefresh() async {
    _metadataByTaskId = await ref
        .read(storageServiceProvider)
        .getAllDownloadMetadata();
    _refreshPresentationState();
  }

  Future<void> _reloadDurableState() {
    final existing = _durableReloadInFlight;
    if (existing != null) return existing;

    final task = () async {
      _records = await ref.read(logicalDownloadStoreV2Provider).all();
      _metadataByTaskId = await ref
          .read(storageServiceProvider)
          .getAllDownloadMetadata();
      _refreshPresentationState();
    }();
    _durableReloadInFlight = task;
    return task.whenComplete(() {
      if (identical(_durableReloadInFlight, task)) {
        _durableReloadInFlight = null;
      }
    });
  }

  List<DownloadItem> _projectList() {
    final manager = ref.read(downloadManagerV2Provider);
    final metadataByTaskId = _metadataByTaskId;
    final metadataByLogicalId = <String, Map<String, dynamic>>{};

    for (final metadata in metadataByTaskId.values) {
      final logicalId = (metadata['logicalId'] as String?)?.trim();
      if (logicalId == null || logicalId.isEmpty) continue;
      final previous = metadataByLogicalId[logicalId];
      final previousTimestamp = (previous?['timestamp'] as int?) ?? -1;
      final timestamp = (metadata['timestamp'] as int?) ?? 0;
      if (previous == null || timestamp >= previousTimestamp) {
        metadataByLogicalId[logicalId] = metadata;
      }
    }

    final items = <DownloadItem>[];
    for (final record in _records) {
      if (record.intent == DownloadUserIntent.canceled) continue;
      final metadata = metadataByTaskId[record.taskId] ??
          metadataByLogicalId[record.logicalId.value];
      if (metadata == null || metadata['item'] is! Map) continue;

      final item = MultimediaItem.fromJson(
        Map<String, dynamic>.from(metadata['item'] as Map),
      );
      final episode = metadata['episode'] is Map
          ? Episode.fromJson(
              Map<String, dynamic>.from(metadata['episode'] as Map),
            )
          : null;
      final taskSnapshot = metadata['taskSnapshot'] is Map
          ? Map<String, dynamic>.from(metadata['taskSnapshot'] as Map)
          : const <String, dynamic>{};
      final chapter = MangaChapter.fromJson(taskSnapshot['chapter']);
      final trackingUrl = _trackingUrlFor(
        metadata,
        item,
        episode,
        chapter,
      );
      final snapshot = manager.snapshotFor(record.logicalId);
      final task = _presentationTaskFor(
        record,
        trackingUrl: trackingUrl,
      );
      final projected = DownloadItem(
        task: task,
        status: _taskStatusFor(record, snapshot),
        progress: _progressFor(record, snapshot),
        item: item,
        episode: episode,
        chapter: chapter,
        mediaKind: record.mediaKind,
        logicalId: record.logicalId.value,
        timestamp: (metadata['timestamp'] as int?) ?? record.updatedAtMillis,
        trackingUrl: trackingUrl,
        destinationPath: record.destinationPath,
        parallelChunks: record.parallelChunks,
        transferredBytes: snapshot?.transferredBytes,
        totalBytes: snapshot?.totalBytes ?? record.expectedBytes,
        networkSpeedMBps: snapshot?.networkSpeedMBps ?? -1,
        timeRemaining: snapshot?.timeRemaining ?? Duration.zero,
      );
      items.add(projected);
      if (projected.status == TaskStatus.complete &&
          projected.mediaKind == DownloadMediaKind.videoEpisode &&
          _artworkScheduledIds.add(projected.id)) {
        unawaited(
          ensureDownloadedEpisodeArtwork(
            taskId: projected.id,
            episode: projected.episode,
          ),
        );
      }
    }

    items.removeWhere((item) => _deletingIds.contains(item.id));
    items.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return _orderDownloads(collapseDuplicateDownloads(items).visible);
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
    return <DownloadItem>[...active, ...completed];
  }

  Future<void> removeDownload(DownloadItem item) async {
    await removeDownloads(<DownloadItem>[item]);
  }

  Future<void> removeDownloads(List<DownloadItem> items) async {
    if (items.isEmpty) return;
    final current = List<DownloadItem>.from(state.value ?? items);
    final toRemove = <String, DownloadItem>{};

    for (final requested in items) {
      toRemove[requested.id] = requested;
      for (final candidate in current) {
        if (downloadsPointAtSameTarget(requested, candidate)) {
          toRemove[candidate.id] = candidate;
        }
      }
    }

    final manager = ref.read(downloadManagerV2Provider);
    final storage = ref.read(storageServiceProvider);
    for (final item in toRemove.values) {
      final logical = item.logicalId?.trim();
      if (logical != null && logical.isNotEmpty) {
        await manager.delete(DownloadLogicalId(logical));
        final metadata = await storage.getAllDownloadMetadata();
        for (final entry in metadata.entries) {
          if ((entry.value['logicalId'] as String?)?.trim() == logical) {
            await storage.removeDownloadMetadata(entry.key);
          }
        }
      } else {
        final path = item.destinationPath.trim();
        if (path.isNotEmpty) {
          try {
            final file = File(path);
            if (await file.exists()) await file.delete();
          } catch (_) {}
        }
        await storage.removeDownloadMetadata(item.id);
      }
    }

    final droppedIds = toRemove.keys.toSet();
    _deletingIds.addAll(droppedIds);
    if (state.value != null) {
      state = AsyncData(
        state.value!.where((item) => !droppedIds.contains(item.id)).toList(),
      );
    }
  }

  Future<void> pauseDownload(String taskId) async {
    final item = state.value?.where((item) => item.id == taskId).firstOrNull;
    final logical = item?.logicalId?.trim();
    if (logical == null || logical.isEmpty) return;
    await ref.read(downloadManagerV2Provider).pause(DownloadLogicalId(logical));
    await _reloadDurableState();
  }

  Future<void> resumeDownload(String taskId) async {
    final item = state.value?.where((item) => item.id == taskId).firstOrNull;
    final logical = item?.logicalId?.trim();
    if (logical == null || logical.isEmpty) return;
    await ref.read(downloadManagerV2Provider).resume(DownloadLogicalId(logical));
    await _reloadDurableState();
  }
}

String _trackingUrlFor(
  Map<String, dynamic> metadata,
  MultimediaItem item,
  Episode? episode,
  MangaChapter? chapter,
) {
  final stored = (metadata['trackingUrl'] as String?)?.trim();
  if (stored != null && stored.isNotEmpty) return stored;
  final chapterUrl = chapter?.url.trim();
  if (chapterUrl != null && chapterUrl.isNotEmpty) return chapterUrl;
  final episodeUrl = episode?.url.trim();
  if (episodeUrl != null && episodeUrl.isNotEmpty) return episodeUrl;
  return item.url.trim();
}

TaskStatus _taskStatusFor(
  LogicalDownloadRecordV2 record,
  DownloadTransportSnapshot? snapshot,
) {
  if (record.completedAtMillis != null) return TaskStatus.complete;
  if (record.intent == DownloadUserIntent.canceled) return TaskStatus.canceled;
  if (record.intent == DownloadUserIntent.paused) return TaskStatus.paused;

  return switch (snapshot?.status) {
    DownloadTransportStatus.queued => TaskStatus.enqueued,
    DownloadTransportStatus.running => TaskStatus.running,
    DownloadTransportStatus.held => TaskStatus.waitingToRetry,
    DownloadTransportStatus.paused => TaskStatus.paused,
    DownloadTransportStatus.failed || DownloadTransportStatus.missing =>
      TaskStatus.paused,
    DownloadTransportStatus.canceled => TaskStatus.canceled,
    // Package completion is not a logical completion until the V2 integrity
    // gate persists completedAtMillis.
    DownloadTransportStatus.complete => TaskStatus.running,
    null => TaskStatus.enqueued,
  };
}

double _progressFor(
  LogicalDownloadRecordV2 record,
  DownloadTransportSnapshot? snapshot,
) {
  if (record.completedAtMillis != null) return 1;
  final progress = snapshot?.progress ?? 0;
  return progress.clamp(0.0, 1.0).toDouble();
}

Task _presentationTaskFor(
  LogicalDownloadRecordV2 record, {
  required String trackingUrl,
}) {
  return _presentationTask(
    taskId: record.taskId,
    destinationPath: record.destinationPath,
    trackingUrl: trackingUrl,
    parallelChunks: record.parallelChunks,
  );
}

Task _presentationTask({
  required String taskId,
  required String destinationPath,
  required String trackingUrl,
  required int parallelChunks,
}) {
  final absolute = p.isAbsolute(destinationPath);
  final directory = p.dirname(destinationPath) == '.'
      ? ''
      : p.dirname(destinationPath);
  final filename = p.basename(destinationPath);
  final url = trackingUrl.isNotEmpty
      ? trackingUrl
      : 'https://animewitcher.invalid/$taskId';
  final baseDirectory = absolute
      ? BaseDirectory.root
      : BaseDirectory.applicationDocuments;

  if (parallelChunks > 1) {
    return ParallelDownloadTask(
      taskId: taskId,
      url: url,
      filename: filename,
      directory: directory,
      baseDirectory: baseDirectory,
      chunks: parallelChunks,
      metaData: trackingUrl,
      updates: Updates.none,
      allowPause: true,
      retries: 0,
    );
  }
  return DownloadTask(
    taskId: taskId,
    url: url,
    filename: filename,
    directory: directory,
    baseDirectory: baseDirectory,
    metaData: trackingUrl,
    updates: Updates.none,
    allowPause: true,
    retries: 0,
  );
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}