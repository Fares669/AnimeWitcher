import 'dart:convert';

import 'package:background_downloader/background_downloader.dart';

/// Hive settings key used by official SkyStream and this fork.
const String kDownloadConcurrencyStorageKey = 'download_concurrency';

/// Persisted on download metadata for leftover Dart-parked rows
/// (kill-recovery of waiters that never reached URLSession). In-app UI
/// still maps this to **في الانتظار...**.
const String kDownloadQueueWaitingMetadataKey = 'queueWaiting';

/// Hive metadata: the user tapped pause. Plugin pause produces resumeData
/// and drops the transferring URLSession task so kill-reopen stays paused
/// (not **جارٍ التنزيل** at 0 MB/s) without deleting already-downloaded bytes.
const String kDownloadUserPausedMetadataKey = 'userPaused';

/// Last known 0–1 progress. Fail/kill/pause must not wipe this.
const String kDownloadLastProgressMetadataKey = 'lastProgress';

/// Last known total size in bytes, paired with [kDownloadLastProgressMetadataKey].
const String kDownloadLastExpectedBytesMetadataKey = 'lastExpectedBytes';

/// Hive settings key for per-type download notification toggles.
const String kDownloadNotificationSettingsKey =
    'download_notification_settings';

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

/// A dead URL must not occupy the only slot with plugin retries. Park that
/// episode as paused and let the next waiter run; the user can resume later.
const int kDownloadTaskRetries = 0;

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

/// True when the user paused this episode (not a parked failure).
bool isUserPausedMetadata(Map<String, dynamic>? metadata) =>
    metadata?[kDownloadUserPausedMetadataKey] == true;

double downloadMetadataProgress(Map<String, dynamic>? metadata) {
  final value = metadata?[kDownloadLastProgressMetadataKey];
  if (value is num) {
    final progress = value.toDouble();
    if (progress > 0 && progress <= 1) return progress;
  }
  return 0;
}

int downloadMetadataExpectedBytes(Map<String, dynamic>? metadata) {
  final value = metadata?[kDownloadLastExpectedBytesMetadataKey];
  if (value is int) return value;
  if (value is num) return value.round();
  return -1;
}

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

/// One BGContinuedProcessingTask / Live Activity for the whole download
/// batch. `start` updates this session; never finish while anything is
/// running or waiting.
const String kDownloadSessionOverlayTaskId = 'session';

/// iOS Live Activity is only for a file that is actually transferring.
/// Waiting **في الانتظار** rows must not create a system task.
bool shouldStartDownloadLiveActivity(TaskStatus status) =>
    status == TaskStatus.running;

/// Never finish the session overlay while any episode in the batch is still
/// running or waiting. Only end the session when the batch is empty.
bool shouldFinishDownloadSessionOverlay({
  required int runningCount,
  required int waitingCount,
}) => runningCount <= 0 && waitingCount <= 0;

/// Plugin/system failure — keep the row, never wipe it as an error.
bool shouldParkFailedDownloadAsPaused(TaskStatus status) {
  switch (status) {
    case TaskStatus.failed:
    case TaskStatus.notFound:
      return true;
    case TaskStatus.canceled:
    case TaskStatus.paused:
    case TaskStatus.running:
    case TaskStatus.enqueued:
    case TaskStatus.waitingToRetry:
    case TaskStatus.complete:
      return false;
  }
}

/// System cancel (not the user's trash button) also parks as paused.
bool shouldParkSystemCanceledDownload({
  required TaskStatus status,
  required bool userCancel,
}) {
  if (userCancel) return false;
  return status == TaskStatus.canceled ||
      shouldParkFailedDownloadAsPaused(status);
}

/// Overlay copy for a parked failure. Never "Download failed" while the
/// rest of the queue is still going — or even when this was the last file.
const String kDownloadParkedNotificationBody = 'التنزيل متوقف مؤقتاً';

const String kDownloadRunningNotificationBodyIos = 'جارٍ التنزيل...';
const String kDownloadRunningNotificationBodyAndroid =
    '{progress} • {networkSpeed} • {timeRemaining}';
const String kDownloadCompleteNotificationBody = 'اكتمل التنزيل';
const String kDownloadCanceledNotificationBody = 'تم إلغاء التنزيل';

