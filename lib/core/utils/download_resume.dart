import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:path/path.dart' as p;

import '../services/download_concurrency.dart';
import '../services/download_job_state.dart';
import 'download_cleanup.dart';

/// How an interrupted download should be continued.
enum DownloadResumeStrategy {
  /// OS/plugin resume data is present — continue the same native task.
  nativeResume,

  /// A leftover dest/temp file has bytes that should be appended to.
  partialFile,

  /// Nothing to keep; start the transfer from byte 0.
  restartFromZero,
}

/// Recovery action to use when a resumable task may need a refreshed source.
///
/// Native resume data can embed the old signed URL and is opaque to Dart. A
/// source replacement must therefore never silently discard opaque bytes. Only
/// a same-source native resume, a visible prefix, or multipart-owned child bytes
/// can be migrated automatically. Otherwise the caller must surface an explicit
/// restart-required outcome.
enum DownloadSourceRefreshResumeAction {
  nativeResume,
  visiblePrefix,
  multipartRefresh,
  restartFromZero,
  restartRequired,
}

DownloadSourceRefreshResumeAction planDownloadSourceRefreshResume({
  required bool sourceRefreshRequired,
  required bool canNativeResumeCurrentSource,
  required bool hasOpaqueNativeResume,
  required int visiblePartialBytes,
  required bool isMultipart,
}) {
  if (!sourceRefreshRequired && canNativeResumeCurrentSource) {
    return DownloadSourceRefreshResumeAction.nativeResume;
  }
  if (isMultipart) {
    return DownloadSourceRefreshResumeAction.multipartRefresh;
  }
  if (visiblePartialBytes > 0) {
    return DownloadSourceRefreshResumeAction.visiblePrefix;
  }
  if (hasOpaqueNativeResume) {
    return DownloadSourceRefreshResumeAction.restartRequired;
  }
  return DownloadSourceRefreshResumeAction.restartFromZero;
}

/// Native status checkpoints can report -1/0 when the response size is not
/// available. Those sentinels must not erase a previously known file length.
int knownDownloadSize(Iterable<int?> candidates) {
  for (final bytes in candidates) {
    if (bytes != null && bytes > 0) return bytes;
  }
  return -1;
}

/// True when [existingPartialBytes] is a usable prefix of the download.
bool shouldResumeFromPartialBytes({
  required int existingPartialBytes,
  required int expectedBytes,
}) {
  if (existingPartialBytes <= 0) return false;
  if (expectedBytes > 0 && existingPartialBytes >= expectedBytes) {
    return false;
  }
  return true;
}

/// Prefer native resume data, then durable leftover bytes. Historical UI
/// progress never substitutes for recoverable bytes and cannot block restart.
DownloadResumeStrategy chooseDownloadResumeStrategy({
  required bool canNativeResume,
  required int existingPartialBytes,
  required int expectedBytes,
  double savedProgress = 0,
}) {
  if (canNativeResume) return DownloadResumeStrategy.nativeResume;
  // An exact-size durable file is already a completion candidate. It must
  // stay on the local recovery path instead of being classified as a
  // zero-byte restart merely because no progress percentage survived.
  if (existingPartialBytes > 0 &&
      expectedBytes > 0 &&
      existingPartialBytes == expectedBytes) {
    return DownloadResumeStrategy.partialFile;
  }
  if (shouldResumeFromPartialBytes(
    existingPartialBytes: existingPartialBytes,
    expectedBytes: expectedBytes,
  )) {
    return DownloadResumeStrategy.partialFile;
  }
  // Historical UI progress is not recoverable-byte evidence. If native resume
  // data and durable local bytes are both absent, a clean restart is safe.
  return DownloadResumeStrategy.restartFromZero;
}

/// Fresh GET from byte 0 is allowed only when nothing has been saved.
/// Pause, fail, kill, and unpause must never take this path.
bool shouldRestartDownloadFromZero({
  required int existingPartialBytes,
  required int expectedBytes,
  double savedProgress = 0,
}) {
  // Exact-size files may be completed downloads whose last callback was lost.
  // Oversized files also contain saved data and must never be overwritten.
  if (existingPartialBytes > 0) return false;
  // savedProgress is presentation history only and deliberately does not fence
  // a zero-byte restart. Durable bytes/native ownership are checked elsewhere.
  return true;
}

/// Progress is monotonic. Late native callbacks after pause/reconnect can report
/// an older percentage; accepting that regression can make restart recovery
/// think fewer bytes exist than are actually durable on disk.
double keepLastKnownDownloadProgress({
  required double incoming,
  double? lastKnown,
}) {
  final last = (lastKnown ?? 0).clamp(0.0, 1.0).toDouble();
  if (incoming > 0 && incoming <= 1) {
    return incoming > last ? incoming : last;
  }
  if (incoming <= 0) return last;
  return last;
}

/// Continue a download that was killed mid-transfer. User-paused rows stay
/// paused, and tasks still owned by the native queue are left alone.
bool shouldAutoResumeInterruptedDownload({
  required bool wasRunningOrFailed,
  required bool userPaused,
  required bool stillInNativeQueue,
  bool queueWaiting = false,
}) {
  if (stillInNativeQueue || userPaused || queueWaiting) return false;
  return wasRunningOrFailed;
}

/// Decide which persisted rows must be restored to AnimeWitcher's logical
/// waiting queue after process death.
///
/// The decision now goes through [planDownloadRecovery], which establishes one
/// precedence order for user pause, native ownership, logical queue state and
/// stale persisted status. This keeps startup recovery deterministic while the
/// rest of DownloadService is migrated onto the same logical state machine.
bool shouldRequeueInterruptedDownloadAfterRelaunch({
  required TaskStatus persisted,
  required bool queueWaiting,
  required bool userPaused,
  required bool stillInNativeQueue,
  required bool hasMetadata,
}) {
  return planDownloadRecovery(
    persisted: persisted,
    queueWaiting: queueWaiting,
    userPaused: userPaused,
    stillInNativeQueue: stillInNativeQueue,
    hasMetadata: hasMetadata,
  ).shouldRequeue;
}

