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
import 'package:animewitcher/core/services/download_v2/manga_chapter_transport_v2.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '../../../support/manga_image_fixtures.dart';
import '../../../support/memory_storage_service.dart';
import 'download_v2_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/connectivity'),
        (call) async => ['none'],
      );
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/connectivity_status'),
        (call) async => null,
      );
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
    test(
      'startup retains exact ${logicalKey ? 'logical' : 'task'} artwork without opening Downloads UI',
      () async {
        final f = await _Fixture.create(root);
        f.storage.metadata[logicalKey
            ? f.record.logicalId.value
            : f.record.taskId] = {
          'logicalId': f.record.logicalId.value,
          'item': {'posterUrl': ''},
          'episode': {'posterUrl': ''},
        };
        final legacy = (await downloadArtworkStoreV2.legacyFileFor(
          f.record.taskId,
        ))!;
        await legacy.parent.create(recursive: true);
        await legacy.writeAsBytes(tinyMangaPng);
        final container = f.productionContainer();
        final manager = container.read(downloadManagerV2Provider);
        try {
          await manager.initialize();
          await _until(
            () async =>
                await downloadArtworkStoreV2.existing(
                  f.record.logicalId.value,
                  DownloadArtworkKindV2.episode,
                ) !=
                null,
          );
          final retained = (await downloadArtworkStoreV2.existing(
            f.record.logicalId.value,
            DownloadArtworkKindV2.episode,
          ))!;
          expect(retained.path, isNot(legacy.path));
          expect(await retained.readAsBytes(), tinyMangaPng);
          expect(await legacy.readAsBytes(), tinyMangaPng);
          expect(
            manager.snapshotFor(f.record.logicalId)?.status,
            DownloadTransportStatus.complete,
          );
          expect(f.storage.reads.first, f.record.logicalId.value);
          if (!logicalKey) expect(f.storage.reads, contains(f.record.taskId));
          expect(f.gateway.starts, 0);
        } finally {
          await manager.dispose();
          container.dispose();
        }
      },
    );
  }

  test(
    'startup retains cached banner fallback without opening Downloads UI',
    () async {
      final f = await _Fixture.create(root);
      const banner = 'https://example.test/startup-banner.png';
      await DefaultCacheManager().putFile(
        banner,
        tinyMangaPng,
        fileExtension: 'png',
      );
      f.storage.metadata[f.record.logicalId.value] = {
        'logicalId': f.record.logicalId.value,
        'item': {'posterUrl': '', 'bannerUrl': banner},
        'episode': {'posterUrl': 'undefined'},
      };
      final container = f.productionContainer();
      final manager = container.read(downloadManagerV2Provider);
      try {
        await manager.initialize();
        await _until(
          () async =>
              await downloadArtworkStoreV2.existing(
                f.record.logicalId.value,
                DownloadArtworkKindV2.episode,
              ) !=
              null,
        );
        final retained = (await downloadArtworkStoreV2.existing(
          f.record.logicalId.value,
          DownloadArtworkKindV2.episode,
        ))!;
        await DefaultCacheManager().removeFile(banner);
        expect(await retained.readAsBytes(), tinyMangaPng);
        expect(await File(f.record.destinationPath).readAsBytes(), [1, 2, 3]);
        expect(f.gateway.starts, 0);
      } finally {
        await manager.dispose();
        container.dispose();
      }
    },
  );

  test('startup rejects task metadata for another logical variant before legacy migration', () async {
    final f = await _Fixture.create(root);
    f.storage.metadata[f.record.taskId] = {
      'logicalId': logicalDownloadIdFor(
        animeId: f.record.mediaId,
        episodeKey: f.record.unitKey,
        variantKey: 'dub|480p',
      ).value,
      'item': {'url': f.record.mediaId, 'posterUrl': ''},
      'trackingUrl': f.record.unitKey,
      'variantKey': f.record.variantKey,
    };
    final legacy = (await downloadArtworkStoreV2.legacyFileFor(
      f.record.taskId,
    ))!;
    await legacy.parent.create(recursive: true);
    await legacy.writeAsBytes(tinyMangaPng);
    final container = f.productionContainer();
    final manager = container.read(downloadManagerV2Provider);
    try {
      await manager.initialize();
      await _until(() async => f.storage.reads.contains(f.record.taskId));
      await manager.dispose();
      expect(
        await downloadArtworkStoreV2.existing(
          f.record.logicalId.value,
          DownloadArtworkKindV2.episode,
        ),
        isNull,
      );
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
    final legacy = (await downloadArtworkStoreV2.legacyFileFor(
      f.record.taskId,
    ))!;
    final other = (await downloadArtworkStoreV2.legacyFileFor(
      'unrelated-task',
    ))!;
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
        expect(
          await file.exists(),
          isFalse,
          reason: 'manager owns artwork lifecycle even without Downloads UI',
        );
      }
      expect(await legacy.exists(), isFalse);
      expect(await other.readAsBytes(), tinyMangaPng);
      expect(f.storage.reads, isEmpty);
    } finally {
      await manager.dispose();
    }
  });

  test(
    'failed video deletion preserves logical record and all owned artwork',
    () async {
      final f = await _Fixture.create(root);
      final owned = await _ownedCopies(root, f.record.logicalId.value);
      final manager = f.plainManager();
      try {
        await manager.initialize();
        await IOOverrides.runWithIOOverrides(() async {
          await expectLater(
            manager.delete(f.record.logicalId),
            throwsA(isA<FileSystemException>()),
          );
        }, _DeleteFailure(f.record.destinationPath));
        final kept = await f.store.get(f.record.logicalId);
        expect(kept, isNotNull);
        expect(kept!.intent, f.record.intent);
        expect(kept.completedAtMillis, f.record.completedAtMillis);
        expect(manager.snapshotFor(f.record.logicalId)?.status,
            DownloadTransportStatus.complete);
        expect(await File(f.record.destinationPath).readAsBytes(), [1, 2, 3]);
        for (final file in owned) {
          expect(await file.readAsBytes(), tinyMangaPng);
        }
      } finally {
        await manager.dispose();
      }
    },
  );

  test('manager disposal fences artwork before joining an issued manga publication', () async {
    final f = await _Fixture.create(root);
    final mangaId = logicalDownloadIdForMangaChapter(
      mangaId: 'manga',
      chapterId: 'publication',
    );
    final manga = _PendingMangaPublication(taskIdForGeneration(mangaId, 1));
    f.gateway.handles.add(manga);
    await f.store.put(
      f.record.copyWith(
        logicalId: mangaId,
        mediaKind: DownloadMediaKind.mangaChapter,
        mediaId: 'manga',
        unitKey: 'publication',
        variantKey: 'pages',
        taskId: manga.taskId,
        generation: 1,
        intent: DownloadUserIntent.paused,
        destinationPath: p.join(root.path, 'manga'),
        updatedAtMillis: 2,
        clearCompletedAtMillis: true,
      ),
    );
    final oldFetchEntered = Completer<void>();
    final oldBytes = Completer<List<int>?>();
    final replacementFetchEntered = Completer<bool>();
    final artwork = DownloadArtworkStoreV2(
      supportDirectory: () async => root,
      cachedFileForUrl: (_) async => null,
      fetchBytes: (uri) {
        if (uri.path.endsWith('old')) {
          oldFetchEntered.complete();
          return oldBytes.future;
        }
        if (!replacementFetchEntered.isCompleted)
          replacementFetchEntered.complete(true);
        return Future.value(tinyMangaPng);
      },
    );
    final oldObserver = DownloadArtworkObserverV2(
      store: artwork,
      sourceFor: (_) async =>
          const DownloadArtworkSourceV2(posterUrl: 'https://example.test/old'),
    );
    final oldManager = DownloadManagerV2(
      store: f.store,
      gateway: f.gateway,
      sourceResolver: StaticSourceResolverV2(),
      presentationObservers: [oldObserver],
    );
    await oldManager.initialize();
    await oldFetchEntered.future.timeout(const Duration(seconds: 5));
    final disposal = oldManager.dispose();
    await manga.disposalEntered.future.timeout(const Duration(seconds: 5));
    final replacementStore = InMemoryLogicalDownloadStoreV2();
    await replacementStore.put(f.record);
    final replacementObserver = DownloadArtworkObserverV2(
      store: artwork,
      sourceFor: (_) async =>
          const DownloadArtworkSourceV2(posterUrl: 'https://example.test/new'),
    );
    final replacementManager = DownloadManagerV2(
      store: replacementStore,
      gateway: _Gateway(),
      sourceResolver: StaticSourceResolverV2(),
      presentationObservers: [replacementObserver],
    );
    var fetchedReplacement = false;
    try {
      await replacementManager.initialize();
      fetchedReplacement = await replacementFetchEntered.future.timeout(
        const Duration(milliseconds: 250),
        onTimeout: () => false,
      );
      if (fetchedReplacement) {
        await _until(
          () async =>
              await artwork.existing(
                f.record.logicalId.value,
                DownloadArtworkKindV2.poster,
              ) !=
              null,
        );
      }
    } finally {
      oldBytes.complete(tinyMangaJpeg);
      manga.releasePublication.complete();
      await disposal;
      await replacementManager.dispose();
    }
    expect(
      fetchedReplacement,
      isTrue,
      reason: 'a replacement manager cannot join the still-eligible old artwork fetch',
    );
    final retained = (await artwork.existing(
      f.record.logicalId.value,
      DownloadArtworkKindV2.poster,
    ))!;
    expect(await retained.readAsBytes(), tinyMangaPng);
    expect(await File(f.record.destinationPath).readAsBytes(), [1, 2, 3]);
  });
}

