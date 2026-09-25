import 'dart:convert';

import 'package:background_downloader/background_downloader.dart';

/// 0 = Auto. Manual connection counts are allowed up to Gopeed's default
/// ceiling, but fresh transfers still open them gradually instead of all at
/// once.
const String kDownloadPartsSettingKey = 'download_parallel_parts';
const int kDownloadPartsAuto = 0;
const int kDownloadPartsMin = 1;
const int kDownloadPartsMax = 16;
const int kDownloadGlobalConnectionBudget = 16;

/// Preserve the selected width. Download Manager V2 applies its own
/// package/platform safety policy at the gateway boundary instead of mutating
/// the user's stored preference.
int effectiveDownloadPartsForPlatform({
  required int selectedParts,
  required bool isIOS,
}) {
  return selectedParts.clamp(kDownloadPartsMin, kDownloadPartsMax).toInt();
}


/// Gopeed lets an idle connection steal half of a slow connection's remaining
/// range. Native URLSession/background_downloader children cannot safely change
/// their Range header after launch, so AnimeWitcher uses immutable checkpoint
/// ranges instead. Connection count stays capped at [kDownloadPartsMax].
///
/// Keep the queued recovery map deliberately bounded. The old 1 MiB / 512-unit
/// policy created hundreds of short-lived DownloadTasks for a single episode,
/// amplifying manifest serialization, package database traffic and platform
/// channel callbacks enough to contend with Flutter's UI isolate. Four MiB
/// checkpoints still bound worst-case re-fetch after a process loss while a
/// 128-unit ceiling keeps coordinator cost proportional to a small work queue.
const int kDownloadWorkUnitsMax = 128;
const int kDownloadCheckpointTargetBytes = 4 * 1024 * 1024;
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

/// Multipart children deliberately disable background_downloader's own retry
/// loop. PersistentParallelDownload owns recovery, backoff, connection pressure
/// and saved-byte resumption. Running a second native retry loop underneath it
/// makes many children enter waitingToRetry together and produces the observed
/// download -> 0 B/s -> retry-wave cycle.
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

/// Manga chapters have no file-size probe before their page URLs are resolved.
/// Auto therefore uses four page requests, while explicit settings stay exact.
int mangaChapterPageConnectionsFromPreference(int preference) {
  final normalized = normalizeDownloadPartPreference(preference);
  return normalized == kDownloadPartsAuto ? 4 : normalized;
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

/// Selects the width handed to Download Manager V2.
///
/// On iOS the V2 gateway performs its own exact byte-range probe before it
/// starts the durable ranged transport. Therefore preliminary metadata must not
/// collapse an explicit manual width (for example 16) to one connection. Auto
/// may likewise request a size-based candidate so the gateway gets a chance to
/// prove Range support. Non-iOS keeps the existing conservative preflight.
int selectV2DownloadParts({
  required int preference,
  required int totalBytes,
  required bool metadataSupportsRanges,
  required bool isIOS,
}) {
  if (!isIOS) {
    return selectAdaptiveDownloadParts(
      preference: preference,
      totalBytes: totalBytes,
      supportsRanges: metadataSupportsRanges,
    );
  }

  final normalized = normalizeDownloadPartPreference(preference);
  if (normalized > 0) {
    return normalized.clamp(kDownloadPartsMin, kDownloadPartsMax).toInt();
  }

  return selectAdaptiveDownloadParts(
    preference: kDownloadPartsAuto,
    totalBytes: totalBytes,
    // This is only a probe-worthy candidate. The iOS V2 gateway still proves
    // Range support before opening more than one native writer.
    supportsRanges: true,
  );
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
  if (totalBytes <= 0) return active;

  final tailTarget = (active * 2)
      .clamp(active, kDownloadWorkUnitsMax)
      .toInt();
  final checkpointTarget =
      ((totalBytes + kDownloadCheckpointTargetBytes - 1) ~/
              kDownloadCheckpointTargetBytes)
          .clamp(active, kDownloadWorkUnitsMax)
          .toInt();
  final desired = tailTarget > checkpointTarget
      ? tailTarget
      : checkpointTarget;

  // Never create sub-512 KiB work solely for checkpointing. Very small files
  // may still have smaller ranges when the user explicitly requests more
  // simultaneous connections than this size bound can provide.
  final sizeBound = totalBytes ~/ kDownloadTailBalanceMinUnitBytes;
  if (sizeBound < active) return active;
  return sizeBound < desired ? sizeBound : desired;
}

const String kLogicalDownloadGroup = 'downloads';
const String kPersistentDownloadChunkGroup = 'animewitcher_parts';

bool isInternalDownloaderChunk(Task task) =>
    task.group == FileDownloader.chunkGroup ||
    task.group == kPersistentDownloadChunkGroup;

/// Persistent multipart children store only their logical parent identity in
/// JSON metadata. Keep this parsing centralized so retry/source-refresh code
/// never mistakes a child for an independent logical download.
String? downloadInternalParentTaskId(Task task) {
  if (!isInternalDownloaderChunk(task)) return null;
  final raw = task.metaData.trim();
  if (raw.isEmpty) return null;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return null;
    final value = decoded['parentTaskId'];
    final parent = value is String ? value.trim() : '';
    return parent.isEmpty ? null : parent;
  } catch (_) {
    return null;
  }
}

/// True when a multipart child was rebound to a refreshed source and must
/// not consume native resumeData that can still embed the previous URL.
bool downloadInternalSourceValidationRequired(Task task) {
  if (!isInternalDownloaderChunk(task)) return false;
  final raw = task.metaData.trim();
  if (raw.isEmpty) return false;
  try {
    final decoded = jsonDecode(raw);
    return decoded is Map && decoded['sourceValidationRequired'] == true;
  } catch (_) {
    return false;
  }
}

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
