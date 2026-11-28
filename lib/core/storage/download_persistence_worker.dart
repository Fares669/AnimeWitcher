import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:background_downloader/background_downloader.dart';
import 'package:collection/collection.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../services/download_parallel.dart';
import '../services/download_v2/download_v2_models.dart';
import 'download_persistence_io.dart';

/// Exclusive owner of the download boxes and downloader JSON files.
///
/// Synchronous disk calls run only in this worker, so stalled DNS cannot starve
/// persistence and no filesystem work blocks Flutter's UI isolate. Existing
/// Hive and background_downloader formats remain unchanged.
final class DownloadPersistenceWorker {
  DownloadPersistenceWorker._(this.directory, this.documentsDirectory);

  factory DownloadPersistenceWorker.forDirectory(
    String directory, {
    String? documentsDirectory,
  }) {
    final key = p.normalize(p.absolute(directory));
    final documents = documentsDirectory == null
        ? null
        : p.normalize(p.absolute(documentsDirectory));
    final existing = _workers[key];
    if (existing != null) {
      if (documents != null && documents != existing.documentsDirectory) {
        if (existing._connection != null) {
          throw StateError(
            'Download persistence directories changed after startup',
          );
        }
        existing.documentsDirectory = documents;
      }
      return existing;
    }
    return _workers[key] = DownloadPersistenceWorker._(key, documents);
  }

  static final _workers = <String, DownloadPersistenceWorker>{};

  static Future<DownloadPersistenceWorker> application() async {
    final support = await getApplicationSupportDirectory();
    final documents = await getApplicationDocumentsDirectory();
    return DownloadPersistenceWorker.forDirectory(
      support.path,
      documentsDirectory: documents.path,
    );
  }

  final String directory;
  String? documentsDirectory;
  final _pending = <int, Completer<dynamic>>{};
  int _nextId = 0;
  Future<SendPort>? _connection;
  ReceivePort? _responses;
  Isolate? _isolate;
  bool _closed = false;
  Future<void>? _closing;

  Future<SendPort> _start() async {
    final ready = Completer<SendPort>();
    final responses = ReceivePort();
    _responses = responses;
    void fail(Object error, StackTrace stack) {
      if (!ready.isCompleted) ready.completeError(error, stack);
      for (final reply in _pending.values) {
        reply.completeError(error, stack);
      }
      _pending.clear();
    }

    responses.listen((dynamic message) {
      if (message is SendPort) {
        ready.complete(message);
      } else if (message is List && message.length == 4) {
        final reply = _pending.remove(message[0]);
        if (message[2] == null) {
          reply?.complete(message[1]);
        } else {
          reply?.completeError(
            message[2] as Object,
            StackTrace.fromString(message[3] as String),
          );
        }
      } else if (!_closed) {
        fail(
          StateError('Download persistence worker stopped: $message'),
          StackTrace.current,
        );
        _closed = true;
        _workers.remove(directory);
        responses.close();
      }
    });
    try {
      _isolate = await Isolate.spawn(
        _downloadPersistenceMain,
        <Object?>[responses.sendPort, directory, documentsDirectory],
        onError: responses.sendPort,
        onExit: responses.sendPort,
      );
    } catch (error, stack) {
      fail(error, stack);
      responses.close();
    }
    return ready.future;
  }

  Future<dynamic> run(String operation, List<Object?> arguments) {
    if (_closing != null || _closed) {
      return Future.error(StateError('Download persistence worker is closed'));
    }
    return _request(operation, arguments);
  }

  Future<dynamic> _request(String operation, List<Object?> arguments) {
    final id = _nextId++;
    final reply = Completer<dynamic>();
    _pending[id] = reply;
    () async {
      try {
        final port = await (_connection ??= _start());
        if (_closed) throw StateError('Download persistence worker is closed');
        port.send(<Object?>[id, operation, arguments]);
      } catch (error, stack) {
        _pending.remove(id)?.completeError(error, stack);
      }
    }();
    return reply.future;
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    if (_closed) return;
    if (_connection != null) await _request('close', const []);
    _closed = true;
    _workers.remove(directory);
    _responses?.close();
    _isolate?.kill(priority: Isolate.immediate);
  }
}

