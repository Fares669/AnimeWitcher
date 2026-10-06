import 'dart:io';

import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/services/download_v2/download_file_planner_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_provider.dart';
import 'package:animewitcher/core/services/download_v2/download_manager_v2.dart';
import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/download_v2/logical_download_store_v2.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/manga/presentation/manga_details_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../../core/services/download_v2/download_v2_test_support.dart';
import '../../../support/memory_storage_service.dart';

import 'package:animewitcher/features/manga/presentation/manga_details_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final originalPathProvider = PathProviderPlatform.instance;

  setUp(() {
    PathProviderPlatform.instance = _FakePathProviderPlatform('/tmp/Downloads');
  });

  tearDown(() {
    PathProviderPlatform.instance = originalPathProvider;
  });
  for (final hasMetadata in [true, false]) {
    test(
      hasMetadata
          ? 'failed paused chapter resume preserves existing metadata unchanged'
          : 'failed chapter launch removes only its newly created metadata',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'aw-manga-metadata-',
        );
        Hive.init(root.path);
        final box = await Hive.openBox<dynamic>(
          StorageService.kDownloadMetadataBox,
        );
        addTearDown(() async {
          await box.close();
          await root.delete(recursive: true);
        });
        final manga = MultimediaItem(
          title: 'Updated title',
          url: 'https://animewitcher.com/manga/m1',
          posterUrl: '',
          contentType: MultimediaContentType.manga,
          provider: 'animewitcher.native',
          syncData: const {'mangaId': 'm1'},
        );
        const chapter = MangaChapter(
          id: '12',
          mangaId: 'm1',
          url: 'https://manga.test/12',
          name: 'Chapter 12',
        );
        final logicalId = logicalDownloadIdForMangaChapter(
          mangaId: 'm1',
          chapterId: '12',
        );
        final oldDestination = p.join(
          root.path,
          'manga',
          'Original title',
          'Chapter 12',
        );
        final page = File(p.join(oldDestination, '00001.jpg'));
        await page.parent.create(recursive: true);
        await page.writeAsBytes([1, 2, 3]);
        final store = InMemoryLogicalDownloadStoreV2();
        await store.put(
          LogicalDownloadRecordV2(
            schemaVersion: kLogicalDownloadSchemaVersionV2,
            logicalId: logicalId,
            mediaKind: DownloadMediaKind.mangaChapter,
            mediaId: 'm1',
            unitKey: '12',
            variantKey: 'pages',
            generation: 1,
            taskId: taskIdForGeneration(logicalId, 1),
            intent: DownloadUserIntent.paused,
            destinationPath: oldDestination,
            sourceDescriptor: const {
              'providerId': 'animewitcher.native',
              'mangaUrl': 'https://animewitcher.com/manga/m1',
              'mangaId': 'm1',
              'chapterId': '12',
              'chapterUrl': 'https://manga.test/12',
              'chapterName': 'Chapter 12',
            },
            updatedAtMillis: 1,
          ),
        );
        final storage = MemoryStorageService();
        if (hasMetadata) {
          await storage.saveDownloadMetadata(
            logicalId.value,
            manga.copyWith(title: 'Original title'),
            trackingUrl: chapter.url,
            filePath: oldDestination,
            logicalId: logicalId.value,
            taskSnapshot: const {
              'mediaKind': 'mangaChapter',
              'chapter': {
                'id': '12',
                'mangaId': 'm1',
                'url': 'https://manga.test/12',
                'name': 'Chapter 12',
              },
            },
            userPaused: true,
            lastProgress: 0.75,
          );
        }
        final originalMetadata = await storage.getDownloadMetadata(
          logicalId.value,
        );
        final manager = DownloadManagerV2(
          store: store,
          gateway: _MissingChapterGateway(),
          sourceResolver: StaticSourceResolverV2(),
        );
        final container = ProviderContainer(
          overrides: [
            storageServiceProvider.overrideWithValue(storage),
            downloadManagerV2Provider.overrideWithValue(manager),
            mangaDetailsControllerProvider(manga.url)
                .overrideWith(() => _ReadyMangaController(manga)),
          ],
        );
        addTearDown(() async {
          container.dispose();
          await manager.dispose();
        });

        container.listen(mangaDetailsControllerProvider(manga.url), (_, _) {});
        await expectLater(
          container
              .read(mangaDetailsControllerProvider(manga.url).notifier)
              .downloadChapter(chapter),
          throwsStateError,
        );

        expect(
          await storage.getDownloadMetadata(logicalId.value),
          originalMetadata,
        );
        expect((await store.get(logicalId))?.destinationPath, oldDestination);
        expect((await store.get(logicalId))?.generation, 1);
        expect(await page.readAsBytes(), [1, 2, 3]);
      },
    );
  }

  test(
    'writable destination preserves preferred location and user files',
    () async {
      final root = await Directory.systemTemp.createTemp('aw-download-write-');
      addTearDown(() => root.delete(recursive: true));
      final preferred = Directory(p.join(root.path, 'public', 'anime'));
      await preferred.create(recursive: true);
      final userFile = File(p.join(preferred.path, 'keep.txt'));
      await userFile.writeAsString('keep');
      final fallback = Directory(p.join(root.path, 'private', 'anime'));

      final destination = await firstWritableDownloadDirectoryV2([
        preferred,
        fallback,
      ]);

      expect(destination, preferred.path);
      expect(await userFile.readAsString(), 'keep');
      expect(await preferred.list().toList(), hasLength(1));
      expect(await fallback.exists(), isFalse);
    },
  );

  test(
    'existing unwritable directory falls back to app-owned destination',
    () async {
      if (!Platform.isLinux) return;
      final preferred = Directory('/proc');
      expect(await preferred.exists(), isTrue);
      final root = await Directory.systemTemp.createTemp(
        'aw-download-fallback-',
      );
      addTearDown(() => root.delete(recursive: true));
      final fallback = Directory(p.join(root.path, 'private', 'manga'));

      final destination = await firstWritableDownloadDirectoryV2([
        preferred,
        fallback,
      ]);

      expect(destination, fallback.path);
      expect(await fallback.list().toList(), isEmpty);
    },
  );

  test('manga chapter request uses readable Downloads/manga folders', () async {
    final manga = MultimediaItem(
      title: 'Manga',
      url: 'https://animewitcher.com/manga/m1',
      posterUrl: '',
      contentType: MultimediaContentType.manga,
      provider: 'animewitcher.native',
      syncData: const <String, String>{'mangaId': 'm1'},
    );
    const chapter = MangaChapter(
      id: '12.5',
      mangaId: 'm1',
      url: 'https://manga.test/chapter-12-5/',
      name: 'الفصل 12.5',
      number: 12.5,
    );

    final request = await mangaChapterDownloadRequest(manga, chapter);

    expect(request.mediaKind, DownloadMediaKind.mangaChapter);
    expect(request.mediaId, 'm1');
    expect(request.unitKey, '12.5');
    expect(request.parallelChunks, 4);
    final manualRequest = await mangaChapterDownloadRequest(
      manga,
      chapter,
      parallelChunks: 16,
    );
    expect(manualRequest.parallelChunks, 16);
    expect(request.sourceDescriptor['chapterUrl'], chapter.url);
    expect(request.sourceDescriptor['mangaUrl'], manga.url);
    expect(
      p.normalize(request.destinationPath),
      endsWith(p.join('manga', 'Manga', 'الفصل 12.5')),
    );
  });

  test('anime episodes stay directly in Downloads/anime/title', () async {
    final seasonOne = Episode(
      name: 'حلقة 1',
      url: 'https://anime.test/one-piece/1',
      season: 1,
      episode: 1,
    );
    final seasonTwo = Episode(
      name: 'حلقة 1',
      url: 'https://anime.test/one-piece/season-2/1',
      season: 2,
      episode: 1,
    );
    final anime = MultimediaItem(
      title: 'ون بيس',
      url: 'https://anime.test/one-piece',
      posterUrl: '',
      contentType: MultimediaContentType.anime,
      episodes: <Episode>[seasonOne, seasonTwo],
    );

    final destination = await downloadDestinationPathV2(
      anime,
      episode: seasonTwo,
      filename: 'حلقة 1.mp4',
    );

    expect(
      p.normalize(destination),
      p.join('/tmp/Downloads', 'anime', 'ون بيس', 'حلقة 1.mp4'),
    );
  });
}

final class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.downloadsPath);

  final String downloadsPath;

  @override
  Future<String?> getDownloadsPath() async => downloadsPath;
}

final class _ReadyMangaController extends MangaDetailsController {
  _ReadyMangaController(this.manga);
  final MultimediaItem manga;

  @override
  MangaDetailsState build(String itemUrl) => MangaDetailsState(item: manga);
}

final class _MissingChapterGateway implements BackgroundDownloaderGateway {
  @override
  Future<void> initialize() async {}

  @override
  Future<DownloadTransportHandle> start(DownloadTaskSpecV2 spec) async =>
      throw StateError('no chapter transport');

  @override
  Future<DownloadTransportHandle?> attach(String taskId) async => null;

  @override
  Future<List<DownloadTransportHandle>> rehydrate() async => const [];

  @override
  Future<void> removeTracking(String taskId) async {}
}
