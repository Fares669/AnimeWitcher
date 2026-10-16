import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Runs Hive's disk operations synchronously inside its persistence worker.
///
/// Call only from the dedicated worker isolate, never the UI isolate. Keeping
/// Hive's Future API while using sync disk calls avoids Dart's shared async IO
/// pool, which can otherwise be occupied by offline DNS requests. Overrides are
/// zone-local and remain active across awaits. Unsupported operations fail
/// instead of silently escaping to the shared pool.
T runDownloadPersistenceIo<T>(T Function() body) {
  final io = _PersistenceIo(Zone.current);
  return IOOverrides.runZoned(
    body,
    createFile: (path) => io.file(io.run(() => File(path))),
    createDirectory: (path) => io.directory(io.run(() => Directory(path))),
    getCurrentDirectory: () => io.directory(io.run(() => Directory.current)),
    getSystemTempDirectory: () =>
        io.directory(io.run(() => Directory.systemTemp)),
    stat: (path) async => io.run(() => FileStat.statSync(path)),
    statSync: (path) => io.run(() => FileStat.statSync(path)),
    fseGetType: (path, followLinks) async =>
        io.run(() => FileSystemEntity.typeSync(path, followLinks: followLinks)),
    fseGetTypeSync: (path, followLinks) =>
        io.run(() => FileSystemEntity.typeSync(path, followLinks: followLinks)),
    fseIdentical: (first, second) async =>
        io.run(() => FileSystemEntity.identicalSync(first, second)),
    fseIdenticalSync: (first, second) =>
        io.run(() => FileSystemEntity.identicalSync(first, second)),
    createLink: (_) =>
        throw UnsupportedError('Persistence IO does not use links'),
    fsWatch: (_, _, _) =>
        throw UnsupportedError('Persistence IO does not watch files'),
  );
}

class _PersistenceIo {
  _PersistenceIo(this.parent);
  final Zone parent;

  // Native methods such as absolute/create/rename can call File/Directory
  // factories themselves. Run them in the captured parent zone to avoid
  // recursively intercepting them, then wrap returned entities again.
  T run<T>(T Function() body) => parent.run(body);
  File file(File raw) => _PersistenceFile(raw, this);
  Directory directory(Directory raw) => _PersistenceDirectory(raw, this);
  FileSystemEntity entity(FileSystemEntity raw) => switch (raw) {
    File() => file(raw),
    Directory() => directory(raw),
    Link() => _PersistenceListedLink(raw, this),
    _ => throw UnsupportedError('Unsupported persistence entity: $raw'),
  };
}

abstract class _PersistenceEntity<E extends FileSystemEntity>
    implements FileSystemEntity {
  _PersistenceEntity(this.raw, this.io);
  final E raw;
  final _PersistenceIo io;

  @override
  String get path => raw.path;
  @override
  Uri get uri => raw.uri;
  @override
  Directory get parent => io.directory(io.run(() => raw.parent));
  @override
  Future<bool> exists() async => existsSync();
  @override
  bool existsSync() => io.run(raw.existsSync);
  @override
  Future<FileStat> stat() async => statSync();
  @override
  FileStat statSync() => io.run(raw.statSync);
  @override
  Future<String> resolveSymbolicLinks() async => resolveSymbolicLinksSync();
  @override
  String resolveSymbolicLinksSync() => io.run(raw.resolveSymbolicLinksSync);
  @override
  Future<FileSystemEntity> delete({bool recursive = false}) async {
    deleteSync(recursive: recursive);
    return this;
  }

  @override
  void deleteSync({bool recursive = false}) =>
      io.run(() => raw.deleteSync(recursive: recursive));

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'Unsupported persistence IO operation: ${invocation.memberName}',
  );
}

class _PersistenceFile extends _PersistenceEntity<File> implements File {
  _PersistenceFile(super.raw, super.io);

  @override
  File get absolute => io.file(io.run(() => raw.absolute));
  @override
  Future<File> create({bool recursive = false, bool exclusive = false}) async {
    createSync(recursive: recursive, exclusive: exclusive);
    return this;
  }

  @override
  void createSync({bool recursive = false, bool exclusive = false}) =>
      io.run(() => raw.createSync(recursive: recursive, exclusive: exclusive));
  @override
  Future<File> rename(String newPath) async => renameSync(newPath);
  @override
  File renameSync(String newPath) =>
      io.file(io.run(() => raw.renameSync(newPath)));
  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) async =>
      openSync(mode: mode);
  @override
  RandomAccessFile openSync({FileMode mode = FileMode.read}) =>
      _PersistenceRandomAccessFile(io.run(() => raw.openSync(mode: mode)));
  @override
  Future<Uint8List> readAsBytes() async => readAsBytesSync();
  @override
  Uint8List readAsBytesSync() => io.run(raw.readAsBytesSync);
  @override
  String readAsStringSync({Encoding encoding = utf8}) =>
      io.run(() => raw.readAsStringSync(encoding: encoding));
  @override
  void writeAsBytesSync(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) => io.run(() => raw.writeAsBytesSync(bytes, mode: mode, flush: flush));
}

