import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/download_v2/download_persistent_storage_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_provider.dart';
import 'package:animewitcher/core/storage/download_persistence_worker.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/features/library/presentation/downloads_provider.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:animewitcher/core/services/download_v2/download_manager_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/core/services/download_v2/logical_download_store_v2.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '../core/services/download_v2/download_v2_test_support.dart';

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
  test(
    'cold production persistence and episode deletion bypass stalled DNS',
    () async {
      final root = Directory.systemTemp.createTempSync(
        'offline-delete-fixture-',
      );
      final previous = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _Paths(root.path);
      var worker = DownloadPersistenceWorker.forDirectory(
        root.path,
        documentsDirectory: root.path,
      );
      final store = HiveLogicalDownloadStoreV2(worker: worker);
      final storage = StorageService(downloadPersistenceWorker: worker);
      final transportStorage = DownloadPersistentStorageV2(worker: worker);
      final downloader = FileDownloader(persistentStorage: transportStorage);
      await downloader.ready;
      final gateway = PackageBackgroundDownloaderGateway(
        downloader: downloader,
        initializePackage: () async {},
        isIOS: () => true,
      );
      final manager = DownloadManagerV2(
        store: store,
        gateway: gateway,
        sourceResolver: StaticSourceResolverV2(),
      );
      final video = File(p.join(root.path, 'anime', 'Show', 'episode.mp4'));
      video.parent.createSync(recursive: true);
      video.writeAsBytesSync([1, 2, 3]);
      final sibling = File(p.join(video.parent.path, 'other.mp4'))
        ..writeAsBytesSync([4, 5, 6]);
      final legacy = File(p.join(root.path, 'anime', 'Legacy', 'episode.mp4'));
      legacy.parent.createSync(recursive: true);
      legacy.writeAsBytesSync([7, 8, 9]);
      final temp = File('${legacy.path}.part')..writeAsBytesSync([7]);
      final id = logicalDownloadIdFor(
        animeId: 'show',
        episodeKey: 'episode',
        variantKey: 'original',
      );
      await transportStorage.storeTaskRecord(
        TaskRecord(
          DownloadTask(
            taskId: taskIdForGeneration(id, 1),
            url: 'https://example.invalid/video.mp4',
            filename: p.basename(video.path),
            directory: video.parent.path,
            baseDirectory: BaseDirectory.root,
          ),
          TaskStatus.complete,
          1,
          3,
        ),
      );
      await transportStorage.storeTaskRecord(
        TaskRecord(
          DownloadTask(
            taskId: 'unrelated-completed-task',
            url: 'https://example.invalid/other.mp4',
            filename: p.basename(sibling.path),
            directory: sibling.parent.path,
            baseDirectory: BaseDirectory.root,
          ),
          TaskStatus.complete,
          1,
          3,
        ),
      );
      final ownedArtwork = Directory(
        p.join(
          root.path,
          'download_artwork_v2',
          sha256.convert(utf8.encode(id.value)).toString(),
        ),
      );
      ownedArtwork.createSync(recursive: true);
      File(p.join(ownedArtwork.path, 'poster.img')).writeAsBytesSync([1, 2, 3]);
      final otherArtwork = File(
        p.join(root.path, 'download_artwork_v2', 'other', 'poster.img'),
      );
      otherArtwork.parent.createSync(recursive: true);
      otherArtwork.writeAsBytesSync([4, 5, 6]);
      await store.put(
        LogicalDownloadRecordV2(
          schemaVersion: kLogicalDownloadSchemaVersionV2,
          logicalId: id,
          mediaKind: DownloadMediaKind.videoEpisode,
          mediaId: 'show',
          unitKey: 'episode',
          variantKey: 'original',
          generation: 1,
          taskId: taskIdForGeneration(id, 1),
          intent: DownloadUserIntent.active,
          destinationPath: video.path,
          sourceDescriptor: const {},
          expectedBytes: 3,
          completedAtMillis: 1,
          updatedAtMillis: 1,
        ),
      );
      final mangaId = logicalDownloadIdForMangaChapter(
        mangaId: 'neighbor',
        chapterId: '1',
      );
      final chapter = Directory(p.join(video.parent.path, 'chapter'))
        ..createSync();
      await store.put(
        LogicalDownloadRecordV2(
          schemaVersion: kLogicalDownloadSchemaVersionV2,
          logicalId: mangaId,
          mediaKind: DownloadMediaKind.mangaChapter,
          mediaId: 'neighbor',
          unitKey: '1',
          variantKey: 'pages',
          generation: 1,
          taskId: taskIdForGeneration(mangaId, 1),
          intent: DownloadUserIntent.paused,
          destinationPath: chapter.path,
          sourceDescriptor: const {},
          updatedAtMillis: 0,
        ),
      );
      await storage.saveDownloadMetadata(
        id.value,
        MultimediaItem(title: 'Show', url: 'show', posterUrl: ''),
        logicalId: id.value,
        filePath: video.path,
      );
      final container = ProviderContainer(
        overrides: [
          downloadManagerV2Provider.overrideWithValue(manager),
          logicalDownloadStoreV2Provider.overrideWithValue(store),
          storageServiceProvider.overrideWithValue(storage),
        ],
      );
      final lookups = List.generate(
        32,
        (i) =>
            InternetAddress.lookup('offline-delete-$i.invalid')
                .then<Object?>((_) => null, onError: (Object _) => null),
      );
      var ticks = 0;
      final timer = Timer.periodic(
        const Duration(milliseconds: 20),
        (_) => ticks++,
      );
      try {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await expectLater(
          video.exists().timeout(const Duration(milliseconds: 300)),
          throwsA(isA<TimeoutException>()),
        );
        final before = ticks;
        final items = await container
            .read(downloadsProvider.future)
            .timeout(const Duration(seconds: 2));
        expect(items, hasLength(1));
        expect(
          await container
              .read(downloadsProvider.notifier)
              .removeDownloads(items)
              .timeout(const Duration(seconds: 2)),
          isTrue,
        );
        expect(video.existsSync(), isFalse);
        expect(ownedArtwork.existsSync(), isFalse);
        expect(await store.get(id), isNull);
        expect(await storage.getAllDownloadMetadata(), isEmpty);
        expect(
          (await transportStorage.retrieveAllTaskRecords()).map(
            (record) => record.taskId,
          ),
          ['unrelated-completed-task'],
        );
        expect(container.read(downloadsProvider).value, isEmpty);
        expect(sibling.readAsBytesSync(), [4, 5, 6]);
        expect(chapter.existsSync(), isTrue);
        expect((await store.get(mangaId))?.intent, DownloadUserIntent.paused);
        expect(otherArtwork.readAsBytesSync(), [4, 5, 6]);
        expect(
          await manager
              .deleteLegacyDownloadedVideo(legacy)
              .timeout(const Duration(seconds: 2)),
          isTrue,
        );
        expect(legacy.existsSync(), isFalse);
        expect(temp.existsSync(), isFalse);
        expect(legacy.parent.existsSync(), isFalse);
        expect(ticks, greaterThanOrEqualTo(before));
        await Future.wait(lookups);
        await manager.initialize();
        container.dispose();
        await manager.dispose();
        await worker.close();
        worker = DownloadPersistenceWorker.forDirectory(
          root.path,
          documentsDirectory: root.path,
        );
        final reopened = HiveLogicalDownloadStoreV2(worker: worker);
        expect(await reopened.get(id), isNull);
        expect(
          (await reopened.get(mangaId))?.intent,
          DownloadUserIntent.paused,
        );
        expect(
          await StorageService(downloadPersistenceWorker: worker)
              .getAllDownloadMetadata(),
          isEmpty,
        );
        expect(
          (await DownloadPersistentStorageV2(
            worker: worker,
          ).retrieveAllTaskRecords()).map((record) => record.taskId),
          ['unrelated-completed-task'],
        );
        stdout.writeln('PASS: downloaded episode deletion bypasses stalled DNS');
      } finally {
        timer.cancel();
        await Future.wait(lookups);
        await manager.dispose();
        await worker.close();
        PathProviderPlatform.instance = previous;
        root.deleteSync(recursive: true);
      }
    },
  );
}

final class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getDownloadsPath() async => root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}
