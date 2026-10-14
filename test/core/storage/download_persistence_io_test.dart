import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:animewitcher/core/storage/download_persistence_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('download_persistence_io_');
  });

  tearDown(() async {
    await temp.delete(recursive: true);
  });

  test(
    'real Hive persists, compacts, reopens, and deletes using only sync IO',
    () async {
      final path = '${temp.path}/nested/boxes';
      final result = await Isolate.run(
        () => _rejectAsyncIo(() {
          return runDownloadPersistenceIo(() async {
            Hive.init(path);
            var box = await Hive.openBox<dynamic>('downloads');
            await box.put('deleted', {'state': 'complete', 'size': 42});
            await box.put('kept', ['synthetic', 123]);
            await box.delete('deleted');
            await box.compact();
            await box.flush();
            await box.close();

            box = await Hive.openBox<dynamic>('downloads');
            final result = [box.get('deleted'), box.get('kept')];
            await box.close();

            // Lazy reads use the random-access read path as well.
            final lazy = await Hive.openLazyBox<dynamic>('downloads');
            result.add(await lazy.get('kept'));
            await lazy.clear();
            await lazy.deleteFromDisk();
            result.add(await Hive.boxExists('downloads'));
            await Hive.close();
            return result;
          });
        }),
      );

      expect(result, [
        null,
        ['synthetic', 123],
        ['synthetic', 123],
        false,
      ]);
    },
  );

  test('derived entities and static metadata stay in the IO scope', () async {
    final path = temp.path;
    final results = await Isolate.run(
      () => _rejectAsyncIo(() {
        return runDownloadPersistenceIo(() async {
          final directory = await Directory('$path/created').create();
          final file = await File('${directory.path}/item').create();
          var raf = await file.open(mode: FileMode.write);
          await raf.writeFrom([1, 2, 3]);
          await raf.close();
          raf = await file.open(mode: FileMode.writeOnlyAppend);
          await raf.writeFrom([4]);
          await raf.flush();
          await raf.close();
          final renamed = await file.rename('${directory.path}/renamed');
          final listed = await directory.absolute.list().toList();
          final results = <Object?>[
            await renamed.readAsBytes(),
            await renamed.parent.exists(),
            await renamed.absolute.exists(),
            await listed.single.exists(),
            (await listed.single.stat()).size,
            (await FileStat.stat(renamed.path)).size,
            await FileSystemEntity.type(renamed.path),
            await renamed.resolveSymbolicLinks(),
            await directory.resolveSymbolicLinks(),
          ];
          await listed.single.delete();
          final moved = await directory.rename('$path/moved');
          results.add(await moved.exists());
          await moved.delete();
          return results;
        });
      }),
    );

    expect(results.take(7), [
      [1, 2, 3, 4],
      true,
      true,
      true,
      4,
      4,
      FileSystemEntityType.file,
    ]);
    expect(results[7], endsWith('/created/renamed'));
    expect(results[8], endsWith('/created'));
    expect(results[9], isTrue);
  });

  test(
    'real Hive restores compaction files and recovers incomplete frames',
    () async {
      final path = temp.path;
      final result = await Isolate.run(
        () => _rejectAsyncIo(() {
          return runDownloadPersistenceIo(() async {
            Hive.init(path);
            var box = await Hive.openBox<dynamic>('recovery');
            await box.put('kept', 'synthetic');
            await box.close();
            final file = File('$path/recovery.hive');
            final originalSize = (await file.stat()).size;
            await file.rename('$path/recovery.hivec');
            box = await Hive.openBox<dynamic>('recovery');
            await box.close();

            // An existing primary file wins over a leftover compacted file.
            final compacted = await File('$path/recovery.hivec').create();
            final raf = await file.open(mode: FileMode.writeOnlyAppend);
            await raf.writeFrom([1, 2]);
            await raf.close();
            box = await Hive.openBox<dynamic>('recovery');
            final result = <Object?>[
              box.get('kept'),
              await compacted.exists(),
              (await file.stat()).size == originalSize,
            ];
            await box.deleteFromDisk();
            return result;
          });
        }),
      );
      expect(result, ['synthetic', false, true]);
    },
  );

  test(
    'random-access handles preserve offsets, locks, and truncation',
    () async {
      final path = '${temp.path}/random_access';
      final result = await Isolate.run(
        () => _rejectAsyncIo(() {
          return runDownloadPersistenceIo(() async {
            final raf = await File(path).open(mode: FileMode.write);
            await raf.lock(FileLock.exclusive, 0, 4);
            await raf.writeFrom([9, 1, 2, 3, 9], 1, 4);
            final position = await raf.position();
            await raf.setPosition(0);
            final buffer = [9, 9, 9, 9];
            final count = await raf.readInto(buffer, 1, 3);
            await raf.truncate(2);
            final length = await raf.length();
            await raf.unlock(0, 4);
            await raf.close();
            return <Object?>[position, buffer, count, length];
          });
        }),
      );
      expect(result, [
        3,
        [9, 1, 2, 9],
        2,
        2,
      ]);
    },
  );

  test(
    'async errors are futures and overrides do not escape their zone',
    () async {
      final outside = IOOverrides.current;
      final missingPath = '${temp.path}/missing';
      await runDownloadPersistenceIo(() async {
        late Future<RandomAccessFile> opening;
        expect(() => opening = File(missingPath).open(), returnsNormally);
        await expectLater(opening, throwsA(isA<FileSystemException>()));
        expect(() => File(missingPath).openWrite(), throwsUnsupportedError);
      });
      expect(IOOverrides.current, same(outside));
    },
  );

  test(
    'worker JSON filesystem calls use synchronous disk operations',
    () async {
      final path = temp.path;
      final result = await Isolate.run(
        () => _rejectAsyncIo(() {
          return runDownloadPersistenceIo(() {
            final file = File('$path/nested/item');
            file.parent.createSync(recursive: true);
            file.writeAsBytesSync(
              utf8.encode('{"value":"synthetic"}'),
              flush: true,
            );
            final renamed = file.renameSync('$path/nested/renamed');
            final listed = renamed.parent.listSync(followLinks: false);
            final result = <Object?>[
              jsonDecode(renamed.readAsStringSync()),
              (listed.single as File).readAsBytesSync(),
              FileSystemEntity.typeSync(renamed.path),
            ];
            renamed.parent.deleteSync(recursive: true);
            return result;
          });
        }),
      );
      expect(result, [
        {'value': 'synthetic'},
        utf8.encode('{"value":"synthetic"}'),
        FileSystemEntityType.file,
      ]);
    },
  );
  test(
    'unfollowed link entries are preserved without traversing their target',
    () async {
      final collection = await Directory('${temp.path}/collection').create();
      final sentinelDirectory = await Directory('${temp.path}/sentinel')
          .create();
      final sentinel = await File('${sentinelDirectory.path}/keep')
          .writeAsString('untouched');
      final link = await Link('${collection.path}/linked')
          .create(sentinelDirectory.path);
      await File('${collection.path}/record').writeAsString('synthetic');
      final path = collection.path;
      final result = await Isolate.run(
        () => _rejectAsyncIo(() {
          return runDownloadPersistenceIo(() {
            final entries = Directory(path).listSync(followLinks: false);
            for (final file in entries.whereType<File>()) {
              file.deleteSync();
            }
            final linked = entries.whereType<Link>().single;
            return <Object?>[
              linked.path,
              linked.absolute.path,
              linked.parent.existsSync(),
              FileSystemEntity.typeSync(linked.path, followLinks: false),
            ];
          });
        }),
      );
      expect(result, [
        link.path,
        link.absolute.path,
        true,
        FileSystemEntityType.link,
      ]);
      expect(await sentinel.readAsString(), 'untouched');
      expect(await link.exists(), isTrue);
      expect(await collection.list(followLinks: false).length, 1);
    },
    skip: Platform.isWindows,
  );
}

