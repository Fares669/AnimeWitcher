import 'package:hive_flutter/hive_flutter.dart';

import 'download_v2_identity.dart';
import 'download_v2_models.dart';

const String kLogicalDownloadStoreV2Box = 'logical_download_store_v2';

abstract interface class LogicalDownloadStoreV2 {
  Future<LogicalDownloadRecordV2?> get(DownloadLogicalId id);

  Future<List<LogicalDownloadRecordV2>> all();

  Future<void> put(LogicalDownloadRecordV2 record);

  Future<void> remove(DownloadLogicalId id);

  /// Atomically applies an application-owned metadata mutation for one logical
  /// download. Returning null removes the record.
  Future<LogicalDownloadRecordV2?> mutate(
    DownloadLogicalId id,
    LogicalDownloadRecordV2? Function(LogicalDownloadRecordV2? current) change,
  );
}

/// Test store that persists the same serialized payload shape used by Hive.
///
/// Supplying a shared [backend] lets tests model manager/store recreation
/// without bypassing serialization by retaining record objects directly.
final class InMemoryLogicalDownloadStoreV2 implements LogicalDownloadStoreV2 {
  InMemoryLogicalDownloadStoreV2([Map<String, Object?>? backend])
    : _backend = backend ?? <String, Object?>{};

  final Map<String, Object?> _backend;
  final _mutations = _LogicalMutationQueue();

  @override
  Future<LogicalDownloadRecordV2?> get(DownloadLogicalId id) async {
    return LogicalDownloadRecordV2.fromJson(_backend[id.value]);
  }

  @override
  Future<List<LogicalDownloadRecordV2>> all() async {
    final records = <LogicalDownloadRecordV2>[];
    for (final raw in _backend.values) {
      final record = LogicalDownloadRecordV2.fromJson(raw);
      if (record != null) records.add(record);
    }
    return records;
  }

  @override
  Future<void> put(LogicalDownloadRecordV2 record) async {
    _backend[record.logicalId.value] = Map<String, Object?>.from(
      record.toJson(),
    );
  }

  @override
  Future<void> remove(DownloadLogicalId id) async {
    _backend.remove(id.value);
  }

  @override
  Future<LogicalDownloadRecordV2?> mutate(
    DownloadLogicalId id,
    LogicalDownloadRecordV2? Function(LogicalDownloadRecordV2? current) change,
  ) {
    return _mutations.run(id.value, () async {
      final current = await get(id);
      final next = change(current);
      if (next == null) {
        await remove(id);
        return null;
      }
      _requireSameLogicalId(id, next);
      await put(next);
      return next;
    });
  }
}

/// Durable AnimeWitcher-owned metadata store for V2 downloads.
///
/// This box is intentionally independent from the legacy download JobStore and
/// from background_downloader's database. Values contain only
/// [LogicalDownloadRecordV2.toJson] application metadata.
final class HiveLogicalDownloadStoreV2 implements LogicalDownloadStoreV2 {
  HiveLogicalDownloadStoreV2({this.boxName = kLogicalDownloadStoreV2Box});

  final String boxName;
  final _mutations = _LogicalMutationQueue();

  Future<Box<dynamic>> _box() => Hive.openBox<dynamic>(boxName);

  @override
  Future<LogicalDownloadRecordV2?> get(DownloadLogicalId id) async {
    final raw = (await _box()).get(id.value);
    return LogicalDownloadRecordV2.fromJson(raw);
  }

  @override
  Future<List<LogicalDownloadRecordV2>> all() async {
    final box = await _box();
    final records = <LogicalDownloadRecordV2>[];
    for (final raw in box.values) {
      final record = LogicalDownloadRecordV2.fromJson(raw);
      if (record != null) records.add(record);
    }
    return records;
  }

  @override
  Future<void> put(LogicalDownloadRecordV2 record) async {
    await (await _box()).put(
      record.logicalId.value,
      Map<String, Object?>.from(record.toJson()),
    );
  }

  @override
  Future<void> remove(DownloadLogicalId id) async {
    await (await _box()).delete(id.value);
  }

  @override
  Future<LogicalDownloadRecordV2?> mutate(
    DownloadLogicalId id,
    LogicalDownloadRecordV2? Function(LogicalDownloadRecordV2? current) change,
  ) {
    return _mutations.run(id.value, () async {
      final current = await get(id);
      final next = change(current);
      if (next == null) {
        await remove(id);
        return null;
      }
      _requireSameLogicalId(id, next);
      await put(next);
      return next;
    });
  }
}

void _requireSameLogicalId(
  DownloadLogicalId requested,
  LogicalDownloadRecordV2 next,
) {
  if (next.logicalId != requested) {
    throw ArgumentError.value(
      next.logicalId.value,
      'next.logicalId',
      'A store mutation cannot move a record to another logical ID',
    );
  }
}

final class _LogicalMutationQueue {
  final Map<String, Future<void>> _tails = <String, Future<void>>{};

  Future<T> run<T>(String key, Future<T> Function() action) {
    final previous = _tails[key] ?? Future<void>.value();
    final result = previous.catchError((_) {}).then((_) => action());
    final barrier = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    _tails[key] = barrier;
    return result.whenComplete(() {
      if (identical(_tails[key], barrier)) {
        _tails.remove(key);
      }
    });
  }
}
