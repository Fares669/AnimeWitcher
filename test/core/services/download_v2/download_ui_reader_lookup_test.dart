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
    addTearDown(controller.dispose);
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
    addTearDown(controller.dispose);
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
      addTearDown(controller.dispose);
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
      addTearDown(controller.dispose);
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