/// Per-type plugin notifications. All default on so existing installs keep
/// start / complete / pause / cancel / error banners until the user turns
/// them off in Settings.
class DownloadNotificationPrefs {
  const DownloadNotificationPrefs({
    this.running = true,
    this.complete = true,
    this.paused = true,
    this.canceled = true,
    this.error = true,
  });

  static const enabled = DownloadNotificationPrefs();

  static const disabled = DownloadNotificationPrefs(
    running: false,
    complete: false,
    paused: false,
    canceled: false,
    error: false,
  );

  final bool running;
  final bool complete;
  final bool paused;
  final bool canceled;
  final bool error;

  bool get allEnabled => running && complete && paused && canceled && error;

  bool get noneEnabled =>
      !running && !complete && !paused && !canceled && !error;

  DownloadNotificationPrefs copyWith({
    bool? running,
    bool? complete,
    bool? paused,
    bool? canceled,
    bool? error,
  }) {
    return DownloadNotificationPrefs(
      running: running ?? this.running,
      complete: complete ?? this.complete,
      paused: paused ?? this.paused,
      canceled: canceled ?? this.canceled,
      error: error ?? this.error,
    );
  }

  DownloadNotificationPrefs copyAll(bool enabled) => DownloadNotificationPrefs(
    running: enabled,
    complete: enabled,
    paused: enabled,
    canceled: enabled,
    error: enabled,
  );

  Map<String, bool> toJson() => <String, bool>{
    'running': running,
    'complete': complete,
    'paused': paused,
    'canceled': canceled,
    'error': error,
  };

  @override
  bool operator ==(Object other) =>
      other is DownloadNotificationPrefs &&
      running == other.running &&
      complete == other.complete &&
      paused == other.paused &&
      canceled == other.canceled &&
      error == other.error;

  @override
  int get hashCode => Object.hash(running, complete, paused, canceled, error);
}

DownloadNotificationPrefs parseDownloadNotificationPrefs(Object? raw) {
  if (raw is! Map) return const DownloadNotificationPrefs();
  bool read(String key) {
    final value = raw[key];
    if (value is bool) return value;
    return true;
  }

  return DownloadNotificationPrefs(
    running: read('running'),
    complete: read('complete'),
    paused: read('paused'),
    canceled: read('canceled'),
    error: read('error'),
  );
}

TaskNotification? downloadNotificationIfEnabled({
  required bool enabled,
  required String title,
  required String body,
}) => enabled ? TaskNotification(title, body) : null;

/// Plugin asserts at least one of running/complete/error/paused/canceled.
/// Turning every type off means we must clear the config set instead.
bool shouldClearDownloadNotificationConfigs(DownloadNotificationPrefs prefs) =>
    prefs.noneEnabled;

/// Native overlay finish: never report `failed` for a parked episode.
/// Remaining waiters keep the session; an idle batch ends as canceled.
String downloadSessionFinishStatus({
  required bool success,
  required bool parkedFailure,
}) {
  if (success && !parkedFailure) return 'completed';
  return 'canceled';
}

class DownloadOverlayEntry {
  const DownloadOverlayEntry({
    required this.taskId,
    required this.status,
    required this.displayName,
    this.queueWaiting = false,
    this.progress = 0,
    this.totalBytes = -1,
    this.speedBytesPerSecond = 0,
  });

  final String taskId;
  final TaskStatus status;
  final String displayName;
  final bool queueWaiting;
  final double progress;
  final int totalBytes;
  final double speedBytesPerSecond;
}

class DownloadOverlaySession {
  const DownloadOverlaySession({
    required this.currentTaskId,
    required this.displayName,
    required this.progress,
    required this.transferredBytes,
    required this.totalBytes,
    required this.completedCount,
    required this.batchTotal,
    required this.runningCount,
    required this.waitingCount,
    required this.currentIndex,
    this.speedBytesPerSecond = 0,
  });

  final String currentTaskId;
  final String displayName;
  final double progress;
  final int transferredBytes;
  final int totalBytes;
  final int completedCount;
  final int batchTotal;
  final int runningCount;
  final int waitingCount;
  final double speedBytesPerSecond;

