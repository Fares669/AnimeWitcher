import 'dart:io';

import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/services/download_v2/manga_chapter_manifest_v2.dart';
import 'package:animewitcher/core/storage/manga_reading_repository.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/manga/reader/manga_reader_controller.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

final class _Provider extends AnimeWitcherProvider {
  int pageCalls = 0;

  @override
  String get packageName => 'p';
  @override
  String get name => 'p';
  @override
  String get mainUrl => 'https://example.test';
  @override
  String get version => '1';
  @override
  List<String> get languages => const ['ar'];
  @override
  Set<ProviderType> get supportedTypes => const {ProviderType.manga};

  @override
  Future<List<MultimediaItem>> search(String query, {CancelToken? cancelToken}) async => const [];
  @override
  Future<Map<String, List<MultimediaItem>>> getHome() async => const {};
  @override
  Future<MultimediaItem> getDetails(String url) => throw UnsupportedError('');
  @override
  Future<List<StreamResult>> loadStreams(String url) async => const [];

  @override
  Future<List<MangaPage>> getMangaChapterPages(
    String mangaUrl,
    MangaChapter chapter,
  ) async {
    pageCalls++;
    throw StateError('network should not be used');
  }
}

final class _MemoryStorage extends StorageService {
  final Map<String, String> values = {};
  @override
  String? getString(String key) => values[key];
  @override
  Future<void> setString(String key, String? value) async {
    if (value == null) values.remove(key); else values[key] = value;
  }
  @override
  Future<void> remove(String key) async => values.remove(key);
}

void main() {
  test('reader prefers complete local manga chapter without network', () async {
    final dir = await Directory.systemTemp.createTemp('aw_manga_offline_');
    addTearDown(() => dir.delete(recursive: true));

    await MangaChapterManifestV2(
      version: MangaChapterManifestV2.currentVersion,
      mangaId: 'm1',
      chapterId: '1',
      pageCount: 2,
      completedIndexes: const {0, 1},
      isComplete: true,
    ).writeTo(dir);
    await File('${dir.path}/0001.webp').writeAsBytes([1]);
    await File('${dir.path}/0002.png').writeAsBytes([2]);

    final provider = _Provider();
    final controller = MangaReaderController(
      provider: provider,
      progressRepository: MangaReadingRepository(_MemoryStorage()),
      manga: MultimediaItem(
        title: 'Manga',
        url: 'manga://m1',
        posterUrl: '',
        contentType: MultimediaContentType.manga,
        syncData: const {'mangaId': 'm1'},
      ),
      chapter: const MangaChapter(
        id: '1',
        mangaId: 'm1',
        url: 'chapter://1',
        name: 'Chapter 1',
      ),
      chapters: const [],
      localChapterDirectory: dir.path,
    );

    await controller.load();

    expect(provider.pageCalls, 0);
    expect(controller.pages, hasLength(2));
    expect(controller.pages.every((page) => page.imageUrl.startsWith('file:')), isTrue);
  });
}
