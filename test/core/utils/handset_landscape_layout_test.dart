import 'dart:io';
import 'dart:ui' as ui;

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/utils/responsive_breakpoints.dart';
import 'package:animewitcher/features/details/presentation/widgets/details_layout_widgets.dart';
import 'package:animewitcher/features/home/presentation/view_all_screen.dart';
import 'package:animewitcher/features/home/presentation/widgets/media_horizontal_list.dart';
import 'package:animewitcher/features/home/presentation/widgets/provider_search_filter_dialog.dart';
import 'package:animewitcher/features/search/presentation/widgets/search_result_section.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:animewitcher/shared/widgets/apple_liquid_glass.dart';
import 'package:animewitcher/shared/widgets/catalog_ltr.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const Size _phoneLandscape = Size(800, 360);
const Size _phonePortrait = Size(390, 844);

MultimediaItem _poster(int index) {
  return MultimediaItem(
    title: 'Show $index',
    url: 'https://example.test/show-$index',
    posterUrl: '',
    catalogType: 'مسلسل',
    year: 2024,
  );
}

Future<ByteData> _fontBytes(String path) async {
  return ByteData.sublistView(await File(path).readAsBytes());
}

Future<void> _loadFonts() async {
  const arabicRegular =
      '/usr/share/fonts/truetype/noto/NotoSansArabic-Regular.ttf';
  if (!File(arabicRegular).existsSync()) return;
  await (FontLoader('NotoSansArabic')
        ..addFont(_fontBytes(arabicRegular))
        ..addFont(
          _fontBytes('/usr/share/fonts/truetype/noto/NotoSansArabic-Bold.ttf'),
        ))
      .load();
  const roboto =
      '/opt/flutter/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf';
  if (File(roboto).existsSync()) {
    await (FontLoader('Roboto')..addFont(_fontBytes(roboto))).load();
  }
  const icons =
      '/opt/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf';
  if (File(icons).existsSync()) {
    await (FontLoader('MaterialIcons')..addFont(_fontBytes(icons))).load();
  }
}

Future<void> _setPhoneSurface(WidgetTester tester, {required Size size}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  await tester.binding.setSurfaceSize(size);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    tester.binding.setSurfaceSize(null);
  });
}

ThemeData _darkTheme() {
  return ThemeData(
    brightness: Brightness.dark,
    fontFamily: 'NotoSansArabic',
    scaffoldBackgroundColor: Colors.black,
    colorScheme: const ColorScheme.dark(
      primary: Color(0xFFEEC60A),
      surface: Color(0xFF111111),
      onSurface: Color(0xFFE5E7EB),
      onSurfaceVariant: Color(0xFFB0B0B0),
    ),
  );
}

