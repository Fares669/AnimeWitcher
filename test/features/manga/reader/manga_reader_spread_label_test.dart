import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/features/manga/reader/manga_reader_settings.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_paged_reader.dart';
// Use the same Flutter Material widgets as the app.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('direct page labels match all generated spread boundaries', () {
    for (var count = 1; count <= 135; count++) {
      for (final singleFirst in [false, true]) {
        final expectedByPage = <String>[];
        final spreads = mangaReaderPageSpreads(
          pageCount: count,
          singleFirst: singleFirst,
        );
        for (final spread in spreads) {
          final label = spread.map((page) => page + 1).join('-');
          expectedByPage.addAll(List.filled(spread.length, label));
        }
        for (var page = -1; page <= count; page++) {
          expect(
            mangaReaderPageLabel(
              pageIndex: page,
              pageCount: count,
              doublePage: true,
              singleFirst: singleFirst,
            ),
            expectedByPage[page.clamp(0, count - 1)],
          );
        }
      }
    }
  });

  testWidgets('paged layouts refresh when grouping or chapter length changes', (
    tester,
  ) async {
    Future<void> show(int count, {required bool paired, bool single = false}) {
      return tester.pumpWidget(
        MaterialApp(
          home: MangaPagedReader(
            pages: [
              for (var i = 0; i < count; i++)
                MangaPage(index: i, imageUrl: 'https://example.test/$i'),
            ],
            initialPage: 0,
            rtl: false,
            doublePage: paired,
            settings: MangaReaderSettings(doublePageSingleFirstPage: single),
            onPageChanged: (_) {},
            pageBuilder: (_, page) => Center(child: Text('Page ${page.index}')),
          ),
        ),
      );
    }

    int? spreadCount() => tester
        .widget<PageView>(find.byType(PageView))
        .childrenDelegate
        .estimatedChildCount;

    await show(6, paired: false);
    expect(spreadCount(), 6);
    await show(6, paired: true);
    expect(spreadCount(), 3);
    await show(6, paired: true, single: true);
    expect(spreadCount(), 4);
    await show(3, paired: true, single: true);
    expect(spreadCount(), 2);
    expect(tester.takeException(), isNull);
  });
}
