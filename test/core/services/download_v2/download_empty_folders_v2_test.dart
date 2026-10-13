import 'dart:async';
import 'dart:io';

import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/download_v2/download_manager_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/core/services/download_v2/logical_download_store_v2.dart';
import 'package:animewitcher/core/services/download_v2/manga_chapter_manifest_v2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'download_v2_test_support.dart';

void main() {
  for (final manga in [false, true]) {
    test(
      'deleting final ${manga ? 'chapter' : 'episode'} removes empty title only',
      () async {
        final f = await _Fixture.create();
        final title = Directory(
          p.join(f.root.path, manga ? 'manga' : 'anime', 'Example'),
        );
        final destination = manga
            ? p.join(title.path, 'الفصل 357')
            : p.join(title.path, 'episode.mp4');
        final record = _record(destination, manga: manga);
        await f.store.put(record);
        if (manga) {
          await MangaChapterManifestV2(
            version: 1,
            mangaId: 'm1',
            chapterId: '357',
            pageCount: 1,
            completedIndexes: {0},
            isComplete: true,
          ).writeTo(Directory(destination));
          await File(p.join(destination, '0001.webp')).writeAsBytes([1, 2, 3]);
        } else {
          await File(destination).create(recursive: true);
          await File(destination).writeAsBytes([1, 2, 3]);
        }
        final unrelated = Directory(
          p.join(f.root.path, manga ? 'manga' : 'anime', 'User folder'),
        );
        await unrelated.create();
        await f.manager.delete(record.logicalId);
        expect(await title.exists(), isFalse);
        expect(await title.parent.exists(), isTrue);
        expect(await unrelated.exists(), isTrue);
        expect(await f.store.get(record.logicalId), isNull);
      },
    );
  }

  test(
    'cancel removes newly created empty title after its transport settles',
    () async {
      final f = await _Fixture.create();
      await f.manager.initialize();
      final title = Directory(p.join(f.root.path, 'anime', 'Canceled show'));
      await title.create(recursive: true);
      final record = _record(p.join(title.path, 'episode.mp4'));
      await f.store.put(record);
      await f.manager.cancel(record.logicalId);
      expect(await title.exists(), isFalse);
      expect(
        (await f.store.get(record.logicalId))!.intent,
        DownloadUserIntent.canceled,
      );
    },
  );

  test('startup prunes known canceled empty containers but preserves public unknown folders', () async {
    final f = await _Fixture.create();
    final title = Directory(p.join(f.root.path, 'anime', 'Old canceled show'));
    final unknown = Directory(p.join(f.root.path, 'anime', 'User folder'));
    await title.create(recursive: true);
    await unknown.create();
    await f.store.put(_record(p.join(title.path, 'episode.mp4')));
    await f.manager.initialize();
    expect(await title.exists(), isFalse);
    expect(await unknown.exists(), isTrue);
    expect(await title.parent.exists(), isTrue);
  });

  test(
    'startup removes orphan empty titles only in dedicated app root',
    () async {
      final f = await _Fixture.create();
      final mediaRoot = Directory(
        p.join(f.root.path, 'AnimeWitcher', 'Downloads'),
      );
      final empty = Directory(p.join(mediaRoot.path, 'Old orphan'));
      final nonempty = Directory(p.join(mediaRoot.path, 'Keep'));
      await empty.create(recursive: true);
      await nonempty.create();
      await File(p.join(nonempty.path, 'notes.txt')).writeAsString('keep');
      await f.manager.initialize();
      expect(await empty.exists(), isFalse);
      expect(await mediaRoot.exists(), isTrue);
      expect(
        await File(p.join(nonempty.path, 'notes.txt')).readAsString(),
        'keep',
      );
    },
  );

  test(
    'startup and sibling deletion preserve paused chapter empty directory',
    () async {
      final f = await _Fixture.create();
      final title = Directory(p.join(f.root.path, 'manga', 'Example'));
      final active = Directory(p.join(title.path, 'الفصل 358'));
      await active.create(recursive: true);
      final paused = _record(
        active.path,
        manga: true,
        unit: '358',
        intent: DownloadUserIntent.paused,
      );
      final removed = _record(p.join(title.path, 'الفصل 357'), manga: true);
      await Directory(removed.destinationPath).create();
      await f.store.put(paused);
      await f.store.put(removed);
      await f.manager.delete(removed.logicalId);
      expect(await active.exists(), isTrue);
      expect(await title.exists(), isTrue);
    },
  );

  test('missing deleted artifact still prunes its empty title', () async {
    final f = await _Fixture.create();
    final title = Directory(p.join(f.root.path, 'anime', 'Example'));
    await title.create(recursive: true);
    final record = _record(
      p.join(title.path, 'episode.mp4'),
      intent: DownloadUserIntent.paused,
    );
    await f.store.put(record);
    await f.manager.delete(record.logicalId);
    expect(await title.exists(), isFalse);
  });

  test(
    'empty cleanup never follows a title symlink even within same media root',
    () async {
      if (Platform.isWindows) return;
      final f = await _Fixture.create();
      final mediaRoot = Directory(p.join(f.root.path, 'anime'));
      final outside = Directory(p.join(f.root.path, 'outside'));
      await mediaRoot.create();
      await outside.create();
      final link = Link(p.join(mediaRoot.path, 'Example'));
      await link.create(outside.path);
      await f.store.put(_record(p.join(link.path, 'episode.mp4')));
      await f.manager.initialize();
      expect(await link.exists(), isTrue);
      expect(await outside.exists(), isTrue);
    },
  );

  test('a newer unmatched native generation defers cleanup of its old recorded folder', () async {
    final f = await _Fixture.create();
    final title = Directory(p.join(f.root.path, 'anime', 'New native writer'));
    await title.create(recursive: true);
    final record = _record(p.join(title.path, 'episode.mp4'));
    await f.store.put(record);
    f.gateway.recovered.add(
      _LiveHandle(taskIdForGeneration(record.logicalId, 2)),
    );
    await f.manager.initialize();
    expect(await title.exists(), isTrue);
  });

  test(
    'legacy video deletion protects an empty paused V2 sibling folder',
    () async {
      final f = await _Fixture.create();
      final title = Directory(p.join(f.root.path, 'anime', 'Example'));
      final legacy = File(p.join(title.path, 'legacy.mp4'));
      await legacy.create(recursive: true);
      await legacy.writeAsBytes([1, 2, 3]);
      await f.store.put(
        _record(
          p.join(title.path, 'paused.mp4'),
          intent: DownloadUserIntent.paused,
        ),
      );
      expect(await f.manager.deleteLegacyDownloadedVideo(legacy), isTrue);
      expect(await legacy.exists(), isFalse);
      expect(await title.exists(), isTrue);
    },
  );

  test('unknown live native writer defers dedicated orphan sweep', () async {
    final f = await _Fixture.create();
    final empty = Directory(
      p.join(f.root.path, 'AnimeWitcher', 'Downloads', 'Unknown writer'),
    );
    await empty.create(recursive: true);
    f.gateway.recovered.add(_LiveHandle());
    await f.manager.initialize();
    expect(await empty.exists(), isTrue);
  });
  test('legacy deletion cannot unlink a current logical owner or its partial bytes', () async {
    final f = await _Fixture.create();
    final file = File(p.join(f.root.path, 'anime', 'Example', 'episode.mp4'));
    await file.create(recursive: true);
    await file.writeAsBytes([1, 2, 3]);
    final partial = File('${file.path}.part');
    await partial.writeAsBytes([4, 5, 6]);
    final owner = _record(file.path, intent: DownloadUserIntent.paused);
    await f.store.put(owner);
    expect(await f.manager.deleteLegacyDownloadedVideo(file), isFalse);
    expect(await file.readAsBytes(), [1, 2, 3]);
    expect(await partial.readAsBytes(), [4, 5, 6]);
    expect(
      (await f.store.get(owner.logicalId))!.intent,
      DownloadUserIntent.paused,
    );
  });
}

