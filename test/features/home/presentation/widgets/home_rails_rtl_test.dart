import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/features/home/presentation/view_all_screen.dart';
import 'package:animewitcher/features/home/presentation/widgets/home_section_header.dart';
import 'package:animewitcher/features/home/presentation/widgets/media_horizontal_list.dart';
import 'package:animewitcher/features/home/presentation/widgets/news_section.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

MultimediaItem _anime(String title, String id) {
  return MultimediaItem(
    title: title,
    url: 'https://animewitcher.test/watch/$id',
    posterUrl: '',
  );
}

NewsItem _news(String title, String id) {
  return NewsItem(id: id, title: title, imageUrl: '');
}

Future<ByteData> _fontBytes(String path) async {
  return ByteData.sublistView(await File(path).readAsBytes());
}

Future<void> _loadWalkthroughFonts() async {
  const arabicRegular =
      '/usr/share/fonts/truetype/noto/NotoSansArabic-Regular.ttf';
  if (!File(arabicRegular).existsSync()) return;
  await (FontLoader('NotoSansArabic')
        ..addFont(_fontBytes(arabicRegular))
        ..addFont(
          _fontBytes('/usr/share/fonts/truetype/noto/NotoSansArabic-Bold.ttf'),
        ))
      .load();
  await (FontLoader('Roboto')
        ..addFont(
          _fontBytes(
            '/opt/flutter/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf',
          ),
        )
        ..addFont(
          _fontBytes(
            '/opt/flutter/bin/cache/artifacts/material_fonts/Roboto-Bold.ttf',
          ),
        ))
      .load();
  await (FontLoader('MaterialIcons')..addFont(
        _fontBytes(
          '/opt/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        ),
      ))
      .load();
}

ThemeData _homeTheme() {
  return ThemeData(
    brightness: Brightness.dark,
    fontFamily: 'NotoSansArabic',
    scaffoldBackgroundColor: Colors.black,
    colorScheme: const ColorScheme.dark(
      primary: Color(0xFFEEC60A),
      surface: Color(0xFF000000),
      onSurface: Color(0xFFE5E7EB),
    ),
  );
}

Widget _rtlApp({required Widget child, Size? size, ThemeData? theme}) {
  return MaterialApp(
    locale: const Locale('ar'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    theme:
        theme ??
        ThemeData(
          brightness: Brightness.dark,
          scaffoldBackgroundColor: Colors.black,
          colorScheme: const ColorScheme.dark(
            primary: Color(0xFFEEC60A),
            surface: Color(0xFF000000),
            onSurface: Color(0xFFE5E7EB),
          ),
        ),
    home: Scaffold(
      backgroundColor: Colors.black,
      body: Align(
        alignment: Alignment.topCenter,
        child: SizedBox(width: size?.width, child: child),
      ),
    ),
  );
}

MediaHorizontalList _rail({required String title, required List<String> ids}) {
  return MediaHorizontalList(
    title: title,
    mediaList: [for (final id in ids) _anime(id, id)],
    category: ViewAllCategory.providerContent,
    showViewAll: true,
    onTap: (_) {},
    heroTagPrefix: title,
    forcePortrait: true,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'home header puts the title on the right and view-all on the left',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        _rtlApp(
          child: HomeSectionHeader(
            title: 'الحلقات الجديدة',
            action: HomeViewAllButton(onTap: () {}),
          ),
        ),
      );
      await tester.pump();

      final titleBox = tester.getRect(find.text('الحلقات الجديدة'));
      final viewAllBox = tester.getRect(find.text('عرض الكل'));
      expect(titleBox.left, greaterThan(viewAllBox.left));
      expect(find.byIcon(Icons.arrow_forward_ios), findsOneWidget);

      final chevronRight = tester
          .getTopRight(find.byIcon(Icons.arrow_forward_ios))
          .dx;
      final labelLeft = tester.getTopLeft(find.text('عرض الكل')).dx;
      expect(
        chevronRight,
        lessThan(labelLeft + 1),
        reason: 'chevron sits to the left of عرض الكل',
      );

      final artifacts = Directory('/opt/cursor/artifacts');
      if (artifacts.existsSync()) {
        await tester.runAsync(_loadWalkthroughFonts);
        await tester.pumpWidget(
          _rtlApp(
            theme: _homeTheme(),
            child: ColoredBox(
              color: Colors.black,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: RepaintBoundary(
                    key: const ValueKey('view-all-closeup'),
                    child: HomeViewAllButton(onTap: () {}),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.runAsync(() async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('view-all-closeup')),
          );
          final image = await boundary.toImage(pixelRatio: 4);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          File(
            '${artifacts.path}/view_all_button_closeup.png',
          ).writeAsBytesSync(bytes!.buffer.asUint8List());
        });
      }
    },
  );

  testWidgets('latest-episode rail starts on the right', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    const title = 'الحلقات الجديدة';
    await tester.pumpWidget(
      _rtlApp(
        child: _rail(
          title: title,
          ids: const ['FirstShow', 'SecondShow', 'ThirdShow'],
        ),
      ),
    );
    await tester.pump();

    final first = tester.getTopLeft(
      find.byKey(const ValueKey('$title-rail-0')),
    );
    final last = tester.getTopLeft(find.byKey(const ValueKey('$title-rail-2')));
    expect(first.dx, greaterThan(last.dx));
  });

  testWidgets('latest-added, most-watched, and news rails start on the right', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    const latestAdded = 'آخر الأعمال المضافة';
    const mostWatched = 'الانميشن الاكثر مشاهدة';
    const newsTitle = 'الأخبار';

    await tester.pumpWidget(
      _rtlApp(
        child: ListView(
          children: [
            _rail(
              title: latestAdded,
              ids: const ['AddedOne', 'AddedTwo', 'AddedThree'],
            ),
            _rail(
              title: mostWatched,
              ids: const ['WatchOne', 'WatchTwo', 'WatchThree'],
            ),
            NewsSection(
              title: newsTitle,
              items: [
                _news('خبر أول', 'n1'),
                _news('خبر ثان', 'n2'),
                _news('خبر ثالث', 'n3'),
              ],
              onViewAll: () {},
            ),
          ],
        ),
      ),
    );
    await tester.pump();

    final addedFirst = tester.getTopLeft(
      find.byKey(const ValueKey('$latestAdded-rail-0')),
    );
    final addedLast = tester.getTopLeft(
      find.byKey(const ValueKey('$latestAdded-rail-2')),
    );
    expect(addedFirst.dx, greaterThan(addedLast.dx));

    final watchedFirst = tester.getTopLeft(
      find.byKey(const ValueKey('$mostWatched-rail-0')),
    );
    final watchedLast = tester.getTopLeft(
      find.byKey(const ValueKey('$mostWatched-rail-2')),
    );
    expect(watchedFirst.dx, greaterThan(watchedLast.dx));

    final newsFirst = tester.getTopLeft(
      find.byKey(const ValueKey('news-rail-n1')),
    );
    final newsLast = tester.getTopLeft(
      find.byKey(const ValueKey('news-rail-n3')),
    );
    expect(newsFirst.dx, greaterThan(newsLast.dx));

    expect(find.text(latestAdded), findsOneWidget);
    expect(find.text(mostWatched), findsOneWidget);
    expect(find.text(newsTitle), findsOneWidget);
    expect(find.text('عرض الكل'), findsNWidgets(3));
  });

  testWidgets('home rails screenshot for walkthrough', (tester) async {
    await tester.runAsync(_loadWalkthroughFonts);

    const size = Size(390, 1680);
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _rtlApp(
        size: size,
        theme: _homeTheme(),
        child: RepaintBoundary(
          key: const ValueKey('home-rails-shot'),
          child: ColoredBox(
            color: Colors.black,
            child: ListView(
              padding: const EdgeInsets.only(top: 8, bottom: 24),
              children: [
                _rail(
                  title: 'الحلقات الجديدة',
                  ids: const ['1 FIRST', '2 SECOND', '3 THIRD'],
                ),
                _rail(
                  title: 'آخر الأعمال المضافة',
                  ids: const ['1 ADDED', '2 ADDED', '3 ADDED'],
                ),
                _rail(
                  title: 'الانميشن الاكثر مشاهدة',
                  ids: const ['1 WATCHED', '2 WATCHED', '3 WATCHED'],
                ),
                NewsSection(
                  title: 'الأخبار',
                  items: [
                    _news('1 خبر أول', 'shot-n1'),
                    _news('2 خبر ثان', 'shot-n2'),
                    _news('3 خبر ثالث', 'shot-n3'),
                  ],
                  onViewAll: () {},
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final first = tester.getTopLeft(
      find.byKey(const ValueKey('الحلقات الجديدة-rail-0')),
    );
    final last = tester.getTopLeft(
      find.byKey(const ValueKey('الحلقات الجديدة-rail-2')),
    );
    expect(first.dx, greaterThan(last.dx));

    final artifacts = Directory('/opt/cursor/artifacts');
    if (!artifacts.existsSync()) {
      return;
    }

    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('home-rails-shot')),
      );
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File(
        '${artifacts.path}/view_all_chevron_left_of_label.png',
      ).writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  });
}
