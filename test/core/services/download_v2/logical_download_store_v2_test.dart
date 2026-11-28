import 'dart:io';

import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/core/services/download_v2/logical_download_store_v2.dart';
import 'package:animewitcher/core/storage/download_persistence_worker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  LogicalDownloadRecordV2 fixtureRecord({
    DownloadUserIntent intent = DownloadUserIntent.active,
    int generation = 1,
    int updatedAtMillis = 1000,
  }) {
    final logicalId = logicalDownloadIdFor(
      animeId: 'anilist:21',
      episodeKey: '12',
      variantKey: 'sub:1080p',
    );
    return LogicalDownloadRecordV2(
      schemaVersion: kLogicalDownloadSchemaVersionV2,
      logicalId: logicalId,
      mediaId: 'anilist:21',
      unitKey: '12',
      variantKey: 'sub:1080p',
      generation: generation,
      taskId: taskIdForGeneration(logicalId, generation),
      intent: intent,
      destinationPath: 'downloads/anime/episode-12.mp4',
      sourceDescriptor: const <String, Object?>{
        'providerId': 'provider.example',
        'trackingUrl': '/anime/21/12',
      },
      expectedBytes: 123456,
      updatedAtMillis: updatedAtMillis,
    );
  }

  test(
    'store round-trips logical metadata without transport internals',
    () async {
      final store = InMemoryLogicalDownloadStoreV2();
      final record = fixtureRecord(intent: DownloadUserIntent.paused);

      await store.put(record);
      final loaded = await store.get(record.logicalId);

      expect(loaded, isNotNull);
      expect(loaded!.intent, DownloadUserIntent.paused);
      expect(loaded.generation, record.generation);
      expect(loaded.taskId, record.taskId);
      expect(loaded.destinationPath, record.destinationPath);
      expect(loaded.sourceDescriptor, record.sourceDescriptor);

      final serializedKeys = loaded.toJson().keys.join('|').toLowerCase();
      for (final forbidden in <String>[
        'chunkid',
        'range',
        'resumebytes',
        'ownership',
        'retryremaining',
        'holdreason',
      ]) {
        expect(serializedKeys, isNot(contains(forbidden)));
      }
    },
  );

  test('paused intent survives store recreation', () async {
    final backend = <String, Object?>{};
    final first = InMemoryLogicalDownloadStoreV2(backend);
    final record = fixtureRecord(intent: DownloadUserIntent.paused);

    await first.put(record);

    final second = InMemoryLogicalDownloadStoreV2(backend);
    final restored = await second.get(record.logicalId);
    expect(restored, isNotNull);
    expect(restored!.intent, DownloadUserIntent.paused);
    expect(restored.taskId, record.taskId);
    expect(restored.generation, record.generation);
  });

  test(
    'mutate updates one logical record without changing its identity',
    () async {
      final store = InMemoryLogicalDownloadStoreV2();
      final record = fixtureRecord();
      await store.put(record);

      final updated = await store.mutate(record.logicalId, (current) {
        expect(current, isNotNull);
        return current!.copyWith(
          intent: DownloadUserIntent.paused,
          updatedAtMillis: 2000,
        );
      });

      expect(updated, isNotNull);
      expect(updated!.logicalId, record.logicalId);
      expect(updated.taskId, record.taskId);
      expect(updated.intent, DownloadUserIntent.paused);
      expect((await store.get(record.logicalId))?.updatedAtMillis, 2000);
    },
  );

  test('mutate returning null removes the logical record', () async {
    final store = InMemoryLogicalDownloadStoreV2();
    final record = fixtureRecord();
    await store.put(record);

    final result = await store.mutate(record.logicalId, (_) => null);

    expect(result, isNull);
    expect(await store.get(record.logicalId), isNull);
    expect(await store.all(), isEmpty);
  });

  test('all returns every logical record', () async {
    final store = InMemoryLogicalDownloadStoreV2();
    final first = fixtureRecord();
    final secondLogicalId = logicalDownloadIdFor(
      animeId: 'anilist:21',
      episodeKey: '13',
      variantKey: 'sub:1080p',
    );
    final second = LogicalDownloadRecordV2(
      schemaVersion: kLogicalDownloadSchemaVersionV2,
      logicalId: secondLogicalId,
      mediaId: 'anilist:21',
      unitKey: '13',
      variantKey: 'sub:1080p',
      generation: 1,
      taskId: taskIdForGeneration(secondLogicalId, 1),
      intent: DownloadUserIntent.active,
      destinationPath: 'downloads/anime/episode-13.mp4',
      sourceDescriptor: const <String, Object?>{
        'providerId': 'provider.example',
        'trackingUrl': '/anime/21/13',
      },
      updatedAtMillis: 1100,
    );

    await store.put(first);
    await store.put(second);

    final records = await store.all();
    expect(records.map((record) => record.logicalId.value).toSet(), {
      first.logicalId.value,
      second.logicalId.value,
    });
  });

  test(
    'durable bulk read preserves order, schema and snapshot isolation',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'aw-logical-v2-store-',
      );
      var worker = DownloadPersistenceWorker.forDirectory(root.path);
      addTearDown(() async {
        await worker.close();
        await root.delete(recursive: true);
      });
      var store = HiveLogicalDownloadStoreV2(worker: worker);
      final first = fixtureRecord(intent: DownloadUserIntent.paused).copyWith(
        sourceDescriptor: <String, Object?>{
          'providerId': 'fixture',
          'meta': <String, Object?>{'title': 'Episode'},
        },
      );
      await store.put(first);
      final legacy = first.toJson()
        ..['schemaVersion'] = 1
        ..['logicalId'] = 'legacy-id'
        ..['animeId'] = 'legacy-anime'
        ..remove('mediaId')
        ..['episodeKey'] = '7'
        ..remove('unitKey')
        ..['intent'] = 'canceled'
        ..remove('allowPause');
      await worker.run('hive.put', [
        kLogicalDownloadStoreV2Box,
        'legacy',
        legacy,
      ]);
      await worker.run('hive.put', [
        kLogicalDownloadStoreV2Box,
        'invalid',
        {'schemaVersion': 0},
      ]);
      await worker.close();

      worker = DownloadPersistenceWorker.forDirectory(root.path);
      store = HiveLogicalDownloadStoreV2(worker: worker);
      final rawSnapshot =
          await worker.run('hive.all', [kLogicalDownloadStoreV2Box]) as Map;
      final oldShape = rawSnapshot.values
          .map(LogicalDownloadRecordV2.fromJson)
          .nonNulls
          .map((record) => record.toJson())
          .toList();
      final firstSnapshot = await store.all();
      expect(firstSnapshot.map((record) => record.toJson()), oldShape);
      final loaded = firstSnapshot.singleWhere(
        (row) => row.logicalId == first.logicalId,
      );
      loaded.sourceDescriptor['providerId'] = 'caller-only';
      (loaded.sourceDescriptor['meta'] as Map)['title'] = 'caller-only';
      // The sort/delete in the caller never reaches the box or a future read.
      firstSnapshot.removeLast();
      expect((await store.all()).map((row) => row.toJson()), oldShape);
      final next = first.copyWith(
        intent: DownloadUserIntent.failed,
        updatedAtMillis: 2000,
      );
      await store.put(next);
      await worker.run('hive.delete', [kLogicalDownloadStoreV2Box, 'legacy']);
      final fresh = await store.all();
      expect(fresh.single.toJson(), next.toJson());
    },
  );

  test(
    'malformed bulk row still fails and does not poison later reads',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'aw-malformed-v2-store-',
      );
      final worker = DownloadPersistenceWorker.forDirectory(root.path);
      addTearDown(() async {
        await worker.close();
        await root.delete(recursive: true);
      });
      final store = HiveLogicalDownloadStoreV2(worker: worker);
      final record = fixtureRecord();
      await store.put(record);
      await worker.run('hive.put', [
        kLogicalDownloadStoreV2Box,
        'bad-key',
        {0: 'not a string key'},
      ]);
      await expectLater(store.all(), throwsA(isA<TypeError>()));
      await worker.run('hive.delete', [kLogicalDownloadStoreV2Box, 'bad-key']);
      expect((await store.all()).single.toJson(), record.toJson());
    },
  );
}