class _PersistenceDirectory extends _PersistenceEntity<Directory>
    implements Directory {
  _PersistenceDirectory(super.raw, super.io);

  @override
  Directory get absolute => io.directory(io.run(() => raw.absolute));
  @override
  Future<Directory> create({bool recursive = false}) async {
    createSync(recursive: recursive);
    return this;
  }

  @override
  void createSync({bool recursive = false}) =>
      io.run(() => raw.createSync(recursive: recursive));
  @override
  Future<Directory> rename(String newPath) async => renameSync(newPath);
  @override
  Directory renameSync(String newPath) =>
      io.directory(io.run(() => raw.renameSync(newPath)));
  @override
  Stream<FileSystemEntity> list({
    bool recursive = false,
    bool followLinks = true,
  }) async* {
    yield* Stream.fromIterable(
      listSync(recursive: recursive, followLinks: followLinks),
    );
  }

  @override
  List<FileSystemEntity> listSync({
    bool recursive = false,
    bool followLinks = true,
  }) => io
      .run(() => raw.listSync(recursive: recursive, followLinks: followLinks))
      .map(io.entity)
      .toList();
}

// Unfollowed links can occur beside legacy JSON files. Preserve their type so
// callers can skip them without traversing or modifying the linked target.
class _PersistenceListedLink implements Link {
  _PersistenceListedLink(this.raw, this.io);
  final Link raw;
  final _PersistenceIo io;

  @override
  String get path => raw.path;
  @override
  Uri get uri => raw.uri;
  @override
  Directory get parent => io.directory(io.run(() => raw.parent));
  @override
  Link get absolute => _PersistenceListedLink(io.run(() => raw.absolute), io);
  @override
  bool existsSync() => io.run(raw.existsSync);
  @override
  FileStat statSync() => io.run(raw.statSync);
  @override
  String targetSync() => io.run(raw.targetSync);
  @override
  String resolveSymbolicLinksSync() => io.run(raw.resolveSymbolicLinksSync);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'Unsupported persistence link operation: ${invocation.memberName}',
  );
}

class _PersistenceRandomAccessFile implements RandomAccessFile {
  _PersistenceRandomAccessFile(this.raw);
  final RandomAccessFile raw;

  @override
  String get path => raw.path;
  @override
  Future<void> close() async => closeSync();
  @override
  void closeSync() => raw.closeSync();
  @override
  Future<Uint8List> read(int count) async => readSync(count);
  @override
  Uint8List readSync(int count) => raw.readSync(count);
  @override
  Future<int> readInto(List<int> buffer, [int start = 0, int? end]) async =>
      readIntoSync(buffer, start, end);
  @override
  int readIntoSync(List<int> buffer, [int start = 0, int? end]) =>
      raw.readIntoSync(buffer, start, end);
  @override
  Future<RandomAccessFile> writeFrom(
    List<int> buffer, [
    int start = 0,
    int? end,
  ]) async {
    writeFromSync(buffer, start, end);
    return this;
  }

  @override
  void writeFromSync(List<int> buffer, [int start = 0, int? end]) =>
      raw.writeFromSync(buffer, start, end);
  @override
  Future<int> length() async => lengthSync();
  @override
  int lengthSync() => raw.lengthSync();
  @override
  Future<int> position() async => positionSync();
  @override
  int positionSync() => raw.positionSync();
  @override
  Future<RandomAccessFile> setPosition(int position) async {
    setPositionSync(position);
    return this;
  }

  @override
  void setPositionSync(int position) => raw.setPositionSync(position);
  @override
  Future<RandomAccessFile> truncate(int length) async {
    truncateSync(length);
    return this;
  }

  @override
  void truncateSync(int length) => raw.truncateSync(length);
  @override
  Future<RandomAccessFile> flush() async {
    flushSync();
    return this;
  }

  @override
  void flushSync() => raw.flushSync();
  @override
  Future<RandomAccessFile> lock([
    FileLock mode = FileLock.exclusive,
    int start = 0,
    int end = -1,
  ]) async {
    lockSync(mode, start, end);
    return this;
  }

  @override
  void lockSync([
    FileLock mode = FileLock.exclusive,
    int start = 0,
    int end = -1,
  ]) => raw.lockSync(mode, start, end);
  @override
  Future<RandomAccessFile> unlock([int start = 0, int end = -1]) async {
    unlockSync(start, end);
    return this;
  }

  @override
  void unlockSync([int start = 0, int end = -1]) => raw.unlockSync(start, end);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'Unsupported persistence file operation: ${invocation.memberName}',
  );
}
