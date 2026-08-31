import 'dart:convert';

import 'package:background_downloader/background_downloader.dart';

/// Hive settings key used by official SkyStream and this fork.
const String kDownloadConcurrencyStorageKey = 'download_concurrency';

/// Persisted on download metadata for leftover Dart-parked rows (PR #114)
/// and for kill-recovery of native holding-queue waiters that never reached
/// URLSession. In-app UI still maps this to **في الانتظار...**.
const String kDownloadQueueWaitingMetadataKey = 'queueWaiting';

const int kDownloadConcurrencyMin = 1;
const int kDownloadConcurrencyMax = 5;
const int kDownloadConcurrencyDefault = 1;

int clampDownloadConcurrency(int value) =>
    value.clamp(kDownloadConcurrencyMin, kDownloadConcurrencyMax);

/// Missing or non-numeric storage values fall back to sequential downloads.
int parseDownloadConcurrency(Object? raw) {
  if (raw is int) return clampDownloadConcurrency(raw);
  if (raw is num) return clampDownloadConcurrency(raw.round());
  return kDownloadConcurrencyDefault;
}

/// [Config.holdingQueue] triple: `(maxConcurrent, maxConcurrentByHost, maxConcurrentByGroup)`.
///
/// Host and group are left unconstrained (`null`) so the user's N is the only
/// cap. Official SkyStream copied the docs example `(N, 2, 1)`. AnimeWitcher
/// notifications use group `'downloads'` and episode tasks share the default
/// task group, so a group cap of 1 would force global sequential downloads and
/// ignore the 1–5 setting.
(int, int?, int?) downloadHoldingQueueValue(int maxConcurrent) =>
    (clampDownloadConcurrency(maxConcurrent), null, null);

List<(String, dynamic)> downloadHoldingQueueGlobalConfig(int maxConcurrent) =>
    <(String, dynamic)>[
      (Config.holdingQueue, downloadHoldingQueueValue(maxConcurrent)),
    ];

/// Persists [maxConcurrent] then reconfigures FileDownloader's holding queue
/// `(N, null, null)`. Every user-started episode is OS-enqueued; extras wait
/// natively as **في الانتظار**. Dart still promotes leftover waiters whenever
/// the isolate is alive (complete / fail / cancel / foreground / init).
Future<int> applyDownloadQueueSettings({
  required int maxConcurrent,
  required Future<void> Function(int value) persist,
  required Future<void> Function(List<(String, dynamic)> globalConfig)
  configure,
}) async {
  final n = clampDownloadConcurrency(maxConcurrent);
  await persist(n);
  await configure(downloadHoldingQueueGlobalConfig(n));
  return n;
}

/// True when Hive metadata marks this row as holding-queue waiting.
bool isQueueWaitingMetadata(Map<String, dynamic>? metadata) =>
    metadata?[kDownloadQueueWaitingMetadataKey] == true;

/// Occupied slots are files actually transferring. Native holding-queue
/// waiters (`enqueued`) and leftover Dart-parked (`queueWaiting`) rows wait
/// as **في الانتظار** and must not count against N.
bool occupiesDownloadSlot({
  required TaskStatus status,
  bool queueWaiting = false,
}) {
  if (queueWaiting) return false;
  switch (status) {
    case TaskStatus.running:
    case TaskStatus.waitingToRetry:
      return true;
    case TaskStatus.enqueued:
    case TaskStatus.paused:
    case TaskStatus.complete:
    case TaskStatus.canceled:
    case TaskStatus.failed:
    case TaskStatus.notFound:
      return false;
  }
}

/// Waiting rows may be stored paused (legacy Dart park) so the Downloads tab
/// must keep the existing **في الانتظار...** (`enqueued`) label. Native
/// holding-queue waiters are already [TaskStatus.enqueued]. A live transfer
/// always wins: `queueWaiting` must not hide **جارٍ التنزيل...**.
TaskStatus displayDownloadStatus({
  required TaskStatus persisted,
  required bool queueWaiting,
}) {
  if (persisted == TaskStatus.running ||
      persisted == TaskStatus.waitingToRetry) {
    return persisted;
  }
  if (queueWaiting) return TaskStatus.enqueued;
  return persisted;
}

