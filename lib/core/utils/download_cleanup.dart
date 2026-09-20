import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../domain/entity/multimedia_item.dart';

/// Video extensions that count as remaining episode files.
const Set<String> kDownloadVideoExtensions = {
  '.mp4',
  '.mkv',
  '.webm',
  '.avi',
};

const String kAppDownloadsRootMarker = 'AnimeWitcher/Downloads';

const List<String> kDownloadTempSuffixes = ['.part', '.tmp', '.download'];

/// Canonical episode identity: [DownloadTask.metaData], which is set to
/// `episode.url` (not `taskId`).
String downloadTrackingUrl(Task task) {
  final meta = task.metaData.trim();
  if (meta.isNotEmpty) return meta;
  return task.url.trim();
}

/// Identity for one downloaded episode (or a movie with no episode).
///
/// Canonical key is `episode.url`, which is stored on the task as
/// [Task.metaData]. `taskId` is not an identity.
String downloadIdentityKey(MultimediaItem item, Episode? episode) {
  final episodeUrl = episode?.url.trim() ?? '';
  if (episodeUrl.isNotEmpty) return episodeUrl;
  return item.url.trim();
}

/// Directory + filename as stored on the task, independent of Unicode form.
String downloadTaskFileKey(Task task) {
  final directory = task.directory.replaceAll('\\', '/').trim();
  final filename = task.filename.trim();
  if (filename.isEmpty) return '';
  return '$directory|$filename';
}

bool metadataMatchesDownload({
  required MultimediaItem item,
  Episode? episode,
  required MultimediaItem candidateItem,
  Episode? candidateEpisode,
}) {
  return downloadIdentityKey(item, episode) ==
      downloadIdentityKey(candidateItem, candidateEpisode);
}

bool taskMatchesDownloadFile({
  required Task task,
  required String filename,
  required String directory,
}) {
  if (task.filename.trim().isEmpty) return false;
  if (task.filename.trim() != filename.trim()) return false;
  final a = task.directory.replaceAll('\\', '/').trim();
  final b = directory.replaceAll('\\', '/').trim();
  if (a == b) return true;
  if (a.isEmpty || b.isEmpty) return false;
  return p.normalize(a) == p.normalize(b) || a.endsWith(b) || b.endsWith(a);
}

bool shouldCancelDownload(TaskStatus status) {
  switch (status) {
    case TaskStatus.running:
    case TaskStatus.enqueued:
    case TaskStatus.paused:
    case TaskStatus.waitingToRetry:
      return true;
    case TaskStatus.complete:
    case TaskStatus.canceled:
    case TaskStatus.failed:
    case TaskStatus.notFound:
      return false;
  }
}

enum CompleteDownloadAction { reuse, dropAndEnqueue, enqueue }

/// How a download start should treat an existing complete record.
CompleteDownloadAction decideCompleteDownloadAction({
  required bool hasCompleteRecord,
  required bool fileExists,
}) {
  if (!hasCompleteRecord) return CompleteDownloadAction.enqueue;
  if (fileExists) return CompleteDownloadAction.reuse;
  return CompleteDownloadAction.dropAndEnqueue;
}

/// Prefer the task's own path; fall back to label reconstruction.
///
/// Order: existing task file, then [File] from `task.filePath()` when that
/// path exists (or `exists()` throws), then reconstructed labels, then the
/// path [File] even if `exists()` was false so delete can still retry.
Future<File?> resolveDownloadFileToDelete({
  required Future<File?> Function() fromTask,
  required Future<String?> Function() taskFilePath,
  required Future<File?> Function() fromLabels,
}) async {
  final taskFile = await fromTask();
  if (taskFile != null) return taskFile;
  final path = await taskFilePath();
  File? pathFile;
  if (path != null && path.isNotEmpty) {
    pathFile = File(path);
    try {
      if (await pathFile.exists()) return pathFile;
    } catch (_) {
      return pathFile;
    }
  }
  final labels = await fromLabels();
  if (labels != null) return labels;
  return pathFile;
}

bool _downloadPathSegmentEquals(String a, String b) =>
    Platform.isWindows ? a.toLowerCase() == b.toLowerCase() : a == b;

String _normalizedAbsoluteDownloadPath(String value) =>
    p.normalize(p.absolute(value));

String _downloadPathComparisonKey(String value) {
  final normalized = _normalizedAbsoluteDownloadPath(value);
  return Platform.isWindows ? normalized.toLowerCase() : normalized;
}

bool _downloadPathsEqual(String a, String b) =>
    _downloadPathComparisonKey(a) == _downloadPathComparisonKey(b);

bool _downloadPathIsWithin(String root, String candidate) {
  final normalizedRoot = _downloadPathComparisonKey(root);
  final normalizedCandidate = _downloadPathComparisonKey(candidate);
  return normalizedCandidate == normalizedRoot ||
      p.isWithin(normalizedRoot, normalizedCandidate);
}