LogicalDownloadRecordV2 _record(
  String path, {
  bool manga = false,
  String unit = '357',
  DownloadUserIntent intent = DownloadUserIntent.canceled,
}) {
  final id = manga
      ? logicalDownloadIdForMangaChapter(mangaId: 'm1', chapterId: unit)
      : logicalDownloadIdFor(
          animeId: 'a1',
          episodeKey: unit,
          variantKey: 'original',
        );
  return LogicalDownloadRecordV2(
    schemaVersion: kLogicalDownloadSchemaVersionV2,
    logicalId: id,
    mediaKind: manga
        ? DownloadMediaKind.mangaChapter
        : DownloadMediaKind.videoEpisode,
    mediaId: manga ? 'm1' : 'a1',
    unitKey: unit,
    variantKey: manga ? 'pages' : 'original',
    generation: 1,
    taskId: taskIdForGeneration(id, 1),
    intent: intent,
    destinationPath: path,
    sourceDescriptor: const {},
    updatedAtMillis: 1,
  );
}

final class _Fixture {
  _Fixture(this.root, this.store, this.gateway, this.manager);
  final Directory root;
  final InMemoryLogicalDownloadStoreV2 store;
  final _Gateway gateway;
  final DownloadManagerV2 manager;

  static Future<_Fixture> create() async {
    final root = await Directory.systemTemp.createTemp('aw-empty-folders-');
    final previous = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    final store = InMemoryLogicalDownloadStoreV2();
    final gateway = _Gateway();
    final manager = DownloadManagerV2(
      store: store,
      gateway: gateway,
      sourceResolver: StaticSourceResolverV2(),
    );
    addTearDown(() async {
      await manager.dispose();
      PathProviderPlatform.instance = previous;
      await root.delete(recursive: true);
    });
    return _Fixture(root, store, gateway, manager);
  }
}

final class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getDownloadsPath() async => root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

final class _Gateway implements BackgroundDownloaderGateway {
  final recovered = <DownloadTransportHandle>[];
  @override
  Future<void> initialize() async {}
  @override
  Future<List<DownloadTransportHandle>> rehydrate() async => recovered;
  @override
  Future<DownloadTransportHandle?> attach(String taskId) async => null;
  @override
  Future<void> removeTracking(String taskId) async {}
  @override
  Future<DownloadTransportHandle> start(DownloadTaskSpecV2 spec) async =>
      throw StateError('Unexpected start');
}

final class _LiveHandle implements DownloadTransportHandle {
  _LiveHandle([this.taskId = 'unrecognized-native-task']);
  @override
  final String taskId;
  @override
  DownloadTransportSnapshot get current => DownloadTransportSnapshot(
    taskId: taskId,
    status: DownloadTransportStatus.running,
    progress: 0,
  );
  @override
  Stream<DownloadTransportSnapshot> get snapshots => const Stream.empty();
  @override
  Future<bool> cancel() async => false;
  @override
  Future<bool> pause() async => false;
  @override
  Future<bool> resume() async => false;
}
