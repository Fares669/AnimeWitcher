import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/features/home/presentation/widgets/latest_manga_chapters_section.dart';
import 'package:animewitcher/shared/widgets/multimedia_card.dart';
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
      chapter: MangaChapter(
        id: '201',
        mangaId: 'solo',
        url: 'chapter://201',
        name: '201 مترجم',
        number: 201,
        publishedAt: DateTime(2026, 9, 19, 21),
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
    expect(find.text('الفصل 201 مترجم'), findsOneWidget);

    final card = tester.widget<MultimediaCard>(find.byType(MultimediaCard));
    expect(card.episodeBadge, 'الفصل 201 مترجم');
    expect(card.subtitle, isNot('الفصل 201 مترجم'));
    expect(card.subtitle, contains('منذ'));

    await tester.tap(find.text('Solo Leveling').first);
    expect(opened, isTrue);
  });
}
