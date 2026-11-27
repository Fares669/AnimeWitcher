import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_models.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/extensions/providers/animewitcher_native_provider.dart';
import 'package:animewitcher/core/storage/settings_repository.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/more/presentation/seasons_screen.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:animewitcher/shared/widgets/app_back_button.dart';
import 'package:animewitcher/shared/widgets/app_page_header.dart';
import 'package:animewitcher/shared/widgets/multimedia_card.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/test_fonts.dart';
import '../../../support/debug_shots.dart';

class _SignedOutAccount extends AnimeWitcherAccountController {
  @override
  Future<AnimeWitcherAccountSnapshot> build() async {
    return const AnimeWitcherAccountSnapshot();
  }
}

class _MemoryStorage extends StorageService {
  final Map<String, String> values = <String, String>{};

  @override
  bool isHighQualityPostersEnabled() => false;

  @override
  bool isEpisodeImagesFromAniZipEnabled() => false;

  @override
  Future<void> setString(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  String? getString(String key) => values[key];
}

class _StubSeasonsProvider extends AnimeWitcherNativeProvider {
  _StubSeasonsProvider() : super(Dio(), SettingsRepository(_MemoryStorage()));

  static const String past = 'ربيع عام 2026';
  static const String current = 'صيف عام 2026';
  static const String next = 'خريف عام 2026';
  static const List<String> allSeasons = <String>[
    'شتاء عام 2026',
    'ربيع عام 2026',
    'صيف عام 2026',
    'خريف عام 2026',
    'شتاء عام 2025',
    'ربيع عام 2025',
    'صيف عام 2025',
    'خريف عام 2025',
  ];

  @override
  Future<AnimeWitcherSeasonConfig> getSeasonConfig() async {
    return const AnimeWitcherSeasonConfig(
      past: past,
      current: current,
      next: next,
    );
  }

  @override
  Future<List<String>> getAllSeasons({bool refresh = false}) async {
    return List<String>.unmodifiable(allSeasons);
  }

  @override
  Future<ProviderMediaPage> getSeasonPage(
    String season, {
    int offset = 0,
    int limit = 30,
  }) async {
    return ProviderMediaPage(
      items: <MultimediaItem>[
        MultimediaItem(
          title: 'Black Torch',
          url: 'https://animewitcher.test/black-torch',
          posterUrl: '',
          catalogType: 'مسلسل',
        ),
        MultimediaItem(
          title: 'Dogulwang',
          url: 'https://animewitcher.test/dogulwang',
          posterUrl: '',
          catalogType: 'مسلسل',
        ),
      ],
      nextOffset: 2,
      hasMore: false,
    );
  }
}

class _ScrollableSeasonsProvider extends _StubSeasonsProvider {
  final requests = <String>[];

  @override
  Future<ProviderMediaPage> getSeasonPage(
    String season, {
    int offset = 0,
    int limit = 30,
  }) async {
    requests.add(season);
    return ProviderMediaPage(
      items: [
        for (var i = 0; i < 30; i++)
          MultimediaItem(
            title: 'Show $i',
            url: 'test://$season/$i',
            posterUrl: '',
          ),
      ],
      nextOffset: 30,
      hasMore: false,
    );
  }
}

class _PendingAppendProvider extends _ScrollableSeasonsProvider {
  final append = Completer<ProviderMediaPage>();
  final appendOffsets = <int>[];

