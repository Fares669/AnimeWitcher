import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/core/storage/manga_reading_repository.dart';
import 'package:animewitcher/features/manga/presentation/widgets/manga_chapter_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const chapter = MangaChapter(
    id: 'c58',
    mangaId: 'm1',
    url: 'https://example.test/chapter/58',
    name: 'Chapter 58',
    number: 58,
  );

  MangaReadingProgress progress({
    required int pageIndex,
    required int pageCount,
    bool isRead = false,
  }) => MangaReadingProgress(
    mangaId: 'm1',
    chapterId: 'c58',
    pageIndex: pageIndex,
    pageCount: pageCount,
    updatedAt: 0,
    isRead: isRead,
  );

  Future<MangaChapterRow> pumpRow(
    WidgetTester tester,
    MangaReadingProgress? value,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MangaChapterRow(chapter: chapter, progress: value),
        ),
      ),
    );
    return tester.widget<MangaChapterRow>(find.byType(MangaChapterRow));
  }

  testWidgets('a fully read chapter shows no read-count label', (tester) async {
    final row = await pumpRow(
      tester,
      progress(pageIndex: 15, pageCount: 16, isRead: true),
    );
    // Completion is told by the dimmed colour alone — no "16/16".
    expect(row.progressLabel, isNull);
    expect(find.textContaining('16/16'), findsNothing);
  });

  testWidgets('reaching the last page also hides the label', (tester) async {
    final row = await pumpRow(tester, progress(pageIndex: 15, pageCount: 16));
    expect(row.progressLabel, isNull);
  });

  testWidgets('a part-read chapter keeps its read-count label', (tester) async {
    final row = await pumpRow(tester, progress(pageIndex: 4, pageCount: 16));
    expect(row.progressLabel, '5/16');
  });

  testWidgets('selection displays one circular mark without moving the row', (
    tester,
  ) async {
    Future<void> render({required bool selecting, required bool selected}) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: MangaChapterRow(
                chapter: chapter,
                selecting: selecting,
                selected: selected,
                action: const SizedBox.square(
                  key: ValueKey('chapter-action'),
                  dimension: 34,
                ),
              ),
            ),
          ),
        );

    await render(selecting: false, selected: false);
    final original = tester.getRect(find.byType(MangaChapterRow));
    final actionCenter = tester.getCenter(
      find.byKey(const ValueKey('chapter-action')),
    );
    final bookCenter = tester.getCenter(find.byIcon(Icons.menu_book_rounded));
    await render(selecting: true, selected: false);
    expect(tester.getRect(find.byType(MangaChapterRow)), original);
    expect(find.byIcon(Icons.radio_button_unchecked_rounded), findsOneWidget);
    expect(
      tester.getCenter(find.byIcon(Icons.radio_button_unchecked_rounded)),
      actionCenter,
    );
    expect(tester.getCenter(find.byIcon(Icons.menu_book_rounded)), bookCenter);
    await render(selecting: true, selected: true);
    expect(tester.getRect(find.byType(MangaChapterRow)), original);
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
    expect(find.byIcon(Icons.menu_book_rounded), findsOneWidget);
    expect(
      tester.getCenter(find.byIcon(Icons.check_circle_rounded)),
      actionCenter,
    );
  });

  testWidgets('an unread chapter has no label', (tester) async {
    final row = await pumpRow(tester, null);
    expect(row.progressLabel, isNull);
  });
}
