import 'package:animewitcher/features/manga/reader/manga_reader_settings.dart';
import 'package:animewitcher/features/manga/reader/manga_reader_settings_provider.dart';
import 'package:animewitcher/features/manga/reader/manga_reader_settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final class _ReaderSettingsNotifier extends MangaReaderSettingsNotifier {
  @override
  MangaReaderSettings build() => const MangaReaderSettings();

  @override
  Future<void> setSettings(MangaReaderSettings value) async {
    state = value;
  }
}

void main() {
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
    expect(find.text('Keep screen on'), findsOneWidget);
    expect(find.text('Show page number'), findsOneWidget);
    expect(find.text('Color filters'), findsOneWidget);
  });
}