  /// 1-based started count of this batch (`3 of 5` when three files run).
  final int currentIndex;

  bool get shouldFinish => shouldFinishDownloadSessionOverlay(
    runningCount: runningCount,
    waitingCount: waitingCount,
  );
}

bool _isOverlayWaiting(DownloadOverlayEntry entry) =>
    entry.queueWaiting || entry.status == TaskStatus.enqueued;

bool _isOverlayRunning(DownloadOverlayEntry entry) => occupiesDownloadSlot(
  status: entry.status,
  queueWaiting: entry.queueWaiting,
);

/// How many episodes in the batch have started (running + complete).
int overlayStartedCount({
  required int runningCount,
  required int completedCount,
}) => runningCount + completedCount;

/// `k of N` is started-count, not "which running file is flashing".
int overlayStartedIndex({
  required int runningCount,
  required int completedCount,
  required int batchTotal,
}) {
  final started = overlayStartedCount(
    runningCount: runningCount,
    completedCount: completedCount,
  );
  return overlayCurrentIndex(
    completedCount: started < 1 ? 0 : started - 1,
    batchTotal: batchTotal,
  );
}

class OverlayByteTotals {
  const OverlayByteTotals({
    required this.transferredBytes,
    required this.totalBytes,
    required this.progress,
    required this.speedBytesPerSecond,
  });

  final int transferredBytes;
  final int totalBytes;
  final double progress;
  final double speedBytesPerSecond;
}

/// N=1: current file bytes. N>1: sum of every transferring file so the
/// island does not flip between sizes.
OverlayByteTotals overlayRunningByteTotals(
  Iterable<DownloadOverlayEntry> running,
) {
  final list = running.toList();
  if (list.isEmpty) {
    return const OverlayByteTotals(
      transferredBytes: 0,
      totalBytes: -1,
      progress: 0,
      speedBytesPerSecond: 0,
    );
  }
  if (list.length == 1) {
    final entry = list.first;
    final progress = entry.progress.clamp(0.0, 1.0).toDouble();
    return OverlayByteTotals(
      transferredBytes: overlayTransferredBytes(
        progress: progress,
        totalBytes: entry.totalBytes,
      ),
      totalBytes: entry.totalBytes,
      progress: progress,
      speedBytesPerSecond: entry.speedBytesPerSecond,
    );
  }
  var transferred = 0;
  var total = 0;
  var speed = 0.0;
  var hasTotal = false;
  for (final entry in list) {
    if (entry.totalBytes > 0) {
      hasTotal = true;
      total += entry.totalBytes;
      transferred += overlayTransferredBytes(
        progress: entry.progress,
        totalBytes: entry.totalBytes,
      );
    }
    if (entry.speedBytesPerSecond > 0) {
      speed += entry.speedBytesPerSecond;
    }
  }
  return OverlayByteTotals(
    transferredBytes: transferred,
    totalBytes: hasTotal ? total : -1,
    progress: hasTotal && total > 0
        ? (transferred / total).clamp(0.0, 1.0)
        : 0.0,
    speedBytesPerSecond: speed,
  );
}

