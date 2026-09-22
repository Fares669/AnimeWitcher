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

    expect(find.text('Reading'), findsOneWidget);
    expect(find.text('General'), findsOneWidget);
    expect(find.text('Disable zoom out'), findsOneWidget);
    expect(find.text('Double-tap zoom'), findsOneWidget);

    final readingScrollable = find.descendant(
      of: find.byType(ListView).first,
      matching: find.byType(Scrollable),
    ).first;

    await tester.tap(find.text('Disable zoom out'));
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MangaReaderQuickSettings)),
    );
    expect(
      container.read(mangaReaderSettingsProvider).webtoonDisableZoomOut,
      isTrue,
    );

    await tester.scrollUntilVisible(
      find.text('Show page gaps'),
      240,
      scrollable: readingScrollable,
    );
    expect(find.text('Show page gaps'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Auto scroll'),
      240,
      scrollable: readingScrollable,
    );
    expect(find.text('Auto scroll'), findsOneWidget);
    await tester.tap(find.text('Auto scroll'));
    await tester.pump();
    expect(autoScrollEnabled, isTrue);
    expect(autoScrollSpeed, 10);

    await tester.tap(find.text('General'));
    await tester.pumpAndSettle();
    expect(find.text('Background color'), findsOneWidget);
    expect(find.text('Scale type'), findsOneWidget);
    expect(find.text('Flash on page change'), findsOneWidget);

    final generalScrollable = find.descendant(
      of: find.byType(ListView).hitTestable(),
      matching: find.byType(Scrollable),
    ).first;
    await tester.scrollUntilVisible(
      find.text('All reader settings'),
      240,
      scrollable: generalScrollable,
    );
    expect(find.text('All reader settings'), findsOneWidget);

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

    expect(find.text('Navigate while zoomed'), findsOneWidget);
    expect(find.text('Disable zoom out'), findsNothing);
    expect(find.text('Auto scroll'), findsNothing);
  });
}
