import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/core/services/download_v2/logical_download_store_v2.dart';
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
      animeId: 'anilist:21',
      episodeKey: '12',
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

  test('store round-trips logical metadata without transport internals', () async {
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
      'chunk',
      'range',
      'resumebytes',
      'ownership',
      'retryremaining',
      'holdreason',
    ]) {
      expect(serializedKeys, isNot(contains(forbidden)));
    }
  });

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

  test('mutate updates one logical record without changing its identity', () async {
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
  });

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
      animeId: 'anilist:21',
      episodeKey: '13',
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
}