DownloadOverlaySession planDownloadOverlaySession({
  required Iterable<DownloadOverlayEntry> entries,
  List<String>? queueOrder,
}) {
  final list = List<DownloadOverlayEntry>.from(entries);
  if (queueOrder != null && queueOrder.isNotEmpty) {
    list.sort(
      (a, b) => compareByDownloadQueueOrder(a.taskId, b.taskId, queueOrder),
    );
  }
  final running = list.where(_isOverlayRunning).toList();
  final waiting = list.where(_isOverlayWaiting).toList();
  final completed = list
      .where((entry) => entry.status == TaskStatus.complete)
      .toList();
  final current = running.isNotEmpty
      ? running.first
      : (waiting.isNotEmpty ? waiting.first : null);
  final totals = overlayRunningByteTotals(running);
  final progress = running.isNotEmpty
      ? totals.progress
      : (current == null ? 0.0 : current.progress.clamp(0.0, 1.0).toDouble());
  final totalBytes = running.isNotEmpty
      ? totals.totalBytes
      : (current?.totalBytes ?? -1);
  final transferred = running.isNotEmpty
      ? totals.transferredBytes
      : overlayTransferredBytes(progress: progress, totalBytes: totalBytes);
  final batchTotal = running.length + waiting.length + completed.length;
  // While ep2 has not written bytes yet, the overlay still shows ep2 as
  // current. Started-count would be `1 of 4` (completed only) — Rivera
  // saw that on a 0B island. Use completed+1 so the next file is `2 of 4`.
  final currentIndex = running.isNotEmpty
      ? overlayStartedIndex(
          runningCount: running.length,
          completedCount: completed.length,
          batchTotal: batchTotal,
        )
      : overlayCurrentIndex(
          completedCount: completed.length,
          batchTotal: batchTotal,
        );
  return DownloadOverlaySession(
    currentTaskId: current?.taskId ?? kDownloadSessionOverlayTaskId,
    displayName: current?.displayName ?? '',
    progress: progress,
    transferredBytes: transferred,
    totalBytes: totalBytes,
    completedCount: completed.length,
    batchTotal: batchTotal,
    runningCount: running.length,
    waitingCount: waiting.length,
    currentIndex: currentIndex,
    speedBytesPerSecond: running.isNotEmpty ? totals.speedBytesPerSecond : 0,
  );
}

int overlayTransferredBytes({
  required double progress,
  required int totalBytes,
}) {
  if (totalBytes <= 0) return 0;
  final normalized = progress.clamp(0.0, 1.0);
  return (totalBytes * normalized).floor();
}

/// Compact `40MB` / `1.9MB/s` matching the manga-style island subtitle.
String formatDownloadOverlayBytes(int bytes) {
  final value = bytes < 0 ? 0.0 : bytes.toDouble();
  if (value >= 1000000000) {
    final gb = value / 1000000000;
    final text = gb >= 10 ? gb.toStringAsFixed(0) : gb.toStringAsFixed(1);
    return '${text}GB';
  }
  if (value >= 1000000) {
    final mb = value / 1000000;
    final text = mb >= 10 ? mb.toStringAsFixed(0) : mb.toStringAsFixed(1);
    return '${text}MB';
  }
  if (value >= 1000) {
    return '${(value / 1000).toStringAsFixed(0)}KB';
  }
  return '${value.toStringAsFixed(0)}B';
}

String formatDownloadOverlaySpeed(double bytesPerSecond) {
  if (bytesPerSecond <= 0) return '';
  if (bytesPerSecond >= 1000000) {
    return '${(bytesPerSecond / 1000000).toStringAsFixed(1)}MB/s';
  }
  if (bytesPerSecond >= 1000) {
    return '${(bytesPerSecond / 1000).toStringAsFixed(0)}KB/s';
  }
  return '${bytesPerSecond.toStringAsFixed(0)}B/s';
}

/// 1-based current episode of the batch. First of 3 → `1 of 3`, not `0 of 3`.
int overlayCurrentIndex({
  required int completedCount,
  required int batchTotal,
}) {
  final total = batchTotal < 1 ? 1 : batchTotal;
  final index = completedCount + 1;
  if (index < 1) return 1;
  if (index > total) return total;
  return index;
}

/// In-progress, waiting, or paused — not complete/canceled.
bool isActiveDownloadStatus(TaskStatus status) {
  switch (status) {
    case TaskStatus.complete:
    case TaskStatus.canceled:
      return false;
    case TaskStatus.running:
    case TaskStatus.enqueued:
    case TaskStatus.waitingToRetry:
    case TaskStatus.paused:
    case TaskStatus.failed:
    case TaskStatus.notFound:
      return true;
  }
}

int compareByDownloadQueueOrder(
  String a,
  String b,
  List<String> order, {
  int fallbackA = 0,
  int fallbackB = 0,
}) {
  final indexA = order.indexOf(a);
  final indexB = order.indexOf(b);
  if (indexA >= 0 && indexB >= 0) return indexA.compareTo(indexB);
  if (indexA >= 0) return -1;
  if (indexB >= 0) return 1;
  return fallbackA.compareTo(fallbackB);
}