/// iOS Live Activity / `BGContinuedProcessingTask` is only for a file that
/// is actually transferring. Waiting **في الانتظار** rows must not call `start`.
bool shouldStartDownloadLiveActivity(TaskStatus status) =>
    status == TaskStatus.running;

/// Overflow episodes are always OS-enqueued into the native holding queue.
/// Dart must not park-without-enqueue: that stranded ep3 on device (#116).
bool shouldEnqueueOverflowToNativeHoldingQueue() => true;

/// When the Flutter isolate is alive, Dart must start the next leftover
/// waiter if a slot is free. Always true in production — do not gate this off.
bool shouldPromoteWaitingWhenIsolateAlive() => true;

/// Opening the app must unstick a leftover waiter if a slot is free.
bool shouldPromoteWaitingOnAppForeground() => true;

/// Native UserDefaults snapshot: leftover parked rows and HQ `enqueued`
/// waiters. User-paused stays paused and is never persisted as a waiter.
bool isNativeWaitingSnapshotWaiter({
  required TaskStatus status,
  required bool queueWaiting,
  required bool userPaused,
}) {
  if (userPaused) return false;
  return queueWaiting || status == TaskStatus.enqueued;
}

/// Plugin `allTasks` / `taskForId` membership: HQ waiter or URLSession task.
bool isLiveNativeDownloadStatus(TaskStatus status) {
  switch (status) {
    case TaskStatus.running:
    case TaskStatus.enqueued:
    case TaskStatus.waitingToRetry:
      return true;
    case TaskStatus.paused:
    case TaskStatus.complete:
    case TaskStatus.canceled:
    case TaskStatus.failed:
    case TaskStatus.notFound:
      return false;
  }
}

class LiveNativeDownload {
  const LiveNativeDownload({required this.taskId, required this.trackingUrl});

  final String taskId;
  final String trackingUrl;
}

/// One native task per episode. If this taskId or trackingUrl is already in
/// FileDownloader's live set, Dart must attach — never enqueue a second copy.
bool shouldAttachToLiveNativeTask({
  required String taskId,
  required String trackingUrl,
  required Iterable<LiveNativeDownload> live,
}) {
  for (final item in live) {
    if (item.taskId == taskId) return true;
    if (trackingUrl.isNotEmpty && item.trackingUrl == trackingUrl) {
      return true;
    }
  }
  return false;
}

bool shouldStartSecondTransfer({required bool liveNativeOwnsEpisode}) =>
    !liveNativeOwnsEpisode;

/// Bytes on the wire: a waiter that is actually transferring must show
/// **جارٍ التنزيل...**, not stay frozen at في الانتظار.
bool progressMeansNativeTransfer(double progress) => progress > 0;

/// A 0.1MB stub must not notify **مكتمل**. Trust complete only when the
/// file is essentially whole, or when we have no contradictory progress.
bool isCompleteDownloadCredible({
  double? progress,
  int expectedBytes = -1,
  int? fileBytes,
}) {
  final p = progress ?? -1;
  if (p >= 0.99) return true;
  if (expectedBytes > 0 && fileBytes != null) {
    return fileBytes >= (expectedBytes * 0.9).round();
  }
  if (p > 0 && p < 0.99) return false;
  return true;
}

/// Full payload Swift needs to create the next `URLSessionDownloadTask`
/// without Dart reconstructing the `DownloadTask`.
Map<String, Object> nativeWaitingPayload(
  DownloadTask task, {
  String? notificationConfigJson,
}) {
  return <String, Object>{
    'taskId': task.taskId,
    'taskJson': jsonEncode(task.toJson()),
    'displayName': task.displayName,
    'url': task.url,
    'headers': Map<String, String>.from(task.headers),
    'filename': task.filename,
    'directory': task.directory,
    'httpRequestMethod': task.httpRequestMethod,
    'group': task.group,
    'metaData': task.metaData,
    if (notificationConfigJson != null && notificationConfigJson.isNotEmpty)
      'notificationConfigJson': notificationConfigJson,
  };
}

