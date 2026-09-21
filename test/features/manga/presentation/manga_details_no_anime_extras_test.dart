import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/features/manga/presentation/manga_details_screen.dart';
import 'package:animewitcher/features/manga/reader/manga_reader_cover_provider.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final class _CountingProvider extends AnimeWitcherProvider {
  int animeDetailsCalls = 0;
  int castCalls = 0;
  int relatedCalls = 0;
  int recommendationCalls = 0;
  int episodesCalls = 0;
  int streamCalls = 0;
  int mangaDetailsCalls = 0;
  int mangaChapterCalls = 0;

  @override
  String get packageName => 'counting.manga';

  @override
  String get name => 'Counting Manga';

  @override
  String get mainUrl => 'https://example.test';

  @override
  String get version => '1';

  @override
  List<String> get languages => const <String>['ar'];

  @override
  Set<ProviderType> get supportedTypes => const <ProviderType>{
    ProviderType.manga,
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
  Future<MultimediaItem> getDetails(String url) async {
    animeDetailsCalls++;
    throw UnsupportedError('anime details');
  }

  @override
  Future<List<Actor>> getCast(String url) async {
    castCalls++;
    return const <Actor>[];
  }

  @override
  Future<List<MultimediaItem>> getRelated(String url) async {
    relatedCalls++;
    return const <MultimediaItem>[];
  }

  @override
  Future<List<MultimediaItem>> getRecommendations(String url) async {
    recommendationCalls++;
    return const <MultimediaItem>[];
  }

  @override
  Future<List<Episode>> getEpisodes(String url) async {
    episodesCalls++;
    return const <Episode>[];
  }

  @override
  Future<List<StreamResult>> loadStreams(String url) async {
    streamCalls++;
    return const <StreamResult>[];
  }

  @override
  Future<MultimediaItem> getMangaDetails(String url) async {
    mangaDetailsCalls++;
    return MultimediaItem(
      title: 'Manga',
      url: url,
      posterUrl: '',
      contentType: MultimediaContentType.manga,
      provider: packageName,
    );
  }

  @override
  Future<List<MangaChapter>> getMangaChapters(String url) async {
    mangaChapterCalls++;
    return const <MangaChapter>[];
  }
}

final class _EmptyCustomCoverNotifier
    extends MangaReaderCustomCoversNotifier {
  @override
  Map<String, String> build() => const <String, String>{};
}

final class _Manager extends ExtensionManager {
  _Manager(this.provider);
  final AnimeWitcherProvider provider;

  @override
  List<AnimeWitcherProvider> build() => <AnimeWitcherProvider>[provider];
}

void main() {
  testWidgets('opening manga details never touches anime-only provider APIs', (
    tester,
  ) async {
    final provider = _CountingProvider();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          extensionManagerProvider.overrideWith(() => _Manager(provider)),
          mangaReaderCustomCoversProvider.overrideWith(
            _EmptyCustomCoverNotifier.new,
          ),
        ],
        child: MaterialApp(
          locale: const Locale('ar'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: MangaDetailsScreen(
            item: MultimediaItem(
              title: 'Manga',
              url: 'https://animewitcher.com/manga/m1',
              posterUrl: '',
              contentType: MultimediaContentType.manga,
              provider: provider.packageName,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(provider.mangaDetailsCalls, 1);
    expect(provider.mangaChapterCalls, 1);
    expect(provider.animeDetailsCalls, 0);
    expect(provider.castCalls, 0);
    expect(provider.relatedCalls, 0);
    expect(provider.recommendationCalls, 0);
    expect(provider.episodesCalls, 0);
    expect(provider.streamCalls, 0);
  });
}
