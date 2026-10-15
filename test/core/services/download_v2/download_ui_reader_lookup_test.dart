import 'dart:async';
import 'dart:io';

import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/services/download_v2/manga_chapter_manifest_v2.dart';
import 'package:animewitcher/core/storage/manga_reading_repository.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/manga/reader/manga_reader_controller.dart';
import 'package:animewitcher/features/manga/reader/manga_reader_page_cache.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/manga_image_fixtures.dart';

void main() {
  late Directory root;
  setUp(() async { root = await Directory.systemTemp.createTemp('aw-reader-lookup-'); });
  tearDown(() async { await root.delete(recursive: true); });
  const first = MangaChapter(id: '1', mangaId: 'saved-manga', url: 'chapter://1', name: 'One');
  const second = MangaChapter(id: '2', mangaId: 'saved-manga', url: 'chapter://2', name: 'Two');
  final manga = MultimediaItem(title: 'Manga', url: 'manga://saved', posterUrl: '', contentType: MultimediaContentType.manga);

  Future<Directory> save(MangaChapter chapter) async {
    final directory = await Directory('${root.path}/${chapter.mangaId}-${chapter.id}').create();
    final file = await File('${directory.path}/0001.jpg').writeAsBytes(tinyMangaJpeg);
    await MangaChapterManifestV2(
      version: MangaChapterManifestV2.currentVersion, mangaId: chapter.mangaId,
      chapterId: chapter.id, pageCount: 1, completedIndexes: const {0}, isComplete: true,
      pageDigests: {0: await MangaChapterManifestV2.pageDigest(file)},
    ).writeTo(directory);
    return directory;
  }

  test('a remote preload reply after disposal cannot recreate its cache directory', () async {
    final directory = await save(first);
    final cacheOwner = await Directory('${root.path}/cache-owner').create();
    final provider = _BlockedProvider();
    final cache = _ObservedPageCache(Directory('${cacheOwner.path}/cache'));
    final controller = MangaReaderController(
      provider: provider, progressRepository: MangaReadingRepository(_Storage()), manga: manga,
      chapter: first, chapters: const [first, second], pageCache: cache,
      localChapterDirectoryFor: (chapter) async => chapter.id == first.id ? directory.path : null,
    );
    await controller.load();
    await provider.entered.future.timeout(const Duration(seconds: 2));
    controller.dispose();
    await controller.close().timeout(const Duration(seconds: 2));
    expect(provider.reply.isCompleted, isFalse, reason: 'close must not wait for a remote extension');
    await cacheOwner.delete(recursive: true);
    provider.reply.complete([const MangaPage(index: 0, imageUrl: 'https://remote.test/2')]);
    // The provider reply has no I/O before the decision to start a cache put.
    await Future<void>.delayed(Duration.zero);
    final lateWrite = cache.putStarted.isCompleted;
    if (lateWrite) await cache.putFinished.future.timeout(const Duration(seconds: 2));
    expect(lateWrite, isFalse, reason: 'a disposed preload must not start another filesystem producer');
    expect(cacheOwner.existsSync(), isFalse);
  });

  test('close drains an accepted local cache write before directory cleanup', () async {
    final directory = await save(first);
    final cacheOwner = await Directory('${root.path}/cache-owner').create();
    final cache = _BlockedPutCache(Directory('${cacheOwner.path}/cache'));
    final controller = MangaReaderController(
      provider: _Provider(), progressRepository: MangaReadingRepository(_Storage()), manga: manga,
      chapter: first, chapters: const [first, second], pageCache: cache,
      localChapterDirectoryFor: (chapter) async => chapter.id == first.id ? directory.path : null,
    );
    await controller.load();
    await cache.putStarted.future.timeout(const Duration(seconds: 2));
    var closed = false;
    final closing = controller.close();
    final completion = closing.then((_) { closed = true; });
    await Future<void>.delayed(Duration.zero);
    final closedBeforeWrite = closed;
    cache.release.complete();
    await completion.timeout(const Duration(seconds: 2));
    await cache.putFinished.future.timeout(const Duration(seconds: 2));
    await cacheOwner.delete(recursive: true);
    expect(closedBeforeWrite, isFalse, reason: 'accepted cache I/O must finish before close reports quiescence');
    expect(controller.close(), same(closing));
    expect(cacheOwner.existsSync(), isFalse);
  });

  test('a current chapter response after close cannot publish pages or cache writes', () async {
    final provider = _BlockedProvider();
    final cache = _ObservedPageCache(Directory('${root.path}/cache'));
    final controller = MangaReaderController(
      provider: provider, progressRepository: MangaReadingRepository(_Storage()), manga: manga,
      chapter: first, chapters: const [first], pageCache: cache,
    );
    var notifications = 0;
    controller.addListener(() { notifications++; });
    final loading = controller.load();
    await provider.entered.future.timeout(const Duration(seconds: 2));
    await controller.close().timeout(const Duration(seconds: 2));
    provider.reply.complete([const MangaPage(index: 0, imageUrl: 'https://remote.test/1')]);
    await loading.timeout(const Duration(seconds: 2));
    expect(controller.pages, isEmpty);
    expect(notifications, 1);
    expect(cache.putStarted.isCompleted, isFalse);
  });

  test('dispose observes a failed progress flush while close retains its error', () async {
    final directory = await save(first);
    final storage = _FailingStorage();
    final controller = MangaReaderController(
      provider: _Provider(), progressRepository: MangaReadingRepository(storage), manga: manga,
      chapter: first, chapters: const [first], localChapterDirectory: directory.path,
      pageCache: MangaReaderPageCache(cacheDirectory: Directory('${root.path}/cache')),
    );
    await controller.load();
    controller.dispose();
    // A synchronous widget dispose has no caller waiting for the final flush.
    await Future<void>.delayed(Duration.zero);
    await expectLater(controller.close(), throwsA(same(storage.failure)));
  });

  test('completed local directory wins over a stale remote page cache', () async {
    final directory = await save(first);
    final provider = _Provider();
    final cache = MangaReaderPageCache(cacheDirectory: Directory('${root.path}/cache'));
    await cache.put(first.mangaId, first, const [MangaPage(index: 0, imageUrl: 'https://stale.test/page')]);
    final controller = MangaReaderController(
      provider: provider, progressRepository: MangaReadingRepository(_Storage()), manga: manga,
      chapter: first, chapters: const [first], pageCache: cache,
      localChapterDirectoryFor: (_) async => directory.path,
    );
    addTearDown(controller.close);
    await controller.load();
    expect(controller.pages.single.imageUrl, File('${directory.path}/0001.jpg').uri.toString());
    expect(provider.requests, isEmpty);
  });

  test('mixed local and remote chapters preserve local-first and initial-only fallback', () async {
    final directory = await save(first);
    final provider = _Provider();
    final controller = MangaReaderController(
      provider: provider, progressRepository: MangaReadingRepository(_Storage()), manga: manga,
      chapter: first, chapters: const [first, second], localChapterDirectory: directory.path,
      pageCache: MangaReaderPageCache(cacheDirectory: Directory('${root.path}/cache')),
      localChapterDirectoryFor: (chapter) async => chapter.id == first.id ? directory.path : null,
    );
    addTearDown(controller.close);
    await controller.load();
    expect(controller.pages.single.imageUrl, startsWith('file:'));
    await controller.nextChapter();
    expect(controller.pages.single.imageUrl, 'https://remote.test/2');
    expect(provider.requests, isNot(contains(first.id)));
    expect(provider.requests, contains(second.id));
    await controller.previousChapter();
    expect(controller.pages.single.imageUrl, File('${directory.path}/0001.jpg').uri.toString());
  });

  for (final deletePage in [false, true]) {
    test('adjacent local preload is revalidated after its page is ${deletePage ? 'deleted' : 'edited'}', () async {
      final firstDirectory = await save(first);
      final secondDirectory = await save(second);
      final adjacentPage = File('${secondDirectory.path}/0001.jpg');
      final digestRead = Completer<void>();
      final provider = _Provider();
      final controller = MangaReaderController(
        provider: provider, progressRepository: MangaReadingRepository(_Storage()), manga: manga,
        chapter: first, chapters: const [first, second],
        pageCache: MangaReaderPageCache(cacheDirectory: Directory('${root.path}/cache')),
        localChapterDirectoryFor: (chapter) async => chapter.id == first.id
            ? firstDirectory.path : secondDirectory.path,
      );
      addTearDown(controller.close);
      final parentZone = Zone.current;
      await IOOverrides.runZoned(() async {
        await controller.load();
        await digestRead.future.timeout(const Duration(seconds: 2));
        // The final digest has no further I/O before local preload publication.
        // This event-loop barrier drains its completion microtasks first.
        await Future<void>.delayed(Duration.zero);
      }, createDirectory: (path) => _DigestObservedDirectory(
        parentZone.run(() => Directory(path)), adjacentPage.path, digestRead,
      ));
      expect(digestRead.isCompleted, isTrue, reason: 'the adjacent digest must actually finish before mutation');
      expect(provider.requests, isEmpty);
      if (deletePage) {
        await adjacentPage.delete();
      } else {
        await adjacentPage.writeAsBytes(tinyMangaPng);
      }
      await controller.nextChapter();
      expect(controller.pages.single.imageUrl, 'https://remote.test/2');
      expect(provider.requests, contains(second.id));
    });
  }

  for (final wrongManga in [false, true]) {
    test('directory manifest with wrong ${wrongManga ? 'manga' : 'chapter'} identity is rejected', () async {
      final wrong = MangaChapter(id: wrongManga ? first.id : 'wrong', mangaId: wrongManga ? 'other-manga' : first.mangaId, url: 'chapter://wrong', name: 'Wrong');
      final directory = await save(wrong);
      final provider = _Provider();
      final controller = MangaReaderController(
        provider: provider, progressRepository: MangaReadingRepository(_Storage()), manga: manga,
        chapter: first, chapters: const [first],
        pageCache: MangaReaderPageCache(cacheDirectory: Directory('${root.path}/cache')),
        localChapterDirectoryFor: (_) async => directory.path,
      );
      addTearDown(controller.close);
      await controller.load();
      expect(controller.pages.single.imageUrl, 'https://remote.test/1');
      expect(provider.requests, [first.id]);
    });
  }
}

