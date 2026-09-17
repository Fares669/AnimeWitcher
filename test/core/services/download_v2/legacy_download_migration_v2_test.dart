import 'dart:async';
import 'dart:io';

import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/download_v2/download_manager_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/core/services/download_v2/legacy_download_migration_v2.dart';
import 'package:animewitcher/core/services/download_v2/logical_download_store_v2.dart';
import 'package:flutter_test/flutter_test.dart';

import 'download_v2_test_support.dart';

void main() {
  test('completed legacy file stays available and creates zero transfers', () async {
    final directory = await Directory.systemTemp.createTemp('aw-v2-legacy-complete-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/episode-12.mp4');
    await file.writeAsBytes(<int>[1, 2, 3, 4]);

    final store = InMemoryLogicalDownloadStoreV2();
    final migration = LegacyDownloadMigrationV2(store: store, nowMillis: () => 200);
    final item = _legacyItem(destinationPath: file.path, completedAtMillis: 150);

    final migrated = await migration.migrate(item);

    expect(migrated.completedAtMillis, 150);
    expect(migrated.destinationPath, file.path);
    expect(await file.exists(), isTrue);

    final gateway = _MigrationGateway();
    final resolver = StaticSourceResolverV2(expectedBytes: 4);
    final manager = DownloadManagerV2(
      store: store,
      gateway: gateway,
      sourceResolver: resolver,
    );

    await manager.initialize();

    expect(gateway.startedSpecs, isEmpty);
    expect(resolver.calls, 0);
    expect(
      manager.snapshotFor(item.logicalId)?.status,
      DownloadTransportStatus.complete,
    );
  });

  test('incomplete legacy item stays offline until explicit resume', () async {
    final store = InMemoryLogicalDownloadStoreV2();
    final migration = LegacyDownloadMigrationV2(store: store, nowMillis: () => 200);
    final item = _legacyItem(destinationPath: '/tmp/episode-12.mp4');

    final migrated = await migration.migrate(item);

    expect(migrated.completedAtMillis, isNull);
    expect(migrated.intent, DownloadUserIntent.paused);
    expect(migrated.generation, 1);

    final gateway = _MigrationGateway();
    final resolver = StaticSourceResolverV2(expectedBytes: 100);
    final manager = DownloadManagerV2(
      store: store,
      gateway: gateway,
      sourceResolver: resolver,
    );

    await manager.initialize();

    expect(gateway.startedSpecs, isEmpty);
    expect(resolver.calls, 0);
    expect(manager.snapshotFor(item.logicalId)?.status, DownloadTransportStatus.paused);

    await manager.resume(item.logicalId);

    expect(gateway.startedSpecs, hasLength(1));
    expect(resolver.calls, 1);
    expect(gateway.startedSpecs.single.taskId, taskIdForGeneration(item.logicalId, 2));
    expect((await store.get(item.logicalId))?.generation, 2);
  });

  test('restart-required legacy row stays visible until explicit resume', () async {
    final store = InMemoryLogicalDownloadStoreV2();
    final migration = LegacyDownloadMigrationV2(
      store: store,
      nowMillis: () => 200,
    );
    final item = _legacyItem(
      destinationPath: '/tmp/episode-12-restart.mp4',
      sourceDescriptor: legacyRestartRequiredSourceDescriptorV2(
        trackingUrl: '/anime/21/12',
        providerId: 'provider.example',
        sourceHint: 'server-a',
        quality: '1080p',
      ),
    );

    final migrated = await migration.migrate(item);
    expect(migrated.intent, DownloadUserIntent.paused);
    expect(
      sourceDescriptorRequiresLegacyRestartV2(migrated.sourceDescriptor),
      isTrue,
    );

    final gateway = _MigrationGateway();
    final resolver = StaticSourceResolverV2(expectedBytes: 100);
    final manager = DownloadManagerV2(
      store: store,
      gateway: gateway,
      sourceResolver: resolver,
    );

    await manager.initialize();

    expect(gateway.startedSpecs, isEmpty);
    expect(resolver.calls, 0);
    expect(
      manager.snapshotFor(item.logicalId)?.status,
      DownloadTransportStatus.paused,
    );

    await manager.resume(item.logicalId);

    expect(gateway.startedSpecs, hasLength(1));
    expect(resolver.calls, 1);
    expect(
      gateway.startedSpecs.single.taskId,
      taskIdForGeneration(item.logicalId, 2),
    );
  });

  test('migration is presentation-only and never serializes legacy transport state', () async {
    final store = InMemoryLogicalDownloadStoreV2();
    final migration = LegacyDownloadMigrationV2(store: store, nowMillis: () => 200);

    final record = await migration.migrate(
      _legacyItem(destinationPath: '/tmp/episode-12.mp4'),
    );
    final json = record.toJson();
    final serialized = json.toString().toLowerCase();

    for (final forbidden in <String>[
      'chunkid',
      'range',
      'resume',
      'durablebytes',
      'nativeowner',
      'persistentparalleldownload',
      'downloadrangetransfer',
    ]) {
      expect(serialized, isNot(contains(forbidden)));
    }
  });

  test('existing v2 record wins over a later legacy migration pass', () async {
    final store = InMemoryLogicalDownloadStoreV2();
    final item = _legacyItem(destinationPath: '/tmp/episode-12.mp4');
    final existing = LogicalDownloadRecordV2(
      schemaVersion: kLogicalDownloadSchemaVersionV2,
      logicalId: item.logicalId,
      animeId: item.animeId,
      episodeKey: item.episodeKey,
      variantKey: item.variantKey,
      generation: 4,
      taskId: taskIdForGeneration(item.logicalId, 4),
      intent: DownloadUserIntent.active,
      destinationPath: '/tmp/v2-owned.mp4',
      sourceDescriptor: const <String, Object?>{'providerId': 'v2'},
      updatedAtMillis: 180,
    );
    await store.put(existing);

    final migration = LegacyDownloadMigrationV2(store: store, nowMillis: () => 200);
    final result = await migration.migrate(item);

    expect(result.generation, 4);
    expect(result.destinationPath, '/tmp/v2-owned.mp4');
    expect(result.sourceDescriptor['providerId'], 'v2');
  });
}