void _downloadPersistenceMain(List<Object?> configuration) {
  final responses = configuration[0] as SendPort;
  final directory = configuration[1] as String;
  final documents = configuration[2] as String?;
  final requests = ReceivePort();
  final durableRecords = _DurableRecordFiles();
  runDownloadPersistenceIo(() async {
    Hive.init(directory);
    responses.send(requests.sendPort);
    // A single awaited dispatch owns both Hive boxes and downloader files.
    // No later mutation can overtake an earlier write/delete/close.
    await for (final dynamic message in requests) {
      final request = message as List;
      final id = request[0] as int;
      final operation = request[1] as String;
      try {
        final result = await _dispatch(
          directory,
          documents,
          operation,
          durableRecords,
          (request[2] as List).cast<Object?>(),
        );
        responses.send(<Object?>[id, result, null, null]);
        if (operation == 'close') {
          requests.close();
          break;
        }
      } catch (error, stack) {
        responses.send(<Object?>[id, null, error, stack.toString()]);
      }
    }
  });
}

Future<dynamic> _dispatch(
  String directory,
  String? documents,
  String operation,
  _DurableRecordFiles durableRecords,
  List<Object?> args,
) async {
  if (operation == 'close') return Hive.close();
  if (operation == 'hive.deleteBox') {
    return Hive.deleteBoxFromDisk(args[0] as String);
  }
  if (operation == 'hive.safeOpen') {
    await _safeOpenHiveBox(args[0] as String);
    return null;
  }
  if (operation.startsWith('hive.')) {
    final box = await _openHiveBox(args[0] as String);
    switch (operation) {
      case 'hive.open':
        return null;
      case 'hive.get':
        return box.get(args[1]);
      case 'hive.all':
        return box.toMap();
      case 'hive.logicalRecords':
        // Decode the fresh snapshot on the isolate that owns the box. Only
        // the typed records cross the port: the box keys and raw Hive maps
        // are not needed on the caller's isolate.
        final records = <LogicalDownloadRecordV2>[];
        for (final raw in box.values) {
          final record = LogicalDownloadRecordV2.fromJson(raw);
          if (record != null) records.add(record);
        }
        return records;
      case 'hive.put':
        return box.put(args[1], args[2]);
      case 'hive.delete':
        return box.delete(args[1]);
      case 'hive.deleteIfUnchanged':
        if (!const DeepCollectionEquality().equals(box.get(args[1]), args[2])) {
          return false;
        }
        await box.delete(args[1]);
        return true;
      case 'hive.patch':
        final current = box.get(args[1]);
        if (current == null) return null;
        return box.put(
          args[1],
          Map<String, dynamic>.from(current as Map)
            ..addAll(Map<String, dynamic>.from(args[2] as Map)),
        );
      case 'hive.compact':
        return box.compact();
      case 'hive.flush':
        return box.flush();
      default:
        throw StateError('Unsupported Hive operation: $operation');
    }
  }
  if (operation == 'local.version') return _localVersion(directory);
  if (operation == 'local.initialize') {
    durableRecords.invalidate();
    final version = _localVersion(directory);
    if (version == 1) return null;
    if (version != 0) {
      throw StateError('Unsupported downloader database version: $version');
    }
    if (documents != null && p.normalize(documents) != p.normalize(directory)) {
      for (final collection in (args[0] as List).cast<String>()) {
        final source = _localDirectory(documents, collection);
        if (!source.existsSync()) continue;
        for (final file
            in source.listSync(followLinks: false).whereType<File>()) {
          final target = _localFile(
            directory,
            collection,
            p.basename(file.path),
          );
          final bytes = file.readAsBytesSync();
          if (target.existsSync()) {
            final existing = target.readAsBytesSync();
            if (!_equalBytes(bytes, existing)) {
              throw StateError(
                'Conflicting downloader migration file: ${p.basename(file.path)}',
              );
            }
          } else {
            _atomicWrite(target, bytes);
          }
          file.deleteSync();
        }
        // Keep unexpected nested directories/symlinks intact.
        if (source.listSync(followLinks: false).isEmpty) source.deleteSync();
      }
    }
    _atomicWrite(
      _localFile(directory, 'backgroundDownloaderDatabase', 'metaData'),
      utf8.encode(jsonEncode({'version': 1})),
    );
    return null;
  }
  if (operation.startsWith('local.')) {
    final collection = _segment(args[0] as String);
    switch (operation) {
      case 'local.get':
        return _readJson(_localFile(directory, collection, args[1] as String));
      case 'local.all':
        final folder = _localDirectory(directory, collection);
        if (!folder.existsSync()) return <Map<String, dynamic>>[];
        return [
          for (final file
              in folder.listSync(followLinks: false).whereType<File>())
            if (!p.basename(file.path).startsWith('.aw-persistence-'))
              if (_readJson(file) case final Map<String, dynamic> value) value,
        ];
      case 'local.durableChildren':
        if (collection != LocalStorePersistentStorage.taskRecordsPath) {
          throw StateError('Durable lookup requires task records');
        }
        return durableRecords.read(directory, args[1] as String);
      case 'local.put':
        final id = args[1] as String;
        _atomicWrite(
          _localFile(directory, collection, id),
          utf8.encode(jsonEncode(args[2])),
        );
        if (collection == LocalStorePersistentStorage.taskRecordsPath) {
          durableRecords.stored(id, args[2]);
        }
        return null;
      case 'local.remove':
        final id = args[1] as String?;
        final isTaskRecord =
            collection == LocalStorePersistentStorage.taskRecordsPath;
        if (id == null) {
          // A recursive deletion may succeed only in part on failure.
          if (isTaskRecord) durableRecords.invalidate();
          final folder = _localDirectory(directory, collection);
          if (folder.existsSync()) folder.deleteSync(recursive: true);
        } else {
          final file = _localFile(directory, collection, id);
          if (file.existsSync()) file.deleteSync();
          if (isTaskRecord) durableRecords.removed(id);
        }
        return null;
    }
  }
  throw StateError('Unsupported download persistence operation: $operation');
}

