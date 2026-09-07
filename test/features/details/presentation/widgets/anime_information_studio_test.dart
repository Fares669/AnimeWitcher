import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/features/details/presentation/widgets/anime_information_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('studio matches genre chip styling and stays tappable', (
    tester,
  ) async {
    final tapped = <String>[];
    final item = MultimediaItem(
      title: 'Test',
      url: 'https://example.test/anime',
      posterUrl: '',
      syncData: const {'awStudio': 'Madhouse'},
    );
    const primary = Color(0xFFEEC60A);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark().copyWith(
          colorScheme: const ColorScheme.dark(
            primary: primary,
            onPrimary: Colors.black,
          ),
        ),
        home: Scaffold(
          body: AnimeInformationSection(item: item, onStudioTap: tapped.add),
        ),
      ),
    );

    final text = tester.widget<Text>(find.text('Madhouse'));
    expect(text.style?.color, Colors.black);
    expect(text.style?.fontWeight, FontWeight.w600);

    final materialFinder = find.ancestor(
      of: find.text('Madhouse'),
      matching: find.byType(Material),
    );
    final material = tester.widget<Material>(materialFinder.first);
    expect(material.color, primary);
    expect(material.borderRadius, BorderRadius.circular(999));

    await tester.tap(find.text('Madhouse'));
    expect(tapped, const ['Madhouse']);
  });
}