// These guards allow synchronous calls and deliberately reject every other
// call. The real Hive tests therefore fail if any wrapper leaks async disk IO.
T _rejectAsyncIo<T>(T Function() body) {
  final parent = Zone.current;
  return IOOverrides.runZoned(
    body,
    createFile: (path) => _SyncOnlyFile(parent.run(() => File(path)), parent),
    createDirectory: (path) =>
        _SyncOnlyDirectory(parent.run(() => Directory(path)), parent),
    stat: (_) => throw StateError('Unexpected async FileStat.stat'),
    fseGetType: (_, _) => throw StateError('Unexpected async entity type'),
  );
}

class _SyncOnlyFile implements File {
  _SyncOnlyFile(this.raw, this.parentZone);
  final File raw;
  final Zone parentZone;

  @override
  String get path => raw.path;
  @override
  Uri get uri => raw.uri;
  @override
  File get absolute =>
      _SyncOnlyFile(parentZone.run(() => raw.absolute), parentZone);
  @override
  Directory get parent =>
      _SyncOnlyDirectory(parentZone.run(() => raw.parent), parentZone);
  @override
  bool existsSync() => parentZone.run(raw.existsSync);
  @override
  void createSync({bool recursive = false, bool exclusive = false}) =>
      parentZone.run(
        () => raw.createSync(recursive: recursive, exclusive: exclusive),
      );
  @override
  void deleteSync({bool recursive = false}) =>
      parentZone.run(() => raw.deleteSync(recursive: recursive));
  @override
  File renameSync(String path) =>
      _SyncOnlyFile(parentZone.run(() => raw.renameSync(path)), parentZone);
  @override
  FileStat statSync() => parentZone.run(raw.statSync);
  @override
  String resolveSymbolicLinksSync() =>
      parentZone.run(raw.resolveSymbolicLinksSync);
  @override
  Uint8List readAsBytesSync() => parentZone.run(raw.readAsBytesSync);
  @override
  String readAsStringSync({Encoding encoding = utf8}) =>
      parentZone.run(() => raw.readAsStringSync(encoding: encoding));
  @override
  void writeAsBytesSync(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) => parentZone.run(
    () => raw.writeAsBytesSync(bytes, mode: mode, flush: flush),
  );
  @override
  RandomAccessFile openSync({FileMode mode = FileMode.read}) =>
      _SyncOnlyRandomAccessFile(parentZone.run(() => raw.openSync(mode: mode)));

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected File operation ${invocation.memberName}');
}

