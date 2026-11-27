import 'dart:io';

import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/download_v2/download_manager_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/core/services/download_v2/logical_download_store_v2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
// Override the platform facade so no filesystem fixture escapes its directory.
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'download_v2_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'oldest canonical owner wins across the startup worker chunks',
    () async {
      final fixture = await _fixture();
      final folder = p.join(fixture.root.path, 'missing', 'series');
      final oldest = _row(0, p.join(folder, 'episode.mp4'));
      final duplicate = _row(
        68,
        '$folder${p.separator}.${p.separator}episode.mp4',
        intent: DownloadUserIntent.active,
      );
      // Reverse store insertion order to prove the durable age ordering.
      await fixture.store.put(duplicate);
      for (var i = 67; i >= 1; i--) {
        await fixture.store.put(_row(i, p.join(folder, 'episode-$i.mp4')));
      }
      await fixture.store.put(oldest);

      final rows = await fixture.manager.records.first;
      await fixture.manager.initialize();
      expect(rows, hasLength(69));
      expect((await fixture.store.get(oldest.logicalId))?.updatedAtMillis, 1);
      expect(
        (await fixture.store.get(duplicate.logicalId))?.intent,
        DownloadUserIntent.paused,
      );
      expect(
        fixture.manager.snapshotFor(duplicate.logicalId)?.status,
        DownloadTransportStatus.paused,
      );
      expect(fixture.resolver.calls, 0);
    },
  );

  test(
    'symlink aliases share one owner and a loop fails only its own row',
    () async {
      final fixture = await _fixture();
      final real = await Directory(p.join(fixture.root.path, 'real')).create();
      final alias = await Link(p.join(fixture.root.path, 'alias'))
          .create(real.path);
      final loop = Link(p.join(fixture.root.path, 'loop'));
      await loop.create(loop.path);
      final oldest = _row(0, p.join(real.path, 'missing', 'episode.mp4'));
      final invalid = _row(1, loop.path);
      final duplicate = _row(
        2,
        p.join(alias.path, 'missing', 'episode.mp4'),
        intent: DownloadUserIntent.active,
      );
      final independent = _row(3, p.join(real.path, 'other.mp4'));
      for (final row in [oldest, invalid, duplicate, independent]) {
        await fixture.store.put(row);
      }

      final rows = await fixture.manager.records.first;
      await fixture.manager.initialize();
      expect(rows, hasLength(4));
      final saved = await fixture.store.get(invalid.logicalId);
      expect(saved?.intent, DownloadUserIntent.paused);
      expect(saved?.failureMessage, contains('FileSystemException'));
      expect(saved?.failureMessage, contains(loop.path));
      expect(
        fixture.manager.snapshotFor(invalid.logicalId)?.status,
        DownloadTransportStatus.failed,
      );
      expect(
        fixture.manager.snapshotFor(duplicate.logicalId)?.status,
        DownloadTransportStatus.paused,
      );
      expect(
        (await fixture.store.get(independent.logicalId))?.failureMessage,
        isNull,
      );
      expect(fixture.resolver.calls, 0);
    },
    skip: Platform.isWindows ? 'Fixture needs unprivileged symlinks' : false,
  );

  test(
    'delete resolves a retargeted symlink after startup to preserve its owner',
    () async {
      final fixture = await _fixture();
      final ownerDir = await Directory(p.join(fixture.root.path, 'owner'))
          .create();
      final unrelated = await Directory(p.join(fixture.root.path, 'unrelated'))
          .create();
      final aliased = await Link(p.join(fixture.root.path, 'alias'))
          .create(unrelated.path);
      final owner = await File(p.join(ownerDir.path, 'episode.mp4'))
          .writeAsString('owned actual artifact');
      final saved = _row(0, owner.path);
      final removed = _row(1, p.join(aliased.path, 'episode.mp4'));
      for (final row in [saved, removed]) {
        await fixture.store.put(row);
      }
      await fixture.manager.initialize();

      await aliased.update(ownerDir.path);
      await fixture.manager.delete(removed.logicalId);

      expect(await owner.readAsString(), 'owned actual artifact');
      expect(await fixture.store.get(saved.logicalId), isNotNull);
      expect(await fixture.store.get(removed.logicalId), isNull);
    },
    skip: Platform.isWindows ? 'Fixture needs unprivileged symlinks' : false,
  );
}

LogicalDownloadRecordV2 _row(
  int index,
  String path, {
  DownloadUserIntent intent = DownloadUserIntent.paused,
}) {
  final logicalId = logicalDownloadIdFor(
    animeId: 'offline-episode',
    episodeKey: '$index',
    variantKey: 'source',
  );
  return LogicalDownloadRecordV2(
    schemaVersion: kLogicalDownloadSchemaVersionV2,
    logicalId: logicalId,
    mediaId: 'offline-episode',
    unitKey: '$index',
    variantKey: 'source',
    generation: 1,
    taskId: taskIdForGeneration(logicalId, 1),
    intent: intent,
    destinationPath: path,
    sourceDescriptor: const {'providerId': 'fixture-only'},
    updatedAtMillis: index + 1,
  );
}

Future<
  ({
    Directory root,
    InMemoryLogicalDownloadStoreV2 store,
    DownloadManagerV2 manager,
    StaticSourceResolverV2 resolver,
  })
>
_fixture() async {
  final root = await Directory.systemTemp.createTemp('aw-path-batch-');
  final platform = PathProviderPlatform.instance;
  PathProviderPlatform.instance = _FixturePaths(root.path);
  final store = InMemoryLogicalDownloadStoreV2();
  final resolver = StaticSourceResolverV2();
  final manager = DownloadManagerV2(
    store: store,
    gateway: _NoTransferGateway(),
    sourceResolver: resolver,
    nowMillis: () => 1000000,
  );
  addTearDown(() async {
    await manager.dispose();
    PathProviderPlatform.instance = platform;
    await root.delete(recursive: true);
  });
  return (root: root, store: store, manager: manager, resolver: resolver);
}

final class _FixturePaths extends PathProviderPlatform {
  _FixturePaths(this.path);
  final String path;
  @override
  Future<String?> getDownloadsPath() async => path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
  @override
  Future<String?> getTemporaryPath() async => path;
}

final class _NoTransferGateway implements BackgroundDownloaderGateway {
  @override
  Future<void> initialize() async {}
  @override
  Future<DownloadTransportHandle> start(DownloadTaskSpecV2 spec) async =>
      throw StateError('The path recovery fixture cannot start downloads');
  @override
  Future<DownloadTransportHandle?> attach(String taskId) async => null;
  @override
  Future<List<DownloadTransportHandle>> rehydrate() async => [];
  @override
  Future<void> removeTracking(String taskId) async {}
}
