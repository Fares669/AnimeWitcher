import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'local_file_io.dart';

const List<String> kDownloadTempSuffixes = [
  '.part',
  '.tmp',
  '.download',
  '.assembling',
];

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

/// Exact media roots used by V2 plus the legacy app-owned download root.
/// A general Documents/Downloads directory is never recursive-delete authority.
Future<List<String>> platformConfiguredAppDownloadRoots({
  bool includeSharedRoots = true,
}) async {
  final roots = <String>[];
  void addMediaRoots(String base) {
    roots.addAll([p.join(base, 'anime'), p.join(base, 'manga')]);
  }

  try {
    if (Platform.isAndroid) {
      const publicDownloads = '/storage/emulated/0/Download';
      if (includeSharedRoots) addMediaRoots(publicDownloads);
      roots.add(p.join(publicDownloads, 'AnimeWitcher', 'Downloads'));
      final external = await getExternalStorageDirectory();
      if (external != null) addMediaRoots(external.path);
      final documents = await getApplicationDocumentsDirectory();
      addMediaRoots(p.join(documents.path, 'Downloads'));
    } else if (Platform.isIOS) {
      final documents = await getApplicationDocumentsDirectory();
      addMediaRoots(p.join(documents.path, 'Downloads'));
      roots.add(p.join(documents.path, 'AnimeWitcher', 'Downloads'));
    } else {
      final downloads = await getDownloadsDirectory();
      if (downloads != null) {
        if (includeSharedRoots) addMediaRoots(downloads.path);
        roots.add(p.join(downloads.path, 'AnimeWitcher', 'Downloads'));
      } else {
        final documents = await getApplicationDocumentsDirectory();
        if (includeSharedRoots)
          addMediaRoots(p.join(documents.path, 'Downloads'));
        roots.add(p.join(documents.path, 'AnimeWitcher', 'Downloads'));
      }
    }
    return roots;
  } catch (_) {
    // Ownership is a safety boundary; an unresolved platform root fails closed.
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
  return platformConfiguredAppDownloadRoots();
}

Future<bool> _resolvesInsideConfiguredAppDownloads(
  Directory directory,
  List<String> roots,
) => runLocalFileIo(
  () => _resolvesInsideConfiguredAppDownloadsSync(directory, roots),
);

bool _resolvesInsideConfiguredAppDownloadsSync(
  Directory directory,
  Iterable<String> appDownloadRoots,
) {
  final lexicalRoot = _configuredAppDownloadsRootForPath(
    directory.path,
    appDownloadRoots,
  );
  if (lexicalRoot == null) {
    return false;
  }
  try {
    var current = lexicalRoot;
    for (final segment in <String>[
      '',
      ...p.split(p.relative(directory.path, from: lexicalRoot)),
    ]) {
      if (segment.isNotEmpty && segment != '.') {
        current = p.join(current, segment);
      }
      if (FileSystemEntity.typeSync(current, followLinks: false) !=
          FileSystemEntityType.directory) {
        return false;
      }
    }
    final canonicalRoot = p.normalize(
      Directory(lexicalRoot).resolveSymbolicLinksSync(),
    );
    final canonicalDirectory = p.normalize(
      directory.resolveSymbolicLinksSync(),
    );
    return _downloadPathIsWithin(canonicalRoot, canonicalDirectory);
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
  final root = _configuredAppDownloadsRootForPath(file.path, appDownloadRoots);
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

/// Prune only the deleted artifact's empty ancestors, up to its title folder.
/// Nonrecursive deletes preserve files arriving between the checks and rmdir.
Future<void> deleteSeriesFolderIfNoVideosRemain(
  File deletedFile, {
  Iterable<String>? appDownloadRoots,
  bool Function(String directoryPath)? isProtected,
}) async {
  final roots = await _effectiveAppDownloadRoots(appDownloadRoots);
  final series = seriesFolderForDownloadedFile(
    deletedFile,
    appDownloadRoots: roots,
  );
  if (series == null) {
    return;
  }
  var directory = deletedFile.parent;
  while (_downloadPathIsWithin(series.path, directory.path)) {
    try {
      final candidate = directory;
      final type = await localPathType(candidate.path);
      if (type != FileSystemEntityType.notFound) {
        if (type != FileSystemEntityType.directory ||
            !await _resolvesInsideConfiguredAppDownloads(candidate, roots) ||
            isProtected?.call(directory.path) == true) {
          return;
        }
        await localDelete(candidate);
      }
    } on FileSystemException {
      // A nonempty directory, permission error, or concurrent writer stays put.
      return;
    }
    if (_downloadPathsEqual(directory.path, series.path)) {
      return;
    }
    directory = directory.parent;
  }
}

Future<void> deleteSiblingTempFiles(
  File file, {
  Iterable<String>? appDownloadRoots,
}) async {
  final roots = await _effectiveAppDownloadRoots(appDownloadRoots);
  await runLocalFileIo(() {
    if (roots.isEmpty ||
        !pathIsInsideConfiguredAppDownloads(file.path, roots) ||
        !_resolvesInsideConfiguredAppDownloadsSync(file.parent, roots)) {
      return;
    }
    final name = p.basename(file.path);
    for (final suffix in kDownloadTempSuffixes) {
      final temp = File(p.join(file.parent.path, '$name$suffix'));
      try {
        if (temp.existsSync()) temp.deleteSync();
      } catch (_) {}
    }
  });
}

/// Retry `file.delete()` — Android public Downloads can fail once on
/// permission or a still-open handle, then succeed.
Future<bool> deleteFileWithRetry(File file, {int attempts = 3}) async {
  for (var i = 0; i < attempts; i++) {
    try {
      if (await runLocalFileIo(() {
        if (!file.existsSync()) return true;
        file.deleteSync();
        return !file.existsSync();
      })) {
        return true;
      }
    } catch (_) {}
    if (i < attempts - 1) {
      await Future<void>.delayed(Duration(milliseconds: 40 * (i + 1)));
    }
  }
  try {
    return !await runLocalFileIo(file.existsSync);
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
  bool Function(String directoryPath)? isProtected,
}) async {
  try {
    final roots = await _effectiveAppDownloadRoots(appDownloadRoots);
    if (!await runLocalFileIo(file.existsSync)) {
      await deleteSeriesFolderIfNoVideosRemain(
        file,
        appDownloadRoots: roots,
        isProtected: isProtected,
      );
      return true;
    }
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
      isProtected: isProtected,
    );
    return deleted;
  } catch (_) {
    return false;
  }
}
