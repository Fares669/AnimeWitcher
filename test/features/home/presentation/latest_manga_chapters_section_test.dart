import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/features/home/presentation/widgets/latest_manga_chapters_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('latest chapters section shows manga and newest chapter', (
    tester,
  ) async {
    var opened = false;
    final entry = MangaLatestChapter(
      manga: MultimediaItem(
        title: 'Solo Leveling',
        url: 'manga://solo',
        posterUrl: '',
        contentType: MultimediaContentType.manga,
      ),
      chapter: const MangaChapter(
        id: '201',
        mangaId: 'solo',
        url: 'chapter://201',
        name: 'الفصل 201',
        number: 201,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LatestMangaChaptersSection(
            title: 'أحدث الفصول',
            items: <MangaLatestChapter>[entry],
            onTap: (_) => opened = true,
          ),
        ),
      ),
    );

    expect(find.text('أحدث الفصول'), findsOneWidget);
    expect(find.text('Solo Leveling'), findsWidgets);
    expect(find.text('الفصل 201'), findsOneWidget);

    await tester.tap(find.text('Solo Leveling').first);
    expect(opened, isTrue);
  });
}
