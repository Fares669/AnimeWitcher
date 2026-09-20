import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/features/manga/presentation/manga_details_screen.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final class _MangaProvider extends AnimeWitcherProvider {
  @override
  String get packageName => 'test.manga';

  @override
  String get name => 'Manga Provider';

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
  Future<MultimediaItem> getDetails(String url) =>
      throw UnsupportedError('Anime details must not be used');

  @override
  Future<List<StreamResult>> loadStreams(String url) =>
      throw UnsupportedError('Streams must not be used');

  @override
  Future<MultimediaItem> getMangaDetails(String url) async => MultimediaItem(
    title: 'Solo Leveling',
    url: url,
    posterUrl: '',
    description: 'Manga description',
    contentType: MultimediaContentType.manga,
    provider: packageName,
    catalogType: 'مانهوا',
    year: 2018,
    tags: const <String>['Action', 'Fantasy'],
  );

  @override
  Future<List<MangaChapter>> getMangaChapters(String url) async =>
      const <MangaChapter>[
        MangaChapter(
          id: '12.5',
          mangaId: 'm1',
          url: 'chapter://12.5',
          name: 'الفصل 12.5',
          number: 12.5,
        ),
      ];
}

final class _Manager extends ExtensionManager {
  _Manager(this.provider);
  final AnimeWitcherProvider provider;

  @override
  List<AnimeWitcherProvider> build() => <AnimeWitcherProvider>[provider];
}

Widget _app(AnimeWitcherProvider provider) => ProviderScope(
  overrides: [
    extensionManagerProvider.overrideWith(() => _Manager(provider)),
  ],
  child: MaterialApp(
    locale: const Locale('ar'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: MangaDetailsScreen(
      item: MultimediaItem(
        title: 'Solo Leveling',
        url: 'https://animewitcher.com/manga/m1',
        posterUrl: '',
        contentType: MultimediaContentType.manga,
        provider: provider.packageName,
        syncData: const <String, String>{
          'mangaId': 'm1',
          'awScore': '9.2',
        },
      ),
    ),
  ),
);

void main() {
  testWidgets('manga details renders only details and chapters tabs', (
    tester,
  ) async {
    await tester.pumpWidget(_app(_MangaProvider()));
    await tester.pumpAndSettle();

    final tabBar = tester.widget<TabBar>(find.byType(TabBar));
    expect(tabBar.indicatorSize, isNull);

    expect(find.text('التفاصيل'), findsOneWidget);
    expect(find.textContaining('الفصول'), findsOneWidget);
    expect(find.text('Solo Leveling'), findsWidgets);
    expect(find.text('Manga description'), findsOneWidget);
    expect(find.text('9.2'), findsOneWidget);
    expect(find.byKey(const ValueKey('manga-details-hero')), findsOneWidget);
    expect(find.byKey(const ValueKey('manga-rate-action')), findsOneWidget);
    expect(find.byIcon(Icons.favorite_border_rounded), findsOneWidget);
    expect(find.byIcon(Icons.bookmark_border_rounded), findsOneWidget);
    expect(find.text('المراجعات'), findsNothing);

    final actionGenre = find.byKey(const ValueKey('manga-genre-Action'));
    expect(actionGenre, findsOneWidget);
    expect(
      find.ancestor(of: actionGenre, matching: find.byType(InkWell)),
      findsNothing,
    );

    await tester.tap(find.textContaining('الفصول'));

    await tester.pumpAndSettle();

    expect(find.text('الفصل 12.5'), findsOneWidget);
    expect(find.text('الحلقات'), findsNothing);
    expect(find.text('التعليقات'), findsNothing);
    expect(find.text('المراجعات'), findsNothing);
    expect(find.text('الشخصيات'), findsNothing);
    expect(find.text('متشابهة'), findsNothing);
    expect(find.text('ذات صلة'), findsNothing);
  });
}
