import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/download_v2/download_artwork_store_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_manager_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_diagnostics.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_provider.dart';
import 'package:animewitcher/core/services/download_v2/logical_download_store_v2.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '../../../support/manga_image_fixtures.dart';
import '../../../support/memory_storage_service.dart';
import 'download_v2_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  final originalPaths = PathProviderPlatform.instance;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('aw-artwork-lifecycle-');
    PathProviderPlatform.instance = _Paths(root.path);
  });
  tearDown(() async {
    PathProviderPlatform.instance = originalPaths;
    await root.delete(recursive: true);
  });

  for (final logicalKey in [true, false]) {
    test('startup retains exact ${logicalKey ? 'logical' : 'task'} artwork without opening Downloads UI', () async {
      final f = await _Fixture.create(root);
      f.storage.metadata[logicalKey ? f.record.logicalId.value : f.record.taskId] = {
        'logicalId': f.record.logicalId.value,
        'item': {'posterUrl': ''},
        'episode': {'posterUrl': ''},
      };
      final legacy = (await downloadArtworkStoreV2.legacyFileFor(f.record.taskId))!;
      await legacy.parent.create(recursive: true);
      await legacy.writeAsBytes(tinyMangaPng);
      final container = f.productionContainer();
      final manager = container.read(downloadManagerV2Provider);
      try {
        await manager.initialize();
        await _until(() async => await downloadArtworkStoreV2.existing(
          f.record.logicalId.value, DownloadArtworkKindV2.episode,
        ) != null);
        final retained = (await downloadArtworkStoreV2.existing(
          f.record.logicalId.value, DownloadArtworkKindV2.episode,
        ))!;
        expect(retained.path, isNot(legacy.path));
        expect(await retained.readAsBytes(), tinyMangaPng);
        expect(await legacy.readAsBytes(), tinyMangaPng);
        expect(manager.snapshotFor(f.record.logicalId)?.status, DownloadTransportStatus.complete);
        expect(f.storage.reads.first, f.record.logicalId.value);
        if (!logicalKey) expect(f.storage.reads, contains(f.record.taskId));
        expect(f.gateway.starts, 0);
      } finally {
        await manager.dispose();
        container.dispose();
      }
    });
  }

  test('startup rejects task metadata for another logical variant before legacy migration', () async {
    final f = await _Fixture.create(root);
    f.storage.metadata[f.record.taskId] = {
      'logicalId': logicalDownloadIdFor(
        animeId: f.record.mediaId, episodeKey: f.record.unitKey, variantKey: 'dub|480p',
      ).value,
      'item': {'url': f.record.mediaId, 'posterUrl': ''},
      'trackingUrl': f.record.unitKey, 'variantKey': f.record.variantKey,
    };
    final legacy = (await downloadArtworkStoreV2.legacyFileFor(f.record.taskId))!;
    await legacy.parent.create(recursive: true);
    await legacy.writeAsBytes(tinyMangaPng);
    final container = f.productionContainer();
    final manager = container.read(downloadManagerV2Provider);
    try {
      await manager.initialize();
      await _until(() async => f.storage.reads.contains(f.record.taskId));
      await manager.dispose();
      expect(await downloadArtworkStoreV2.existing(
        f.record.logicalId.value, DownloadArtworkKindV2.episode,
      ), isNull);
      expect(await legacy.readAsBytes(), tinyMangaPng);
      expect(await File(f.record.destinationPath).readAsBytes(), [1, 2, 3]);
    } finally {
      await manager.dispose();
      container.dispose();
    }
  });

  test('manager deletion removes exact owned artwork without presentation metadata', () async {
    final f = await _Fixture.create(root);
    final owned = await _ownedCopies(root, f.record.logicalId.value);
    final legacy = (await downloadArtworkStoreV2.legacyFileFor(f.record.taskId))!;
    final other = (await downloadArtworkStoreV2.legacyFileFor('unrelated-task'))!;
    await legacy.parent.create(recursive: true);
    await legacy.writeAsBytes(tinyMangaPng);
    await other.writeAsBytes(tinyMangaPng);
    final manager = f.plainManager();
    try {
      await manager.initialize();
      await manager.delete(f.record.logicalId);
      expect(await File(f.record.destinationPath).exists(), isFalse);
      expect(await f.store.get(f.record.logicalId), isNull);
      for (final file in owned) {
        expect(await file.exists(), isFalse, reason: 'manager owns artwork lifecycle even without Downloads UI');
      }
      expect(await legacy.exists(), isFalse);
      expect(await other.readAsBytes(), tinyMangaPng);
      expect(f.storage.reads, isEmpty);
    } finally {
      await manager.dispose();
    }
  });

  test('failed video deletion preserves logical record and all owned artwork', () async {
    final f = await _Fixture.create(root);
    final owned = await _ownedCopies(root, f.record.logicalId.value);
    final manager = f.plainManager();
    try {
      await manager.initialize();
      await IOOverrides.runWithIOOverrides(() async {
        await expectLater(manager.delete(f.record.logicalId), throwsA(isA<FileSystemException>()));
      }, _DeleteFailure(f.record.destinationPath));
      expect(await f.store.get(f.record.logicalId), isNotNull);
      expect(await File(f.record.destinationPath).readAsBytes(), [1, 2, 3]);
      for (final file in owned) {
        expect(await file.readAsBytes(), tinyMangaPng);
      }
    } finally {
      await manager.dispose();
    }
  });
}