int compareDownloadQueueEntries(
  DownloadQueueEntry a,
  DownloadQueueEntry b, [
  List<String>? queueOrder,
]) {
  final order = queueOrder ?? const <String>[];
  if (order.isEmpty) return a.timestamp.compareTo(b.timestamp);
  return compareByDownloadQueueOrder(
    a.taskId,
    b.taskId,
    order,
    fallbackA: a.timestamp,
    fallbackB: b.timestamp,
  );
}

List<T> sortByDownloadQueueOrder<T>(
  Iterable<T> items, {
  required String Function(T) idOf,
  required List<String> order,
  required int Function(T) fallbackTimestamp,
}) {
  final list = items.toList();
  list.sort(
    (a, b) => compareByDownloadQueueOrder(
      idOf(a),
      idOf(b),
      order,
      fallbackA: fallbackTimestamp(a),
      fallbackB: fallbackTimestamp(b),
    ),
  );
  return list;
}

List<String> appendDownloadQueueId(List<String> order, String id) {
  if (id.isEmpty || order.contains(id)) return List<String>.from(order);
  return [...order, id];
}

List<String> removeDownloadQueueIds(List<String> order, Iterable<String> ids) {
  final drop = ids.toSet();
  return order.where((id) => !drop.contains(id)).toList();
}

/// Attach / foreground must not flash **0 MB/s**. Keep the last live speed
/// until the next real progress event.
double keepLastKnownDownloadSpeed({
  required TaskStatus status,
  required double incomingSpeed,
  double? lastKnownSpeed,
}) {
  final transferring =
      status == TaskStatus.running || status == TaskStatus.waitingToRetry;
  if (!transferring) {
    return incomingSpeed < 0 ? 0 : incomingSpeed;
  }
  if (incomingSpeed > 0) return incomingSpeed;
  final last = lastKnownSpeed ?? 0;
  if (last > 0) return last;
  return incomingSpeed;
}

/// Native overlay `update` keeps the last speed when the incoming value is
/// ≤0. After ep1 completes that leaks **859KB/s** onto ep2 at **0B**.
///
/// Returns `-1` only for hitch-protection on the **same** transferring file.
/// File switches and waiting-only overlays send `0` so native resets.
double overlayNativeSpeedUpdate({
  required String currentTaskId,
  required String previousTaskId,
  required int runningCount,
  required double plannedSpeed,
}) {
  final switched =
      previousTaskId.isNotEmpty &&
      currentTaskId.isNotEmpty &&
      previousTaskId != currentTaskId;
  if (runningCount <= 0) return 0;
  if (switched) return plannedSpeed > 0 ? plannedSpeed : 0;
  return plannedSpeed > 0 ? plannedSpeed : -1;
}

/// Finish the session overlay only when nothing is running, waiting in the
/// plugin, **or** still in the native waiter payload map. An empty
/// `allRecords()` while Flutter is backgrounded must not wipe waiters.
bool downloadSessionHasRemainingWork({
  required int runningCount,
  required int waitingCount,
  int pendingWaiterPayloads = 0,
}) => runningCount > 0 || waitingCount > 0 || pendingWaiterPayloads > 0;

/// Line 1: `Downloading “الحلقة 2.mp4”`. Percent lives on the circular progress.
String formatDownloadSessionTitle({required String displayName}) {
  final name = displayName.trim();
  if (name.isEmpty) return 'Downloading';
  return 'Downloading “$name”';
}

/// Line 2: `3.2MB/6.6MB • 1 of 3`, optionally `85KB/s • 3.2MB/6.6MB • 1 of 3`.
String formatDownloadSessionSubtitle({
  required int transferredBytes,
  required int totalBytes,
  required int currentIndex,
  required int batchTotal,
  double speedBytesPerSecond = 0,
}) {
  final total = batchTotal < 1 ? 1 : batchTotal;
  final index = currentIndex < 1
      ? 1
      : (currentIndex > total ? total : currentIndex);
  final count = '$index of $total';
  final parts = <String>[];
  final speed = formatDownloadOverlaySpeed(speedBytesPerSecond);
  if (speed.isNotEmpty) parts.add(speed);
  if (totalBytes > 0) {
    parts.add(
      '${formatDownloadOverlayBytes(transferredBytes)}/'
      '${formatDownloadOverlayBytes(totalBytes)}',
    );
  }
  parts.add(count);
  return parts.join(' • ');
}

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
  String? resumeDataBase64,
  double? progress,
  int? expectedBytes,
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
    if (resumeDataBase64 != null && resumeDataBase64.isNotEmpty)
      'resumeDataBase64': resumeDataBase64,
    if (progress != null && progress > 0) 'progress': progress,
    if (expectedBytes != null && expectedBytes > 0)
      'expectedBytes': expectedBytes,
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