class _SyncOnlyDirectory implements Directory {
  _SyncOnlyDirectory(this.raw, this.parentZone);
  final Directory raw;
  final Zone parentZone;

  @override
  String get path => raw.path;
  @override
  Uri get uri => raw.uri;
  @override
  Directory get absolute =>
      _SyncOnlyDirectory(parentZone.run(() => raw.absolute), parentZone);
  @override
  Directory get parent =>
      _SyncOnlyDirectory(parentZone.run(() => raw.parent), parentZone);
  @override
  bool existsSync() => parentZone.run(raw.existsSync);
  @override
  void createSync({bool recursive = false}) =>
      parentZone.run(() => raw.createSync(recursive: recursive));
  @override
  void deleteSync({bool recursive = false}) =>
      parentZone.run(() => raw.deleteSync(recursive: recursive));
  @override
  Directory renameSync(String path) => _SyncOnlyDirectory(
    parentZone.run(() => raw.renameSync(path)),
    parentZone,
  );
  @override
  FileStat statSync() => parentZone.run(raw.statSync);
  @override
  String resolveSymbolicLinksSync() =>
      parentZone.run(raw.resolveSymbolicLinksSync);
  @override
  List<FileSystemEntity> listSync({
    bool recursive = false,
    bool followLinks = true,
  }) => parentZone
      .run(() => raw.listSync(recursive: recursive, followLinks: followLinks))
      .map(
        (entity) => switch (entity) {
          File() => _SyncOnlyFile(entity, parentZone),
          Directory() => _SyncOnlyDirectory(entity, parentZone),
          Link() => entity,
          _ => throw StateError('Unexpected test fixture entity'),
        },
      )
      .toList();

  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(
    'Unexpected Directory operation ${invocation.memberName}',
  );
}

class _SyncOnlyRandomAccessFile implements RandomAccessFile {
  _SyncOnlyRandomAccessFile(this.raw);
  final RandomAccessFile raw;

  @override
  String get path => raw.path;
  @override
  void closeSync() => raw.closeSync();
  @override
  Uint8List readSync(int count) => raw.readSync(count);
  @override
  int readIntoSync(List<int> buffer, [int start = 0, int? end]) =>
      raw.readIntoSync(buffer, start, end);
  @override
  void writeFromSync(List<int> buffer, [int start = 0, int? end]) =>
      raw.writeFromSync(buffer, start, end);
  @override
  int lengthSync() => raw.lengthSync();
  @override
  int positionSync() => raw.positionSync();
  @override
  void setPositionSync(int position) => raw.setPositionSync(position);
  @override
  void truncateSync(int length) => raw.truncateSync(length);
  @override
  void flushSync() => raw.flushSync();
  @override
  void lockSync([
    FileLock mode = FileLock.exclusive,
    int start = 0,
    int end = -1,
  ]) => raw.lockSync(mode, start, end);
  @override
  void unlockSync([int start = 0, int end = -1]) => raw.unlockSync(start, end);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected RAF operation ${invocation.memberName}');
}
