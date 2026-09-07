import 'package:background_downloader/background_downloader.dart';

/// 0 = Auto. Manual choices intentionally stay conservative on mobile.
const String kDownloadPartsSettingKey = 'download_parallel_parts';
const int kDownloadPartsAuto = 0;
const int kDownloadPartsMin = 1;
const int kDownloadPartsMax = 4;
const List<int> kDownloadPartChoices = <int>[0, 1, 2, 3, 4];

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
  if (totalBytes < 100 * mib) return 1;
  if (totalBytes < 200 * mib) return 2;
  if (totalBytes < 300 * mib) return 3;
  return 4;
}

const kPersistentDownloadChunkGroup = 'animewitcher_parts';

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