// Observe only the digest-bearing page yielded by directory.list. All I/O is
// forwarded, including fresh navigation after the observation zone has ended.
class _DigestObservedDirectory implements Directory {
  _DigestObservedDirectory(this.directory, this.pagePath, this.done);
  final Directory directory;
  final String pagePath;
  final Completer<void> done;
  @override
  String get path => directory.path;
  @override
  Future<bool> exists() => directory.exists();
  @override
  Stream<FileSystemEntity> list({bool recursive = false, bool followLinks = true}) =>
      directory.list(recursive: recursive, followLinks: followLinks).map((entity) =>
          entity is File && entity.path == pagePath ? _DigestObservedFile(entity, done) : entity);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _DigestObservedFile implements File {
  _DigestObservedFile(this.file, this.done);
  final File file;
  final Completer<void> done;
  @override
  String get path => file.path;
  @override
  Uri get uri => file.uri;
  @override
  Future<bool> exists() => file.exists();
  @override
  Future<int> length() => file.length();
  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) => file.open(mode: mode);
  @override
  Stream<List<int>> openRead([int? start, int? end]) => file.openRead(start, end).transform(
    StreamTransformer<List<int>, List<int>>.fromHandlers(handleDone: (sink) {
      if (!done.isCompleted) done.complete();
      sink.close();
    }),
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Storage extends StorageService {
  final values = <String, String>{};
  @override
  String? getString(String key) => values[key];
  @override
  Future<void> setString(String key, String? value) async {
    if (value == null) { values.remove(key); } else { values[key] = value; }
  }
}

class _FailingStorage extends _Storage {
  final failure = StateError('progress storage unavailable');
  @override
  Future<void> setString(String key, String? value) async => throw failure;
}

class _Provider extends AnimeWitcherProvider {
  final requests = <String>[];
  @override
  String get packageName => 'test.reader.lookup';
  @override
  String get name => 'Reader lookup';
  @override
  String get mainUrl => 'https://remote.test';
  @override
  String get version => '1';
  @override
  List<String> get languages => const ['ar'];
  @override
  Set<ProviderType> get supportedTypes => const {ProviderType.manga};
  @override
  Future<Map<String, List<MultimediaItem>>> getHome() async => const {};
  @override
  Future<List<MultimediaItem>> search(String query, {CancelToken? cancelToken}) async => const [];
  @override
  Future<MultimediaItem> getDetails(String url) async => throw UnimplementedError();
  @override
  Future<List<StreamResult>> loadStreams(String url) async => const [];
  @override
  Future<List<MangaPage>> getMangaChapterPages(String mangaUrl, MangaChapter chapter) async {
    requests.add(chapter.id);
    return [MangaPage(index: 0, imageUrl: 'https://remote.test/${chapter.id}')];
  }
}

class _BlockedProvider extends _Provider {
  final entered = Completer<void>();
  final reply = Completer<List<MangaPage>>();
  @override
  Future<List<MangaPage>> getMangaChapterPages(String mangaUrl, MangaChapter chapter) {
    requests.add(chapter.id);
    if (!entered.isCompleted) entered.complete();
    return reply.future;
  }
}

class _ObservedPageCache extends MangaReaderPageCache {
  _ObservedPageCache(Directory directory) : super(cacheDirectory: directory);
  final putStarted = Completer<void>();
  final putFinished = Completer<void>();
  @override
  Future<void> put(String mangaId, MangaChapter chapter, List<MangaPage> pages) async {
    if (!putStarted.isCompleted) putStarted.complete();
    try {
      await super.put(mangaId, chapter, pages);
    } finally {
      if (!putFinished.isCompleted) putFinished.complete();
    }
  }
}

class _BlockedPutCache extends _ObservedPageCache {
  _BlockedPutCache(super.directory);
  final release = Completer<void>();
  @override
  Future<void> put(String mangaId, MangaChapter chapter, List<MangaPage> pages) async {
    if (!putStarted.isCompleted) putStarted.complete();
    await release.future;
    await super.put(mangaId, chapter, pages);
  }
}
