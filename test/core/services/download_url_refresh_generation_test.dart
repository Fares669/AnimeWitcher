import 'package:animewitcher/core/services/download_url_refresh.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryBackend implements DownloadUrlRefreshBackend {
  _MemoryBackend({this.throwOnWrite = false});

  final bool throwOnWrite;
  final Map<String, Map<String, Object?>> rows = {};

  @override
  Future<Map<String, dynamic>?> read(String key) async {
    final value = rows[key];
    return value == null ? null : Map<String, dynamic>.from(value);
  }

  @override
  Future<void> write(String key, Map<String, Object?> value) async {
    if (throwOnWrite) {
      throw StateError('injected descriptor-store write failure');
    }
    rows[key] = Map<String, Object?>.from(value);
  }

  @override
  Future<void> delete(String key) async {
    rows.remove(key);
  }
}

final _baseUpdatedAtMillis = DateTime.now().millisecondsSinceEpoch;

DownloadUrlRefreshDescriptor descriptor(
  int generation, {
  String ownerTaskId = 'task-a',
  String logicalId = 'episode-logical-1',
}) => DownloadUrlRefreshDescriptor(
  trackingUrl: 'episode-1',
  providerId: 'provider',
  source: 'server-a',
  updatedAtMillis: _baseUpdatedAtMillis + generation,
  generation: generation,
  ownerTaskId: ownerTaskId,
  logicalId: logicalId,
);

void main() {
  test('newer generation cannot be overwritten by an older start', () async {
    final store = DownloadUrlRefreshStore(_MemoryBackend());

    expect(await store.claimOwnership(descriptor(0)), isTrue);
    expect(await store.save(descriptor(4)), isTrue);
    expect(await store.save(descriptor(3)), isFalse);
    expect((await store.get('episode-1'))!.generation, 4);
  });

  test('stale generation cannot delete a newer descriptor', () async {
    final store = DownloadUrlRefreshStore(_MemoryBackend());

    expect(await store.claimOwnership(descriptor(0)), isTrue);
    expect(await store.save(descriptor(7)), isTrue);
    expect(
      await store.removeForOwnerGeneration('episode-1', 'task-a', 6),
      isFalse,
    );
    expect((await store.get('episode-1'))!.generation, 7);
    expect(
      await store.removeForOwnerGeneration('episode-1', 'task-a', 7),
      isTrue,
    );
    expect(await store.get('episode-1'), isNull);
  });

  test('old task cannot overwrite or delete a newer task owner', () async {
    final store = DownloadUrlRefreshStore(_MemoryBackend());

    expect(await store.claimOwnership(descriptor(8)), isTrue);
    expect(
      await store.claimOwnership(descriptor(0, ownerTaskId: 'task-b')),
      isTrue,
    );

    // A task-local generation can reset for the new task. Once task B owns
    // the descriptor, delayed writes/removals from task A must be fenced even
    // when task A carries a numerically larger generation.
    expect(await store.save(descriptor(99)), isFalse);
    expect(
      await store.removeForOwnerGeneration('episode-1', 'task-a', 99),
      isFalse,
    );

    final current = await store.get('episode-1');
    expect(current, isNotNull);
    expect(current!.ownerTaskId, 'task-b');
    expect(current.generation, 0);
  });

  test('same owner can advance but cannot regress its generation', () async {
    final store = DownloadUrlRefreshStore(_MemoryBackend());

    expect(await store.claimOwnership(descriptor(0)), isTrue);
    expect(await store.save(descriptor(2)), isTrue);
    expect(await store.save(descriptor(1)), isFalse);
    expect((await store.get('episode-1'))!.generation, 2);
  });

  test('ownership metadata round trips and legacy records remain readable', () {
    final owned = descriptor(3);
    final restored = DownloadUrlRefreshDescriptor.fromJson(owned.toJson());
    expect(restored, isNotNull);
    expect(restored!.ownerTaskId, 'task-a');
    expect(restored.logicalId, 'episode-logical-1');
    expect(restored.generation, 3);

    final legacy = owned.toJson()
      ..remove('generation')
      ..remove('ownerTaskId')
      ..remove('logicalId');
    final legacyRestored = DownloadUrlRefreshDescriptor.fromJson(legacy);
    expect(legacyRestored, isNotNull);
    expect(legacyRestored!.generation, 0);
    expect(legacyRestored.ownerTaskId, isNull);
    expect(legacyRestored.logicalId, isNull);
  });

  test('descriptor-store write failure is surfaced to the start owner', () async {
    final backend = _MemoryBackend(throwOnWrite: true);
    final store = DownloadUrlRefreshStore(backend);

    await expectLater(
      store.claimOwnership(descriptor(0)),
      throwsA(isA<StateError>()),
    );
    expect(await store.get('episode-1'), isNull);
  });
}