Widget _app({required Widget child, bool catalogLtr = false}) {
  final body = catalogLtr ? CatalogLtr(child: child) : child;
  return ProviderScope(
    child: MaterialApp(
      locale: const Locale('ar'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: _darkTheme(),
      home: Scaffold(backgroundColor: Colors.black, body: body),
    ),
  );
}

Future<void> _writeShot(WidgetTester tester, String filename, Key key) async {
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

  test('handset landscape poster grids use 7 columns', () {
    expect(ResponsiveBreakpoints.handsetLandscapeAnimeColumns, 7);
    expect(ResponsiveBreakpoints.handsetLandscapeEpisodeColumns, 2);
    expect(ResponsiveBreakpoints.desktopLandscapeAnimeColumns, 8);
  });

  testWidgets('search grid is 7 posters per row in phone landscape', (
    tester,
  ) async {
    await _setPhoneSurface(tester, size: const Size(800, 420));
    await tester.runAsync(_loadFonts);

    await tester.pumpWidget(
      _app(
        catalogLtr: true,
        child: RepaintBoundary(
          key: const ValueKey('search-landscape-grid-shot'),
          child: CustomScrollView(
            slivers: [
              SearchResultSection(
                providerName: 'AnimeWitcher',
                providerId: 'native',
                results: [for (var i = 0; i < 8; i++) _poster(i)],
                isLoadingMore: false,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    final rects = [
      for (var i = 0; i < 8; i++)
        tester.getRect(find.byKey(ValueKey('https://example.test/show-$i'))),
    ];
    for (var i = 1; i < 7; i++) {
      expect((rects[i].top - rects[0].top).abs(), lessThan(1));
      expect(rects[i].left, greaterThan(rects[i - 1].left));
    }
    expect(rects[7].top, greaterThan(rects[0].bottom - 1));
    expect(rects[0].width, lessThan(800 / 6));
    expect(rects[0].width, greaterThan(70));

    await _writeShot(
      tester,
      'phone_landscape_search_7col.png',
      const ValueKey('search-landscape-grid-shot'),
    );
  });

  testWidgets('search grid stays 3 posters per row in phone portrait', (
    tester,
  ) async {
    await _setPhoneSurface(tester, size: _phonePortrait);

    await tester.pumpWidget(
      _app(
        catalogLtr: true,
        child: CustomScrollView(
          slivers: [
            SearchResultSection(
              providerName: 'AnimeWitcher',
              providerId: 'native',
              results: [for (var i = 0; i < 4; i++) _poster(i)],
              isLoadingMore: false,
            ),
          ],
        ),
      ),
    );
    await tester.pump();

    final first = tester.getRect(
      find.byKey(const ValueKey('https://example.test/show-0')),
    );
    final third = tester.getRect(
      find.byKey(const ValueKey('https://example.test/show-2')),
    );
    final fourth = tester.getRect(
      find.byKey(const ValueKey('https://example.test/show-3')),
    );
    expect((first.top - third.top).abs(), lessThan(1));
    expect(fourth.top, greaterThan(first.bottom - 1));
  });

  testWidgets('home rails use the same 7-across card width in landscape', (
    tester,
  ) async {
    await _setPhoneSurface(tester, size: _phoneLandscape);

    const title = 'الحلقات الجديدة';
    await tester.pumpWidget(
      _app(
        child: MediaHorizontalList(
          title: title,
          mediaList: [for (var i = 0; i < 8; i++) _poster(i)],
          category: ViewAllCategory.providerContent,
          showViewAll: false,
          onTap: (_) {},
          forcePortrait: true,
        ),
      ),
    );
    await tester.pump();

    final paddingBox = tester.getRect(
      find.byKey(const ValueKey('$title-rail-0')),
    );
    const expectedCard =
        (800 - 32 - ResponsiveBreakpoints.handsetLandscapeGridMaxSpacing * 6) /
        7;
    expect(
      paddingBox.width,
      closeTo(
        expectedCard + ResponsiveBreakpoints.handsetLandscapeGridMaxSpacing,
        1.5,
      ),
    );
  });

  testWidgets('episode list is 2 columns in phone landscape', (tester) async {
    await _setPhoneSurface(tester, size: _phoneLandscape);
    await tester.runAsync(_loadFonts);

    await tester.pumpWidget(
      _app(
        child: RepaintBoundary(
          key: const ValueKey('episodes-landscape-shot'),
          child: CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.all(16),
                sliver: SliverEpisodeCardGrid(
                  children: [
                    for (var i = 0; i < 4; i++)
                      DecoratedBox(
                        key: ValueKey('episode-$i'),
                        decoration: BoxDecoration(
                          color: const Color(0xFF2A2A2A),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFFEEC60A)),
                        ),
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Text(
                              'الحلقة ${i + 1}',
                              style: const TextStyle(color: Colors.white),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    final first = tester.getRect(find.byKey(const ValueKey('episode-0')));
    final second = tester.getRect(find.byKey(const ValueKey('episode-1')));
    final third = tester.getRect(find.byKey(const ValueKey('episode-2')));

    expect((first.top - second.top).abs(), lessThan(1));
    expect(first.width, closeTo(second.width, 1));
    expect(first.width, lessThan(800 * 0.6));
    expect(third.top, greaterThan(first.bottom - 1));

    await _writeShot(
      tester,
      'phone_landscape_episodes_2col.png',
      const ValueKey('episodes-landscape-shot'),
    );
  });

  testWidgets('episode list stays 1 column in phone portrait', (tester) async {
    await _setPhoneSurface(tester, size: _phonePortrait);

    await tester.pumpWidget(
      _app(
        child: CustomScrollView(
          slivers: [
            SliverEpisodeCardGrid(
              children: [
                for (var i = 0; i < 2; i++)
                  ColoredBox(
                    key: ValueKey('episode-$i'),
                    color: Colors.grey,
                    child: SizedBox(height: 72, child: Text('E$i')),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
    await tester.pump();

    final first = tester.getRect(find.byKey(const ValueKey('episode-0')));
    final second = tester.getRect(find.byKey(const ValueKey('episode-1')));
    expect(second.top, greaterThan(first.bottom - 1));
  });

  testWidgets('search filter dialog uses landscape height to show more chips', (
    tester,
  ) async {
    await _setPhoneSurface(tester, size: _phoneLandscape);
    await tester.runAsync(_loadFonts);

    const options = ProviderSearchFilterOptions(
      genres: <String>[
        'اكشن',
        'مغامرات',
        'دراما',
        'كوميديا',
        'خيال',
        'رعب',
        'رياضة',
        'غموض',
        'حربي',
        'مدرسي',
        'رومانسي',
        'تاريخي',
      ],
      types: <String>['مسلسل', 'فيلم', 'أوفا'],
      statuses: <String>['يعرض الآن', 'مكتمل'],
      ageRatings: <String>['+13', '+18'],
      years: <String>['2024', '2023', '2022'],
      seasons: <String>['شتاء', 'ربيع'],
    );

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          locale: const Locale('ar'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: _darkTheme(),
          home: Builder(
            builder: (context) {
              return Scaffold(
                backgroundColor: Colors.black,
                body: Center(
                  child: TextButton(
                    onPressed: () {
                      showDialog<void>(
                        context: context,
                        builder: (_) => const RepaintBoundary(
                          key: ValueKey('filter-landscape-shot'),
                          child: ProviderSearchFilterDialog(
                            options: options,
                            initialValue: ProviderSearchFilters(),
                          ),
                        ),
                      );
                    },
                    child: const Text('open-filters'),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('open-filters'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('فلاتر البحث'), findsOneWidget);
    expect(find.text('تطبيق'), findsOneWidget);
    expect(find.text('مسح الكل'), findsOneWidget);
    expect(find.byIcon(Icons.close_rounded), findsOneWidget);
    expect(find.text('التصنيفات'), findsOneWidget);
    expect(find.text('السنة'), findsOneWidget);
    expect(find.text('العمر'), findsOneWidget);
    expect(find.text('النوع'), findsOneWidget);
    expect(find.text('الحالة'), findsOneWidget);
    expect(find.text('اكشن'), findsOneWidget);
    expect(find.text('غموض'), findsOneWidget);
    expect(find.text('تاريخي'), findsOneWidget);
    expect(
      tester.getRect(find.text('غموض')).bottom,
      lessThan(tester.getRect(find.text('تطبيق')).top),
    );
    // 12 chips / 5 landscape columns => a third row. The taller sheet must
    // keep that row fully above the apply button instead of clipping it.
    expect(
      tester.getRect(find.text('تاريخي')).bottom,
      lessThan(tester.getRect(find.text('تطبيق')).top),
    );

    final dialog = tester.getRect(find.byType(Dialog));
    final panel = tester.getRect(find.byType(AppleLiquidGlassSurface));
    expect(dialog.height, lessThanOrEqualTo(360));
    expect(panel.height, greaterThan(300));
    expect(panel.height, lessThanOrEqualTo(360));
    expect(panel.width, greaterThan(600));
    expect(find.text('تطبيق'), findsOneWidget);
    expect(tester.getRect(find.text('تطبيق')).bottom, lessThan(360));
    expect(tester.getRect(find.text('مسح الكل')).bottom, lessThan(360));

    await _writeShot(
      tester,
      'phone_landscape_filters_fitted.png',
      const ValueKey('filter-landscape-shot'),
    );

    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();
    expect(find.text('فلاتر البحث'), findsNothing);
  });
}
