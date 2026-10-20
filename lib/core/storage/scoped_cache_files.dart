import 'dart:io';

/// Only explicit cache files and app-owned directories, never the OS temp root.
/// In particular Windows exposes a shared temp directory containing other apps.
class ScopedCacheFiles {
  ScopedCacheFiles({
    required this.trackedFiles,
    required this.trackedDirectories,
    required this.ownedDirectories,
  });

  final List<File> trackedFiles;
  final List<Directory> trackedDirectories;
  final List<Directory> ownedDirectories;

  Future<List<File>> _files() async {
    final files = <String, File>{};
    for (final directory in [...trackedDirectories, ...ownedDirectories]) {
      if (await FileSystemEntity.type(directory.path, followLinks: false) ==
          FileSystemEntityType.link) {
        throw FileSystemException(
          'Refusing symbolic-link cache directory',
          directory.path,
        );
      }
    }
    final parents = trackedDirectories.map((dir) => dir.absolute.path).toSet();
    for (final file in trackedFiles) {
      if (!parents.contains(file.parent.absolute.path)) {
        throw FileSystemException(
          'Cache file is outside its managed directory',
          file.path,
        );
      }
      if (await FileSystemEntity.type(file.path, followLinks: false) ==
          FileSystemEntityType.link) {
        throw FileSystemException(
          'Refusing symbolic-link cache file',
          file.path,
        );
      }
      if (await FileSystemEntity.type(file.path, followLinks: false) ==
          FileSystemEntityType.file) {
        try {
          if (await file.resolveSymbolicLinks() != file.absolute.path) {
            throw FileSystemException(
              'Cache file resolves outside its managed path',
              file.path,
            );
          }
          files[file.absolute.path] = file;
        } on PathNotFoundException {
          // Normal expiry may remove a file after the type check.
        }
      }
    }
    for (final directory in ownedDirectories) {
      if (await FileSystemEntity.type(directory.path, followLinks: false) !=
          FileSystemEntityType.directory) {
        continue;
      }
      await for (final entity in directory.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File) files[entity.absolute.path] = entity;
      }
    }
    return files.values.toList();
  }

  Future<int> bytes() async {
    var total = 0;
    for (final file in await _files()) {
      try {
        total += await file.length();
      } on PathNotFoundException {
        // Cache expiry may remove a file while measuring.
      }
    }
    return total;
  }

  Future<void> clear() async {
    Object? failure;
    for (final file in await _files()) {
      try {
        await file.delete();
      } on PathNotFoundException {
        // Already removed by cache expiry or another clear.
      } on FileSystemException catch (error) {
        failure ??= error;
      }
    }
    // Keep directories and all links intact. Report partial failure, not success.
    if (failure != null) throw failure;
  }
}
