import 'dart:io';
import 'dart:ui' as ui;

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/features/home/presentation/widgets/news_card.dart';
import 'package:animewitcher/features/news/presentation/news_list_screen.dart';
import 'package:animewitcher/features/news/presentation/news_utils.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/test_fonts.dart';

NewsItem _item(String id, {String? title}) {
  return NewsItem(id: id, title: title ?? 'خبر $id', imageUrl: '');
}

Widget _app(Size size, List<NewsItem> items) {
  return MediaQuery(
    data: MediaQueryData(size: size),
    child: MaterialApp(
      locale: const Locale('ar'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(
        brightness: Brightness.dark,
        fontFamily: 'NotoSansArabic',
        scaffoldBackgroundColor: Colors.black,
      ),
      home: RepaintBoundary(
        key: const ValueKey('news-landscape-shot'),
        child: NewsListScreen(
          initialItems: items,
          loadPage: (offset, limit) async => const ProviderNewsPage(
            items: <NewsItem>[],
            nextOffset: 0,
            hasMore: false,
          ),
        ),
      ),
    ),
  );
}

void main() {
  test('news list uses two columns in landscape and one in portrait', () {
    expect(newsListColumnCount(const Size(390, 844)), 1);
    expect(newsListColumnCount(const Size(844, 390)), 2);
    expect(
      newsListLandscapeMainAxisExtent(
        size: const Size(844, 390),
        padding: EdgeInsets.zero,
      ),
      closeTo(294, 0.5),
    );
  });

  testWidgets('landscape news page places two articles on the first row', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(844, 390));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(TestFonts.loadWalkthroughFonts);

    await tester.pumpWidget(
      _app(const Size(844, 390), <NewsItem>[
        _item(
          '1',
          title:
              'الموسم الرابع من أنمي JUJUTSU KAISEN يكشف عن ملصق تشويقي مثير',
        ),
        _item('2'),
        _item('3'),
      ]),
    );
    await tester.pump();

    expect(find.byType(GridView), findsOneWidget);
    expect(find.byType(ListView), findsNothing);
    expect(find.byType(NewsCard), findsNWidgets(3));
    expect(tester.takeException(), isNull);

    final first = tester.getRect(find.byType(NewsCard).at(0));
    final second = tester.getRect(find.byType(NewsCard).at(1));
    final third = tester.getRect(find.byType(NewsCard).at(2));
    expect((first.center.dy - second.center.dy).abs(), lessThan(2));
    expect(first.center.dx, greaterThan(second.center.dx));
    expect(third.top, greaterThan(first.bottom - 1));

    final artifacts = Directory('/opt/cursor/artifacts');
    if (!artifacts.existsSync()) return;
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('news-landscape-shot')),
      );
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File(
        '${artifacts.path}/news_list_landscape_two_per_row.png',
      ).writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  });

  testWidgets('portrait news page keeps one article per row', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _app(const Size(390, 844), <NewsItem>[_item('1'), _item('2')]),
    );
    await tester.pump();

    expect(find.byType(ListView), findsOneWidget);
    expect(find.byType(GridView), findsNothing);
    final first = tester.getRect(find.text('خبر 1'));
    final second = tester.getRect(find.text('خبر 2'));
    expect(second.top, greaterThan(first.bottom - 1));
  });
}