/// HTTP headers that continue a download from [existingBytes].
Map<String, String> rangeResumeHeaders({
  required Map<String, String> existing,
  required int existingBytes,
}) {
  final headers = <String, String>{};
  for (final entry in existing.entries) {
    if (entry.key.toLowerCase() == 'range') continue;
    headers[entry.key] = entry.value;
  }
  headers['Range'] = 'bytes=$existingBytes-';
  return headers;
}

/// The dest file or a sibling `.part` / `.tmp` / `.download` with the most bytes.
Future<File?> findPartialDownloadFile({
  required String destinationPath,
  List<String> tempSuffixes = kDownloadTempSuffixes,
}) async {
  File? best;
  var bestBytes = 0;

  Future<void> consider(File file) async {
    try {
      if (!await file.exists()) return;
      final bytes = await file.length();
      if (bytes <= bestBytes) return;
      best = file;
      bestBytes = bytes;
    } catch (_) {}
  }

  final dest = File(destinationPath);
  await consider(dest);
  final dir = dest.parent;
  final name = p.basename(destinationPath);
  for (final suffix in tempSuffixes) {
    await consider(File(p.join(dir.path, '$name$suffix')));
  }
  return best;
}

/// Put the largest durable prefix at the canonical destination before a Range
/// append.
///
/// Native downloaders often leave the best prefix in a sibling `.tmp` or
/// `.download` file. Copying that file first temporarily requires roughly twice
/// the partial size and can fail on a nearly-full device. Because the candidate
/// is a sibling on the same filesystem, prefer a rename after removing only the
/// smaller canonical prefix. If rename is unavailable (for example because a
/// platform still has the source handle open), fall back to copy while keeping
/// the source intact as crash-recovery evidence.
///
/// Crash safety: if the process dies after the smaller destination is removed
/// but before rename/copy finishes, the larger suffix file is still present and
/// [findPartialDownloadFile] will select it again on the next launch.
Future<({File file, int bytes})?> canonicalizePartialDownloadFile({
  required String destinationPath,
}) async {
  final partial = await findPartialDownloadFile(
    destinationPath: destinationPath,
  );
  if (partial == null) return null;

  final bytes = await partial.length();
  final destination = File(destinationPath);
  if (partial.path == destination.path) {
    return (file: destination, bytes: bytes);
  }

  await destination.parent.create(recursive: true);

  // The selected suffix is strictly larger than destination (ties keep the
  // destination because it is considered first). Removing that smaller copy
  // cannot discard the best durable prefix: [partial] remains untouched until
  // rename succeeds.
  try {
    if (await destination.exists()) {
      await destination.delete();
    }
  } catch (_) {
    // A locked destination may still be replaceable by File.copy below.
  }

  try {
    final moved = await partial.rename(destination.path);
    final movedBytes = await moved.length();
    if (movedBytes != bytes) {
      throw FileSystemException(
        'Partial rename changed file length',
        destination.path,
      );
    }
    return (file: moved, bytes: bytes);
  } catch (_) {
    // If rename completed but a follow-up stat failed, prefer the canonical
    // file when it contains the exact prefix rather than copying again.
    try {
      if (await destination.exists() && await destination.length() == bytes) {
        return (file: destination, bytes: bytes);
      }
    } catch (_) {}

    // Rename failed before moving the source. Copy is the compatibility path;
    // leave [partial] in place so a disk-full/interrupted copy never destroys
    // the only good prefix.
    if (!await partial.exists()) return null;
    try {
      final copied = await partial.copy(destination.path);
      if (await copied.length() != bytes) return null;
      return (file: copied, bytes: bytes);
    } catch (_) {
      return null;
    }
  }
}

/// Appends [chunks] onto [dest] without rewriting the existing prefix.
Future<int> appendDownloadChunks({
  required File dest,
  required Stream<List<int>> chunks,
  required int existingBytes,
  void Function(int written)? onBytes,
}) async {
  await dest.parent.create(recursive: true);
  final raf = await dest.open(mode: FileMode.append);
  var written = existingBytes;
  try {
    await for (final chunk in chunks) {
      await raf.writeFrom(chunk);
      written += chunk.length;
      onBytes?.call(written);
    }
  } finally {
    await raf.close();
  }
  return written;
}

/// Resumes a paused/failed/killed download. Native resume data and durable
/// local bytes are recovery evidence; saved progress remains presentation only.
Future<bool> resumeOrRestartDownload({
  required Future<bool> Function() canResume,
  required Future<bool> Function() resume,
  Future<bool> Function()? resumeFromPartial,
  required Future<bool> Function() restart,
  double savedProgress = 0,
  int existingPartialBytes = 0,
  int expectedBytes = -1,
}) async {
  try {
    if (await canResume() && await resume()) {
      return true;
    }
  } catch (_) {
    // A stale task can throw while its resume metadata is being inspected.
  }

  if (resumeFromPartial != null) {
    try {
      if (await resumeFromPartial()) {
        return true;
      }
    } catch (_) {
      // Leftover bytes can be unreadable or the host can reject Range.
    }
  }

  if (!shouldRestartDownloadFromZero(
    existingPartialBytes: existingPartialBytes,
    expectedBytes: expectedBytes,
    savedProgress: savedProgress,
  )) {
    return false;
  }

  try {
    return await restart();
  } catch (_) {
    return false;
  }
}
