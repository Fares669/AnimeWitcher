import 'dart:io';

import 'package:animewitcher/core/storage/download_persistence_worker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late DownloadPersistenceWorker worker;

  setUp(() {
    root = Directory.systemTemp.createTempSync('download-persistence-test-');
    worker = DownloadPersistenceWorker.forDirectory(root.path);
  });
  tearDown(() async {
    await worker.close();
    await Hive.close();
    root.deleteSync(recursive: true);
  });

  test('opens existing Hive format, persists deletion, and reopens', () async {
    Hive.init(root.path);
    final old = await Hive.openBox<dynamic>('fixture');
    await old.put('old', {'id': 'old', 'complete': true});
    await old.close();

    expect(await worker.run('hive.get', ['fixture', 'old']), {
      'id': 'old',
      'complete': true,
    });
    await worker.run('hive.put', [
      'fixture',
      'keep',
      {'id': 'keep'},
    ]);
    await worker.run('hive.delete', ['fixture', 'old']);
    await worker.close();
    worker = DownloadPersistenceWorker.forDirectory(root.path);
    expect(await worker.run('hive.all', ['fixture']), {
      'keep': {'id': 'keep'},
    });
    await worker.close();

    final reopened = await Hive.openBox<dynamic>('fixture');
    expect(reopened.get('old'), isNull);
    expect(reopened.get('keep'), {'id': 'keep'});
    await reopened.close();
  });

  test('serializes concurrent mutations and preserves compaction', () async {
    await Future.wait([
      worker.run('hive.put', [
        'fixture',
        'same',
        {'value': 1},
      ]),
      worker.run('hive.delete', ['fixture', 'same']),
      worker.run('hive.put', [
        'fixture',
        'same',
        {'value': 2},
      ]),
    ]);
    await worker.run('hive.compact', ['fixture']);
    await worker.close();
    worker = DownloadPersistenceWorker.forDirectory(root.path);
    expect(await worker.run('hive.get', ['fixture', 'same']), {'value': 2});
  });

  test(
    'rejects unsupported operations without poisoning later requests',
    () async {
      await expectLater(worker.run('bad-operation', []), throwsStateError);
      await worker.run('hive.put', ['fixture', 'ok', 7]);
      expect(await worker.run('hive.get', ['fixture', 'ok']), 7);
    },
  );

  test('same directory shares one exclusive box owner', () async {
    final other = DownloadPersistenceWorker.forDirectory(root.path);
    expect(identical(worker, other), isTrue);
    await worker.run('hive.put', ['fixture', 'ok', 8]);
    expect(await other.run('hive.get', ['fixture', 'ok']), 8);
  });
  test('patches preserve concurrent independent metadata fields', () async {
    await worker.run('hive.put', [
      'fixture',
      'task',
      {'title': 'Episode'},
    ]);
    await Future.wait([
      worker.run('hive.patch', [
        'fixture',
        'task',
        {'path': '/video'},
      ]),
      worker.run('hive.patch', [
        'fixture',
        'task',
        {'logicalId': 'logical'},
      ]),
    ]);
    expect(await worker.run('hive.get', ['fixture', 'task']), {
      'title': 'Episode',
      'path': '/video',
      'logicalId': 'logical',
    });
    await worker.run('hive.patch', [
      'fixture',
      'absent',
      {'path': '/video'},
    ]);
    expect(await worker.run('hive.get', ['fixture', 'absent']), isNull);
  });

  test('close settles accepted requests and rejects later work', () async {
    final write = worker.run('hive.put', ['fixture', 'key', 'durable']);
    final closing = worker.close();
    expect(identical(closing, worker.close()), isTrue);
    await expectLater(
      worker.run('hive.get', ['fixture', 'key']),
      throwsStateError,
    );
    await write;
    await closing;
    worker = DownloadPersistenceWorker.forDirectory(root.path);
    expect(await worker.run('hive.get', ['fixture', 'key']), 'durable');
  });

  test(
    'download directories cannot silently change after worker startup',
    () async {
      await worker.run('hive.open', ['fixture']);
      expect(
        () => DownloadPersistenceWorker.forDirectory(
          root.path,
          documentsDirectory: '${root.path}/other',
        ),
        throwsStateError,
      );
    },
  );

  test(
    'failed filesystem write remains visible to caller and is retryable',
    () async {
      final blocked = File('${root.path}/blocked')..writeAsStringSync('keep');
      await expectLater(
        worker.run('local.put', [
          'blocked',
          'key',
          {'value': 1},
        ]),
        throwsA(isA<FileSystemException>()),
      );
      expect(blocked.readAsStringSync(), 'keep');
      blocked.deleteSync();
      await worker.run('local.put', [
        'blocked',
        'key',
        {'value': 2},
      ]);
      expect(await worker.run('local.get', ['blocked', 'key']), {'value': 2});
    },
  );
}
