import 'dart:io';
import 'dart:isolate';

/// Synchronous filesystem work on a worker avoids Dart's DNS-shared I/O pool.
/// Keep application state checks outside the worker and capture only its data.
Future<T> runLocalFileIo<T>(T Function() operation) => Isolate.run(operation);

Future<FileSystemEntityType> localPathType(String path) =>
    runLocalFileIo(() => FileSystemEntity.typeSync(path, followLinks: false));

Future<String?> localCanonicalDirectory(String path) => runLocalFileIo(
  () =>
      FileSystemEntity.typeSync(path, followLinks: false) ==
          FileSystemEntityType.directory
      ? Directory(path).resolveSymbolicLinksSync()
      : null,
);

Future<List<FileSystemEntity>> localDirectoryEntries(
  String path, {
  bool recursive = false,
}) => runLocalFileIo(
  () => Directory(path).listSync(recursive: recursive, followLinks: false),
);

Future<void> localDelete(FileSystemEntity entity, {bool recursive = false}) =>
    runLocalFileIo(() => entity.deleteSync(recursive: recursive));

Future<bool> localDeleteFileIfPresent(File file) => runLocalFileIo(() {
  if (!file.existsSync()) return false;
  file.deleteSync();
  return true;
});

Future<String> localReadString(File file) =>
    runLocalFileIo(file.readAsStringSync);

Future<FileStat> localStat(FileSystemEntity entity) =>
    runLocalFileIo(entity.statSync);
