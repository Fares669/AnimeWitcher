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
import 'package:animewitcher/shared/widgets/multimedia_card.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/test_fonts.dart';

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

Future<void> _pumpSeasons(
  WidgetTester tester, {
  required AnimeWitcherNativeProvider provider,
  Key? shotKey,
}) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
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
          fontFamily: 'NotoSansArabic',
          scaffoldBackgroundColor: Colors.black,
          colorScheme: const ColorScheme.dark(
            primary: Color(0xFFEEC60A),
            surface: Color(0xFF000000),
            onSurface: Color(0xFFE5E7EB),
          ),
        ),
        home: shotKey == null
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
  final artifacts = Directory('/opt/cursor/artifacts');
  if (!artifacts.existsSync()) return;
  await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(key),
    );
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    File(
      '${artifacts.path}/$filename',
    ).writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
