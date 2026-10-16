import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/features/manga/presentation/widgets/manga_information_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Arabic metadata labels preserve the full English source title', (
    tester,
  ) async {
    const sourceTitle =
        'A Very Long English Manga Title That Must Stay Complete Across Multiple Lines';
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        home: Scaffold(
          body: SizedBox(
            width: 320,
            child: MangaInformationSection(
              item: MultimediaItem(
                title: 'عنوان المانجا',
                url: 'https://example.test/manga',
                posterUrl: '',
                syncData: const {'englishTitle': sourceTitle},
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('العنوان الإنجليزي'), findsOneWidget);
    expect(find.text('English title'), findsNothing);
    final title = tester.widget<Text>(find.text(sourceTitle));
    expect(title.maxLines, isNull);
    expect(title.overflow, TextOverflow.visible);
    expect(tester.takeException(), isNull);
  });
}
