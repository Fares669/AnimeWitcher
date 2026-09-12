import 'package:animewitcher/core/services/download_url_refresh.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryBackend implements DownloadUrlRefreshBackend {
  final Map<String, Map<String, Object?>> rows = {};

  @override
  Future<Map<String, dynamic>?> read(String key) async {
    final value = rows[key];
    return value == null ? null : Map<String, dynamic>.from(value);
  }

  @override
  Future<void> write(String key, Map<String, Object?> value) async {
    rows[key] = Map<String, Object?>.from(value);
  }

  @override
  Future<void> delete(String key) async {
    rows.remove(key);
  }
}

DownloadUrlRefreshDescriptor descriptor(int generation) =>
    DownloadUrlRefreshDescriptor(
      trackingUrl: 'episode-1',
      providerId: 'provider',
      source: 'server-a',
      updatedAtMillis: 100 + generation,
      generation: generation,
    );

void main() {
  test('newer generation cannot be overwritten by an older start', () async {
    final store = DownloadUrlRefreshStore(_MemoryBackend());

    expect(await store.save(descriptor(4)), isTrue);
    expect(await store.save(descriptor(3)), isFalse);
    expect((await store.get('episode-1'))!.generation, 4);
  });

  test('stale generation cannot delete a newer descriptor', () async {
    final store = DownloadUrlRefreshStore(_MemoryBackend());

    expect(await store.save(descriptor(7)), isTrue);
    expect(await store.removeForGeneration('episode-1', 6), isFalse);
    expect((await store.get('episode-1'))!.generation, 7);
    expect(await store.removeForGeneration('episode-1', 7), isTrue);
    expect(await store.get('episode-1'), isNull);
  });

  test('legacy descriptor deserializes as generation zero', () {
    final legacy = descriptor(3).toJson()..remove('generation');
    expect(DownloadUrlRefreshDescriptor.fromJson(legacy)!.generation, 0);
  });
}
