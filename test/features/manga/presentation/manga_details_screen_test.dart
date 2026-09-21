import 'dart:io';

import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/features/manga/presentation/manga_details_screen.dart';
import 'package:animewitcher/features/manga/reader/manga_reader_cover_provider.dart';
import 'package:animewitcher/features/manga/reader/manga_reader_settings.dart';
import 'package:animewitcher/features/manga/reader/manga_reader_settings_provider.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final class _MangaProvider extends AnimeWitcherProvider {
  int detailsCalls = 0;
  int chaptersCalls = 0;
  bool detailsFinished = false;
  bool chaptersStartedBeforeDetailsFinished = false;

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
  Future<MultimediaItem> getMangaDetails(String url) async {
    detailsCalls += 1;
    await Future<void>.delayed(Duration.zero);
    detailsFinished = true;
    return MultimediaItem(
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
  }

  @override
  Future<List<MangaChapter>> getMangaChapters(String url) async {
    chaptersCalls += 1;
    chaptersStartedBeforeDetailsFinished = !detailsFinished;
    return const <MangaChapter>[
      MangaChapter(
        id: '12.5',
        mangaId: 'm1',
        url: 'chapter://12.5',
        name: 'الفصل 12.5',
        number: 12.5,
      ),
    ];
  }
}

final class _MangaDetailsReaderSettingsNotifier
    extends MangaReaderSettingsNotifier {
  @override
  MangaReaderSettings build() => const MangaReaderSettings();
}

String _testCustomCoverUri = '';

final class _MangaDetailsEmptyCoverNotifier
    extends MangaReaderCustomCoversNotifier {
  @override
  Map<String, String> build() => const <String, String>{};
}

final class _MangaDetailsCustomCoverNotifier
    extends MangaReaderCustomCoversNotifier {
  @override
  Map<String, String> build() => <String, String>{
    'https://animewitcher.com/manga/m1': _testCustomCoverUri,
  };
}

final class _Manager extends ExtensionManager {
  _Manager(this.provider);
  final AnimeWitcherProvider provider;

  @override
  List<AnimeWitcherProvider> build() => <AnimeWitcherProvider>[provider];
}

Widget _app(
  AnimeWitcherProvider provider, {
  bool customCover = false,
}) => ProviderScope(
  overrides: [
    extensionManagerProvider.overrideWith(() => _Manager(provider)),
    mangaReaderSettingsProvider.overrideWith(
      _MangaDetailsReaderSettingsNotifier.new,
    ),
    mangaReaderCustomCoversProvider.overrideWith(
      customCover
          ? _MangaDetailsCustomCoverNotifier.new
          : _MangaDetailsEmptyCoverNotifier.new,
    ),
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
  testWidgets('manga details loads details before chapters on route open', (
    tester,
  ) async {
    final provider = _MangaProvider();

    expect(provider.detailsCalls, 0);
    expect(provider.chaptersCalls, 0);

    await tester.pumpWidget(_app(provider));
    await tester.pumpAndSettle();

    expect(provider.detailsCalls, 1);
    expect(provider.chaptersCalls, 1);
    expect(provider.chaptersStartedBeforeDetailsFinished, isFalse);
  });

  testWidgets('long pressing manga title copies it like anime details', (
    tester,
  ) async {
    String? clipboardText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData' && call.arguments is Map) {
          clipboardText = Map<Object?, Object?>.from(
            call.arguments as Map,
          )['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });

    await tester.pumpWidget(_app(_MangaProvider()));
    await tester.pumpAndSettle();

    final title = find.descendant(
      of: find.byKey(const ValueKey('manga-details-hero')),
      matching: find.text('Solo Leveling'),
    );
    expect(title, findsOneWidget);

    await tester.longPress(title);
    await tester.pump();

    expect(clipboardText, 'Solo Leveling');

    // NotificationService keeps the success toast alive for one second.
    // Let that timer expire so this widget test does not leak a pending timer.
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('manga details uses the reader custom cover override', (
    tester,
  ) async {
    final temp = await Directory.systemTemp.createTemp('aw_manga_cover_');
    addTearDown(() => temp.delete(recursive: true));
    final cover = File('${temp.path}/cover.webp');
    await cover.writeAsBytes(<int>[
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
      0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
      0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
      0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
      0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41,
      0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
      0x00, 0x04, 0x00, 0x01, 0xDD, 0x8D, 0xB1, 0x1C,
      0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44,
      0xAE, 0x42, 0x60, 0x82,
    ]);
    _testCustomCoverUri = cover.uri.toString();

    await tester.pumpWidget(_app(_MangaProvider(), customCover: true));
    await tester.pump();
    await tester.pump();

    expect(
      find.byKey(const ValueKey('manga-details-custom-cover')),
      findsWidgets,
    );
  });

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
