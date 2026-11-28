import 'dart:io';

import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/download_v2/download_integrity_verifier_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_manager_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/core/services/download_v2/logical_download_store_v2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
// Keep the manager's filesystem fixture inside its temporary directory.
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'download_v2_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('startup validates each completed video at its reconciliation turn', () async {
    final fixture = await _fixture();
    final first = await fixture.save(0, body: '#EXTM3U');
    final shrunk = await fixture.save(1, body: 'fixed', expectedBytes: 5);
    final repaired = await fixture.save(2, body: 'x', expectedBytes: 3);
    final missing = await fixture.save(3, expectedBytes: 8);
    final later = await fixture.save(4, body: 'intact');

    fixture.gateway.onRemove = (taskId) async {
      if (taskId != first.taskId) return;
      // This callback is reached only after the earlier file has been checked.
      // An eager read of the whole batch would invert both later judgments.
      await File(shrunk.destinationPath).writeAsString('a');
      await File(repaired.destinationPath).writeAsString('new');
    };

    await fixture.manager.records.first;
    await fixture.manager.initialize();

    expect(fixture.gateway.removed, [
      first.taskId,
      repaired.taskId,
      later.taskId,
    ]);
    expect(fixture.resolver.calls, 0);
    for (final row in [first, repaired, later]) {
      final saved = (await fixture.store.get(row.logicalId))!;
      expect(saved.completedAtMillis, row.completedAtMillis);
      expect(
        fixture.manager.snapshotFor(row.logicalId)?.status,
        DownloadTransportStatus.complete,
      );
    }
    expect(await File(first.destinationPath).readAsString(), '#EXTM3U');
    expect(await File(repaired.destinationPath).readAsString(), 'new');
    for (final (row, reason) in [
      (shrunk, 'size-mismatch'),
      (missing, 'missing'),
    ]) {
      final saved = (await fixture.store.get(row.logicalId))!;
      expect(saved.intent, DownloadUserIntent.failed);
      expect(saved.completedAtMillis, isNull);
      expect(saved.failureCategory, DownloadFailureCategory.integrity);
      expect(saved.failureMessage, reason);
      expect(await File(row.destinationPath).exists(), isFalse);
    }
  });

  test(
    'closing a pending startup session does not disable fresh checks',
    () async {
      final fixture = await _fixture();
      final saved = await fixture.save(0, body: 'abc');
      final file = File(saved.destinationPath);
      const verifier = DownloadIntegrityVerifierV2();
      final session = verifier.startupSession();
      final pending = session.verify(file, expectedBytes: 3);
      final stopped = expectLater(pending, throwsStateError);
      session.close();
      session.close();
      await stopped;
      await expectLater(session.verify(file), throwsStateError);

      final result = await verifier.verify(file, expectedBytes: 3);
      expect(result.isValid, isTrue);
      await file.writeAsString('x');
      expect(
        (await verifier.verify(file, expectedBytes: 3)).reason,
        'size-mismatch',
      );
    },
  );

  test(
    'startup verification after a retarget cannot delete the other owner',
    () async {
      final fixture = await _fixture();
      final first = await fixture.save(0, body: 'first');
      final futureOwner = await fixture.save(2, body: 'owned bytes');
      final original = File(p.join(fixture.root.path, 'original.mp4'));
      await original.writeAsString('123');
      final link = Link(p.join(fixture.root.path, 'alias.mp4'));
      await link.create(original.path);
      final alias = await fixture.save(1, path: link.path, expectedBytes: 3);

      fixture.gateway.onRemove = (taskId) async {
        if (taskId == first.taskId) {
          await link.update(futureOwner.destinationPath);
        }
      };

      await fixture.manager.records.first;
      await fixture.manager.initialize();

      final aliasRecord = (await fixture.store.get(alias.logicalId))!;
      expect(aliasRecord.failureMessage, 'size-mismatch');
      expect(aliasRecord.completedAtMillis, isNull);
      expect(await link.target(), futureOwner.destinationPath);
      expect(await original.readAsString(), '123');
      expect(
        await File(futureOwner.destinationPath).readAsString(),
        'owned bytes',
      );
      expect(
        (await fixture.store.get(futureOwner.logicalId))!.completedAtMillis,
        futureOwner.completedAtMillis,
      );
      expect(fixture.gateway.removed, [first.taskId, futureOwner.taskId]);
      expect(fixture.resolver.calls, 0);
    },
    skip: Platform.isWindows ? 'Tests POSIX symlink ownership' : false,
  );
}

Future<_Fixture> _fixture() async {
  final root = await Directory.systemTemp.createTemp('aw-verify-v2-startup-');
  final oldPaths = PathProviderPlatform.instance;
  PathProviderPlatform.instance = _FixturePaths(root.path);
  final store = InMemoryLogicalDownloadStoreV2();
  final gateway = _NoTransferGateway();
  final resolver = StaticSourceResolverV2();
  final manager = DownloadManagerV2(
    store: store,
    gateway: gateway,
    sourceResolver: resolver,
    nowMillis: () => 1000,
  );
  addTearDown(() async {
    await manager.dispose();
    PathProviderPlatform.instance = oldPaths;
    await root.delete(recursive: true);
  });
  return _Fixture(root, store, gateway, resolver, manager);
}

final class _Fixture {
  _Fixture(this.root, this.store, this.gateway, this.resolver, this.manager);
  final Directory root;
  final InMemoryLogicalDownloadStoreV2 store;
  final _NoTransferGateway gateway;
  final StaticSourceResolverV2 resolver;
  final DownloadManagerV2 manager;

  Future<LogicalDownloadRecordV2> save(
    int order, {
    String? body,
    String? path,
    int? expectedBytes,
  }) async {
    final key = '$order';
    final id = logicalDownloadIdFor(
      animeId: 'startup-verify-fixture',
      episodeKey: key,
      variantKey: 'source',
    );
    final destination = path ?? p.join(root.path, 'video-$order.mp4');
    if (body != null) await File(destination).writeAsString(body);
    final row = LogicalDownloadRecordV2(
      schemaVersion: kLogicalDownloadSchemaVersionV2,
      logicalId: id,
      mediaId: 'startup-verify-fixture',
      unitKey: key,
      variantKey: 'source',
      generation: 1,
      taskId: taskIdForGeneration(id, 1),
      intent: DownloadUserIntent.active,
      destinationPath: destination,
      sourceDescriptor: const {'providerId': 'offline-fixture'},
      updatedAtMillis: order + 1,
      completedAtMillis: order + 1,
      expectedBytes: expectedBytes ?? body?.length,
    );
    await store.put(row);
    return row;
  }
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
  final removed = <String>[];
  Future<void> Function(String)? onRemove;

  @override
  Future<void> initialize() async {}
  @override
  Future<DownloadTransportHandle> start(DownloadTaskSpecV2 spec) async =>
      throw StateError(
        'Startup verifies local files without network transfers',
      );
  @override
  Future<DownloadTransportHandle?> attach(String taskId) async => null;
  @override
  Future<List<DownloadTransportHandle>> rehydrate() async => [];
  @override
  Future<void> removeTracking(String taskId) async {
    removed.add(taskId);
    await onRemove?.call(taskId);
  }
}
