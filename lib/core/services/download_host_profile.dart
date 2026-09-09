import 'package:hive_flutter/hive_flutter.dart';

import 'download_connection_governor.dart';
import 'download_parallel.dart';

const String kDownloadHostProfileBox = 'download_host_profiles_v1';
const Duration kDownloadHostProfileTtl = Duration(hours: 6);
const Duration kDownloadHostCircuitOpenDuration = Duration(minutes: 2);
const int kDownloadHostCircuitPressureThreshold = 3;
const double kDownloadUsefulThroughputGain = 0.08;

class DownloadHostProfile {
  const DownloadHostProfile({
    required this.origin,
    required this.safeConnectionCeiling,
    required this.bestConnections,
    required this.bestBytesPerSecond,
    required this.maxSuccessfulConnectMicros,
    required this.consecutivePressure,
    required this.updatedAtMillis,
    this.circuitOpenUntilMillis = 0,
  });

  final String origin;
  final int safeConnectionCeiling;
  final int bestConnections;
  final double bestBytesPerSecond;
  final int maxSuccessfulConnectMicros;
  final int consecutivePressure;
  final int updatedAtMillis;
  final int circuitOpenUntilMillis;

  bool isExpiredAt(DateTime now) =>
      now.millisecondsSinceEpoch - updatedAtMillis >
      kDownloadHostProfileTtl.inMilliseconds;

  bool circuitIsOpenAt(DateTime now) =>
      circuitOpenUntilMillis > now.millisecondsSinceEpoch;

  int connectionCeilingAt(DateTime now, {required int requested}) {
    final safeRequested = requested
        .clamp(kDownloadPartsMin, kDownloadGlobalConnectionBudget)
        .toInt();
    if (isExpiredAt(now)) return safeRequested;
    if (circuitIsOpenAt(now)) return 1;
    return safeConnectionCeiling.clamp(1, safeRequested).toInt();
  }

  Map<String, Object> toJson() => <String, Object>{
    'origin': origin,
    'safeConnectionCeiling': safeConnectionCeiling,
    'bestConnections': bestConnections,
    'bestBytesPerSecond': bestBytesPerSecond,
    'maxSuccessfulConnectMicros': maxSuccessfulConnectMicros,
    'consecutivePressure': consecutivePressure,
    'updatedAtMillis': updatedAtMillis,
    'circuitOpenUntilMillis': circuitOpenUntilMillis,
  };

  static DownloadHostProfile? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final map = Map<String, dynamic>.from(raw);
    final origin = (map['origin'] ?? '').toString().trim();
    if (origin.isEmpty) return null;
    final safe = _asInt(map['safeConnectionCeiling'], fallback: 1)
        .clamp(kDownloadPartsMin, kDownloadGlobalConnectionBudget)
        .toInt();
    return DownloadHostProfile(
      origin: origin,
      safeConnectionCeiling: safe,
      bestConnections: _asInt(map['bestConnections'], fallback: safe)
          .clamp(kDownloadPartsMin, kDownloadGlobalConnectionBudget)
          .toInt(),
      bestBytesPerSecond: _asDouble(map['bestBytesPerSecond']),
      maxSuccessfulConnectMicros: _asInt(map['maxSuccessfulConnectMicros']),
      consecutivePressure: _asInt(map['consecutivePressure']),
      updatedAtMillis: _asInt(map['updatedAtMillis']),
      circuitOpenUntilMillis: _asInt(map['circuitOpenUntilMillis']),
    );
  }
}

abstract interface class DownloadHostProfileBackend {
  Future<Map<String, dynamic>?> read(String origin);
  Future<void> write(String origin, Map<String, Object> value);
  Future<void> delete(String origin);
  Future<List<Map<String, dynamic>>> readAll();
}

class HiveDownloadHostProfileBackend implements DownloadHostProfileBackend {
  const HiveDownloadHostProfileBackend({this.boxName = kDownloadHostProfileBox});

  final String boxName;

  Future<Box<dynamic>> _box() => Hive.openBox<dynamic>(boxName);

  @override
  Future<Map<String, dynamic>?> read(String origin) async {
    final raw = (await _box()).get(origin);
    return raw is Map ? Map<String, dynamic>.from(raw) : null;
  }

  @override
  Future<void> write(String origin, Map<String, Object> value) async {
    await (await _box()).put(origin, value);
  }

  @override
  Future<void> delete(String origin) async {
    await (await _box()).delete(origin);
  }

  @override
  Future<List<Map<String, dynamic>>> readAll() async {
    final box = await _box();
    return <Map<String, dynamic>>[
      for (final raw in box.values)
        if (raw is Map) Map<String, dynamic>.from(raw),
    ];
  }
}