  @override
  Future<ProviderMediaPage> getSeasonPage(
    String season, {
    int offset = 0,
    int limit = 30,
  }) async {
    if (season == _StubSeasonsProvider.current && offset > 0) {
      appendOffsets.add(offset);
      return append.future;
    }
    final first = await super.getSeasonPage(
      season,
      offset: offset,
      limit: limit,
    );
    return ProviderMediaPage(
      items: first.items,
      nextOffset: first.nextOffset,
      hasMore: season == _StubSeasonsProvider.current,
    );
  }
}

Future<void> _pumpSeasons(
  WidgetTester tester, {
  required AnimeWitcherNativeProvider provider,
  Key? shotKey,
  Size viewport = const Size(390, 844),
  String font = 'NotoSansArabic',
  bool openRoute = false,
}) async {
  await tester.binding.setSurfaceSize(viewport);
  addTearDown(() => tester.binding.setSurfaceSize(null));

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        animeWitcherAccountControllerProvider.overrideWith(
          _SignedOutAccount.new,
        ),
        extensionManagerProvider.overrideWithValue(<AnimeWitcherProvider>[
          provider,
        ]),
        activeProviderProvider.overrideWithValue(provider),
      ],
      child: MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(
          brightness: Brightness.dark,
          fontFamily: font,
          scaffoldBackgroundColor: Colors.black,
          colorScheme: const ColorScheme.dark(
            primary: Color(0xFFEEC60A),
            surface: Color(0xFF000000),
            onSurface: Color(0xFFE5E7EB),
          ),
        ),
        builder: openRoute && shotKey != null
            ? (context, child) => RepaintBoundary(key: shotKey, child: child)
            : null,
        home: openRoute
            ? Builder(
                builder: (context) => Scaffold(
                  body: Center(
                    child: FilledButton(
                      onPressed: () => Navigator.of(context).push<void>(
                        MaterialPageRoute(
                          builder: (_) => const SeasonsScreen(),
                        ),
                      ),
                      child: const Text('افتح المواسم'),
                    ),
                  ),
                ),
              )
            : shotKey == null
            ? const SeasonsScreen()
            : RepaintBoundary(key: shotKey, child: const SeasonsScreen()),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 50));
}

const Map<String, int> _seasonTabIndex = <String, int>{
  'السابق': 0,
  'الحالي': 1,
  'القادم': 2,
  'المواسم الأخرى': 3,
};

