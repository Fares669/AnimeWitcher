import 'dart:io';
import 'dart:ui' as ui;

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/features/home/presentation/widgets/news_card.dart';
import 'package:animewitcher/features/news/presentation/news_list_screen.dart';
import 'package:animewitcher/features/news/presentation/news_utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/test_fonts.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/features/home/presentation/widgets/news_card.dart';
import 'package:animewitcher/features/news/presentation/news_list_screen.dart';
import 'package:animewitcher/features/news/presentation/news_utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

NewsItem _item(String id) {
  return NewsItem(id: id, title: 'خبر $id', imageUrl: '');
}

void main() {
  test('news list uses two columns in landscape and one in portrait', () {
    expect(newsListColumnCount(const Size(390, 844)), 1);
    expect(newsListColumnCount(const Size(844, 390)), 2);
  });

  testWidgets('landscape news page places two articles on the first row', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(844, 390));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(TestFonts.loadWalkthroughFonts);

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        theme: ThemeData(
          brightness: Brightness.dark,
          fontFamily: 'NotoSansArabic',
          scaffoldBackgroundColor: Colors.black,
        ),
        home: RepaintBoundary(
          key: const ValueKey('news-landscape-shot'),
          child: NewsListScreen(
            initialItems: <NewsItem>[_item('1'), _item('2'), _item('3')],
            loadPage: (offset, limit) async => const ProviderNewsPage(
              items: <NewsItem>[],
              nextOffset: 0,
              hasMore: false,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(GridView), findsOneWidget);
    expect(find.byType(NewsCard), findsNWidgets(3));

    final first = tester.getRect(find.text('خبر 1'));
    final second = tester.getRect(find.text('خبر 2'));
    final third = tester.getRect(find.text('خبر 3'));
    expect((first.center.dy - second.center.dy).abs(), lessThan(8));
    expect(first.center.dx, isNot(closeTo(second.center.dx, 8)));
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
}