/// Cancel deletes the URLSession temp file and resumeData. Never cancel on
/// pause/fail/kill — only an explicit user delete may remove bytes.
bool shouldCancelNativeAfterUserPause({
  required bool userPaused,
  required bool stillInNativeQueue,
}) => false;

/// Plugin `pause()` uses `cancelByProducingResumeData`, which drops the
/// transferring task so it cannot come back as running after kill, while
/// keeping resumeData / the partial file.
bool shouldNativePauseAfterUserPause({
  required bool userPaused,
  required bool stillInNativeQueue,
}) => userPaused && stillInNativeQueue;

class DownloadQueueEntry {
  const DownloadQueueEntry({
    required this.taskId,
    required this.status,
    required this.timestamp,
    this.queueWaiting = false,
    this.userPaused = false,
  });

  final String taskId;
  final TaskStatus status;
  final bool queueWaiting;
  final bool userPaused;
  final int timestamp;
}

class DownloadQueuePlan {
  const DownloadQueuePlan({
    required this.maxConcurrent,
    required this.occupiedCount,
    required this.waitingFifoIds,
    required this.idsToPromote,
  });

  final int maxConcurrent;
  final int occupiedCount;
  final List<String> waitingFifoIds;
  final List<String> idsToPromote;

  int get freeSlots => (maxConcurrent - occupiedCount).clamp(0, maxConcurrent);
}

/// FIFO re-enqueue of leftover Dart-parked waiters only. User-paused rows
/// are out of the queue and are skipped. Native holding-queue `enqueued`
/// rows already have a live FileDownloader task — promoting them starts a
/// second transfer of the same episode. Occupying URLSession tasks are
/// never detached.
DownloadQueuePlan planDownloadQueue({
  required int maxConcurrent,
  required Iterable<DownloadQueueEntry> entries,
  List<String>? queueOrder,
}) {
  final n = clampDownloadConcurrency(maxConcurrent);
  final occupying = entries
      .where(
        (entry) =>
            !entry.userPaused &&
            occupiesDownloadSlot(
              status: entry.status,
              queueWaiting: entry.queueWaiting,
            ),
      )
      .toList();

  final waiting =
      entries
          .where(
            (entry) =>
                !entry.userPaused &&
                (entry.queueWaiting || entry.status == TaskStatus.enqueued),
          )
          .toList()
        ..sort((a, b) => compareDownloadQueueEntries(a, b, queueOrder));
  final leftoverParked =
      entries.where((entry) => entry.queueWaiting && !entry.userPaused).toList()
        ..sort((a, b) => compareDownloadQueueEntries(a, b, queueOrder));

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
    idsToPromote: idsToPromote,
  );
}

/// After a file is parked paused (failure / system cancel), the slot is
/// free. Leftover Dart-parked waiters re-enqueue; HQ `enqueued` waiters
/// are listed so the caller can attach UI — never enqueue a second copy.
List<String> idsToStartAfterParkedFailure({
  required int maxConcurrent,
  required Iterable<DownloadQueueEntry> entries,
  List<String>? queueOrder,
}) {
  final plan = planDownloadQueue(
    maxConcurrent: maxConcurrent,
    entries: entries,
    queueOrder: queueOrder,
  );
  if (plan.freeSlots <= 0) return const [];
  if (plan.idsToPromote.isNotEmpty) {
    return plan.idsToPromote.take(plan.freeSlots).toList();
  }
  return plan.waitingFifoIds.take(plan.freeSlots).toList();
}

class UserResumeQueuePlan {
  const UserResumeQueuePlan({
    required this.startNow,
    required this.occupiedCount,
    required this.waitingFifoIds,
    required this.earlierWaiterIds,
    required this.waitersToRestack,
  });

  final bool startNow;
  final int occupiedCount;
  final List<String> waitingFifoIds;
  final List<String> earlierWaiterIds;
  final List<String> waitersToRestack;
}