LegacyDownloadPresentationV2 _legacyItem({
  required String destinationPath,
  int? completedAtMillis,
  Map<String, Object?>? sourceDescriptor,
}) {
  final logicalId = logicalDownloadIdFor(
    animeId: 'anilist:21',
    episodeKey: '12',
    variantKey: 'sub:1080p',
  );
  return LegacyDownloadPresentationV2(
    logicalId: logicalId,
    animeId: 'anilist:21',
    episodeKey: '12',
    variantKey: 'sub:1080p',
    destinationPath: destinationPath,
    sourceDescriptor: sourceDescriptor ??
        const <String, Object?>{
          'providerId': 'provider.example',
          'trackingUrl': '/anime/21/12',
          'quality': '1080p',
        },
    completedAtMillis: completedAtMillis,
  );
}

final class _MigrationGateway implements BackgroundDownloaderGateway {
  final List<DownloadTaskSpecV2> startedSpecs = <DownloadTaskSpecV2>[];
  final Map<String, _MigrationHandle> _handles = <String, _MigrationHandle>{};

  @override
  Future<void> initialize() async {}

  @override
  Future<DownloadTransportHandle> start(DownloadTaskSpecV2 spec) async {
    startedSpecs.add(spec);
    final handle = _MigrationHandle(
      DownloadTransportSnapshot(
        taskId: spec.taskId,
        status: DownloadTransportStatus.running,
        progress: 0,
      ),
    );
    _handles[spec.taskId] = handle;
    return handle;
  }

  @override
  Future<DownloadTransportHandle?> attach(String taskId) async => _handles[taskId];

  @override
  Future<List<DownloadTransportHandle>> rehydrate() async =>
      _handles.values.toList(growable: false);

  @override
  Future<void> removeTracking(String taskId) async {
    _handles.remove(taskId);
  }
}

final class _MigrationHandle implements DownloadTransportHandle {
  _MigrationHandle(this._current);

  DownloadTransportSnapshot _current;
  final StreamController<DownloadTransportSnapshot> _snapshots =
      StreamController<DownloadTransportSnapshot>.broadcast(sync: true);

  @override
  String get taskId => _current.taskId;

  @override
  DownloadTransportSnapshot get current => _current;

  @override
  Stream<DownloadTransportSnapshot> get snapshots => _snapshots.stream;

  @override
  Future<bool> pause() async => true;

  @override
  Future<bool> resume() async => true;

  @override
  Future<bool> cancel() async => true;
}