class DownloadHostProfileStore {
  DownloadHostProfileStore(this.backend, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final DownloadHostProfileBackend backend;
  final DateTime Function() _now;

  Future<DownloadHostProfile?> getForUrl(String url) async {
    final origin = downloadOriginKey(url);
    final profile = DownloadHostProfile.fromJson(await backend.read(origin));
    if (profile == null) return null;
    if (profile.isExpiredAt(_now())) {
      await backend.delete(origin);
      return null;
    }
    return profile;
  }

  Future<Map<String, int>> validHostCeilings() async {
    final now = _now();
    final result = <String, int>{};
    for (final raw in await backend.readAll()) {
      final profile = DownloadHostProfile.fromJson(raw);
      if (profile == null) continue;
      if (profile.isExpiredAt(now)) {
        await backend.delete(profile.origin);
        continue;
      }
      result[profile.origin] = profile.connectionCeilingAt(
        now,
        requested: kDownloadGlobalConnectionBudget,
      );
    }
    return result;
  }

  Future<DownloadHostProfile> recordSuccess({
    required String url,
    required int activeConnections,
    required double bytesPerSecond,
    Duration? connectTime,
  }) async {
    final now = _now();
    final origin = downloadOriginKey(url);
    final previous = await getForUrl(url);
    final connections = activeConnections
        .clamp(kDownloadPartsMin, kDownloadGlobalConnectionBudget)
        .toInt();
    final throughput = bytesPerSecond < 0 ? 0.0 : bytesPerSecond;

    var bestConnections = previous?.bestConnections ?? connections;
    var bestThroughput = previous?.bestBytesPerSecond ?? 0.0;
    var safeCeiling = previous?.safeConnectionCeiling ?? connections;

    if (bestThroughput <= 0 ||
        throughput > bestThroughput * (1 + kDownloadUsefulThroughputGain)) {
      bestConnections = connections;
      bestThroughput = throughput;
      if (connections > safeCeiling) safeCeiling = connections;
    } else if (connections > bestConnections && throughput > 0) {
      // More sockets added less than 8% throughput: remember the cheaper level.
      safeCeiling = safeCeiling.clamp(1, bestConnections).toInt();
    }

    final connectMicros = connectTime?.inMicroseconds ?? 0;
    final profile = DownloadHostProfile(
      origin: origin,
      safeConnectionCeiling: safeCeiling,
      bestConnections: bestConnections,
      bestBytesPerSecond: bestThroughput,
      maxSuccessfulConnectMicros: connectMicros >
              (previous?.maxSuccessfulConnectMicros ?? 0)
          ? connectMicros
          : (previous?.maxSuccessfulConnectMicros ?? 0),
      consecutivePressure: 0,
      circuitOpenUntilMillis: 0,
      updatedAtMillis: now.millisecondsSinceEpoch,
    );
    await backend.write(origin, profile.toJson());
    return profile;
  }

  Future<DownloadHostProfile> recordPressure({
    required String url,
    required int fallbackCeiling,
  }) async {
    final now = _now();
    final origin = downloadOriginKey(url);
    final previous = await getForUrl(url);
    final pressure = (previous?.consecutivePressure ?? 0) + 1;
    final fallback = fallbackCeiling
        .clamp(kDownloadPartsMin, kDownloadGlobalConnectionBudget)
        .toInt();
    final safeCeiling = previous == null
        ? fallback
        : (fallback < previous.safeConnectionCeiling
              ? fallback
              : previous.safeConnectionCeiling);
    final openCircuit = pressure >= kDownloadHostCircuitPressureThreshold;
    final profile = DownloadHostProfile(
      origin: origin,
      safeConnectionCeiling: safeCeiling,
      bestConnections: previous?.bestConnections ?? safeCeiling,
      bestBytesPerSecond: previous?.bestBytesPerSecond ?? 0,
      maxSuccessfulConnectMicros:
          previous?.maxSuccessfulConnectMicros ?? 0,
      consecutivePressure: pressure,
      circuitOpenUntilMillis: openCircuit
          ? now.add(kDownloadHostCircuitOpenDuration).millisecondsSinceEpoch
          : (previous?.circuitOpenUntilMillis ?? 0),
      updatedAtMillis: now.millisecondsSinceEpoch,
    );
    await backend.write(origin, profile.toJson());
    return profile;
  }
}

int _asInt(Object? value, {int fallback = 0}) {
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? fallback;
}

double _asDouble(Object? value) {
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '') ?? 0.0;
}
