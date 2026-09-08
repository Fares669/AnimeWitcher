import 'package:background_downloader/background_downloader.dart';

/// 0 = Auto. Manual connection counts are allowed up to Gopeed's default
/// ceiling, but fresh transfers still open them gradually instead of all at
/// once.
const String kDownloadPartsSettingKey = 'download_parallel_parts';
const int kDownloadPartsAuto = 0;
const int kDownloadPartsMin = 1;
const int kDownloadPartsMax = 16;
const int kDownloadGlobalConnectionBudget = 16;

/// Gopeed lets an idle connection steal half of a slow connection's remaining
/// range. Native URLSession/background_downloader children cannot safely change
/// their Range header after launch, so AnimeWitcher uses a conservative work
/// queue instead: large transfers are pre-split into at most twice as many
/// immutable work units while no more than [kDownloadPartsMax] are active.
/// Finished connections can then pick up queued tail work without touching an
/// in-flight native request.
const int kDownloadWorkUnitsMax = kDownloadPartsMax * 2;
const int kDownloadTailBalanceMinUnitBytes = 512 * 1024;

const List<int> kDownloadPartChoices = <int>[
  0,
  1,
  2,
  3,
  4,
  5,
  6,
  7,
  8,
  9,
  10,
  11,
  12,
  13,
  14,
  15,
  16,
];

/// Multipart recovery is owned by [PersistentParallelDownload], which keeps
/// the same child taskId and partial bytes while applying its own bounded
/// backoff/connection-pressure policy. Native retries must stay disabled here;
/// stacking background_downloader retries on top creates synchronized retry
/// waves where several parts stop and restart together.
const int kDownloadPartRetries = 0;

/// Gopeed expands 1, 2, 4, 8... and waits for the current batch's HTTP
/// responses before opening the next batch. This helper only describes those
/// batch sizes; [PersistentParallelDownload] owns the response-gated control.
List<int> downloadConnectionRampBatches(int parts) {
  var remaining = parts.clamp(0, kDownloadPartsMax).toInt();
  if (remaining == 0) return const <int>[];
  final batches = <int>[];
  var next = 1;
  while (remaining > 0) {
    final count = next < remaining ? next : remaining;
    batches.add(count);
    remaining -= count;
    next *= 2;
  }
  return batches;
}

int normalizeDownloadPartPreference(Object? raw) {
  final value = raw is num ? raw.toInt() : int.tryParse(raw?.toString() ?? '');
  return kDownloadPartChoices.contains(value) ? value! : kDownloadPartsAuto;
}

/// Pick the requested connection ceiling. Parallel mode is never attempted
/// unless the origin proved byte-range support and exposed a trustworthy size.
/// Auto stays size-aware so small episodes do not pay for 16 tiny requests.
int selectAdaptiveDownloadParts({
  required int preference,
  required int totalBytes,
  required bool supportsRanges,
}) {
  if (!supportsRanges || totalBytes <= 0) return 1;
  final normalized = normalizeDownloadPartPreference(preference);
  if (normalized > 0) return normalized;

  const mib = 1024 * 1024;
  if (totalBytes < 100 * mib) return 1;
  if (totalBytes < 200 * mib) return 2;
  if (totalBytes < 400 * mib) return 4;
  if (totalBytes < 800 * mib) return 8;
  return 16;
}

/// Number of immutable byte ranges kept in the tail work queue.
///
/// This never raises the active connection ceiling. It only creates spare work
/// for a connection that finishes early. Extra units are used only when they
/// remain at least 512 KiB, matching Gopeed's minimum useful stolen range. For
/// tiny files we preserve the requested connection split instead of creating
/// even smaller extra ranges.
int selectDownloadWorkUnitCount({
  required int connections,
  required int totalBytes,
}) {
  final active = connections
      .clamp(kDownloadPartsMin, kDownloadPartsMax)
      .toInt();
  if (active <= 1 || totalBytes <= 0) return active;

  final desired = (active * 2)
      .clamp(active, kDownloadWorkUnitsMax)
      .toInt();
  final sizeBound = totalBytes ~/ kDownloadTailBalanceMinUnitBytes;
  return sizeBound.clamp(active, desired).toInt();
}

const String kLogicalDownloadGroup = 'downloads';
const String kPersistentDownloadChunkGroup = 'animewitcher_parts';

bool isInternalDownloaderChunk(Task task) =>
    task.group == FileDownloader.chunkGroup ||
    task.group == kPersistentDownloadChunkGroup;

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