/// User-paused rows are out of the queue. Play puts [resumedId] back at
/// its original FIFO place. A parked failure (`paused` without `userPaused`)
/// is not a waiter.
bool isUserResumeWaiter(DownloadQueueEntry entry, {required String resumedId}) {
  if (entry.taskId == resumedId) return true;
  if (entry.userPaused) return false;
  return entry.queueWaiting || entry.status == TaskStatus.enqueued;
}

List<String> userResumeWaitingFifoIds({
  required String resumedId,
  required Iterable<DownloadQueueEntry> entries,
  List<String>? queueOrder,
}) {
  final waiters =
      entries
          .where((entry) => isUserResumeWaiter(entry, resumedId: resumedId))
          .toList()
        ..sort((a, b) => compareDownloadQueueEntries(a, b, queueOrder));
  return waiters.map((entry) => entry.taskId).toList();
}

/// Start now only when a slot is free and [resumedId] is among the next
/// unpaused FIFO waiters. An occupying transfer is never displaced.
bool shouldStartImmediatelyAfterUserResume({
  required String resumedId,
  required int occupyingCount,
  required List<String> waitingFifoIdsIncludingResumed,
  required int maxConcurrent,
}) {
  final n = clampDownloadConcurrency(maxConcurrent);
  if (resumedId.isEmpty || occupyingCount >= n) return false;
  final freeSlots = n - occupyingCount;
  return waitingFifoIdsIncludingResumed.take(freeSlots).contains(resumedId);
}

/// Later unpaused HQ / leftover waiters that must be placed behind the
/// resumed id. Occupying URLSession tasks are never restacked.
List<String> waitersToRestackAfterResume({
  required String resumedId,
  required List<String> waitingFifoIdsIncludingResumed,
  required Iterable<DownloadQueueEntry> entries,
}) {
  final index = waitingFifoIdsIncludingResumed.indexOf(resumedId);
  if (index < 0) return const [];
  final byId = {for (final entry in entries) entry.taskId: entry};
  return waitingFifoIdsIncludingResumed.skip(index + 1).where((id) {
    final entry = byId[id];
    if (entry == null || entry.userPaused) return false;
    if (occupiesDownloadSlot(
      status: entry.status,
      queueWaiting: entry.queueWaiting,
    )) {
      return false;
    }
    return entry.status == TaskStatus.enqueued || entry.queueWaiting;
  }).toList();
}

/// Play: re-enter the queue at the original tap/FIFO place. Skip other
/// user-paused rows. Do not treat failure-parked rows as waiters.
UserResumeQueuePlan planUserResumeQueue({
  required String resumedId,
  required int maxConcurrent,
  required Iterable<DownloadQueueEntry> entries,
  List<String>? queueOrder,
}) {
  final n = clampDownloadConcurrency(maxConcurrent);
  final occupiedCount = entries
      .where(
        (entry) =>
            entry.taskId != resumedId &&
            !entry.userPaused &&
            occupiesDownloadSlot(
              status: entry.status,
              queueWaiting: entry.queueWaiting,
            ),
      )
      .length;
  final waitingFifoIds = userResumeWaitingFifoIds(
    resumedId: resumedId,
    entries: entries,
    queueOrder: queueOrder,
  );
  final resumeIndex = waitingFifoIds.indexOf(resumedId);
  final earlierWaiterIds = resumeIndex <= 0
      ? const <String>[]
      : waitingFifoIds.take(resumeIndex).toList();
  final waitersToRestack = waitersToRestackAfterResume(
    resumedId: resumedId,
    waitingFifoIdsIncludingResumed: waitingFifoIds,
    entries: entries,
  );
  return UserResumeQueuePlan(
    startNow: shouldStartImmediatelyAfterUserResume(
      resumedId: resumedId,
      occupyingCount: occupiedCount,
      waitingFifoIdsIncludingResumed: waitingFifoIds,
      maxConcurrent: n,
    ),
    occupiedCount: occupiedCount,
    waitingFifoIds: waitingFifoIds,
    earlierWaiterIds: earlierWaiterIds,
    waitersToRestack: waitersToRestack,
  );
}