String? _appDownloadsRootForPath(String value) {
  final normalized = _normalizedAbsoluteDownloadPath(value);
  final segments = p.split(normalized);
  for (var i = 0; i + 1 < segments.length; i++) {
    if (_downloadPathSegmentEquals(segments[i], 'AnimeWitcher') &&
        _downloadPathSegmentEquals(segments[i + 1], 'Downloads')) {
      return p.normalize(p.joinAll(segments.take(i + 2)));
    }
  }
  return null;
}

/// Lexical marker check retained for non-destructive compatibility.
///
/// Never use this as proof of filesystem ownership: any external directory can
/// be named `AnimeWitcher/Downloads`. Destructive cleanup must use the
/// configured-root helpers below.
bool pathIsInsideAppDownloads(String path) {
  final normalized = _normalizedAbsoluteDownloadPath(path);
  final root = _appDownloadsRootForPath(normalized);
  if (root == null) return false;
  return normalized == root || p.isWithin(root, normalized);
}

bool pathIsAppDownloadsRoot(String path) {
  final normalized = _normalizedAbsoluteDownloadPath(path);
  final root = _appDownloadsRootForPath(normalized);
  return root != null && normalized == root;
}

bool pathIsInsideConfiguredAppDownloads(
  String path,
  Iterable<String> appDownloadRoots,
) {
  for (final root in appDownloadRoots) {
    if (root.trim().isEmpty) continue;
    if (_downloadPathIsWithin(root, path)) return true;
  }
  return false;
}

String? _configuredAppDownloadsRootForPath(
  String path,
  Iterable<String> appDownloadRoots,
) {
  for (final root in appDownloadRoots) {
    if (root.trim().isEmpty) continue;
    if (_downloadPathIsWithin(root, path)) {
      return _normalizedAbsoluteDownloadPath(root);
    }
  }
  return null;
}

Future<List<String>> _platformConfiguredAppDownloadRoots() async {
  try {
    late final String basePath;
    if (Platform.isAndroid) {
      basePath = '/storage/emulated/0/Download';
    } else if (Platform.isIOS) {
      basePath = (await getApplicationDocumentsDirectory()).path;
    } else {
      basePath =
          (await getDownloadsDirectory() ??
                  await getApplicationDocumentsDirectory())
              .path;
    }
    return <String>[p.join(basePath, 'AnimeWitcher', 'Downloads')];
  } catch (_) {
    // Filesystem ownership is a safety boundary. If the platform root cannot
    // be established, recursive/sibling cleanup must fail closed.
    return const <String>[];
  }
}

Future<List<String>> _effectiveAppDownloadRoots(
  Iterable<String>? appDownloadRoots,
) async {
  if (appDownloadRoots != null) {
    return appDownloadRoots
        .where((root) => root.trim().isNotEmpty)
        .map(_normalizedAbsoluteDownloadPath)
        .toList(growable: false);
  }
  return _platformConfiguredAppDownloadRoots();
}

Future<bool> _resolvesInsideConfiguredAppDownloads(
  Directory directory,
  Iterable<String> appDownloadRoots,
) async {
  final lexicalRoot = _configuredAppDownloadsRootForPath(
    directory.path,
    appDownloadRoots,
  );
  if (lexicalRoot == null) return false;
  try {
    final canonicalRoot = p.normalize(
      await Directory(lexicalRoot).resolveSymbolicLinks(),
    );
    final canonicalDirectory = p.normalize(
      await directory.resolveSymbolicLinks(),
    );
    return _downloadPathsEqual(canonicalDirectory, canonicalRoot) ||
        _downloadPathIsWithin(canonicalRoot, canonicalDirectory);
  } catch (_) {
    return false;
  }
}

/// The `<title>` directory directly under a configured
/// `AnimeWitcher/Downloads` root, or null when [file] is outside those roots.
Directory? seriesFolderForDownloadedFile(
  File file, {
  Iterable<String> appDownloadRoots = const <String>[],
}) {
  final root = _configuredAppDownloadsRootForPath(
    file.path,
    appDownloadRoots,
  );
  if (root == null) return null;

  var dir = file.parent;
  while (true) {
    if (_downloadPathsEqual(dir.path, root)) return null;
    if (!_downloadPathIsWithin(root, dir.path)) return null;
    if (_downloadPathsEqual(dir.parent.path, root)) return dir;
    if (dir.parent.path == dir.path) return null;
    dir = dir.parent;
  }
}

bool isDownloadVideoFileName(String name) {
  final lower = name.toLowerCase();
  if (lower.startsWith('.')) return false;
  return kDownloadVideoExtensions.any(lower.endsWith);
}

Future<bool> directoryContainsVideoFiles(Directory directory) async {
  if (!await directory.exists()) return false;
  await for (final entity in directory.list(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is! File) continue;
    if (!isDownloadVideoFileName(p.basename(entity.path))) continue;
    try {
      if (await entity.length() > 0) return true;
    } catch (_) {
      continue;
    }
  }
  return false;
}