Future<List<File>> _ownedCopies(Directory root, String logicalId) async {
  final directory = await Directory(p.join(
    root.path, 'download_artwork_v2', sha256.convert(utf8.encode(logicalId)).toString(),
  )).create(recursive: true);
  return [
    for (final kind in DownloadArtworkKindV2.values)
      await File(p.join(directory.path, '${kind.name}.img')).writeAsBytes(tinyMangaPng),
  ];
}

Future<void> _until(Future<bool> Function() done) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    if (await done()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('startup artwork lifecycle did not reach the required observable state');
}

final class _Fixture {
  _Fixture(this.record, this.store);
  final LogicalDownloadRecordV2 record;
  final InMemoryLogicalDownloadStoreV2 store;
  final storage = _MetadataStorage();
  final gateway = _Gateway();

  static Future<_Fixture> create(Directory root) async {
    final mediaId = p.basename(root.path);
    final logicalId = logicalDownloadIdFor(animeId: mediaId, episodeKey: 'episode://2', variantKey: 'sub|1080p');
    final file = await File(p.join(root.path, 'episode.mp4')).writeAsBytes([1, 2, 3]);
    final record = LogicalDownloadRecordV2(
      schemaVersion: kLogicalDownloadSchemaVersionV2,
      logicalId: logicalId, mediaId: mediaId, unitKey: 'episode://2', variantKey: 'sub|1080p',
      generation: 3, taskId: taskIdForGeneration(logicalId, 3), intent: DownloadUserIntent.active,
      destinationPath: file.path, sourceDescriptor: const {}, updatedAtMillis: 1,
      expectedBytes: 3, completedAtMillis: 1,
    );
    final store = InMemoryLogicalDownloadStoreV2();
    await store.put(record);
    return _Fixture(record, store);
  }

  DownloadManagerV2 plainManager() => DownloadManagerV2(
    store: store, gateway: gateway, sourceResolver: StaticSourceResolverV2(),
  );

  ProviderContainer productionContainer() => ProviderContainer(overrides: [
    logicalDownloadStoreV2Provider.overrideWithValue(store),
    backgroundDownloaderGatewayV2Provider.overrideWithValue(gateway),
    downloadSourceResolverV2Provider.overrideWithValue(StaticSourceResolverV2()),
    mangaChapterPageResolverV2Provider.overrideWithValue(ProviderMangaChapterPageResolverV2((_) => null)),
    downloadDiagnosticsV2Provider.overrideWithValue(const NoopDownloadDiagnosticsV2()),
    storageServiceProvider.overrideWithValue(storage),
  ]);
}

final class _MetadataStorage extends MemoryStorageService {
  final metadata = <String, Map<String, dynamic>>{};
  final reads = <String>[];
  @override
  Future<Map<String, dynamic>?> getDownloadMetadata(String taskId) async {
    reads.add(taskId);
    return metadata[taskId];
  }
}

final class _Gateway implements BackgroundDownloaderGateway {
  int starts = 0;
  @override
  Future<void> initialize() async {}
  @override
  Future<List<DownloadTransportHandle>> rehydrate() async => [];
  @override
  Future<DownloadTransportHandle?> attach(String taskId) async => null;
  @override
  Future<void> removeTracking(String taskId) async {}
  @override
  Future<DownloadTransportHandle> start(DownloadTaskSpecV2 spec) async {
    starts++;
    throw StateError('verified completed startup must not create a writer');
  }
}

final class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

final class _DeleteFailure extends IOOverrides {
  _DeleteFailure(this.path);
  final String path;
  @override
  File createFile(String candidate) {
    final file = super.createFile(candidate);
    return candidate == path ? _UndeletableFile(file) : file;
  }
}

final class _UndeletableFile implements File {
  _UndeletableFile(this.file);
  final File file;
  @override
  String get path => file.path;
  @override
  File get absolute => file.absolute;
  @override
  Future<bool> exists() => file.exists();
  @override
  Future<String> resolveSymbolicLinks() => file.resolveSymbolicLinks();
  @override
  Future<File> delete({bool recursive = false}) async => throw FileSystemException('test-only denied media delete', path);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