/// Indexes only durable child file names; the worker is the exclusive task
/// record writer. Initialize after migration, then observe each successful
/// atomic put/remove in the same dispatch sequence. The current rows still
/// come from disk, and no native writer status is cached.
final class _DurableRecordFiles {
  Map<String, Set<String>>? _filesByParent;
  final _parentByFile = <String, String>{};
  bool _hasMixedCase = false;

  void invalidate() {
    _filesByParent = null;
    _parentByFile.clear();
    _hasMixedCase = false;
  }

  void _add(String filename, Map<String, dynamic> json) {
    if (filename.startsWith('.aw-persistence-')) return;
    // Keep the same compatibility rules as Database.allRecords, including
    // validation of task types/status and metadata-based durable ownership.
    final record = TaskRecord.fromJson(json);
    if (record.group != kPersistentDownloadChunkGroup) return;
    final parent = downloadInternalParentTaskId(record.task);
    if (parent == null) return;
    _hasMixedCase |= filename.toLowerCase() != filename;
    _parentByFile[filename] = parent;
    (_filesByParent![parent] ??= <String>{}).add(filename);
  }

  void stored(String filename, Object? value) {
    if (_filesByParent == null) return;
    removed(filename);
    if (_filesByParent == null) return;
    try {
      _add(filename, Map<String, dynamic>.from(value as Map));
    } catch (_) {
      // Do not change storage write semantics; the next lookup will rescan and
      // surface any malformed task record as the previous full scan did.
      invalidate();
    }
  }

  void removed(String filename) {
    // Legacy mixed-case aliases can resolve to the same file on Windows/iOS.
    // Admit such a mutation only through a new authoritative directory scan.
    if (_hasMixedCase || filename != filename.toLowerCase()) {
      invalidate();
      return;
    }
    final parent = _parentByFile.remove(filename);
    if (parent == null) return;
    final files = _filesByParent![parent]!;
    files.remove(filename);
    if (files.isEmpty) _filesByParent!.remove(parent);
  }