Future<void> _deleteEmptyAncestorsUpTo(
  Directory start,
  Directory stopAt,
) async {
  var dir = start;
  final stop = _normalizedAbsoluteDownloadPath(stopAt.path);
  while (true) {
    final current = _normalizedAbsoluteDownloadPath(dir.path);
    if (_downloadPathsEqual(current, stop)) return;
    if (!_downloadPathIsWithin(stop, current)) return;
    if (!await dir.exists()) {
      dir = dir.parent;
      continue;
    }
    final children = await dir.list(followLinks: false).toList();
    if (children.isNotEmpty) return;
    await dir.delete();
    if (dir.parent.path == dir.path) return;
    dir = dir.parent;
  }
}

/// A recursive series-directory delete is safe only when no file evidence is
/// left at all. A `.part`, `.assembling`, manifest, or other recognized name is
/// not proof that the artifact is obsolete; it may be the only durable recovery
/// evidence after process death. Proven obsolete artifacts are deleted by their
/// owning lifecycle/reconciliation path, not by this filename-only cleanup.
Future<bool> _directoryContainsOnlyEmptyDirectories(Directory directory) async {
  if (!await directory.exists()) return true;
  await for (final entity in directory.list(followLinks: false)) {
    if (entity is Link || entity is File) return false;
    if (entity is Directory &&
        !await _directoryContainsOnlyEmptyDirectories(entity)) {
      return false;
    }
  }
  return true;
}

/// After a video is gone: remove the series folder only when no videos and no
/// durable recovery/user evidence remain.
///
/// Temp/resume artifacts are deliberately preserved unless their owning
/// lifecycle has already proved them obsolete. Never deletes outside a
/// configured app Downloads root.
Future<void> deleteSeriesFolderIfNoVideosRemain(
  File deletedFile, {
  Iterable<String>? appDownloadRoots,
}) async {
  final roots = await _effectiveAppDownloadRoots(appDownloadRoots);
  if (roots.isEmpty) return;

  final seriesDir = seriesFolderForDownloadedFile(
    deletedFile,
    appDownloadRoots: roots,
  );
  if (seriesDir == null) return;
  if (!await seriesDir.exists()) return;
  if (!await _resolvesInsideConfiguredAppDownloads(seriesDir, roots)) return;

  if (await directoryContainsVideoFiles(seriesDir)) {
    await _deleteEmptyAncestorsUpTo(deletedFile.parent, seriesDir);
    return;
  }

  if (!await _directoryContainsOnlyEmptyDirectories(seriesDir)) {
    await _deleteEmptyAncestorsUpTo(deletedFile.parent, seriesDir);
    return;
  }
  await seriesDir.delete(recursive: true);
}

Future<void> deleteSiblingTempFiles(
  File file, {
  Iterable<String>? appDownloadRoots,
}) async {
  final roots = await _effectiveAppDownloadRoots(appDownloadRoots);
  if (roots.isEmpty ||
      !pathIsInsideConfiguredAppDownloads(file.path, roots) ||
      !await _resolvesInsideConfiguredAppDownloads(file.parent, roots)) {
    return;
  }

  final dir = file.parent;
  final name = p.basename(file.path);
  for (final suffix in kDownloadTempSuffixes) {
    final temp = File(p.join(dir.path, '$name$suffix'));
    try {
      if (await temp.exists()) await temp.delete();
    } catch (_) {}
  }
}

/// Retry `file.delete()` — Android public Downloads can fail once on
/// permission or a still-open handle, then succeed.
Future<bool> deleteFileWithRetry(File file, {int attempts = 3}) async {
  for (var i = 0; i < attempts; i++) {
    try {
      if (!await file.exists()) return true;
      await file.delete();
      if (!await file.exists()) return true;
    } catch (_) {}
    if (i < attempts - 1) {
      await Future<void>.delayed(Duration(milliseconds: 40 * (i + 1)));
    }
  }
  try {
    return !await file.exists();
  } catch (_) {
    return false;
  }
}

/// Delete [file] and its app-owned sibling temps, then remove an empty series
/// directory. Existing files outside the configured app roots are never
/// deleted even if their path happens to contain `AnimeWitcher/Downloads`.
Future<bool> deleteDownloadedVideo(
  File file, {
  Iterable<String>? appDownloadRoots,
}) async {
  try {
    final roots = await _effectiveAppDownloadRoots(appDownloadRoots);
    if (!await file.exists()) return true;
    if (roots.isEmpty ||
        !pathIsInsideConfiguredAppDownloads(file.path, roots) ||
        !await _resolvesInsideConfiguredAppDownloads(file.parent, roots)) {
      return false;
    }

    await deleteSiblingTempFiles(file, appDownloadRoots: roots);
    final deleted = await deleteFileWithRetry(file);
    await deleteSeriesFolderIfNoVideosRemain(
      file,
      appDownloadRoots: roots,
    );
    return deleted;
  } catch (_) {
    return false;
  }
}
