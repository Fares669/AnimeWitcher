import 'package:animewitcher/features/manga/reader/manga_reader_settings.dart';
import 'package:animewitcher/features/manga/reader/manga_reader_settings_provider.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_reader_quick_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final class _QuickSettingsNotifier extends MangaReaderSettingsNotifier {
  @override
  MangaReaderSettings build() => const MangaReaderSettings();

  @override
  Future<void> setSettings(MangaReaderSettings value) async {
    state = value;
  }
}

void main() {
  testWidgets('quick settings omits the removed color-filter surface', (
    tester,
  ) async {
    var autoScrollEnabled = false;
    var autoScrollSpeed = 0.0;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mangaReaderSettingsProvider.overrideWith(
            _QuickSettingsNotifier.new,
          ),
        ],
        child: MaterialApp(
          locale: const Locale('en'),
          home: Scaffold(
            body: MangaReaderQuickSettings(
              currentMode: MangaReaderMode.webtoon,
              mangaId: 'm1',
              onModeChanged: (_) {},
              onAutoScrollChanged: (enabled, speed) {
                autoScrollEnabled = enabled;
                autoScrollSpeed = speed;
              },
              onOpenAllSettings: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('القراءة'), findsOneWidget);
    expect(find.text('عام'), findsOneWidget);
    expect(find.text('تعطيل التصغير'), findsOneWidget);
    expect(find.text('تكبير بالنقر المزدوج'), findsOneWidget);

    final readingScrollable = find.descendant(
      of: find.byType(ListView).first,
      matching: find.byType(Scrollable),
    ).first;

    await tester.tap(find.text('تعطيل التصغير'));
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MangaReaderQuickSettings)),
    );
    expect(
      container.read(mangaReaderSettingsProvider).webtoonDisableZoomOut,
      isTrue,
    );

    await tester.scrollUntilVisible(
      find.text('إظهار الفواصل بين الصفحات'),
      240,
      scrollable: readingScrollable,
    );
    expect(find.text('إظهار الفواصل بين الصفحات'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('التمرير التلقائي'),
      240,
      scrollable: readingScrollable,
    );
    expect(find.text('التمرير التلقائي'), findsOneWidget);
    await tester.tap(find.text('التمرير التلقائي'));
    await tester.pump();
    expect(autoScrollEnabled, isTrue);
    expect(autoScrollSpeed, 10);

    await tester.tap(find.text('عام'));
    await tester.pumpAndSettle();
    expect(find.text('لون الخلفية'), findsOneWidget);
    expect(find.text('طريقة الملاءمة'), findsOneWidget);
    expect(find.text('وميض عند تغيير الصفحة'), findsOneWidget);

    final generalScrollable = find.descendant(
      of: find.byType(ListView).hitTestable(),
      matching: find.byType(Scrollable),
    ).first;
    await tester.scrollUntilVisible(
      find.text('كل إعدادات القارئ'),
      240,
      scrollable: generalScrollable,
    );
    expect(find.text('كل إعدادات القارئ'), findsOneWidget);

    expect(find.text('Filter'), findsNothing);
    expect(find.text('Invert colors'), findsNothing);
    expect(find.text('Grayscale'), findsNothing);
    expect(find.text('Brightness'), findsNothing);
    expect(find.text('Custom color filter'), findsNothing);
    expect(find.text('Blend mode'), findsNothing);
  });

  testWidgets('paged quick settings exposes navigate-to-pan instead of webtoon zoom', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mangaReaderSettingsProvider.overrideWith(
            _QuickSettingsNotifier.new,
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: MangaReaderQuickSettings(
              currentMode: MangaReaderMode.pagedRtl,
              mangaId: 'm1',
              onModeChanged: (_) {},
              onAutoScrollChanged: (_, _) {},
              onOpenAllSettings: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('التنقل أثناء التكبير'), findsOneWidget);
    expect(find.text('تعطيل التصغير'), findsNothing);
    expect(find.text('التمرير التلقائي'), findsNothing);
  });
}
