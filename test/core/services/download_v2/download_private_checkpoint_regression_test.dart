import 'dart:convert';
import 'dart:io';

import 'package:animewitcher/core/services/persistent_parallel_download.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/parallel_download_fixtures.dart';

typedef _Publisher = Future<bool> Function(File, File, int);

class _CheckpointHarness {
  _CheckpointHarness(this.root) {
    parent = ParallelDownloadTask(
      taskId: 'private-checkpoint',
      url: 'https://example.com/video?token=private-url-secret',
      headers: {'Cookie': 'session=private-cookie-secret'},
      filename: 'episode.mp4',
      directory: '${root.path}/Downloads',
      baseDirectory: BaseDirectory.root,
      chunks: 2,
      allowPause: true,
    );
    rebuild();
  }

  final Directory root;
  late final ParallelDownloadTask parent;
  late PersistentParallelDownload coordinator;
  final records = <String, TaskRecord>{};
  final starts = <DownloadTask>[];
  final live = <String>{};
  bool rejectCancel = false;
  bool livenessUnavailable = false;
  Duration recoveryDelay = const Duration(days: 1);
  bool failCompleteRecord = false;
  bool failAfterCompleteRecord = false;
  _Publisher publisher = publishCompletedTestFile;
  File get privateManifest => File('${root.path}/ApplicationSupport/ranges/private-checkpoint/manifest.json');
  Future<File> get target async => File(await parent.filePath());
  Future<File> get legacyManifest async => File('${(await target).path}.parts/manifest.json');

  void rebuild({bool private = true}) {
    coordinator = PersistentParallelDownload(
      manifestFileResolver: private ? (_) async => privateManifest : null,
      promoteFile: (source, target, bytes) => publisher(source, target, bytes),
      verifyPartSource: verifiedSavedTestRange,
      startPart: (task, _, _) async {
        starts.add(task);
        live.add(task.taskId);
        return true;
      },
      pausePart: (task) async => live.remove(task.taskId),
      cancelParts: (ids) async {
        if (rejectCancel) throw StateError('native cancellation rejected');
        live.removeAll(ids);
      },
      livePartIds: () async {
        if (livenessUnavailable) throw StateError('raw ownership unavailable');
        return Set<String>.from(live);
      },
      saveRecord: (record) async {
        if (failCompleteRecord && record.task.taskId == parent.taskId && record.status == TaskStatus.complete) {
          throw StateError('crash before parent complete record');
        }
        records[record.task.taskId] = record;
      },
      recordForId: (id) async => records[id],
      onUpdate: (update) {
        if (failAfterCompleteRecord && update is TaskStatusUpdate && update.task.taskId == parent.taskId && update.status == TaskStatus.complete) {
          throw StateError('crash after parent complete record');
        }
      },
      onPartProgress: (_, _, _) {},
      recoveryDelay: recoveryDelay,
      tailStallDelay: const Duration(days: 1),
      pendingStartLeaseDelay: const Duration(days: 1),
      diskProgressPollInterval: const Duration(days: 1),
      maxActiveConnections: 2,
    );
  }

  Future<void> barrier() async {
    await coordinator.reconcile(() async => Set<String>.from(live));
  }