Future<List<File>> _ownedCopies(Directory root, String logicalId) async {
  final directory = await Directory(
    p.join(
      root.path,
      'download_artwork_v2',
      sha256.convert(utf8.encode(logicalId)).toString(),
    ),
  ).create(recursive: true);
  return [
    for (final kind in DownloadArtworkKindV2.values)
      await File(p.join(directory.path, '${kind.name}.img'))
          .writeAsBytes(tinyMangaPng),
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
    final logicalId = logicalDownloadIdFor(
      animeId: mediaId,
      episodeKey: 'episode://2',
      variantKey: 'sub|1080p',
    );
    final file = await File(p.join(root.path, 'episode.mp4'))
        .writeAsBytes([1, 2, 3]);
    final record = LogicalDownloadRecordV2(
      schemaVersion: kLogicalDownloadSchemaVersionV2,
      logicalId: logicalId,
      mediaId: mediaId,
      unitKey: 'episode://2',
      variantKey: 'sub|1080p',
      generation: 3,
      taskId: taskIdForGeneration(logicalId, 3),
      intent: DownloadUserIntent.active,
      destinationPath: file.path,
      sourceDescriptor: const {},
      updatedAtMillis: 1,
      expectedBytes: 3,
      completedAtMillis: 1,
    );
    final store = InMemoryLogicalDownloadStoreV2();
    await store.put(record);
    return _Fixture(record, store);
  }

  DownloadManagerV2 plainManager() => DownloadManagerV2(
    store: store,
    gateway: gateway,
    sourceResolver: StaticSourceResolverV2(),
  );

  ProviderContainer productionContainer() => ProviderContainer(
    overrides: [
      logicalDownloadStoreV2Provider.overrideWithValue(store),
      backgroundDownloaderGatewayV2Provider.overrideWithValue(gateway),
      downloadSourceResolverV2Provider.overrideWithValue(
        StaticSourceResolverV2(),
      ),
      mangaChapterPageResolverV2Provider.overrideWithValue(
        ProviderMangaChapterPageResolverV2((_) => null),
      ),
      downloadDiagnosticsV2Provider.overrideWithValue(
        const NoopDownloadDiagnosticsV2(),
      ),
      storageServiceProvider.overrideWithValue(storage),
    ],
  );
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
  final handles = <DownloadTransportHandle>[];
  @override
  Future<void> initialize() async {}
  @override
  Future<List<DownloadTransportHandle>> rehydrate() async => handles.toList();
  @override
  Future<DownloadTransportHandle?> attach(String taskId) async {
    for (final handle in handles) {
      if (handle.taskId == taskId) return handle;
    }
    return null;
  }

  @override
  Future<void> removeTracking(String taskId) async {}
  @override
  Future<DownloadTransportHandle> start(DownloadTaskSpecV2 spec) async {
    starts++;
    throw StateError('verified completed startup must not create a writer');
  }
}

final class _PendingMangaPublication implements MangaChapterTransportHandleV2 {
  _PendingMangaPublication(this.taskId);
  @override
  final String taskId;
  final disposalEntered = Completer<void>();
  final releasePublication = Completer<void>();
  Future<void>? _disposal;
  @override
  bool get recoveryOnly => false;
  @override
  DownloadTransportSnapshot get current => DownloadTransportSnapshot(
    taskId: taskId,
    status: DownloadTransportStatus.paused,
    progress: .5,
  );
  @override
  Stream<DownloadTransportSnapshot> get snapshots => const Stream.empty();
  @override
  Future<bool> pause() async => true;
  @override
  Future<bool> resume() async => false;
  @override
  Future<bool> cancel() async => false;
  @override
  Future<void> dispose() => _disposal ??= () async {
    disposalEntered.complete();
    await releasePublication.future;
  }();
}

final class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
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
  bool existsSync() => file.existsSync();
  @override
  Future<String> resolveSymbolicLinks() => file.resolveSymbolicLinks();
  @override
  Future<File> delete({bool recursive = false}) async =>
      throw FileSystemException('test-only denied media delete', path);
  @override
  void deleteSync({bool recursive = false}) =>
      throw FileSystemException('test-only denied media delete', path);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
