import 'package:animewitcher/core/services/download_host_profile.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryBackend implements DownloadHostProfileBackend {
  final Map<String, Map<String, dynamic>> values = {};

  @override
  Future<void> delete(String origin) async => values.remove(origin);

  @override
  Future<List<Map<String, dynamic>>> readAll() async => values.values
      .map((value) => Map<String, dynamic>.from(value))
      .toList(growable: false);

  @override
  Future<Map<String, dynamic>?> read(String origin) async {
    final value = values[origin];
    return value == null ? null : Map<String, dynamic>.from(value);
  }

  @override
  Future<void> write(String origin, Map<String, Object> value) async {
    values[origin] = Map<String, dynamic>.from(value);
  }
}

void main() {
  late DateTime now;
  late _MemoryBackend backend;
  late DownloadHostProfileStore store;

  setUp(() {
    now = DateTime.utc(2026, 9, 9, 8);
    backend = _MemoryBackend();
    store = DownloadHostProfileStore(backend, now: () => now);
  });

  test('meaningful throughput gain allows a higher useful ceiling', () async {
    await store.recordSuccess(
      url: 'https://cdn.test/a.mp4',
      activeConnections: 2,
      bytesPerSecond: 10 * 1024 * 1024,
    );
    final profile = await store.recordSuccess(
      url: 'https://cdn.test/b.mp4',
      activeConnections: 4,
      bytesPerSecond: 13 * 1024 * 1024,
    );

    expect(profile.bestConnections, 4);
    expect(profile.safeConnectionCeiling, 4);
  });

  test('extra sockets with less than 8 percent gain keep cheaper level', () async {
    await store.recordSuccess(
      url: 'https://cdn.test/a.mp4',
      activeConnections: 4,
      bytesPerSecond: 20 * 1024 * 1024,
    );
    final profile = await store.recordSuccess(
      url: 'https://cdn.test/b.mp4',
      activeConnections: 8,
      bytesPerSecond: 21 * 1024 * 1024,
    );

    expect(profile.bestConnections, 4);
    expect(profile.safeConnectionCeiling, 4);
  });

  test('three pressure signals open a temporary one-connection circuit', () async {
    for (var i = 0; i < 3; i++) {
      await store.recordPressure(
        url: 'https://cdn.test/a.mp4',
        fallbackCeiling: 4,
      );
    }

    final profile = await store.getForUrl('https://cdn.test/next.mp4');
    expect(profile, isNotNull);
    expect(profile!.circuitIsOpenAt(now), isTrue);
    expect(profile.connectionCeilingAt(now, requested: 16), 1);
  });

  test('successful transfer closes circuit and resets pressure', () async {
    for (var i = 0; i < 3; i++) {
      await store.recordPressure(
        url: 'https://cdn.test/a.mp4',
        fallbackCeiling: 2,
      );
    }
    final recovered = await store.recordSuccess(
      url: 'https://cdn.test/b.mp4',
      activeConnections: 2,
      bytesPerSecond: 5 * 1024 * 1024,
      connectTime: const Duration(milliseconds: 180),
    );

    expect(recovered.consecutivePressure, 0);
    expect(recovered.circuitOpenUntilMillis, 0);
    expect(recovered.maxSuccessfulConnectMicros, 180000);
  });

  test('expired profiles are discarded instead of throttling forever', () async {
    await store.recordPressure(
      url: 'https://cdn.test/a.mp4',
      fallbackCeiling: 2,
    );
    now = now.add(kDownloadHostProfileTtl + const Duration(seconds: 1));

    expect(await store.getForUrl('https://cdn.test/b.mp4'), isNull);
    expect(backend.values, isEmpty);
  });

  test('validHostCeilings returns origin-scoped persisted cap', () async {
    await store.recordPressure(
      url: 'https://cdn.test/a.mp4',
      fallbackCeiling: 3,
    );

    expect(await store.validHostCeilings(), {'https://cdn.test': 3});
  });
}