  Future<void> begin() async {
    expect(await coordinator.start(parent, 8), isTrue);
    coordinator.handleUpdate(TaskStatusUpdate(starts.first, TaskStatus.running));
    for (var i = 0; i < 200 && starts.length < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(starts, hasLength(2));
    await barrier();
  }

  Future<File> write(DownloadTask task, List<int> bytes) async {
    final file = File(await task.filePath());
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  Future<void> complete({bool fullBody = false}) async {
    await begin();
    if (fullBody) {
      await write(starts.first, List<int>.generate(8, (i) => i));
      live.remove(starts.first.taskId);
      coordinator.handleUpdate(TaskStatusUpdate(starts.first, TaskStatus.complete).copyWith(responseStatusCode: 200));
    } else {
      for (var i = 0; i < 2; i++) {
        final task = starts[i];
        await write(task, List<int>.generate(4, (offset) => i * 4 + offset));
        live.remove(task.taskId);
        coordinator.handleUpdate(TaskStatusUpdate(task, TaskStatus.complete).copyWith(
          responseStatusCode: 206,
          responseHeaders: {'Content-Range': 'bytes ${i * 4}-${i * 4 + 3}/8'},
        ));
        await barrier();
      }
    }
    await barrier();
  }

  Future<void> restart() async {
    await coordinator.dispose();
    live.clear();
    rebuild();
  }

  Future<void> close() async {
    await coordinator.dispose();
    if (await root.exists()) await root.delete(recursive: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _CheckpointHarness harness;
  setUp(() async => harness = _CheckpointHarness(await Directory.systemTemp.createTemp('private-checkpoint-')));
  tearDown(() async => harness.close());

  test('private checkpoint keeps URL and cookies out of visible files and restores identity', () async {
    await harness.begin();
    final part = await harness.write(harness.starts.first, [0, 1]);
    expect(await harness.coordinator.pause(harness.parent), isTrue);
    final snapshot = jsonDecode(await harness.privateManifest.readAsString()) as Map;
    final childIds = (snapshot['parts'] as List).map((raw) => (raw as Map)['task']['taskId']).toList();
    final generation = snapshot['generation'];
    expect(await (await harness.legacyManifest).exists(), isFalse);
    for (final entity in await Directory('${harness.root.path}/Downloads').list(recursive: true).toList()) {
      if (entity is File) {
        final text = latin1.decode(await entity.readAsBytes());
        expect(text, isNot(contains('private-url-secret')));
        expect(text, isNot(contains('private-cookie-secret')));
      }
    }
    await harness.restart();
    expect(await harness.coordinator.restore(harness.parent), isTrue);
    final restored = jsonDecode(await harness.privateManifest.readAsString()) as Map;
    expect(restored['parentTaskId'], harness.parent.taskId);
    expect(restored['generation'], generation);
    expect((restored['parts'] as List).map((raw) => (raw as Map)['task']['taskId']).toList(), childIds);
    expect(await part.readAsBytes(), [0, 1]);
    final task = (restored['parts'] as List).first['task'] as Map;
    expect(task['url'], contains('private-url-secret'));
    expect(task['headers']['Cookie'], 'session=private-cookie-secret');
  });

  test('legacy temporary checkpoint migrates durably before visible secrets are removed', () async {
    await harness.coordinator.dispose();
    harness.rebuild(private: false);
    await harness.begin();
    final part = await harness.write(harness.starts.first, [0, 1]);
    expect(await harness.coordinator.pause(harness.parent), isTrue);
    final legacy = await harness.legacyManifest;
    final snapshot = jsonDecode(await legacy.readAsString()) as Map<String, dynamic>;
    snapshot['checkpointSequence'] = (snapshot['checkpointSequence'] as int) + 10;
    snapshot['generation'] = (snapshot['generation'] as int) + 4;
    await File('${legacy.path}.tmp').writeAsString(jsonEncode(snapshot), flush: true);
    await harness.restart();
    expect(await harness.coordinator.restore(harness.parent), isTrue);
    final migrated = jsonDecode(await harness.privateManifest.readAsString()) as Map;
    expect(migrated['generation'], snapshot['generation']);
    expect(await legacy.exists(), isFalse);
    expect(await File('${legacy.path}.tmp').exists(), isFalse);
    expect(await part.readAsBytes(), [0, 1]);
  });

  test('migration preserves a foreign legacy temporary descriptor', () async {
    await harness.coordinator.dispose();
    harness.rebuild(private: false);
    await harness.begin();
    expect(await harness.coordinator.pause(harness.parent), isTrue);
    final legacy = await harness.legacyManifest;
    final foreign = File('${legacy.path}.tmp');
    await foreign.writeAsString('{"parentTaskId":"foreign-parent","checkpointSequence":999}', flush: true);
    final bytes = await foreign.readAsBytes();
    await harness.restart();
    expect(await harness.coordinator.restore(harness.parent), isTrue);
    expect(await harness.privateManifest.exists(), isTrue);
    expect(await legacy.exists(), isFalse);
    expect(await foreign.readAsBytes(), bytes);
  });

  test('failed private migration preserves legacy recovery until a durable retry', () async {
    await harness.coordinator.dispose();
    harness.rebuild(private: false);
    await harness.begin();
    final part = await harness.write(harness.starts.first, [0, 1]);
    expect(await harness.coordinator.pause(harness.parent), isTrue);
    final legacy = await harness.legacyManifest;
    final bytes = await legacy.readAsBytes();
    await harness.restart();
    final blocker = File('${harness.root.path}/ApplicationSupport');
    await blocker.writeAsString('block private directory');
    final starts = harness.starts.length;
    expect(await harness.coordinator.start(harness.parent, 8), isFalse);
    expect(await legacy.readAsBytes(), bytes);
    expect(await part.readAsBytes(), [0, 1]);
    expect(harness.starts, hasLength(starts));
    await blocker.delete();
    expect(await harness.coordinator.start(harness.parent, 8), isTrue);
    expect(await harness.privateManifest.exists(), isTrue);
    expect(await legacy.exists(), isFalse);
    expect(await part.readAsBytes(), [0, 1]);
  });

  for (final fullBody in [false, true]) {
    final mode = fullBody ? 'full body' : 'multipart';
    test('$mode resumes retained ready source after pre-promotion failure without refetch', () async {
      harness.publisher = (_, _, _) async => throw const FileSystemException('unsupported', '', OSError('ENOTSUP', 45));
      await harness.complete(fullBody: fullBody);
      final checkpoint = jsonDecode(await harness.privateManifest.readAsString()) as Map;
      final ready = checkpoint['readyToPublish'] as Map;
      final source = File(ready['sourcePath'] as String);
      expect(await source.readAsBytes(), List<int>.generate(8, (i) => i));
      expect(ready['sha256'], matches(RegExp(r'^[a-f0-9]{64}$')));
      expect(await (await harness.target).exists(), isFalse);
      final starts = harness.starts.length;
      await harness.restart();
      harness.publisher = publishCompletedTestFile;
      expect(await harness.coordinator.start(harness.parent, 8), isTrue);
      expect(await (await harness.target).readAsBytes(), List<int>.generate(8, (i) => i));
      expect(harness.records[harness.parent.taskId]?.status, TaskStatus.complete);
      expect(harness.starts, hasLength(starts));
      expect(await harness.privateManifest.exists(), isFalse);
    });

    test('$mode recovers post-promotion crash by hash without another publisher or download', () async {
      var publications = 0;
      harness.publisher = (source, target, bytes) async {
        publications++;
        await publishCompletedTestFile(source, target, bytes);
        throw StateError('crash after native rename');
      };
      await harness.complete(fullBody: fullBody);
      expect(await harness.privateManifest.exists(), isTrue);
      final starts = harness.starts.length;
      await harness.restart();
      expect(await harness.coordinator.start(harness.parent, 8), isTrue);
      expect(publications, 1);
      expect(harness.starts, hasLength(starts));
      expect(harness.records[harness.parent.taskId]?.status, TaskStatus.complete);
      expect(await harness.privateManifest.exists(), isFalse);
    });
  }

  test('native publication sees a durable private ready hash before its first call', () async {
    harness.publisher = (source, target, bytes) async {
      final snapshot = jsonDecode(await harness.privateManifest.readAsString()) as Map;
      final ready = snapshot['readyToPublish'] as Map;
      expect(ready['sourcePath'], source.path);
      expect(ready['expectedBytes'], bytes);
      expect(ready['parentTaskId'], harness.parent.taskId);
      expect(ready['generation'], snapshot['generation']);
      expect(ready['sha256'], matches(RegExp(r'^[a-f0-9]{64}$')));
      expect(await (await harness.legacyManifest).exists(), isFalse);
      return publishCompletedTestFile(source, target, bytes);
    };
    await harness.complete();
    expect(harness.records[harness.parent.taskId]?.status, TaskStatus.complete);
  });

  test('post-promotion crash before parent complete record recovers by private hash', () async {
    harness.failCompleteRecord = true;
    await harness.complete();
    expect(harness.records[harness.parent.taskId]?.status, isNot(TaskStatus.complete));
    expect(await harness.privateManifest.exists(), isTrue);
    final starts = harness.starts.length;
    harness.failCompleteRecord = false;
    await harness.restart();
    expect(await harness.coordinator.start(harness.parent, 8), isTrue);
    expect(harness.records[harness.parent.taskId]?.status, TaskStatus.complete);
    expect(harness.starts, hasLength(starts));
  });

  test('trusted inventory discovers private descriptors with visible-byte destinations', () async {
    await harness.begin();
    expect(await harness.coordinator.pause(harness.parent), isTrue);
    final evidence = await discoverParallelManifestRecoveryEvidence(
      [Directory('${harness.root.path}/ApplicationSupport'), Directory('${harness.root.path}/Downloads')],
      manifestFileResolver: (_) async => harness.privateManifest,
    );
    expect(evidence, hasLength(1));
    expect(evidence.single.parentTask?.taskId, harness.parent.taskId);
    expect(evidence.single.manifestFile.path, harness.privateManifest.path);
    expect(evidence.single.childTasks.map((task) => task.taskId).toSet(), harness.starts.map((task) => task.taskId).toSet());
    final untrusted = await discoverParallelManifestRecoveryEvidence([harness.root]);
    expect(untrusted, isEmpty);
  });

  test('completed parent checkpoint survives crash before cleanup and recovers without refetch', () async {
    harness.failAfterCompleteRecord = true;
    await harness.complete();
    expect(harness.records[harness.parent.taskId]?.status, TaskStatus.complete);
    expect(await harness.privateManifest.exists(), isTrue);
    final starts = harness.starts.length;
    harness.failAfterCompleteRecord = false;
    await harness.restart();
    expect(await harness.coordinator.start(harness.parent, 8), isTrue);
    expect(harness.starts, hasLength(starts));
    expect(await harness.privateManifest.exists(), isFalse);
  });

  test('post-promotion same-size altered target fails hash and retains ready checkpoint', () async {
    harness.publisher = (source, target, bytes) async {
      await publishCompletedTestFile(source, target, bytes);
      throw StateError('crash after native rename');
    };
    await harness.complete();
    final target = await harness.target;
    await target.writeAsBytes(List<int>.filled(8, 9), flush: true);
    final starts = harness.starts.length;
    await harness.restart();
    expect(await harness.coordinator.start(harness.parent, 8), isFalse);
    expect(await target.readAsBytes(), List<int>.filled(8, 9));
    expect(await harness.privateManifest.exists(), isTrue);
    expect(harness.starts, hasLength(starts));
    expect(harness.records[harness.parent.taskId]?.status, isNot(TaskStatus.complete));
  });

  for (final body in <List<int>>[[], [99], List<int>.filled(8, 99)]) {
    test('publication collision ${body.length} bytes preserves target and verified source', () async {
      harness.publisher = (source, target, bytes) async {
        await target.writeAsBytes(body, flush: true);
        return false;
      };
      await harness.complete();
      final snapshot = jsonDecode(await harness.privateManifest.readAsString()) as Map;
      final source = File((snapshot['readyToPublish'] as Map)['sourcePath'] as String);
      expect(await source.readAsBytes(), List<int>.generate(8, (i) => i));
      expect(await (await harness.target).readAsBytes(), body);
      await harness.restart();
      expect(await harness.coordinator.start(harness.parent, 8), isFalse);
      expect(await source.readAsBytes(), List<int>.generate(8, (i) => i));
      expect(await (await harness.target).readAsBytes(), body);
    });
  }

  for (final code in [28, 69, 45, 18]) {
    test('publisher errno $code preserves source and checkpoint without fallback', () async {
      harness.publisher = (_, _, _) async => throw FileSystemException('publish failed', '', OSError('injected native failure', code));
      await harness.complete();
      final snapshot = jsonDecode(await harness.privateManifest.readAsString()) as Map;
      final source = File((snapshot['readyToPublish'] as Map)['sourcePath'] as String);
      expect(await source.readAsBytes(), List<int>.generate(8, (i) => i));
      expect(await (await harness.target).exists(), isFalse);
      expect(harness.records[harness.parent.taskId]?.status, TaskStatus.paused);
    });
  }

  test('rejected full-body sibling cancellation becomes usable Resume without source relaunch', () async {
    harness.rejectCancel = true;
    await harness.complete(fullBody: true);
    final source = File(await harness.starts.first.filePath());
    expect(harness.coordinator.activeConnectionCount, 1);
    expect(await source.readAsBytes(), List<int>.generate(8, (i) => i));
    final sibling = harness.starts[1];
    harness.live.remove(sibling.taskId);
    harness.coordinator.handleUpdate(TaskStatusUpdate(sibling, TaskStatus.paused));
    await harness.barrier();
    expect(harness.coordinator.isActive(harness.parent.taskId), isFalse);
    harness.rejectCancel = false;
    expect(await harness.coordinator.start(harness.parent, 8), isTrue);
    expect(await (await harness.target).readAsBytes(), List<int>.generate(8, (i) => i));
    expect(harness.starts, hasLength(2));
    expect(harness.records[harness.parent.taskId]?.status, TaskStatus.complete);
  });

  test('held full body Resume reconciles settled raw native ownership without a terminal callback', () async {
    harness.rejectCancel = true;
    await harness.complete(fullBody: true);
    expect(harness.coordinator.isActive(harness.parent.taskId), isTrue);
    harness.live.clear();
    harness.rejectCancel = false;
    expect(await harness.coordinator.start(harness.parent, 8), isTrue);
    expect(harness.records[harness.parent.taskId]?.status, TaskStatus.complete);
    expect(await (await harness.target).readAsBytes(), List<int>.generate(8, (i) => i));
    expect(harness.starts, hasLength(2));
  });

  test('unknown restored ready-source liveness cannot authorize publication', () async {
    harness.publisher = (_, _, _) async => false;
    await harness.complete(fullBody: true);
    final source = File(await harness.starts.first.filePath());
    await harness.restart();
    harness.recoveryDelay = const Duration(milliseconds: 10);
    await harness.coordinator.dispose();
    harness.rebuild();
    harness.live.add(harness.starts.first.taskId);
    harness.livenessUnavailable = true;
    var publications = 0;
    harness.publisher = (source, target, bytes) async {
      publications++;
      return publishCompletedTestFile(source, target, bytes);
    };
    expect(await harness.coordinator.start(harness.parent, 8), isFalse);
    expect(await harness.coordinator.start(harness.parent, 8), isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(publications, 0);
    expect(await source.readAsBytes(), List<int>.generate(8, (i) => i));
    expect(await (await harness.target).exists(), isFalse);
    harness.livenessUnavailable = false;
    harness.live.clear();
    expect(await harness.coordinator.start(harness.parent, 8), isTrue);
    expect(publications, 1);
  });

  test('private temporary checkpoint symlink cannot receive signed credentials', () async {
    await harness.begin();
    expect(await harness.coordinator.pause(harness.parent), isTrue);
    final foreign = File('${harness.root.path}/foreign-sentinel');
    await foreign.writeAsString('foreign bytes', flush: true);
    final link = Link('${harness.privateManifest.path}.tmp');
    await link.create(foreign.path);
    await expectLater(harness.coordinator.start(harness.parent, 8), throwsA(isA<FileSystemException>()));
    expect(await foreign.readAsString(), 'foreign bytes');
    expect(await FileSystemEntity.type(link.path, followLinks: false), FileSystemEntityType.link);
  });

  test('malformed private child destination parks without replacing checkpoint or bytes', () async {
    await harness.begin();
    expect(await harness.coordinator.pause(harness.parent), isTrue);
    final snapshot = jsonDecode(await harness.privateManifest.readAsString()) as Map<String, dynamic>;
    final rawTask = (snapshot['parts'] as List).first['task'] as Map;
    rawTask['directory'] = '${harness.root.path}/foreign';
    await harness.privateManifest.writeAsString(jsonEncode(snapshot), flush: true);
    final saved = await harness.privateManifest.readAsBytes();
    final starts = harness.starts.length;
    await harness.restart();
    expect(await harness.coordinator.start(harness.parent, 8), isFalse);
    expect(await harness.privateManifest.readAsBytes(), saved);
    expect(harness.starts, hasLength(starts));
  });
}
