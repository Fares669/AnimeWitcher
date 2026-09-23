import 'dart:io';

import 'package:animewitcher/features/manga/reader/manga_reader_settings.dart';
import 'package:animewitcher/features/manga/reader/manga_reader_settings_provider.dart';
import 'package:animewitcher/features/manga/reader/manga_reader_settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final class _ReaderSettingsNotifier extends MangaReaderSettingsNotifier {
  @override
  MangaReaderSettings build() => const MangaReaderSettings(
    flashOnPageChange: true,
  );

  @override
  Future<void> setSettings(MangaReaderSettings value) async {
    state = value;
  }
}

void main() {
  test('reader settings source has no color-filter controls', () {
    final source = File(
      'lib/features/manga/reader/manga_reader_settings_screen.dart',
    ).readAsStringSync();

    for (final label in <String>[
      'Color filters',
      'Invert colors',
      'Grayscale',
      'Custom color filter',
      'Blend mode',
      'Brightness',
      'Contrast',
      'Saturation',
    ]) {
      expect(source, isNot(contains(label)), reason: label);
    }
  });

  test('reader settings source has no chapter swipe controls', () {
    final source = File(
      'lib/features/manga/reader/manga_reader_settings_screen.dart',
    ).readAsStringSync();

    for (final label in <String>[
      'Chapter swipes',
      'Swipe from start',
      'Swipe from end',
    ]) {
      expect(source, isNot(contains(label)), reason: label);
    }
  });


  test('reader settings keeps back left and reset right without duplicate iOS back', () {
    final source = File(
      'lib/features/manga/reader/manga_reader_settings_screen.dart',
    ).readAsStringSync();

    expect(source, contains('Directionality('));
    expect(source, contains('textDirection: TextDirection.ltr'));
    expect(source, contains('automaticallyImplyLeading: false'));
    expect(source, contains('ApplePersistentGlassHeaderScope('));
    expect(source, contains('AppleLiquidGlassBackButton('));
    expect(
      source,
      contains('leading: appleUsesPersistentLiquidGlassHeader ? null'),
    );
    expect(
      source,
      contains('actions: appleUsesPersistentLiquidGlassHeader'),
    );
  });

  testWidgets('reader settings exposes Mangayomi reading and display controls', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mangaReaderSettingsProvider.overrideWith(_ReaderSettingsNotifier.new),
        ],
        child: const MaterialApp(home: MangaReaderSettingsScreen()),
      ),
    );

    expect(find.text('Manga Reader'), findsOneWidget);
    expect(find.text('Reading mode'), findsOneWidget);
    expect(find.text('Automatic double page'), findsOneWidget);
    expect(find.text('Crop borders'), findsOneWidget);

    Future<void> expectWhileScrolling(String label) async {
      final list = find.byType(ListView);
      for (var attempt = 0; attempt < 24; attempt++) {
        if (find.text(label).evaluate().isNotEmpty) {
          expect(find.text(label), findsOneWidget);
          return;
        }
        await tester.drag(list, const Offset(0, -280));
        await tester.pump();
      }
      fail('Reader setting "$label" was not reachable in the settings list.');
    }

    // Assert in the same top-to-bottom order as the lazy ListView so an item
    // is verified while it is actually mounted.
    for (final label in <String>[
      'Keep screen on',
      'Show page number',
      'Auto-read duplicate chapters',
      'Reader hide threshold',
      'Flash color',
    ]) {
      await expectWhileScrolling(label);
    }
  });
}