Future<void> _selectTab(WidgetTester tester, String label) async {
  final index = _seasonTabIndex[label]!;
  final bar = tester.widget<TabBar>(find.byType(TabBar));
  bar.controller!.animateTo(index);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void _expectTitleCentered(WidgetTester tester, String title) {
  final titleBox = tester.getRect(find.text(title).hitTestable());
  final screen = tester.getRect(find.byType(Scaffold));
  expect(
    (titleBox.center.dx - screen.center.dx).abs(),
    lessThan(2),
    reason: '"$title" should sit at the horizontal center, not the RTL start',
  );
}

Future<void> _writeShot(WidgetTester tester, Key key, String filename) async {
  final artifacts = debugShotDirectory();
  if (artifacts == null) return;
  await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(key),
    );
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    File('${artifacts.path}/$filename')
        .writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

Future<String?> _rgbaHash(WidgetTester tester, Key key) =>
    tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(key),
      );
      final image = await boundary.toImage();
      try {
        final rgba = (await image.toByteData())!;
        return sha256
            .convert(
              rgba.buffer.asUint8List(rgba.offsetInBytes, rgba.lengthInBytes),
            )
            .toString();
      } finally {
        image.dispose();
      }
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('loaded RTL Seasons keeps route configuration on tab changes', (
    tester,
  ) async {
    const font = 'C20SeasonsReadex';
    await tester.runAsync(() async {
      final loader = FontLoader(font)
        ..addFont(
          rootBundle.load('assets/fonts/readex_pro/ReadexPro-Regular.ttf'),
        );
      await loader.load();
    });
    for (final size in [const Size(390, 844), const Size(1280, 800)]) {
      const shotKey = ValueKey('season-route-frame');
      final provider = _ScrollableSeasonsProvider();
      await _pumpSeasons(
        tester,
        provider: provider,
        shotKey: shotKey,
        viewport: size,
        openRoute: true,
        font: font,
      );
      await tester.tap(find.text('افتح المواسم'));
      await tester.pumpAndSettle();

      final page = find.byType(SeasonsScreen);
      expect(Directionality.of(tester.element(page)), TextDirection.rtl);
      final appBar = find.byType(AppPageAppBar).hitTestable();
      final tabs = find.byType(TabBar).hitTestable();
      final body = find.byType(TabBarView).hitTestable();
      ScrollController scroll() => tester
          .widget<CustomScrollView>(
            find.byType(CustomScrollView).hitTestable().first,
          )
          .controller!;
      var appBarUpdates = 0;
      var bodyUpdates = 0;
      var childUpdates = 0;
      final hashes = <String?>[];

      if (size.width < 500)
        scroll().jumpTo(630);
      else
        scroll().jumpTo(320);
      await tester.pumpAndSettle();
      final originalOffset = scroll().offset;
      expect(originalOffset, greaterThan(0));
      hashes.add(await _rgbaHash(tester, shotKey));

      Future<void> switchTo(String label) async {
        final beforeBar = tester.widget<AppPageAppBar>(appBar);
        final beforeBody = tester.widget<TabBarView>(body);
        await _selectTab(tester, label);
        await tester.pumpAndSettle();
        expect(
          tester.widget<TabBar>(tabs).controller!.index,
          _seasonTabIndex[label],
        );
        final afterBar = tester.widget<AppPageAppBar>(appBar);
        final afterBody = tester.widget<TabBarView>(body);
        if (!identical(beforeBar, afterBar)) appBarUpdates++;
        if (!identical(beforeBody, afterBody)) bodyUpdates++;
        for (var i = 0; i < beforeBody.children.length; i++) {
          if (!identical(beforeBody.children[i], afterBody.children[i])) {
            childUpdates++;
          }
        }
      }

      await switchTo('السابق');
      _expectTitleCentered(tester, _StubSeasonsProvider.past);
      hashes.add(await _rgbaHash(tester, shotKey));
      await switchTo('القادم');
      _expectTitleCentered(tester, _StubSeasonsProvider.next);
      hashes.add(await _rgbaHash(tester, shotKey));
      await switchTo('المواسم الأخرى');
      final year = find.byKey(const ValueKey('other-season-year-2026'));
      expect(year.hitTestable(), findsOneWidget);
      hashes.add(await _rgbaHash(tester, shotKey));
      await tester.tap(find.text('شتاء').hitTestable().first);
      await tester.pumpAndSettle();
      expect(find.text('شتاء عام 2026'), findsOneWidget);
      expect(find.byType(MultimediaCard).hitTestable(), findsWidgets);
      await tester.tap(find.byType(AppBackButton).hitTestable().last);
      await tester.pumpAndSettle();
      expect(year.hitTestable(), findsOneWidget);
      expect(tester.widget<TabBar>(tabs).controller!.index, 3);
      hashes.add(await _rgbaHash(tester, shotKey));

      await switchTo('الحالي');
      expect(scroll().offset, closeTo(originalOffset, 0.01));
      final prefix = 'season-${_StubSeasonsProvider.current}-';
      expect(
        tester
            .widgetList<MultimediaCard>(
              find.byType(MultimediaCard, skipOffstage: false),
            )
            .every((card) => card.heroTag.startsWith(prefix)),
        isTrue,
      );
      hashes.add(await _rgbaHash(tester, shotKey));
      await switchTo('القادم');
      await switchTo('الحالي');
      expect(scroll().offset, closeTo(originalOffset, 0.01));
      expect(provider.requests, [
        _StubSeasonsProvider.current,
        _StubSeasonsProvider.past,
        _StubSeasonsProvider.next,
        'شتاء عام 2026',
      ]);
      expect(hashes, everyElement(isNotNull));
      debugPrint(
        'C20_SEASONS_RTL width=${size.width.toInt()} '
        'appbar=$appBarUpdates body=$bodyUpdates tabs=$childUpdates '
        'rgba=${hashes.join(',')}',
      );
      expect((appBarUpdates, bodyUpdates, childUpdates), (0, 0, 0));
      await tester.tap(find.byType(AppBackButton).hitTestable().last);
      await tester.pumpAndSettle();
      expect(find.text('افتح المواسم'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets(
    'past/current/next tabs show the centered settings season string',
    (tester) async {
      await tester.runAsync(TestFonts.loadWalkthroughFonts);
      const shotKey = ValueKey('seasons-shot');
      final provider = _StubSeasonsProvider();
      await _pumpSeasons(tester, provider: provider, shotKey: shotKey);

      expect(find.byType(SeasonListTitle).hitTestable(), findsOneWidget);
      expect(find.text('صيف عام 2026').hitTestable(), findsOneWidget);
      expect(find.text('Summer 2026'), findsNothing);
      expect(find.text('صيف 2026'), findsNothing);

      final tabsBottom = tester.getBottomLeft(find.text('الحالي')).dy;
      final titleBox = tester.getRect(find.text('صيف عام 2026').hitTestable());
      final gridTop = tester
          .getTopLeft(find.byType(MultimediaCard).hitTestable().first)
          .dy;
      expect(titleBox.top, greaterThan(tabsBottom));
      expect(titleBox.bottom, lessThan(gridTop));

      await _writeShot(tester, shotKey, 'seasons_current_title_centered.png');

      _expectTitleCentered(tester, 'صيف عام 2026');

      await _selectTab(tester, 'السابق');
      expect(find.text('ربيع عام 2026').hitTestable(), findsOneWidget);
      expect(find.text('صيف عام 2026').hitTestable(), findsNothing);
      _expectTitleCentered(tester, 'ربيع عام 2026');
      await _writeShot(tester, shotKey, 'seasons_previous_title_centered.png');

      await _selectTab(tester, 'القادم');
      expect(find.text('خريف عام 2026').hitTestable(), findsOneWidget);
      expect(find.text('ربيع عام 2026').hitTestable(), findsNothing);
      _expectTitleCentered(tester, 'خريف عام 2026');
      await _writeShot(tester, shotKey, 'seasons_next_title_centered.png');
    },
  );

  testWidgets(
    'season tab switches release offscreen cards without refetching',
    (tester) async {
      final provider = _ScrollableSeasonsProvider();
      await _pumpSeasons(tester, provider: provider);
      final cards = find.byType(MultimediaCard, skipOffstage: false);
      ScrollController visibleScroll() => tester
          .widget<CustomScrollView>(
            find.byType(CustomScrollView).hitTestable().first,
          )
          .controller!;

      final currentScroll = visibleScroll();
      currentScroll.jumpTo(630);
      await tester.pump();
      final currentCards = tester.widgetList<MultimediaCard>(cards).toList();
      expect(currentCards, isNotEmpty);
      expect(provider.requests, [_StubSeasonsProvider.current]);

      await _selectTab(tester, 'السابق');
      await tester.pumpAndSettle();
      await _selectTab(tester, 'القادم');
      await tester.pumpAndSettle();
      final visitedCards = tester.widgetList<MultimediaCard>(cards).toList();
      final currentPrefix = 'season-${_StubSeasonsProvider.current}-';
      final nextPrefix = 'season-${_StubSeasonsProvider.next}-';
      final retained = visitedCards
          .where((card) => card.heroTag.startsWith(currentPrefix))
          .length;
      debugPrint(
        'SEASON_PROFILE $retained previous-current cards after browsing '
        '${visitedCards.length} mounted cards total',
      );
      expect(retained, 0);
      expect(visitedCards, isNotEmpty);
      expect(
        visitedCards,
        everyElement(
          isA<MultimediaCard>().having(
            (card) => card.heroTag.startsWith(nextPrefix),
            'next season',
            isTrue,
          ),
        ),
      );

      await _selectTab(tester, 'الحالي');
      await tester.pumpAndSettle();
      expect(visibleScroll().offset, closeTo(630, 0.01));
      expect(provider.requests, [
        _StubSeasonsProvider.current,
        _StubSeasonsProvider.past,
        _StubSeasonsProvider.next,
      ]);
    },
  );

  testWidgets('a seasonal append survives leaving and returning mid-request', (
    tester,
  ) async {
    final provider = _PendingAppendProvider();
    await _pumpSeasons(tester, provider: provider);
    ScrollController visibleScroll() => tester
        .widget<CustomScrollView>(
          find.byType(CustomScrollView).hitTestable().first,
        )
        .controller!;

    final initial = visibleScroll();
    initial.jumpTo(initial.position.maxScrollExtent);
    await tester.pump();
    expect(provider.appendOffsets, [30]);

    await _selectTab(tester, 'السابق');
    await tester.pumpAndSettle();
    await _selectTab(tester, 'الحالي');
    // Do not settle until the intentionally held request has completed.
    final resumed = visibleScroll();
    expect(resumed, isNot(same(initial)));
    expect(provider.appendOffsets, [30]);

    const url = 'https://fixture.test/season-appended';
    provider.append.complete(
      ProviderMediaPage(
        items: [
          MultimediaItem(title: 'Appended show', url: url, posterUrl: ''),
        ],
        nextOffset: 31,
        hasMore: false,
      ),
    );
    await tester.pumpAndSettle();
    resumed.jumpTo(resumed.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(
      find
          .byKey(ValueKey('season-${_StubSeasonsProvider.current}-$url'))
          .hitTestable(),
      findsOneWidget,
    );
    expect(provider.appendOffsets, [30]);
  });

  testWidgets('season title scrolls away while the season tabs stay fixed', (
    tester,
  ) async {
    await _pumpSeasons(tester, provider: _ScrollableSeasonsProvider());
    for (final entry in const {
      'الحالي': 'صيف عام 2026',
      'السابق': 'ربيع عام 2026',
      'القادم': 'خريف عام 2026',
    }.entries) {
      await _selectTab(tester, entry.key);
      final title = find.text(entry.value).hitTestable();
      expect(
        find.ancestor(of: title, matching: find.byType(TabBarView)),
        findsOneWidget,
      );
      final tabsBefore = tester.getRect(find.byType(TabBar));
      await tester.drag(
        find.byType(CustomScrollView).hitTestable().first,
        const Offset(0, -400),
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text(entry.value).hitTestable(), findsNothing);
      expect(tester.getRect(find.byType(TabBar)), tabsBefore);
      await tester.drag(
        find.byType(CustomScrollView).hitTestable().first,
        const Offset(0, 400),
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text(entry.value).hitTestable(), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('other-seasons year headings are horizontally centered', (
    tester,
  ) async {
    await tester.runAsync(TestFonts.loadWalkthroughFonts);
    const shotKey = ValueKey('seasons-shot');
    await _pumpSeasons(
      tester,
      provider: _StubSeasonsProvider(),
      shotKey: shotKey,
    );

    await _selectTab(tester, 'المواسم الأخرى');
    // The archive loads when this tab is first reached.
    final firstYear = find.byKey(const ValueKey('other-season-year-2026'));
    for (var frame = 0; frame < 12 && firstYear.evaluate().isEmpty; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(firstYear, findsOneWidget);
    expect(find.byType(SeasonListTitle).hitTestable(), findsNothing);

    final screen = tester.getRect(find.byType(Scaffold));
    for (final year in <int>[2026, 2025]) {
      final yearBox = tester.getRect(
        find.byKey(ValueKey('other-season-year-$year')),
      );
      expect(
        (yearBox.center.dx - screen.center.dx).abs(),
        lessThan(2),
        reason: '$year should sit at the horizontal center, not the RTL start',
      );
      expect(find.text('شتاء'), findsWidgets);
    }

    await _writeShot(tester, shotKey, 'seasons_other_years_centered.png');
  });
}