bool nativeWaiterPayloadIsComplete(Map<String, Object?> payload) {
  final taskJson = payload['taskJson'] as String?;
  final url = payload['url'] as String?;
  final filename = payload['filename'] as String?;
  final taskId = payload['taskId'] as String?;
  return taskJson != null &&
      taskJson.isNotEmpty &&
      url != null &&
      url.isNotEmpty &&
      filename != null &&
      filename.isNotEmpty &&
      taskId != null &&
      taskId.isNotEmpty;
}

/// After a process kill, iOS `HoldingQueue` memory is gone. URLSession tasks
/// already submitted can continue; waiters that never reached URLSession must
/// be restored into the Swift waiting store. Never auto-resume a user-paused
/// row.
bool shouldReenqueueWaitingAfterProcessKill({
  required TaskStatus persisted,
  required bool queueWaiting,
  required bool userPaused,
  required bool stillInNativeQueue,
}) {
  if (stillInNativeQueue || userPaused) return false;
  if (queueWaiting) return true;
  return persisted == TaskStatus.enqueued;
}

/// iOS concurrency=1, two episodes: waiting rows stay **في الانتظار** with
/// no Live Activity. Overlay starts only when the native task is `running`.
bool waitingEpisodeMayStartLiveActivityWhileQueued() => false;

enum DownloadAdmission { enqueueToNativeHoldingQueue }

/// Every user-started episode is OS-enqueued. Native HoldingQueue owns N.
DownloadAdmission admitDownload({
  required int occupiedSlots,
  required int maxConcurrent,
}) {
  assert(occupiedSlots >= 0);
  clampDownloadConcurrency(maxConcurrent);
  return DownloadAdmission.enqueueToNativeHoldingQueue;
}

class DownloadQueueEntry {
  const DownloadQueueEntry({
    required this.taskId,
    required this.status,
    required this.timestamp,
    this.queueWaiting = false,
  });

  final String taskId;
  final TaskStatus status;
  final bool queueWaiting;
  final int timestamp;
}

class DownloadQueuePlan {
  const DownloadQueuePlan({
    required this.maxConcurrent,
    required this.occupiedCount,
    required this.waitingFifoIds,
    required this.idsToPark,
    required this.idsToPromote,
  });

  final int maxConcurrent;
  final int occupiedCount;
  final List<String> waitingFifoIds;
  final List<String> idsToPark;
  final List<String> idsToPromote;

  int get freeSlots => (maxConcurrent - occupiedCount).clamp(0, maxConcurrent);
}

/// FIFO re-enqueue of leftover Dart-parked waiters only. Native holding-queue
/// `enqueued` rows already have a live FileDownloader task — promoting them
/// starts a second transfer of the same episode (Rivera: 0.1MB ghost complete
/// then restart from 0). Occupying URLSession tasks are never detached.
DownloadQueuePlan planDownloadQueue({
  required int maxConcurrent,
  required Iterable<DownloadQueueEntry> entries,
}) {
  final n = clampDownloadConcurrency(maxConcurrent);
  final occupying = entries
      .where(
        (entry) => occupiesDownloadSlot(
          status: entry.status,
          queueWaiting: entry.queueWaiting,
        ),
      )
      .toList();
  final waiting =
      entries
          .where(
            (entry) =>
                entry.queueWaiting || entry.status == TaskStatus.enqueued,
          )
          .toList()
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
  final leftoverParked = entries.where((entry) => entry.queueWaiting).toList()
    ..sort((a, b) => a.timestamp.compareTo(b.timestamp));

  final waitingFifoIds = waiting.map((e) => e.taskId).toList();
  final occupiedCount = occupying.length;
  final freeSlots = (n - occupiedCount).clamp(0, n);
  final idsToPromote = leftoverParked
      .map((e) => e.taskId)
      .take(freeSlots)
      .toList();

  return DownloadQueuePlan(
    maxConcurrent: n,
    occupiedCount: occupiedCount,
    waitingFifoIds: waitingFifoIds,
    idsToPark: const [],
    idsToPromote: idsToPromote,
  );
}
