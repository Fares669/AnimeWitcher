import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class _LegacyProvider extends AnimeWitcherProvider {
  @override
  String get packageName => 'test.legacy';

  @override
  String get name => 'Legacy';

  @override
  String get mainUrl => 'https://example.invalid';

  @override
  String get version => '1';

  @override
  List<String> get languages => const <String>['ar'];

  @override
  Set<ProviderType> get supportedTypes => const <ProviderType>{
    ProviderType.anime,
  };

  @override
  Future<List<MultimediaItem>> search(
    String query, {
    CancelToken? cancelToken,
  }) async => const <MultimediaItem>[];

  @override
  Future<Map<String, List<MultimediaItem>>> getHome() async =>
      const <String, List<MultimediaItem>>{};

  @override
  Future<MultimediaItem> getDetails(String url) async => MultimediaItem(
    title: 'Anime',
    url: url,
    posterUrl: '',
    contentType: MultimediaContentType.anime,
  );

  @override
  Future<List<StreamResult>> loadStreams(String url) async =>
      const <StreamResult>[];
}

void main() {
  test('older providers get safe empty manga catalog defaults', () async {
    final provider = _LegacyProvider();

    final page = await provider.searchMangaPage(
      'query',
      const ProviderSearchFilters(),
    );
    final chapters = await provider.getMangaChapters('manga://m1');
    final pages = await provider.getMangaChapterPages(
      'manga://m1',
      const MangaChapter(
        id: 'c1',
        mangaId: 'm1',
        url: 'chapter://c1',
        name: 'Chapter 1',
        number: 1,
      ),
    );
    final latest = await provider.getLatestMangaPage();

    expect(page.items, isEmpty);
    expect(page.hasMore, isFalse);
    expect(chapters, isEmpty);
    expect(pages, isEmpty);
    expect(latest.items, isEmpty);
    expect(latest.hasMore, isFalse);
  });

  test('manga details is unsupported unless provider opts in', () async {
    final provider = _LegacyProvider();

    expect(
      () => provider.getMangaDetails('manga://m1'),
      throwsA(isA<UnsupportedError>()),
    );
  });
}