  List<Map<String, dynamic>> read(String directory, String parent) {
    final folder = _localDirectory(
      directory,
      LocalStorePersistentStorage.taskRecordsPath,
    );
    if (_filesByParent == null) {
      _filesByParent = <String, Set<String>>{};
      try {
        if (folder.existsSync()) {
          for (final file
              in folder.listSync(followLinks: false).whereType<File>()) {
            final filename = p.basename(file.path);
            if (filename.startsWith('.aw-persistence-')) continue;
            if (_readJson(file) case final Map<String, dynamic> json) {
              _add(filename, json);
            }
          }
        }
      } catch (_) {
        invalidate();
        rethrow;
      }
    }
    return [
      for (final filename in _filesByParent![parent] ?? const <String>{})
        if (FileSystemEntity.typeSync(
              p.join(folder.path, filename),
              followLinks: false,
            ) ==
            FileSystemEntityType.file)
          if (_readJson(File(p.join(folder.path, filename)))
              case final Map<String, dynamic> json)
            json,
    ];
  }
}

Future<Box<dynamic>> _openHiveBox(String name) async {
  final opening = Hive.openBox<dynamic>(name);
  // Hive 2 also errors an internal coalescing future on a failed open. Observe
  // that future through a second coalesced call so it cannot kill the worker;
  // callers still receive the original opening failure below.
  Hive.openBox<dynamic>(name).ignore();
  try {
    return await opening;
  } catch (_) {
    // Hive also starts close without awaiting it. Our synchronous worker IO
    // settles in microtasks; let it release the old lock before any retry.
    await Future<void>.delayed(Duration.zero);
    rethrow;
  }
}

Future<Box<dynamic>> _safeOpenHiveBox(String name) async {
  try {
    return await _openHiveBox(name);
  } catch (_) {
    // Preserve StorageService's existing metadata salvage/reset behavior.
    // Ordinary logical-record opens never use this destructive fallback.
    final salvaged = <dynamic, dynamic>{};
    try {
      final recovery = await _openHiveBox(name);
      salvaged.addAll(recovery.toMap());
      await recovery.close();
    } catch (_) {
      // Hive's default crash recovery could not read this metadata box.
    }
    try {
      await Hive.deleteBoxFromDisk(name);
    } catch (_) {
      // The final open below still reports a persistent filesystem failure.
    }
    final fresh = await _openHiveBox(name);
    if (salvaged.isNotEmpty) await fresh.putAll(salvaged);
    return fresh;
  }
}

String _segment(String value) {
  if (value.isEmpty ||
      value == '.' ||
      value == '..' ||
      value.contains('/') ||
      value.contains('\\')) {
    throw ArgumentError.value(value, 'path segment');
  }
  return value;
}

Directory _localDirectory(String root, String collection) {
  final folder = Directory(p.join(root, _segment(collection)));
  if (FileSystemEntity.typeSync(folder.path, followLinks: false) ==
      FileSystemEntityType.link) {
    throw FileSystemException(
      'Downloader collection must not be a symlink',
      folder.path,
    );
  }
  return folder;
}

File _localFile(String root, String collection, String id) {
  final file = File(
    p.join(_localDirectory(root, collection).path, _segment(id)),
  );
  if (FileSystemEntity.typeSync(file.path, followLinks: false) ==
      FileSystemEntityType.link) {
    throw FileSystemException(
      'Downloader record must not be a symlink',
      file.path,
    );
  }
  return file;
}

Map<String, dynamic>? _readJson(File file) {
  if (!file.existsSync()) return null;
  // Localstore created empty files even for missing reads and ignored malformed
  // JSON rows. Keep that legacy read behavior; filesystem/write errors surface.
  try {
    final value = jsonDecode(file.readAsStringSync());
    return value is Map ? Map<String, dynamic>.from(value) : null;
  } on FormatException {
    return null;
  }
}

int _localVersion(String directory) =>
    (_readJson(
              _localFile(directory, 'backgroundDownloaderDatabase', 'metaData'),
            )?['version']
            as num?)
        ?.toInt() ??
    0;

void _atomicWrite(File target, List<int> bytes) {
  target.parent.createSync(recursive: true);
  final temporary = File(
    p.join(
      target.parent.path,
      '.aw-persistence-${DateTime.now().microsecondsSinceEpoch}.tmp',
    ),
  );
  try {
    temporary.writeAsBytesSync(bytes, flush: true);
    temporary.renameSync(target.path);
  } catch (_) {
    if (temporary.existsSync()) temporary.deleteSync();
    rethrow;
  }
}

bool _equalBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
